# 首次启动：从通电到桌面

本文描述镜像烧录后第一次开机的完整路径、每一步的失败行为，以及失败时从哪里看。
日常使用和设置界面的设计见 [oobe.md](oobe.md)；出问题时按
[troubleshooting.md](troubleshooting.md) 排查。

## 总览

~~~text
上电
 └─ U-Boot（SPI-NOR / SD）
     └─ 内核 + initramfs，根分区 ext4
         └─ systemd
             ├─ jh7110-prepare.service      机器自己能做的部分（无人值守）
             ├─ jh7110-pvr.service          GPU 内核模块与固件
             ├─ NetworkManager / sshd / ...
             └─ graphical.target
                 └─ lightdm
                     └─ jh7110-greeter      未设置时先跑向导，设置完成后 exec 真 greeter
                         ├─ jh7110-oobe      GTK3 设置向导（tty1）
                         │   └─ /run/jh7110/oobe.sock
                         │       └─ jh7110-oobe-backend（root，按需启动）
                         └─ lightdm-gtk-greeter
                             └─ XFCE 会话
~~~

镜像里 root 是锁定的，也没有任何可登录的人类账户。首次启动必须先创建一个账户，
所以启动路径里必须有一个能创建账户的东西；本工程把这件事交给图形向导，而不是
控制台上的交互式脚本。

## 各步骤

### jh7110-prepare.service

不需要人参与的部分，`StandardInput=null`、没有 `TTYPath`、有 5 分钟上限：

- 板型 hostname 与 `/etc/hosts` 同步（`jh7110_set_system_hostname`）
- 时区（`/etc/timezone` 与 `/etc/localtime`）
- locale（`locale-gen`）
- `systemd-machine-id-setup`
- `ssh-keygen -A`
- rootfs 扩容（`growpart` + `resize2fs`）
- 硬件报告写入 `/var/lib/jh7110/hardware.json`

完成后写 `/var/lib/jh7110/prepare.done`。**任何一步失败都不会阻塞 LightDM**，
也不会写完成标记，所以下次开机会重试。这个单元永远不碰终端。

### jh7110-pvr.service

加载 GPU 内核模块和 IMG BXE 固件。它与桌面启动无关，失败只影响硬件渲染；
HDMI 显示走 DRM/KMS，不依赖它。

### lightdm 与 greeter

`lightdm.conf.d/50-jh7110.conf` 把 `greeter-session` 指向 `jh7110-greeter`，
它不是一个真正的登录界面，而是一个包装脚本：

- `/var/lib/jh7110/oobe.done` 存在 → 直接 `exec lightdm-gtk-greeter`
- 否则先跑 `jh7110-oobe`，向导写出 `oobe.done` 后再 `exec` 真 greeter

两者在**同一个会话**里切换，所以从向导到登录界面不需要重启 LightDM，
也不需要任何特权。

### 设置向导与后端

向导以 `lightdm` 账户运行，不写任何系统文件；改机器的事全部通过
`/run/jh7110/oobe.sock` 交给 `jh7110-oobe-backend`（root）。后端的可用方法是一个
固定列表，**没有**「执行任意命令」这一类。详见 [oobe.md](oobe.md)。

## 离线

网络不是启动依赖。没有网线、没有 Wi-Fi 也能开机、也能完成设置（网络页可以跳过）。
`NetworkManager-wait-online` 不在启动路径上。

## 与其他单元的先后关系

- `jh7110-prepare.service` 排在 `local-fs.target` 和 `systemd-logind.service` 之后，
  排在 `display-manager.service` 之前（greeter 要显示板卡自己的名字），
  不依赖网络，也不是 `graphical.target` 的依赖：扩容或 locale 失败仍然进桌面。
- `jh7110-oobe-backend.socket` 属于 `sockets.target`：后端由第一次连接启动，
  没有向导的连接就不会运行。`.service` 没有 `[Install]` 段，不能被装进启动路径。
- `jh7110-console-setup.service` **不启用**，也不在任何 `.wants` 目录里。
  它是 tty9 上的恢复路径，由 greeter 包装脚本按需请求，或人工
  `sudo systemctl start jh7110-console-setup`。

## 失败时

| 现象 | 起点 |
| --- | --- |
| 停在 U-Boot / 显示标志不动 | 串口日志；本仓库不管启动链，见 [boot-regression.md](boot-regression.md) |
| 有 LightDM 背景但没有登录界面，也没有向导 | `journalctl -b -u lightdm`，`cat /var/log/jh7110-oobe.log` |
| 向导窗口出现但某一步失败 | 该页会显示失败步骤；`journalctl -b -u jh7110-oobe-backend` |
| 登录界面有账户但登录后黑屏 | `journalctl -b -u lightdm`，`~/.local/share/xsessions/` 日志 |
| 没有可见屏幕（只有串口） | 在串口上 `sudo jh7110-console-setup` |

在任何一种情况下，能进系统就有：

~~~sh
jh7110-info            # 硬件报告
jh7110-diagnostics     # 脱敏诊断包
~~~

## 参考

- [oobe.md](oobe.md)：设置向导与后端
- [troubleshooting.md](troubleshooting.md)：按现象排查
- [architecture.md](architecture.md)：构建图与板级分离
- [boot-regression.md](boot-regression.md)：启动链回归记录
