#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 2 ]] || { echo 'usage: merge-kernel-payload.sh PAYLOAD ROOTFS' >&2; exit 1; }
payload=$1
rootfs=$2
[[ -d "$payload/lib/modules" && -d "$rootfs/usr/lib" ]] || exit 1
for alias in bin sbin; do
    [[ -L "$rootfs/$alias" && $(readlink "$rootfs/$alias") == "usr/$alias" ]] \
        || { echo "broken Debian merged-usr link: $alias" >&2; exit 1; }
done
if [[ -d "$rootfs/lib" && ! -L "$rootfs/lib" ]]; then
    # Some mmdebstrap layouts create /lib before usrmerge is finalized.
    # Accept only an empty directory or the kernel module subtree.
    while IFS= read -r entry; do
        [[ "$entry" == "$rootfs/lib/modules" ]] \
            || { echo "unexpected files in unmerged /lib: $entry" >&2; exit 1; }
    done < <(find "$rootfs/lib" -mindepth 1 -maxdepth 1 -print)
    mkdir -p "$rootfs/usr/lib/modules"
    if [[ -d "$rootfs/lib/modules" ]]; then
        rsync -a --remove-source-files "$rootfs/lib/modules/" "$rootfs/usr/lib/modules/"
        find "$rootfs/lib/modules" -depth -type d -empty -delete
    fi
    [[ ! -e "$rootfs/lib/modules" ]] \
        || { echo "could not move all files from unmerged /lib/modules" >&2; exit 1; }
    rmdir "$rootfs/lib"
    ln -s usr/lib "$rootfs/lib"
elif [[ ! -L "$rootfs/lib" || $(readlink "$rootfs/lib") != "usr/lib" ]]; then
    echo "broken Debian merged-usr link: lib" >&2
    exit 1
fi
# Kernel bindeb-pkg contains a real ./lib directory. Never unpack it directly
# over Debian's /lib symlink: that removes the ELF interpreter from /lib.
rsync -a --keep-dirlinks "$payload/" "$rootfs/"
