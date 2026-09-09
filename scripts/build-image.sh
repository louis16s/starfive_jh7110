#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

die() {
    echo "build-image: $*" >&2
    exit 1
}

[[ $# -eq 1 ]] || die "usage: $0 BOARD"
board=$1
[[ "$(id -u)" -eq 0 ]] || die "must run as root for loop devices and filesystem creation"

# shellcheck source=/dev/null
source "$REPO_ROOT/board/$board/profile.conf"

for command_name in truncate sfdisk losetup mkfs.vfat mkfs.ext4 mount umount blkid rsync install sed; do
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

shopt -s nullglob
initrds=("$rootfs_dir"/boot/initrd.img-*)
shopt -u nullglob
if [[ -n "${INITRD_PATH:-}" ]]; then
    initrds=("$INITRD_PATH")
fi
[[ ${#initrds[@]} -eq 1 && -f "${initrds[0]}" ]] || die "exactly one initrd is required; set INITRD_PATH or install a kernel package into the rootfs"

kernel_release=$(make -s -C "$REPO_ROOT/$SOURCE_ROOT/$KERNEL_SOURCE" O="$kernel_dir" ARCH=riscv CROSS_COMPILE="${CROSS_COMPILE:-riscv64-linux-gnu-}" kernelrelease)
mkdir -p "$image_dir"
[[ ! -e "$image_path" ]] || die "output exists: $image_path; remove it explicitly before rebuilding"
truncate -s "$((IMAGE_SIZE_MIB * 1024 * 1024))" "$image_path"
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

mkfs.vfat -n "$BOOT_PARTITION_LABEL" "$boot_device"
mkfs.ext4 -L "$ROOT_PARTITION_LABEL" "$root_device"
mount "$boot_device" "$boot_mount"
mount "$root_device" "$root_mount"

rsync -a --exclude=/boot --exclude=/boot/ "$rootfs_dir/" "$root_mount/"
install -d -m 0755 "$boot_mount/extlinux" "$boot_mount/dtbs/$kernel_release"
install -m 0644 "$kernel_dir/arch/riscv/boot/Image" "$boot_mount/Image-$kernel_release"
ln -s "Image-$kernel_release" "$boot_mount/Image"
install -m 0644 "${initrds[0]}" "$boot_mount/initrd.img-$kernel_release"
ln -s "initrd.img-$kernel_release" "$boot_mount/initrd.img"
install -m 0644 "$kernel_dir/arch/riscv/boot/dts/starfive/$KERNEL_DTB" "$boot_mount/dtbs/$kernel_release/$KERNEL_DTB"

root_partuuid=$(blkid -s PARTUUID -o value "$root_device")
sed \
    -e "s|@KERNEL_RELEASE@|$kernel_release|g" \
    -e "s|@KERNEL_DTB@|$KERNEL_DTB|g" \
    -e "s|@ROOT_PARTUUID@|$root_partuuid|g" \
    "$template" > "$boot_mount/extlinux/extlinux.conf"

if [[ -f "$boot_mount/Image.previous" && -f "$boot_mount/initrd.img.previous" ]]; then
    cat >> "$boot_mount/extlinux/extlinux.conf" <<EOF

LABEL previous
    MENU LABEL Debian GNU/Linux - Previous Kernel
    LINUX /Image.previous
    INITRD /initrd.img.previous
    FDT /dtbs/$kernel_release/$KERNEL_DTB
    APPEND root=PARTUUID=$root_partuuid rw rootwait console=ttyS0,115200 earlycon=sbi
EOF
fi

cat > "$root_mount/etc/fstab" <<EOF
PARTUUID=$root_partuuid / ext4 defaults,noatime 0 1
LABEL=$BOOT_PARTITION_LABEL /boot vfat umask=0077 0 2
EOF
sync
printf 'image build complete: %s\n' "$image_path"
