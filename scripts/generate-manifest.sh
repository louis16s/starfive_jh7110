#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly REPO_ROOT

die() {
    echo "generate-manifest: $*" >&2
    exit 1
}

[[ $# -eq 1 ]] || die "usage: $0 BOARD"
board=$1
# shellcheck source=/dev/null
source "$REPO_ROOT/board/$board/profile.conf"
command -v sha256sum >/dev/null 2>&1 || die "missing sha256sum"

readonly output_dir="$REPO_ROOT/$OUTPUT_ROOT/$board"
readonly manifest="$output_dir/build-manifest.txt"
mkdir -p "$output_dir"
mkdir -p "$output_dir/packages"

# Hashing through a pipeline used to hide a missing file: the exit status came
# from awk, so `$(sha256sum "$path" | awk ...)` expanded to the empty string and
# the manifest was published with a blank digest.  Fail on the digest instead.
sha256_file() {
    local path=$1 digest
    [[ -f "$path" ]] || die "cannot hash missing file: $path"
    # These are the files CI uploads and users download, and CI uploads them as
    # the unprivileged runner user while this script has usually been run under
    # sudo.  A root-owned 0600 artifact is invisible to both, so refuse it here
    # rather than letting the artifact upload fail after the image has already
    # been transferred.  `find` is used because -perm is the same on BSD and
    # GNU, while stat(1) takes different flags on each.
    [[ -z "$(find "$path" ! -perm -o=r -print -quit)" ]] \
        || die "published artifact is not world-readable: $path"
    digest=$(sha256sum -- "$path" | awk '{print $1}')
    [[ -n "$digest" ]] || die "sha256sum produced no digest for $path"
    printf '%s' "$digest"
}

# Print "sha256  repo-relative-path" for every matching file directly inside
# DIR.  A build tree that is missing a stage is skipped instead of aborting:
# `find` on an absent directory used to terminate the script mid-write and
# leave a truncated manifest behind.
emit_artifacts() {
    local directory=$1
    [[ -d "$directory" ]] || return 0
    shift
    find "$directory" -maxdepth 1 -type f \( "$@" \) -print0 |
        sort -z | while IFS= read -r -d '' artifact; do
            printf '%s  %s\n' \
                "$(sha256_file "$artifact")" "${artifact#"$REPO_ROOT/"}"
        done
}

# Provenance is computed before the manifest is opened so that a broken tool
# aborts the build with the previous manifest still in place.
source_lock_sha256=$(sha256_file "$REPO_ROOT/$SOURCE_LOCK")
repository_commit=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)
[[ -n "$repository_commit" ]] \
    || die "cannot determine repository commit; is $REPO_ROOT a git checkout?"
build_host=$(uname -a)
build_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
timezone_offset=$(TZ="$TIMEZONE" date +%z)
gpu_package=$(find "$output_dir/packages" -maxdepth 1 -type f \
    -name 'jh7110-pvr-rogue_*.deb' -print -quit)

# Write through a temporary file: the manifest is a published release asset, so
# a failed run must never replace a complete manifest with a partial one.
manifest_tmp=$(mktemp "$output_dir/.build-manifest.XXXXXX")
trap 'rm -f "$manifest_tmp"' EXIT
# mktemp always creates its file 0600, and `mv` would carry that mode onto the
# published manifest.  CI stages the manifest with `sudo make manifest` and the
# upload step then runs as the unprivileged runner user, which cannot read a
# 0600 root-owned file: the upload of a board's whole artifact set failed with
# EACCES on this file alone, after 800 MB of image had already been sent.
chmod 0644 "$manifest_tmp"

{
    printf 'project=%s\n' "$PROJECT_NAME"
    printf 'board=%s\n' "$BOARD_ID"
    printf 'board_name=%s\n' "$BOARD_NAME"
    printf 'target_arch=%s\n' "$TARGET_ARCH"
    # BUILD_TYPE does not change a single compiled byte: it selects the CI
    # artifact name only.  Recording it here is what makes that visible, so a
    # "debug" download can be told apart from a release one without digging
    # through the workflow.
    printf 'build_type=%s\n' "$BUILD_TYPE"
    printf 'debian_suite=%s\n' "$DEBIAN_SUITE"
    printf 'debian_version=%s\n' "$DEBIAN_VERSION"
    printf 'debian_snapshot=%s\n' "$DEBIAN_SNAPSHOT"
    printf 'debian_security_snapshot=%s\n' "$DEBIAN_SECURITY_SNAPSHOT"
    printf 'debian_runtime_mainland_mirror=%s\n' "$DEBIAN_MAINLAND_MIRROR"
    printf 'debian_runtime_official_mirror=%s\n' "$DEBIAN_OFFICIAL_MIRROR"
    printf 'debian_runtime_security_mainland_mirror=%s\n' "$DEBIAN_SECURITY_MAINLAND_MIRROR"
    printf 'debian_runtime_security_official_mirror=%s\n' "$DEBIAN_SECURITY_OFFICIAL_MIRROR"
    printf 'timezone=%s\n' "$TIMEZONE"
    printf 'timezone_utc_offset=UTC%s:%s\n' "${timezone_offset:0:3}" "${timezone_offset:3:2}"
    printf 'locale_default=%s\n' "$DEFAULT_LOCALE"
    printf 'locales_supported=%s\n' "$SUPPORTED_LOCALES"
    printf 'default_user=%s\n' "$DEFAULT_USER"
    printf 'kernel_source=%s\n' "$KERNEL_SOURCE"
    printf 'kernel_dtb=%s\n' "$KERNEL_DTB"
    printf 'uboot_source=%s\n' "$UBOOT_SOURCE"
    printf 'opensbi_source=%s\n' "$OPENSBI_SOURCE"
    printf 'bootloader_media=%s\n' "$BOOTLOADER_MEDIA"
    # Released files are renamed to <prefix><basename>, so a downloaded asset
    # can be matched back to the "artifacts:" entries below.
    printf 'release_asset_prefix=jh7110-%s-\n' "$BOARD_ID"
    if [[ -n "$gpu_package" ]]; then
        printf 'gpu_package=%s\n' "${gpu_package#"$REPO_ROOT/"}"
    else
        printf 'gpu_package=not-built\n'
    fi
    printf 'source_lock_sha256=%s\n' "$source_lock_sha256"
    printf 'repository_commit=%s\n' "$repository_commit"
    printf 'build_host=%s\n' "$build_host"
    printf 'build_utc=%s\n' "$build_utc"
    printf '\nartifacts:\n'
    emit_artifacts "$output_dir/image" \
        -name '*.img.xz' -o -name '*.img.xz.sha256' -o -name '*.deb'
    emit_artifacts "$output_dir/packages" -name '*.deb'
    emit_artifacts "$output_dir/u-boot" \
        -name 'u-boot.bin' -o -name 'u-boot.itb' -o -name 'u-boot.img' \
        -o -name 'u-boot-*.bin' -o -name 'u-boot-*.img'
    emit_artifacts "$output_dir/u-boot/spl" \
        -name 'u-boot-spl.bin' -o -name 'u-boot-spl.bin.normal.out' \
        -o -name 'u-boot-spl.dtb'
    for artifact in \
        "$output_dir/opensbi/platform/generic/firmware/fw_dynamic.bin" \
        "$output_dir/release/$KERNEL_DTB"; do
        if [[ -f "$artifact" ]]; then
            printf '%s  %s\n' \
                "$(sha256_file "$artifact")" "${artifact#"$REPO_ROOT/"}"
        fi
    done
} > "$manifest_tmp"

mv "$manifest_tmp" "$manifest"
trap - EXIT
[[ -z "$(find "$manifest" ! -perm -o=r -print -quit)" ]] \
    || die "manifest is not world-readable: $manifest"
printf 'manifest: %s\n' "$manifest"
