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
readonly board_package_dir="$REPO_ROOT/$OUTPUT_ROOT/$board/packages"
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

mmdebstrap_attempt=1
while :; do
    if mmdebstrap \
        --mode="$mmdebstrap_mode" \
        --format=directory \
        --architectures="$TARGET_ARCH" \
        --variant=apt \
        --components=main,contrib,non-free-firmware \
        --keyring="$debian_keyring" \
        --aptopt='Acquire::Check-Valid-Until "false"' \
        --aptopt='Acquire::Retries "5"' \
        --include="$include_list" \
        "$DEBIAN_SUITE" "$rootfs_dir" "$snapshot"; then
        break
    fi
    if (( mmdebstrap_attempt >= 3 )); then
        die "mmdebstrap failed after $mmdebstrap_attempt attempts"
    fi
    printf 'build-rootfs: mmdebstrap attempt %s failed; retrying snapshot download\n' \
        "$mmdebstrap_attempt" >&2
    rm -rf "$rootfs_dir"
    ((mmdebstrap_attempt += 1))
    sleep 10
done

rsync -a --chown=root:root "$overlay_dir/" "$rootfs_dir/"
chmod 0755 "$rootfs_dir/usr/libexec/jh7110-firstboot"

install -d -m 0755 "$rootfs_dir/etc/jh7110"
cat > "$rootfs_dir/etc/jh7110/board.conf" <<EOF
BOARD_ID=$BOARD_ID
BOARD_NAME='$BOARD_NAME'
TIMEZONE=$TIMEZONE
DEFAULT_LOCALE=$DEFAULT_LOCALE
DEFAULT_LANGUAGE=$DEFAULT_LANGUAGE
SUPPORTED_LOCALES='$SUPPORTED_LOCALES'
DEFAULT_USER=$DEFAULT_USER
EOF
printf '%s\n' "$TIMEZONE" > "$rootfs_dir/etc/timezone"
ln -sfn "/usr/share/zoneinfo/$TIMEZONE" "$rootfs_dir/etc/localtime"

install -d -m 0755 "$rootfs_dir/etc/apt/sources.list.d"
cat > "$rootfs_dir/etc/apt/sources.list.d/debian.sources" <<EOF
Types: deb
URIs: $DEBIAN_MAINLAND_MIRROR $DEBIAN_OFFICIAL_MIRROR
Suites: $DEBIAN_SUITE
Components: main contrib non-free-firmware
Architectures: $TARGET_ARCH
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: $DEBIAN_SECURITY_MAINLAND_MIRROR $DEBIAN_SECURITY_OFFICIAL_MIRROR
Suites: ${DEBIAN_SUITE}-security
Components: main contrib non-free-firmware
Architectures: $TARGET_ARCH
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
rm -f "$rootfs_dir/etc/apt/sources.list"
install -d -m 0755 "$rootfs_dir/etc/apt/apt.conf.d"
cat > "$rootfs_dir/etc/apt/apt.conf.d/80-jh7110-network" <<'EOF'
Acquire::Retries "5";
Acquire::http::Timeout "15";
Acquire::https::Timeout "15";
EOF

install -d -m 0755 "$rootfs_dir/etc/systemd/system/multi-user.target.wants"
ln -s ../jh7110-firstboot.service \
    "$rootfs_dir/etc/systemd/system/multi-user.target.wants/jh7110-firstboot.service"

qemu_target="$rootfs_dir/usr/bin/qemu-riscv64-static"
cleanup_qemu() {
    rm -f "$qemu_target"
}
trap cleanup_qemu EXIT
install -m 0755 "$(command -v qemu-riscv64-static)" "$qemu_target"

shopt -s nullglob
gpu_packages=("$board_package_dir"/jh7110-pvr-rogue_*.deb)
shopt -u nullglob
[[ ${#gpu_packages[@]} -le 1 ]] || die "multiple GPU packages found in $board_package_dir"
gpu_deb_name=
if [[ ${#gpu_packages[@]} -eq 1 ]]; then
    gpu_deb_name=$(basename "${gpu_packages[0]}")
    install -m 0644 "${gpu_packages[0]}" "$rootfs_dir/tmp/$gpu_deb_name"
fi

chroot "$rootfs_dir" /usr/bin/env -i \
    HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    LC_ALL=C DEBIAN_FRONTEND=noninteractive \
    DEFAULT_LOCALE="$DEFAULT_LOCALE" DEFAULT_LANGUAGE="$DEFAULT_LANGUAGE" \
    SUPPORTED_LOCALES="$SUPPORTED_LOCALES" DEFAULT_USER="$DEFAULT_USER" \
    GPU_DEB_NAME="$gpu_deb_name" \
    /bin/bash -Eeuc '
        if [[ -n "${GPU_DEB_NAME:-}" ]]; then
            dpkg --install "/tmp/$GPU_DEB_NAME"
            rm -f "/tmp/$GPU_DEB_NAME"
        fi
        : > /etc/locale.gen
        for locale_name in $SUPPORTED_LOCALES; do
            printf "%s UTF-8\\n" "$locale_name" >> /etc/locale.gen
        done
        locale-gen
        update-locale LANG="$DEFAULT_LOCALE" LANGUAGE="$DEFAULT_LANGUAGE" \
            LC_MESSAGES="$DEFAULT_LOCALE"
        passwd --lock root
        systemctl preset-all
        systemctl enable NetworkManager systemd-timesyncd ssh lightdm jh7110-firstboot
        systemctl set-default graphical.target
        # Validate target binaries and desktop payload before assembling an image.
        for helper in chvt whiptail growpart resize2fs lsblk; do
            command -v "$helper" >/dev/null
        done
        test -s /usr/lib/xorg/modules/drivers/modesetting_drv.so
        test -s /usr/share/xsessions/xfce.desktop
        test -s /usr/share/xgreeters/lightdm-gtk-greeter.desktop
        test -s /etc/X11/xorg.conf.d/20-jh7110-safe-desktop.conf
        rm -f /etc/machine-id
        rm -f /etc/ssh/ssh_host_*
        apt-get clean
    '
cleanup_qemu
trap - EXIT

printf 'rootfs build complete: %s\n' "$rootfs_dir"
