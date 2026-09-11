#!/usr/bin/env bash
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/root/usr/"{lib,bin,sbin} "$test_dir/payload/lib/modules/test"
for alias in lib bin sbin; do
    ln -s "usr/$alias" "$test_dir/root/$alias"
done
touch "$test_dir/root/usr/lib/loader-sentinel" "$test_dir/payload/lib/modules/test/module.ko"
bash "$repo/scripts/merge-kernel-payload.sh" "$test_dir/payload" "$test_dir/root"
[[ -L "$test_dir/root/lib" && -f "$test_dir/root/usr/lib/loader-sentinel" ]]
[[ -f "$test_dir/root/usr/lib/modules/test/module.ko" ]]
# Repeat installs must preserve both the symlink and existing userspace.
bash "$repo/scripts/merge-kernel-payload.sh" "$test_dir/payload" "$test_dir/root"
[[ -L "$test_dir/root/lib" && -f "$test_dir/root/usr/lib/loader-sentinel" ]]
mkdir -p "$test_dir/broken/usr/lib" "$test_dir/broken/lib"
if bash "$repo/scripts/merge-kernel-payload.sh" "$test_dir/payload" "$test_dir/broken"; then
    echo 'FAIL: accepted a broken merged-usr rootfs' >&2
    exit 1
fi
mkdir -p "$test_dir/unmerged/usr/lib" "$test_dir/unmerged/usr/bin" "$test_dir/unmerged/usr/sbin" \
    "$test_dir/unmerged/lib/modules/old"
for alias in bin sbin; do
    ln -s "usr/$alias" "$test_dir/unmerged/$alias"
done
printf 'old module' > "$test_dir/unmerged/lib/modules/old/old.ko"
bash "$repo/scripts/merge-kernel-payload.sh" "$test_dir/payload" "$test_dir/unmerged"
[[ -L "$test_dir/unmerged/lib" ]]
[[ -f "$test_dir/unmerged/usr/lib/modules/old/old.ko" ]]
[[ ! -e "$test_dir/unmerged/lib/modules" ]]
echo 'PASS: kernel payload preserves merged-usr; broken rootfs rejected'
