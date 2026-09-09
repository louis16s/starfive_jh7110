#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

die() {
    echo "build-opensbi: $*" >&2
    exit 1
}

[[ $# -eq 1 ]] || die "usage: $0 BOARD"
board=$1

# shellcheck source=/dev/null
source "$REPO_ROOT/board/$board/profile.conf"

opensbi_source="$REPO_ROOT/$SOURCE_ROOT/$OPENSBI_SOURCE"
output_dir="$REPO_ROOT/$OUTPUT_ROOT/$board/opensbi"
cross_compile=${CROSS_COMPILE:-riscv64-linux-gnu-}
jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}

[[ -d "$opensbi_source" ]] || die "missing source; run make BOARD=$board fetch"
command -v "${cross_compile}gcc" >/dev/null 2>&1 || die "missing ${cross_compile}gcc"

mkdir -p "$output_dir"
make -C "$opensbi_source" O="$output_dir" ARCH=riscv CROSS_COMPILE="$cross_compile" \
    PLATFORM=generic -j"$jobs"
printf 'OpenSBI build complete: %s\n' "$board"
