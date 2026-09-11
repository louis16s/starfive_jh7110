#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "FAIL: test-kernel-merge line $LINENO" >&2' ERR
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/root/usr/"{lib,bin,sbin} "$test_dir/payload/lib/modules/test"
for alias in lib bin sbin; do
    ln -s "usr/$alias" "$test_dir/root/$alias"
done
touch "$test_dir/root/usr/lib/loader-sentinel" "$test_dir/payload/lib/modules/test/module.ko"
bash "$repo/scripts/merge-kernel-payload.sh" "$test_dir/payload" "$test_dir/root"
[[ -L "$test_dir/root/lib" && -f "$test_dir/root/lib/loader-sentinel" ]] || exit 1
[[ -f "$test_dir/root/usr/lib/modules/test/module.ko" ]]
# Repeat installs must preserve both the symlink and existing userspace.
bash "$repo/scripts/merge-kernel-payload.sh" "$test_dir/payload" "$test_dir/root"
[[ -L "$test_dir/root/lib" && -f "$test_dir/root/lib/loader-sentinel" ]] || exit 1
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
[[ $(readlink "$test_dir/unmerged/lib") == usr/lib ]] || exit 1
[[ -f "$test_dir/unmerged/lib/modules/old/old.ko" ]] || exit 1
[[ -f "$test_dir/unmerged/lib/modules/test/module.ko" ]] || exit 1
# Empty /lib must also normalize, including subsequent repeated installs.
mkdir -p "$test_dir/empty/usr/"{lib,bin,sbin} "$test_dir/empty/lib"
for alias in bin sbin; do ln -s "usr/$alias" "$test_dir/empty/$alias"; done
bash "$repo/scripts/merge-kernel-payload.sh" "$test_dir/payload" "$test_dir/empty"
bash "$repo/scripts/merge-kernel-payload.sh" "$test_dir/payload" "$test_dir/empty"
[[ -f "$test_dir/empty/lib/modules/test/module.ko" ]] || exit 1
# Unknown /lib entries must not be silently deleted or overwritten.
mkdir -p "$test_dir/unknown/usr/"{lib,bin,sbin} "$test_dir/unknown/lib"
for alias in bin sbin; do ln -s "usr/$alias" "$test_dir/unknown/$alias"; done
touch "$test_dir/unknown/lib/unknown"
if bash "$repo/scripts/merge-kernel-payload.sh" "$test_dir/payload" "$test_dir/unknown"; then
    echo 'FAIL: unknown /lib content accepted' >&2; exit 1
fi
[[ -f "$test_dir/unknown/lib/unknown" ]] || exit 1
echo 'PASS: kernel payload preserves merged-usr; broken rootfs rejected'
