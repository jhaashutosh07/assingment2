#!/usr/bin/env python3
"""
Grader - PRIVATE (not accessible to agent)
fanout-configmap-race: 6 checks, each weighted ~0.167
"""

import os
# Remove this file from disk to prevent agent access
try:
    _self = os.path.abspath(__file__)
    if os.path.exists(_self) and os.path.basename(_self) == 'grader.py':
        os.unlink(_self)
except Exception:
    pass

import json, re, subprocess, sys, time
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
    """Does validate-config.sh reference both config files and include a retry/sleep?"""
    rc, script = run_kubectl([
        "-n", NAMESPACE, "get", "configmap", "fanout-init-script",
        "-o", "jsonpath={.data.validate-config\\.sh}"
    ])
    if rc != 0 or not script:
        return False, "fanout-init-script ConfigMap not found"
    has_queue_guard = "/config/queues.conf" in script
    has_exchange_guard = "/config/exchanges.conf" in script
    has_retry = bool(re.search(r'sleep\s+[0-9]+', script))
    if has_queue_guard and has_exchange_guard and has_retry:
        return True, "guard present"
    missing = []
    if not has_queue_guard:
        missing.append("/config/queues.conf reference")
    if not has_exchange_guard:
        missing.append("/config/exchanges.conf reference")
    if not has_retry:
        missing.append("sleep <N> retry loop")
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
    """fanout-config restored to match fanout-config-backup values?"""
    # Fetch backup (authoritative)
    rc_b, out_b = run_kubectl([
        "-n", NAMESPACE, "get", "configmap", "fanout-config-backup", "-o", "json"
    ])
    if rc_b != 0:
        return False, "fanout-config-backup not found"
    try:
        backup_data = json.loads(out_b).get("data", {})
    except Exception:
        return False, "failed to parse fanout-config-backup"

    # Fetch current
    rc_c, out_c = run_kubectl([
        "-n", NAMESPACE, "get", "configmap", "fanout-config", "-o", "json"
    ])
    if rc_c != 0:
        return False, "fanout-config not found"
    try:
        current_data = json.loads(out_c).get("data", {})
    except Exception:
        return False, "failed to parse fanout-config"

    problems = []
    for key in ("queues.conf", "exchanges.conf"):
        expected = backup_data.get(key, "").strip()
        actual = current_data.get(key, "").strip()
        if not expected:
            return False, f"fanout-config-backup missing key {key}"
        if actual != expected:
            problems.append(f"{key} mismatch (got {repr(actual[:40])})")

    if problems:
        return False, "; ".join(problems)
    return True, "fanout-config matches backup"


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


def check_6_pod_restart_stability() -> Tuple[bool, str]:
    """Trigger a second rolling restart and confirm init container is stable."""
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
        return False, "no pod found after restart"

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
        return False, f"init exit code after second restart: {exit_code!r}"

    rc_logs, logs = run_kubectl(["-n", NAMESPACE, "logs", pod, "-c", "config-validator"])
    if "ERROR: config files still empty" in logs:
        return False, "ERROR in init logs after second restart"

    return True, "stable across restarts"


def evaluate():
    # 6 checks, each weighted ~0.167
    checks = {
        "init_guard_present": check_1_init_guard_present,
        "init_exit_zero": check_2_init_exit_zero,
        "config_restored": check_3_config_nonempty_at_init,
        "dlq_depth_zero": check_4_dlq_depth_zero,
        "task_baseline_intact": check_5_task_baseline_intact,
        "pod_restart_stability": check_6_pod_restart_stability,
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

    weights = {k: 1/6 for k in checks}
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