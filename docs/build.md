# Build Workflow

The current pipeline produces board-specific image build candidates. A successful CI build proves source, package, rootfs and image assembly; boot and hardware status still require the board acceptance tests.

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

`verify-source-lock.sh` resolves the recorded branch/tag and reports when that human-readable reference has moved. The full commit SHA remains authoritative; `fetch-sources.sh` must fetch and verify that exact SHA before any build. A missing or moved reference therefore does not silently change the build. The PVR archive is downloaded separately by the `gpu-package` target and is verified against its locked SHA256 before packaging.

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
make BOARD=visionfive2 gpu-package
```

The kernel target also invokes the kernel `bindeb-pkg` target with a fixed Debian package version and copies the resulting `.deb` files to `build/<board>/packages/`. The locked vendor kernel generates a Debian build dependency on the historical `debhelper-compat (= 12)` and an unqualified target-architecture `libssl-dev`; Ubuntu 24.04 does not satisfy that exact cross-architecture metadata even when the native build tools are installed, so the CI installs the current debhelper implementation and passes `DPKG_FLAGS=-d` only to skip the metadata pre-check. The actual Debian packaging rules still run and failures remain fatal. It refuses to report success if the selected board DTB is absent. The package names remain kernel-release-derived (for example `linux-image-<release>.deb` and `linux-headers-<release>.deb`) so Debian package metadata stays truthful.

Mars uses the locked upstream U-Boot reference because the StarFive vendor U-Boot tree does not contain the Mars DTB in its board configuration. The Mars profile and build checks reject a missing Mars DTB rather than silently falling back to VisionFive 2.

The JH7110 SPI-NOR boot chain has two separate files. The SPL file is
`u-boot/spl/u-boot-spl.bin.normal.out` and is written at offset `0x0`; the
second-stage payload is `u-boot/u-boot.itb` and is written at offset
`0x100000`. `u-boot.img`/`u-boot-dtb.img` are legacy U-Boot outputs and must
not be flashed as the Mars SPI payload. The build now fails if the FIT
payload is missing or invalid and CI publishes `u-boot.itb` explicitly.

From an already booted Mars Linux system, use the board's MTD partitions:

```sh
sudo apt install mtd-utils
cat /proc/mtd
sudo flashcp -v mars_u-boot-spl.bin.normal.out /dev/mtd0
sudo flashcp -v mars_visionfive2_fw_payload.img /dev/mtd1
```

The two official `mars_*` files above are the vendor recovery/update pair.
For this project's build, use the locked project SPL and `u-boot.itb` pair,
then reset the saved U-Boot environment with `env default -f -a` and
`env save`. If SPI boot is already damaged, follow the official Mars UART
recovery procedure and hold the Mars upgrade key while powering the board;
the serial port must show the XMODEM `CCCC` prompt before sending the SPL.
Do not use a VisionFive 2 bootloader or DTB on Mars.

## Phase 4 Debian rootfs

The rootfs builder uses the Debian Trixie snapshot recorded in `configs/common.conf` and installs the same package manifests for both boards. Board identity is written separately to `/etc/jh7110/board.conf`; no VisionFive 2 DTB or board-specific rootfs is reused for Mars.

The Linux build host must provide `mmdebstrap`, `qemu-riscv64-static`, `rsync`, the `riscv64-linux-gnu` cross compiler and `dtc`:

```sh
make BOARD=visionfive2 rootfs
make BOARD=mars rootfs
```

The result is a directory rootfs under `build/<board>/rootfs/rootfs`. The builder removes machine-id and SSH host keys, enables the common services, creates a locked `root` account, installs the selected board's licensed `jh7110-pvr-rogue` package when it has been built, and installs `jh7110-firstboot.service`. On local first boot, an English `whiptail` screen asks for and confirms a root password on the HDMI text console before LightDM starts; the desktop remains localized separately. The service then sets the board hostname, initializes locale and identity, grows the root filesystem when the image layout permits it, and records a hardware report when `jh7110-info` is present.

The default timezone is `Asia/Shanghai` (UTC+8). Both `zh_CN.UTF-8` and
`en_US.UTF-8` are generated; the default locale is `zh_CN.UTF-8` with the
English fallback chain `zh_CN:zh:en_US:en`. These values are written to the
rootfs and recorded in `build-manifest.txt`.

The build uses the locked Debian snapshots above. The installed image uses
deb822 APT sources with the Tsinghua mainland mirror first and Debian official
endpoints second, so normal `apt update`/`apt upgrade` can fall back when the
mainland mirror is unavailable. `jh7110-mirror status` checks the mainland
endpoints; `jh7110-mirror mainland` and `jh7110-mirror official` change the
priority order without changing the locked build snapshot.

## Phase 5 removable-media image

The image assembler creates a GPT image with a 512 MiB FAT32 `/boot` partition and an ext4 root partition. The image size is a board-profile setting, not a target storage assumption. OpenSBI/U-Boot remain in the board's SPI-NOR boot path; the image carries the kernel, initrd, DTB and `extlinux.conf` only.

Before assembly, install one kernel package into the rootfs so that an initrd exists. An explicitly generated initrd can also be supplied:

```sh
sudo make BOARD=visionfive2 install-kernel
sudo make BOARD=visionfive2 image
sudo INITRD_PATH=/absolute/path/to/initrd.img make BOARD=visionfive2 image
sudo INITRD_PATH=/absolute/path/to/initrd.img make BOARD=mars image
```

The script refuses to assemble an image when the board DTB, kernel Image or initrd is missing. It writes the root partition PARTUUID into both `fstab` and `extlinux.conf`, so the image is not tied to `/dev/mmcblk*` naming.

## CI and releases

`.github/workflows/build.yml` uses Ubuntu 24.04 x86_64, caches the locked source checkouts, compiler objects and the PVR archive, builds each selected board independently, and uploads the compressed image, kernel `.deb` files, PVR `.deb` and manifest. `.github/workflows/release.yml` invokes the same reusable build on `v*` tags and publishes both board artifacts. The PVR package is generated from the exact StarFive archive in `sources.lock`; its redistribution is covered by the project owner's explicit license authorization and is recorded in the package `SOURCE` file.

CI build success is not a hardware acceptance result. GPU acceleration,
Vulkan/OpenGL, HDMI 1080p60, Wayland and audio must be tested on physical VF2
and Mars boards. The licensed PVR package is now integrated into the build,
but its package/install success cannot prove the board-specific kernel ABI,
firmware initialization or physical HDMI link; until those tests are recorded,
the image remains a desktop build candidate with possible board-specific
rendering issues.

## Build entry points

### CI performance

The failed run 34366689840 spent 6.7–8.8 minutes fetching sources,
12.6–13.8 minutes building bootloaders/kernel packages, and 11.5–12.8 minutes
building each rootfs. These are baseline measurements, not promised savings.

CI now saves locked source checkouts immediately after fetching and saves a
separate 1 GiB compiler cache per board before starting the rootfs. Kernel,
U-Boot and OpenSBI explicitly invoke ccache when `USE_CCACHE=1`; local builds
default to the compiler directly. Compiler content checking protects against
toolchain changes. A unique cache key per run allows new objects to be saved,
with prefix fallback to a previous cache. Cache statistics are printed after
compilation; compare warm-run timings with the baseline to measure benefit.

Single-board requests allocate only that board's job. Both boards remain
parallel for `all`. The unused standalone modules installation was removed;
`bindeb-pkg` still stages modules into the Debian image package. Uploads use
compression level zero because image and package payloads are already compressed.

The rootfs is still independently built under QEMU for each board. Sharing a
pristine rootfs and identical kernel outputs is a further optimization, but
requires separate artifact handoff and cache invalidation for package manifests,
snapshot, overlays, configuration and build scripts. Full rootfs caching has
not been enabled, so stale board identity and packages cannot bypass construction.
The fixed Debian Snapshot is retried up to three times with APT transport
retries; a transient 5xx response therefore does not immediately discard the
whole build.
The `debug` input currently labels the build; it does not yet select a distinct
kernel debug configuration.

```sh
./build.sh visionfive2 image
./build.sh mars image
make BOARD=visionfive2 image
make BOARD=mars image
```
