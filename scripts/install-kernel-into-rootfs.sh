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
target_loader="$rootfs_dir/usr/lib/ld-linux-riscv64-lp64d.so.1"
compat_loader="$rootfs_dir/lib/ld-linux-riscv64-lp64d.so.1"
if [[ ! -f "$target_loader" ]]; then
    target_loader=$(find "$rootfs_dir/usr/lib" "$rootfs_dir/lib" \
        -type f -name 'ld-linux-riscv64*.so*' -print -quit 2>/dev/null || true)
fi
[[ -n "$target_loader" && -f "$target_loader" ]] \
    || die "riscv64 dynamic loader is missing from $rootfs_dir"
install -d -m 0755 "$rootfs_dir/lib"
if [[ ! -e "$compat_loader" ]]; then
    [[ ! -L "$compat_loader" ]] || rm -f "$compat_loader"
    compat_target=$(realpath --relative-to="$rootfs_dir/lib" "$target_loader")
    ln -s "$compat_target" "$compat_loader"
fi
[[ -e "$compat_loader" ]] || die "could not provide $compat_loader"
printf 'install-kernel: riscv64 loader %s -> %s\n' \
    "$target_loader" "$(readlink -f "$compat_loader")"

printf 'install-kernel: extracting %s\n' "${image_packages[0]}"
dpkg-deb --extract "${image_packages[0]}" "$rootfs_dir"
printf 'install-kernel: running depmod for %s\n' "$kernel_release"
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
# The rootfs loader prefix makes /lib in the target ELF interpreter resolve
# inside the chroot, independent of the host binfmt registration.
printf 'install-kernel: generating initrd for %s\n' "$kernel_release"
chroot "$rootfs_dir" /usr/bin/qemu-riscv64-static -L / /usr/bin/env -i \
    HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    LC_ALL=C DEBIAN_FRONTEND=noninteractive \
    /usr/sbin/mkinitramfs -o "/boot/initrd.img-$kernel_release" "$kernel_release"
[[ -s "$rootfs_dir/boot/initrd.img-$kernel_release" ]] \
    || die "mkinitramfs did not create a usable initrd"
printf 'kernel installed into rootfs: %s (%s)\n' "$board" "$kernel_release"
