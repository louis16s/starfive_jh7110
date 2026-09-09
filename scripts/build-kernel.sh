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

package_dir="$REPO_ROOT/$OUTPUT_ROOT/$board/packages"
mkdir -p "$package_dir"
make -C "$kernel_source" O="$output_dir" ARCH=riscv CROSS_COMPILE="$cross_compile" \
    KBUILD_DEBARCH=riscv64 KDEB_PKGVERSION="$KERNEL_PACKAGE_VERSION" \
    -j"$jobs" bindeb-pkg

shopt -s nullglob
deb_files=("$kernel_source"/*.deb "$output_dir"/*.deb "$REPO_ROOT"/*.deb)
shopt -u nullglob
[[ ${#deb_files[@]} -gt 0 ]] || die "kernel build produced no Debian packages"
for deb_file in "${deb_files[@]}"; do
    install -m 0644 "$deb_file" "$package_dir/"
done

dtb_path="$output_dir/arch/riscv/boot/dts/starfive/$KERNEL_DTB"
[[ -f "$dtb_path" ]] || die "kernel build did not produce $KERNEL_DTB"

kernel_release=$(make -s -C "$kernel_source" O="$output_dir" ARCH=riscv CROSS_COMPILE="$cross_compile" kernelrelease)
printf 'kernel build complete: %s (%s), packages: %s\n' "$board" "$kernel_release" "$package_dir"
