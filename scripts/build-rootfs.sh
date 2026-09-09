#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

die() {
    echo "build-rootfs: $*" >&2
    exit 1
}

[[ $# -eq 1 ]] || die "usage: $0 BOARD"
board=$1

# shellcheck source=/dev/null
source "$REPO_ROOT/board/$board/profile.conf"

command -v mmdebstrap >/dev/null 2>&1 || die "mmdebstrap is required on the Linux build host"
command -v qemu-riscv64-static >/dev/null 2>&1 || die "qemu-riscv64-static is required for riscv64 customization"
command -v rsync >/dev/null 2>&1 || die "rsync is required"
[[ -f /usr/share/keyrings/debian-archive-keyring.gpg ]] \
    || die "missing Debian archive keyring: install debian-archive-keyring"

readonly output_dir="$REPO_ROOT/$OUTPUT_ROOT/$board/rootfs"
readonly rootfs_dir="$output_dir/rootfs"
readonly package_dir="$REPO_ROOT/rootfs/packages"
readonly overlay_dir="$REPO_ROOT/rootfs/overlay"
readonly snapshot="$DEBIAN_SNAPSHOT"
readonly security_snapshot="$DEBIAN_SECURITY_SNAPSHOT"
readonly debian_keyring=/usr/share/keyrings/debian-archive-keyring.gpg
mmdebstrap_mode=unshare
if [[ "$EUID" -eq 0 ]]; then
    # Rootless unshare cannot reliably create a destination below the GitHub
    # runner workspace after the kernel package build. In a privileged build,
    # use mmdebstrap's root mode instead of nesting another user namespace.
    mmdebstrap_mode=root
fi

[[ ! -e "$rootfs_dir" ]] || die "output exists: $rootfs_dir; remove it explicitly before rebuilding"
mkdir -p "$output_dir"

mapfile -t packages < <(
    awk '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        { print }
    ' "$package_dir/base.list" "$package_dir/desktop.list" \
      "$package_dir/development.list" "$package_dir/board-tools.list"
)
[[ ${#packages[@]} -gt 0 ]] || die "package manifest is empty"
include_list=$(IFS=,; echo "${packages[*]}")

mmdebstrap \
    --mode="$mmdebstrap_mode" \
    --format=directory \
    --architectures="$TARGET_ARCH" \
    --variant=apt \
    --components=main,contrib,non-free-firmware \
    --keyring="$debian_keyring" \
    --aptopt='Acquire::Check-Valid-Until "false"' \
    --include="$include_list" \
    "$DEBIAN_SUITE" "$rootfs_dir" "$snapshot"

rsync -a --chown=root:root "$overlay_dir/" "$rootfs_dir/"
chmod 0755 "$rootfs_dir/usr/libexec/jh7110-firstboot"

install -d -m 0755 "$rootfs_dir/etc/jh7110"
cat > "$rootfs_dir/etc/jh7110/board.conf" <<EOF
BOARD_ID=$BOARD_ID
BOARD_NAME='$BOARD_NAME'
EOF
printf '%s\n' "$TIMEZONE" > "$rootfs_dir/etc/timezone"
ln -sfn "/usr/share/zoneinfo/$TIMEZONE" "$rootfs_dir/etc/localtime"

install -d -m 0755 "$rootfs_dir/etc/apt/sources.list.d"
cat > "$rootfs_dir/etc/apt/sources.list.d/debian.sources" <<EOF
Types: deb
URIs: $snapshot
Suites: $DEBIAN_SUITE
Components: main contrib non-free-firmware
Architectures: $TARGET_ARCH
Check-Valid-Until: no

Types: deb
URIs: $security_snapshot
Suites: ${DEBIAN_SUITE}-security
Components: main contrib non-free-firmware
Architectures: $TARGET_ARCH
Check-Valid-Until: no
EOF
rm -f "$rootfs_dir/etc/apt/sources.list"

install -d -m 0755 "$rootfs_dir/etc/systemd/system/multi-user.target.wants"
ln -s ../jh7110-firstboot.service \
    "$rootfs_dir/etc/systemd/system/multi-user.target.wants/jh7110-firstboot.service"

qemu_target="$rootfs_dir/usr/bin/qemu-riscv64-static"
cleanup_qemu() {
    rm -f "$qemu_target"
}
trap cleanup_qemu EXIT
install -m 0755 "$(command -v qemu-riscv64-static)" "$qemu_target"
chroot "$rootfs_dir" /usr/bin/env -i \
    HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    LC_ALL=C DEBIAN_FRONTEND=noninteractive \
    /bin/bash -Eeuc '
        echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
        echo "zh_CN.UTF-8 UTF-8" >> /etc/locale.gen
        locale-gen
        update-locale LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8
        useradd --create-home --shell /bin/bash --groups sudo,audio,video,input,plugdev,netdev jh7110
        passwd --lock jh7110
        systemctl preset-all
        systemctl enable NetworkManager systemd-timesyncd ssh lightdm
        rm -f /etc/machine-id
        rm -f /etc/ssh/ssh_host_*
        apt-get clean
    '
cleanup_qemu
trap - EXIT

printf 'rootfs build complete: %s\n' "$rootfs_dir"
