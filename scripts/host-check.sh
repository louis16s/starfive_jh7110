#!/usr/bin/env bash
set -Eeuo pipefail

readonly REQUIRED_COMMANDS=(
    bash git python3 curl make awk sed find sort rsync mmdebstrap qemu-riscv64-static
    riscv64-linux-gnu-gcc dtc dpkg-deb depmod chroot sfdisk losetup truncate
    mkfs.vfat mkfs.ext4 mount umount blkid realpath xz sha256sum sync
)
missing=0

for command_name in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "MISSING command: $command_name" >&2
        missing=1
    fi
done

python3 - <<'PY'
try:
    import yaml
except ImportError as exc:
    raise SystemExit(f"MISSING Python module: yaml ({exc})")
print("OK Python module: yaml")
PY

if [[ "$missing" -ne 0 ]]; then
    exit 1
fi

host_arch=$(uname -m)
if [[ "$host_arch" != x86_64 ]]; then
    echo "WARN host architecture is $host_arch; CI baseline is x86_64" >&2
fi

echo "host prerequisites OK: $host_arch"
