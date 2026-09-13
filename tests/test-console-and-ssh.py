#!/usr/bin/env python3
"""How a board is reached: the serial console, ssh, and the board's own name.

A board that boots to a prompt nobody can answer is not diagnosable from
anywhere else - there is no shell to run a command in and no log to read except
the one on the serial port - so the ways in are treated here as properties of
the build rather than as things that happen to be installed.

Everything checked here is static: the package manifest, the files the image
ships, the two build scripts that assert them, the profiles that decide which
board an image is, and the workflow that has to run these checks before it
spends an hour compiling.  The build itself asserts the same things from inside
the rootfs, where the target's own systemd can be asked; this is what runs
first, on a checkout, without a board and without root.
"""
import importlib.machinery
import importlib.util
import re
import subprocess
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
BACKEND = REPO / "rootfs/overlay/usr/libexec/jh7110-oobe-backend"
SSHD_DROP_IN = REPO / "rootfs/overlay/etc/ssh/sshd_config.d/90-jh7110.conf"
SSHD_UNIT_DROP_IN = REPO / "rootfs/overlay/etc/systemd/system/ssh.service.d/10-jh7110.conf"
PACKAGE_LISTS = (
    "rootfs/packages/base.list",
    "rootfs/packages/desktop.list",
    "rootfs/packages/development.list",
    "rootfs/packages/board-tools.list",
)


def read(path):
    return (REPO / path).read_text(encoding="utf-8")


def manifest_packages():
    """Every package named by the manifest, in file order, comments dropped."""
    packages = []
    for name in PACKAGE_LISTS:
        for line in read(name).splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            packages.append(line)
    return packages


def load_backend():
    """Import the shipped backend, without writing bytecode beside it."""
    sys.dont_write_bytecode = True
    loader = importlib.machinery.SourceFileLoader("jh7110_oobe_backend", str(BACKEND))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def ssh_directives(text):
    """The directives in a configuration file, in either spelling.

    sshd_config takes `Keyword value`; a systemd drop-in takes `Keyword=value`.
    """
    directives = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        keyword, separator, value = (
            line.partition("=") if "=" in line.split(" ")[0] else line.partition(" ")
        )
        if not separator:
            continue
        directives[keyword] = value.strip()
    return directives


class ManifestTests(unittest.TestCase):
    def test_the_manifest_names_login_and_openssh_server_once_each(self):
        # Debian keeps login in a package of its own, apart from the base
        # system, and nothing the desktop installs depends on it.  A manifest
        # that does not name it produces the image this project shipped once: a
        # board that boots, prints its log to the serial port and never offers a
        # login prompt.  Naming it twice is the other failure - a package list
        # that grew a duplicate after a merge is a list whose intent is no
        # longer readable.
        packages = manifest_packages()
        self.assertEqual(packages.count("login"), 1, "login must be named exactly once")
        self.assertIn("login", read("rootfs/packages/base.list").splitlines())
        self.assertEqual(
            packages.count("openssh-server"), 1, "openssh-server must be named exactly once"
        )

    def test_no_second_login_binary_is_placed_into_the_tree(self):
        # The binary comes from the package and from nowhere else: a copy in the
        # overlay is a binary of unknown provenance in an image that is
        # otherwise built from a signed snapshot, and /usr/bin/login is not
        # where Debian puts it.
        offenders = []
        for path in list((REPO / "scripts").glob("*.sh")) + list(
            (REPO / "rootfs/overlay").rglob("*")
        ):
            if not path.is_file():
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            if "/usr/bin/login" in text or re.search(r"\b(cp|install)\b[^\n]*bin/login", text):
                offenders.append(str(path.relative_to(REPO)))
        self.assertEqual(offenders, [], "a login binary is copied instead of installed")


class SerialConsoleTests(unittest.TestCase):
    def test_the_build_asserts_the_prompt_the_console_ends_in(self):
        script = read("scripts/build-rootfs.sh")
        # The prompt is agetty's and the thing behind it is /bin/login; login
        # without its PAM stack is a prompt that refuses every password.
        self.assertIn("test -x /bin/login", script)
        self.assertIn("test -s /etc/pam.d/login", script)
        self.assertIn("/sbin/agetty", script)
        self.assertIn("/usr/sbin/agetty", script)
        # The unit that starts it cannot be started under QEMU, so the build
        # asks systemd what it would do on the board.
        self.assertIn("systemctl cat serial-getty@ttyS0.service", script)
        self.assertIn("systemctl is-enabled serial-getty@ttyS0.service", script)

    def test_the_kernel_names_the_console_the_getty_serves(self):
        # systemd's getty generator is what instantiates serial-getty@ttyS0 from
        # the command line; a board whose command line says something else has a
        # getty unit nobody asked for.
        for board in ("mars", "visionfive2"):
            cmdline = read(f"board/{board}/extlinux.conf.in")
            self.assertIn("console=ttyS0,115200", cmdline, f"{board} has no serial console")


class SshConfigurationTests(unittest.TestCase):
    def test_the_image_ships_the_drop_in_the_setup_also_writes(self):
        # The first-run setup rewrites this file, so a shorter version there
        # would quietly take away the lines the image was built with.  The two
        # are one text, and this is what keeps them one text.
        module = load_backend()
        self.assertEqual(
            SSHD_DROP_IN.read_text(encoding="utf-8"),
            module.SSHD_DROP_IN,
            "the shipped ssh drop-in and the one the first-run setup writes differ",
        )

    def test_the_drop_in_refuses_root_and_admits_the_desktop_account(self):
        directives = ssh_directives(SSHD_DROP_IN.read_text(encoding="utf-8"))
        self.assertEqual(directives["PermitRootLogin"], "no")
        # Password authentication is how the account the wizard creates logs in
        # over ssh; the root account is locked at build time and refused above,
        # so what this admits is that account and nothing else.
        self.assertEqual(directives["PasswordAuthentication"], "yes")
        self.assertEqual(directives["KbdInteractiveAuthentication"], "yes")
        self.assertEqual(directives["UsePAM"], "yes")
        # A directive that narrowed logins to a list of names would be the one
        # that kept the account out: the wizard offers a name and this file
        # cannot know it in advance.
        for directive in ("AllowUsers", "AllowGroups", "DenyUsers", "DenyGroups"):
            self.assertNotIn(directive, directives)
        self.assertNotEqual(directives.get("PermitEmptyPasswords"), "yes")

    def test_sshd_gets_the_runtime_directory_it_refuses_to_start_without(self):
        directives = ssh_directives(SSHD_UNIT_DROP_IN.read_text(encoding="utf-8"))
        self.assertEqual(directives["RuntimeDirectory"], "sshd")
        self.assertEqual(directives["RuntimeDirectoryMode"], "0755")

    def test_sshd_starts_after_the_unit_that_makes_its_host_keys(self):
        # The image ships no host keys and sshd does not start without them, so
        # the daemon has to be ordered after the first-boot unit that makes
        # them.  Both are wanted by multi-user.target: started together, the
        # daemon can reach its own start-up check first and exit with no host
        # keys, and a unit that exited that way is not restarted - the board
        # would be unreachable until someone rebooted it, which is exactly the
        # "flash it and set the password up" path this image is for.
        text = SSHD_UNIT_DROP_IN.read_text(encoding="utf-8")
        directives = ssh_directives(text)
        self.assertEqual(directives["After"], "jh7110-prepare.service")
        # And in the section systemd reads it in.  The drop-in cannot be handed
        # to systemd-analyze the way a unit file can - the CI step that does
        # that walks the unit files, and a drop-in is not one - so the same line
        # under [Service] would be a line systemd ignores, with nothing failing
        # anywhere and the ordering simply not there.
        after = text.index("After=jh7110-prepare.service")
        self.assertLess(text.index("[Unit]"), after)
        self.assertLess(after, text.index("RuntimeDirectory=sshd"))
        # Ordered after the unit that makes the keys, and not merely waiting on
        # it: the key generation is named in the unit the ordering names, so
        # that the two statements are about the same thing.
        prepare_unit = read("rootfs/overlay/etc/systemd/system/jh7110-prepare.service")
        self.assertIn("ssh-keygen -A", read("rootfs/overlay/usr/libexec/jh7110-prepare"))
        self.assertIn("ExecStart=/usr/libexec/jh7110-prepare", prepare_unit)
        # And both the build and the tree verifier fail on a unit drop-in that
        # lost the ordering.
        self.assertIn("After=jh7110-prepare.service", read("scripts/build-rootfs.sh"))
        self.assertIn("After=jh7110-prepare.service", read("scripts/verify-rootfs-login.sh"))
        self.assertRegex(
            read("scripts/verify-rootfs-login.sh"),
            r"ssh\.service is not ordered after jh7110-prepare\.service",
        )

    def test_the_build_fails_when_ssh_cannot_be_enabled(self):
        script = read("scripts/build-rootfs.sh")
        self.assertRegex(script, r"systemctl enable[^\n]*\bssh\b")
        # Enabled is read back rather than assumed: the enable above would
        # otherwise hide a missing unit, and this is the only way in for a board
        # with no serial cable.
        self.assertIn("systemctl is-enabled ssh.service", script)
        self.assertIn("is not enabled", script)
        # sshd itself validates the configuration the image ships, drop-in
        # included, in the position sshd reads it.
        self.assertIn("sshd -t", script)

    def test_no_password_is_written_into_the_image_or_the_repository(self):
        # The account is created by a person at first boot; every file here is
        # shipped to everyone, so a password in one is a password on every board
        # the image is written to.
        for path in [
            *sorted((REPO / "scripts").iterdir()),
            *sorted((REPO / "rootfs/overlay").rglob("*")),
            *(REPO / name for name in PACKAGE_LISTS),
        ]:
            if not path.is_file():
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            self.assertNotIn("DEFAULT_PASSWORD", text, f"a default password in {path}")
            # `--passwordbox` is whiptail asking for one, which is the opposite
            # of this; what is checked for is a password passed as an argument,
            # where the process table would show it to anyone on the board.
            self.assertIsNone(
                re.search(r"(^|\s)--?password[= ]", text, re.MULTILINE),
                f"a password on a command line in {path}",
            )


class RepositoryTests(unittest.TestCase):
    def test_no_key_material_is_committed(self):
        # A host key in the repository is the same private key on every board
        # the image is built from and in every clone of it, which is the whole
        # reason the keys are made on the board instead; an authorized_keys file
        # is an account that exists before anyone has made one.
        tracked = subprocess.run(
            ["git", "ls-files"], cwd=REPO, check=True, capture_output=True, text=True
        ).stdout.split()
        offenders = [
            path
            for path in tracked
            if re.search(
                r"ssh_host_|(^|/)id_(rsa|dsa|ecdsa|ed25519)|authorized_keys|\.(pem|key)$", path
            )
        ]
        self.assertEqual(offenders, [], "key material is tracked by git")


class FirstBootIdentityTests(unittest.TestCase):
    def test_host_keys_are_made_on_the_board_and_a_failure_is_fatal(self):
        script = read("rootfs/overlay/usr/libexec/jh7110-prepare")
        # The image ships without host keys: generated on the build host they
        # would be one private key on every board the image is written to.
        self.assertIn("ssh-keygen -A", script)
        self.assertRegex(script, r"ssh-keygen -A \|\| die")
        self.assertNotRegex(script, r"ssh-keygen -A[^\n]*\|\| true")
        self.assertIn("/run", script)
        self.assertRegex(script, r"install -d -m 0755 \"\$RUN_DIR/sshd\"")
        # A board that cannot make an identity cannot be reached, so it is the
        # unit that fails and the journal that says why.
        unit = read("rootfs/overlay/etc/systemd/system/jh7110-prepare.service")
        self.assertIn("StandardError=journal", unit)
        self.assertIn("Type=oneshot", unit)
        # Once it has run once, the condition keeps it from running again.
        self.assertIn("ConditionPathExists=!/var/lib/jh7110/prepare.done", unit)
        # It writes identities, never a person's own files: an ssh directory in
        # a home directory is the account's, and this runs as root.
        self.assertNotIn("/home", script)
        self.assertNotIn(".ssh", script)

    def test_the_profiles_keep_their_own_name_and_device_tree(self):
        # One tree, one recipe, two boards: the profile is the only thing that
        # decides which board an image is, and an image that carries the other
        # board's name or device tree is a board that boots as something else.
        mars = read("configs/mars.conf")
        vf2 = read("configs/visionfive2.conf")
        self.assertIn("DEFAULT_HOSTNAME=jh7110-mars", mars)
        self.assertIn("DEFAULT_HOSTNAME=jh7110-vf2", vf2)
        self.assertIn("KERNEL_DTB=jh7110-milkv-mars.dtb", mars)
        self.assertIn("KERNEL_DTB=jh7110-starfive-visionfive-2-v1.3b.dtb", vf2)
        # And the validator is what makes the profile keep saying so.
        validator = read("scripts/validate-profile.sh")
        self.assertIn('DEFAULT_HOSTNAME" == "jh7110-$board_image_token"', validator)
        self.assertIn("Mars must use its own DTB", validator)
        self.assertIn("VisionFive 2 cannot use the Mars DTB", validator)

    def test_the_rootfs_verifier_covers_both_ways_in(self):
        verifier = read("scripts/verify-rootfs-login.sh")
        for artifact in (
            "bin/login",
            "etc/pam.d/login",
            "usr/sbin/sshd",
            "serial-getty@.service",
            "multi-user.target.wants/ssh.service",
        ):
            self.assertIn(artifact, verifier, f"the rootfs verifier does not check {artifact}")
        self.assertIn("PermitRootLogin no", verifier)
        self.assertIn("jh7110-vf2", verifier)
        self.assertIn("jh7110-mars", verifier)


class WorkflowTests(unittest.TestCase):
    """The checks have to run before the build they are there to protect."""

    @classmethod
    def setUpClass(cls):
        import yaml

        cls.workflow = yaml.safe_load(read(".github/workflows/build.yml"))
        cls.jobs = cls.workflow["jobs"]

    def test_the_preflight_job_runs_the_static_checks(self):
        steps = self.jobs["preflight"]["steps"]
        commands = "\n".join(str(step.get("run", "")) for step in steps)
        self.assertIn("test-console-and-ssh.py", commands)
        self.assertIn("validate-profile.sh", commands)
        self.assertIn("bash -n", commands)

    def test_a_rootfs_smoke_job_runs_before_the_expensive_half(self):
        # The rootfs takes minutes and the compile takes the better part of an
        # hour, so the checks that only need a rootfs are a job of their own
        # that the build waits for.
        smoke = self.jobs["rootfs-smoke"]
        commands = "\n".join(str(step.get("run", "")) for step in smoke["steps"])
        # A rootfs installs the GPU package, so a job that builds one without
        # building that first fails - which is how this job failed its first
        # time, fifteen minutes into mmdebstrap.
        self.assertIn("gpu-package", commands)
        self.assertIn("rootfs", commands)
        self.assertIn("verify-rootfs-login.sh", commands)
        needs = self.jobs["build"]["needs"]
        self.assertIn("rootfs-smoke", needs)

    def test_the_build_reads_its_state_after_it_writes_it(self):
        # Three checks in this block read state another part of the same block
        # writes - the removals of the image's identities, and the privilege
        # separation directory sshd insists on before it will parse anything.
        # Each was written in the wrong place first, and each passed on the
        # development host, where the block cannot run at all, and failed on the
        # first CI run that could reach it.
        script = read("scripts/build-rootfs.sh")
        for check, before_it in (
            ("the image ships a machine id", "rm -f /etc/machine-id"),
            ("the image ships an SSH host key", "rm -f /etc/ssh/ssh_host_*"),
            ("sshd -t -f", "install -d -m 0755 /run/sshd"),
        ):
            self.assertLess(
                script.index(before_it),
                script.index(check),
                f"{check} is checked for before {before_it} has happened",
            )

    def test_the_rootfs_build_checks_its_inputs_before_the_long_run(self):
        # mmdebstrap spends a quarter of an hour downloading and unpacking the
        # base system, and the GPU package it needs is not checked until after
        # that - so the check is also made before it, where a tree that has
        # never been through `make gpu-package` fails in seconds.
        script = read("scripts/build-rootfs.sh")
        self.assertLess(
            script.index("expected exactly one GPU package"),
            script.index("if mmdebstrap \\"),
            "the GPU package is only checked after mmdebstrap has run",
        )

    def test_the_existing_workflows_and_jobs_survive(self):
        for name, job in (
            ("build.yml", "build"),
            ("build.yml", "preflight"),
            ("release.yml", "build"),
            ("release.yml", "release"),
            ("verify-image.yml", None),
        ):
            self.assertTrue((REPO / ".github/workflows" / name).is_file(), name)
            if job is not None:
                self.assertIn(job, read(f".github/workflows/{name}"))


if __name__ == "__main__":
    unittest.main()
