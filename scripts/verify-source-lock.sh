#!/usr/bin/env bash
set -Eeuo pipefail

readonly PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly LOCK_FILE="$PROJECT_ROOT/sources.lock"

[[ -f "$LOCK_FILE" ]] || { echo "missing $LOCK_FILE" >&2; exit 1; }

python3 - "$LOCK_FILE" <<'PY'
import subprocess
import sys

try:
    import yaml
except ImportError as exc:
    raise SystemExit(f"PyYAML is required to verify sources.lock: {exc}")

lock_path = sys.argv[1]
with open(lock_path, encoding="utf-8") as handle:
    lock = yaml.safe_load(handle)

sources = lock.get("sources", {})
if not sources:
    raise SystemExit("sources.lock contains no sources")

for name, entry in sources.items():
    url = entry.get("url", "")
    expected = entry.get("commit")
    ref = entry.get("ref")
    if "/blob/" in url or not ref:
        print(f"SKIP {name}: non-Git artifact or documentation URL")
        continue
    if not expected or len(expected) != 40:
        raise SystemExit(f"{name}: commit must be a full 40-character SHA")

    candidates = [f"refs/heads/{ref}", f"refs/tags/{ref}", f"refs/tags/{ref}^{{}}"]
    result = subprocess.run(
        ["git", "ls-remote", url, *candidates],
        check=True,
        capture_output=True,
        text=True,
    )
    resolved = None
    for line in result.stdout.splitlines():
        sha, remote_ref = line.split("\t", 1)
        if remote_ref.endswith("^{}"):
            resolved = sha
            break
        if resolved is None:
            resolved = sha
    if resolved != expected:
        raise SystemExit(f"{name}: lock mismatch {resolved} != {expected}")
    print(f"LOCK OK {name}: {expected}")
PY
