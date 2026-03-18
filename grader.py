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
_LATEST_POD = ""


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
    """Does validate-config.sh contain the -s guard for BOTH files and a retry loop?"""
    rc, script = run_kubectl([
        "-n", NAMESPACE, "get", "configmap", "fanout-init-script",
        "-o", "jsonpath={.data.validate-config\\.sh}"
    ])
    if rc != 0 or not script:
        return False, "fanout-init-script ConfigMap not found"
    has_queue_guard = "-s /config/queues.conf" in script
    has_exchange_guard = "-s /config/exchanges.conf" in script
    has_retry = "sleep 2" in script
    if has_queue_guard and has_exchange_guard and has_retry:
        return True, "guard present"
    missing = []
    if not has_queue_guard:
        missing.append("-s /config/queues.conf")
    if not has_exchange_guard:
        missing.append("-s /config/exchanges.conf")
    if not has_retry:
        missing.append("sleep 2 (retry loop)")
    return False, f"guard missing: {', '.join(missing)}"


def check_2_init_exit_zero() -> Tuple[bool, str]:
    """After rolling restart, init container exits 0 and no ERROR in logs."""
    global _LATEST_POD

    # Check if pod is already healthy (agent already did a successful rollout)
    pod = get_newest_pod()
    already_healthy = False
    if pod:
        rc_ec, exit_code = run_kubectl([
            "-n", NAMESPACE, "get", "pod", pod,
            "-o", "jsonpath={.status.initContainerStatuses[0].state.terminated.exitCode}"
        ])
        rc_logs, logs = run_kubectl(["-n", NAMESPACE, "logs", pod, "-c", "config-validator"])
        if rc_ec == 0 and exit_code == "0" and "ERROR: config files still empty" not in logs:
            already_healthy = True

    if not already_healthy:
        # Trigger rolling restart
        rc, _ = run_kubectl(["-n", NAMESPACE, "rollout", "restart", "deployment/fanout-service"])
        if rc != 0:
            return False, "rollout restart failed"

        # Wait for rollout to complete (180s)
        rc, _ = run_kubectl(
            ["-n", NAMESPACE, "rollout", "status", "deployment/fanout-service", "--timeout=180s"],
            timeout=190
        )
        if rc != 0:
            return False, "rollout did not complete"

    pod = get_newest_pod()
    if not pod:
        return False, "no pod found"

    # Wait for init container to reach terminated state (30 attempts × 2s = 60s max)
    exit_code = ""
    for _ in range(30):
        rc_ec, exit_code = run_kubectl([
            "-n", NAMESPACE, "get", "pod", pod,
            "-o", "jsonpath={.status.initContainerStatuses[0].state.terminated.exitCode}"
        ])
        if rc_ec == 0 and exit_code != "":
            break
        time.sleep(2)

    if exit_code != "0":
        return False, f"init exit code: {exit_code!r}"

    rc_logs, logs = run_kubectl(["-n", NAMESPACE, "logs", pod, "-c", "config-validator"])
    if "ERROR: config files still empty" in logs:
        return False, "ERROR in init logs"

    _LATEST_POD = pod
    return True, "init exit 0"


def check_3_config_nonempty_at_init() -> Tuple[bool, str]:
    """fanout-config restored to exact required values?"""
    EXPECTED_QUEUES = "fanout.main\nfanout.secondary"
    EXPECTED_EXCHANGES = "fanout.exchange\nfanout.dlx"

    rc, out = run_kubectl([
        "-n", NAMESPACE, "get", "configmap", "fanout-config", "-o", "json"
    ])
    if rc != 0:
        return False, "fanout-config not found"

    try:
        data = json.loads(out).get("data", {})
    except Exception:
        return False, "failed to parse fanout-config"

    queues = data.get("queues.conf", "")
    exchanges = data.get("exchanges.conf", "")

    queues_ok = queues.strip() == EXPECTED_QUEUES
    exchanges_ok = exchanges.strip() == EXPECTED_EXCHANGES

    if queues_ok and exchanges_ok:
        return True, "fanout-config exact values correct"

    problems = []
    if not queues_ok:
        problems.append(f"queues.conf={repr(queues.strip())} (expected {repr(EXPECTED_QUEUES)})")
    if not exchanges_ok:
        problems.append(f"exchanges.conf={repr(exchanges.strip())} (expected {repr(EXPECTED_EXCHANGES)})")
    return False, f"wrong values: {'; '.join(problems)}"


def check_4_dlq_depth_zero() -> Tuple[bool, str]:
    """fanout.dlq message count is 0 AND init guard is present (prevents gaming via direct purge)."""
    # Verify guard is present — prevents scoring by purging DLQ without fixing root cause
    guard_ok, guard_msg = check_1_init_guard_present()
    if not guard_ok:
        return False, f"dlq purge without guard fix ({guard_msg})"

    code, body = http_get(
        "http://127.0.0.1:15672/api/queues/%2F/fanout.dlq",
        auth_header="Basic Z3Vlc3Q6Z3Vlc3Q="
    )
    if code == 404:
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


def check_5_task_baseline_intact() -> Tuple[bool, str]:
    """task-baseline ConfigMap is unchanged (dlq_expected=0)."""
    rc, val = run_kubectl([
        "-n", NAMESPACE, "get", "configmap", "task-baseline",
        "-o", "jsonpath={.data.dlq_expected}"
    ])
    if rc != 0 or not val:
        return False, "task-baseline ConfigMap missing or empty"
    if val.strip() == "0":
        return True, "task-baseline intact"
    return False, f"task-baseline tampered: dlq_expected={val}"


def evaluate():
    checks = {
        "init_guard_present": check_1_init_guard_present,
        "init_exit_zero": check_2_init_exit_zero,
        "config_nonempty_at_init": check_3_config_nonempty_at_init,
        "dlq_depth_zero": check_4_dlq_depth_zero,
        "task_baseline_intact": check_5_task_baseline_intact,
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