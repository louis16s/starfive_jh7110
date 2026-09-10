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

## 中文环境与时区

镜像默认使用：

* 时区：`Asia/Shanghai`（UTC+8）
* 默认语言：`zh_CN.UTF-8`
* 已生成语言：`zh_CN.UTF-8`、`en_US.UTF-8`
* 英文回退链：`zh_CN:zh:en_US:en`

登录后可以通过系统设置或命令切换语言；构建 manifest 会记录默认 locale、支持的 locale 和 UTC 偏移。
这些设置从下一次重新构建镜像后生效，已有 Artifact 不会被原地修改。

## 当前硬件状态

Run 成功只代表源码、内核包、Debian rootfs 和镜像组装成功，不代表真实硬件验收完成。

当前镜像尚未包含可重新分发的 StarFive PVR DDK、GPU firmware 和 GPU userspace，因此不能宣称 IMG BXE-4-32 已启用硬件加速。HDMI/DRM/LightDM/桌面软件已作为构建目标纳入，但 VF2 和 Mars 的 HDMI 1080p60、Wayland、OpenGL/Vulkan 仍需连接实际开发板和显示器验证。详细状态见 [`docs/research.md`](docs/research.md)。
