#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly REPO_ROOT
readonly LOCK_FILE="$REPO_ROOT/sources.lock"
readonly SOURCE_ROOT="$REPO_ROOT/sources"

usage() {
    echo "usage: $0 SOURCE_NAME [SOURCE_NAME ...]" >&2
}

[[ $# -ge 1 ]] || { usage; exit 2; }
mkdir -p "$SOURCE_ROOT"

python3 - "$LOCK_FILE" "$SOURCE_ROOT" "$@" <<'PY'
import os
import subprocess
import sys

import yaml

lock_path, source_root, *names = sys.argv[1:]
with open(lock_path, encoding="utf-8") as handle:
    sources = yaml.safe_load(handle)["sources"]

for name in names:
    if name not in sources:
        raise SystemExit(f"unknown source: {name}")
    entry = sources[name]
    url = entry.get("url", "")
    commit = entry.get("commit")
    if "/blob/" in url or not commit:
        raise SystemExit(f"{name}: not a cloneable Git source")

    destination = os.path.join(source_root, name)
    if not os.path.isdir(os.path.join(destination, ".git")):
        os.makedirs(destination, exist_ok=True)
        subprocess.run(["git", "-C", destination, "init"], check=True)
        subprocess.run(["git", "-C", destination, "remote", "add", "origin", url], check=True)
    else:
        current_url = subprocess.check_output(
            ["git", "-C", destination, "remote", "get-url", "origin"], text=True
        ).strip()
        if current_url != url:
            subprocess.run(
                ["git", "-C", destination, "remote", "set-url", "origin", url],
                check=True,
            )
    subprocess.run(["git", "-C", destination, "fetch", "--no-tags", "origin", commit], check=True)
    subprocess.run(["git", "-C", destination, "checkout", "--detach", commit], check=True)
    actual = subprocess.check_output(
        ["git", "-C", destination, "rev-parse", "HEAD"], text=True
    ).strip()
    if actual != commit:
        raise SystemExit(f"{name}: checkout mismatch {actual} != {commit}")
    print(f"source ready: {name} {actual}")
PY
