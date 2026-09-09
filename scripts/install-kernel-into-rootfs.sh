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

for command_name in dpkg-deb depmod chroot; do
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

kernel_release_file="$kernel_dir/include/config/kernel.release"
[[ -s "$kernel_release_file" ]] || die "kernel release file is missing: $kernel_release_file"
kernel_release=$(<"$kernel_release_file")
dpkg-deb --extract "${image_packages[0]}" "$rootfs_dir"
depmod -b "$rootfs_dir" "$kernel_release"
install -d -m 0755 "$rootfs_dir/boot"
qemu_path=$(command -v qemu-riscv64-static) || die "missing qemu-riscv64-static"
cleanup() {
    rm -f "$rootfs_dir/usr/bin/qemu-riscv64-static"
}
trap cleanup EXIT
install -m 0755 "$qemu_path" "$rootfs_dir/usr/bin/qemu-riscv64-static"
# Invoke the target command through the copied static emulator explicitly.
# Debian Trixie stores the riscv64 loader in /usr/lib on merged-/usr systems,
# while the ELF interpreter name remains /lib/ld-linux-riscv64-lp64d.so.1.
# The /usr loader prefix keeps this invocation independent of host binfmt.
chroot "$rootfs_dir" /usr/bin/qemu-riscv64-static -L /usr /usr/bin/env -i \
    HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    LC_ALL=C DEBIAN_FRONTEND=noninteractive \
    /usr/sbin/mkinitramfs -o "/boot/initrd.img-$kernel_release" "$kernel_release"
printf 'kernel installed into rootfs: %s (%s)\n' "$board" "$kernel_release"
