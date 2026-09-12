#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly REPO_ROOT
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

# The release asset and image name must identify their own board: both board
# trees share OUTPUT_ROOT=build and the CI release step publishes
# jh7110-<board>-<basename>, so a copy-pasted layout.conf would silently
# overwrite the other board's download.
if [[ "$board" == mars ]]; then
    board_image_token=mars
else
    board_image_token=vf2
fi

# Every name below is consumed by at least one build script.  An empty or
# mistyped value surfaces late - after a multi-hour kernel build - or, for the
# partition labels, only when mkfs rejects them mid-image.
for required in \
    PROJECT_NAME BOARD_NAME BOARD_VENDOR TARGET_ARCH \
    SOURCE_LOCK SOURCE_ROOT OUTPUT_ROOT \
    BOOT_FILESYSTEM ROOT_FILESYSTEM DEFAULT_USER \
    IMAGE_BASENAME BOOT_PARTITION_LABEL ROOT_PARTITION_LABEL \
    KERNEL_PACKAGE_VERSION ROOT_DEVICE_POLICY NVME_POLICY EMMC_POLICY; do
    [[ -n "${!required:-}" ]] || die "$required is empty"
done

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
[[ -n "${DEFAULT_LOCALE:-}" ]] || die "DEFAULT_LOCALE is empty"
[[ -n "${DEFAULT_LANGUAGE:-}" ]] || die "DEFAULT_LANGUAGE is empty"
[[ -n "${SUPPORTED_LOCALES:-}" ]] || die "SUPPORTED_LOCALES is empty"
[[ " $SUPPORTED_LOCALES " == *' en_US.UTF-8 '* ]] \
    || die "SUPPORTED_LOCALES must include en_US.UTF-8"
[[ " $SUPPORTED_LOCALES " == *' zh_CN.UTF-8 '* ]] \
    || die "SUPPORTED_LOCALES must include zh_CN.UTF-8"
[[ "$DEFAULT_LOCALE" == zh_CN.UTF-8 ]] || die "default locale must be zh_CN.UTF-8"
timezone_offset=$(TZ="$TIMEZONE" date +%z)
[[ "$timezone_offset" == +0800 ]] || die "timezone must resolve to UTC+8: $TIMEZONE ($timezone_offset)"
[[ "${ROOT_PARTITION_NUMBER:-}" == 2 ]] || die "root partition must be partition 2"
[[ "${BOOTLOADER_MEDIA:-}" == spi-nor ]] || die "unsupported bootloader media"
[[ "$TARGET_ARCH" == riscv64 ]] || die "unsupported target architecture: $TARGET_ARCH"
# build-image.sh calls mkfs.vfat and mkfs.ext4 unconditionally.
[[ "$BOOT_FILESYSTEM" == vfat ]] || die "boot filesystem must be vfat"
[[ "$ROOT_FILESYSTEM" == ext4 ]] || die "root filesystem must be ext4"
if [[ "$board" == mars && "${MARS_DTB_ALLOWED:-0}" != 1 ]]; then
    die "Mars board separation flag is invalid"
fi
if [[ "$board" == visionfive2 && "${MARS_DTB_ALLOWED:-1}" != 0 ]]; then
    die "VisionFive 2 board separation flag is invalid"
fi

for numeric in IMAGE_SIZE_MIB BOOT_SIZE_MIB; do
    numeric_value=${!numeric:-}
    [[ "$numeric_value" =~ ^[0-9]+$ ]] \
        || die "$numeric must be a whole number of MiB: $numeric_value"
    (( numeric_value > 0 )) || die "$numeric must be greater than zero"
done
(( IMAGE_SIZE_MIB >= BOOT_SIZE_MIB )) \
    || die "IMAGE_SIZE_MIB ($IMAGE_SIZE_MIB) is smaller than BOOT_SIZE_MIB ($BOOT_SIZE_MIB)"

# mkfs.vfat silently truncates a longer label and mkfs.ext4 rejects one, both
# of which abort image assembly long after the kernel has been built.
[[ "$BOOT_PARTITION_LABEL" =~ ^[A-Z0-9_]{1,11}$ ]] \
    || die "BOOT_PARTITION_LABEL must be 1-11 upper-case characters: $BOOT_PARTITION_LABEL"
[[ "$ROOT_PARTITION_LABEL" =~ ^[A-Za-z0-9_-]{1,16}$ ]] \
    || die "ROOT_PARTITION_LABEL must be 1-16 characters: $ROOT_PARTITION_LABEL"
[[ "$BOOT_PARTITION_LABEL" != "$ROOT_PARTITION_LABEL" ]] \
    || die "boot and root partition labels must differ"

# The image is published as <IMAGE_BASENAME>.img, so it has to be a portable
# file name that identifies its own board.
[[ "$IMAGE_BASENAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || die "IMAGE_BASENAME is not a portable file name: $IMAGE_BASENAME"
[[ "$IMAGE_BASENAME" == *"$board_image_token"* ]] \
    || die "IMAGE_BASENAME must contain '$board_image_token': $IMAGE_BASENAME"

for policy_name in ROOT_DEVICE_POLICY NVME_POLICY EMMC_POLICY; do
    case ${!policy_name} in
        uuid|required|capable|skip) ;;
        *) die "$policy_name has an unknown value: ${!policy_name}" ;;
    esac
done

# Debian version string: used verbatim in the kernel package name.
[[ "$KERNEL_PACKAGE_VERSION" =~ ^[0-9][A-Za-z0-9.+:~-]*$ ]] \
    || die "KERNEL_PACKAGE_VERSION is not a valid Debian version: $KERNEL_PACKAGE_VERSION"

# The device tree file has to match the compatible string the FIT is checked
# against, otherwise a board can be built, flashed and never booted.
[[ "$KERNEL_DTB" == *.dtb ]] || die "KERNEL_DTB must name a .dtb file: $KERNEL_DTB"
dtb_from_compatible="jh7110-${KERNEL_DTB_COMPATIBLE/,/-}.dtb"
[[ "$KERNEL_DTB" == "$dtb_from_compatible" ]] \
    || die "KERNEL_DTB ($KERNEL_DTB) does not correspond to KERNEL_DTB_COMPATIBLE ($KERNEL_DTB_COMPATIBLE); expected $dtb_from_compatible"
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
