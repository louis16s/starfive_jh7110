#!/usr/bin/env python3
"""Host-side regression checks, not a replacement for hardware boot tests."""
from pathlib import Path
import configparser
import unittest

ROOT = Path(__file__).resolve().parents[1]


def read(name):
    return (ROOT / name).read_text()


class BootConfig(unittest.TestCase):
    def test_console_and_board_separation(self):
        for board, compatible in (("mars", "milkv,mars"), ("visionfive2", "starfive,visionfive-2")):
            template = read(f"board/{board}/extlinux.conf.in")
            self.assertIn("console=tty0", template)
            self.assertIn("console=ttyS0,115200", template)
            self.assertIn("fbcon=nodefer", template)
            self.assertIn("@KERNEL_DTB@", template)
            self.assertIn(compatible, read(f"configs/{board}.conf"))

    def test_password_service_is_bounded(self):
        unit = configparser.ConfigParser(interpolation=None)
        unit.read(ROOT / "rootfs/overlay/etc/systemd/system/jh7110-firstboot.service")
        self.assertEqual(unit["Service"]["Environment"], "TERM=linux")
        self.assertEqual(unit["Service"]["TTYPath"], "/dev/tty1")
        self.assertLessEqual(int(unit["Service"]["TimeoutStartSec"]), 300)
        script = read("rootfs/overlay/usr/libexec/jh7110-firstboot")
        self.assertNotIn("PARTNUM", script)
        self.assertIn("--output PARTN", script)
        self.assertNotIn("lsblk --help | grep -qw PARTN", read("scripts/build-rootfs.sh"))
        self.assertIn('resize2fs "$root_source"', script)
        self.assertIn("chvt 1", script)
        for package in ("kbd", "whiptail", "e2fsprogs", "cloud-guest-utils"):
            self.assertIn(package, read("rootfs/packages/base.list").splitlines())

    def test_kernel_console_required(self):
        script = read("scripts/build-kernel.sh")
        for symbol in ("VT_CONSOLE", "FRAMEBUFFER_CONSOLE", "DRM_FBDEV_EMULATION", "USB_HID"):
            self.assertIn(symbol, script)
        self.assertIn('required BSP option missing', script)
        self.assertIn('--module ZRAM', script)
        self.assertIn('CONFIG_ZRAM=m', script)

    def test_safe_login(self):
        config = read("rootfs/overlay/etc/X11/xorg.conf.d/20-jh7110-safe-desktop.conf")
        self.assertIn('Driver "modesetting"', config)
        self.assertIn('Option "AccelMethod" "none"', config)
        self.assertNotIn("BusID", config)
        self.assertIn("TimeoutStartSec=30", read("scripts/build-gpu-package.sh"))

    def test_runtime_probe_uses_systemd_executable(self):
        script = read("scripts/install-kernel-into-rootfs.sh")
        self.assertIn("/usr/lib/systemd/systemd --version", script)
        self.assertNotIn("/sbin/init --version", script)


if __name__ == "__main__":
    unittest.main()
