#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly REPO_ROOT

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
compiler="${cross_compile}gcc"
if [[ "${USE_CCACHE:-0}" == 1 ]]; then
    command -v ccache >/dev/null 2>&1 || die "USE_CCACHE=1 requires ccache"
    compiler="ccache $compiler"
fi

mkdir -p "$output_dir"
env -u BOARD -u BUILD_TYPE -u MAKEFLAGS -u MFLAGS -u MAKEOVERRIDES \
    make -C "$opensbi_source" O="$output_dir" ARCH=riscv \
    CROSS_COMPILE="$cross_compile" CC="$compiler" PLATFORM=generic -j"$jobs"
printf 'OpenSBI build complete: %s\n' "$board"
