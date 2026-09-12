#!/usr/bin/env bash
# Pin the timestamps that the U-Boot and kernel builds embed in their payloads.
#
# Both builds default to the wall clock, so two builds of the same commit
# produced different bytes: U-Boot writes U_BOOT_DATE/U_BOOT_TIME into its
# version string (which lands in the SPL, in u-boot-nodtb.bin and in the `uboot`
# image inside the FIT), the kernel stamps every entry of its built-in initramfs
# cpio, and scripts/mkcompile_h takes the compile user and host from `whoami`
# and `uname -n`, which published the CI runner's hostname inside every released
# kernel banner.  None of that is a difference a reviewer wants to see: it made
# byte comparison of two builds useless, and a rebuild could never be checked
# against a published digest.
#
# The epoch is the commit date, which build-manifest.txt records as
# repository_commit, so a published artifact can be rebuilt from the manifest.
#
# Sourced by the build scripts; defines pin_build_timestamps().

pin_build_timestamps() {
    if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
        SOURCE_DATE_EPOCH=$(git -C "$REPO_ROOT" log -1 --pretty=%ct 2>/dev/null || true)
    fi
    # U-Boot reads the variable itself (Makefile: it formats U_BOOT_DATE and
    # friends from it, and `touch -d @$SOURCE_DATE_EPOCH`).  Refusing to build
    # without it keeps a tarball checkout from silently publishing payloads
    # that cannot be reproduced.
    [[ "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]] \
        || die "cannot determine SOURCE_DATE_EPOCH from $REPO_ROOT; set it in the environment"
    export SOURCE_DATE_EPOCH

    # The kernel wants a date string, not an epoch: usr/Makefile passes it to
    # `gen_initramfs.sh -d`, which runs `date -d` in the build machine's
    # timezone.  Naming the zone in the value is what keeps the cpio mtimes
    # independent of the runner's TZ.  GNU and BSD date disagree on the flag
    # that reads an epoch, and this has to work on a macOS development host too.
    KBUILD_BUILD_TIMESTAMP=$(LC_ALL=C date -u -d "@$SOURCE_DATE_EPOCH" \
        '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null \
        || LC_ALL=C date -u -r "$SOURCE_DATE_EPOCH" '+%Y-%m-%d %H:%M:%S UTC')
    export KBUILD_BUILD_TIMESTAMP
    # mkcompile_h falls back to whoami/uname -n.  Both are recorded in
    # linux_banner and in include/generated/compile.h.
    KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-builder}
    KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-jh7110-desktop}
    export KBUILD_BUILD_USER KBUILD_BUILD_HOST
}
