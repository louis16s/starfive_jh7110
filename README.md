# jh7110-desktop

Reproducible Debian Trixie desktop image engineering for:

* StarFive VisionFive 2 8GB (`visionfive2`)
* Milk-V Mars 8GB (`mars`)

The project is currently at the Phase 5/CI foundation. Phase 1 research and locked source decisions are in [`docs/research.md`](docs/research.md), [`docs/architecture.md`](docs/architecture.md), and [`sources.lock`](sources.lock). Phase 3 provides locked source checkout and BSP build entry points; Phase 4 provides the Debian rootfs builder; Phase 5 provides board-specific GPT image assembly. Hardware validation and vendor GPU/VPU integration remain explicit gates.

## Current commands

```sh
./build.sh visionfive2 check
./build.sh mars check
./build.sh all check
./build.sh visionfive2 rootfs
./build.sh mars rootfs
./build.sh visionfive2 install-kernel
./build.sh visionfive2 image
./build.sh visionfive2 compress
```

The commands validate board profiles and locked sources, build pinned boot and kernel sources, create the common Debian rootfs, install the packaged kernel, and assemble the board-specific image. The resulting images are CI build candidates; hardware acceptance remains pending until the board test matrix is executed.

## Status

The stable track starts from the locked StarFive JH7110 6.12 BSP. The Debian rootfs, GPU/VPU packages and image assembler are being built as separate modules. Vendor GPU/VPU binaries are license-gated and are not committed to this repository.

See [`docs/architecture.md`](docs/architecture.md) for the build graph and board separation rules.
