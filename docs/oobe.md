# 首次设置向导（jh7110-oobe）

镜像里 root 是锁定的，也没有可登录的账户，所以第一次开机必须先创建设置账户的人。
这件事由 greeter 会话里的图形向导完成；本文说明它怎么工作、权限从哪里来、
失败时会怎样。开机路径本身见 [first-boot.md](first-boot.md)。

## 为什么是图形向导

设置需要用户名、密码、设备名这些只有人知道的信息，所以它必须有界面。控制台
（whiptail）方式仍然保留，但退到恢复路径：图形界面能跑的时候，用户不应该被要求
去看 Linux 文本控制台。

## 组件

| 文件 | 身份 | 职责 |
| --- | --- | --- |
| `/usr/libexec/jh7110-greeter` | lightdm | 未设置时先跑向导，设置完成后 `exec` 真正的 greeter |
| `/usr/share/xgreeters/jh7110-greeter.desktop` | — | 让 `greeter-session=jh7110-greeter` 能解析到包装脚本 |
| `/usr/bin/jh7110-oobe` | lightdm | GTK3 窗口，只画界面，不写任何系统文件 |
| `/usr/lib/jh7110/oobe.py` | — | 全部规则：校验、状态机、硬件检查、网络查询 |
| `/usr/libexec/jh7110-oobe-backend` | root | 通过 Unix socket 提供的固定方法表 |
| `/usr/libexec/jh7110-set-hostname` | root | 把设备名同时写进 `/etc/hostname`、内核和解析器 |
| `/usr/libexec/jh7110-account` | root | 账户的唯一实现，密码从标准输入读入 |
| `/etc/polkit-1/rules.d/50-jh7110-oobe.rules` | — | 唯一两条额外授权，见下 |

界面和规则分开是有意的：`oobe.py` 不 import GTK，所以它能在没有显示器的
机器上被完整测试；`jh7110-oobe` 不持有任何规则。

## 权限模型

向导以 `lightdm` 账户运行，**不是 root**，也不调用 `sudo`。它需要的特权通过
socket 交给后端：

~~~text
/run/jh7110/oobe.sock   root:lightdm 0660
~~~

- `jh7110-oobe-backend.socket` 属于 `sockets.target`，后端由第一次连接启动；
  没有向导的板子不会运行它。`.service` 没有 `[Install]` 段，不能被装进启动路径。
- 后端除检查 socket 的属主与权限外，还用 `SO_PEERCRED` 检查连接方 uid，
  只接受两个：`lightdm`（首启时运行向导的账户）和 root（控制台恢复路径，
  以及人工以 root 运行的向导）。
- 方法表是固定的：`Ping`、`GetBoard`、`GetState`、`SetHostname`、`CreateUser`、
  `SetUserPassword`、`SetTimezone`、`SetLocale`、`SetKeymap`、`ConfigureSSH`、
  `SaveHardware`、`FinalizeSetup`。**没有** `RunArbitraryCommand` 这类方法，
  也不接受任何形式的命令字符串。

polkit 规则只给了 `lightdm` 两件事，别的都没有：

1. 连接网络（`wifi.scan`、`network-control`、`settings.modify.system`），
   这是 NetworkManager 自己的授权，向导的网络页绕不开；
2. `start` 一个单元 `jh7110-console-setup.service`，也就是下面说的恢复路径。

规则文件里没有 `polkit.spawn`，它只做判断，不做别的。

## 状态

~~~text
/var/lib/jh7110/oobe.done         设置已完成（一行 finalized=… hostname=… user=…）
/var/lib/jh7110/oobe-state.json   向导记录下来的选择，不含密码
/var/lib/jh7110/hardware.json     硬件报告
/var/lib/jh7110/prepare.done      机器准备完成（见 first-boot.md）
~~~

这些文件都不含密码。密码只在内存里从输入框走到 `CreateUser`，进了
`jh7110-account` 之后经管道交给 `chpasswd`，不写文件、不打日志、不作为参数。
它的长度按**字符**而不是字节计算，所以三个汉字不会当成九个字符通过检查。

断电安全性：`oobe.done` 是最后写的，而且写入是原子的（写临时文件 + `fsync` +
`rename`）。已经存在的账户会被**修复**而不是重建，所以重复运行向导不会产生第二个
用户，也不会改掉已有用户的密码。

## 页面

步骤条是：欢迎 → 网络 → 设备名称 → 用户 → 地区设置 → SSH → 更新 → 硬件检测 →
确认 → 收尾。

| 页面 | 做什么 | 失败时 |
| --- | --- | --- |
| 欢迎 | 等后端就绪，读板卡信息 | 后端连不上就禁用「下一步」，显示原因 |
| 网络 | 用 NetworkManager 列出 Wi-Fi 并连接；有线已连就不必管 | **可跳过**，离线也能完成设置 |
| 设备名称 | 默认 `jh7110-mars` / `jh7110-vf2`，同步 `/etc/hosts` | 名字不合法就停在原页 |
| 用户 | 显示名、用户名、密码 + 确认；显示名放在折叠的「高级选项」里 | 弱密码/重名/不一致会说明原因 |
| 地区设置 | locale、时区、键盘 | 从这个系统里实际存在的值中选 |
| SSH | 写 `/etc/ssh/sshd_config.d/90-jh7110.conf`（`PermitRootLogin no`），用 `sshd -t` 校验 | 校验不过就不写 |
| 更新 | 只显示信息，**不自动 apt upgrade** | 永远不是阻塞项 |
| 硬件检测 | 显示/GPU/内存/存储/网络/USB/音频/固件，结果存 `hardware.json` | 检测失败不阻塞设置 |
| 确认 | 汇总；密码不显示在这里 | — |
| 收尾 | 依次应用上面所有选择，最后写 `oobe.done` | 停在做不到的步骤，可以重试 |

收尾的顺序是「设备名称 → 用户账户 → 地区设置 → SSH → 硬件报告 → FinalizeSetup」，
中途失败会停在那里并保留已经生效的部分，重试不会重复创建用户。

## 恢复路径（tty9 与串口）

图形向导跑不起来、或者用户三次都没做完时，走控制台设置：

~~~sh
sudo systemctl start jh7110-console-setup     # tty9，给没有可用 GUI 的机器
sudo jh7110-console-setup                     # 就在当前终端（比如串口）
~~~

`jh7110-console-setup.service` **不启用**，也不在任何 `.wants` 目录里：
它是恢复路径，放进启动路径才是它最不该做的事。单元有 `ConditionPathExists=`
`!/var/lib/jh7110/oobe.done`，所以设置完之后即使被请求也不会再运行。

greeter 包装脚本会在下面三种情况下请求它，并且**不会**消耗重试次数：

- 图形栈不可用（先跑 `jh7110-oobe --check`，它只 import 工具包，不开显示器）；
- 向导没有安装；
- 向导连续三次没有做完（计数在 `${HOME}/.jh7110-oobe-attempts`，设置完成后清除）。

如果连启动这个单元都被拒绝（没有 polkit 规则、单元被删），包装脚本会打印
一条可以照抄的命令，而不是留下一个没有账户的登录界面。

## 命令行

~~~sh
jh7110-oobe --check     # 图形栈能不能跑；构建期也用这个断言，不需要显示器
sudo jh7110-oobe --reset
                        # 删掉完成标记，下次登录重新运行向导；
                        # 已存在的账户会被修复，不会被删除
cat /var/log/jh7110-oobe.log
                        # 向导的日志；密码永远不在这里
~~~

## 测试

- `tests/test-oobe-backend.py`：后端的方法表、peer 检查、原子写入、状态互斥。
- `tests/test-oobe-wizard.py`：用假 GTK 真跑窗口，走完「欢迎 → … → 收尾」，
  断言密码只进入 `CreateUser` 一次、不进日志、完成后清空输入框、失败步骤可重试。
- `tests/test-greeter.sh`：包装脚本的每一个分支，包括三种回退。
- `tests/test-boot-config.py`：单元形状、polkit 规则边界、`greeter-session`
  能解析到存在的 desktop 文件。
