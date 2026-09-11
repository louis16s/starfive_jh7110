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

if [[ "$board" == mars ]]; then
    grep -q 'jh7110-milkv-mars' "$uboot_source/configs/starfive_visionfive2_defconfig" \
        || die "Mars U-Boot source has no Mars DTB in CONFIG_OF_LIST"
fi

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
uboot_make -j"$jobs" all
printf 'U-Boot build complete: %s\n' "$board"
