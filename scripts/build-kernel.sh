#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

die() {
    echo "build-kernel: $*" >&2
    exit 1
}

[[ $# -eq 1 ]] || die "usage: $0 BOARD"
board=$1

# shellcheck source=/dev/null
source "$REPO_ROOT/board/$board/profile.conf"

kernel_source="$REPO_ROOT/$SOURCE_ROOT/$KERNEL_SOURCE"
output_dir="$REPO_ROOT/$OUTPUT_ROOT/$board/kernel"
cross_compile=${CROSS_COMPILE:-riscv64-linux-gnu-}
jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}

[[ -d "$kernel_source" ]] || die "missing source; run make BOARD=$board fetch"
command -v "${cross_compile}gcc" >/dev/null 2>&1 || die "missing ${cross_compile}gcc"
command -v make >/dev/null 2>&1 || die "missing make"

mkdir -p "$output_dir"
make -C "$kernel_source" O="$output_dir" ARCH=riscv CROSS_COMPILE="$cross_compile" "$KERNEL_DEFCONFIG"
make -C "$kernel_source" O="$output_dir" ARCH=riscv CROSS_COMPILE="$cross_compile" olddefconfig
make -C "$kernel_source" O="$output_dir" ARCH=riscv CROSS_COMPILE="$cross_compile" -j"$jobs" Image modules dtbs
make -C "$kernel_source" O="$output_dir" ARCH=riscv CROSS_COMPILE="$cross_compile" \
    INSTALL_MOD_PATH="$output_dir/modules" modules_install

kernel_release=$(make -s -C "$kernel_source" O="$output_dir" ARCH=riscv CROSS_COMPILE="$cross_compile" kernelrelease)
printf 'kernel build complete: %s (%s)\n' "$board" "$kernel_release"
