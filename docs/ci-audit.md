# CI 失败审查与构建前验证

2026-09-11，审查基线 `739b1bd`。

## 已取得的证据

Action `34606665299` 的日志显示失败在 `Validate profile and lock`：
`bash tests/test-kernel-merge.sh` 返回非零，尚未开始编译。
测试在恢复 `/lib -> usr/lib` 后错误地断言 `/lib/modules` 不存在。
macOS Bash 3.2 的 `set -e; [[ ! -e /bin ]]; echo ...` 未中止，
因此此前本地“通过”不能代表 Ubuntu Bash 5。现使用 Bash 5.3、GNU rsync 3.5
验证，并改成显式正向断言，覆盖链接路径可达、重复安装、普通目录及未知内容拒绝。
更早两次失败任务的日志端点现返回 404，不能补称其根因已经由日志证实。

## 本次修正

- 修正测试的相反断言，恢复通过 `/lib` 路径验证加载器文件。
- PVR 包的 firmware 和 systemd unit 安装到 `/usr/lib`；不再打包真实顶层 `/lib`。
  包修订号增为 `-2`，源二进制版本和校验值不变。
- Release 保留已含板名的镜像文件名及其 checksum 文件名；其余产物仍按板名隔离。
  上传规则匹配重命名后的 manifest。测试实际执行两个 workflow 的重命名代码，
  检查最终上传集合无重名、manifest 存在、checksum 指向的镜像可验证。
- 内核安装只依赖已生成的 kernel deb 和 release 文件，去掉没有使用的源码目录依赖。

## Ubuntu 验证门槛

`Verify rootfs using existing binaries` 手动工作流先生成小型 Debian Trixie 根目录，
安装本次 PVR 包并检查 merged-usr 与 ELF 加载器。随后下载并校验固定 build-36 测试镜像
和内核包，复制到独立工作区，执行当前安装内核、QEMU 运行检查、initrd 生成和镜像组装脚本。
不编译 OpenSBI、U-Boot 或内核，也不发布镜像。日志在失败时仍上传。
只有该验证通过，才应手动启动完整镜像构建。

这不替代实板 HDMI、GPU、USB、音频、启动介质验收。内核包目前仍通过解包合并安装，
完整 dpkg 注册及 apt 内核升级回滚仍是待完善项；现有 runtime APT 双 URI 也不等于
已经验证的镜像故障切换。不能将这些未完成项描述为已验收。
