# Milk-V 标志停留：启动链回归排查

## 结论范围

用户反馈较早镜像可显示 LightDM，加入 GPU 和首次设密后停留在 Milk-V 标志。
未取得该设备串口、内核及 Xorg 日志，因此不能将停留标志直接判定为某一驱动故障，
也不能将 CI 成功视为 HDMI 实机恢复。标志可能是 bootloader 留下的最后一帧。

## 本次修复

- 首次设密服务排在 LightDM 前，却依赖 tty1，缺少 TERM、主动切换 VT 和超时。
  显式启用内核 VT、fbcon、DRM fbdev 和 USB HID，启动参数同时保留 HDMI 文本控制台和串口。
  设密时切换 tty1，用英文控制台文本避免中文字体不可显示；中文桌面和 UTC+8 保留。
- `lsblk --output PARTNUM` 是错误列名；改为 `PARTN`。
  依据：[util-linux v2.41 源码列定义](https://github.com/util-linux/util-linux/blob/v2.41/misc-utils/lsblk.c)。
  原来裸调用的 `systemd-growfs` 不是常规 PATH 命令；改用已安装 e2fsprogs 的 resize2fs，
  并验证根设备和 ext4 类型。扩容失败仍明确报错，不伪造完成标志。
- 首次初始化最多 300 秒，PVR 初始化最多 30 秒，避免无限阻塞登录。
  首次设密超时不会解锁 root；重新启动设备，在 HDMI 上完成设密。
- Xorg modesetting 默认关闭 glamor 加速，先恢复稳定登录路径。
  这意味着默认 X11 桌面不承诺 GPU 加速；PVR/Vulkan/EGL 包仍保留，独立测试。
  必须实测通过后才能移除 `/etc/X11/xorg.conf.d/20-jh7110-safe-desktop.conf` 恢复自动加速。
- 保留 Mars 自身 DTS 和已有 GPIO15 HDMI HPD 修正，不套用 VF2 DTB。

## 检查与实板验收

构建前运行 `python3 tests/test-boot-config.py`，内核 olddefconfig 后检查必需图形、
控制台选项。DTB 构建继续检查板型 compatible 和显示/GPU 节点状态。
这些仅验证配置与编译，不能证明显示器 EDID、实际输出和 USB 键盘工作。

刷入新镜像后，应依次看到 U-Boot 菜单、控制台初始化/设密、LightDM、XFCE。
已有镜像不会自动获得这些修改。若仍停在标志，优先记录完整 115200 8N1 串口启动日志，
区分是否加载 kernel、是否挂载 rootfs、是否进入 systemd，再检查显示服务。
在已经认证的 shell 中执行：

```sh
cat /proc/cmdline
systemctl --failed
systemctl status jh7110-firstboot lightdm jh7110-pvr
journalctl -b -u jh7110-firstboot -u lightdm -u jh7110-pvr
journalctl -b -k
cat /var/log/lightdm/lightdm.log
cat /var/log/lightdm/x-0.log
ls -l /dev/dri /dev/fb0
cat /sys/class/drm/card*-HDMI-A-*/status
```

日志可能含主机信息，分享前检查。不要以 llvmpipe 或仅出现桌面声称 GPU 已通过。
尚未验证：实板 HDMI、PVR userspace/内核 ABI 配合、VPU、所有外设、多内核 apt 升级。
