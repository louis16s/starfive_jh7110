#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly MATRIX_FILE="$REPO_ROOT/configs/hardware-matrix.yaml"

die() {
    echo "validate-profile: $*" >&2
    exit 1
}

[[ $# -eq 1 ]] || die "usage: $0 BOARD"
board=$1
[[ "$board" == visionfive2 || "$board" == mars ]] || die "unsupported board: $board"

profile="$REPO_ROOT/board/$board/profile.conf"
[[ -f "$profile" ]] || die "missing profile: $profile"
[[ -f "$MATRIX_FILE" ]] || die "missing capability matrix: $MATRIX_FILE"

# shellcheck source=/dev/null
source "$profile"

[[ "${BOARD_ID:-}" == "$board" ]] || die "profile BOARD_ID mismatch"
[[ -n "${KERNEL_DTB:-}" ]] || die "KERNEL_DTB is empty"
[[ -n "${KERNEL_DTB_COMPATIBLE:-}" ]] || die "KERNEL_DTB_COMPATIBLE is empty"
[[ -n "${UBOOT_DEFCONFIG:-}" ]] || die "UBOOT_DEFCONFIG is empty"
[[ -n "${UBOOT_VARIANT:-}" ]] || die "UBOOT_VARIANT is empty"
[[ -n "${KERNEL_SOURCE:-}" ]] || die "KERNEL_SOURCE is empty"
[[ -n "${KERNEL_DEFCONFIG:-}" ]] || die "KERNEL_DEFCONFIG is empty"
[[ -n "${UBOOT_SOURCE:-}" ]] || die "UBOOT_SOURCE is empty"
[[ -n "${OPENSBI_SOURCE:-}" ]] || die "OPENSBI_SOURCE is empty"
[[ -n "${TIMEZONE:-}" ]] || die "TIMEZONE is empty"
if [[ "$board" == mars && "${MARS_DTB_ALLOWED:-0}" != 1 ]]; then
    die "Mars board separation flag is invalid"
fi
if [[ "$board" == visionfive2 && "${MARS_DTB_ALLOWED:-1}" != 0 ]]; then
    die "VisionFive 2 board separation flag is invalid"
fi

if [[ "$board" == mars && "$KERNEL_DTB" != jh7110-milkv-mars.dtb ]]; then
    die "Mars must use its own DTB"
fi
if [[ "$board" == visionfive2 && "$KERNEL_DTB" == jh7110-milkv-mars.dtb ]]; then
    die "VisionFive 2 cannot use the Mars DTB"
fi

python3 - "$MATRIX_FILE" "$board" "$KERNEL_DTB" <<'PY'
import sys

try:
    import yaml
except ImportError as exc:
    raise SystemExit(f"PyYAML is required to validate hardware-matrix.yaml: {exc}")

matrix_path, board, expected_dtb = sys.argv[1:]
with open(matrix_path, encoding="utf-8") as handle:
    data = yaml.safe_load(handle)

entry = data.get(board)
if not isinstance(entry, dict):
    raise SystemExit(f"missing board entry: {board}")
if entry.get("dtb") != expected_dtb:
    raise SystemExit(f"matrix DTB mismatch: {entry.get('dtb')} != {expected_dtb}")
capabilities = entry.get("capabilities")
if not isinstance(capabilities, dict) or not capabilities:
    raise SystemExit(f"missing capabilities for {board}")
for name, value in capabilities.items():
    if not isinstance(value, dict) or value.get("status") not in {"target", "bsp-required", "skip", "warn"}:
        raise SystemExit(f"invalid capability status: {board}.{name}")
print(f"profile OK: {board} ({len(capabilities)} capabilities)")
PY
