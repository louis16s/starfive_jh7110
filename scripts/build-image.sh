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
# shellcheck source=lib/build-timestamps.sh
source "$REPO_ROOT/scripts/lib/build-timestamps.sh"

# An image is not just the files that went into it: the partition table and both
# filesystems carry identifiers and times of their own, and sfdisk, mkfs.fat and
# mkfs.ext4 take those from the clock and from /dev/urandom.  Two builds of one
# commit therefore differed in every PARTUUID the image ships - the ones its
# extlinux.conf and /etc/fstab point at - as well as in the filesystem UUID and
# hash seed.  The identifiers are derived below and the times are pinned here.
pin_build_timestamps
# mke2fs and debugfs take the fake time from their own variable, falling back to
# SOURCE_DATE_EPOCH; with either set, even the flush debugfs performs when it
# closes a filesystem stamps the epoch instead of the moment it ran.
export E2FSPROGS_FAKE_TIME="$SOURCE_DATE_EPOCH"

for command_name in truncate sfdisk losetup mkfs.vfat mkfs.ext4 mount umount blkid rsync install sed du python3 debugfs dumpe2fs e2fsck fsck.fat tune2fs; do
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

# Every identifier the finished image is addressed by comes from here, and a
# board has to keep the same ones across builds: the root PARTUUID is what
# extlinux.conf and /etc/fstab name, and the filesystem UUID and hash seed are
# what the ext4 metadata and directory checksums are derived from.
image_identifiers=$(python3 - "$board" <<'PY'  # image-identifiers
import sys
import uuid

# A host that never resolves - RFC 2606 reserves .invalid - because the string
# only has to be stable and unique to this project: uuid5 turns it into one
# identifier per board and role.  Nothing about the build machine, the clock or
# the checkout path enters, so two builders derive the same values, and the two
# boards never share one.
board = sys.argv[1]


def identifier(role):
    return uuid.uuid5(uuid.NAMESPACE_URL,
                      f'https://jh7110-desktop.invalid/{board}/{role}')


# The FAT volume serial is a 32-bit value rather than a UUID.
print(identifier('disk'), identifier('esp'), identifier('root'),
      identifier('rootfs'), identifier('hash-seed'),
      identifier('esp-serial').hex[:8])
PY
)
read -r disk_guid esp_guid root_guid rootfs_uuid hash_seed esp_serial <<<"$image_identifiers"
uuid_pattern='^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
for identifier in "$disk_guid" "$esp_guid" "$root_guid" "$rootfs_uuid" "$hash_seed"; do
    [[ "$identifier" =~ $uuid_pattern ]] \
        || die "derived identifier is not a version 5 UUID: '$identifier'"
done
[[ "$esp_serial" =~ ^[0-9a-f]{8}$ ]] \
    || die "derived volume serial is not eight hex digits: '$esp_serial'"
printf 'build-image: disk=%s esp=%s root=%s rootfs=%s serial=%s\n' \
    "$disk_guid" "$esp_guid" "$root_guid" "$rootfs_uuid" "$esp_serial"

# The fields are named rather than positional: sfdisk reads the fourth
# positional field as the boot flag, so a uuid written there is a parse error,
# and every slot it fills in itself comes out with a GUID generated for that run.
sfdisk --label gpt "$image_path" <<EOF
label: gpt
label-id: $disk_guid
first-lba: 2048
size=${BOOT_SIZE_MIB}MiB, type=U, uuid=$esp_guid, bootable
size=, type=L, uuid=$root_guid
EOF

loop_device=$(losetup --find --show --partscan "$image_path")
boot_device="${loop_device}p1"
root_device="${loop_device}p2"
boot_mount=$(mktemp -d)
root_mount=$(mktemp -d)
# The inode pass is driven by a command stream that is far too long to hold
# anywhere but a file, and its read-back needs the list of inodes it stamped.
# Both are named here so the trap can remove them if a later step fails.
inode_commands=
inode_offsets=

cleanup() {
    set +e
    [[ -n "$inode_commands" ]] && rm -f "$inode_commands"
    [[ -n "$inode_offsets" ]] && rm -f "$inode_offsets"
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

# -i pins the volume serial, and --invariant stops mkfs.fat from taking the
# times it writes into the label entry from the clock: the final pass stamps
# every entry including that one, which makes this the second line of defence
# rather than the first.
mkfs.vfat --invariant -i "$esp_serial" -n "$BOOT_PARTITION_LABEL" "$boot_device"
# The filesystem UUID and the directory hash seed are pinned together: they are
# what the metadata and htree checksums are derived from, so a filesystem with
# one of them left to mkfs.ext4 still differs from its twin in several hundred
# bytes even when it holds exactly the same files.
#
# It is built without a journal, and the journal is created once the rootfs has
# been copied in.  Populating a journaled filesystem fills the journal's ring
# buffer with the transactions the mount committed - whole inode table blocks
# and superblock blocks, carrying the wall clock of the run - and jbd2 does not
# clear that area when it unmounts cleanly: it writes s_start = 0 into the
# journal superblock and leaves the transactions behind.  Every pass below
# reads inode tables, the superblock and its copies, and none of them reaches
# the journal, so the two builds would ship different bytes in a region no
# check looks at.
mkfs.ext4 -L "$ROOT_PARTITION_LABEL" -U "$rootfs_uuid" \
    -E hash_seed="$hash_seed" -O ^has_journal "$root_device"

# Reading the identifiers back is what says whether the three tools honoured
# them: extlinux.conf, fstab and the firmware's view of the boot partition all
# depend on these answers.  blkid -p probes the device, because the cache blkid
# normally answers from lags behind a device that was just written.
boot_label=$(blkid -p -s LABEL -o value "$boot_device" || true)
[[ "${boot_label,,}" == "${BOOT_PARTITION_LABEL,,}" ]] \
    || die "boot partition label is '$boot_label', expected '$BOOT_PARTITION_LABEL'"
boot_serial=$(blkid -p -s UUID -o value "$boot_device" || true)
[[ "${boot_serial//-/}" == "${esp_serial^^}" ]] \
    || die "boot partition serial is '$boot_serial', expected '${esp_serial:0:4}-${esp_serial:4}'"
root_uuid=$(blkid -p -s UUID -o value "$root_device" || true)
[[ "${root_uuid,,}" == "$rootfs_uuid" ]] \
    || die "root filesystem UUID is '$root_uuid', expected '$rootfs_uuid'"

mount "$boot_device" "$boot_mount"
# No options of our own: the root filesystem is mounted as mkfs.ext4 left it,
# without a journal, so there is no commit interval to hold down and no journal
# to replay.  It is still flushed and cleanly unmounted, and the board mounts
# the finished filesystem - journal and all - the way any other Debian rootfs
# is mounted.
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
[[ "${root_partuuid,,}" == "${root_guid,,}" ]] \
    || die "root PARTUUID is '$root_partuuid', not the derived GUID '$root_guid'"
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
# Everything the image holds is in place; the passes below are what remove the
# build's own traces from it.  The kernel stamps s_mtime, s_wtime, s_mnt_count
# and the lifetime write counter when it releases a filesystem, and only then, so
# they run with both filesystems unmounted - and on the root filesystem in this
# order, because debugfs restamps s_wtime every time it closes a filesystem it
# has written.  Nothing else touches either device before the loop is detached.
umount "$boot_mount"
umount "$root_mount"

python3 - "$boot_device" "$SOURCE_DATE_EPOCH" <<'PY'  # esp-times
import os
import struct
import sys
import time

# The kernel stamps a FAT entry's creation and access dates as it creates it
# (fs/fat/namei_vfat.c sets them from current_time), and nothing in userspace can
# change them afterwards: touch moves the modification time only.  The three
# dates live in every directory entry, so an ESP assembled twice differs in
# bytes that no file-level comparison would show.  The free-cluster summary is
# written back too, because only mkfs and Windows keep it up to date and a stale
# one is what dosfsck reports as an error.

device, epoch = sys.argv[1], int(sys.argv[2])
moment = time.gmtime(epoch)
if not 1980 <= moment.tm_year <= 2107:
    sys.exit(f'esp-times: the FAT date field cannot hold {moment.tm_year}')
# Stored in UTC, because the alternative is the runner's timezone, and the two
# runners are not guaranteed to agree on one.
stamp_time = (moment.tm_hour << 11) | (moment.tm_min << 5) | (moment.tm_sec // 2)
stamp_date = ((moment.tm_year - 1980) << 9) | (moment.tm_mon << 5) | moment.tm_mday

fd = os.open(device, os.O_RDWR)
boot = os.pread(fd, 512, 0)
if len(boot) != 512 or boot[510:512] != b'\x55\xaa':
    sys.exit(f'esp-times: {device} does not begin with a boot sector')
bytes_per_sector, = struct.unpack_from('<H', boot, 0x0B)
sectors_per_cluster = boot[0x0D]
reserved, = struct.unpack_from('<H', boot, 0x0E)
fat_count = boot[0x10]
root_entries, = struct.unpack_from('<H', boot, 0x11)
total16, = struct.unpack_from('<H', boot, 0x13)
fat_size16, = struct.unpack_from('<H', boot, 0x16)
total32, = struct.unpack_from('<I', boot, 0x20)
fat_size32, = struct.unpack_from('<I', boot, 0x24)
root_cluster, = struct.unpack_from('<I', boot, 0x2C)
fsinfo_sector, = struct.unpack_from('<H', boot, 0x30)
if not bytes_per_sector or not sectors_per_cluster:
    sys.exit(f'esp-times: {device} has an empty BIOS parameter block')
if fat_size16 or root_entries:
    # mkfs.vfat only writes FAT12/16 for volumes of a few tens of MiB, so this is
    # a layout change rather than corruption: the fixed root directory would have
    # to be walked before the clustered one.
    sys.exit(f'esp-times: {device} is not FAT32; the boot partition layout changed')

cluster_size = sectors_per_cluster * bytes_per_sector
fat = os.pread(fd, fat_size32 * bytes_per_sector, reserved * bytes_per_sector)
if len(fat) != fat_size32 * bytes_per_sector:
    sys.exit(f'esp-times: {device} ends inside the allocation table')
data_start = reserved + fat_count * fat_size32
clusters = ((total16 or total32) - data_start) // sectors_per_cluster


def cluster_start(number):
    return (data_start + (number - 2) * sectors_per_cluster) * bytes_per_sector


def fat_entry(number):
    # A chain that points past the table is a corrupt filesystem, not a reason
    # for a traceback: the pass reports what it found the way it does elsewhere.
    if number >= len(fat) // 4:
        sys.exit(f'esp-times: the allocation table does not cover cluster {number}')
    return struct.unpack_from('<I', fat, 4 * number)[0] & 0x0FFFFFFF


# 0x0D is the tenths-of-a-second field only the creation date has, 0x0E/0x10 the
# creation time and date, 0x12 the access date, 0x16/0x18 the write time and
# date.  Each pair is written as one slice, and the entry is kept for the
# read-back below: a slice assignment that changed length would corrupt every
# entry behind it instead of failing.
creation = struct.pack('<BHHH', 0, stamp_time, stamp_date, stamp_date)
modification = struct.pack('<HH', stamp_time, stamp_date)

pending = [root_cluster]
walked = set()
stamped = []
while pending:
    number = pending.pop()
    while 2 <= number < 0x0FFFFFF8:
        if number in walked:
            sys.exit(f'esp-times: the directory chain loops at cluster {number}')
        walked.add(number)
        base = cluster_start(number)
        block = bytearray(os.pread(fd, cluster_size, base))
        if len(block) != cluster_size:
            sys.exit(f'esp-times: {device} ends before cluster {number}')
        for offset in range(0, cluster_size, 32):
            entry = block[offset:offset + 32]
            if entry[0] == 0:
                break                       # past the last entry here
            if entry[0] == 0xE5:
                continue                    # deleted
            if (entry[0x0B] & 0x0F) == 0x0F:
                continue                    # long-name entry: 0x0D is a checksum
            stamped.append((base + offset, bytes(entry)))
            block[offset + 0x0D:offset + 0x14] = creation
            block[offset + 0x16:offset + 0x1A] = modification
            if (entry[0x0B] & 0x10) and entry[0] != 0x2E:
                child, = struct.unpack_from('<H', entry, 0x1A)
                child |= struct.unpack_from('<H', entry, 0x14)[0] << 16
                pending.append(child)
        os.pwrite(fd, bytes(block), base)
        number = fat_entry(number)

def read_fsinfo(sector):
    block = os.pread(fd, 512, sector * bytes_per_sector)
    if len(block) != 512 or struct.unpack_from('<I', block, 0x00)[0] != 0x41615252 \
            or struct.unpack_from('<I', block, 0x1E4)[0] != 0x61417272 \
            or struct.unpack_from('<I', block, 0x1FC)[0] != 0xAA550000:
        sys.exit(f'esp-times: {device} has no FSInfo block in sector {sector}')
    return bytearray(block)


# mkfs.fat writes the boot sector and the free-cluster summary twice, the second
# pair starting at BPB_BkBootSec, and the build had only ever updated the first:
# the image shipped one summary computed after the boot files were copied and
# one from the empty filesystem mkfs had just made.  dosfsck reads the first and
# says nothing, but a repair tool that finds the primary invalid falls back to
# the backup and would take the stale count for the truth.
summaries = [fsinfo_sector]
backup_boot, = struct.unpack_from('<H', boot, 0x32)
if backup_boot not in (0, 0xFFFF):
    summaries.append(backup_boot + fsinfo_sector)
free = [number for number in range(2, clusters + 2) if not fat_entry(number)]
for sector in summaries:
    summary = read_fsinfo(sector)
    struct.pack_into('<I', summary, 0x1E8, len(free))
    struct.pack_into('<I', summary, 0x1EC, free[0] if free else 0xFFFFFFFF)
    os.pwrite(fd, bytes(summary), sector * bytes_per_sector)
os.fsync(fd)

# A write to a loop device can be refused or short, and a board finding out is
# not a failure mode worth shipping, so everything written above is read back.
for offset, before in stamped:
    entry = os.pread(fd, 32, offset)
    if entry[0x0D:0x14] != creation or entry[0x16:0x1A] != modification:
        sys.exit(f'esp-times: the entry at 0x{offset:x} did not take the stamp')
    if entry[:0x0D] != before[:0x0D] or entry[0x14:0x16] != before[0x14:0x16] \
            or entry[0x1A:] != before[0x1A:]:
        sys.exit(f'esp-times: the entry at 0x{offset:x} changed outside its dates')
for sector in summaries:
    summary = os.pread(fd, 4, sector * bytes_per_sector + 0x1E8)
    if len(summary) != 4 or struct.unpack('<I', summary)[0] != len(free):
        sys.exit(f'esp-times: the free-cluster summary in sector {sector} did not take')
print(f'esp-times: {len(stamped)} entries stamped, {len(free)} of {clusters} clusters '
      f'free in all {len(summaries)} summaries as of '
      f'{time.strftime("%Y-%m-%d %H:%M:%S UTC", moment)}')
PY

# Every inode the image holds carries four times and a generation number, and
# all five come from outside the files' contents: the kernel stamps them as it
# creates the inode, and for atime, ctime, crtime and the generation there is no
# system call that sets them afterwards - which is why a rootfs with
# byte-identical contents still differed in tens of thousands of places on every
# build.  mtimes are overwritten with the epoch as well: rsync carries the
# packages' own mtimes over, so keeping those would be defensible, but then the
# image's determinism would rest on what rsync preserved rather than on what is
# written here.
#
# Which inodes exist is not something to assume: the pass reads the group
# descriptors, walks each group's inode bitmap and counts what it finds against
# the superblock's free-inode count, because a pass that guessed the layout wrong
# would stamp nothing and still report success.
inode_offsets=$(mktemp)
inode_commands=$(mktemp)
python3 - "$root_device" "$SOURCE_DATE_EPOCH" "$inode_offsets" <<'PY' > "$inode_commands"  # inode-times
import os
import struct
import sys

SUPERBLOCK = 1024
# The descriptor tables sit in the block after the superblock, except on a
# 1024-byte filesystem, where the superblock is a block of its own and they are
# in the second block after it.
device, epoch, offsets_path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
fd = os.open(device, os.O_RDONLY)
superblock = os.pread(fd, 1024, SUPERBLOCK)
if len(superblock) != 1024 or struct.unpack_from('<H', superblock, 0x38)[0] != 0xEF53:
    sys.exit(f'inode-times: {device} does not hold an ext2/3/4 filesystem')
inodes_count, = struct.unpack_from('<I', superblock, 0x00)
free_inodes, = struct.unpack_from('<I', superblock, 0x10)
log_block_size, = struct.unpack_from('<I', superblock, 0x18)
inodes_per_group, = struct.unpack_from('<I', superblock, 0x28)
inode_size, = struct.unpack_from('<H', superblock, 0x58) or 128
desc_size, = struct.unpack_from('<H', superblock, 0xFE)
incompat, = struct.unpack_from('<I', superblock, 0x60)
if incompat & 0x0010:
    sys.exit('inode-times: the filesystem uses meta_bg, whose descriptors this '
             'pass does not follow')
block_size = 1024 << log_block_size
desc_size = max(desc_size, 32)
if inode_size < 0x98:
    # crtime lives past the end of a 128-byte inode, so the four time fields
    # this pass writes do not all exist there.
    sys.exit(f'inode-times: {inode_size}-byte inodes have no crtime field to '
             'write; the filesystem was not made in this century')
descriptors = block_size if log_block_size else 2 * block_size
wide = bool(incompat & 0x0080)          # 64BIT: the high halves are in use
if wide and desc_size < 64:
    # The high halves of the block numbers live at the end of a 64-byte
    # descriptor; reading them out of a shorter one would point this pass at
    # block numbers that mean something else, and it writes what it reads.
    sys.exit(f'inode-times: the filesystem is 64-bit but its descriptors are '
             f'{desc_size} bytes')


def descriptor_word(blob, low, high):
    value, = struct.unpack_from('<I', blob, low)
    if wide:
        high_half, = struct.unpack_from('<I', blob, high)
        value |= high_half << 32
    return value


found = []
tables = []
groups = (inodes_count + inodes_per_group - 1) // inodes_per_group
for group in range(groups):
    table = descriptors + group * desc_size
    descriptor = os.pread(fd, desc_size, table)
    if len(descriptor) < desc_size:
        sys.exit(f'inode-times: {device} ends inside the group descriptors')
    flags, = struct.unpack_from('<H', descriptor, 0x12)
    if flags & 0x0001:
        # INODE_UNINIT: mkfs left this group's inode table to the kernel, so
        # there is nothing in it that was ever allocated.
        continue
    bitmap_block = descriptor_word(descriptor, 0x04, 0x24)
    table_block = descriptor_word(descriptor, 0x08, 0x28)
    bitmap = os.pread(fd, block_size, bitmap_block * block_size)
    if len(bitmap) != block_size:
        sys.exit(f'inode-times: {device} ends inside the inode bitmap of group {group}')
    inodes = table_block * block_size
    tables.append((inodes, min(inodes_per_group, inodes_count - group * inodes_per_group),
                   inode_size))
    for index in range(inodes_per_group):
        if not (bitmap[index // 8] >> (index % 8)) & 1:
            continue
        number = group * inodes_per_group + index + 1
        offset = inodes + index * inode_size
        inode = os.pread(fd, inode_size, offset)
        if len(inode) != inode_size:
            sys.exit(f'inode-times: {device} ends inside inode {number}')
        mode, = struct.unpack_from('<H', inode, 0x00)
        links, = struct.unpack_from('<H', inode, 0x1A)
        # Inodes 1 to 10 are reserved and some of them are deliberately empty;
        # everything the build can create is numbered from 11 up.
        if number >= 11 and not (mode and links):
            sys.exit(f'inode-times: inode {number} is marked in use but holds no '
                     f'file; the descriptor walk is wrong')
        found.append((number, offset))
if len(found) != inodes_count - free_inodes:
    sys.exit(f'inode-times: the walk found {len(found)} inodes in use and the '
             f'superblock says {inodes_count - free_inodes}')

# The offsets are handed to the read-back that runs after debugfs has written,
# so that it checks the inodes this pass meant to stamp rather than re-deriving
# which ones those were.  The tables go with them: the read-back also checks the
# inodes this pass left alone, which is where a deletion in the image's own
# filesystem would leave a time nobody could pin.
with open(offsets_path, 'w') as stream:
    stream.writelines(f'{offset}\n' for _, offset in found)
    stream.writelines(f'table {start} {count} {size}\n'
                      for start, count, size in tables)
lines = []
for number, _ in found:
    for field in ('atime', 'mtime', 'ctime', 'crtime'):
        lines.append(f'set_inode_field <{number}> {field} @{epoch}\n')
    # The _extra fields hold nanoseconds in the top thirty bits and the epoch
    # flag in the bottom two, so they take a plain number rather than a time: an
    # @ in front of it is refused, and debugfs prints its complaint and runs the
    # next command anyway.
    lines.append(f'set_inode_field <{number}> generation 0\n')
    for field in ('atime_extra', 'mtime_extra', 'ctime_extra', 'crtime_extra'):
        lines.append(f'set_inode_field <{number}> {field} 0\n')
sys.stdout.write(''.join(lines))
PY
# debugfs echoes every command it reads, which for a root filesystem is one line
# per field per inode; the read-back below is what says whether the write took,
# so the echo goes nowhere rather than filling a build log nobody reads.
debugfs -w -f "$inode_commands" "$root_device" > /dev/null \
    || die "debugfs could not write the inode timestamps"
rm -f "$inode_commands"
inode_commands=

# The order matters: debugfs restamps s_wtime when it closes the filesystem, so
# a wtime written anywhere but last is overwritten by the moment the command
# ran.  The lifetime write counter is pinned to zero because the kernel derives
# it from the sectors the device has written - the one superblock field that
# records how the build went rather than what it contains.
debugfs -w -R "set_super_value kbytes_written 0" "$root_device"
for field in mkfs_time lastcheck mtime first_error_time last_error_time wtime; do
    debugfs -w -R "set_super_value $field @$SOURCE_DATE_EPOCH" "$root_device"
done

# The journal the image ships, and the last writer of the superblock.  tune2fs
# builds it from this filesystem and the pinned clock alone - a journal
# superblock naming the filesystem's UUID with nothing to replay, over blocks
# that were free and so still hold the zeros the image file was made with - and
# the inode it allocates is one of the inodes the read-back below checks.
#
# It runs here, between the writes and the read-backs, because it also writes
# the copies of the superblock in the other block groups from the primary:
# placed before the passes it propagates the times the passes replace, and
# placed after the read-back it does so unverified.  Its own flush takes
# s_wtime from E2FSPROGS_FAKE_TIME, the epoch the loop above wrote, and it
# copies a lifetime write counter of zero - libext2fs only adds to that counter
# when it is already non-zero - so the bytes it writes are the ones pinned
# above.
tune2fs -O has_journal "$root_device" \
    || die "tune2fs could not create the root filesystem journal"

python3 - "$root_device" "$SOURCE_DATE_EPOCH" <<'PY'  # superblock-times
import struct
import sys
import time

# debugfs prints its complaint about a field it does not recognise on the
# banner line and goes on to the next command, so the status of this pass says
# nothing about whether it took.  The fields are read back out of the raw
# superblock instead, at the offsets the on-disk layout defines.
#
# The copies further into the device are read too.  Only mkfs writes them - the
# kernel commits the primary and nothing else, which is what fs/ext4/super.c
# shows - so pinning the primary would still leave a build that stamped nothing
# but a copy, and the image would carry the clock that made it in a block no
# tool of ours looks at.

device, epoch = sys.argv[1], int(sys.argv[2])
fields = {'s_mkfs_time': 0x108, 's_lastcheck': 0x40, 's_mtime': 0x2C,
          's_first_error_time': 0x198, 's_last_error_time': 0x1CC, 's_wtime': 0x30}
with open(device, 'rb') as image:
    image.seek(1024)
    superblock = image.read(1024)
    if struct.unpack_from('<H', superblock, 0x38)[0] != 0xEF53:
        sys.exit(f'superblock-times: {device} does not hold an ext2/3/4 filesystem')
    wrong = []
    for name, offset in fields.items():
        value, = struct.unpack_from('<I', superblock, offset)
        if value != epoch:
            wrong.append(f'{name} is {time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(value))}'
                         f', not the epoch')
    written, = struct.unpack_from('<Q', superblock, 0x178)
    if written:
        wrong.append(f'the lifetime write counter is {written} KiB, not zero')
    # The journal is created after the rootfs has been copied in, and its
    # absence is not something the rest of the build would notice: e2fsck
    # accepts a filesystem without one.  The image would then be one that
    # loses its metadata to a power cut on the board.
    features, = struct.unpack_from('<I', superblock, 0x5C)
    journal_inode, = struct.unpack_from('<I', superblock, 0xE0)
    if not features & 0x0004 or not journal_inode:
        wrong.append(f'has_journal is {"set" if features & 0x0004 else "clear"} '
                     f'and the journal inode is {journal_inode}')
    if wrong:
        sys.exit('superblock-times: ' + '; '.join(wrong))

    # Where those copies live is the filesystem's own business: sparse_super
    # keeps one at the start of every group numbered one, or a power of three,
    # five or seven.  sparse_super2 replaces that with two group numbers stored
    # in the superblock, and a filesystem that used it would need those read out
    # of a field this pass has no other reason to trust.
    compat, = struct.unpack_from('<I', superblock, 0x5C)
    incompat, = struct.unpack_from('<I', superblock, 0x60)
    if compat & 0x0200:
        sys.exit('superblock-times: the filesystem uses sparse_super2, whose '
                 'backup groups this pass does not follow')
    block_size = 1024 << struct.unpack_from('<I', superblock, 0x18)[0]
    blocks_per_group, = struct.unpack_from('<I', superblock, 0x20)
    first_block, = struct.unpack_from('<I', superblock, 0x14)
    blocks, = struct.unpack_from('<I', superblock, 0x04)
    if incompat & 0x0080:                       # 64BIT
        high, = struct.unpack_from('<I', superblock, 0x150)
        blocks |= high << 32
    uuid = superblock[0x68:0x78]

    def holds_a_backup(group):
        if group == 0:
            return False
        if group == 1:
            return True
        if group % 2 == 0:
            return False
        for divisor in (3, 5, 7):
            value = group
            while value % divisor == 0:
                value //= divisor
            if value == 1:
                return True
        return False

    groups = (blocks - first_block + blocks_per_group - 1) // blocks_per_group
    copies = 0
    for group in range(groups):
        if not holds_a_backup(group):
            continue
        offset = (first_block + group * blocks_per_group) * block_size
        image.seek(offset)
        copy = image.read(1024)
        # A copy that is not a superblock of this filesystem would mean this
        # pass has the rule wrong, and reading the times out of some other
        # structure would be worse than not looking at all.
        marker = struct.unpack_from('<H', copy, 0x38)[0] if len(copy) == 1024 else None
        number = struct.unpack_from('<H', copy, 0x5A)[0] if len(copy) == 1024 else None
        if marker != 0xEF53 or copy[0x68:0x78] != uuid or number != group:
            wrong.append(f'the block group {group} copy at 0x{offset:x} is not a '
                         f'superblock of this filesystem')
            continue
        copies += 1
        for name, field_offset in fields.items():
            value, = struct.unpack_from('<I', copy, field_offset)
            # mkfs fills three of these from its clock and leaves the other
            # three empty, the way a filesystem that was never mounted or never
            # went wrong looks.  Either is a value this build pins; a time that
            # is neither is the clock of the machine that made the image, which
            # is what the copies stopped this pass from carrying.  The write
            # counter is left out: it counts what mkfs wrote, and a counter is
            # neither a time nor something the build has an opinion about.
            if value not in (0, epoch):
                wrong.append(f'the block group {group} copy holds '
                             f'{name} as {time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(value))}')
    if wrong:
        sys.exit('superblock-times: ' + '; '.join(wrong[:6])
                 + (' and more' if len(wrong) > 6 else ''))
print(f'superblock-times: six time fields and the write counter read back as '
      f'{time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime(epoch))}, and so do '
      f'{copies} copies of the superblock')
PY

python3 - "$root_device" "$SOURCE_DATE_EPOCH" "$inode_offsets" <<'PY'  # inode-times-check
import os
import struct
import sys
import time

# The read-back for the inode pass.  debugfs prints its complaint about a field
# it cannot set on the banner line and runs the next command, so the pass above
# reports success whether or not it did anything; the values are read out of the
# raw inodes here instead, because a wrong one is in a published image for good.
# The inodes the pass left out are checked too: an unused inode that is not all
# zeros is one the kernel wrote to after the filesystem was populated - a
# deletion, or a reused inode - and both carry times nothing here can pin.

TIMES = (0x08, 0x0C, 0x10, 0x90)        # atime, ctime, mtime, crtime
EXTRAS = (0x8C, 0x84, 0x88, 0x94)       # the same four, in nanoseconds
GENERATION = 0x64
device, epoch, offsets_path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
allocated, tables = set(), []
for line in open(offsets_path):
    fields = line.split()
    if fields[0] == 'table':
        tables.append((int(fields[1]), int(fields[2]), int(fields[3])))
    else:
        allocated.add(int(fields[0]))

fd = os.open(device, os.O_RDONLY)
wrong = []
for offset in sorted(allocated):
    inode = os.pread(fd, 0x98, offset)
    if len(inode) != 0x98:
        sys.exit(f'inode-times-check: {device} ends inside the inode at 0x{offset:x}')
    for name, at in zip(('atime', 'ctime', 'mtime', 'crtime'), TIMES):
        value, = struct.unpack_from('<I', inode, at)
        if value != epoch:
            wrong.append(f'{name} of the inode at 0x{offset:x} is '
                         f'{time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(value))}')
    for name, at in zip(('atime_extra', 'ctime_extra', 'mtime_extra', 'crtime_extra'),
                        EXTRAS):
        value, = struct.unpack_from('<I', inode, at)
        if value:
            wrong.append(f'{name} of the inode at 0x{offset:x} is {value}')
    value, = struct.unpack_from('<I', inode, GENERATION)
    if value:
        wrong.append(f'the generation of the inode at 0x{offset:x} is {value}')

# A megabyte of inode table at a time: a rootfs holds a few hundred thousand
# inodes, and this is the only pass that reads all of them.
for start, count, size in tables:
    per_window = max(1, (1 << 20) // size)
    for index in range(0, count, per_window):
        first = index * size
        window = os.pread(fd, min(per_window, count - index) * size, start + first)
        for step in range(0, len(window), size):
            offset = start + first + step
            if offset in allocated:
                continue
            inode = window[step:step + size]
            mode, = struct.unpack_from('<H', inode, 0x00)
            links, = struct.unpack_from('<H', inode, 0x1A)
            dtime, = struct.unpack_from('<I', inode, 0x14)
            values = [struct.unpack_from('<I', inode, at)[0]
                      for at in EXTRAS + TIMES + (GENERATION,)]
            if mode or links or dtime or any(values):
                wrong.append(f'the unused inode at 0x{offset:x} is not empty')

if wrong:
    sys.exit('inode-times-check: ' + '; '.join(wrong[:6])
             + (f' (and {len(wrong) - 6} more)' if len(wrong) > 6 else ''))
print(f'inode-times-check: {len(allocated)} inodes carry the epoch in all four '
      f'times and a clear generation, and every unused inode is empty')
PY
rm -f "$inode_offsets"
inode_offsets=

# Neither the workflow nor the build had ever looked at the filesystems the
# finished image ships; a rootfs that cannot be mounted was published anyway.
# These are read-only passes, and they run after the last write to either
# device.
e2fsck -fn "$root_device" || die "the root filesystem did not pass e2fsck -fn"
fsck.fat -n "$boot_device" || die "the boot partition did not pass fsck.fat -n"

# What the build log keeps about the filesystem that just passed: the
# identifier the firmware and fstab read, the state it was left in, and the
# journal it ships.  The checks above are the gate, so a grep that matches
# nothing must not fail a build whose image has already been written.
LANG=C dumpe2fs -h "$root_device" \
    | grep -E 'Filesystem UUID|Filesystem state|Journal inode|Journal size|Last mount time|Last write time|Last checked|Lifetime writes' \
    || true

sync
printf 'image build complete: %s\n' "$image_path"
