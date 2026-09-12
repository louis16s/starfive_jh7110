#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly REPO_ROOT

die() {
    echo "build-kernel: $*" >&2
    exit 1
}

[[ $# -eq 1 ]] || die "usage: $0 BOARD"
board=$1

# shellcheck source=/dev/null
source "$REPO_ROOT/board/$board/profile.conf"

kernel_source="$REPO_ROOT/$SOURCE_ROOT/$KERNEL_SOURCE"
output_dir="$REPO_ROOT/$OUTPUT_ROOT/$board/kernel"
cross_compile=${CROSS_COMPILE:-riscv64-linux-gnu-}
jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}

[[ -d "$kernel_source" ]] || die "missing source; run make BOARD=$board fetch"
command -v "${cross_compile}gcc" >/dev/null 2>&1 || die "missing ${cross_compile}gcc"
command -v make >/dev/null 2>&1 || die "missing make"
compiler="${cross_compile}gcc"
if [[ "${USE_CCACHE:-0}" == 1 ]]; then
    command -v ccache >/dev/null 2>&1 || die "USE_CCACHE=1 requires ccache"
    compiler="ccache $compiler"
fi

mkdir -p "$output_dir"
kernel_make() {
    env -u BOARD -u BUILD_TYPE -u MAKEFLAGS -u MFLAGS -u MAKEOVERRIDES \
        make -C "$kernel_source" O="$output_dir" ARCH=riscv \
        CROSS_COMPILE="$cross_compile" CC="$compiler" "$@"
}

kernel_make "$KERNEL_DEFCONFIG"
for symbol in VT VT_CONSOLE HW_CONSOLE FB FRAMEBUFFER_CONSOLE DRM_FBDEV_EMULATION HID HID_GENERIC USB_HID INPUT_EVDEV; do
    "$kernel_source/scripts/config" --file "$output_dir/.config" --enable "$symbol"
done
# zram-tools loads zram with modprobe during boot, so keep the driver as a
# module rather than built-in. This also lets the userspace service choose the
# number of devices and compressor at runtime.
"$kernel_source/scripts/config" --file "$output_dir/.config" --module ZRAM
# LZ4 keeps swap compression inexpensive on the U74 cores. Retain LZO for
# existing user configurations; explicitly match the image's zramswap policy.
for symbol in SWAP ZRAM_BACKEND_LZ4 ZRAM_BACKEND_LZO ZRAM_DEF_COMP_LZ4; do
    "$kernel_source/scripts/config" --file "$output_dir/.config" --enable "$symbol"
done
"$kernel_source/scripts/config" --file "$output_dir/.config" --disable ZRAM_DEF_COMP_LZORLE
kernel_make olddefconfig
# Fail before the expensive build if the locked BSP loses graphics support.
for symbol in DRM DRM_VERISILICON STARFIVE_INNO_HDMI DRM_IMG_ROGUE SWAP ZRAM_BACKEND_LZ4 VT VT_CONSOLE FRAMEBUFFER_CONSOLE DRM_FBDEV_EMULATION USB_HID; do
    grep -qx "CONFIG_${symbol}=y" "$output_dir/.config" \
        || die "required BSP option missing: CONFIG_$symbol"
done
grep -qx "CONFIG_ZRAM=m" "$output_dir/.config" \
    || die "required zram module missing: CONFIG_ZRAM=m"
kernel_make -j"$jobs" Image modules dtbs

build_desktop_dtb() {
if [[ "$board" == mars ]]; then
    command -v dtc >/dev/null 2>&1 || die "missing dtc"
    "${cross_compile}gcc" -E -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
        -I "$kernel_source/arch/riscv/boot/dts/starfive" \
        -I "$kernel_source/include" \
        "$REPO_ROOT/dts/mars/desktop.dts" -o "$output_dir/mars-desktop.dts"
    dtc -I dts -O dtb -o "$output_dir/arch/riscv/boot/dts/starfive/$KERNEL_DTB" \
        "$output_dir/mars-desktop.dts"
fi
}

patch_8g_memory_dtb() {
    local dtb_path memory_reg
    command -v fdtput >/dev/null 2>&1 || die "missing fdtput"
    command -v fdtget >/dev/null 2>&1 || die "missing fdtget"
    dtb_path="$output_dir/arch/riscv/boot/dts/starfive/$KERNEL_DTB"
    [[ -f "$dtb_path" ]] || die "missing selected DTB: $dtb_path"

    # Both target boards in this project are the 8GB variants. The locked BSP
    # DTS defaults to a 4GB memory node, while U-Boot has already verified the
    # actual 8GB LPDDR4 population. Keep the patch explicit and validate it.
    fdtput -t x "$dtb_path" /memory@40000000 reg 0 40000000 2 0
    memory_reg=$(fdtget -t x "$dtb_path" /memory@40000000 reg)
    [[ "$memory_reg" == "0 40000000 2 0" ]] \
        || die "selected DTB does not describe 8GB RAM: $memory_reg"
}

build_desktop_dtb
patch_8g_memory_dtb

package_dir="$REPO_ROOT/$OUTPUT_ROOT/$board/packages"
package_output_root="$REPO_ROOT/$OUTPUT_ROOT/$board"
mkdir -p "$package_dir"
kernel_make KBUILD_DEBARCH=riscv64 KDEB_PKGVERSION="$KERNEL_PACKAGE_VERSION" \
    DPKG_FLAGS=-d \
    -j"$jobs" bindeb-pkg
# Packaging may invoke dtbs again; restore the board-specific desktop DTB
# consumed by the image assembler and validate the final output.
build_desktop_dtb
patch_8g_memory_dtb
dtb_path="$output_dir/arch/riscv/boot/dts/starfive/$KERNEL_DTB"
for node in /display-subsystem /soc/dc8200@29400000 /soc/hdmi@29590000 /soc/gpu@18000000; do
    [[ "$(fdtget "$dtb_path" "$node" status)" == okay ]] \
        || die "graphics node disabled: $node"
done
compatible=$(fdtget "$dtb_path" / compatible)
[[ " $compatible " == *" $KERNEL_DTB_COMPATIBLE "* ]] \
    || die "DTB compatible does not match board: $compatible"

shopt -s nullglob
deb_files=("$package_output_root"/*.deb)
package_metadata=("$package_output_root"/*.buildinfo "$package_output_root"/*.changes)
shopt -u nullglob
[[ ${#deb_files[@]} -gt 0 ]] || die "kernel build produced no Debian packages"
for deb_file in "${deb_files[@]}"; do
    install -m 0644 "$deb_file" "$package_dir/"
done
for metadata_file in "${package_metadata[@]}"; do
    install -m 0644 "$metadata_file" "$package_dir/"
done

dtb_path="$output_dir/arch/riscv/boot/dts/starfive/$KERNEL_DTB"
[[ -f "$dtb_path" ]] || die "kernel build did not produce $KERNEL_DTB"

kernel_release_file="$output_dir/include/config/kernel.release"
[[ -s "$kernel_release_file" ]] || die "kernel release file is missing: $kernel_release_file"
kernel_release=$(<"$kernel_release_file")
printf 'kernel build complete: %s (%s), packages: %s\n' "$board" "$kernel_release" "$package_dir"
