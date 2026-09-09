#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

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

xz -T0 -9e --keep "$image_path"
sha256sum "$compressed_path" > "$compressed_path.sha256"
printf 'compressed image: %s\n' "$compressed_path"
