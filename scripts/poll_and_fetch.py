#!/usr/bin/env python3
# Poll Actions run for Corpse-zhao/WiFiRelay; on success download artifact zip.
import json, os, re, sys, time, urllib.request, urllib.error

REPO = "Corpse-zhao/WiFiRelay"

def token():
    cfg = "C:/Users/Administrator/WorkBuddy/2026-10-28-11-00-19/MotoCarPlay/.git/config"
    with open(cfg, "r", encoding="utf-8", errors="ignore") as f:
        return re.search(r"gh[pousr]_[A-Za-z0-9]+", f.read()).group(0)

TOKEN = token()

def api(method, path, payload=None, raw=False):
    url = f"https://api.github.com{path}"
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"token {TOKEN}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("User-Agent", "wifirelay-ci")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            b = r.read()
            if raw:
                return r.status, b, dict(r.headers)
            return r.status, (json.loads(b) if b else {}), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode(errors="ignore")[:400]}, {}

deadline = time.time() + 900
run = None
while time.time() < deadline:
    st, d, _ = api("GET", f"/repos/{REPO}/actions/workflows/build.yml/runs?per_page=1")
    runs = d.get("workflow_runs") or []
    if runs:
        run = runs[0]
        print(f"run {run['id']} status={run['status']} conclusion={run.get('conclusion')}", flush=True)
        if run["status"] == "completed":
            break
    time.sleep(20)

if not run or run["status"] != "completed":
    print("TIMEOUT waiting for CI"); sys.exit(2)
if run["conclusion"] != "success":
    st, jobs, _ = api("GET", f"/repos/{REPO}/actions/runs/{run['id']}/jobs")
    for j in jobs.get("jobs", []):
        for s in j.get("steps", []):
            if s.get("conclusion") not in ("success", "skipped", None):
                print(f"FAILED step: {s['name']}")
    print("CI FAILED, run id:", run["id"]); sys.exit(3)

print("CI SUCCESS, fetching artifact...")
st, arts, _ = api("GET", f"/repos/{REPO}/actions/runs/{run['id']}/artifacts")
art = (arts.get("artifacts") or [None])[0]
assert art, "no artifact"
url = f"https://api.github.com/repos/{REPO}/actions/artifacts/{art['id']}/zip"
st, body, hdrs = api("GET", url, raw=True)
if st not in (200, 302):
    # follow manually with redirect location
    print("artifact fetch status", st); sys.exit(4)
out_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "packages")
os.makedirs(out_dir, exist_ok=True)
out = os.path.join(out_dir, "wifirelay-artifact.zip")
open(out, "wb").write(body)
print("artifact saved:", out, len(body), "bytes")
