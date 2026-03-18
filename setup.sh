#!/usr/bin/env bash
set -euo pipefail
trap 'echo "[!] Setup failed at line ${LINENO}" >&2; exit 1' ERR

NAMESPACE="bleater"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "[*] Waiting for PostgreSQL pod..."
PG_POD=""
for i in {1..60}; do
  PG_POD=$(kubectl -n "$NAMESPACE" get pods -o name 2>/dev/null | grep postgres | head -1 | cut -d/ -f2)
  [ -n "$PG_POD" ] && break
  sleep 1
done

[ -n "$PG_POD" ] || { echo "[!] PostgreSQL pod not found" >&2; exit 1; }

PSQL_BASE="PGPASSWORD=bleater psql -U bleater -d bleater -q"

echo "[*] Waiting for PostgreSQL to accept connections..."
for i in {1..60}; do
  kubectl -n "$NAMESPACE" exec "$PG_POD" -- sh -c "PGPASSWORD=bleater pg_isready -U bleater -d bleater -q" 2>/dev/null && break
  sleep 2
done

kubectl -n "$NAMESPACE" exec "$PG_POD" -- sh -c "PGPASSWORD=bleater pg_isready -U bleater -d bleater -q" || {
  echo "[!] PostgreSQL not accepting connections" >&2; exit 1
}

cat > /tmp/statping_task.env <<EOF
NAMESPACE=$NAMESPACE
PG_POD=$PG_POD
PSQL_BASE=$PSQL_BASE
EOF

echo "[*] Generating randomized scenario..."
ORPHAN_TOTAL=$((100 + RANDOM % 101))
NULL_COUNT=$((10 + RANDOM % 21))
SG1_COUNT=$((ORPHAN_TOTAL / 3))
SG3_COUNT=$((ORPHAN_TOTAL / 3))
SG4_COUNT=$((ORPHAN_TOTAL - SG1_COUNT - SG3_COUNT))

echo "[*] Creating database schema and broken state..."

# Create schema and base tables
kubectl -n "$NAMESPACE" exec "$PG_POD" -- sh -c "$PSQL_BASE" <<'SCHEMA_SQL'

DROP SCHEMA IF EXISTS statping_task CASCADE;
CREATE SCHEMA statping_task;

-- Service groups table (only 2 and 5 exist; 1, 3, 4 were deleted)
CREATE TABLE statping_task.service_groups (
  id INT PRIMARY KEY,
  name TEXT NOT NULL
);

INSERT INTO statping_task.service_groups VALUES
  (2, 'valid-group'),
  (5, 'unreferenced-group');

-- Incidents table with broken references
CREATE TABLE statping_task.incidents (
  id SERIAL PRIMARY KEY,
  service_group_id INT,
  summary TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Baseline data (must be preserved)
CREATE TABLE statping_task.uptime_history (
  id SERIAL PRIMARY KEY,
  service_name TEXT,
  status TEXT
);

INSERT INTO statping_task.uptime_history (service_name, status) VALUES
  ('fanout-service', 'degraded'),
  ('fanout-service', 'ok');

CREATE TABLE statping_task.task_baseline (
  key TEXT PRIMARY KEY,
  value TEXT
);

INSERT INTO statping_task.task_baseline (key, value) VALUES ('uptime_count', '2');

-- Legacy trigger that must be removed
CREATE FUNCTION statping_task.legacy_block_delete()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'Legacy protection';
END;
$$;

CREATE TRIGGER legacy_delete_trigger
BEFORE DELETE ON statping_task.service_groups
FOR EACH ROW EXECUTE FUNCTION statping_task.legacy_block_delete();

SCHEMA_SQL
rc=$?
[ $rc -eq 0 ] || { echo "[!] Schema creation failed (exit $rc)" >&2; exit 1; }

# Insert orphaned and NULL incidents (variables substituted here)
cat > /tmp/orphans.sql <<ORPHAN_INSERT
INSERT INTO statping_task.incidents (service_group_id, summary) 
SELECT 1, 'orphan-sg1-' || i FROM generate_series(1, $SG1_COUNT) AS i;

INSERT INTO statping_task.incidents (service_group_id, summary)
SELECT 3, 'orphan-sg3-' || i FROM generate_series(1, $SG3_COUNT) AS i;

INSERT INTO statping_task.incidents (service_group_id, summary)
SELECT 4, 'orphan-sg4-' || i FROM generate_series(1, $SG4_COUNT) AS i;

INSERT INTO statping_task.incidents (service_group_id, summary)
SELECT NULL, 'null-incident-' || i FROM generate_series(1, $NULL_COUNT) AS i;
ORPHAN_INSERT

kubectl -n "$NAMESPACE" exec "$PG_POD" -- sh -c "$PSQL_BASE" < /tmp/orphans.sql
rc=$?
[ $rc -eq 0 ] || { echo "[!] Orphan insert failed (exit $rc)" >&2; exit 1; }
rm -f /tmp/orphans.sql

echo "[✓] Created broken state: $ORPHAN_TOTAL orphans, $NULL_COUNT NULLs"

echo "[*] Verifying setup..."
SCHEMA_CHECK=$(kubectl -n "$NAMESPACE" exec "$PG_POD" -- sh -c "$PSQL_BASE -t -A -c \"SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = 'statping_task'\"")
[ "$SCHEMA_CHECK" = "1" ] || { echo "[!] Schema verification failed" >&2; exit 1; }

TABLE_CHECK=$(kubectl -n "$NAMESPACE" exec "$PG_POD" -- sh -c "$PSQL_BASE -t -A -c \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'statping_task' AND table_name IN ('incidents','service_groups','uptime_history','task_baseline')\"")
[ "$TABLE_CHECK" = "4" ] || { echo "[!] Table verification failed: expected 4, got $TABLE_CHECK" >&2; exit 1; }

ORPHAN_CHECK=$(kubectl -n "$NAMESPACE" exec "$PG_POD" -- sh -c "$PSQL_BASE -t -A -c \"SELECT COUNT(*) FROM statping_task.incidents WHERE service_group_id IS NULL OR service_group_id NOT IN (SELECT id FROM statping_task.service_groups)\"")
echo "[✓] Setup verified: schema exists, $TABLE_CHECK/4 tables present, $ORPHAN_CHECK orphans created"

# Start API server
cat > /tmp/api.py <<'PYTHON_API'
#!/usr/bin/env python3
import json, subprocess, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

env = {}
with open('/tmp/statping_task.env') as f:
    for line in f:
        if '=' in line:
            k, v = line.strip().split('=', 1)
            env[k] = v

def psql(sql):
    cmd = f"kubectl exec -n {env['NAMESPACE']} {env['PG_POD']} -- sh -c '{env['PSQL_BASE']} -t -A -c \"{sql}\"'"
    try:
        p = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        return p.returncode == 0, p.stdout.strip()
    except:
        return False, ""

class Handler(BaseHTTPRequestHandler):
    def _json(self, code, data):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def do_POST(self):
        if self.path != "/incidents":
            return self._json(404, {"error": "not found"})
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length)) if length else {}
            gid = body.get("service_group_id")
            summary = body.get("summary", "").replace("'", "''")
            if gid is None or not summary:
                return self._json(400, {"error": "missing fields"})
            ok, out = psql(f"INSERT INTO statping_task.incidents(service_group_id,summary) VALUES({int(gid)},'{summary}') RETURNING id;")
            if not ok:
                return self._json(500, {"error": "constraint violation"})
            return self._json(201, {"id": int(out), "service_group_id": gid, "summary": summary})
        except:
            return self._json(400, {"error": "bad request"})

    def do_GET(self):
        if self.path == "/incidents":
            ok, out = psql("SELECT id, service_group_id, summary FROM statping_task.incidents ORDER BY id DESC LIMIT 200;")
            rows = []
            for line in out.splitlines():
                try:
                    p = line.split("|", 2)
                    rows.append({"id": int(p[0]), "service_group_id": int(p[1]) if p[1] else None, "summary": p[2] if len(p) > 2 else ""})
                except:
                    pass
            return self._json(200, rows)
        elif self.path == "/status":
            return self._json(200, {"status": "ok"})
        return self._json(404, {})

    def log_message(self, *a):
        pass

try:
    HTTPServer(("127.0.0.1", 18080), Handler).serve_forever()
except:
    sys.exit(1)
PYTHON_API

nohup python3 /tmp/api.py >/tmp/api.log 2>&1 &
sleep 2

echo "[✓] API server started"
echo "[✓] Setup complete"
exit 0