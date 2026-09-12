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

    def test_machine_preparation_runs_without_asking_anything(self):
        unit = configparser.ConfigParser(interpolation=None)
        unit.read(ROOT / "rootfs/overlay/etc/systemd/system/jh7110-prepare.service")
        # Everything that can be done without a person is done without one:
        # this unit must never take the console, and it must not be able to
        # wait for input that nothing can give it.
        self.assertNotIn("TTYPath", unit["Service"])
        self.assertIn("StandardInput", unit["Service"])
        self.assertEqual(unit["Service"]["StandardInput"], "null")
        self.assertNotEqual(unit["Service"]["TimeoutStartSec"], "infinity")
        self.assertNotIn("Conflicts", unit["Unit"])
        self.assertEqual(
            unit["Unit"]["ConditionPathExists"], "!/var/lib/jh7110/prepare.done"
        )
        script = read("rootfs/overlay/usr/libexec/jh7110-prepare")
        for interactive in ("whiptail", "chvt", "--passwordbox", "TERM=linux"):
            self.assertNotIn(interactive, script)
        self.assertIn("jh7110_set_system_hostname", script)
        self.assertIn("systemd-machine-id-setup", script)
        self.assertIn("ssh-keygen -A", script)
        # The resize is a machine step: growpart exits 1 to say the partition
        # already fills the card, and that must not fail the boot.
        self.assertNotIn("PARTNUM", script)
        self.assertIn("--output PARTN", script)
        self.assertIn('resize2fs "$root_source"', script)
        self.assertIn("growpart_status", script)
        self.assertNotIn("lsblk --help | grep -qw PARTN", read("scripts/build-rootfs.sh"))

    def test_interactive_setup_survives_waiting_for_a_person(self):
        unit = configparser.ConfigParser(interpolation=None)
        unit.read(ROOT / "rootfs/overlay/etc/systemd/system/jh7110-console-setup.service")
        # The console setup asks for a password.  A finite start timeout fires
        # while the dialog is on screen, and a killed prompt leaves the image's
        # locked root account locked, so this unit must be allowed to wait for
        # the user.  It is the recovery path as well as the first-run path.
        self.assertEqual(unit["Service"]["Environment"], "TERM=linux")
        self.assertEqual(unit["Service"]["TTYPath"], "/dev/tty1")
        self.assertEqual(unit["Service"]["TimeoutStartSec"], "infinity")
        self.assertNotIn("RuntimeMaxSec", unit["Service"])
        self.assertEqual(unit["Service"]["ExecStart"], "/usr/libexec/jh7110-console-setup")
        self.assertIn("jh7110-prepare.service", unit["Unit"]["After"])
        self.assertEqual(
            unit["Unit"]["ConditionPathExists"], "!/var/lib/jh7110/oobe.done"
        )
        # The unit must own tty1 while it runs: before the getty so the two
        # cannot race for the console, and never after it, which would
        # contradict the ordering and make systemd drop the job.
        self.assertEqual(unit["Unit"]["Conflicts"], "getty@tty1.service")
        self.assertIn("getty@tty1.service", unit["Unit"]["Before"])
        self.assertNotIn("getty@tty1.service", unit["Unit"].get("After", ""))
        script = read("rootfs/overlay/usr/libexec/jh7110-console-setup")
        self.assertIn("chvt 1", script)
        # The account is unlocked before anything else that can fail, and the
        # password is measured in characters, not bytes of the C-locale console.
        self.assertLess(
            script.index("setup_root_password\n"), script.index(': > "$DONE_FILE"')
        )
        self.assertNotIn("passwd --unlock root", script)
        self.assertIn("LC_ALL=C.UTF-8 wc -m", script)
        # This path must be able to run on a board whose prepare unit never
        # finished, so it is what completes the machine half.
        self.assertIn("/usr/libexec/jh7110-prepare", script)
        for package in ("kbd", "whiptail", "e2fsprogs", "cloud-guest-utils"):
            self.assertIn(package, read("rootfs/packages/base.list").splitlines())

    def test_hostname_and_hosts_are_written_together(self):
        # The board's name lives in two files, and sudo resolves it through the
        # second one: a first boot that only sets /etc/hostname is the "sudo:
        # unable to resolve host" warning on every later command.
        for script in ("jh7110-prepare", "jh7110-console-setup"):
            script_text = read(f"rootfs/overlay/usr/libexec/{script}")
            self.assertIn("jh7110_set_system_hostname", script_text)
            self.assertNotIn("hostnamectl set-hostname", script_text)
        library = read("rootfs/overlay/usr/lib/jh7110/common.sh")
        self.assertIn('"$JH7110_ETC/hostname"', library)
        self.assertIn('"$JH7110_ETC/hosts"', library)
        self.assertIn("getent hosts", library)
        # The image ships its own identity: mmdebstrap copies the build host's
        # /etc/hostname and /etc/hosts in, which is both a runner-dependent
        # image and a name the board's hosts file has never heard of.
        rootfs = read("scripts/build-rootfs.sh")
        self.assertIn("jh7110_write_hostname_files", rootfs)
        self.assertIn("DEFAULT_HOSTNAME=$DEFAULT_HOSTNAME", rootfs)
        self.assertIn(': > "$rootfs_dir/etc/hosts"', rootfs)
        for board, token in (("mars", "mars"), ("visionfive2", "vf2")):
            self.assertIn(
                f"DEFAULT_HOSTNAME=jh7110-{token}", read(f"configs/{board}.conf")
            )

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
