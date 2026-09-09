#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./build.sh BOARD [check|profile|verify-sources|host-check|image]

Boards:
  visionfive2   StarFive VisionFive 2 8GB
  mars          Milk-V Mars 8GB
  all           Validate both board profiles

Phase 2 commands:
  check           Validate profile, host prerequisites and locked sources
  profile         Validate only the board profile and capability matrix
  verify-sources  Resolve every Git source and compare its locked commit
  host-check      Check the x86_64 build host prerequisites
  image           Reserved for the Phase 5 image builder
EOF
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage
    exit 2
fi

board=$1
target=${2:-check}

case "$board" in
    visionfive2|mars)
        make BOARD="$board" BUILD_TYPE="${BUILD_TYPE:-release}" "$target"
        ;;
    all)
        if [[ "$target" == "image" ]]; then
            echo "image target does not support BOARD=all yet" >&2
            exit 2
        fi
        for board_name in visionfive2 mars; do
            make BOARD="$board_name" BUILD_TYPE="${BUILD_TYPE:-release}" "$target"
        done
        ;;
    -h|--help)
        usage
        ;;
    *)
        echo "unsupported board: $board" >&2
        usage >&2
        exit 2
        ;;
esac
