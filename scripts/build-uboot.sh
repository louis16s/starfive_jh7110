#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

die() {
    echo "build-uboot: $*" >&2
    exit 1
}

[[ $# -eq 1 ]] || die "usage: $0 BOARD"
board=$1

# shellcheck source=/dev/null
source "$REPO_ROOT/board/$board/profile.conf"

uboot_source="$REPO_ROOT/$SOURCE_ROOT/$UBOOT_SOURCE"
output_dir="$REPO_ROOT/$OUTPUT_ROOT/$board/u-boot"
cross_compile=${CROSS_COMPILE:-riscv64-linux-gnu-}
jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}

[[ -d "$uboot_source" ]] || die "missing source; run make BOARD=$board fetch"
command -v "${cross_compile}gcc" >/dev/null 2>&1 || die "missing ${cross_compile}gcc"

if [[ "$board" == mars ]]; then
    grep -q 'jh7110-milkv-mars' "$uboot_source/configs/starfive_visionfive2_defconfig" \
        || die "Mars U-Boot source has no Mars DTB in CONFIG_OF_LIST"
fi

mkdir -p "$output_dir"
make -C "$uboot_source" O="$output_dir" ARCH=riscv CROSS_COMPILE="$cross_compile" "$UBOOT_DEFCONFIG"
make -C "$uboot_source" O="$output_dir" ARCH=riscv CROSS_COMPILE="$cross_compile" olddefconfig
make -C "$uboot_source" O="$output_dir" ARCH=riscv CROSS_COMPILE="$cross_compile" -j"$jobs" all
printf 'U-Boot build complete: %s\n' "$board"
