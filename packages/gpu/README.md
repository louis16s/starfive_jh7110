# JH7110 GPU package

This directory documents the generated Debian package; vendor binaries are
not committed to Git. `make BOARD=visionfive2 gpu-package` or
`make BOARD=mars gpu-package` downloads the exact archive named in
`sources.lock`, verifies its SHA256, and creates:

```text
build/<board>/packages/jh7110-pvr-rogue_1.19.6345021-3_riscv64.deb
```

The payload is the official StarFive `soft_3rdpart` IMG GPU archive at commit
`b60da16be1b36453aa46599889c28310fd148fb8`, DDK `1.19.6345021`, SHA256
`9dcaf2084b13e59c4e50a4a288f5de56f8e9ee631627a3e818591675bf61311a`:

- [StarFive soft_3rdpart](https://github.com/starfive-tech/soft_3rdpart)
- [Locked archive reference](https://github.com/starfive-tech/soft_3rdpart/blob/b60da16be1b36453aa46599889c28310fd148fb8/IMG_GPU/out/img-gpu-powervr-bin-1.19.6345021.tar.gz)

The package installs the vendor firmware and userspace, Vulkan ICD, OpenCL
ICD, test utilities and the official `rc.pvr` helper. It also enables
`jh7110-pvr.service`, which loads the board kernel's PVR modules before the
display manager. Debian supplies the Mesa GBM/EGL and Vulkan loader pieces.

The project owner has authorized redistribution of this payload. The package
keeps a `usr/share/doc/jh7110-pvr-rogue/SOURCE` audit record. Do not replace
the locked archive with an unpinned download or copy individual shared
objects manually.
