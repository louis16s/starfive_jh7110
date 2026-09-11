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

for command_name in curl dpkg-deb python3 rsync sha256sum tar; do
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
readonly package_version="${pvr_version}-2"
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
        --max-time 300 --output "$archive" "$pvr_url"
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
# Debian Trixie uses merged-usr. Package firmware and units under /usr/lib,
# never ship a real top-level /lib directory over the distribution symlink.
if [[ -d "$stage_dir/lib" ]]; then
    rsync -a --remove-source-files "$stage_dir/lib/" "$stage_dir/usr/lib/"
    find "$stage_dir/lib" -depth -type d -empty -delete
    [[ ! -e "$stage_dir/lib" ]] || die "unmerged GPU payload remains"
fi

install -d -m 0755 \
    "$stage_dir/DEBIAN" \
    "$stage_dir/usr/share/doc/$package_name" \
    "$stage_dir/usr/lib/systemd/system" \
    "$stage_dir/etc/systemd/system/multi-user.target.wants"

printf '%s\n' \
    'Package: jh7110-pvr-rogue' \
    "Version: $package_version" \
    'Section: non-free/libs' \
    'Priority: optional' \
    'Architecture: riscv64' \
    'Maintainer: jh7110-desktop maintainers' \
    'Description: StarFive JH7110 IMG BXE-4-32 PowerVR runtime' \
    ' Licensed IMG GPU firmware and userspace runtime from the StarFive BSP.' \
    > "$stage_dir/DEBIAN/control"

printf '%s\n' \
    '#!/bin/sh' \
    'set -eu' \
    'ldconfig' \
    > "$stage_dir/DEBIAN/postinst"
chmod 0755 "$stage_dir/DEBIAN/postinst"

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
    'ConditionPathExists=/etc/init.d/rc.pvr' \
    '' \
    '[Service]' \
    'Type=oneshot' \
    'TimeoutStartSec=30' \
    'ExecStart=/etc/init.d/rc.pvr start' \
    'ExecStop=/etc/init.d/rc.pvr stop' \
    'RemainAfterExit=yes' \
    '' \
    '[Install]' \
    'WantedBy=multi-user.target' \
    > "$stage_dir/usr/lib/systemd/system/jh7110-pvr.service"

ln -s /usr/lib/systemd/system/jh7110-pvr.service \
    "$stage_dir/etc/systemd/system/multi-user.target.wants/jh7110-pvr.service"

dpkg-deb --build --root-owner-group "$stage_dir" "$output_package" >/dev/null
dpkg-deb --info "$output_package" >/dev/null
printf 'GPU package ready: %s\n' "$output_package"
