#!/usr/bin/env python3
"""Regression tests for the privileged half of the first-run setup.

The backend is the one process in this project that a wizard talks to and that
runs as root, so what is checked here is that it can only do the things it is
supposed to do: the methods in the table and nothing else, the values they take
validated before they reach a file name or a command line, the state file
written atomically, and no password anywhere but on the standard input of
jh7110-account.

The tests drive the real module against a sandbox tree (JH7110_ROOT) with the
project's own tools replaced by stubs, so they run on the host without a board
and without root.
"""
from pathlib import Path
import importlib.machinery
import importlib.util
import json
import os
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[1]
BACKEND = REPO / "rootfs/overlay/usr/libexec/jh7110-oobe-backend"

SANDBOX = Path(tempfile.mkdtemp(prefix="jh7110-oobe-"))
ROOT = SANDBOX / "root"
CALLS = SANDBOX / "calls.log"

ACCOUNT_STUB = """#!/bin/bash
# Stand-in for the account tool: records how it was called, and what arrived
# on standard input, so the tests can prove the password never became an
# argument and that the name it was given is the one in the request.
set -u
printf 'account %%s\\n' "$*" >> "%(calls)s"
if [ "${ACCOUNT_FAIL:-0}" = 1 ]; then
    echo "jh7110-account: the account could not be created" >&2
    exit 1
fi
read -r record || exit 1
printf '%%s\\n' "${record#*:}" > "%(password)s"
exit 0
"""

HOSTNAME_STUB = """#!/bin/bash
set -u
printf 'hostname %%s\\n' "$*" >> "%(calls)s"
case "${HOSTNAME_STATUS:-0}" in
    0) exit 0 ;;
    3) echo "jh7110-set-hostname: the device name was written but does not resolve yet" >&2; exit 3 ;;
    *) echo "jh7110-set-hostname: that is not a usable device name" >&2; exit 1 ;;
esac
"""

SSHD_STUB = """#!/bin/bash
set -u
printf 'sshd %%s\\n' "$*" >> "%(calls)s"
echo "sshd: refusing on purpose" >&2
exit "${SSHD_STATUS:-0}"
"""

SYSTEMCTL_STUB = """#!/bin/bash
set -u
printf 'systemctl %%s\\n' "$*" >> "%(calls)s"
exit 0
"""


def write(path, text, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(mode)


def build_sandbox():
    # run/ is left alone: the socket of a backend started by another test class
    # lives there, and removing it would break a backend that is still serving.
    for sub in ("etc", "usr", "var"):
        shutil.rmtree(ROOT / sub, ignore_errors=True)
    write(
        ROOT / "etc/jh7110/board.conf",
        "BOARD_ID=mars\n"
        "BOARD_NAME='Milk-V Mars'\n"
        "DEFAULT_HOSTNAME=jh7110-mars\n"
        "TIMEZONE=Asia/Shanghai\n"
        "DEFAULT_LOCALE=zh_CN.UTF-8\n"
        "DEFAULT_LANGUAGE=zh_CN:zh:en_US:en\n"
        "SUPPORTED_LOCALES='en_US.UTF-8 zh_CN.UTF-8'\n"
        "ACCOUNT_MODEL=admin-user\n"
        "DEFAULT_USER=jh7110\n"
        "SECRET_KEY=this-must-not-be-handed-to-the-wizard\n",
    )
    password_file = SANDBOX / "password.received"
    calls = str(CALLS)
    write(
        ROOT / "usr/libexec/jh7110-account",
        ACCOUNT_STUB % {"calls": calls, "password": str(password_file)},
        mode=0o755,
    )
    write(
        ROOT / "usr/libexec/jh7110-set-hostname",
        HOSTNAME_STUB % {"calls": calls},
        mode=0o755,
    )
    write(ROOT / "usr/sbin/sshd", SSHD_STUB % {"calls": calls}, mode=0o755)
    write(ROOT / "usr/bin/systemctl", SYSTEMCTL_STUB % {"calls": calls}, mode=0o755)
    # A timezone database and a keyboard table small enough to keep in the test
    # but real enough for the existence checks the backend does.
    write(ROOT / "usr/share/zoneinfo/Asia/Shanghai", "TZif\n")
    write(ROOT / "usr/share/zoneinfo/UTC", "TZif\n")
    write(ROOT / "usr/share/X11/xkb/symbols/us", "xkb_symbols\n")
    write(ROOT / "usr/share/X11/xkb/symbols/de", "xkb_symbols\n")
    CALLS.unlink(missing_ok=True)
    password_file.unlink(missing_ok=True)
    return password_file


os.environ["JH7110_ROOT"] = str(ROOT)
os.environ["JH7110_ALLOWED_UIDS"] = str(os.getuid())
os.environ["JH7110_OOBE_SOCKET"] = str(ROOT / "run/jh7110/oobe.sock")


def load_backend():
    # Loading the module is what writes bytecode beside it on a stock CPython,
    # and beside it is the overlay the image is built from.
    sys.dont_write_bytecode = True
    loader = importlib.machinery.SourceFileLoader("jh7110_oobe_backend", str(BACKEND))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class MethodTests(unittest.TestCase):
    """The method table, driven the way the socket drives it."""

    @classmethod
    def setUpClass(cls):
        cls.backend_module = load_backend()

    def setUp(self):
        self.password_file = build_sandbox()
        self.state_file = ROOT / "var/lib/jh7110/oobe-state.json"
        self.done_file = ROOT / "var/lib/jh7110/oobe.done"
        self.backend = self.backend_module.Backend()

    def call(self, method, params=None):
        return self.backend.handle({"method": method, "params": params or {}})

    def ok(self, method, params=None):
        response = self.call(method, params)
        self.assertTrue(response["ok"], response.get("error"))
        return response["result"]

    def refused(self, method, params=None):
        response = self.call(method, params)
        self.assertFalse(response["ok"], "expected a refusal from %s" % method)
        return response["error"]

    def state(self):
        with open(self.state_file) as stream:
            return json.load(stream)

    def calls(self):
        if not CALLS.exists():
            return ""
        return CALLS.read_text()

    # -- the table itself -------------------------------------------------
    def test_only_the_named_methods_exist(self):
        self.assertEqual(
            sorted(self.backend_module.METHODS),
            [
                "ConfigureSSH",
                "CreateUser",
                "FinalizeSetup",
                "GetBoard",
                "GetState",
                "Ping",
                "SaveHardware",
                "SetHostname",
                "SetKeymap",
                "SetLocale",
                "SetTimezone",
                "SetUserPassword",
            ],
        )

    def test_there_is_no_way_to_run_a_command(self):
        # The whole point of the backend: a request names a method and passes
        # values, and no value is ever interpreted as something to execute.
        for method in ("RunCommand", "Exec", "Shell", "RunArbitraryCommand", "eval"):
            self.assertIn("unknown method", self.refused(method, {"command": "id"}))
        for method in ("__init__", "handle", "load", "save", "main", ""):
            self.assertIn("unknown method", self.refused(method, {}))
        # A request without params is a request, not an error: Ping and
        # GetBoard take none, and the wizard sends `params` only when it has
        # something to say.
        self.assertTrue(self.backend.handle({"method": "Ping"})["ok"])
        for broken in ("Ping", ["Ping"], 12, None, {"method": 12}, {"params": {}}):
            response = self.backend.handle(broken)
            self.assertFalse(response["ok"], "accepted a request that is not a method")
        for params in (1, "hostname", ["jh7110"]):
            response = self.backend.handle({"method": "Ping", "params": params})
            self.assertFalse(response["ok"])
            self.assertIn("not an object", response["error"])

    def test_board_settings_come_from_the_board_file(self):
        board = self.ok("GetBoard")
        self.assertEqual(board["board_id"], "mars")
        self.assertEqual(board["default_hostname"], "jh7110-mars")
        self.assertEqual(board["default_user"], "jh7110")
        self.assertEqual(board["supported_locales"], ["en_US.UTF-8", "zh_CN.UTF-8"])
        # A settings file can hold values the wizard has no business seeing;
        # the response is built from a list of keys, not from the file.
        self.assertNotIn("SECRET_KEY", board)
        self.assertNotIn("this-must-not-be-handed-to-the-wizard", json.dumps(board))

    def test_state_starts_empty_and_survives_a_corrupt_file(self):
        state = self.ok("GetState")
        self.assertEqual(state["version"], 1)
        self.assertFalse(state["user_created"])
        self.assertFalse(state["finalized"])
        # A half-written state file is a board that lost power: the defaults
        # are what the first run would do anyway, and it is reported.
        write(self.state_file, '{"hostname": "jh711')
        state = self.ok("GetState")
        self.assertEqual(state["hostname"], "")
        self.assertEqual(state["version"], 1)

    # -- the device name --------------------------------------------------
    def test_set_hostname_writes_and_records_it(self):
        result = self.ok("SetHostname", {"hostname": "jh7110-mars"})
        self.assertEqual(result["hostname"], "jh7110-mars")
        self.assertEqual(result["warning"], "")
        self.assertIn("hostname jh7110-mars", self.calls())
        self.assertEqual(self.state()["hostname"], "jh7110-mars")

    def test_set_hostname_reports_a_name_that_does_not_resolve(self):
        # Exit 3 is "written, but the resolver disagrees": the files are right
        # and the user is told, rather than being asked to pick another name.
        os.environ["HOSTNAME_STATUS"] = "3"
        try:
            result = self.ok("SetHostname", {"hostname": "jh7110-mars"})
        finally:
            del os.environ["HOSTNAME_STATUS"]
        self.assertIn("does not resolve", result["warning"])

    def test_set_hostname_reports_a_refusal_from_the_tool(self):
        os.environ["HOSTNAME_STATUS"] = "1"
        try:
            error = self.refused("SetHostname", {"hostname": "not a name"})
        finally:
            del os.environ["HOSTNAME_STATUS"]
        self.assertEqual(error, "that is not a usable device name")
        self.assertFalse(self.state_file.exists(), "a refused name was still recorded")

    def test_set_hostname_rejects_values_that_are_not_names(self):
        for value in ("", "   ", "a" * 64, "jh7110\nmars", "jh7110\0", 12, None, ["x"]):
            self.refused("SetHostname", {"hostname": value})
        self.refused("SetHostname", {})

    # -- the account ------------------------------------------------------
    def test_create_user_passes_the_password_on_standard_input(self):
        password = "correct horse battery"
        self.ok("CreateUser", {"username": "jh7110", "password": password})
        self.assertEqual(self.password_file.read_text().strip(), password)
        self.assertIn("account create jh7110", self.calls())
        # The stub records its arguments, and the password is not one of them:
        # an argument is visible in ps to every process on the board.
        self.assertNotIn(password, self.calls())
        state = self.state()
        self.assertEqual(state["username"], "jh7110")
        self.assertTrue(state["user_created"])
        self.assertNotIn(password, self.state_file.read_text())

    def test_create_user_refuses_what_the_account_tool_would_refuse(self):
        for username in ("root", "Root", "1user", "bad name", "-x", "", "a" * 33):
            self.refused("CreateUser", {"username": username, "password": "longenough"})
        for password in ("", "short", "seven77", None, 12345678, "eight\ncharacters"):
            self.refused("CreateUser", {"username": "jh7110", "password": password})
        self.assertFalse(self.state_file.exists(), "a refused account was still recorded")

    def test_create_user_reports_a_failure_of_the_account_tool(self):
        os.environ["ACCOUNT_FAIL"] = "1"
        try:
            error = self.refused(
                "CreateUser", {"username": "jh7110", "password": "longenough"}
            )
        finally:
            del os.environ["ACCOUNT_FAIL"]
        self.assertEqual(error, "the account could not be created")
        self.assertFalse(self.state_file.exists())

    def test_set_user_password_needs_the_account_to_exist(self):
        self.assertIn("no account", self.refused("SetUserPassword", {"username": "jh7110", "password": "longenough"}))
        self.ok("CreateUser", {"username": "jh7110", "password": "longenough"})
        self.assertIn(
            "no account",
            self.refused("SetUserPassword", {"username": "someone", "password": "longenough"}),
        )
        self.ok("SetUserPassword", {"username": "jh7110", "password": "another-one"})
        self.assertEqual(self.password_file.read_text().strip(), "another-one")

    # -- the machine's settings -------------------------------------------
    def test_set_timezone_writes_both_files(self):
        self.ok("SetTimezone", {"timezone": "Asia/Shanghai"})
        self.assertEqual((ROOT / "etc/timezone").read_text().strip(), "Asia/Shanghai")
        link = ROOT / "etc/localtime"
        self.assertTrue(link.is_symlink())
        self.assertEqual(os.readlink(link), "/usr/share/zoneinfo/Asia/Shanghai")
        self.assertEqual(self.state()["timezone"], "Asia/Shanghai")
        self.ok("SetTimezone", {"timezone": "UTC"})
        self.assertEqual(os.readlink(link), "/usr/share/zoneinfo/UTC")

    def test_set_timezone_refuses_anything_that_is_not_a_zone(self):
        for timezone in (
            "",
            "/etc/passwd",
            "../../etc/passwd",
            "Asia/../Asia/Shanghai",
            "Asia/Shang\nhai",
            "No/Such_Zone",
            12,
        ):
            self.refused("SetTimezone", {"timezone": timezone})
        self.assertFalse((ROOT / "etc/timezone").exists())
        self.assertFalse((ROOT / "etc/localtime").exists())

    def test_set_locale_accepts_only_what_the_image_carries(self):
        self.ok("SetLocale", {"locale": "zh_CN.UTF-8"})
        settings = (ROOT / "etc/default/locale").read_text()
        self.assertIn('LANG="zh_CN.UTF-8"', settings)
        self.assertIn('LC_MESSAGES="zh_CN.UTF-8"', settings)
        self.ok("SetLocale", {"locale": "en_US.UTF-8", "language": "en_US:en"})
        self.assertIn('LANGUAGE="en_US:en"', (ROOT / "etc/default/locale").read_text())
        for locale in ("fr_FR.UTF-8", "../../etc/passwd", "", 'zh"CN', "zh\nCN", 5):
            self.refused("SetLocale", {"locale": locale})
        self.assertEqual(self.state()["locale"], "en_US.UTF-8")

    def test_set_keymap_accepts_only_layouts_that_exist(self):
        self.ok("SetKeymap", {"keymap": "de"})
        keyboard = (ROOT / "etc/default/keyboard").read_text()
        self.assertIn('XKBLAYOUT="de"', keyboard)
        for keymap in ("fr", "../../etc/passwd", "u\ns", "US", "", 7):
            self.refused("SetKeymap", {"keymap": keymap})
        self.assertEqual(self.state()["keymap"], "de")

    # -- ssh ---------------------------------------------------------------
    def test_configure_ssh_writes_the_drop_in_and_validates_it(self):
        result = self.ok("ConfigureSSH", {"enabled": True})
        self.assertTrue(result["ssh_enabled"])
        drop_in = (ROOT / "etc/ssh/sshd_config.d/90-jh7110.conf").read_text()
        directives = [
            line
            for line in drop_in.splitlines()
            if line.strip() and not line.startswith("#")
        ]
        self.assertEqual(directives, ["PermitRootLogin no"])
        self.assertIn("sshd -t", self.calls())
        self.assertTrue(self.state()["ssh_enabled"])

    def test_configure_ssh_puts_the_file_back_when_sshd_refuses_it(self):
        target = ROOT / "etc/ssh/sshd_config.d/90-jh7110.conf"
        write(target, "# a configuration that was there before\nPermitRootLogin no\n")
        before = target.read_text()
        os.environ["SSHD_STATUS"] = "1"
        try:
            error = self.refused("ConfigureSSH", {"enabled": True})
        finally:
            del os.environ["SSHD_STATUS"]
        # What sshd said is what the user is shown: it names the directive that
        # was refused, which the generic message cannot.
        self.assertEqual(error, "refusing on purpose")
        self.assertEqual(target.read_text(), before, "a refused config was left in place")
        os.unlink(target)
        os.environ["SSHD_STATUS"] = "1"
        try:
            self.refused("ConfigureSSH", {"enabled": True})
        finally:
            del os.environ["SSHD_STATUS"]
        self.assertFalse(target.exists(), "a refused config was left behind")

    def test_root_login_over_ssh_cannot_be_enabled(self):
        self.assertIn(
            "not something this setup enables",
            self.refused("ConfigureSSH", {"enabled": True, "permit_root_login": True}),
        )
        self.refused("ConfigureSSH", {"enabled": "yes"})
        self.refused("ConfigureSSH", {"enabled": "no"})

    def test_ssh_can_be_left_off(self):
        result = self.ok("ConfigureSSH", {"enabled": False})
        self.assertFalse(result["ssh_enabled"])
        self.assertFalse(self.state()["ssh_enabled"])
        self.assertIn("systemctl disable --now ssh.service", self.calls())

    # -- the report and the end -------------------------------------------
    def test_save_hardware_writes_the_report(self):
        report = {"board": "mars", "checks": [{"name": "hdmi", "status": "ok"}]}
        self.ok("SaveHardware", {"report": report})
        saved = json.loads((ROOT / "var/lib/jh7110/hardware.json").read_text())
        self.assertEqual(saved, report)
        self.refused("SaveHardware", {"report": "not an object"})
        self.refused("SaveHardware", {"report": ["a", "list"]})
        self.refused("SaveHardware", {})
        self.refused("SaveHardware", {"report": {"blob": "x" * (70 * 1024)}})

    def test_finalize_needs_an_account_and_a_name(self):
        self.assertIn("account", self.refused("FinalizeSetup", {}))
        self.ok("CreateUser", {"username": "jh7110", "password": "longenough"})
        self.assertIn("device name", self.refused("FinalizeSetup", {}))
        self.ok("SetHostname", {"hostname": "jh7110-mars"})
        result = self.ok("FinalizeSetup", {"network_configured": True})
        self.assertTrue(result["finalized"])
        self.assertTrue(self.done_file.exists())
        self.assertTrue(self.state()["finalized"])
        self.assertTrue(self.state()["network_configured"])
        done = self.done_file.read_text()
        self.assertIn("jh7110-mars", done)
        self.assertIn("jh7110", done)
        self.assertNotIn("longenough", done)
        self.assertNotIn("longenough", json.dumps(self.ok("GetState")))

    def test_a_finished_setup_can_no_longer_be_changed(self):
        # The socket stays where it is for as long as the board exists, so the
        # state is what stops it from being a way to rewrite the machine after
        # the first run is over.  Only a reset - which root has to ask for -
        # opens it again.
        self.ok("CreateUser", {"username": "jh7110", "password": "longenough"})
        self.ok("SetHostname", {"hostname": "jh7110-mars"})
        self.ok("FinalizeSetup", {})
        for method, params in (
            ("SetHostname", {"hostname": "another-name"}),
            ("CreateUser", {"username": "someone", "password": "longenough"}),
            ("SetUserPassword", {"username": "jh7110", "password": "longenough"}),
            ("SetTimezone", {"timezone": "UTC"}),
            ("SetLocale", {"locale": "zh_CN.UTF-8"}),
            ("SetKeymap", {"keymap": "us"}),
            ("ConfigureSSH", {"enabled": True}),
            ("FinalizeSetup", {}),
        ):
            self.assertIn("already finished", self.refused(method, params))
        # Reading is always allowed: the wizard and jh7110-info both ask a
        # finished board what it is.
        self.assertTrue(self.ok("GetState")["finalized"])
        self.assertTrue(self.ok("GetBoard")["board_id"] == "mars")
        self.assertTrue(self.ok("Ping")["version"] == 1)

    def test_the_done_file_holds_no_secret(self):
        self.ok("CreateUser", {"username": "jh7110", "password": "longenough"})
        self.ok("SetHostname", {"hostname": "jh7110-mars"})
        self.ok("ConfigureSSH", {"enabled": True})
        self.ok("FinalizeSetup", {})
        for path in ROOT.rglob("*"):
            if path.is_file():
                self.assertNotIn(
                    "longenough",
                    path.read_text(errors="replace"),
                    "%s holds the password" % path,
                )


class SocketTests(unittest.TestCase):
    """The socket the wizard actually talks to."""

    @classmethod
    def setUpClass(cls):
        build_sandbox()
        cls.socket_path = Path(os.environ["JH7110_OOBE_SOCKET"])
        cls.process = subprocess.Popen(
            [sys.executable, str(BACKEND)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        deadline = time.time() + 20
        while time.time() < deadline and not cls.socket_path.exists():
            if cls.process.poll() is not None:
                raise AssertionError(cls.process.stdout.read())
            time.sleep(0.1)
        if not cls.socket_path.exists():
            cls.process.kill()
            raise AssertionError("the backend did not create its socket")

    @classmethod
    def tearDownClass(cls):
        cls.process.terminate()
        try:
            cls.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            cls.process.kill()

    def request(self, payload, raw=None):
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(20)
        connection.connect(str(self.socket_path))
        connection.sendall((raw if raw is not None else json.dumps(payload) + "\n").encode())
        data = b""
        while b"\n" not in data:
            chunk = connection.recv(65536)
            if not chunk:
                break
            data += chunk
        connection.close()
        return json.loads(data.split(b"\n", 1)[0].decode())

    def test_the_socket_is_only_for_its_owner_and_the_greeter(self):
        mode = stat.S_IMODE(os.stat(self.socket_path).st_mode)
        self.assertEqual(mode & 0o007, 0, "the socket is open to everybody")
        self.assertEqual(mode & 0o700, 0o600, "the owner cannot use its own socket")

    def test_a_round_trip_over_the_socket(self):
        response = self.request({"method": "Ping"})
        self.assertTrue(response["ok"])
        self.assertEqual(response["result"]["version"], 1)

    def test_the_socket_answers_bad_input_instead_of_dying(self):
        self.assertFalse(self.request(None, raw="not json at all\n")["ok"])
        self.assertFalse(self.request({"method": "Nope"})["ok"])
        self.assertFalse(self.request({"method": "SetHostname", "params": 3})["ok"])
        self.assertTrue(self.request({"method": "Ping"})["ok"], "the backend did not survive")

    def test_a_second_socket_is_refused_rather_than_shared(self):
        # A second backend on the same path would mean two writers racing for
        # the state file; the standalone path refuses instead of unlinking a
        # socket somebody is listening on.
        second = subprocess.run(
            [sys.executable, str(BACKEND)],
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertNotEqual(second.returncode, 0)
        self.assertIn("already listening", second.stdout + second.stderr)


if __name__ == "__main__":
    try:
        unittest.main(verbosity=2)
    finally:
        shutil.rmtree(SANDBOX, ignore_errors=True)
