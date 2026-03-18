#!/usr/bin/env bash
set -euo pipefail
trap 'echo "[!] Error at line ${LINENO}" >&2; exit 1' ERR

if [ ! -f /tmp/statping_task.env ]; then
  echo "[!] Environment file missing" >&2
  exit 1
fi

while IFS='=' read -r key value; do
  export "$key"="$value"
done < /tmp/statping_task.env

[ -n "${NAMESPACE:-}" ] && [ -n "${PG_POD:-}" ] && [ -n "${PSQL_BASE:-}" ] || exit 1

echo "[+] Executing repair transaction..."

# Single atomic transaction - all or nothing
kubectl -n "$NAMESPACE" exec "$PG_POD" -- sh -c "$PSQL_BASE -v ON_ERROR_STOP=1" <<'TXNSQL'
BEGIN;

-- Fix all orphaned and NULL incidents
UPDATE statping_task.incidents SET service_group_id = 2
WHERE service_group_id IS NULL OR service_group_id NOT IN (SELECT id FROM statping_task.service_groups);

-- Verify orphan fix
DO $$
DECLARE cnt INT;
BEGIN
  SELECT COUNT(*) INTO cnt FROM statping_task.incidents 
  WHERE service_group_id IS NULL OR service_group_id NOT IN (SELECT id FROM statping_task.service_groups);
  IF cnt > 0 THEN RAISE EXCEPTION 'Orphans remain'; END IF;
END $$;

-- Create FK constraint
ALTER TABLE statping_task.incidents DROP CONSTRAINT IF EXISTS incidents_service_group_id_fkey;
ALTER TABLE statping_task.incidents ADD CONSTRAINT incidents_service_group_id_fkey 
FOREIGN KEY (service_group_id) REFERENCES statping_task.service_groups(id) ON DELETE RESTRICT;
ALTER TABLE statping_task.incidents VALIDATE CONSTRAINT incidents_service_group_id_fkey;

-- Remove old broken triggers
DROP TRIGGER IF EXISTS legacy_delete_trigger ON statping_task.service_groups;
DROP FUNCTION IF EXISTS statping_task.legacy_block_delete() CASCADE;

-- Create protective trigger function
CREATE FUNCTION statping_task.prevent_service_group_delete() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM statping_task.incidents WHERE service_group_id = OLD.id) THEN
    RAISE EXCEPTION 'Cannot delete service_group % with active incidents', OLD.id;
  END IF;
  RETURN OLD;
END $$;

-- Attach trigger
CREATE TRIGGER prevent_service_group_delete BEFORE DELETE ON statping_task.service_groups 
FOR EACH ROW EXECUTE FUNCTION statping_task.prevent_service_group_delete();

COMMIT;
TXNSQL

echo "[+] Repair complete"

# Verify all fixed
INVALID=$(kubectl -n "$NAMESPACE" exec "$PG_POD" -- sh -c "$PSQL_BASE -t -A -c \"SELECT COUNT(*) FROM statping_task.incidents WHERE service_group_id IS NULL OR service_group_id NOT IN (SELECT id FROM statping_task.service_groups)\"")
[ "$INVALID" = "0" ] || (echo "[!] Verification failed" >&2; exit 1)

# Test API
HTTP=$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:18080/incidents \
  -H "Content-Type: application/json" -d '{"service_group_id":2,"summary":"test"}' 2>/dev/null || echo "000")
[ "$HTTP" = "201" ] || (echo "[!] API test failed" >&2; exit 1)

echo "[✓] Repair verified - incident creation functional"
exit 0