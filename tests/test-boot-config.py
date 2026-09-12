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

    def test_recovery_console_setup_is_opt_in(self):
        unit = configparser.ConfigParser(interpolation=None)
        unit.read(ROOT / "rootfs/overlay/etc/systemd/system/jh7110-console-setup.service")
        # The console setup asks for a password on tty9 and is the recovery
        # path: the greeter asks for it when the graphical setup cannot run or
        # is not being finished, and a person can start it by hand.  It must
        # never be part of the boot, because the fallback holding up the
        # machine it exists to rescue is the one failure it would not survive.
        self.assertNotIn("Install", unit)
        self.assertEqual(unit["Service"]["Environment"], "TERM=linux")
        self.assertEqual(unit["Service"]["TTYPath"], "/dev/tty9")
        self.assertNotEqual(unit["Service"]["TimeoutStartSec"], "infinity")
        self.assertNotIn("RuntimeMaxSec", unit["Service"])
        self.assertEqual(unit["Service"]["ExecStart"], "/usr/libexec/jh7110-console-setup")
        self.assertIn("jh7110-prepare.service", unit["Unit"]["After"])
        self.assertEqual(
            unit["Unit"]["ConditionPathExists"], "!/var/lib/jh7110/oobe.done"
        )
        # The unit must own tty9 while it runs: before the getty so the two
        # cannot race for the console, and never after it, which would
        # contradict the ordering and make systemd drop the job.
        self.assertEqual(unit["Unit"]["Conflicts"], "getty@tty9.service")
        self.assertIn("getty@tty9.service", unit["Unit"]["Before"])
        self.assertNotIn("getty@tty9.service", unit["Unit"].get("After", ""))
        # tty1 is the desktop's: the greeter and the wizard run there, so the
        # recovery console is the one that has to move out of the way.
        self.assertNotEqual(unit["Service"]["TTYPath"], "/dev/tty1")
        script = read("rootfs/overlay/usr/libexec/jh7110-console-setup")
        self.assertIn('readonly SETUP_TTY=9', script)
        # Started from the serial console there is no virtual console to switch
        # to, and the dialogs simply appear where the command was run.
        self.assertIn('chvt "$SETUP_TTY"', script)
        # The account is created before anything else that can fail, and the
        # password is measured in characters rather than bytes, because the
        # console locale is C and a CJK password would otherwise count double.
        self.assertLess(
            script.index("setup_desktop_account\n"), script.index(': > "$DONE_FILE"')
        )
        self.assertNotIn("passwd --unlock root", script)
        self.assertIn("LC_ALL=C.UTF-8 wc -m", script)
        # One implementation of the account, shared with the graphical setup
        # and usable by hand on a board that cannot start a desktop.
        self.assertIn("ACCOUNT_TOOL=/usr/libexec/jh7110-account", script)
        self.assertIn('"$ACCOUNT_TOOL" create "$user_name"', script)
        self.assertIn('"$ACCOUNT_TOOL" validate "$name"', script)
        # This path must be able to run on a board whose prepare unit never
        # finished, so it is what completes the machine half.
        self.assertIn("/usr/libexec/jh7110-prepare", script)
        for package in ("kbd", "whiptail", "e2fsprogs", "cloud-guest-utils"):
            self.assertIn(package, read("rootfs/packages/base.list").splitlines())

    def test_graphical_setup_is_the_first_run_path(self):
        # A board that has never been set up boots to the setup, not to a login
        # screen with no account behind it.  lightdm starts the wrapper, which
        # runs the wizard and then execs the real greeter in the same session -
        # which is why getting from one to the other needs no LightDM restart.
        lightdm = read("rootfs/overlay/etc/lightdm/lightdm.conf.d/50-jh7110.conf")
        self.assertIn("greeter-session=jh7110-greeter", lightdm)
        greeter_entry = configparser.ConfigParser(interpolation=None)
        greeter_entry.read(ROOT / "rootfs/overlay/usr/share/xgreeters/jh7110-greeter.desktop")
        self.assertEqual(
            greeter_entry["Desktop Entry"]["Exec"], "/usr/libexec/jh7110-greeter"
        )
        # lightdm resolves greeter-session against the desktop file names in
        # /usr/share/xgreeters, so the name and the file have to agree.
        declared = [
            line.split("=", 1)[1].strip()
            for line in lightdm.splitlines()
            if line.startswith("greeter-session=")
        ]
        self.assertEqual(declared, ["jh7110-greeter"])
        self.assertTrue(
            (ROOT / f"rootfs/overlay/usr/share/xgreeters/{declared[0]}.desktop").is_file()
        )

        wrapper = read("rootfs/overlay/usr/libexec/jh7110-greeter")
        # The wrapper runs as the greeter account and must not need privilege
        # for anything but the one thing it asks polkit for.  What it prints at
        # a person is not what it runs, so the comments and the hint it prints
        # are taken out before looking for a way to raise privilege.
        for line in wrapper.splitlines():
            command = line.strip()
            if not command or command.startswith("#"):
                continue
            # A line that starts with one of these is the wrapper raising its
            # own privilege, which it must never do.  The hint it prints at a
            # person mentions sudo as something for them to type; that is a
            # message, not a command, and it does not start the line.
            for raise_privilege in ("sudo", "pkexec", "su ", "setpriv", "chroot"):
                self.assertFalse(
                    command.startswith(raise_privilege),
                    f"{raise_privilege} is run as a command: {command}",
                )
        self.assertIn('exec "$GREETER" "$@"', wrapper)
        # It hands the session over rather than restarting lightdm, and it
        # re-checks the done file after the wizard returns - the wizard exits 0
        # whether the user finished or closed the window.
        self.assertEqual(wrapper.count('if [[ -e "$DONE_FILE" ]]; then'), 2)
        self.assertIn('"$WIZARD"', wrapper)
        # A board without GTK must reach the recovery console immediately
        # rather than after burning every retry on a wizard that cannot open.
        self.assertIn('"$WIZARD" --check', wrapper)
        self.assertIn("ATTEMPT_LIMIT=3", wrapper)
        # The one privileged thing it does: ask for the recovery unit.
        self.assertIn('systemctl start --no-block "$RECOVERY_UNIT"', wrapper)

        # The permission it asks for is granted to that account alone, and only
        # for starting that one unit.
        rules = read("rootfs/overlay/etc/polkit-1/rules.d/50-jh7110-oobe.rules")
        self.assertIn('subject.user !== "lightdm"', rules)
        self.assertIn("jh7110-console-setup.service", rules)
        self.assertIn('action.lookup("verb") === "start"', rules)
        # A rules file that can run a program is a rules file that can be made
        # to run anything; this one decides, and decides nothing else.
        self.assertNotIn("polkit.spawn", rules)

    def test_the_setup_backend_is_a_socket_with_a_fixed_method_list(self):
        # The wizard runs as the greeter account and changes the machine only
        # through this socket, so the socket has to exist before the greeter
        # session does and the daemon behind it is started by the connection.
        socket = configparser.ConfigParser(interpolation=None)
        socket.read(ROOT / "rootfs/overlay/etc/systemd/system/jh7110-oobe-backend.socket")
        self.assertEqual(socket["Socket"]["ListenStream"], "/run/jh7110/oobe.sock")
        self.assertEqual(socket["Socket"]["SocketGroup"], "lightdm")
        self.assertEqual(socket["Socket"]["SocketMode"], "0660")
        self.assertEqual(socket["Socket"]["SocketUser"], "root")
        self.assertIn("sockets.target", socket["Install"]["WantedBy"])
        rootfs = read("scripts/build-rootfs.sh")
        self.assertIn("systemctl enable jh7110-oobe-backend.socket", rootfs)
        # The daemon itself is started by a connection to that socket and by
        # nothing else.  An [Install] section would let presets - or anyone
        # running `systemctl enable` - turn it into a root daemon that runs on
        # every boot of every board, including the ones that never show the
        # setup wizard at all.
        service = configparser.ConfigParser(interpolation=None)
        service.read(ROOT / "rootfs/overlay/etc/systemd/system/jh7110-oobe-backend.service")
        self.assertNotIn("Install", service)
        self.assertEqual(
            service["Service"]["ExecStart"], "/usr/libexec/jh7110-oobe-backend"
        )
        self.assertIn("jh7110-oobe-backend.socket", service["Unit"]["Requires"])
        # The socket is not readable by anyone else, and the daemon checks the
        # peer on top of that.
        self.assertIn("SO_PEERCRED", read("rootfs/overlay/usr/libexec/jh7110-oobe-backend"))
        # A GTK3 wizard through PyGObject is the whole of the graphical stack it
        # needs, and it is a hard dependency of the image rather than something
        # the package set happens to bring in.
        desktop_packages = read("rootfs/packages/desktop.list").splitlines()
        for package in ("python3", "python3-gi", "gir1.2-gtk-3.0"):
            self.assertIn(package, desktop_packages)
        for package in ("lightdm", "lightdm-gtk-greeter", "accountsservice", "fonts-noto-cjk"):
            self.assertIn(package, desktop_packages)

    def test_root_stays_locked_and_the_desktop_account_has_sudo(self):
        # The image ships root locked and no human account at all.  The account
        # the first-run setup creates is the only way in, and it is the one
        # that can use sudo - so root has to stay unreachable from the greeter,
        # from sshd and from the tool that creates it.
        self.assertIn("passwd --lock root", read("scripts/build-rootfs.sh"))
        account = read("rootfs/overlay/usr/libexec/jh7110-account")
        self.assertIn(
            "readonly DESKTOP_GROUPS=(sudo video render audio netdev plugdev bluetooth dialout)",
            account,
        )
        self.assertIn("the desktop account must not be root", account)
        # A password is never an argument: arguments show up in `ps`, in the
        # journal and in a shell history, and a password read from standard
        # input shows up in none of them.
        self.assertIn("IFS= read -r password", account)
        self.assertNotIn("--password", account)
        # chpasswd is the only thing that ever sees it, through a pipe.
        self.assertIn("| chpasswd", account)
        # The greeter lists the account the setup created instead of offering a
        # name box, whose only extra name would be root.
        lightdm = read("rootfs/overlay/etc/lightdm/lightdm.conf.d/50-jh7110.conf")
        self.assertIn("greeter-hide-users=false", lightdm)
        self.assertIn("greeter-show-manual-login=false", lightdm)
        self.assertNotIn("autologin-user", lightdm)
        # And sshd refuses root even if a password is ever set for it.  Debian
        # ships an `Include` at the top of sshd_config, so a drop-in is the
        # only way to set this without editing a file a package owns.
        sshd = [
            line
            for line in read(
                "rootfs/overlay/etc/ssh/sshd_config.d/90-jh7110.conf"
            ).splitlines()
            if line.strip() and not line.startswith("#")
        ]
        self.assertEqual(sshd, ["PermitRootLogin no"])
        # The account model is a property of the image, declared in the profile
        # every board shares and checked before a build starts.
        common = read("configs/common.conf")
        self.assertIn("ACCOUNT_MODEL=admin-user", common)
        self.assertIn("DEFAULT_USER=jh7110", common)
        self.assertIn("ACCOUNT_MODEL", read("scripts/validate-profile.sh"))
        # lightdm reads the account list from accountsservice.
        self.assertIn("accountsservice", read("rootfs/packages/desktop.list"))

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

    def test_the_desktop_configuration_parses(self):
        # LightDM reads this as an ini file and ignores any line it does not
        # understand, which is the worst way to be wrong: a key with a typo in
        # it takes effect by not taking effect, and the setting it was supposed
        # to change stays at whatever the default is.  The file is parsed here
        # and its keys are checked against the ones that exist, so a mistake is
        # a failure and not a silently different desktop.
        known = {
            "user-session",
            "greeter-session",
            "greeter-hide-users",
            "greeter-show-manual-login",
            "allow-guest",
        }
        lightdm = configparser.RawConfigParser(strict=True)
        lightdm.read_string(
            read("rootfs/overlay/etc/lightdm/lightdm.conf.d/50-jh7110.conf")
        )
        self.assertEqual(lightdm.sections(), ["Seat:*"])
        self.assertEqual(set(lightdm["Seat:*"]), known)
        self.assertEqual(lightdm["Seat:*"]["user-session"], "xfce")
        # The two that decide who can get in, spelled out here because a typo
        # in either would leave the greeter offering a name box whose only
        # extra name is root.
        self.assertEqual(lightdm["Seat:*"]["greeter-hide-users"], "false")
        self.assertEqual(lightdm["Seat:*"]["greeter-show-manual-login"], "false")
        self.assertEqual(lightdm["Seat:*"]["allow-guest"], "false")

    def test_the_chroot_payload_is_one_string(self):
        # The customisation script is one single-quoted argument, so a single
        # quote anywhere inside it ends the argument early and turns the rest
        # of the block into extra words on the command line - which bash
        # accepts, and which then runs something that is not the script that
        # was written.  Nothing inside may use one.
        lines = read("scripts/build-rootfs.sh").splitlines()
        openings = [i for i, line in enumerate(lines) if "/bin/bash -Eeuc '" in line]
        self.assertEqual(len(openings), 1, "expected exactly one chroot payload")
        start = openings[0]
        end = next(
            (i for i in range(start + 1, len(lines)) if lines[i].strip() == "'"),
            None,
        )
        self.assertIsNotNone(end, "the chroot payload is never closed")
        payload = lines[start + 1 : end]
        self.assertGreater(len(payload), 50, "the chroot payload looks truncated")
        for offset, line in enumerate(payload, start=start + 2):
            self.assertNotIn("'", line, f"line {offset} would close the payload early")

    def test_runtime_probe_uses_systemd_executable(self):
        script = read("scripts/install-kernel-into-rootfs.sh")
        self.assertIn("/usr/lib/systemd/systemd --version", script)
        self.assertNotIn("/sbin/init --version", script)


if __name__ == "__main__":
    unittest.main()
