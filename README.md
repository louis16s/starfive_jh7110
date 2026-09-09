# jh7110-desktop

Reproducible Debian Trixie desktop image engineering for:

* StarFive VisionFive 2 8GB (`visionfive2`)
* Milk-V Mars 8GB (`mars`)

The project is currently at Phase 4. Phase 1 research and locked source decisions are in [`docs/research.md`](docs/research.md), [`docs/architecture.md`](docs/architecture.md), and [`sources.lock`](sources.lock). Phase 3 provides locked source checkout and BSP build entry points; Phase 4 provides the Debian rootfs builder. Hardware image assembly remains intentionally gated until the boot artifacts are validated on both boards.

## Current commands

```sh
./build.sh visionfive2 check
./build.sh mars check
./build.sh all check
./build.sh visionfive2 rootfs
./build.sh mars rootfs
```

These commands validate board profiles, the capability matrix, host prerequisites and the locked source references. Image creation is intentionally not enabled until the Phase 3 kernel/bootloader packages are implemented and tested.

## Status

The stable track starts from the locked StarFive JH7110 6.12 BSP. The Debian rootfs, GPU/VPU packages and image assembler are being built as separate modules. Vendor GPU/VPU binaries are license-gated and are not committed to this repository.

See [`docs/architecture.md`](docs/architecture.md) for the build graph and board separation rules.
