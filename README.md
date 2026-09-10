# jh7110-desktop

面向 StarFive JH7110 的 Debian riscv64 桌面镜像工程，当前支持：

- StarFive VisionFive 2 8GB：visionfive2
- Milk-V Mars 8GB：mars

两块板共用 Debian Trixie riscv64 rootfs、软件包清单和构建流程，但分别使用自己的 DTB、U-Boot/启动配置、存储布局和板级参数。Mars 不会复用 VisionFive 2 的 DTB。

## 当前状态

Run 26 已成功生成两套镜像和内核 Debian 包：

- jh7110-desktop-vf2-8g.img.xz
- jh7110-desktop-mars-8g.img.xz
- linux-image-6.12.5+_1.0.0_riscv64.deb
- linux-headers-6.12.5+_1.0.0_riscv64.deb
- linux-libc-dev_1.0.0_riscv64.deb

镜像已经包含 Debian 基础系统、XFCE、LightDM、Firefox ESR、Python 3、开发工具、PipeWire、NetworkManager、Podman 和硬件诊断工具。

构建成功不等于实板验收成功。当前仓库仍需在实际 VisionFive 2 和 Mars 上验证 HDMI 1080p60、GPU 硬件渲染、Vulkan、VPU、音频、USB 外设和桌面启动。

## 默认账户与开机密码

当前 CI 镜像没有预设开机密码，也没有 starfive、jh7110 或其他通用密码。

构建脚本会创建用户：

~~~text
用户名：jh7110
密码：未设置，账户处于 locked 状态
权限：sudo、audio、video、input、plugdev、netdev
~~~

因此当前 Artifact 不是可以直接在 LightDM 登录的最终用户发行版。若已经能够通过串口或维护 shell 获得 root 权限，可以设置密码：

~~~sh
passwd jh7110
~~~

设置后即可使用 jh7110 登录图形桌面，再立即修改为自己的强密码。不要在公开镜像中写入固定默认密码。

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

镜像包含 GPT、FAT32 /boot 和 ext4 rootfs 分区。镜像不固定为 64GB；首次启动时 jh7110-firstboot.service 使用 growpart 和 systemd-growfs 将第 2 分区及 rootfs 扩展到目标 TF 卡的最大可用空间。完成后可检查：

~~~sh
lsblk
df -h /
systemctl status jh7110-firstboot.service
~~~

## 启动和桌面

U-Boot、OpenSBI 和板级启动介质配置必须按板型区分。当前配置使用：

- VisionFive 2：jh7110-starfive-visionfive-2-v1.3b.dtb
- Mars：jh7110-milkv-mars.dtb
- 启动方式：OpenSBI + U-Boot + extlinux.conf
- /boot：内核、initrd、DTB 和 extlinux 配置

启动介质、SPI-NOR 写入、UART 接线和板级差异目前请参阅 docs/build.md、docs/architecture.md、docs/research.md 和 docs/graphics.md。对应的详细板级启动文档仍待补充；在此之前应先通过串口确认 U-Boot 环境，不要盲目写入另一块板的 bootloader。

## HDMI、GPU 和 VPU 状态

内核构建会检查 DRM、StarFive display controller、Inno HDMI 和 IMG/PVR 内核选项，Mars 还会单独生成和检查 Mars desktop DTB。

但当前仓库没有重新分发 StarFive PVR DDK、IMG firmware、完整 GPU userspace 或 vendor VPU payload。因许可证和可再分发性限制，当前镜像不能保证 pvr、Vulkan、OpenGL ES 或硬件视频解码已经可用，也不能仅凭 CI 成功宣称 GPU/HDMI 实板通过。

登录后可运行：

~~~sh
jh7110-info
jh7110-test-graphics
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

源码版本固定在 sources.lock，不得使用 floating branch 或未锁定的 HEAD。GitHub Actions 支持 workflow_dispatch，可选择 visionfive2、mars 或 all，并上传镜像、内核 deb、SHA256、manifest 和构建信息。

## 诊断和测试

系统工具：

~~~sh
jh7110-info
sudo jh7110-config
sudo jh7110-selftest
~~~

测试脚本和完整测试矩阵仍在补充中；当前可使用 jh7110-info、jh7110-test-graphics 以及标准 Linux 工具进行检查。硬件不存在的能力应报告 SKIP，不能伪造为 PASS。

## 目录和文档

- docs/research.md：官方来源、版本、许可证和风险
- docs/architecture.md：构建图和板级分离原则
- docs/build.md：本地构建和 CI
- docs/graphics.md：HDMI/DRM/GPU 当前状态
- sources.lock：源码 commit/tag 锁定
- configs/hardware-matrix.yaml：板级能力矩阵

## 已知限制

1. 当前镜像没有默认登录密码，jh7110 初始为锁定账户；需要先通过维护入口设置密码。
2. GPU PVR DDK、firmware 和完整 userspace 尚未作为可再分发包集成。
3. HDMI、Wayland、Vulkan、VPU、音频和 USB 键鼠仍需真实硬件验收。
4. Mars 的 NVMe 默认按能力矩阵报告为 SKIP，不能套用 VisionFive 2 的 NVMe 结论。
5. Chromium 暂未提供官方 riscv64 Trixie 安装包。

## 许可证

本工程脚本、配置和文档按仓库中的 LICENSE 发布。Linux、U-Boot、OpenSBI、Debian、Mesa、PVR 和 VPU 组件分别遵循各自上游或厂商许可证。任何加入 vendor GPU/VPU 二进制的发布版本都必须先完成许可证和再分发权限核查。
