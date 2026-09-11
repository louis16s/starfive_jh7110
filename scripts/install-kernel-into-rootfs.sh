#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly REPO_ROOT

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
printf 'install-kernel: riscv64 loader %s -> %s\n' \
    "$target_loader" "pending merged-usr repair"

printf 'install-kernel: extracting %s\n' "${image_packages[0]}"
kernel_payload=$(mktemp -d "$package_dir/.kernel-payload.XXXXXX")
trap 'rm -rf "$kernel_payload"' EXIT
dpkg-deb --extract "${image_packages[0]}" "$kernel_payload"
bash "$REPO_ROOT/scripts/merge-kernel-payload.sh" "$kernel_payload" "$rootfs_dir"
if [[ ! -e "$compat_loader" ]]; then
    compat_target=$(realpath --relative-to="$rootfs_dir/lib" "$target_loader")
    ln -s "$compat_target" "$compat_loader"
fi
[[ -e "$compat_loader" ]] || die "could not provide $compat_loader"
[[ -L "$rootfs_dir/lib" && -e "$compat_loader" ]] \
    || die "kernel extraction broke merged-usr or the ELF interpreter"
printf 'install-kernel: running depmod for %s\n' "$kernel_release"
depmod -b "$rootfs_dir" "$kernel_release"
install -d -m 0755 "$rootfs_dir/boot"
# Debian's qemu binfmt wrapper uses /etc/qemu-binfmt/<arch> as its ELF
# interpreter prefix. That prefix is host-specific, so provide the equivalent
# target-root mapping temporarily while mkinitramfs launches target helpers
# such as ldconfig. Without it, GitHub's Ubuntu runner reports that
# /lib/ld-linux-riscv64-lp64d.so.1 cannot be opened from nested target execs.
qemu_path=$(command -v qemu-riscv64-static) || die "missing qemu-riscv64-static"
qemu_target="$rootfs_dir/usr/bin/qemu-riscv64-static"
qemu_binfmt_dir="$rootfs_dir/etc/qemu-binfmt"
qemu_binfmt_link="$qemu_binfmt_dir/riscv64"
qemu_binfmt_link_created=0
cleanup_qemu() {
    rm -rf "$kernel_payload"
    rm -f "$qemu_target"
    if [[ "$qemu_binfmt_link_created" -eq 1 ]]; then
        rm -f "$qemu_binfmt_link"
        rmdir --ignore-fail-on-non-empty "$qemu_binfmt_dir"
    fi
}
trap cleanup_qemu EXIT
install -m 0755 "$qemu_path" "$qemu_target"
if [[ ! -e "$qemu_binfmt_link" && ! -L "$qemu_binfmt_link" ]]; then
    install -d -m 0755 "$qemu_binfmt_dir"
    ln -s /usr "$qemu_binfmt_link"
    qemu_binfmt_link_created=1
fi
[[ -e "$qemu_binfmt_link" ]] || die "could not provide $qemu_binfmt_link"
# Exercise the actual runtime /lib interpreter path. The /usr QEMU prefix
# used by mkinitramfs below can otherwise conceal a broken target /lib.
chroot "$rootfs_dir" /usr/bin/qemu-riscv64-static -L / /bin/true
chroot "$rootfs_dir" /usr/bin/qemu-riscv64-static -L / /sbin/init --version
printf 'install-kernel: generating initrd for %s\n' "$kernel_release"
chroot "$rootfs_dir" /usr/bin/qemu-riscv64-static -L /usr /usr/bin/env -i \
    HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    LC_ALL=C DEBIAN_FRONTEND=noninteractive QEMU_LD_PREFIX=/usr \
    /usr/sbin/mkinitramfs -o "/boot/initrd.img-$kernel_release" "$kernel_release"
[[ -s "$rootfs_dir/boot/initrd.img-$kernel_release" ]] \
    || die "mkinitramfs did not create a usable initrd"
printf 'kernel installed into rootfs: %s (%s)\n' "$board" "$kernel_release"
