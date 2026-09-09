#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

die() {
    echo "install-kernel-into-rootfs: $*" >&2
    exit 1
}

[[ $# -eq 1 ]] || die "usage: $0 BOARD"
board=$1

# shellcheck source=/dev/null
source "$REPO_ROOT/board/$board/profile.conf"

for command_name in dpkg-deb depmod make chroot; do
    command -v "$command_name" >/dev/null 2>&1 || die "missing command: $command_name"
done

readonly rootfs_dir="$REPO_ROOT/$OUTPUT_ROOT/$board/rootfs/rootfs"
readonly kernel_dir="$REPO_ROOT/$OUTPUT_ROOT/$board/kernel"
readonly package_dir="$REPO_ROOT/$OUTPUT_ROOT/$board/packages"
readonly kernel_source="$REPO_ROOT/$SOURCE_ROOT/$KERNEL_SOURCE"

[[ -d "$rootfs_dir" ]] || die "missing rootfs: run make BOARD=$board rootfs"
[[ -d "$kernel_source" ]] || die "missing kernel source: run make BOARD=$board fetch"

shopt -s nullglob
image_packages=("$package_dir"/linux-image-*.deb)
shopt -u nullglob
[[ ${#image_packages[@]} -eq 1 ]] || die "expected exactly one linux-image package in $package_dir"

kernel_release=$(make -s -C "$kernel_source" O="$kernel_dir" ARCH=riscv \
    CROSS_COMPILE="${CROSS_COMPILE:-riscv64-linux-gnu-}" kernelrelease)
dpkg-deb --extract "${image_packages[0]}" "$rootfs_dir"
depmod -b "$rootfs_dir" "$kernel_release"
install -d -m 0755 "$rootfs_dir/boot"
qemu_path=$(command -v qemu-riscv64-static) || die "missing qemu-riscv64-static"
cleanup() {
    rm -f "$rootfs_dir/usr/bin/qemu-riscv64-static"
}
trap cleanup EXIT
install -m 0755 "$qemu_path" "$rootfs_dir/usr/bin/qemu-riscv64-static"
chroot "$rootfs_dir" /usr/bin/env -i \
    HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    LC_ALL=C DEBIAN_FRONTEND=noninteractive \
    /usr/sbin/mkinitramfs -o "/boot/initrd.img-$kernel_release" "$kernel_release"
printf 'kernel installed into rootfs: %s (%s)\n' "$board" "$kernel_release"
