# HDMI 与 GPU 集成状态

本次补齐显示启动条件和诊断工具。默认 LightDM 启动 XFCE X11，
systemd 默认目标为 graphical.target。Weston 保留为手动测试会话。
中文字体包含 Noto CJK。显示器模式由 EDID 协商，不强制不受支持的 4K 模式。

## Mars 显示设备树

锁定的 6.12 Mars DTS 仅包含 common.dtsi，显示、HDMI、GPU 节点原本关闭。
`dts/mars/desktop.dts` 包含原 Mars DTS，仅增加图形节点配置；保留 Mars
Ethernet PHY、PCIe、USB、电源和板型信息。DC endpoint 1 与 HDMI 互连。
6.12 HDMI 驱动要求 HPD GPIO 和电源属性，不能仅将 status 改成 okay。

### CMA 预留区

`dts/mars/desktop.dts` 还补上了 VF2 已验证的 `reserved-memory/linux,cma`
节点（512 MiB，`shared-dma-pool` + `reusable` + `linux,cma-default`，
`alloc-ranges` 限定在 4 GiB 以下的 `0x70000000`–`0x90000000`）。

Mars 的 DTS 链（`jh7110-milkv-mars.dts` → `jh7110-common.dtsi` → `jh7110.dtsi`）
里原本没有任何 reserved-memory 节点，而厂商 defconfig 也没有 CMA 条目：
`kernel/dma/Kconfig` 的 `CMA_SIZE_MBYTES` 在内核里默认只有 16 MiB。
显示、GPU、VPU 驱动都通过 CMA 分配扫描输出缓冲，一个 1080p XRGB8888
帧缓冲就是 8.29 MiB，16 MiB 池在桌面会话下会立刻耗尽。
`scripts/build-kernel.sh` 现在设置 `CMA_SIZE_MBYTES=512` 并断言生成的
DTB 里存在 `linux,cma` 默认池且不小于 256 MiB，构建期就会拦住回退。
运行期可用 `jh7110-info` 的 `CmaTotal` 字段核对（健康值 524288 kB）。

依据：

- [Milk-V 官方 Mars DTS](https://github.com/milkv-mars/mars-buildroot-sdk/blob/1fd6bac9f2efde47fbb8afd28d2903c49f893e3f/linux/arch/riscv/boot/dts/starfive/jh7110-milkv-mars.dtsi)：HDMI endpoint 1 和 GPU 启用。
- [Mars V1.21 原理图](https://github.com/milkv-mars/mars-files/blob/main/Mars_Hardware_Schematics/Milk-V_Mars_SCH_V1.21_2024-0510.pdf)：DDC GPIO0/1、HPD GPIO15。
- [StarFive 6.12 HDMI 驱动](https://github.com/starfive-tech/linux/blob/4cecf169f38eb94b40e307f5f870055e4d9d64f1/drivers/gpu/drm/verisilicon/inno_hdmi.c)：HPD 和 regulator 获取要求。

VF2 使用原 BSP v1.3B DTS。两个板型都需实际确认 HDMI 1080p60 和热插拔。
Mars 其他 PCB 修订版引脚与电源对应关系尚需核对。

## GPU 集成

构建检查 DRM、Verisilicon、HDMI 和 IMG Rogue 必须启用。工程从
`sources.lock` 中固定的 StarFive `img-gpu-powervr-bin-1.19.6345021.tar.gz`
生成 `jh7110-pvr-rogue_1.19.6345021-3_riscv64.deb`，构建时校验归档
SHA256，并通过 dpkg 安装 firmware、PVR userspace、Vulkan ICD 和
`rc.pvr`。用户已确认该 GPU 包具备镜像分发许可；包内 `SOURCE` 文件仍
记录来源、版本、哈希和授权说明，便于审计。

安装包会启用 `jh7110-pvr.service`，仅请求加载 `pvrsrvkm`（也支持
内建驱动）。锁定的 6.12 显示驱动是 `vs_drm`，不再调用旧版
`rc.pvr` 加载不存在的 `drm_starfive`，关机时也不主动卸载显示驱动。Mesa 的 GBM/EGL、Wayland
和通用 Vulkan loader 来自 Debian；真正的 PowerVR 渲染取决于选中的
6.12 BSP 内核、Mars/VF2 DTB、firmware 和 DDK ABI 是否匹配。CI 能验证
打包和安装，不能代替两块实板的 DRM/Vulkan/HDMI 验收。

## 实板检查

在桌面终端运行 `jh7110-test-graphics`，保存完整输出。它检查 PVR 内核
模块、firmware、DRM 节点、HDMI 状态与模式、Vulkan、EGL 和 OpenGL。
`drm_info` 成功和 `/dev/dri/card0` 存在只能说明 DRM 路径存在，必须核对
Vulkan device 和 GL renderer，不能把 llvmpipe 当作 GPU 通过。只有
Vulkan 报出软件渲染或没有 PowerVR 证据时才算 GPU 失败，其余判定见文末。

黑屏时从串口查看 `journalctl -b -u lightdm` 和
`journalctl -b -k`，关注 drm/hdmi/pvr、deferred probe 和电源错误。
HDMI 输出与 GPU 渲染是两条不同路径，软件渲染也可能显示 XFCE。

镜像不预置可登录账户：root 在构建时被锁定。机器初始化由
`jh7110-prepare.service` 在无终端条件下完成（hostname、时区、locale、
machine-id、SSH host key、rootfs 扩容），交互式创建账户仍由
`jh7110-console-setup.service` 在 HDMI tty1 显示英文界面，账户创建成功后才
允许 LightDM 启动；LightDM 只列出可登录账户（手动输入用户名已关闭），因此
root 不能从图形界面登录。没有写入任何固定默认密码。串口维护时可执行
`systemctl restart jh7110-console-setup.service` 重新进入设置流程，
或执行 `jh7110-prepare` 重新初始化机器。

## 2026-09-12 审查后的默认策略

PVR 包保留厂商专用库，删除其旧 Vulkan loader 和通用 GLES SONAME
链接，让 Debian 的 Vulkan loader 与 GLVND 管理系统入口。Vulkan 检测
通过 `VK_DRIVER_FILES` 和兼容变量 `VK_ICD_FILENAMES` 只选择 IMG ICD。
普通 OpenGL/EGL 应用仍需要与厂商 DDK 相容的 Mesa 集成；安装 PVR 包
不能证明 Debian Mesa 已具备硬件加速。

核对锁定归档（`img-gpu-powervr-bin-1.19.6345021.tar.gz`）里每个
`.so` 的 SONAME 与 NEEDED 得到两点结论：归档的 `target/usr/lib`
**完全没有 EGL 运行库**（只有 `staging/usr/lib/libIMGeglsup.a` 静态库
和头文件），所以这块板子上没有可供 GLVND 加载的厂商 EGL，硬件
GLES 路径不可达；而 `libVK_IMG.so` 的 SONAME 是 `libVK_IMG.so.1`，
NEEDED 只有 `libsrv_um`/`libusc`/`libufwriter`/`libdrm`/libc，不依赖
被删除的 `libvulkan.so*`，因此删除厂商 loader 不会破坏 Vulkan ICD。
硬件路径只剩 Vulkan（`libVK_IMG.so`）与 OpenCL（`libPVROCL.so`）。

mmdebstrap 会写入 `Apt::Install-Recommends false`，而构建脚本没有
覆盖它，所以镜像里的 Mesa 软件栈完全由硬依赖保证。按快照索引计算
的依赖闭包（1278 个包）包含 `libegl1`、`libegl-mesa0`、`libglx-mesa0`、
`libglvnd0`、`libgl1-mesa-dri`、`libgles2`、`libgbm1`、`libvulkan1`。
`scripts/build-rootfs.sh` 现在在打包前断言这些运行库和 `swrast_dri.so`、
`kms_swrast_dri.so` 存在且非空，并核对 GPU 包的
`/etc/vulkan/icd.d/icdconf.json` 与 `/usr/lib/libVK_IMG.so`，避免快照
更新或打包回退后交付一个没有 GL/EGL 的桌面镜像。

X11 保留 modesetting 的软件显示路径，并默认关闭 XFWM 合成，减少
窗口移动与重绘的额外合成开销。可在 XFCE 窗口管理器微调中重新启用。
内存交换采用 LZ4 zram，逻辑容量为内存的 25%，物理内存按需占用。
这些是性能配置调整，尚无实板帧率、功耗或延迟的前后对比数据。

图形诊断在没有 HDMI 连接、缺少任一 GPU 固件、缺少检测命令，
或 Vulkan 报软件渲染 / 没有 PowerVR 证据时返回失败；无相关 dmesg 行
不会提前退出。两处判定按"是否属于本镜像的设计路径"区分：

- OpenGL 与 EGL 报 llvmpipe 只记 WARN 并计入警告，不计失败。X11 走
  modesetting，且镜像默认 `AccelMethod none`
  （`/etc/X11/xorg.conf.d/20-jh7110-safe-desktop.conf`），软件 GLX/EGL
  是设计结果而不是 GPU 故障；硬件加速由 Vulkan 一项负责证明。报成
  FAIL 会让每次桌面自检都在正常配置下失败。
- 未设置 `DISPLAY` 时（串口或 SSH 会话）只记 WARN 并跳过 X11 检测。
  这项检查在无桌面会话时无从执行，报成失败会让整份诊断恒定非零。

完整 X11 验收需在已登录的桌面终端运行。详细审查记录见
[代码审查](audit-20260912.md)。
