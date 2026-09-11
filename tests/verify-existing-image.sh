#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "FAIL: verify-existing-image line $LINENO" >&2' ERR
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo"
[[ $(id -u) == 0 ]] || { echo 'Linux root required' >&2; exit 1; }
audit=$(mktemp -d "$repo/build/.verify.XXXXXX")
loop=
cleanup() {
    if mountpoint -q "$audit/root"; then umount "$audit/root"; fi
    if mountpoint -q "$audit/boot"; then umount "$audit/boot"; fi
    if [[ -n "$loop" ]]; then losetup -d "$loop"; fi
}
trap cleanup EXIT

bash scripts/build-gpu-package.sh mars
# Test the actual GPU package against a freshly bootstrapped Debian layout.
# shellcheck source=/dev/null
source configs/common.conf
mmdebstrap --mode=root --architectures=riscv64 --variant=minbase \
    --keyring=/usr/share/keyrings/debian-archive-keyring.gpg \
    --include=systemd-sysv --aptopt='Acquire::Check-Valid-Until "false"' \
    --aptopt='Acquire::Retries "3"' trixie "$audit/minimal" "$DEBIAN_SNAPSHOT"
ls -ld "$audit/minimal/lib" "$audit/minimal/bin" "$audit/minimal/sbin"
gpu=(build/mars/packages/jh7110-pvr-rogue_*.deb)
[[ ${#gpu[@]} == 1 && -s "${gpu[0]}" ]]
install -m 0644 "${gpu[0]}" "$audit/minimal/tmp/gpu.deb"
chroot "$audit/minimal" dpkg --install /tmp/gpu.deb
[[ -L "$audit/minimal/lib" && $(readlink "$audit/minimal/lib") == usr/lib ]]
[[ -s "$audit/minimal/lib/ld-linux-riscv64-lp64d.so.1" ]]
echo 'PASS: fresh Debian and GPU installation preserve runtime loader'

# Fixed historical fixture: this image reproduced the broken /lib regression.
base=https://github.com/louis16s/starfive_jh7110/releases/download/jh7110-build-36
curl --fail --location --retry 3 --max-time 300 "$base/jh7110-desktop-mars-8g.img.xz" -o "$audit/image.xz"
printf '%s  %s\n' d14a7796786417528e124557aa99cbcdfff51ad0c48710be39edbb52b39e69ee "$audit/image.xz" | sha256sum -c -
xz -dk "$audit/image.xz"
loop=$(losetup --find --show --partscan "$audit/image")
udevadm settle
mkdir -p "$audit/root" "$audit/boot"
mount -o ro,noload "${loop}p2" "$audit/root"
mount -o ro "${loop}p1" "$audit/boot"
rootfs=build/mars/rootfs/rootfs
[[ ! -e "$rootfs" ]]
mkdir -p "$rootfs" build/mars/kernel/arch/riscv/boot/dts/starfive build/mars/kernel/include/config
rsync -aH "$audit/root/" "$rootfs/"
kernel=build/mars/packages/linux-image-6.12.5+_1.0.0_riscv64.deb
curl --fail --location --retry 3 --max-time 120 "$base/linux-image-6.12.5%2B_1.0.0_riscv64.deb" -o "$kernel"
printf '%s  %s\n' 2970df69f050a4370e4cfcdc34e1004a62cefe78663ef84a46e25c37262459b0 "$kernel" | sha256sum -c -
install -m 0644 "$audit/boot/Image" build/mars/kernel/arch/riscv/boot/Image
install -m 0644 "$audit/boot/dtbs/6.12.5+/jh7110-milkv-mars.dtb" build/mars/kernel/arch/riscv/boot/dts/starfive/
printf '6.12.5+\n' > build/mars/kernel/include/config/kernel.release
bash scripts/install-kernel-into-rootfs.sh mars
bash scripts/build-image.sh mars
echo 'PASS: real kernel payload, target runtime, initrd and ext4 image assembly'
