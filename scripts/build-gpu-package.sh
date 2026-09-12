#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly REPO_ROOT

die() {
    echo "build-gpu-package: $*" >&2
    exit 1
}

[[ $# -eq 1 ]] || die "usage: $0 BOARD"
board=$1

# shellcheck source=/dev/null
source "$REPO_ROOT/board/$board/profile.conf"
# shellcheck source=lib/build-timestamps.sh
source "$REPO_ROOT/scripts/lib/build-timestamps.sh"

for command_name in curl dpkg-deb md5sum python3 rsync sha256sum tar; do
    command -v "$command_name" >/dev/null 2>&1 \
        || die "missing command: $command_name"
done

read -r pvr_url pvr_sha256 pvr_version pvr_license < <(
    python3 - "$REPO_ROOT/$SOURCE_LOCK" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    entry = yaml.safe_load(handle)["sources"]["starfive_pvr_ddk_1_19"]
url = entry["url"].replace("/blob/", "/raw/")
print(url, entry["sha256"], entry["ref"], entry["license"])
PY
)

[[ -n "$pvr_url" && -n "$pvr_sha256" && -n "$pvr_version" && -n "$pvr_license" ]] \
    || die "incomplete PVR lock entry"
[[ "$pvr_license" == proprietary-vendor-license-accepted ]] \
    || die "PVR lock entry is not license-approved: $pvr_license"

readonly cache_dir="$REPO_ROOT/$SOURCE_ROOT/gpu"
readonly archive="$cache_dir/img-gpu-powervr-bin-${pvr_version}.tar.gz"
readonly output_dir="$REPO_ROOT/$OUTPUT_ROOT/$board/packages"
readonly package_name=jh7110-pvr-rogue
readonly package_version="${pvr_version}-3"
readonly output_package="$output_dir/${package_name}_${package_version}_riscv64.deb"
mkdir -p "$cache_dir" "$output_dir"
work_dir=$(mktemp -d "$output_dir/.gpu-package.XXXXXX")
readonly work_dir
readonly stage_dir="$work_dir/package"
readonly payload_dir="$work_dir/payload"

cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT

if [[ ! -s "$archive" ]]; then
    curl --fail --location --retry 3 --retry-delay 2 \
        --max-time 300 --output "$work_dir/download.tar.gz" "$pvr_url"
    actual_sha256=$(sha256sum "$work_dir/download.tar.gz" | awk '{print $1}')
    [[ "$actual_sha256" == "$pvr_sha256" ]] || die "downloaded PVR archive SHA256 mismatch"
    mv "$work_dir/download.tar.gz" "$archive"
fi
actual_sha256=$(sha256sum "$archive" | awk '{print $1}')
[[ "$actual_sha256" == "$pvr_sha256" ]] \
    || die "PVR archive SHA256 mismatch: $actual_sha256 != $pvr_sha256"

mkdir -p "$payload_dir" "$stage_dir"
tar --extract --gzip --file="$archive" --directory="$payload_dir"
top_dir=$(find "$payload_dir" -mindepth 1 -maxdepth 1 -type d -print -quit)
[[ -n "$top_dir" && -d "$top_dir/target" ]] \
    || die "PVR archive has no target directory"
rsync -a "$top_dir/target/" "$stage_dir/"
# Use Debian's Vulkan loader and GLVND entry points. The BSP's generic SONAME
# aliases can shadow them via ldconfig; retain only vendor-named GLES libraries.
rm -f "$stage_dir"/usr/lib/libvulkan.so* \
    "$stage_dir"/usr/lib/libvulkan-1.so \
    "$stage_dir"/usr/lib/libGLESv1_CM.so* "$stage_dir"/usr/lib/libGLESv2.so*
# The vendor archive also ships an init.d launcher that targets the old
# drm_starfive module. The systemd unit below loads the current pvrsrvkm
# driver; leaving the obsolete script installed invites accidental use.
rm -f "$stage_dir/etc/init.d/rc.pvr"
# dpkg records the directories it finds, empty ones included, so removing the
# script above would otherwise leave an empty /etc/init.d behind in the
# package - a directory the system already provides and no maintainer script
# expects to be shipped.
if [[ -d "$stage_dir/etc/init.d" ]]; then
    find "$stage_dir/etc/init.d" -depth -type d -empty -delete
fi

# Debian Trixie uses merged-usr. Package firmware and units under /usr/lib,
# never ship a real top-level /lib directory over the distribution symlink.
if [[ -d "$stage_dir/lib" ]]; then
    rsync -a --remove-source-files "$stage_dir/lib/" "$stage_dir/usr/lib/"
    find "$stage_dir/lib" -depth -type d -empty -delete
    [[ ! -e "$stage_dir/lib" ]] || die "unmerged GPU payload remains"
fi

for firmware_pattern in 'rgx.fw.*' 'rgx.sh.*'; do
    firmware=$(find "$stage_dir/usr/lib/firmware" -maxdepth 1 -type f \
        -name "$firmware_pattern" -size +0c -print -quit)
    [[ -n "$firmware" ]] || die "PVR archive is missing non-empty $firmware_pattern"
done

# Nothing else stamps this package.  dpkg-deb takes the packaging time for its
# ar members, and keeping SOURCE_DATE_EPOCH unset would leave the directories,
# the maintainer scripts and the systemd symlink created below newer than that
# epoch, so it also ships them with the packaging time.  Two boards packaging a
# byte-identical vendor payload therefore produced .deb files 14 bytes and 11
# seconds apart.
pin_build_timestamps

install -d -m 0755 \
    "$stage_dir/DEBIAN" \
    "$stage_dir/usr/share/doc/$package_name" \
    "$stage_dir/usr/lib/systemd/system" \
    "$stage_dir/etc/systemd/system/multi-user.target.wants" \
    "$stage_dir/etc/initramfs-tools/hooks"

# The PVR kernel driver probes during initramfs, before the real rootfs is
# mounted. Ship the exact firmware in every generated initramfs so a package
# install cannot silently degrade to "firmware not found" at boot.
install -m 0755 "$REPO_ROOT/packages/gpu/initramfs-hook" \
    "$stage_dir/etc/initramfs-tools/hooks/jh7110-pvr-firmware"

printf '%s\n' \
    'Package: jh7110-pvr-rogue' \
    "Version: $package_version" \
    'Section: non-free/libs' \
    'Priority: optional' \
    'Architecture: riscv64' \
    'Maintainer: jh7110-desktop maintainers' \
    'Depends: libc6, libdrm2, libstdc++6, libgcc-s1, libvulkan1, initramfs-tools, kmod' \
    'Description: StarFive JH7110 IMG BXE-4-32 PowerVR runtime' \
    ' Licensed IMG GPU firmware and userspace runtime from the StarFive BSP.' \
    > "$stage_dir/DEBIAN/control"

install -m 0755 "$REPO_ROOT/packages/gpu/postinst" "$stage_dir/DEBIAN/postinst"

printf '%s\n' \
    "Source URL: $pvr_url" \
    "Source SHA256: $pvr_sha256" \
    "DDK version: $pvr_version" \
    'License: proprietary vendor payload; redistribution authorized by project owner' \
    > "$stage_dir/usr/share/doc/$package_name/SOURCE"

printf '%s\n' \
    '[Unit]' \
    'Description=StarFive PowerVR kernel services' \
    'After=local-fs.target systemd-modules-load.service' \
    'Before=display-manager.service' \
    '' \
    '[Service]' \
    'Type=oneshot' \
    'TimeoutStartSec=30' \
    'ExecStart=/sbin/modprobe pvrsrvkm' \
    'RemainAfterExit=yes' \
    '' \
    '[Install]' \
    'WantedBy=multi-user.target' \
    > "$stage_dir/usr/lib/systemd/system/jh7110-pvr.service"

ln -s /usr/lib/systemd/system/jh7110-pvr.service \
    "$stage_dir/etc/systemd/system/multi-user.target.wants/jh7110-pvr.service"

# dpkg-deb only copies DEBIAN/ into the archive, so nothing generates the file
# list digest that dpkg-buildpackage would: without md5sums `dpkg --verify`
# reports every file in this package as unverified, which hides real
# corruption. Paths are relative to the package root (no leading ./), sorted,
# and cover regular files only - symlinks are not digestible and dpkg does not
# list them here.
(
    cd "$stage_dir"
    find . -path ./DEBIAN -prune -o -type f -print0 \
        | LC_ALL=C sort -z \
        | xargs -0 md5sum \
        | sed 's|^\([0-9a-f]\{32\}\)  \./|\1  |' \
        > DEBIAN/md5sums
)
[[ -s "$stage_dir/DEBIAN/md5sums" ]] || die "generated an empty md5sums file"

dpkg-deb --build --root-owner-group "$stage_dir" "$output_package" >/dev/null
dpkg-deb --info "$output_package" >/dev/null
# Read the control member back out of the finished archive: writing the file
# into the staging tree is not the same as dpkg-deb carrying it into the .deb.
control_listing=$(dpkg-deb --ctrl-tarfile "$output_package" | tar --list --file=-)
[[ "$control_listing" == *md5sums* ]] \
    || die "md5sums did not make it into $output_package"
printf 'GPU package ready: %s\n' "$output_package"
