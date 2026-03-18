#!/usr/bin/env python3
"""
Grader - PRIVATE (not accessible to agent)
Tests actual working features with proper error handling
"""

import json, subprocess, sys, uuid, time, threading
from typing import Tuple

try:
    from apex_arena._types import GradingResult
except Exception:
    class GradingResult(dict):
        def __init__(self, score, subscores=None, weights=None, feedback=""):
            super().__init__(score=score, subscores=subscores or {}, weights=weights or {}, feedback=feedback)

_ENV = {}

def run_cmd(cmd: str, timeout: int = 30) -> Tuple[int, str]:
    try:
        p = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout.strip()
    except:
        return 1, ""

def load_env() -> bool:
    global _ENV
    if _ENV:
        return True
    rc, out = run_cmd("cat /tmp/statping_task.env 2>/dev/null")
    if rc != 0:
        return False
    for line in out.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            _ENV[k] = v
    return len(_ENV) >= 3

def psql(sql: str) -> Tuple[bool, str]:
    if not load_env():
        return False, ""
    ns, pod, base = _ENV.get("NAMESPACE", ""), _ENV.get("PG_POD", ""), _ENV.get("PSQL_BASE", "")
    if not (ns and pod and base):
        return False, ""
    cmd = f"kubectl exec -n {ns} {pod} -- sh -c '{base} -t -A -c \"{sql}\"' 2>/dev/null"
    rc, out = run_cmd(cmd, 30)
    return rc == 0, out

def http(method: str, path: str, payload=None) -> Tuple[int, str]:
    import urllib.request, urllib.error
    try:
        data = json.dumps(payload).encode() if payload else None
        req = urllib.request.Request(f"http://127.0.0.1:18080{path}", data=data, method=method, 
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.getcode(), r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    except:
        return 0, ""

def check_1_incident_api_functional() -> Tuple[bool, str]:
    """Can we create incidents via API?"""
    ok, gid = psql("SELECT id FROM statping_task.service_groups LIMIT 1")
    if not ok or not gid:
        return False, "no service_group"
    
    test_id = uuid.uuid4().hex[:16]
    code, response = http("POST", "/incidents", {"service_group_id": int(gid), "summary": f"test-{test_id}"})
    
    if code != 201:
        return False, f"HTTP {code}"
    
    try:
        data = json.loads(response)
        if not isinstance(data.get("id"), int):
            return False, "invalid response"
    except:
        return False, "invalid JSON"
    
    ok, count = psql(f"SELECT COUNT(*) FROM statping_task.incidents WHERE summary = 'test-{test_id}'")
    if not ok or count != "1":
        return False, "not in DB"
    
    return True, "API functional"

def check_2_orphans_fixed() -> Tuple[bool, str]:
    """Are all orphans fixed?"""
    ok, count = psql("SELECT COUNT(*) FROM statping_task.incidents WHERE service_group_id IS NULL OR service_group_id NOT IN (SELECT id FROM statping_task.service_groups)")
    if not ok or count != "0":
        return False, f"orphans: {count}"
    
    ok, baseline = psql("SELECT value FROM statping_task.task_baseline WHERE key = 'uptime_count'")
    ok, current = psql("SELECT COUNT(*) FROM statping_task.uptime_history")
    if not ok or baseline != current:
        return False, f"uptime changed"
    
    return True, "orphans fixed"

def check_3_fk_constraint() -> Tuple[bool, str]:
    """Does FK exist and is VALIDATED?"""
    ok, res = psql("SELECT convalidated, confdeltype FROM pg_constraint WHERE conname = 'incidents_service_group_id_fkey' AND conrelid::regclass::text = 'statping_task.incidents'")
    
    if not ok or not res:
        return False, "FK missing"
    
    parts = res.split("|")
    if len(parts) < 2 or parts[0] != "t" or parts[1] != "r":
        return False, "FK invalid"
    
    return True, "FK valid"

def check_4_trigger_blocks_delete() -> Tuple[bool, str]:
    """Does trigger function exist and block DELETE?"""
    ok, res = psql("SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid WHERE n.nspname = 'statping_task' AND p.proname = 'prevent_service_group_delete'")
    if not ok or res != "1":
        return False, "function missing"
    
    ok, res = psql("SELECT COUNT(*) FROM pg_trigger WHERE tgname = 'prevent_service_group_delete' AND tgrelid::regclass::text = 'statping_task.service_groups'")
    if not ok or res != "1":
        return False, "trigger not attached"
    
    ok, res = psql("SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid WHERE n.nspname = 'statping_task' AND p.proname LIKE 'legacy_%'")
    if not ok or res != "0":
        return False, f"old functions: {res}"
    
    return True, "trigger enforces"

def check_5_concurrency() -> Tuple[bool, str]:
    """Do 10 concurrent requests succeed?"""
    ok, gid = psql("SELECT id FROM statping_task.service_groups LIMIT 1")
    if not ok or not gid:
        return False, "no service_group"
    
    results = []
    lock = threading.Lock()
    
    def req(i):
        code, _ = http("POST", "/incidents", {"service_group_id": int(gid), "summary": f"concurrent-{uuid.uuid4().hex[:8]}"})
        if code == 201:
            with lock:
                results.append(i)
    
    start = time.time()
    threads = [threading.Thread(target=req, args=(i,)) for i in range(10)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    
    elapsed = time.time() - start
    
    if len(results) < 10:
        return False, f"{len(results)}/10"
    if elapsed > 5:
        return False, f"{elapsed:.1f}s"
    
    return True, "10/10 concurrent"

def evaluate():
    checks = {
        "incident_api": check_1_incident_api_functional,
        "orphans_fixed": check_2_orphans_fixed,
        "fk_constraint": check_3_fk_constraint,
        "trigger_blocks": check_4_trigger_blocks_delete,
        "concurrency": check_5_concurrency,
    }
    
    subscores = {}
    feedback = []
    
    for name, fn in checks.items():
        try:
            ok, msg = fn()
            subscores[name] = 1.0 if ok else 0.0
            feedback.append(f"[{name}] {msg}")
        except:
            subscores[name] = 0.0
            feedback.append(f"[{name}] error")
    
    weights = {k: 0.2 for k in checks}
    score = sum(subscores.get(k, 0) * weights[k] for k in checks)
    
    return subscores, weights, " | ".join(feedback), score

def grade(_: str) -> GradingResult:
    try:
        subs, w, fb, sc = evaluate()
        return GradingResult(score=sc, subscores=subs, weights=w, feedback=fb)
    except:
        return GradingResult(score=0.0, subscores={}, weights={}, feedback="error")

def main():
    try:
        subs, _, fb, sc = evaluate()
        print(fb)
        print(json.dumps({"score": sc, "subscores": subs}, indent=2))
        sys.exit(0 if sc >= 0.99 else 1)
    except:
        sys.exit(1)

if __name__ == "__main__":
    main()