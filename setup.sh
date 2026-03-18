#!/usr/bin/env bash
set -euo pipefail
trap 'echo "[!] Setup failed at line ${LINENO}" >&2; exit 1' ERR

NAMESPACE="fanout"

# ── 1. Create namespace ──────────────────────────────────────────────────────
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "[✓] Namespace $NAMESPACE ready"

# ── 2. Deploy RabbitMQ ───────────────────────────────────────────────────────
kubectl -n "$NAMESPACE" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rabbitmq
  namespace: fanout
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rabbitmq
  template:
    metadata:
      labels:
        app: rabbitmq
    spec:
      containers:
      - name: rabbitmq
        image: rabbitmq:3.12-management
        ports:
        - containerPort: 5672
        - containerPort: 15672
        env:
        - name: RABBITMQ_DEFAULT_USER
          value: guest
        - name: RABBITMQ_DEFAULT_PASS
          value: guest
        readinessProbe:
          httpGet:
            path: /api/overview
            port: 15672
          initialDelaySeconds: 20
          periodSeconds: 5
          timeoutSeconds: 5
          failureThreshold: 12
---
apiVersion: v1
kind: Service
metadata:
  name: rabbitmq
  namespace: fanout
spec:
  selector:
    app: rabbitmq
  ports:
  - name: amqp
    port: 5672
    targetPort: 5672
  - name: management
    port: 15672
    targetPort: 15672
EOF
echo "[✓] RabbitMQ Deployment + Service created"

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
RABBITMQ_USER=guest
RABBITMQ_PASS=guest
EOF
echo "[✓] Environment written to /tmp/fanout_task.env"

# ── 12. Port-forward RabbitMQ management API ─────────────────────────────────
echo "[*] Port-forwarding RabbitMQ management port..."
# Wait for RabbitMQ pod to be ready first
for i in $(seq 1 60); do
  RMQP=$(kubectl -n "$NAMESPACE" get pods -l app=rabbitmq \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
  [ "$RMQP" = "Running" ] && break
  sleep 3
done

kubectl -n "$NAMESPACE" port-forward svc/rabbitmq 15672:15672 \
  >/tmp/rabbitmq_pf.log 2>&1 &
PF_PID=$!
echo "[*] Port-forward PID: $PF_PID"

# Wait for RabbitMQ management API to be available
echo "[*] Waiting for RabbitMQ management API..."
for i in $(seq 1 40); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -u guest:guest http://127.0.0.1:15672/api/overview 2>/dev/null || true)
  [ "$STATUS" = "200" ] && break
  sleep 3
done
STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -u guest:guest http://127.0.0.1:15672/api/overview 2>/dev/null || true)
[ "$STATUS" = "200" ] || { echo "[!] RabbitMQ management API not available" >&2; exit 1; }
echo "[✓] RabbitMQ management API ready"

# ── 13. Pre-create fanout.dlq and publish 5 messages (simulate DLQ depth) ───
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

# ── 14. Start status API server (ThreadingHTTPServer) ────────────────────────
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

# ── 15. Verify setup ──────────────────────────────────────────────────────────
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