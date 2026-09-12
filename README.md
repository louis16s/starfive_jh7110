# jh7110-desktop

面向 StarFive JH7110 的 Debian riscv64 桌面镜像工程，当前支持：

- StarFive VisionFive 2 8GB：visionfive2
- Milk-V Mars 8GB：mars

两块板共用 Debian Trixie riscv64 rootfs、软件包清单和构建流程，但分别使用自己的 DTB、U-Boot/启动配置、存储布局和板级参数。Mars 不会复用 VisionFive 2 的 DTB。

## 当前状态

Run 26 已成功生成两套镜像和内核 Debian 包，是本次增强前的基线运行。
本次更新后的下一次 Actions 构建还会额外生成并安装锁定的 PVR GPU 包：

- jh7110-desktop-vf2-8g.img.xz
- jh7110-desktop-mars-8g.img.xz
- linux-image-6.12.5+_1.0.0_riscv64.deb
- linux-headers-6.12.5+_1.0.0_riscv64.deb
- linux-libc-dev_1.0.0_riscv64.deb
- jh7110-pvr-rogue_1.19.6345021-3_riscv64.deb（下一次构建起）

镜像已经包含 Debian 基础系统、XFCE、LightDM、Firefox ESR、Python 3、开发工具、PipeWire、NetworkManager、Podman、Mesa 图形工具和硬件诊断工具；下一次构建还会将获授权的 StarFive PVR runtime 纳入镜像。

构建成功不等于实板验收成功。当前仓库仍需在实际 VisionFive 2 和 Mars 上验证 HDMI 1080p60、GPU 硬件渲染、Vulkan、VPU、音频、USB 外设和桌面启动。

已确认 build-36 的根文件系统 `/lib` 链接被内核包解包破坏，缺少运行时 ELF 加载器；
该镜像不能作为可启动版本使用。修复及实际镜像检查记录见 [启动排查](docs/boot-regression.md)。

## 默认账户与开机密码

镜像不会写入固定的通用密码。构建时 root 账户保持 locked 状态，首次
启动会在 HDMI 本地 tty1 显示英文设密界面（Linux 文本控制台不能使用桌面的中文字体）：输入两次不少于 8 位的密码，
确认后才启动 LightDM。密码只写入目标设备，不会进入 GitHub Actions、
日志或镜像文件。

默认账户为：

~~~text
用户名：root
密码：首次启动时由用户设置
权限：root
~~~

首次启动设密服务完成后，LightDM 允许手动输入用户名，使用 root 登录。
桌面仍默认中文、Asia/Shanghai（UTC+8）。

首次启动分成两半：机器自己能做的部分由 `jh7110-prepare.service` 在无终端条件下
完成（板型 hostname 与 `/etc/hosts`、时区、locale、machine-id、SSH host key、
rootfs 扩容、硬件报告），它最多运行 5 分钟，失败也不会阻塞 LightDM；需要人的部分
由 `jh7110-console-setup.service` 在 HDMI tty1 等待设密，没有超时，因为超时杀掉
对话框会让设备没有任何可用账户。

如果已经能通过受信任的恢复方式进入 root shell，可执行下列命令重启本地 HDMI 设密界面
（它不会转移到串口）：

~~~sh
systemctl restart jh7110-console-setup.service
~~~

重新执行机器初始化（hostname、时区、locale、扩容等，全部幂等）：

~~~sh
sudo rm -f /var/lib/jh7110/prepare.done
sudo jh7110-prepare
~~~

不要在公开环境中复用简单密码；root 通过 SSH 登录也应在首次启动后按需
配置安全策略。

## 键盘和鼠标

有线 USB 键盘和鼠标已纳入支持范围：

- 内核启用 USB HID、通用 HID 和 input 子系统
- rootfs 包含 udev、usbutils 和 xserver-xorg-input-libinput
- XFCE/X11 使用 libinput
- Weston/Wayland 使用 compositor 的 libinput 输入后端
- USB 无线键鼠接收器通常可直接工作
- Bluetooth 键盘鼠标可通过 bluez、blueman 配对

接线建议：优先连接板载 USB Host 口；如果使用 USB 3 Hub，需要保证 Hub 有足够供电。当前软件配置已具备支持，但键盘、鼠标、USB Hub 的实际兼容性仍需在两块板上分别实测。

## 已预装的基础软件

### 系统与网络

systemd、systemd-timesyncd、NetworkManager、SSH server、sudo、udev、D-Bus、polkit、journald、nftables、WireGuard、Podman、zram。

### Python 与开发工具

~~~text
python3 python3-pip python3-venv
gcc g++ make build-essential
git cmake ninja-build pkg-config
gdb strace tmux vim nano curl wget rsync
htop btop
~~~

### 桌面与浏览器

~~~text
XFCE LightDM Thunar Mousepad file-roller
Firefox ESR
network-manager-gnome blueman pavucontrol
gnome-disk-utility xfce4-goodies
~~~

### 音频与媒体

PipeWire、WirePlumber、PulseAudio 兼容层、ALSA 工具、mpv、VLC、LibreOffice。

### 硬件工具

i2c-tools、GPIO/gpiod 工具、minicom、screen、picocom、ethtool、iproute2、usbutils、pciutils、mmc-utils、nvme-cli、lm-sensors、smartmontools。

### Chromium

Chromium 当前没有预装。Debian Trixie riscv64 没有可直接使用的官方 Chromium 包，因此项目不会安装来源不明的预编译 deb 或 so。Firefox ESR 是当前默认浏览器；Chromium 作为后续可选集成项，并会单独记录来源和兼容性。

## 中文环境和时区

- 默认 locale：zh_CN.UTF-8
- 保留 locale：en_US.UTF-8
- 默认时区：Asia/Shanghai
- UTC 偏移：UTC+08:00
- 默认 hostname：jh7110-vf2 或 jh7110-mars

首次启动服务会初始化 machine-id、SSH host key、locale、板型 hostname，并尝试扩展 rootfs。完成后会自动禁用自身。

## 软件源和大陆网络适配

镜像构建阶段仍使用 `sources.lock` 中锁定的 Debian snapshot，保证构建可重复；安装到设备后的 APT 默认优先使用清华 Debian 镜像，并在镜像不可用时由 deb822 多 URI 配置自动回退到 Debian 官方镜像。安全更新同样配置了大陆镜像和 `security.debian.org` 官方回退。

查看镜像连通性和当前配置：

~~~sh
sudo jh7110-mirror status
~~~

切换顺序：

~~~sh
sudo jh7110-mirror mainland
sudo jh7110-mirror official
~~~

APT 使用 HTTPS、Debian archive keyring 和重试机制；大陆镜像故障不会导致系统永久失去官方软件源。

## 下载与校验

从 GitHub Actions 的成功运行中下载对应 Artifact，解压后校验：

~~~sh
unzip jh7110-desktop-mars-release.zip
cd image
sha256sum -c jh7110-desktop-mars-8g.img.xz.sha256
~~~

VisionFive 2 使用 jh7110-desktop-vf2-8g.img.xz，Mars 使用 jh7110-desktop-mars-8g.img.xz。不要把 VisionFive 2 镜像刷到 Mars，也不要把 Mars 镜像刷到 VisionFive 2。

## 烧录到 TF 卡

烧录会清空目标设备。先确认设备号，绝对不要凭磁盘名称猜测：

~~~sh
diskutil list                 # macOS
lsblk -o NAME,SIZE,MODEL      # Linux
~~~

macOS 示例，假设目标盘已经确认是 /dev/disk4：

~~~sh
diskutil unmountDisk /dev/disk4
unzip -p jh7110-desktop-mars-release.zip image/jh7110-desktop-mars-8g.img.xz \
  | xz -dc \
  | sudo dd of=/dev/rdisk4 bs=4m
sync
diskutil eject /dev/disk4
~~~

Linux 示例，假设目标盘已经确认是 /dev/sdX：

~~~sh
unzip -p jh7110-desktop-mars-release.zip image/jh7110-desktop-mars-8g.img.xz \
  | xz -dc \
  | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
sync
~~~

镜像包含 GPT、FAT32 /boot 和 ext4 rootfs 分区。镜像不固定为 64GB；首次启动时 jh7110-prepare.service 使用 growpart 和 resize2fs 将根分区及 ext4 文件系统扩展到目标 TF 卡的最大可用空间。完成后可检查：

~~~sh
lsblk
df -h /
systemctl status jh7110-prepare.service
cat /var/lib/jh7110/hardware-report.txt
~~~

## 启动和桌面

U-Boot、OpenSBI 和板级启动介质配置必须按板型区分。当前配置使用：

- VisionFive 2：jh7110-starfive-visionfive-2-v1.3b.dtb
- Mars：jh7110-milkv-mars.dtb
- 启动方式：OpenSBI + U-Boot + extlinux.conf
- /boot：内核、initrd、DTB 和 extlinux 配置

如果 Mars 的 SPI-NOR 已经写入正确的 Mars SPL/FIT，且 U-Boot 环境保存为从
`mmc 1:1` 读取 `/extlinux/extlinux.conf`，以后只更新 TF/eMMC 镜像通常不需要
再次刷 U-Boot。只有 SPI-NOR 损坏、环境被清空、启动协议或分区布局改变，或明确
要升级 bootloader 时，才需要按板型重新刷写对应的 SPL 与 FIT payload。

启动介质、SPI-NOR 写入、UART 接线和板级差异请参阅
[构建与启动文档](docs/build.md)、[架构说明](docs/architecture.md)、
[研究记录](docs/research.md) 和 [图形说明](docs/graphics.md)。Mars 的 SPI-NOR
必须使用成对的 SPL 与 FIT payload：SPL 写入 `0x0`，`u-boot.itb` 写入
`0x100000`；不要把同目录的 `u-boot.img` 当作第二阶段 payload。刷写前先通过
串口确认板型和 U-Boot 环境，不要把 VisionFive 2 的 bootloader 或 DTB 写入 Mars。

## HDMI、GPU 和 VPU 状态

内核构建会检查 DRM、StarFive display controller、Inno HDMI 和 IMG/PVR 内核选项，Mars 还会单独生成和检查 Mars desktop DTB。构建同时固化几项桌面必需的内核配置并逐项断言：`CMA_SIZE_MBYTES=512`（厂商 defconfig 用的是内核默认 16 MiB，不够一个 1080p 帧缓冲）、`CONFIG_HZ=250`、`CPU_FREQ_DEFAULT_GOV_SCHEDUTIL`，以及 `SECCOMP`/`SECCOMP_FILTER`。生成的 DTB 还要通过断言：必须存在不少于 256 MiB 的 `linux,cma` 默认池。

本次更新将 sources.lock 固定的 StarFive PVR DDK 1.19.6345021 制作为
`jh7110-pvr-rogue` Debian 包，包含 IMG BXE-4-32 firmware、PVR userspace、
Vulkan/OpenCL ICD 和官方 `rc.pvr`。项目所有者已确认这些 GPU 包获得许可，
构建时仍会验证官方归档 SHA256，并在包内保留来源和授权记录。CI 能验证
打包和安装，不能替代 VF2/Mars 实板上的 GPU ABI、HDMI 热插拔和显示器验收。

登录后可运行：

~~~sh
jh7110-info
jh7110-test-graphics
systemctl status jh7110-pvr.service
drm_info
vulkaninfo
eglinfo
glmark2
~~~

图形测试方法和已知限制见 docs/graphics.md。若输出为 llvmpipe，表示使用 CPU 软件渲染，不是 GPU 硬件加速通过。

## 构建

主机优先支持 Ubuntu 24.04 x86_64。需要 mmdebstrap、QEMU riscv64 用户态、riscv64 交叉编译器、dtc、dpkg-deb 和常用构建工具。

~~~sh
./build.sh visionfive2 check
./build.sh mars check
make BOARD=visionfive2 image
make BOARD=mars image
~~~

源码版本固定在 sources.lock，不得使用 floating branch 或未锁定的 HEAD。
GitHub Actions 支持 workflow_dispatch，可选择 visionfive2、mars 或 all，
并上传镜像、内核 deb、GPU deb、SHA256、manifest 和构建信息。单独构建
GPU 包可执行 `make BOARD=mars gpu-package`。

## 诊断和测试

当前可用的系统工具（`jh7110-config` 与 `jh7110-selftest` 尚未发布）：

~~~sh
jh7110-info            # 板型、内存与 CMA、CPU 调频、内核项、DRM/HDMI、GPU、温度
jh7110-test-graphics   # 桌面会话内的 DRM/HDMI/Vulkan/OpenGL 验收
~~~

`jh7110-info` 是只读报告，缺失属性一律打印 unknown 或 SKIP，因为首次启动
服务在 `set -e` 下用它记录硬件报告，诊断工具不能让启动失败。硬件不存在的
能力应报告 SKIP，不能伪造为 PASS。GPU 测试只在 Vulkan 报软件渲染或没有
PowerVR 证据时失败；OpenGL/EGL 报 llvmpipe 只记警告，因为 X11 走
modesetting 且镜像默认 `AccelMethod none`，软件 GLX 是设计路径。

## 目录和文档

- docs/research.md：官方来源、版本、许可证和风险
- docs/architecture.md：构建图和板级分离原则
- docs/build.md：本地构建和 CI
- docs/graphics.md：HDMI/DRM/GPU 当前状态
- docs/licenses.md：GPU 等二进制组件的来源、哈希和授权记录
- sources.lock：源码 commit/tag 锁定
- configs/hardware-matrix.yaml：板级能力矩阵

## 已知限制

1. root 密码必须在首次启动的 HDMI tty1 设置；串口重启服务也仍然在 HDMI 显示设密界面。启动异常见 [HDMI 启动排查](docs/boot-regression.md)。
2. PVR 包已纳入构建，但 HDMI、Wayland、Vulkan、VPU、音频和 USB 键鼠仍需真实硬件验收。
3. Mars 的 NVMe 默认按能力矩阵报告为 SKIP，不能套用 VisionFive 2 的 NVMe 结论。
4. Chromium 暂未提供官方 riscv64 Trixie 安装包。

## 许可证

本工程脚本、配置和文档按仓库中的 LICENSE 发布。Linux、U-Boot、OpenSBI、Debian、Mesa、PVR 和 VPU 组件分别遵循各自上游或厂商许可证。PVR
再分发授权由项目所有者确认，并在生成包的 SOURCE 文件中留痕；其他
vendor GPU/VPU 二进制仍须单独核查许可证。
