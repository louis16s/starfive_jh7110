# HDMI 与 GPU 集成状态

本次补齐显示启动条件和诊断工具。默认 LightDM 启动 XFCE X11，
systemd 默认目标为 graphical.target。Weston 保留为手动测试会话。
中文字体包含 Noto CJK。显示器模式由 EDID 协商，不强制不受支持的 4K 模式。

## Mars 显示设备树

锁定的 6.12 Mars DTS 仅包含 common.dtsi，显示、HDMI、GPU 节点原本关闭。
`dts/mars/desktop.dts` 包含原 Mars DTS，仅增加图形节点配置；保留 Mars
Ethernet PHY、PCIe、USB、电源和板型信息。DC endpoint 1 与 HDMI 互连。
6.12 HDMI 驱动要求 HPD GPIO 和电源属性，不能仅将 status 改成 okay。

依据：

- [Milk-V 官方 Mars DTS](https://github.com/milkv-mars/mars-buildroot-sdk/blob/1fd6bac9f2efde47fbb8afd28d2903c49f893e3f/linux/arch/riscv/boot/dts/starfive/jh7110-milkv-mars.dtsi)：HDMI endpoint 1 和 GPU 启用。
- [Mars V1.21 原理图](https://github.com/milkv-mars/mars-files/blob/main/Mars_Hardware_Schematics/Milk-V_Mars_SCH_V1.21_2024-0510.pdf)：DDC GPIO0/1、HPD GPIO15。
- [StarFive 6.12 HDMI 驱动](https://github.com/starfive-tech/linux/blob/4cecf169f38eb94b40e307f5f870055e4d9d64f1/drivers/gpu/drm/verisilicon/inno_hdmi.c)：HPD 和 regulator 获取要求。

VF2 使用原 BSP v1.3B DTS。两个板型都需实际确认 HDMI 1080p60 和热插拔。
Mars 其他 PCB 修订版引脚与电源对应关系尚需核对。

## GPU 集成

构建检查 DRM、Verisilicon、HDMI 和 IMG Rogue 必须启用。工程从
`sources.lock` 中固定的 StarFive `img-gpu-powervr-bin-1.19.6345021.tar.gz`
生成 `jh7110-pvr-rogue_1.19.6345021-1_riscv64.deb`，构建时校验归档
SHA256，并通过 dpkg 安装 firmware、PVR userspace、Vulkan ICD 和
`rc.pvr`。用户已确认该 GPU 包具备镜像分发许可；包内 `SOURCE` 文件仍
记录来源、版本、哈希和授权说明，便于审计。

安装包会启用 `jh7110-pvr.service`，由官方 `rc.pvr` 负责加载
`pvrsrvkm`/`drm_starfive` 并启动 PVR 服务。Mesa 的 GBM/EGL、Wayland
和通用 Vulkan loader 来自 Debian；真正的 PowerVR 渲染取决于选中的
6.12 BSP 内核、Mars/VF2 DTB、firmware 和 DDK ABI 是否匹配。CI 能验证
打包和安装，不能代替两块实板的 DRM/Vulkan/HDMI 验收。

## 实板检查

在桌面终端运行 `jh7110-test-graphics`，保存完整输出。它检查 DRM、
HDMI 状态/模式、Vulkan、EGL 和 OpenGL，软件渲染或探测失败返回非零。
`drm_info` 成功和 `/dev/dri/card0` 存在只能说明 DRM 路径存在，
必须核对 Vulkan device 和 GL renderer，不能把 llvmpipe 当作 GPU 通过。

黑屏时从串口查看 `journalctl -b -u lightdm` 和
`journalctl -b -k`，关注 drm/hdmi/pvr、deferred probe 和电源错误。
HDMI 输出与 GPU 渲染是两条不同路径，软件渲染也可能显示 XFCE。

镜像默认使用锁定的 root 账户。首次启动服务在 tty1 显示中文设密界面，
密码确认后才允许 LightDM 启动；LightDM 配置为手动输入用户名，因此
可以使用 root 登录。没有写入任何固定默认密码。串口维护时可执行
`systemctl restart jh7110-firstboot.service` 重新进入流程。

在桌面终端运行 `jh7110-test-graphics`。它检查 PVR 内核模块、firmware、
DRM 节点、HDMI 状态、Vulkan、EGL 和 OpenGL；检测到 llvmpipe/softpipe/
lavapipe 会失败，避免把 CPU 软件渲染误报为 GPU 通过。HDMI 输出与 GPU
渲染是两条不同路径，软件渲染也可能显示 XFCE。
