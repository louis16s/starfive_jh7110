#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly PROJECT_ROOT
readonly LOCK_FILE="$PROJECT_ROOT/sources.lock"
readonly COMMON_CONFIG="$PROJECT_ROOT/configs/common.conf"

[[ -f "$LOCK_FILE" ]] || { echo "missing $LOCK_FILE" >&2; exit 1; }
[[ -f "$COMMON_CONFIG" ]] || { echo "missing $COMMON_CONFIG" >&2; exit 1; }

python3 - "$LOCK_FILE" "$COMMON_CONFIG" <<'PY'
import re
import subprocess
import sys

try:
    import yaml
except ImportError as exc:
    raise SystemExit(f"PyYAML is required to verify sources.lock: {exc}")

lock_path, common_path = sys.argv[1:3]
with open(lock_path, encoding="utf-8") as handle:
    lock = yaml.safe_load(handle)

sources = lock.get("sources", {})
if not sources:
    raise SystemExit("sources.lock contains no sources")

failures = []

with open(common_path, encoding="utf-8") as handle:
    common_text = handle.read()


def read_common(name):
    """Return the value of NAME=... from configs/common.conf."""
    pattern = re.compile(rf"^{re.escape(name)}=(.*)$", re.MULTILINE)
    match = pattern.search(common_text)
    if not match:
        return None
    value = match.group(1).strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    return value


# The Debian snapshot is part of the reproducibility contract, and the build
# reads it from configs/common.conf rather than from this lock.  Nothing else
# compares the two, so a snapshot bump that forgets the lock silently produces
# an image the lock file does not describe.  This check is offline and exact,
# which is why it is a hard failure rather than a warning.
debian = lock.get("debian", {})
expected_debian = {
    "suite": read_common("DEBIAN_SUITE"),
    "version": read_common("DEBIAN_VERSION"),
    "archive_snapshot": read_common("DEBIAN_SNAPSHOT"),
    "security_snapshot": read_common("DEBIAN_SECURITY_SNAPSHOT"),
}
locked_debian = {
    "suite": debian.get("suite"),
    "version": debian.get("version"),
    "archive_snapshot": debian.get("archive_snapshot", {}).get("uri"),
    "security_snapshot": debian.get("security_snapshot", {}).get("uri"),
}
for field, value in expected_debian.items():
    if value is None:
        continue
    # YAML turns a bare 13.6 into a float, so compare the rendered forms.
    locked_value = locked_debian.get(field)
    if locked_value is None or str(locked_value) != value:
        failures.append(
            f"debian.{field}: sources.lock has {locked_value!r} "
            f"but configs/common.conf has {value!r}"
        )

for name, entry in sources.items():
    url = entry.get("url", "")
    expected = entry.get("commit")
    ref = entry.get("ref")
    if "/blob/" in url or not ref:
        print(f"SKIP {name}: non-Git artifact or documentation URL")
        continue
    if not expected or not re.fullmatch(r"[0-9a-f]{40}", expected):
        failures.append(f"{name}: commit must be a full 40-character lowercase SHA")
        continue

    candidates = [f"refs/heads/{ref}", f"refs/tags/{ref}", f"refs/tags/{ref}^{{}}"]
    try:
        result = subprocess.run(
            ["git", "ls-remote", url, *candidates],
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.CalledProcessError as exc:
        failures.append(
            f"{name}: cannot reach {url} ({exc.stderr.strip() or exc.returncode})"
        )
        continue
    except OSError as exc:
        failures.append(f"{name}: cannot run git ls-remote ({exc})")
        continue

    resolved = None
    for line in result.stdout.splitlines():
        sha, remote_ref = line.split("\t", 1)
        if remote_ref.endswith("^{}"):
            resolved = sha
            break
        if resolved is None:
            resolved = sha
    if resolved == expected:
        print(f"LOCK OK {name}: {expected}")
    elif resolved:
        # Expected drift: several entries pin a moving branch such as master.
        # The pinned commit, not the ref, is what the build fetches, and
        # fetch-sources.sh re-checks it after checkout.
        print(
            f"LOCK WARN {name}: {ref} moved from {expected} to {resolved}; "
            "the pinned commit remains authoritative"
        )
    else:
        print(
            f"LOCK WARN {name}: {ref} is not advertised by the remote; "
            "the pinned commit will be checked during fetch"
        )

if failures:
    raise SystemExit("source lock verification failed:\n  " + "\n  ".join(failures))
PY
