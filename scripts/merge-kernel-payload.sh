#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 2 ]] || { echo 'usage: merge-kernel-payload.sh PAYLOAD ROOTFS' >&2; exit 1; }
payload=$1
rootfs=$2
[[ -d "$payload/lib/modules" && -d "$rootfs/usr/lib" ]] || exit 1
for alias in bin sbin lib; do
    [[ -L "$rootfs/$alias" && $(readlink "$rootfs/$alias") == "usr/$alias" ]] \
        || { echo "broken Debian merged-usr link: $alias" >&2; exit 1; }
done
# Kernel bindeb-pkg contains a real ./lib directory. Never unpack it directly
# over Debian's /lib symlink: that removes the ELF interpreter from /lib.
rsync -a --keep-dirlinks "$payload/" "$rootfs/"
