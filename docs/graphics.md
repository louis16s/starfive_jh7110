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

## GPU 剩余阻碍

构建检查 DRM、Verisilicon、HDMI 和 IMG Rogue 必须启用。
官方 `img-gpu-powervr-bin-1.19.6345021.tar.gz` 已下载检查，SHA256 与
sources.lock 一致。归档内未找到 LICENSE/COPYING/NOTICE；官方 README
称其为非开源二进制，尚无明确可再分发授权。

因此本次不将该归档放入镜像。还需要确认授权、与内核匹配的 DDK ABI、
patched Mesa 的 libpvr_dri_support 接口、GBM/EGL、Vulkan ICD 和 firmware
初始化路径，并制作有依赖和许可证记录的 Debian 包。单独拷贝 libGLES
或启用 GPU 节点无法完成这些工作。当前 GPU 硬件加速仍为未完成。

## 实板检查

在桌面终端运行 `jh7110-test-graphics`，保存完整输出。它检查 DRM、
HDMI 状态/模式、Vulkan、EGL 和 OpenGL，软件渲染或探测失败返回非零。
`drm_info` 成功和 `/dev/dri/card0` 存在只能说明 DRM 路径存在，
必须核对 Vulkan device 和 GL renderer，不能把 llvmpipe 当作 GPU 通过。

黑屏时从串口查看 `journalctl -b -u lightdm` 和
`journalctl -b -k`，关注 drm/hdmi/pvr、deferred probe 和电源错误。
HDMI 输出与 GPU 渲染是两条不同路径，软件渲染也可能显示 XFCE。

当前登录用户仍为锁定的 jh7110，尚无首次启动设密界面；实板测试前需
通过可信的离线配置设置凭据。项目仍需补齐登录引导、内核包安装登记和
升级启动菜单、GPU/VPU 集成及实板验收，CI 成功不能当作可发布桌面验收。
