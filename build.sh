#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./build.sh BOARD [check|profile|verify-sources|host-check|fetch|kernel|uboot|opensbi|rootfs|install-kernel|image|compress|manifest]

Boards:
  visionfive2   StarFive VisionFive 2 8GB
  mars          Milk-V Mars 8GB
  all           Validate both board profiles

Phase 4 commands:
  check           Validate profile, host prerequisites and locked sources
  profile         Validate only the board profile and capability matrix
  verify-sources  Resolve every Git source and compare its locked commit
  host-check      Check the x86_64 build host prerequisites
  fetch           Fetch the exact locked kernel/U-Boot/OpenSBI sources
  kernel          Build the locked BSP kernel (requires the cross toolchain)
  uboot           Build the board-selected U-Boot (requires the cross toolchain)
  opensbi         Build the board-selected OpenSBI (requires the cross toolchain)
  rootfs          Build the Debian Trixie riscv64 directory rootfs
  install-kernel  Extract the built kernel package and generate the initrd
  compress        Compress the assembled image and write a SHA256 file
  manifest        Write the build manifest and artifact hashes
  image           Assemble the GPT boot/root image (run as root)
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
