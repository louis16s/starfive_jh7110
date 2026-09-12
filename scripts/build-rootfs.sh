#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly REPO_ROOT

die() {
    echo "build-rootfs: $*" >&2
    exit 1
}

[[ $# -eq 1 ]] || die "usage: $0 BOARD"
board=$1

# shellcheck source=/dev/null
source "$REPO_ROOT/board/$board/profile.conf"
# shellcheck source=lib/build-timestamps.sh
source "$REPO_ROOT/scripts/lib/build-timestamps.sh"

# The rootfs is where the image's file times come from: dpkg unpacks each
# package with the times the archive recorded, and the chroot then runs tools
# that stamp the moment they ran.  The image build normalises the inodes it
# creates from this tree, so what matters here is that the times are a function
# of the commit rather than of the runner - and that the chroot sees the same
# epoch, which is why it is passed into the environment below.
pin_build_timestamps

command -v mmdebstrap >/dev/null 2>&1 || die "mmdebstrap is required on the Linux build host"
command -v qemu-riscv64-static >/dev/null 2>&1 || die "qemu-riscv64-static is required for riscv64 customization"
command -v rsync >/dev/null 2>&1 || die "rsync is required"
[[ -f /usr/share/keyrings/debian-archive-keyring.gpg ]] \
    || die "missing Debian archive keyring: install debian-archive-keyring"
# The overlay copy uses --chown=root:root, the board config is written into
# root-owned directories and the customization runs inside a real chroot.
# Running unprivileged cannot satisfy any of those, so reject it up front
# instead of failing halfway through the rootfs assembly.
[[ "$EUID" -eq 0 ]] \
    || die "rootfs construction requires root; run: sudo make BOARD=$board rootfs"

readonly output_dir="$REPO_ROOT/$OUTPUT_ROOT/$board/rootfs"
readonly rootfs_dir="$output_dir/rootfs"
readonly package_dir="$REPO_ROOT/rootfs/packages"
readonly overlay_dir="$REPO_ROOT/rootfs/overlay"
readonly board_package_dir="$REPO_ROOT/$OUTPUT_ROOT/$board/packages"
readonly snapshot="$DEBIAN_SNAPSHOT"
readonly debian_keyring=/usr/share/keyrings/debian-archive-keyring.gpg
# Privileged builds use mmdebstrap's root mode rather than nesting another
# user namespace.
readonly mmdebstrap_mode=root

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
chmod 0755 "$rootfs_dir/usr/libexec/jh7110-prepare" \
    "$rootfs_dir/usr/libexec/jh7110-console-setup" \
    "$rootfs_dir/usr/libexec/jh7110-account"

install -d -m 0755 "$rootfs_dir/etc/jh7110"
cat > "$rootfs_dir/etc/jh7110/board.conf" <<EOF
BOARD_ID=$BOARD_ID
BOARD_NAME='$BOARD_NAME'
DEFAULT_HOSTNAME=$DEFAULT_HOSTNAME
TIMEZONE=$TIMEZONE
DEFAULT_LOCALE=$DEFAULT_LOCALE
DEFAULT_LANGUAGE=$DEFAULT_LANGUAGE
SUPPORTED_LOCALES='$SUPPORTED_LOCALES'
ACCOUNT_MODEL=$ACCOUNT_MODEL
DEFAULT_USER=$DEFAULT_USER
EOF

# mmdebstrap --mode=root copies the build host's /etc/hostname and /etc/hosts
# into the target, and nothing used to overwrite them: two runs of the same
# commit produced images with different content, and the board booted
# answering to the CI runner's name with a hosts file that had never heard of
# it, which is the `sudo: unable to resolve host` warning on every command.
# Both files are written here, with the same functions the board runs, so the
# image ships and the first boot maintains one implementation.
inherited_hostname=$(head -n 1 "$rootfs_dir/etc/hostname" 2>/dev/null || true)
inherited_hostname=${inherited_hostname%%[[:space:]]*}
if [[ -n "$inherited_hostname" && "$inherited_hostname" != "$DEFAULT_HOSTNAME" ]]; then
    printf 'build-rootfs: replacing the inherited hostname %s with %s\n' \
        "$inherited_hostname" "$DEFAULT_HOSTNAME" >&2
fi
# The inherited hosts file describes the build host - its extra lines are not
# this image's - so the base entries are rendered from nothing and the result
# is a function of the profile alone.
: > "$rootfs_dir/etc/hosts"

# The library derives every path from these, and the board's own copy of it is
# the one that will run on the device; source the same file the overlay ships.
JH7110_ETC="$rootfs_dir/etc"
JH7110_STATE_DIR="$rootfs_dir/var/lib/jh7110"
readonly JH7110_ETC JH7110_STATE_DIR
# shellcheck source=../rootfs/overlay/usr/lib/jh7110/common.sh
source "$overlay_dir/usr/lib/jh7110/common.sh"
# This writes files only - it must never rename the machine doing the build.
jh7110_write_hostname_files "$DEFAULT_HOSTNAME" \
    || die "could not write the image hostname and hosts files"
if ! awk -v name="$DEFAULT_HOSTNAME" '
    $1 == "127.0.1.1" && $2 == name { found = 1 }
    END { exit !found }
' "$rootfs_dir/etc/hosts"; then
    die "$rootfs_dir/etc/hosts does not map 127.0.1.1 to $DEFAULT_HOSTNAME"
fi

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
ln -s ../jh7110-prepare.service \
    "$rootfs_dir/etc/systemd/system/multi-user.target.wants/jh7110-prepare.service"
ln -s ../jh7110-console-setup.service \
    "$rootfs_dir/etc/systemd/system/multi-user.target.wants/jh7110-console-setup.service"

qemu_target="$rootfs_dir/usr/bin/qemu-riscv64-static"
cleanup_qemu() {
    rm -f "$qemu_target"
}
trap cleanup_qemu EXIT
install -m 0755 "$(command -v qemu-riscv64-static)" "$qemu_target"

shopt -s nullglob
gpu_packages=("$board_package_dir"/jh7110-pvr-rogue_*.deb)
shopt -u nullglob
[[ ${#gpu_packages[@]} -eq 1 ]] || die "expected exactly one GPU package in $board_package_dir; run make BOARD=$board gpu-package"
gpu_deb_name=
if [[ ${#gpu_packages[@]} -eq 1 ]]; then
    gpu_deb_name=$(basename "${gpu_packages[0]}")
    install -m 0644 "${gpu_packages[0]}" "$rootfs_dir/tmp/$gpu_deb_name"
fi

chroot "$rootfs_dir" /usr/bin/env -i \
    HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    LC_ALL=C DEBIAN_FRONTEND=noninteractive \
    SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    DEFAULT_LOCALE="$DEFAULT_LOCALE" DEFAULT_LANGUAGE="$DEFAULT_LANGUAGE" \
    SUPPORTED_LOCALES="$SUPPORTED_LOCALES" DEFAULT_USER="$DEFAULT_USER" \
    DEFAULT_HOSTNAME="$DEFAULT_HOSTNAME" \
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
        systemctl enable NetworkManager systemd-timesyncd ssh lightdm jh7110-prepare jh7110-console-setup jh7110-pvr zramswap
        systemctl set-default graphical.target
        # smartd is useful when a SMART-capable disk is attached, but it is
        # not a boot prerequisite and exits noisily on SD/eMMC-only boards.
        # Keep smartmontools installed while leaving its daemon opt-in.
        for service in smartmontools.service smartd.service; do
            if systemctl cat "$service" >/dev/null 2>&1; then
                # Leaving these enabled is the only thing that must not happen;
                # a unit that is already absent or has no [Install] section is
                # not a build failure.
                systemctl disable "$service" >/dev/null 2>&1 || true
            fi
        done
        # Validate target binaries and desktop payload before assembling an image.
        for helper in chvt whiptail growpart resize2fs lsblk \
            useradd usermod chpasswd getent; do
            command -v "$helper" >/dev/null
        done
        # The desktop account is created by the first-run setup, so the group
        # it uses to become an administrator has to exist in the image.
        getent group sudo >/dev/null
        # nft opens a NETLINK_NETFILTER socket even for a dry run, and QEMU
        # user-mode does not provide one, so the checker itself cannot start
        # there.  Only a real ruleset error may fail the build.
        if ! nft_output=$(nft -c -f /etc/nftables.conf 2>&1); then
            if [[ $nft_output == *"Netlink socket"* ||
                $nft_output == *"Protocol not supported"* ]]; then
                echo "rootfs: WARN nft syntax check skipped; QEMU user-mode has no netlink" >&2
            else
                printf "%s\\n" "$nft_output" >&2
                exit 1
            fi
        fi
        # The board has to be able to resolve its own name before the first
        # boot even runs, and a hosts file with no 127.0.1.1 line is the
        # `sudo: unable to resolve host` warning waiting to happen.
        # Resolving its own name is what `sudo` needs, and it is the one check
        # that reads the file the way the board will.  A failure here prints
        # what is in the file, because that is the whole diagnosis.
        if ! getent hosts "$DEFAULT_HOSTNAME" > /dev/null; then
            echo "rootfs: /etc/hosts does not resolve $DEFAULT_HOSTNAME:" >&2
            cat /etc/hosts >&2
            exit 1
        fi
        test -s /usr/lib/xorg/modules/drivers/modesetting_drv.so
        test -s /usr/share/xsessions/xfce.desktop
        test -s /usr/share/xgreeters/lightdm-gtk-greeter.desktop
        test -s /etc/X11/xorg.conf.d/20-jh7110-safe-desktop.conf
        # The desktop GL/EGL stack is Mesa and runs on the CPU: the locked PVR
        # archive contains no EGL runtime at all (only a static libIMGeglsup.a
        # in its staging tree), so there is no vendor EGL for GLVND to load.
        # mmdebstrap also bootstraps with Apt::Install-Recommends false, which
        # means these libraries are only guaranteed by hard dependencies.  A
        # snapshot update that drops one would otherwise ship an image that
        # boots to a desktop with no GL and no EGL, so fail the build here.
        for graphics_library in libEGL.so.1 libEGL_mesa.so.0 libGLX_mesa.so.0 \
            libGLESv2.so.2 libgbm.so.1 libvulkan.so.1 \
            dri/swrast_dri.so dri/kms_swrast_dri.so; do
            graphics_matches=(/usr/lib/*-linux-gnu/$graphics_library)
            # An unmatched glob stays literal and a match can be an empty file,
            # so both cases are reported instead of failing on a bare test -s.
            if [[ ${#graphics_matches[@]} -ne 1 ||
                ! -s "${graphics_matches[0]}" ]]; then
                echo "rootfs: missing or empty graphics runtime: $graphics_library" >&2
                exit 1
            fi
        done
        # Vulkan is the only hardware acceleration path on this board, and it
        # is provided by the GPU package rather than by Debian.  Assert the
        # installed contract (ICD manifest plus its library) so a packaging
        # regression fails the build instead of the first boot of the board.
        test -s /etc/vulkan/icd.d/icdconf.json
        test -s /usr/lib/libVK_IMG.so
        # These carry the identities and the clock of the machine that built the
        # image rather than anything the image is meant to have: dpkg and apt log
        # each step with the time it ran, and the machine id and host keys are
        # per-installation secrets.  The image build pins the metadata of every
        # inode it writes, but a log line is content and no pass can reach it, so
        # the files are removed here - systemd and the first-boot unit create
        # both identities on the board, where they belong.
        rm -f /var/log/dpkg.log /var/log/dpkg.log.* /var/log/alternatives.log \
            /var/log/alternatives.log.* /var/log/bootstrap.log
        rm -f /var/log/apt/*
        rm -f /etc/machine-id
        rm -f /etc/ssh/ssh_host_*
        apt-get clean
    '
cleanup_qemu
trap - EXIT

printf 'rootfs build complete: %s\n' "$rootfs_dir"
