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
kernel_config="$kernel_source/scripts/config"
for symbol in VT VT_CONSOLE HW_CONSOLE FB FRAMEBUFFER_CONSOLE DRM_FBDEV_EMULATION HID HID_GENERIC USB_HID INPUT_EVDEV; do
    "$kernel_config" --file "$output_dir/.config" --enable "$symbol"
done
# Debian userspace expects seccomp: systemd's SystemCallFilter= sandboxing and
# the browser sandboxes are unavailable without it.  The BSP defconfig disables
# it (CONFIG_EXPERT is set), so it has to be turned back on here.
"$kernel_config" --file "$output_dir/.config" --enable SECCOMP
"$kernel_config" --file "$output_dir/.config" --enable SECCOMP_FILTER
# The tick rate and the default cpufreq governor are what a desktop feels.
# 100 Hz quantizes scheduling decisions to 10 ms, which shows up as input and
# compositor latency on the 1.5 GHz U74 cores; 250 Hz is the usual desktop
# tick.  schedutil ramps from the scheduler's own utilization instead of
# ondemand's 10 ms sampling window, and both governors stay built in, so
# `echo ondemand > /sys/.../scaling_governor` remains available for A/B tests.
"$kernel_config" --file "$output_dir/.config" --disable HZ_100
"$kernel_config" --file "$output_dir/.config" --enable HZ_250
"$kernel_config" --file "$output_dir/.config" --disable CPU_FREQ_DEFAULT_GOV_ONDEMAND
"$kernel_config" --file "$output_dir/.config" --enable CPU_FREQ_DEFAULT_GOV_SCHEDUTIL
# Both target boards are 8GB. Boards whose DTS declares no linux,cma node fall
# back to this built-in pool size, which has to hold the display, GPU and VPU
# buffers.
"$kernel_config" --file "$output_dir/.config" --set-val CMA_SIZE_MBYTES 512
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
# Fail before the expensive build if the locked BSP loses graphics support, the
# sandbox userspace needs, or the interactive settings applied above.
for symbol in DRM DRM_VERISILICON STARFIVE_INNO_HDMI DRM_IMG_ROGUE SWAP ZRAM_BACKEND_LZ4 VT VT_CONSOLE FRAMEBUFFER_CONSOLE DRM_FBDEV_EMULATION USB_HID CMA DMA_CMA SECCOMP SECCOMP_FILTER CPU_FREQ_DEFAULT_GOV_SCHEDUTIL; do
    grep -qx "CONFIG_${symbol}=y" "$output_dir/.config" \
        || die "required BSP option missing: CONFIG_$symbol"
done
grep -qx "CONFIG_ZRAM=m" "$output_dir/.config" \
    || die "required zram module missing: CONFIG_ZRAM=m"
grep -qx "CONFIG_HZ=250" "$output_dir/.config" \
    || die "kernel tick rate is not 250 Hz: $(grep '^CONFIG_HZ=' "$output_dir/.config" || echo 'CONFIG_HZ unset')"
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

# Display, GPU and VPU allocations all come out of the CMA pool.  A board DTS
# without a linux,cma node does not fail to build; it falls back to the small
# built-in default, and the failure then appears on the desk as an HDMI mode
# that will not set or as stutter while the kernel migrates pages out of an
# exhausted pool.  VisionFive 2 supplies this node itself; Mars needs the one
# in dts/mars/desktop.dts, so both are checked here.
cma_compatible=$(fdtget "$dtb_path" /reserved-memory/linux,cma compatible 2>/dev/null || true)
cma_size=$(fdtget -t x "$dtb_path" /reserved-memory/linux,cma size 2>/dev/null || true)
[[ "$cma_compatible" == shared-dma-pool ]] \
    || die "DTB has no CMA pool for the display and GPU: /reserved-memory/linux,cma"
fdtget "$dtb_path" /reserved-memory/linux,cma linux,cma-default >/dev/null 2>&1 \
    || die "DTB CMA pool is not the default pool: /reserved-memory/linux,cma"
read -r cma_hi cma_lo <<<"$cma_size"
if [[ ! "$cma_hi" =~ ^[0-9a-f]+$ || ! "$cma_lo" =~ ^[0-9a-f]+$ ]]; then
    die "cannot read the CMA pool size: '$cma_size'"
fi
cma_mib=$(((16#$cma_hi * 4294967296 + 16#$cma_lo) / 1048576))
(( cma_mib >= 256 )) || die "CMA pool is too small for the desktop: ${cma_mib} MiB"
printf 'kernel: CMA pool %s MiB\n' "$cma_mib"

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
