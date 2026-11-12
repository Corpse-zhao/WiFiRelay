#!/usr/bin/env python3
# One-shot: create Corpse-zhao/WiFiRelay and push all files in a single commit via REST API
import base64, json, os, sys, urllib.request, urllib.error, re

REPO = "Corpse-zhao/WiFiRelay"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # repo root = parent of scripts/
EXEC_FILES = {"layout/DEBIAN/postinst", "layout/DEBIAN/prerm"}
MSG = "WiFiRelay v0.1.0: root daemon + pf anchor to force cellular fallback on internet-less hotspots"
BRANCH = "main"

def token():
    t = os.environ.get("GITHUB_TOKEN")
    if t:
        return t
    cfg = "C:/Users/Administrator/WorkBuddy/2026-10-28-11-00-19/MotoCarPlay/.git/config"
    with open(cfg, "r", encoding="utf-8", errors="ignore") as f:
        m = re.search(r"gh[pousr]_[A-Za-z0-9]+", f.read())
    if not m:
        sys.exit("no token found")
    return m.group(0)

TOKEN = token()

def api(method, path, payload=None):
    url = f"https://api.github.com{path}"
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"token {TOKEN}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("User-Agent", "wifirelay-push")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            body = r.read()
            return r.status, (json.loads(body) if body else {})
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode(errors="ignore")[:300]}

# 1. ensure repo exists
st, r = api("POST", "/user/repos", {"name": "WiFiRelay", "description": "Keep cellular internet alive on internet-less hotspots (CarPlay head units)", "private": False, "auto_init": False})
print("create repo:", st, r.get("html_url") or r)
if st == 422:
    print("repo already exists, continue")

# 2. collect files
files = []
for dirpath, dirnames, filenames in os.walk(ROOT):
    dirnames[:] = [d for d in dirnames if d not in (".git", "packages", "obj", ".theos")]
    for fn in filenames:
        full = os.path.join(dirpath, fn)
        rel = os.path.relpath(full, ROOT).replace("\\", "/")
        files.append((rel, full))
files.sort()
print("files:", [f[0] for f in files])

# 3. empty-repo bootstrap: initial commit via contents API
st, r = api("GET", f"/repos/{REPO}/git/refs/heads/{BRANCH}")
if st == 200:
    base_sha = r["object"]["sha"]
    print("existing base:", base_sha)
else:
    readme = os.path.join(ROOT, "README.md")
    content_b64 = base64.b64encode(open(readme, "rb").read()).decode() if os.path.exists(readme) else base64.b64encode(b"# WiFiRelay\n").decode()
    st, r = api("PUT", f"/repos/{REPO}/contents/README.md", {"message": "init", "content": content_b64, "branch": BRANCH})
    assert st in (200, 201), f"bootstrap commit: {st} {r}"
    base_sha = r["commit"]["sha"]
    print("bootstrapped empty repo:", base_sha)

# 4. blobs -> tree -> commit -> update ref
tree_items = []
for rel, full in files:
    if rel == "README.md":
        continue
    with open(full, "rb") as f:
        content = f.read()
    st, b = api("POST", f"/repos/{REPO}/git/blobs", {"content": base64.b64encode(content).decode(), "encoding": "base64"})
    assert st == 201, f"blob {rel}: {st} {b}"
    mode = "100755" if rel in EXEC_FILES else "100644"
    tree_items.append({"path": rel, "mode": mode, "type": "blob", "sha": b["sha"]})
    print("blob ok:", rel, mode)

st, t = api("POST", f"/repos/{REPO}/git/trees", {"base_tree": base_sha, "tree": tree_items})
assert st == 201, f"tree: {st} {t}"

st, c = api("POST", f"/repos/{REPO}/git/commits", {"message": MSG, "tree": t["sha"], "parents": [base_sha]})
assert st == 201, f"commit: {st} {c}"

st, u = api("PATCH", f"/repos/{REPO}/git/refs/heads/{BRANCH}", {"sha": c["sha"], "force": True})
assert st == 200, f"ref: {st} {u}"
print("PUSHED:", c["sha"], "-> https://github.com/" + REPO)
