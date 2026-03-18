#!/usr/bin/env python3
"""
Grader - PRIVATE (not accessible to agent)
fanout-configmap-race: 5 checks, each weighted 0.2
"""

import os
# Remove this file from disk to prevent agent access
try:
    _self = os.path.abspath(__file__)
    if os.path.exists(_self) and os.path.basename(_self) == 'grader.py':
        os.unlink(_self)
except Exception:
    pass

import json, subprocess, sys, time
from typing import Tuple

try:
    from apex_arena._types import GradingResult
except Exception:
    class GradingResult(dict):
        def __init__(self, score, subscores=None, weights=None, feedback=""):
            super().__init__(score=score, subscores=subscores or {}, weights=weights or {}, feedback=feedback)

NAMESPACE = "fanout"


def run_kubectl(args: list, timeout: int = 30) -> Tuple[int, str]:
    try:
        p = subprocess.run(
            ["kubectl"] + args,
            capture_output=True, text=True, timeout=timeout
        )
        return p.returncode, p.stdout.strip()
    except Exception:
        return 1, ""


def http_get(url: str, auth_header: str = None, timeout: int = 10) -> Tuple[int, str]:
    import urllib.request, urllib.error
    try:
        req = urllib.request.Request(url)
        if auth_header:
            req.add_header("Authorization", auth_header)
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.getcode(), r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    except Exception:
        return 0, ""


def get_newest_pod() -> str:
    rc, out = run_kubectl([
        "-n", NAMESPACE, "get", "pods", "-l", "app=fanout-service",
        "--sort-by=.metadata.creationTimestamp",
        "-o", "jsonpath={.items[-1].metadata.name}"
    ])
    return out.strip() if rc == 0 else ""


def check_1_init_guard_present() -> Tuple[bool, str]:
    """Does validate-config.sh contain the -s guard?"""
    rc, script = run_kubectl([
        "-n", NAMESPACE, "get", "configmap", "fanout-init-script",
        "-o", "jsonpath={.data.validate-config\\.sh}"
    ])
    if rc != 0 or not script:
        return False, "fanout-init-script ConfigMap not found"
    if "-s /config/queues.conf" in script:
        return True, "guard present"
    return False, "guard missing"


def check_2_init_exit_zero() -> Tuple[bool, str]:
    """After rolling restart, init container exits 0 and no ERROR in logs."""
    # Trigger rolling restart
    rc, _ = run_kubectl(["-n", NAMESPACE, "rollout", "restart", "deployment/fanout-service"])
    if rc != 0:
        return False, "rollout restart failed"

    # Wait for rollout to complete
    rc, _ = run_kubectl(
        ["-n", NAMESPACE, "rollout", "status", "deployment/fanout-service", "--timeout=120s"],
        timeout=130
    )
    if rc != 0:
        return False, "rollout did not complete"

    pod = get_newest_pod()
    if not pod:
        return False, "no pod found"

    # Check init container exit code
    rc, exit_code = run_kubectl([
        "-n", NAMESPACE, "get", "pod", pod,
        "-o", "jsonpath={.status.initContainerStatuses[0].state.terminated.exitCode}"
    ])
    if rc != 0:
        return False, "could not read init exit code"
    if exit_code != "0":
        return False, f"init exit code: {exit_code}"

    # Check logs do not contain ERROR
    rc, logs = run_kubectl(["-n", NAMESPACE, "logs", pod, "-c", "config-validator"])
    if "ERROR: config files still empty" in logs:
        return False, "ERROR in init logs"

    return True, "init exit 0"


def check_3_config_nonempty_at_init() -> Tuple[bool, str]:
    """Init container logs show non-empty queues.conf content."""
    pod = get_newest_pod()
    if not pod:
        return False, "no pod found"

    rc, logs = run_kubectl(["-n", NAMESPACE, "logs", pod, "-c", "config-validator"])
    if rc != 0:
        return False, "could not read init logs"

    # Look for 'queues.conf: fanout' — non-empty content was read
    if "queues.conf: fanout" in logs:
        return True, "config non-empty at init"
    return False, "queues.conf empty at init"


def check_4_dlq_depth_zero() -> Tuple[bool, str]:
    """fanout.dlq message count is 0."""
    code, body = http_get(
        "http://127.0.0.1:15672/api/queues/%2F/fanout.dlq",
        auth_header="Basic Z3Vlc3Q6Z3Vlc3Q="
    )
    if code == 404:
        # Queue doesn't exist = depth 0
        return True, "dlq depth 0 (queue absent)"
    if code != 200:
        return False, f"RabbitMQ API HTTP {code}"
    try:
        data = json.loads(body)
        depth = int(data.get("messages", -1))
        if depth == 0:
            return True, "dlq depth 0"
        return False, f"dlq depth {depth}"
    except Exception:
        return False, "invalid RabbitMQ response"


def check_5_status_api_functional() -> Tuple[bool, str]:
    """GET /status returns 200 with status=ok and init_guard=true."""
    code, body = http_get("http://127.0.0.1:18080/status")
    if code != 200:
        return False, f"HTTP {code}"
    try:
        data = json.loads(body)
        if data.get("status") != "ok":
            return False, f"status={data.get('status')}"
        if data.get("init_guard") is not True:
            return False, f"init_guard={data.get('init_guard')}"
        return True, "status ok, init_guard true"
    except Exception:
        return False, "invalid JSON"


def evaluate():
    checks = {
        "init_guard_present": check_1_init_guard_present,
        "init_exit_zero": check_2_init_exit_zero,
        "config_nonempty_at_init": check_3_config_nonempty_at_init,
        "dlq_depth_zero": check_4_dlq_depth_zero,
        "status_api_functional": check_5_status_api_functional,
    }

    subscores = {}
    feedback = []

    for name, fn in checks.items():
        try:
            ok, msg = fn()
            subscores[name] = 1.0 if ok else 0.0
            feedback.append(f"[{name}] {msg}")
        except Exception:
            subscores[name] = 0.0
            feedback.append(f"[{name}] error")

    weights = {k: 0.2 for k in checks}
    score = sum(subscores.get(k, 0) * weights[k] for k in checks)
    return subscores, weights, " | ".join(feedback), score


def grade(_: str) -> GradingResult:
    try:
        subs, w, fb, sc = evaluate()
        return GradingResult(score=sc, subscores=subs, weights=w, feedback=fb)
    except Exception:
        return GradingResult(score=0.0, subscores={}, weights={}, feedback="error")


def main():
    try:
        subs, _, fb, sc = evaluate()
        print(fb)
        print(json.dumps({"score": sc, "subscores": subs}, indent=2))
        sys.exit(0 if sc >= 0.99 else 1)
    except Exception:
        sys.exit(1)


if __name__ == "__main__":
    main()