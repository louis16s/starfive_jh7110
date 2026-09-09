# Build Workflow

Phase 2 provides validation only. It does not claim to produce a bootable image yet.

## Host baseline

The supported build host is Ubuntu 24.04 x86_64. The final build will install the cross compiler, qemu-user-static/binfmt, image tools, device-tree compiler, `mmdebstrap`/`debootstrap`, `xz`, `squashfs-tools`, `dosfstools`, `parted`/`sgdisk`, `shellcheck` and Python YAML support in a dedicated CI environment.

## Validate a profile

```sh
./build.sh visionfive2 profile
./build.sh mars profile
```

## Validate the Phase 2 environment and sources

```sh
./build.sh visionfive2 check
./build.sh mars check
```

`verify-source-lock.sh` resolves the recorded branch/tag and rejects a moving or changed revision. Vendor binary artifacts are identified but are not downloaded by this phase.

## Phase 3 source and build entry points

The source fetcher checks out the exact SHA from `sources.lock` in `sources/`:

```sh
make BOARD=visionfive2 fetch
make BOARD=mars fetch
```

Then the individual BSP components can be built when an Ubuntu x86_64 host with a RISC-V cross toolchain is available:

```sh
make BOARD=visionfive2 uboot
make BOARD=visionfive2 opensbi
make BOARD=visionfive2 kernel
```

The kernel target also invokes the kernel `bindeb-pkg` target with a fixed Debian package version and copies the resulting `.deb` files to `build/<board>/packages/`. It refuses to report success if the selected board DTB is absent. The package names remain kernel-release-derived (for example `linux-image-<release>.deb` and `linux-headers-<release>.deb`) so Debian package metadata stays truthful.

Mars uses the locked upstream U-Boot reference because the StarFive vendor U-Boot tree does not contain the Mars DTB in its board configuration. The Mars profile and build checks reject a missing Mars DTB rather than silently falling back to VisionFive 2.

## Phase 4 Debian rootfs

The rootfs builder uses the Debian Trixie snapshot recorded in `configs/common.conf` and installs the same package manifests for both boards. Board identity is written separately to `/etc/jh7110/board.conf`; no VisionFive 2 DTB or board-specific rootfs is reused for Mars.

The Linux build host must provide `mmdebstrap`, `qemu-riscv64-static`, `rsync`, the `riscv64-linux-gnu` cross compiler and `dtc`:

```sh
make BOARD=visionfive2 rootfs
make BOARD=mars rootfs
```

The result is a directory rootfs under `build/<board>/rootfs/rootfs`. The builder removes machine-id and SSH host keys, enables the common services, creates a locked `jh7110` sudo-capable account, and installs `jh7110-firstboot.service`. The first-boot service sets the board hostname, initializes locale and identity, grows the root filesystem when the image layout permits it, and records a hardware report when `jh7110-info` is present.

## Phase 5 removable-media image

The image assembler creates a GPT image with a 512 MiB FAT32 `/boot` partition and an ext4 root partition. The image size is a board-profile setting, not a target storage assumption. OpenSBI/U-Boot remain in the board's SPI-NOR boot path; the image carries the kernel, initrd, DTB and `extlinux.conf` only.

Before assembly, install one kernel package into the rootfs so that an initrd exists, or pass an explicitly generated initrd:

```sh
sudo INITRD_PATH=/absolute/path/to/initrd.img make BOARD=visionfive2 image
sudo INITRD_PATH=/absolute/path/to/initrd.img make BOARD=mars image
```

The script refuses to assemble an image when the board DTB, kernel Image or initrd is missing. It writes the root partition PARTUUID into both `fstab` and `extlinux.conf`, so the image is not tied to `/dev/mmcblk*` naming.

## Planned build entry points

After Phase 3–5, these commands will become enabled:

```sh
./build.sh visionfive2
./build.sh mars
make BOARD=visionfive2 image
make BOARD=mars image
```

Until then, `image` exits intentionally so a partial scaffold cannot be mistaken for a tested image builder.
