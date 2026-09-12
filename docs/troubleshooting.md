# 排查

按现象找。每条给出先看什么、再看什么，以及哪些操作**不要**做。
设置向导本身的设计见 [oobe.md](oobe.md)，开机顺序见 [first-boot.md](first-boot.md)。

## 先做这两件事

只要能进系统（包括串口），先收集信息：

~~~sh
jh7110-info            # 硬件：显示、GPU、内存、热区、根文件系统
jh7110-diagnostics     # 脱敏诊断包，可以附在问题报告里
~~~

`jh7110-diagnostics` 会把每个文件过一遍过滤：`psk`、`password`、`secret`、
`token`、`authorization` 这些键的**值**替换成 `REDACTED`，私钥和
`authorized_keys` 整份不收，并在包里的 `README` 中列出被略过的文件。
它只读，不改动系统。

如果连系统都进不去，用串口。串口在任何情况下都保持可用，本工程不会为了
界面好看而关掉它。

## 开机后停在标志画面 / 完全没有输出

启动链（U-Boot → 内核 → rootfs）不在本工程的修改范围内，先看
[boot-regression.md](boot-regression.md) 里的记录，再接串口看 U-Boot 和内核输出。

**不要**在没有串口日志的情况下改分区表或重刷启动固件。

## 有 LightDM 背景，但没有登录框，也没有向导

向导没有起来，包装脚本应该已经把控制台恢复路径叫起来了。包装脚本自己写的行
（`jh7110-greeter:` 开头）在 LightDM 的日志里，向导写的行在它自己的日志里：

~~~sh
journalctl -b -u lightdm --no-pager | tail -50     # 包装脚本说了什么
cat /var/log/jh7110-oobe.log                       # 向导说了什么
systemctl status jh7110-oobe-backend.socket
~~~

镜像里这个日志文件是预先建好的，属主是向导运行的身份（`lightdm:adm`、0640），
所以它一直是可写的。如果它不存在，或者里面有「写不进日志文件」一句话，说明
那张镜像或者那块板子上权限被改过；向导每一步都会往标准错误写同样一行，
LightDM 的会话日志里仍然找得到。

对照 `jh7110-greeter:` 后面的那句话：

| 那一行 | 含义 | 下一步 |
| --- | --- | --- |
| `the login screen is missing:` | `lightdm-gtk-greeter` 不在 | 镜像构建问题，重装 lightdm-gtk-greeter |
| `the graphical setup cannot run on this board` | `jh7110-oobe --check` 没通过，通常是 GTK 或 `python3-gi` 缺失 | 在终端跑一次 `jh7110-oobe --check` 看具体原因 |
| `the graphical setup is not installed` | `/usr/bin/jh7110-oobe` 不在 | 镜像构建问题 |
| `was started 3 times without finishing` | 三次没走完向导 | 走控制台路径，或 `sudo jh7110-oobe --reset` 之后再试 |
| `asked for the console setup on tty9` | 恢复单元已经请求成功 | 按 Ctrl+Alt+F9 |
| `run 'sudo jh7110-console-setup' from the serial console` | 连启动恢复单元都被拒绝 | 在串口上照抄这句话 |

什么都没有 → 看 LightDM 自己的日志，它没起来。

保底走控制台：

~~~sh
sudo systemctl start jh7110-console-setup     # 切到 tty9
sudo jh7110-console-setup                     # 就在当前终端（串口）
~~~

## 向导窗口出现，但某一步失败

失败的那一页会显示步骤名和原因，已生效的部分会保留。常见的：

| 提示 | 原因 | 处理 |
| --- | --- | --- |
| 设置服务没有响应 | 后端 socket 没起来或权限不对 | `systemctl status jh7110-oobe-backend.socket`；`ls -l /run/jh7110/oobe.sock` 应该是 `root:lightdm 0660` |
| 设备名不合法 | 含下划线、以 `-` 开头结尾、超过 63 字符 | 用字母、数字和 `-` |
| 用户名已被占用 | 上一次运行已经创建过 | 换个名字，或直接完成设置后用它登录 |
| SSH 配置被拒绝 | `sshd -t` 没通过 | `sshd -t` 看具体哪一行 |
| 时区/locale 不可用 | 系统里没有这一项 | 从列表里选别的 |

## 关机重启后向导又出现了

说明 `oobe.done` 没写成功，或者被删掉了。检查：

~~~sh
ls -l /var/lib/jh7110/oobe.done
cat /var/lib/jh7110/oobe-state.json
~~~

`oobe.done` 只有在账户和设备名都设置好之后才写。如果它存在而向导仍然出现，
看 greeter 包装脚本的日志里有没有「did not finish」。

连续三次没做完向导，包装脚本会改用控制台路径，这是设计行为，不是故障。

## 登录后黑屏 / 回到登录界面

~~~sh
journalctl -b -u lightdm --no-pager | tail -80
cat ~/.xsession-errors 2>/dev/null
cat /var/log/lightdm/x-0.log /var/log/Xorg.0.log 2>/dev/null | tail -60
~~~

先确认 XFCE 会话本身能起：在 tty 上以桌面账户登录后手动跑一次 `startxfce4`。

## 桌面是软件渲染 / 很卡

~~~sh
jh7110-test-graphics
systemctl status jh7110-pvr
dmesg | grep -i -e pvr -e rgx -e gpu
~~~

`/etc/X11/xorg.conf.d/20-jh7110-safe-desktop.conf` 里默认关掉了 Xorg 的 glamor
加速，这是为了让登录路径先稳下来；HDMI 输出走 DRM/KMS，与它无关。
**不要在没有实测通过之前**删掉那个文件。

## `sudo` 每次都说 `unable to resolve host`

这是 `/etc/hosts` 里没有本机名字的典型症状。本工程在镜像构建、首次启动的机器
准备和设置向导里都会同时写 `/etc/hostname` 和 `/etc/hosts`，所以出现它意味着
某一步没跑完：

~~~sh
cat /etc/hostname
grep 127.0.1.1 /etc/hosts
getent hosts "$(cat /etc/hostname)"
~~~

修复（一条命令，幂等）：

~~~sh
sudo /usr/libexec/jh7110-set-hostname "$(cat /etc/hostname)"
~~~

## 没有网络

网络不是启动依赖，离线可以开机、也可以完成设置。

~~~sh
nmcli device status
nmcli connection show --active
nmcli device wifi list
~~~

Wi-Fi 从向导里连时，用的是 `nmcli --ask`，密码不经过命令行参数。

## 想让向导重新跑一遍

~~~sh
sudo jh7110-oobe --reset
~~~

它删除 `oobe.done`、`oobe-state.json` 和「连续三次没做完」的重试计数
（计数在 `lightdm` 账户的家目录里，用 sudo 运行也会清掉，下次登录才会真的重跑向导），
然后下次登录重新运行向导。
**已经存在的账户不会被删除**：向导会修复它，而不是新建一个。

## 应该附在问题报告里的东西

~~~sh
jh7110-diagnostics -o /tmp/report.tar.gz
~~~

打开确认一遍再发出去。报告里已经有 `jh7110-info` 的输出、本次启动的 journal、
各单元状态、NetworkManager 连接（密码已过滤）和设置状态。

**不要**把 `~/.ssh/id_*`、`/etc/ssh/ssh_host_*_key` 或任何私钥贴进 issue。
`jh7110-diagnostics` 不会收这些。

## 已知限制

见 [README 的已知限制](../README.md#已知限制) 和
[graphics.md](graphics.md)。
