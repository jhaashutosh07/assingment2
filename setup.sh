#!/usr/bin/env bash
set -euo pipefail
trap 'echo "[!] Setup failed at line ${LINENO}" >&2; exit 1' ERR

NAMESPACE="fanout"

# ── 1. Create namespace ──────────────────────────────────────────────────────
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "[✓] Namespace $NAMESPACE ready"

# ── 2. Start mock RabbitMQ management API (replaces real RabbitMQ — no image needed) ──
cat > /tmp/mock_rabbitmq.py <<'MOCK_RMQAPI'
#!/usr/bin/env python3
"""
Minimal mock of the RabbitMQ management HTTP API.
Implements only the endpoints used by setup.sh, grader.py, and the agent.
DLQ depth starts at 5 (simulating dropped messages); purge sets it to 0.
"""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
import threading

_dlq_depth = 5
_dlq_lock = threading.Lock()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _reply(self, code, body=b"", ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        global _dlq_depth
        if self.path in ("/api/overview", "/api/overview/"):
            data = json.dumps({"rabbitmq_version": "3.12.0-mock", "management_version": "3.12.0"}).encode()
            return self._reply(200, data)
        if self.path == "/api/queues/%2F/fanout.dlq":
            with _dlq_lock:
                depth = _dlq_depth
            data = json.dumps({"name": "fanout.dlq", "messages": depth, "durable": True}).encode()
            return self._reply(200, data)
        self._reply(404, b'{"error":"not_found"}')

    def do_PUT(self):
        length = int(self.headers.get("Content-Length", 0))
        if length:
            self.rfile.read(length)
        if "fanout.dlq" in self.path:
            return self._reply(201, b'{}')
        self._reply(404, b'{"error":"not_found"}')

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        if length:
            self.rfile.read(length)
        if "publish" in self.path:
            return self._reply(200, b'{"routed":true}')
        self._reply(404, b'{"error":"not_found"}')

    def do_DELETE(self):
        global _dlq_depth
        if "fanout.dlq/contents" in self.path:
            with _dlq_lock:
                _dlq_depth = 0
            return self._reply(204)
        self._reply(404, b'{"error":"not_found"}')

HTTPServer(("127.0.0.1", 15672), Handler).serve_forever()
MOCK_RMQAPI

nohup python3 /tmp/mock_rabbitmq.py >/tmp/mock_rmq.log 2>&1 &
MOCK_RMQ_PID=$!

echo "[*] Waiting for mock RabbitMQ API..."
for i in $(seq 1 20); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -u guest:guest http://127.0.0.1:15672/api/overview 2>/dev/null || true)
  [ "$STATUS" = "200" ] && break
  sleep 1
done
STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -u guest:guest http://127.0.0.1:15672/api/overview 2>/dev/null || true)
[ "$STATUS" = "200" ] || { echo "[!] Mock RabbitMQ API not available" >&2; exit 1; }
echo "[✓] Mock RabbitMQ management API ready (PID $MOCK_RMQ_PID)"

# ── 3. Create fanout-config ConfigMap ────────────────────────────────────────
kubectl -n "$NAMESPACE" create configmap fanout-config \
  --from-literal='queues.conf=fanout.main
fanout.secondary' \
  --from-literal='exchanges.conf=fanout.exchange
fanout.dlx' \
  --dry-run=client -o yaml | kubectl apply -f -
echo "[✓] fanout-config ConfigMap created"

# ── 4. Create fanout-init-script ConfigMap (broken — no empty-file guard) ───
kubectl -n "$NAMESPACE" create configmap fanout-init-script \
  --from-literal='validate-config.sh=#!/bin/sh
# Broken: no guard for empty files
echo "[init] queues.conf: $(cat /config/queues.conf)"
echo "[init] exchanges.conf: $(cat /config/exchanges.conf)"
echo "[init] Validation complete (no empty-file guard)"
exit 0
' \
  --dry-run=client -o yaml | kubectl apply -f -
echo "[✓] fanout-init-script ConfigMap created (broken)"

# ── 5. Create task_baseline ConfigMap ────────────────────────────────────────
kubectl -n "$NAMESPACE" create configmap task-baseline \
  --from-literal=dlq_expected=0 \
  --dry-run=client -o yaml | kubectl apply -f -
echo "[✓] task_baseline ConfigMap created"

# ── 6. Deploy fanout-service with broken projected volume + init container ───
kubectl -n "$NAMESPACE" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fanout-service
  namespace: fanout
spec:
  replicas: 1
  selector:
    matchLabels:
      app: fanout-service
  template:
    metadata:
      labels:
        app: fanout-service
    spec:
      initContainers:
      - name: config-validator
        image: busybox:1.36
        command: ["/bin/sh", "/init/validate-config.sh"]
        volumeMounts:
        - name: fanout-projected
          mountPath: /config
        - name: fanout-init-script
          mountPath: /init
      containers:
      - name: fanout-app
        image: busybox:1.36
        command: ["sh", "-c", "while true; do sleep 30; done"]
        volumeMounts:
        - name: fanout-projected
          mountPath: /config
      volumes:
      - name: fanout-projected
        projected:
          sources:
          - configMap:
              name: fanout-config
              items:
              - key: queues.conf
                path: queues.conf
              - key: exchanges.conf
                path: exchanges.conf
          - serviceAccountToken:
              path: token
              expirationSeconds: 3607
      - name: fanout-init-script
        configMap:
          name: fanout-init-script
          defaultMode: 0755
EOF
echo "[✓] fanout-service Deployment created"

# ── 7. Wait for first pod to be Running ─────────────────────────────────────
echo "[*] Waiting for fanout-service pod to be Running (initial)..."
for i in $(seq 1 60); do
  POD_PHASE=$(kubectl -n "$NAMESPACE" get pods -l app=fanout-service \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
  [ "$POD_PHASE" = "Running" ] && break
  sleep 3
done
POD_PHASE=$(kubectl -n "$NAMESPACE" get pods -l app=fanout-service \
  -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
[ "$POD_PHASE" = "Running" ] || { echo "[!] fanout-service pod not Running" >&2; exit 1; }
echo "[✓] fanout-service initial pod is Running"

# ── 8. Inject broken state: patch fanout-config to empty values ──────────────
echo "[*] Injecting broken state: emptying fanout-config values..."
kubectl -n "$NAMESPACE" patch configmap fanout-config \
  --type merge \
  -p '{"data":{"queues.conf":"","exchanges.conf":""}}'
echo "[✓] fanout-config patched to empty values (race injected)"

# ── 9. Rolling restart so new pod starts with empty ConfigMap ────────────────
echo "[*] Triggering rolling restart of fanout-service..."
kubectl -n "$NAMESPACE" rollout restart deployment/fanout-service
kubectl -n "$NAMESPACE" rollout status deployment/fanout-service --timeout=120s
echo "[✓] Rolling restart complete"

# ── 10. Capture init log for the restarted pod ───────────────────────────────
NEW_POD=$(kubectl -n "$NAMESPACE" get pods -l app=fanout-service \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1].metadata.name}')
kubectl -n "$NAMESPACE" logs "$NEW_POD" -c config-validator \
  > /tmp/fanout_init_log.txt 2>/dev/null || true
echo "[✓] Init container log captured: /tmp/fanout_init_log.txt"

# ── 11. Write environment info ────────────────────────────────────────────────
cat > /tmp/fanout_task.env <<EOF
NAMESPACE=fanout
RABBITMQ_URL=http://127.0.0.1:15672
RABBITMQ_HOST=127.0.0.1
RABBITMQ_PORT=15672
RABBITMQ_USER=guest
RABBITMQ_PASS=guest
EOF
echo "[✓] Environment written to /tmp/fanout_task.env"

# ── 12. Pre-create fanout.dlq and publish 5 messages (simulate DLQ depth) ───
echo "[*] Creating fanout.dlq queue..."
curl -s -u guest:guest -X PUT http://127.0.0.1:15672/api/queues/%2F/fanout.dlq \
  -H "content-type: application/json" \
  -d '{"durable": true}' >/dev/null

echo "[*] Publishing 5 messages to fanout.dlq..."
for i in 1 2 3 4 5; do
  curl -s -u guest:guest -X POST \
    http://127.0.0.1:15672/api/exchanges/%2F/amq.default/publish \
    -H "content-type: application/json" \
    -d "{\"properties\":{},\"routing_key\":\"fanout.dlq\",\"payload\":\"dropped-message-${i}\",\"payload_encoding\":\"string\"}" \
    >/dev/null
done
echo "[✓] 5 messages published to fanout.dlq"

# ── 13. Start status API server (ThreadingHTTPServer) ────────────────────────
cat > /tmp/fanout_api.py <<'PYTHON_API'
#!/usr/bin/env python3
import json, subprocess, sys
import urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RABBITMQ_BASE = "http://127.0.0.1:15672"
RABBITMQ_AUTH = "Basic Z3Vlc3Q6Z3Vlc3Q="  # guest:guest

def get_dlq_depth():
    try:
        req = urllib.request.Request(
            f"{RABBITMQ_BASE}/api/queues/%2F/fanout.dlq",
            headers={"Authorization": RABBITMQ_AUTH}
        )
        with urllib.request.urlopen(req, timeout=5) as r:
            data = json.loads(r.read().decode())
            return int(data.get("messages", 0))
    except Exception:
        return 0

def get_init_guard():
    try:
        result = subprocess.run(
            ["kubectl", "-n", "fanout", "get", "configmap", "fanout-init-script",
             "-o", "jsonpath={.data.validate-config\\.sh}"],
            capture_output=True, text=True, timeout=10
        )
        return "-s /config/queues.conf" in result.stdout
    except Exception:
        return False

def get_pod_starts():
    try:
        with open("/tmp/fanout_init_log.txt") as f:
            log = f.read()
        import re
        nonempty = bool(re.search(r'queues\.conf:\s+\S', log))
        return [{"pod": "latest", "init_exit_code": 0, "config_nonempty": nonempty}]
    except Exception:
        return []

class Handler(BaseHTTPRequestHandler):
    def _json(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/status":
            return self._json(200, {
                "status": "ok",
                "dlq_depth": get_dlq_depth(),
                "init_guard": get_init_guard(),
            })
        elif self.path == "/pod-starts":
            return self._json(200, get_pod_starts())
        return self._json(404, {"error": "not found"})

    def log_message(self, *a):
        pass

try:
    server = ThreadingHTTPServer(("127.0.0.1", 18080), Handler)
    server.serve_forever()
except Exception as e:
    print(f"Server error: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON_API

nohup python3 /tmp/fanout_api.py >/tmp/fanout_api.log 2>&1 &
echo "[*] Waiting for status API server to be ready..."
for i in $(seq 1 15); do
  curl -sf http://127.0.0.1:18080/status >/dev/null 2>&1 && break
  sleep 1
done
curl -sf http://127.0.0.1:18080/status >/dev/null 2>&1 || \
  { echo "[!] Status API server failed to start" >&2; exit 1; }
echo "[✓] Status API server ready at http://127.0.0.1:18080"

# ── 14. Verify setup ──────────────────────────────────────────────────────────
echo "[*] Verifying setup..."
kubectl get namespace "$NAMESPACE" >/dev/null
kubectl -n "$NAMESPACE" get configmap fanout-config >/dev/null
kubectl -n "$NAMESPACE" get configmap fanout-init-script >/dev/null
kubectl -n "$NAMESPACE" get deployment fanout-service >/dev/null

SCRIPT=$(kubectl -n "$NAMESPACE" get configmap fanout-init-script \
  -o jsonpath='{.data.validate-config\.sh}' 2>/dev/null || true)
if echo "$SCRIPT" | grep -q '\-s /config/queues.conf'; then
  echo "[!] validate-config.sh already contains guard — broken state not injected!" >&2
  exit 1
fi
echo "[✓] Broken state confirmed: validate-config.sh has no empty-file guard"

curl -sf http://127.0.0.1:18080/status >/dev/null 2>&1
echo "[✓] API server responds to GET /status"

echo "[✓] Setup complete — fanout-configmap-race task ready"
exit 0