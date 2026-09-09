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
kernel_make() {
    env -u BOARD -u BUILD_TYPE -u MAKEFLAGS -u MFLAGS -u MAKEOVERRIDES \
        make -C "$kernel_source" O="$output_dir" ARCH=riscv \
        CROSS_COMPILE="$cross_compile" "$@"
}

kernel_make "$KERNEL_DEFCONFIG"
kernel_make olddefconfig
kernel_make -j"$jobs" Image modules dtbs
kernel_make INSTALL_MOD_PATH="$output_dir/modules" modules_install

package_dir="$REPO_ROOT/$OUTPUT_ROOT/$board/packages"
package_output_root="$REPO_ROOT/$OUTPUT_ROOT/$board"
mkdir -p "$package_dir"
kernel_make KBUILD_DEBARCH=riscv64 KDEB_PKGVERSION="$KERNEL_PACKAGE_VERSION" \
    DPKG_FLAGS=-d \
    -j"$jobs" bindeb-pkg

shopt -s nullglob
deb_files=("$package_output_root"/*.deb)
package_metadata=("$package_output_root"/*.buildinfo "$package_output_root"/*.changes)
shopt -u nullglob
[[ ${#deb_files[@]} -gt 0 ]] || die "kernel build produced no Debian packages"
for deb_file in "${deb_files[@]}"; do
    install -m 0644 "$deb_file" "$package_dir/"
done
for metadata_file in "${package_metadata[@]}"; do
    install -m 0644 "$metadata_file" "$package_dir/"
done

dtb_path="$output_dir/arch/riscv/boot/dts/starfive/$KERNEL_DTB"
[[ -f "$dtb_path" ]] || die "kernel build did not produce $KERNEL_DTB"

kernel_release_file="$output_dir/include/config/kernel.release"
[[ -s "$kernel_release_file" ]] || die "kernel release file is missing: $kernel_release_file"
kernel_release=$(<"$kernel_release_file")
printf 'kernel build complete: %s (%s), packages: %s\n' "$board" "$kernel_release" "$package_dir"
