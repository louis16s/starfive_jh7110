# JH7110 Desktop Phase 1 Research

Research date: 2026-09-09
Decision scope: StarFive VisionFive 2 8GB and Milk-V Mars 8GB
Target userspace: Debian Trixie riscv64
Primary objective: choose a reproducible functionality-first baseline without conflating upstream support with vendor support.

## Executive decision

The first implementation baseline is the StarFive `JH7110_VF2_6.12_v6.0.0` SDK release, pinned in [`sources.lock`](../sources.lock), with Debian Trixie built separately by `mmdebstrap` or `debootstrap`. The SDK tag resolves to commit `7f1bacc7c3969ea7ae7da4b9f3ca3fbd6e39c142`; its submodules pin the 6.12 StarFive kernel, U-Boot, OpenSBI and third-party software commits recorded in the lock file.

The same kernel source can carry both board DTBs, but board-specific U-Boot, DTB selection, power/PHY settings, boot media and capability metadata must remain separate. Mars is not treated as a renamed VisionFive 2 image. The current official Mars SDK is useful evidence for board bring-up but is a Linux 5.15-era Buildroot/FIT project and is not imported as the Debian rootfs or build system.

The stable desktop GPU path is vendor-dependent. StarFive's third-party repository explicitly describes `IMG_GPU` as binary and not open source, and its 6.12 kernel branch contains a vendor `DRM_IMG_ROGUE` path for `PVR_SYSTEM=sf_7110`. Current Mesa documentation lists BXE-4-32 BVNC `36.50.54.182` as unsupported and not under active development. Therefore the stable image must use a license-gated StarFive PVR DDK/userspace integration; upstream Mesa/PowerVR is a separate experimental track and cannot be used as proof of GPU functionality.

## Sources and findings

### StarFive VisionFive 2 SDK and 6.12 BSP

Official repository: <https://github.com/starfive-tech/VisionFive2>
Selected release: `JH7110_VF2_6.12_v6.0.0`
Selected commit: `7f1bacc7c3969ea7ae7da4b9f3ca3fbd6e39c142`

The release notes state that the 6.12 SDK supports VisionFive 2 and VisionFive 2 Lite, automatic board/DTB selection for the Lite variant, single-image boot from SD/eMMC/NVMe, and the 6.12 kernel line. They also document known issues including AC108 recording on 6.12 and failures in selected GPU Vulkan CTS cases. Those notes make this a better functionality baseline than immediately moving to a fully mainline stack.

The SDK's `.gitmodules` and release tree resolve to:

| Component | Revision | Use in this project |
| --- | --- | --- |
| Linux | `4cecf169f38eb94b40e307f5f870055e4d9d64f1` | Stable-BSP kernel baseline |
| U-Boot | `c4c67bb66ae6f41c98537d18cf5c3abc8b97b8e4` | VF2 bootloader reference |
| OpenSBI | `1725bd71080960290fdde4499a58c25c09d5c8ee` | Stable-BSP firmware |
| Buildroot | `70e7c10de57195237ee4ae95f3c87637a39429b0` | Reference only; not the Debian rootfs |
| soft_3rdpart | `b60da16be1b36453aa46599889c28310fd148fb8` | PVR/VPU reference and license inventory |

The SDK Makefile generates a FIT image, SPL and a firmware payload, but it is Buildroot-centric. The new project will reuse the source revisions and board knowledge, while replacing the rootfs/image assembly with modular Debian packaging and GPT image creation.

### Linux 6.12 BSP and device tree

The selected StarFive kernel contains the JH7110 clock, reset, PHY, Ethernet, PCIe, USB, display, camera, audio, GPU and vendor multimedia support needed for the functionality-first track. Its DTS includes the JH7110 GPU node (`compatible = "img-gpu"`) and WAVE511/WAVE420L nodes.

The kernel branch contains both:

* `drivers/gpu/drm/img/img-rogue`, the StarFive vendor PVR path; and
* `drivers/gpu/drm/imagination`, the newer upstream PowerVR driver family.

They are not interchangeable. The vendor path and the StarFive userspace/firmware have to be matched as a release set; the upstream path must be tested against the exact BXE BVNC and firmware before it can be promoted.

The selected kernel's common DTS still describes memory as a 4GB region (`reg = <0x0 0x40000000 0x1 0x0>`). This is a release-blocking 8GB validation item. The project must either consume the official U-Boot/EEPROM memory-selection mechanism or carry a reviewed, board-profile-specific 8GB memory patch, then verify `memblock`, `/proc/meminfo`, DMA/CMA and GPU/VPU stability on physical 8GB boards.

### VisionFive 2 hardware evidence

The official datasheet lists 2/4/8GB LPDDR4 options, M.2, an eMMC socket, USB 3, 40-pin GPIO, Gigabit Ethernet and a TF card slot. The official Linux/U-Boot DTS enables both JH7110 PCIe controllers, SD/eMMC, USB and the two GMACs. NVMe is therefore a valid VisionFive 2 capability target, but the image test must still validate the specific M.2 wiring and PCIe link on the board revision under test.

The VF2 profile will initially target the v1.3B 8GB board and use the upstream-compatible DTB name `jh7110-starfive-visionfive-2-v1.3b.dtb`, with a vendor/BSP variant kept available if the 6.12 display/GPU/VPU stack requires it.

### Milk-V Mars hardware and software evidence

Official overview: <https://milkv.io/docs/mars/overview>
Official boot documentation: <https://milkv.io/docs/mars/getting-started/boot>
Official hardware documents: <https://milkv.io/docs/mars/getting-started/hardware>
Official SDK: <https://github.com/milkv-mars/mars-buildroot-sdk>

The official overview documents up to 8GB LPDDR4, removable eMMC, microSD, SPI flash bootloader storage, HDMI 2.0, three USB 3 ports plus one USB 2 port, Gigabit Ethernet, M.2 E-Key Wi-Fi/Bluetooth, 40-pin GPIO, MIPI DSI/CSI, and JH7110 H.264/H.265 multimedia. The official boot page recommends booting through the SPI flash bootloader and then continuing from SD or eMMC; Mars V1.2 and newer expose a DIP boot-mode selector.

The official Mars SDK's `dev` revision is pinned for reference in `sources.lock`. Its README identifies a 5.15 kernel and Buildroot/FIT outputs such as `jh7110-milkv-mars.dtb`, `u-boot-spl.bin.normal.out` and `visionfive2_fw_payload.img`. That naming and age are evidence of the vendor flow, not permission to reuse a VisionFive 2 DTB or silently share board binaries.

The Mars board DTS is now present in upstream Linux and U-Boot DTS sources as `jh7110-milkv-mars.dts`. It contains Mars-specific GMAC clocking and Motorcomm PHY delays, eMMC/SD, PCIe, PWM, PWMDAC and USB-host pin/VBUS configuration. These details must remain in the Mars profile. The official Mars overview does not advertise an M-key NVMe connector; the initial capability matrix therefore sets NVMe to `false`/`SKIP` for Mars even though the SoC has PCIe controllers and the DTS enables them. This is a conservative board-capability decision pending schematic-level proof of a usable NVMe connection.

U-Boot upstream documents that Mars can use the VisionFive 2 U-Boot code with board detection and DT selection. The new project will not depend on an implicit VF2 fallback: it will build and label a Mars-specific artifact, select `jh7110-milkv-mars.dtb` explicitly, and test the SPI/SPL/U-Boot path separately.

### Upstream Linux, U-Boot and Mesa

Upstream Linux contains `jh7110-milkv-mars.dts`, the VisionFive 2 DTS family, JH7110 peripherals and the newer `DRM_POWERVR` driver. Upstream U-Boot contains the Mars board document and multi-DTB support. This is valuable for the `mainline-experimental` branch, but not sufficient to replace the BSP for the initial stable desktop image.

The Linux kernel documentation for the upstream PowerVR driver currently lists AXE-1-16M and BXS-4-64 MC1 as supported examples. Mesa's PowerVR documentation lists BXE-4-32 BVNC `36.50.54.182` as unsupported and not under active development. That combination means upstream GPU support is a research path, not an acceptance criterion for Phase 1 or the stable image.

### GPU, VPU and licensing

StarFive `soft_3rdpart` documents:

* `IMG_GPU`: firmware, OpenCL, Vulkan, GLES2/GLES3 binary library package; not open source.
* `WAVE511`: 4K H.264/H.265 decoder package.
* `WAVE420L`: H.265 encoder package.
* `CODAJ12`: JPEG/MJPEG codec package.
* `OMX-IL`: vendor OpenMAX integration layer.

The exact GPU candidate in the lock file is the Git LFS object `img-gpu-powervr-bin-1.19.6345021.tar.gz`, with SHA-256 `9dcaf2084b13e59c4e50a4a288f5de56f8e9ee631627a3e818591675bf61311a`. The project owner has now confirmed that the GPU payload is licensed for inclusion in project artifacts. The build still keeps a hard audit gate:

1. Do not commit the GPU/VPU binary payloads to this repository; generate the package from the locked archive.
2. The authorized PVR Debian package may be uploaded to GitHub Actions artifacts and Releases.
3. If any future vendor payload lacks authorization, keep it out of artifacts and require a post-install downloader or documented user-supplied package input.
4. Record every binary's license status, source URL, checksum and install path in the package `SOURCE` file and build manifest.

### Debian Trixie

Debian 13/Trixie officially supports `riscv64`. The initial rootfs will use Debian packages rather than a copied vendor rootfs. The builder will use deb822 sources, `debootstrap` or `mmdebstrap`, qemu-user-static/binfmt for cross-architecture chroot steps, and a pinned snapshot. The lock file records the Debian and security snapshot endpoints used for this research date; the builder must capture and verify each Release file hash in the build manifest.

The desktop package set should start from Debian Trixie packages: systemd, NetworkManager, OpenSSH, sudo, locales, XFCE, LightDM, PipeWire/WirePlumber, Firefox ESR where available, Chromium as an explicit WARN-capable option, and the diagnostics/development tools requested in the project brief. Vendor GPU/VPU packages remain an overlay/package input, never a replacement for APT ownership of ordinary system libraries.

## Initial capability matrix decisions

This is an evidence status matrix, not a claim that Phase 1 has passed hardware tests.

| Capability | VisionFive 2 8GB | Milk-V Mars 8GB | Evidence/status |
| --- | --- | --- | --- |
| JH7110 / 8GB RAM | target | target | Hardware pages confirm options; exact DTS/U-Boot 8GB path must be tested |
| HDMI | target | target | Board docs and JH7110 display stack |
| DRM/KMS | BSP target | BSP target | StarFive 6.12 BSP required initially |
| IMG BXE-4-32 GPU | BSP target | BSP target | Vendor PVR DDK/userspace; upstream Mesa currently not a baseline |
| H.264/H.265 decode | BSP target | BSP target | WAVE511 vendor stack; verify actual decoder path |
| H.265 encode | BSP target | BSP target | WAVE420L vendor stack; verify actual encoder path |
| Gigabit Ethernet | target | target | Board docs plus board-specific PHY/DTS |
| USB 3/USB 2 | target | target | Board docs and DTS |
| eMMC | target | target | Both board docs/DTS expose eMMC |
| microSD/TF | target | target | Both board docs/DTS expose removable storage |
| NVMe | target | `SKIP` initially | VF2 M.2 evidence; Mars official overview advertises M.2 E-Key, not M-Key |
| PCIe | target | target | JH7110/DT support; board routing still needs validation |
| Wi-Fi/Bluetooth | module-dependent | M.2 E-Key/module-dependent | No board-wide pass until module and firmware are selected |
| Camera/CSI | target | target | JH7110 and board connectors; sensor-specific |

## Explicitly upstream vs BSP-dependent

### Already upstream or substantially upstream

* JH7110 CPU, clocks, resets, pinctrl, GPIO, I2C, SPI, UART, PWM, watchdog, RTC, thermal and many storage/network/PCIe/USB bindings.
* VisionFive 2 and Milk-V Mars Linux DTS files.
* U-Boot JH7110 support and Mars board documentation.
* Debian riscv64 packages and the general debootstrap/mmdebstrap rootfs model.
* Upstream DRM/KMS interfaces and the newer generic PowerVR driver framework.

### Must remain on the stable BSP at first

* JH7110 BXE-4-32 PVR kernel/userspace/firmware integration.
* StarFive display/HDMI combinations that are validated with the selected 6.12 release.
* WAVE511/WAVE420L/CodaJ12 kernel modules, firmware and userspace.
* Board-specific memory initialization and any 8GB selection logic.
* Mars PHY, USB VBUS, PMIC and power/reset behavior.

### Mars-specific adaptation required

* Linux DTB selection and package installation path.
* U-Boot output/profile and explicit `fdtfile`/extlinux behavior.
* GMAC clock/PHY delay configuration.
* USB host VBUS pinctrl and `dr_mode`.
* eMMC/SD boot target and SPI bootloader documentation.
* Capability matrix and test expectations, especially NVMe.

## Major risks

| Risk | Impact | Mitigation / exit criterion |
| --- | --- | --- |
| 8GB DTS/U-Boot memory selection | High; image may expose only 4GB or break DMA | Physical 8GB boot test on both boards; record `/proc/meminfo`, CMA, GPU/VPU and stress results |
| PVR DDK license scope changes | High; stable GPU image cannot be published | Keep the owner's authorization recorded; fail packaging if the lock entry is no longer accepted |
| Vendor PVR DDK versus 6.12 kernel ABI | High; no `/dev/dri/renderD*` or GPU crashes | Build/test exact locked kernel + DDK pair; never mix arbitrary `.so` files |
| VPU integration uses CPU fallback | High; false PASS | Require decoder name, device nodes, traces and CPU budget in `test-vpu.sh` |
| Mars bootloader silently selects VF2 DTB | High; Ethernet/USB/PMIC failures | Explicit Mars DTB, separate artifact names, boot log assertion and no generic fallback |
| HDMI/Wayland compositor maturity | Medium/high | Start with X11 fallback and a small Wayland session; gate default session on physical tests |
| Trixie riscv64 package gaps | Medium | Keep Debian package set modular; document any Testing package exception with snapshot and reason |
| PCIe/NVMe routing differs by board revision | Medium | Capability matrix is board-profile data, not SoC data; test link training on hardware |
| Vendor source branches move | Medium | Only locked commits are build inputs; CI rejects floating refs |

## Phase 1 exit criteria

Phase 1 is complete when the repository contains this report, `sources.lock`, and the architecture document; all selected revisions resolve; proprietary package gates are explicit; and the next phase can create a source cache without making an unreviewed board or license assumption.

## References

1. [StarFive VisionFive2 SDK](https://github.com/starfive-tech/VisionFive2)
2. [StarFive VisionFive2 releases](https://github.com/starfive-tech/VisionFive2/releases/tag/JH7110_VF2_6.12_v6.0.0)
3. [StarFive Linux BSP](https://github.com/starfive-tech/linux)
4. [StarFive third-party JH7110 software](https://github.com/starfive-tech/soft_3rdpart)
5. [Milk-V Mars overview](https://milkv.io/docs/mars/overview)
6. [Milk-V Mars boot documentation](https://milkv.io/docs/mars/getting-started/boot)
7. [Milk-V Mars hardware documents](https://milkv.io/docs/mars/getting-started/hardware)
8. [Milk-V Mars official SDK](https://github.com/milkv-mars/mars-buildroot-sdk)
9. [Upstream Linux Mars DTS](https://github.com/torvalds/linux/blob/master/arch/riscv/boot/dts/starfive/jh7110-milkv-mars.dts)
10. [Upstream U-Boot Mars board documentation](https://source.denx.de/u-boot/u-boot/-/blob/master/doc/board/starfive/milk-v_mars.rst)
11. [Linux PowerVR DRM documentation](https://docs.kernel.org/gpu/imagination/index.html)
12. [Mesa PowerVR documentation](https://docs.mesa3d.org/drivers/powervr.html)
13. [Debian Trixie release information](https://www.debian.org/releases/trixie/)
14. [Debian Trixie riscv64 installation guide](https://www.debian.org/releases/trixie/riscv64/)
