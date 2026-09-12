#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly REPO_ROOT

die() {
    echo "build-uboot: $*" >&2
    exit 1
}

[[ $# -eq 1 ]] || die "usage: $0 BOARD"
board=$1
# GNU make exports command-line variables. Do not let the project-level
# BOARD=mars override U-Boot's Kconfig-generated BOARD=visionfive2 value.
unset BOARD

# shellcheck source=/dev/null
source "$REPO_ROOT/board/$board/profile.conf"

uboot_source="$REPO_ROOT/$SOURCE_ROOT/$UBOOT_SOURCE"
output_dir="$REPO_ROOT/$OUTPUT_ROOT/$board/u-boot"
opensbi_image="$REPO_ROOT/$OUTPUT_ROOT/$board/opensbi/platform/generic/firmware/fw_dynamic.bin"
cross_compile=${CROSS_COMPILE:-riscv64-linux-gnu-}
jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}

[[ -d "$uboot_source" ]] || die "missing source; run make BOARD=$board fetch"
[[ -f "$opensbi_image" ]] || die "missing OpenSBI image: run make BOARD=$board opensbi"
command -v "${cross_compile}gcc" >/dev/null 2>&1 || die "missing ${cross_compile}gcc"
compiler="${cross_compile}gcc"
if [[ "${USE_CCACHE:-0}" == 1 ]]; then
    command -v ccache >/dev/null 2>&1 || die "USE_CCACHE=1 requires ccache"
    compiler="ccache $compiler"
fi

# The board DTB is chosen by the generated configuration, not by the defconfig
# file on disk: `olddefconfig` can change CONFIG_OF_LIST/CONFIG_DEFAULT_DEVICE_TREE
# and only .config feeds the binman FIT (`fit,fdt-list = "of-list"`).  A board
# whose DTB never reached .config would still produce a payload that flashes
# cleanly and cannot boot that board.  Checked below, after olddefconfig.
board_dtb_token=${KERNEL_DTB%.dtb}
[[ -n "$board_dtb_token" ]] || die "board profile does not set KERNEL_DTB: $board"

mkdir -p "$output_dir"
# The outer project invokes this script through `make BOARD=...`. GNU make
# propagates command-line variables through MAKEFLAGS/MAKEOVERRIDES even after
# the shell variable has been unset, which makes U-Boot see BOARD=mars and
# skips the Kconfig-selected board objects. Keep the U-Boot make environment
# isolated from project-level make variables.
uboot_make() {
    env -u BOARD -u MAKEFLAGS -u MFLAGS -u MAKEOVERRIDES \
        make -C "$uboot_source" O="$output_dir" ARCH=riscv \
        CROSS_COMPILE="$cross_compile" CC="$compiler" OPENSBI="$opensbi_image" "$@"
}

uboot_make "$UBOOT_DEFCONFIG"
uboot_make olddefconfig
grep -q -- "$board_dtb_token" "$output_dir/.config" \
    || die "$board_dtb_token is missing from the generated U-Boot configuration"
uboot_make -j"$jobs" all

# JH7110 SPL loads the second stage as a FIT image containing OpenSBI and
# U-Boot proper.  u-boot.img is the legacy mkimage output and is not the
# SPI-NOR payload for this board; flashing it leaves SPL waiting at
# "Trying to boot from SPI".  Fail here instead of publishing a bootable-
# looking but unusable artifact.  The matching SPL has to be in the StarFive
# "normal.out" container, which is what the QSPI boot ROM expects; both files
# are binman outputs of the same build and are published as a pair.
payload="$output_dir/u-boot.itb"
[[ -s "$payload" ]] || die "missing JH7110 FIT payload: $payload"
spl_payload="$output_dir/spl/u-boot-spl.bin.normal.out"
[[ -s "$spl_payload" ]] || die "missing JH7110 SPI SPL payload: $spl_payload"

dumpimage_tool="$output_dir/tools/dumpimage"
if [[ -x "$dumpimage_tool" ]] || command -v dumpimage >/dev/null 2>&1; then
    [[ -x "$dumpimage_tool" ]] || dumpimage_tool=dumpimage
    "$dumpimage_tool" -l "$payload" >/dev/null 2>&1 \
        || die "invalid JH7110 FIT payload: $payload"
fi

# The FIT carries every DTB from CONFIG_OF_LIST, so a wrong board would still
# validate as a FIT.  Prove this board's own DTB is inside it by matching the
# NUL-terminated compatible string of the board profile; matching a bare
# "milkv,mars" would also hit "milkv,marscm-emmc".
python3 - "$payload" "$KERNEL_DTB_COMPATIBLE" <<'PY' \
    || die "FIT payload has no $KERNEL_DTB_COMPATIBLE DTB: $payload"
import sys

payload, compatible = sys.argv[1:3]
with open(payload, "rb") as handle:
    blob = handle.read()
sys.exit(0 if compatible.encode() + b"\0" in blob else 1)
PY

printf 'U-Boot build complete: %s\n' "$board"
