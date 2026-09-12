# 首次启动现状审计（重构前）

本文记录重构之前的实际实现，只描述仓库里真实存在的代码，不描述设想的架构。
审计对象是 commit `58a9822`。后续的首次启动改动以本文为对照，逐项说明改了什么、
为什么改、保留了什么。

## 一、当前启动调用链

```text
U-Boot (SPI-NOR)
  → extlinux.conf (p1 FAT32 /boot)
  → Linux kernel + initrd (cmdline: root=PARTUUID=… rw rootwait
                           console=tty0 console=ttyS0,115200 earlycon=sbi fbcon=nodefer)
  → systemd (default target: graphical.target)
  → multi-user.target.wants/jh7110-firstboot.service   ← 在这里阻塞
  → display-manager.service (lightdm)
  → lightdm-gtk-greeter (手动输入用户名 root)
  → XFCE (xfce4-session)
```

`jh7110-firstboot.service` 是这条链上唯一被仓库定制过的一环，其余全是 Debian
默认组件。

## 二、jh7110-firstboot.service 的 systemd 依赖

```ini
[Unit]
Description=JH7110 first boot initialization
After=local-fs.target systemd-logind.service
Before=display-manager.service getty@tty1.service
Conflicts=getty@tty1.service
ConditionPathExists=!/var/lib/jh7110/firstboot.done

[Service]
Type=oneshot
Environment=TERM=linux
TimeoutStartSec=infinity
ExecStart=/usr/libexec/jh7110-firstboot
StandardInput=tty
StandardOutput=tty
StandardError=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

事实清单：

* **它是阻塞 graphical.target 的那一个。** `Before=display-manager.service` 加上
  `Type=oneshot`、`RemainAfterExit=yes`，意味着 ExecStart 返回之前 LightDM 起不来；
  而 ExecStart 里包含一个没有超时的交互式密码输入（`TimeoutStartSec=infinity`）。
  用户在密码界面停留多久，桌面就晚到多久；窗口被 USB/printk 刷屏冲掉时，用户看到
  的是一个被破坏的界面。
* `Conflicts=getty@tty1.service` + `Before=getty@tty1.service`：该 unit 独占 tty1。
* `ConditionPathExists=!/var/lib/jh7110/firstboot.done`：完成后不再运行；脚本结尾
  还会 `systemctl disable jh7110-firstboot.service`，两重保险。
* 没有任何 `Restart=`，也没有看门狗。脚本中途 `die` 之后，unit 进入 failed 状态，
  下一次启动因为 done 文件不存在会重跑（root 口令已设置时会跳过提示）。

## 三、jh7110-firstboot 脚本做了什么

`rootfs/overlay/usr/libexec/jh7110-firstboot`（bash，`set -Eeuo pipefail`，
必须以 root 运行），按执行顺序：

| 顺序 | 动作 | 是否需要 root | 是否与 UI 耦合 |
| --- | --- | --- | --- |
| 0 | `install -d -m 0755 /var/lib/jh7110` | 是 | 否 |
| 1 | `chvt 1` 切到 tty1 | 是 | **是（明文抢 VT）** |
| 2 | whiptail 两次输入 root 密码 → `chpasswd` | 是 | **是（阻塞交互）** |
| 3 | `hostnamectl set-hostname "jh7110-$BOARD_ID"` | 是 | 否 |
| 4 | 时区：`ln -sfn /usr/share/zoneinfo/$TIMEZONE /etc/localtime`，写 `/etc/timezone` | 是 | 否 |
| 5 | `systemd-machine-id-setup`（`/etc/machine-id` 为空时） | 是 | 否 |
| 6 | `ssh-keygen -A` | 是 | 否 |
| 7 | `locale-gen`、`update-locale` | 是 | 否 |
| 8 | `growpart`（父设备 + 分区号） | 是 | 否 |
| 9 | `resize2fs` 扩容根文件系统 | 是 | 否 |
| 10 | `jh7110-info > /var/lib/jh7110/hardware-report.firstboot.txt` | 是（写目录） | 否 |
| 11 | `touch /var/lib/jh7110/firstboot.done`、`systemctl disable jh7110-firstboot.service` | 是 | 否 |

也就是说：11 个步骤里只有第 1、2 步需要终端，其余全部是后台机器初始化。

## 四、逐项现状

### 4.1 hostname

* 唯一实现是 `hostnamectl set-hostname "jh7110-$BOARD_ID"`，`BOARD_ID` 来自
  `/etc/jh7110/board.conf`（构建时由 `configs/<board>.conf` 写入）。
* 没有校验，没有 fallback；`hostnamectl` 缺失时脚本直接失败。
* 名字表：`mars → jh7110-mars`，`visionfive2 → jh7110-vf2`（README 里这么写，
  但代码生成的是 `jh7110-visionfive2`，见问题 P0-2）。

### 4.2 /etc/hosts

**仓库里没有任何一处写 `/etc/hosts`。** 全仓库 grep（`/etc/hosts`、`getent`）
返回空。`hostnamectl set-hostname` 只写 `/etc/hostname`，不动 `/etc/hosts`，
于是：

```text
/etc/hostname        → jh7110-mars      （首次启动写入）
/etc/hosts           → 只有 localhost / 构建主机残留的名字
sudo 解析自己的名字   → 失败 → "sudo: unable to resolve host jh7110-mars"
```

`sudo` 每次运行都会调用 `getaddrinfo()` 解析本机名来做日志与策略判断，
解析失败只打印警告后继续，但每个 `sudo` 都会刷一行，`hostname -f` 也拿不到
FQDN。这不是网络问题，是本机名字解析问题。

`/etc/hosts` 在镜像里的初始内容来自 mmdebstrap：它以 `--mode=root` 复制构建主机
的 `/etc/hostname`、`/etc/hosts` 到目标 rootfs，所以镜像里躺着的是 **CI runner
的名字**（`runnervmlun5p`）。除了触发上面的警告，它还是一条内容级（而非元数据级）
的构建差异来源：换个 runner 主机名，镜像内容就不同。`scripts/build-rootfs.sh`
目前只删 `/etc/machine-id`、`/etc/ssh/ssh_host_*` 和 dpkg/apt 日志，没有碰这两个
文件。

### 4.3 tty1 / 终端依赖

`chvt 1` + `TTYPath=/dev/tty1` + `StandardInput=tty`。串口（`console=ttyS0,115200`）
上也能看到同一个 whiptail 界面，并且 `chvt` 会把 HDMI 抢到 tty1。kernel printk、
USB 插拔日志都写进同一个 VT，直接把字符界面刷花，用户看到的密码框被切成碎片。

### 4.4 root 账户模型

* `configs/common.conf`：`DEFAULT_USER=root`。
* 构建时 `passwd --lock root`（`scripts/build-rootfs.sh`），镜像里 root 是 locked。
* 首次启动唯一能创建账户的路径就是给它设密码；除此之外**没有任何账户**。
* `/etc/lightdm/lightdm.conf.d/50-jh7110.conf`：
  ```ini
  user-session=xfce
  greeter-session=lightdm-gtk-greeter
  greeter-show-manual-login=true
  greeter-hide-users=true
  allow-guest=false
  ```
  即：登录界面不列用户，必须手动输入 `root`，也就是**桌面用户就是 root**。
* 没有普通用户、没有 sudo 用户、没有用户级 locale/时区。

### 4.5 LightDM 启动条件

`lightdm` 由 `systemctl enable lightdm` 开启，`:0` 的 X 用 modesetting 驱动
（`etc/X11/xorg.conf.d/20-jh7110-safe-desktop.conf`，`AccelMethod none`）。
它能起来的前提是 `jh7110-firstboot.service` 已经结束——包括那个没有超时的
密码输入。

### 4.6 machine-id / SSH host key

`/etc/machine-id` 与 `/etc/ssh/ssh_host_*` 在构建时被删除，首次启动由
`systemd-machine-id-setup`（其实是 systemd 自己在启动早期生成）+ `ssh-keygen -A`
创建。这是正确的“每台设备自己的身份”处理方式，重构必须保留。

### 4.7 rootfs 扩容

`findmnt` 取 `/` 的设备 → `lsblk` 取父设备与分区号 → `growpart` → `resize2fs`。
`growpart` 返回 1（“nothing to do”）被容忍，其它返回码 `die`。
只在 `/` 是块设备时执行；扩容失败会让脚本 `die`，但因为 root 口令在前面已经
设置好，失败仍可通过 tty 登录后手工修复。

### 4.8 locale / 时区

* 构建期：`/etc/locale.gen` 写入 `SUPPORTED_LOCALES`（`en_US.UTF-8 zh_CN.UTF-8`），
  `locale-gen`，`update-locale LANG/LANGUAGE/LC_MESSAGES` 为中文默认。
* 首次启动期：再跑一次 `locale-gen` + `update-locale`（幂等，但每次首次启动白跑）。
* 时区：构建期已写好 `/etc/localtime` + `/etc/timezone`，首次启动再写一遍。
* `board.conf` 里带着 `TIMEZONE`/`DEFAULT_LOCALE`/`DEFAULT_LANGUAGE`/
  `SUPPORTED_LOCALES`，供首次启动读取。

### 4.9 board 检测

`/etc/jh7110/board.conf` 由构建时写入（`BOARD_ID`、`BOARD_NAME`、时区、locale）。
运行时的板型**不**靠 DT 判定：`jh7110-info` 会同时打印 DT 的 `model`/`compatible`
和 profile 里的 `board_id`，两者不一致时以 DT 为准判断是不是刷错了镜像。
OOBE 必须沿用同一套（读 board.conf，展示 BOARD_NAME，用 BOARD_ID 生成 hostname），
不能写死 Mars。

### 4.10 NetworkManager

`systemctl enable NetworkManager`，rootfs 里有 `network-manager`、
`network-manager-gnome`、`wireguard-tools`、`bluez`/`blueman`。
没有任何“联网才能完成首次启动”的依赖：apt/NTP/DNS 都不在 boot 路径上。
这一条重构必须保持。

### 4.11 hardware report

`/usr/bin/jh7110-info`（bash，只读）打印文本报告：DT model/compatible、内存与 CMA、
CPU/调频、内核配置项、DRM 与 connector、GPU 固件/Vulkan ICD、温度、根文件系统。
首次启动把它输出到 `/var/lib/jh7110/hardware-report.firstboot.txt`。
没有结构化输出（无 JSON），没有网络/USB/音频/存储条目，没有状态分类
（正常/可用/未检测/未验证/异常/不支持），只有 `SKIP:` 文本。

### 4.12 状态与幂等

唯一状态文件是 `/var/lib/jh7110/firstboot.done`（空文件）。
所有步骤靠各自的判断做幂等：root 口令用 `passwd -S` 判断、machine-id 用非空判断、
host key 用 `ssh-keygen -A`（已存在就跳过）、`growpart` 容忍 1。
**只要 done 不存在，整个脚本从头重跑**；没有阶段化状态，因此也没有“中途断电后
从哪一步继续”的概念（靠各步骤自己幂等）。

### 4.13 测试与 CI 现状

* `tests/test-boot-config.py` 把当前的 tty1 方案写成了断言：`TTYPath=/dev/tty1`、
  `TimeoutStartSec=infinity`、`Conflicts=getty@tty1.service`、`"chvt 1" in script`。
  改动终端方案必须同步改这些断言。
* `tests/test-board-info.py` 覆盖 `jh7110-info` 的“缺属性不许失败”契约。
* `.github/workflows/build.yml` 手写了 shellcheck 的文件列表（新增脚本要加进去），
  没有 `python3 -m compileall`，没有 systemd unit 校验。
* `make check` 只跑上述 python 测试 + profile/host/source-lock 校验，不构建 rootfs。

## 五、问题清单

### P0

| 编号 | 问题 | 证据 |
| --- | --- | --- |
| P0-1 | hostname 与 `/etc/hosts` 不同步，`sudo` 每次报 `unable to resolve host` | 仓库内零处写 `/etc/hosts`；`hostnamectl` 只写 `/etc/hostname` |
| P0-2 | hostname 命名与文档不一致：代码生成 `jh7110-visionfive2`，README 承诺 `jh7110-vf2` | `jh7110-firstboot:90` vs `README.md:112` |
| P0-3 | 首次启动用 tty1 阻塞桌面启动，USB/printk 冲掉交互界面 | unit 的 `Before=display-manager.service` + `TTYPath=/dev/tty1` + `chvt 1` |
| P0-4 | 唯一账户是 root 且用来登录桌面 | `DEFAULT_USER=root`、`greeter-show-manual-login=true`、`greeter-hide-users=true` |
| P0-5 | 镜像内容包含 CI runner 的 `/etc/hostname` 与 `/etc/hosts`（内容级差异，不只元数据） | mmdebstrap `--mode=root` 复制宿主配置，构建脚本未覆盖 |
| P0-6 | 没有普通用户、没有 sudo 用户、root 一旦设密即可 GUI/SSH 登录 | `passwd --lock root` 之后唯一的解锁路径就是设密码 |

### P1

| 编号 | 问题 | 证据 |
| --- | --- | --- |
| P1-1 | 机器初始化与交互式设置耦合在一个脚本里，无法分别幂等/分别重试 | `jh7110-firstboot` 单文件 11 步 |
| P1-2 | 没有图形化首次设置，也没有 fallback；GUI 失败即无法使用（无账户） | 只有 tty1 whiptail |
| P1-3 | 状态只有 `firstboot.done`，没有阶段状态、没有恢复语义 | `/var/lib/jh7110/firstboot.done` |
| P1-4 | 硬件报告是文本，没有结构化 JSON 与状态分类 | `jh7110-info` 输出格式 |
| P1-5 | 没有 `jh7110-diagnostics` / `--reset` 之类运维入口 | 仓库无对应文件 |
| P1-6 | CI 没有覆盖 python 语法与 systemd unit 校验 | `.github/workflows/build.yml` |

### P2

| 编号 | 问题 | 说明 |
| --- | --- | --- |
| P2-1 | 启动过程在 HDMI 上是文本滚动 | 可评估 plymouth，但绝不能动 cmdline 的 UART 能力 |
| P2-2 | 没有首次进入桌面的欢迎/信息入口 | 新增 jh7110-welcome |

## 六、实施计划

按“稳定 > 美观”的顺序推进，每个 Phase 一个独立 commit，任何一步都不能破坏
现有启动路径。所有新增能力都必须是**离线可用**的：DNS、NTP、apt、Wi-Fi、互联网
都不在 boot 路径上。

| Phase | 内容 | 提交 |
| --- | --- | --- |
| 1（P0） | `set_system_hostname()` 统一函数（校验、`/etc/hostname`、内核 hostname、`/etc/hosts` 的 `127.0.1.1` 行、幂等、`getent` 验证）；构建期写入确定性的 `/etc/hostname` 与 `/etc/hosts`；首次启动改用它 | `fix(firstboot): keep hostname and hosts in sync` |
| 2（P1） | 拆 `jh7110-prepare.service`（无交互、无 tty、不阻塞 graphical.target、幂等）与交互式设置；旧交互流程保留为 recovery | `refactor(firstboot): split machine preparation from interactive setup` |
| 3（P1） | 普通用户模型：root 默认 locked，首次设置创建 sudo 用户，LightDM 正常列用户、不再手动输入 root | `feat(accounts): create sudo user during first setup` |
| 4（P1） | GTK3 OOBE（PyGObject）+ 受限 root backend（Unix socket，方法白名单，禁止任意命令）+ OOBE 状态机 | `feat(oobe): add graphical first-run setup` |
| 5（P1） | tty9 文本 recovery + 看门狗，GUI 起不来也能完成初始化 | `feat(oobe): add recovery setup fallback` |
| 6（P2） | `jh7110-welcome`（首次自动一次 + 菜单常驻）、`jh7110-diagnostics`、`--reset`、文档与 CI | `feat(desktop): add JH7110 welcome application` |

## 七、实施记录

### Phase 1（P0）：hostname 与 /etc/hosts 同步

提交：`fix(firstboot): keep hostname and hosts in sync`

* 新增 `rootfs/overlay/usr/lib/jh7110/common.sh`：`jh7110_hostname_validate`（RFC 1123，
  ≤63 字符，禁止全数字）、`jh7110_hosts_render`（改写 `127.0.1.1` 行、保留用户别名与注释、
  只补一次基础条目）、`jh7110_write_hostname_files`（只写文件，绝不重命名构建主机）、
  `jh7110_set_kernel_hostname`（`hostnamectl`，失败退回 `/proc/sys/kernel/hostname`）、
  `jh7110_verify_hostname`（`getent hosts`，缺 getent 只告警不失败）、
  `jh7110_set_system_hostname`（文件 → 内核 → 验证，返回码 0/2/3 可区分）。
  路径全部来自 `JH7110_ETC` / `JH7110_STATE_DIR`，测试因此可以在沙箱里跑真实函数。
* `jh7110-firstboot`：`hostnamectl set-hostname "jh7110-$BOARD_ID"` 换成
  `jh7110_set_system_hostname "$(jh7110_default_hostname)"`；名字不再在脚本里拼。
* 构建期：`scripts/build-rootfs.sh` 用同一套函数写镜像里的 `/etc/hostname` 与
  `/etc/hosts`，写入前先清空 mmdebstrap 复制进来的宿主 hosts 文件，因此镜像内容只由
  profile 决定（P0-5 的内容级差异随之消失）；构建日志会打印被替换掉的宿主 hostname。
  chroot 里用 `getent hosts "$DEFAULT_HOSTNAME"` 做最终校验。
* 板级配置：`configs/mars.conf` / `configs/visionfive2.conf` 各自声明
  `DEFAULT_HOSTNAME`（`jh7110-mars` / `jh7110-vf2`），`scripts/validate-profile.sh` 用
  运行期同一个校验函数检查它，并要求等于 `jh7110-$board_image_token`（P0-2 消除）。
  不写死 Mars：名字来自 profile，`jh7110_default_hostname` 在没有该值时才回退到
  `jh7110-$BOARD_ID`，旧镜像升级后行为不变。
* 测试：`tests/test-hostname.sh`（首次写入、重跑字节一致、改名不留旧名、保留用户别名与
  注释、hosts 缺失时补齐基础条目、IPv6 只补一次、`hostnamectl` 调用、无法解析的名字被
  拒绝、空名被拒绝、无 getent 时跳过校验、非法/合法名字列表）；
  `tests/test-boot-config.py` 增加 hostname 接线断言；Makefile 与 CI shellcheck 列表
  同步更新。
* 未覆盖：真实板子的 HDMI/串口行为与 `sudo` 实际输出需要上板验证；host-side 只能证到
  “两个文件一致 + `getent` 能解析”。

### 明确不做

* 不改 boot stack：U-Boot、OpenSBI、kernel、DTB、分区布局、`extlinux.conf`
  全部不动。
* 不改 kernel cmdline（`console=tty0 console=ttyS0,115200 earlycon=sbi
  fbcon=nodefer` 保持不变），串口调试输出优先于视觉美化。
* 不引入 Electron / Node.js / Qt / GTK4。
* 不把密码写入任何文件、日志、命令行参数或 shell history。
* 不实现能执行任意命令的 root 接口。
* 不在 OOBE 里自动 `apt upgrade`，不把网络当作完成条件。
