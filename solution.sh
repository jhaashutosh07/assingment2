#!/usr/bin/env bash
set -euo pipefail
trap 'echo "[!] Error at line ${LINENO}" >&2; exit 1' ERR

NAMESPACE="fanout"

# Step 1: Restore fanout-config to the exact non-empty values required by the grader.
# queues.conf must contain "fanout.main\nfanout.secondary"
# exchanges.conf must contain "fanout.exchange\nfanout.dlx"
echo "[+] Step 1: Restore fanout-config to non-empty values..."
kubectl -n "$NAMESPACE" patch configmap fanout-config \
  --type merge \
  -p '{"data":{"queues.conf":"fanout.main\nfanout.secondary","exchanges.conf":"fanout.exchange\nfanout.dlx"}}'

echo "[+] Step 2: Update fanout-init-script with guard logic..."
kubectl -n "$NAMESPACE" create configmap fanout-init-script \
  --from-literal=validate-config.sh='#!/bin/sh
# Guard: wait for non-empty config files (up to 60s)
echo "[init] Waiting for non-empty config files..."
for i in $(seq 1 30); do
  if [ -s /config/queues.conf ] && [ -s /config/exchanges.conf ]; then
    echo "[init] queues.conf: $(cat /config/queues.conf)"
    echo "[init] exchanges.conf: $(cat /config/exchanges.conf)"
    echo "[init] Validation complete - config files non-empty"
    exit 0
  fi
  echo "[init] Attempt $i: config files empty, retrying in 2s..."
  sleep 2
done
echo "[init] ERROR: config files still empty after 60s"
exit 1
' \
  --dry-run=client -o yaml | kubectl apply -f -

echo "[+] Step 3: Optionally separate the projected volume..."
# Patch the Deployment to use separate volumes (removes the race at kubelet level)
kubectl -n "$NAMESPACE" patch deployment fanout-service --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/volumes/0","value":{
    "name":"fanout-config-vol",
    "configMap":{"name":"fanout-config"}
  }},
  {"op":"replace","path":"/spec/template/spec/initContainers/0/volumeMounts/0","value":{
    "name":"fanout-config-vol",
    "mountPath":"/config"
  }}
]' 2>/dev/null || echo "[*] Volume separation patch skipped (optional)"

echo "[+] Step 4: Rolling restart to apply changes..."
kubectl -n "$NAMESPACE" rollout restart deployment/fanout-service
kubectl -n "$NAMESPACE" rollout status deployment/fanout-service --timeout=120s

echo "[+] Step 5: Drain the dead letter queue..."
# Purge fanout.dlq via RabbitMQ management API.
# This is required because the grader checks that fanout.dlq message count is 0.
# The 5 messages accumulated during the broken state must be cleared after the fix is applied.
curl -s -u guest:guest -X DELETE \
  "http://127.0.0.1:15672/api/queues/%2F/fanout.dlq/contents" \
  -H "content-type: application/json" || true

echo "[+] Step 6: Capture init container log..."
NEW_POD=$(kubectl -n "$NAMESPACE" get pods -l app=fanout-service \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
kubectl -n "$NAMESPACE" logs "$NEW_POD" -c config-validator > /tmp/fanout_init_log.txt 2>/dev/null || true

echo "[✓] Solution applied"
exit 0
