#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly REPO_ROOT

die() {
    echo "build-image: $*" >&2
    exit 1
}

[[ $# -eq 1 ]] || die "usage: $0 BOARD"
board=$1
[[ "$(id -u)" -eq 0 ]] || die "must run as root for loop devices and filesystem creation"

# shellcheck source=/dev/null
source "$REPO_ROOT/board/$board/profile.conf"

for command_name in truncate sfdisk losetup mkfs.vfat mkfs.ext4 mount umount blkid rsync install sed du; do
    command -v "$command_name" >/dev/null 2>&1 || die "missing command: $command_name"
done

readonly rootfs_dir="$REPO_ROOT/$OUTPUT_ROOT/$board/rootfs/rootfs"
readonly kernel_dir="$REPO_ROOT/$OUTPUT_ROOT/$board/kernel"
readonly image_dir="$REPO_ROOT/$OUTPUT_ROOT/$board/image"
readonly image_path="$image_dir/$IMAGE_BASENAME.img"
readonly template="$REPO_ROOT/board/$board/extlinux.conf.in"

[[ -d "$rootfs_dir" ]] || die "missing rootfs: run make BOARD=$board rootfs"
[[ -f "$kernel_dir/arch/riscv/boot/Image" ]] || die "missing kernel Image: run make BOARD=$board kernel"
[[ -f "$kernel_dir/arch/riscv/boot/dts/starfive/$KERNEL_DTB" ]] || die "missing board DTB"
[[ -f "$template" ]] || die "missing extlinux template"

# rootfs construction copies the host's qemu-riscv64-static into the target
# while it customizes it and removes it from an EXIT trap.  A build killed
# before that trap runs (CI job timeout, OOM kill) leaves the host binary
# behind, and it would otherwise be rsynced into the published riscv64 image.
# Neither the overlay nor the package lists ship any qemu binary, so its
# presence here is always a leak.
shopt -s nullglob
leaked_emulators=("$rootfs_dir"/usr/bin/qemu-*-static)
shopt -u nullglob
[[ ${#leaked_emulators[@]} -eq 0 ]] \
    || die "rootfs carries a host emulator binary: ${leaked_emulators[*]}"

shopt -s nullglob
initrds=("$rootfs_dir"/boot/initrd.img-*)
shopt -u nullglob
if [[ -n "${INITRD_PATH:-}" ]]; then
    initrds=("$INITRD_PATH")
fi
[[ ${#initrds[@]} -eq 1 && -f "${initrds[0]}" ]] || die "exactly one initrd is required; set INITRD_PATH or install a kernel package into the rootfs"

kernel_release_file="$kernel_dir/include/config/kernel.release"
[[ -s "$kernel_release_file" ]] || die "kernel release file is missing: $kernel_release_file"
kernel_release=$(<"$kernel_release_file")
mkdir -p "$image_dir"
[[ ! -e "$image_path" ]] || die "output exists: $image_path; remove it explicitly before rebuilding"
rootfs_used_mib=$(du -sm "$rootfs_dir" | awk '{print $1}')
minimum_image_mib=$((BOOT_SIZE_MIB + rootfs_used_mib + rootfs_used_mib / 10 + 512))
image_size_mib=$IMAGE_SIZE_MIB
if (( minimum_image_mib > image_size_mib )); then
    image_size_mib=$minimum_image_mib
fi
printf 'build-image: rootfs uses %s MiB; allocating %s MiB image\n' \
    "$rootfs_used_mib" "$image_size_mib"
truncate -s "$((image_size_mib * 1024 * 1024))" "$image_path"
sfdisk --label gpt "$image_path" <<EOF
label: gpt
first-lba: 2048
,${BOOT_SIZE_MIB}MiB,U,*
,,L
EOF

loop_device=$(losetup --find --show --partscan "$image_path")
boot_device="${loop_device}p1"
root_device="${loop_device}p2"
boot_mount=$(mktemp -d)
root_mount=$(mktemp -d)

cleanup() {
    set +e
    umount "$boot_mount" 2>/dev/null
    umount "$root_mount" 2>/dev/null
    losetup --detach "$loop_device" 2>/dev/null
    rmdir "$boot_mount" "$root_mount" 2>/dev/null
}
trap cleanup EXIT

for _ in {1..40}; do
    if [[ -b "$boot_device" && -b "$root_device" ]]; then
        break
    fi
    sleep 0.25
done
[[ -b "$boot_device" ]] || die "boot partition device did not appear: $boot_device"
[[ -b "$root_device" ]] || die "root partition device did not appear: $root_device"

mkfs.vfat -n "$BOOT_PARTITION_LABEL" "$boot_device"
mkfs.ext4 -L "$ROOT_PARTITION_LABEL" "$root_device"
mount "$boot_device" "$boot_mount"
mount "$root_device" "$root_mount"

rsync -a --exclude=/boot --exclude=/boot/ "$rootfs_dir/" "$root_mount/"
for alias in bin sbin lib; do
    [[ -L "$root_mount/$alias" && $(readlink "$root_mount/$alias") == "usr/$alias" ]] \
        || die "assembled image has broken merged-usr link: $alias"
done
[[ -s "$root_mount/lib/ld-linux-riscv64-lp64d.so.1" ]] \
    || die "assembled image is missing its runtime ELF interpreter"
install -d -m 0755 "$root_mount/boot"
install -d -m 0755 "$boot_mount/extlinux" "$boot_mount/dtbs/$kernel_release"
install -m 0644 "$kernel_dir/arch/riscv/boot/Image" "$boot_mount/Image-$kernel_release"
install -m 0644 "$kernel_dir/arch/riscv/boot/Image" "$boot_mount/Image"
install -m 0644 "${initrds[0]}" "$boot_mount/initrd.img-$kernel_release"
install -m 0644 "${initrds[0]}" "$boot_mount/initrd.img"
install -m 0644 "$kernel_dir/arch/riscv/boot/dts/starfive/$KERNEL_DTB" "$boot_mount/dtbs/$kernel_release/$KERNEL_DTB"

# blkid answers from udev's cache, which can lag behind the partition table
# sfdisk just wrote.  An empty PARTUUID used to be substituted straight into
# extlinux.conf and fstab, so the build reported success and produced an image
# that cannot find its root filesystem.
root_partuuid=
for _ in {1..40}; do
    root_partuuid=$(blkid -s PARTUUID -o value "$root_device" || true)
    [[ -n "$root_partuuid" ]] && break
    sleep 0.25
done
[[ -n "$root_partuuid" ]] || die "blkid returned no PARTUUID for $root_device"
sed \
    -e "s|@KERNEL_RELEASE@|$kernel_release|g" \
    -e "s|@KERNEL_DTB@|$KERNEL_DTB|g" \
    -e "s|@ROOT_PARTUUID@|$root_partuuid|g" \
    "$template" > "$boot_mount/extlinux/extlinux.conf"

# There is deliberately no "previous kernel" boot entry: every image is built
# from a fresh, empty boot partition (see the output-exists check above), so a
# stale Image.previous can never be present and printing such an entry would
# only produce a menu item that cannot boot.
cat > "$root_mount/etc/fstab" <<EOF
PARTUUID=$root_partuuid / ext4 defaults,noatime 0 1
LABEL=$BOOT_PARTITION_LABEL /boot vfat umask=0077 0 2
EOF
sync
printf 'image build complete: %s\n' "$image_path"
