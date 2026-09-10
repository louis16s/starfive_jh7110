#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

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

{
    printf 'project=%s\n' "$PROJECT_NAME"
    printf 'board=%s\n' "$BOARD_ID"
    printf 'board_name=%s\n' "$BOARD_NAME"
    printf 'target_arch=%s\n' "$TARGET_ARCH"
    printf 'debian_suite=%s\n' "$DEBIAN_SUITE"
    printf 'debian_version=%s\n' "$DEBIAN_VERSION"
    printf 'debian_snapshot=%s\n' "$DEBIAN_SNAPSHOT"
    printf 'debian_security_snapshot=%s\n' "$DEBIAN_SECURITY_SNAPSHOT"
    printf 'timezone=%s\n' "$TIMEZONE"
    timezone_offset=$(TZ="$TIMEZONE" date +%z)
    printf 'timezone_utc_offset=UTC%s:%s\n' "${timezone_offset:0:3}" "${timezone_offset:3:2}"
    printf 'locale_default=%s\n' "$DEFAULT_LOCALE"
    printf 'locales_supported=%s\n' "$SUPPORTED_LOCALES"
    printf 'default_user=%s\n' "$DEFAULT_USER"
    printf 'kernel_source=%s\n' "$KERNEL_SOURCE"
    printf 'kernel_dtb=%s\n' "$KERNEL_DTB"
    printf 'uboot_source=%s\n' "$UBOOT_SOURCE"
    printf 'opensbi_source=%s\n' "$OPENSBI_SOURCE"
    printf 'bootloader_media=%s\n' "$BOOTLOADER_MEDIA"
    gpu_package=$(find "$output_dir/packages" -maxdepth 1 -type f \
        -name 'jh7110-pvr-rogue_*.deb' -print -quit)
    if [[ -n "$gpu_package" ]]; then
        printf 'gpu_package=%s\n' "${gpu_package#"$REPO_ROOT/"}"
    else
        printf 'gpu_package=not-built\n'
    fi
    printf 'source_lock_sha256=%s\n' "$(sha256sum "$REPO_ROOT/$SOURCE_LOCK" | awk '{print $1}')"
    printf 'repository_commit=%s\n' "$(git -C "$REPO_ROOT" rev-parse HEAD)"
    printf 'build_host=%s\n' "$(uname -a)"
    printf 'build_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '\nartifacts:\n'
    find "$output_dir/image" "$output_dir/packages" -maxdepth 1 -type f \
        \( -name '*.img.xz' -o -name '*.img.xz.sha256' -o -name '*.deb' \) -print0 |
        sort -z | while IFS= read -r -d '' artifact; do
            printf '%s  %s\n' "$(sha256sum "$artifact" | awk '{print $1}')" "${artifact#"$REPO_ROOT/"}"
        done
    find "$output_dir/u-boot" -maxdepth 1 -type f \
        \( -name 'u-boot.bin' -o -name 'u-boot.img' -o -name 'u-boot-*.bin' -o -name 'u-boot-*.img' \) -print0 |
        sort -z |
        while IFS= read -r -d '' artifact; do
            printf '%s  %s\n' "$(sha256sum "$artifact" | awk '{print $1}')" "${artifact#"$REPO_ROOT/"}"
        done
    find "$output_dir/u-boot/spl" -maxdepth 1 -type f \
        \( -name 'u-boot-spl.bin' -o -name 'u-boot-spl.bin.normal.out' -o -name 'u-boot-spl.dtb' \) -print0 |
        sort -z |
        while IFS= read -r -d '' artifact; do
            printf '%s  %s\n' "$(sha256sum "$artifact" | awk '{print $1}')" "${artifact#"$REPO_ROOT/"}"
        done
    for artifact in \
        "$output_dir/opensbi/platform/generic/firmware/fw_dynamic.bin" \
        "$output_dir/kernel/arch/riscv/boot/dts/starfive/$KERNEL_DTB"; do
        if [[ -f "$artifact" ]]; then
            printf '%s  %s\n' "$(sha256sum "$artifact" | awk '{print $1}')" "${artifact#"$REPO_ROOT/"}"
        fi
    done
} > "$manifest"
printf 'manifest: %s\n' "$manifest"
