#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly REPO_ROOT

die() {
    echo "compress-image: $*" >&2
    exit 1
}

[[ $# -eq 1 ]] || die "usage: $0 BOARD"
board=$1
# shellcheck source=/dev/null
source "$REPO_ROOT/board/$board/profile.conf"
command -v xz >/dev/null 2>&1 || die "missing xz"
command -v sha256sum >/dev/null 2>&1 || die "missing sha256sum"

readonly image_dir="$REPO_ROOT/$OUTPUT_ROOT/$board/image"
readonly image_path="$image_dir/$IMAGE_BASENAME.img"
readonly compressed_path="$image_path.xz"
[[ -f "$image_path" ]] || die "missing image: $image_path"
[[ ! -e "$compressed_path" ]] || die "output exists: $compressed_path; remove it explicitly before rebuilding"
xz_threads=${XZ_THREADS:-2}
[[ "$xz_threads" =~ ^[1-9][0-9]*$ ]] || die "XZ_THREADS must be a positive integer"

xz -T"$xz_threads" -6 --keep "$image_path"
(
    cd "$image_dir"
    sha256sum "$(basename "$compressed_path")"
) > "$compressed_path.sha256"
[[ -s "$compressed_path" ]] || die "xz did not create a usable compressed image"
printf 'compressed image: %s\n' "$compressed_path"
