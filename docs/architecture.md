# JH7110 Desktop Architecture

Status: Phase 1 design baseline
Boards: `visionfive2` and `mars`
Userspace: one Debian Trixie riscv64 rootfs
Kernel strategy: stable StarFive 6.12 BSP first, mainline experiments isolated

## Design goals

The project is a source-driven image builder, not a vendor image repackager. One Debian rootfs and one package policy are shared by both boards. A board profile selects only the parts that truly differ: bootloader output, DTB, firmware inputs, storage layout, boot arguments, PHY/power settings, capability expectations and small patches.

The order of priorities is:

1. Hardware functionality and recoverability.
2. Stable boot and package upgrades.
3. Reproducibility and maintainability.
4. Gradual upstreaming.

The stable BSP and mainline experimental tracks must be buildable independently. An experimental upstream GPU or VPU change must never silently become part of the stable release image.

## Layered build model

```text
sources.lock
      |
      v
source cache + verified commits + license gate
      |
      +--> board profile ------------------------------+
      |    (VF2 or Mars, DTB, U-Boot, layout, caps)    |
      |                                                v
      +--> kernel + patches + config ----------> Debian kernel .deb
      +--> OpenSBI + U-Boot + DTB -------------> board boot artifacts
      +--> mmdebstrap/debootstrap --------------> common Debian rootfs
      +--> packaged GPU/VPU inputs --------------> optional BSP packages
      +--> image assembler ----------------------> GPT .img
                                                |
                                                +--> manifest, logs, checksums
```

The build graph will be implemented as small scripts and Make targets. `build.sh` is only a user-facing dispatcher; it must not contain the implementation of rootfs, kernel, bootloader or image assembly.

## Repository layout for later phases

```text
jh7110-desktop/
├── Makefile
├── build.sh
├── sources.lock
├── configs/
│   ├── common.conf
│   ├── visionfive2.conf
│   ├── mars.conf
│   ├── kernel-common.config
│   ├── kernel-visionfive2.config
│   ├── kernel-mars.config
│   └── hardware-matrix.yaml
├── board/
│   ├── visionfive2/
│   │   ├── profile.conf
│   │   ├── u-boot/
│   │   ├── dts/
│   │   ├── firmware/
│   │   └── layout/
│   └── mars/
│       ├── profile.conf
│       ├── u-boot/
│       ├── dts/
│       ├── firmware/
│       └── layout/
├── kernel/
│   ├── patches/common/
│   ├── patches/visionfive2/
│   ├── patches/mars/
│   └── packaging/
├── rootfs/
│   ├── packages/
│   ├── overlay/
│   ├── scripts/
│   └── services/
├── packages/
│   ├── gpu/
│   ├── vpu/
│   ├── mesa/
│   ├── ffmpeg/
│   └── gstreamer/
├── scripts/
│   ├── fetch-sources.sh
│   ├── build-rootfs.sh
│   ├── build-kernel.sh
│   ├── build-bootloader.sh
│   ├── build-packages.sh
│   ├── build-image.sh
│   ├── compress-image.sh
│   └── generate-manifest.sh
├── tools/
├── tests/
├── docs/
└── .github/workflows/
```

The Phase 1 commit intentionally contains only the research and architecture decisions. Code and generated artifacts are added in subsequent phases after the sources and licenses are accepted.

## Board profile contract

Every board profile must define these fields before a build can start:

* `TARGET_BOARD`: `visionfive2` or `mars`.
* Exact kernel, U-Boot, OpenSBI and DTB source/revision.
* DTB filename and `/boot/dtbs/<kernel-release>/` install path.
* U-Boot/SPL/OpenSBI output names and SPI offsets.
* Boot media and root device policy.
* Required firmware and license status.
* Memory expectation and 8GB validation status.
* Capability matrix reference and PASS/WARN/SKIP rules.
* Board-specific kernel fragments/patches.

The build must fail if a profile requests another board's DTB or bootloader, if the DTB model/compatible does not match the board, or if a required proprietary input has no accepted license record.

## Boot chain

The first boot design is:

```text
SPI NOR: board-specific SPL
    -> OpenSBI firmware payload
    -> board-specific U-Boot
    -> extlinux.conf on the boot partition
    -> selected Debian kernel + initrd + board DTB
    -> rootfs partition
```

The kernel path is package-managed. `/boot` contains `Image` or `vmlinuz`, initrds, versioned DTBs and `extlinux/extlinux.conf`. The configuration must allow at least a current and previous kernel entry. U-Boot must not embed a hard-coded rootfs or kernel path in source code.

Although upstream U-Boot documents shared VisionFive 2/Mars binaries with board detection, this project will keep board-labelled build outputs and independent validation. Mars will explicitly select `jh7110-milkv-mars.dtb`; a VF2 fallback is a build/test error, not a recovery strategy.

## Kernel strategy

### Stable BSP

The stable branch starts from the locked StarFive 6.12 BSP. Common kernel configuration enables the JH7110 platform, SMP, 8GB-capable memory handling, CMA, DRM/KMS, HDMI/display, storage, USB, PCIe/NVMe, networking, audio, containers and diagnostics. Board fragments only change real board differences.

Kernel packaging produces a normal Debian `linux-image-jh7110` package, headers and DTBs. Modules are installed through dpkg; no build step may rely on copying random modules into a rootfs.

### Mainline experimental

The experimental branch tracks the locked upstream Linux/U-Boot references from `sources.lock`. It can be used for DTS cleanup, upstream display, upstream PowerVR and upstream media work, but it is not a release input until the hardware acceptance tests pass.

## GPU and VPU boundaries

The graphics boundary is a package interface, not a directory of copied shared objects.

Stable BSP GPU package responsibilities:

* match the StarFive PVR kernel module to the exact kernel build;
* install firmware in `/lib/firmware` with checksums;
* install EGL/GLES/GBM/Vulkan ICD files through dpkg or a documented external package;
* provide an explicit renderer/version report;
* fail or WARN when only llvmpipe is active.

Stable BSP VPU package responsibilities:

* install WAVE511 decode and WAVE420L encode modules/firmware;
* expose the intended V4L2/codec path to FFmpeg/GStreamer/mpv/VLC;
* identify the selected hardware decoder/encoder in test output;
* reject CPU-only decoding as a hardware PASS.

The proprietary input gate is evaluated before packaging. If redistribution is disallowed, CI may build a headless or software-rendered image only when explicitly requested, but it must not publish an image that claims GPU/VPU support.

## Debian rootfs

The rootfs is generated from Debian Trixie `riscv64` using a pinned snapshot and deb822 sources:

* Debian main, contrib/non-free-firmware only when required and documented.
* Debian security snapshot.
* No copied vendor rootfs.
* `systemd`, NetworkManager, SSH, sudo, journald, udev, dbus, polkit, locales and PipeWire/WirePlumber as normal packages.
* `zh_CN.UTF-8` and `en_US.UTF-8` generated explicitly.
* Board hostname set by `jh7110-firstboot.service`, not baked permanently into a common rootfs.

The rootfs is the same package manifest for both boards. Board-specific packages are additive and selected by profile. APT remains the owner of ordinary Debian libraries and desktop components.

## Image layout

Initial image layout is GPT with a board-independent partition contract:

| Partition | Suggested size | Filesystem | Purpose |
| --- | ---: | --- | --- |
| p1 | 512 MiB | FAT32 | U-Boot-visible boot files, DTBs, kernels, initrds |
| p2 | remaining image | ext4 | Debian rootfs |

The image file is intentionally not sized to 8GB RAM. It has a minimum build size and supports larger target media. `growpart` and `resize2fs` run once by `jh7110-firstboot.service`; the service records completion and disables itself. Bootloader SPI contents are separate board artifacts and are not blindly embedded into a generic disk image.

## Services and first boot

`jh7110-firstboot.service` performs only idempotent first-boot work:

1. Prompt for a root password on tty1, before anything else that can fail. The
   image ships a locked root account, so any later failure would otherwise
   strand the user at a login prompt with no usable account.
2. Set board-specific hostname.
3. Configure locale/timezone defaults.
4. Ensure machine-id and SSH host keys exist.
5. Grow the root filesystem.
6. Generate a hardware report.
7. Record completion and disable itself.

The service is `Type=oneshot` with `TimeoutStartSec=infinity`: a finite start
timeout can fire while the password dialog is still on screen, which kills the
prompt and leaves root locked. `Before=getty@tty1.service` plus
`Conflicts=getty@tty1.service` is the "this unit owns tty1 until it finishes"
idiom; adding `After=` for the same unit would contradict the `Before=` and make
systemd drop one of the jobs.

`jh7110-info` is an installed read-only report; `jh7110-config` and
`jh7110-selftest` are not implemented yet. A report tool reads board identity
from the DT `compatible`/`model`, kernel and firmware metadata, and never infers
Mars from a VisionFive 2 compatible string. It must exit zero on a board that is
missing an attribute, because firstboot runs it under `set -e` to record the
hardware report.

## CI and reproducibility

GitHub Actions will use an x86_64 Ubuntu runner and cache source archives, ccache, cross tools and Debian packages. Every job records:

* repository/ref/commit for every source;
* Debian Release metadata hashes and snapshot URLs;
* compiler/tool versions;
* board profile and kernel config hash;
* build command and environment summary;
* license gate result;
* build logs and artifact SHA-256.

Both payload builds are timestamp-pinned, so two builds of the same commit
produce identical bytes and a published digest can be checked by rebuilding it
rather than by trusting the manifest. `scripts/lib/build-timestamps.sh` derives
`SOURCE_DATE_EPOCH` from the commit date — the same value the manifest records
as `source_date_epoch` — and exports `KBUILD_BUILD_TIMESTAMP` along with
`KBUILD_BUILD_USER`/`KBUILD_BUILD_HOST`. U-Boot formats its version string from
the epoch; the kernel stamps its built-in initramfs cpio with it, and without
the user/host overrides it would take those from `whoami`/`uname -n`, which put
the CI runner's hostname inside every released kernel banner. One timestamp
sits outside those switches: binman has no `SOURCE_DATE_EPOCH` handling and lets
`-t` on mkimage stamp the FIT's `/timestamp` property from the input file's
mtime, so `scripts/build-uboot.sh` rewrites that property afterwards. The
rewrite is an in-place, size-preserving four-byte overwrite — the FIT's image
data follows the device tree, so repacking the blob the way `fdtput` does would
move that data and invalidate every data-offset in the file — and it refuses to
write unless exactly those four bytes change.

`workflow_dispatch` accepts `board=all|visionfive2|mars` and `build_type=release|debug`. A `preflight` job rejects anything else before the matrix starts: `workflow_call` passes a free-form board, and an unknown value used to fall through the matrix expression to "build both boards" while every guarded step evaluated false, so the job reported success having built nothing. A release job must build each requested board in a clean output directory. A failure in one board must not publish the other board under the wrong filename.

Publishing is opt-in (`publish_release` defaults to false) and the release asset
list is generated from the files that were actually staged, not from extension
globs, so `fail_on_unmatched_files` can be enabled without a board-specific run
failing on the other board's patterns.

## Required validation gates

Before a board can be marked release-ready:

* static: shell syntax, ShellCheck, YAML parse, lock-file validation, DTB/model separation;
* build: kernel packages, U-Boot/SPL/OpenSBI, DTB, rootfs and GPT image;
* boot: serial boot, Debian login, 8GB RAM, SSH and network;
* display: DRM/KMS, HDMI 1080p60, desktop session;
* graphics: `/dev/dri`, PVR module, EGL/OpenGL ES/Vulkan, no llvmpipe unless explicitly WARNed;
* media: hardware H.264/H.265 decode with decoder identity and CPU budget;
* I/O: USB, SD/eMMC, VF2 NVMe, Mars SKIP for NVMe unless hardware evidence changes;
* audio: HDMI/USB/board path as applicable;
* upgrade: `apt update`, `apt upgrade`, previous-kernel boot entry and rollback;
* safety: no destructive test unless explicitly invoked by a human.

## Phased implementation map

| Phase | Deliverable | Exit evidence |
| ---: | --- | --- |
| 1 | research, lock, architecture | this commit |
| 2 | profiles, source cache, host checks | both profiles parse and refs verify |
| 3 | BSP OpenSBI/U-Boot/kernel packages | both kernels build and DTBs are distinct |
| 4 | Debian Trixie rootfs | apt-managed headless rootfs |
| 5 | headless VF2/Mars images | UART/SSH/Ethernet/USB/storage |
| 6 | DRM/HDMI/desktop | physical 1080p60 test |
| 7 | GPU/Wayland | PVR/Vulkan/EGL test with license gate |
| 8 | VPU/media | hardware decoder evidence |
| 9 | audio/browser/camera | device-specific tests and WARN policy |
| 10 | diagnostics/selftest | safe capability-aware reports |
| 11 | GitHub Actions | clean x86_64 runner build |
| 12 | release/docs/rollback | signed-off artifacts, manifest, notes |
