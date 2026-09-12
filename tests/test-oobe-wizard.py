#!/usr/bin/env python3
"""Tests for the first-run wizard.

Two halves.  The first drives /usr/lib/jh7110/oobe.py directly: the rules the
pages apply, the NetworkManager calls, the hardware report and the order the
settings are applied in.  That module was split out of the window precisely so
that it can be tested here.

The second half runs the window itself against a stand-in for GTK.  The real
GTK needs a display, which the build host does not have, so what these tests
prove is not that the pixels look right - they prove that every page can be
built, that walking through them with valid input reaches the end, that the
password never reaches the log, and that a failed step offers a retry.  The
stand-in refuses nothing the real toolkit would refuse, so it is a check on
this program's logic, not on its rendering.

Run: python3 tests/test-oobe-wizard.py
"""
import json
import os
import re
import shutil
import socket
import sys
import tempfile
import time
import threading
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
LIB_DIR = os.path.join(REPO, "rootfs/overlay/usr/lib/jh7110")
BIN_DIR = os.path.join(REPO, "rootfs/overlay/usr/bin")
WIZARD_SOURCE = os.path.join(BIN_DIR, "jh7110-oobe")

sys.path.insert(0, LIB_DIR)
# The import below is of the module the image ships, and a stock CPython writes
# bytecode beside the source it imports - which here is the tree the image is
# built from.  Running a test must not change what it is testing.
sys.dont_write_bytecode = True
import oobe  # noqa: E402


def load_wizard_source():
    with open(WIZARD_SOURCE) as stream:
        return stream.read()


# ---------------------------------------------------------------------------
# A stand-in for GTK
# ---------------------------------------------------------------------------
class StyleContext:
    def __init__(self):
        self.classes = set()

    def add_class(self, name):
        self.classes.add(name)

    def remove_class(self, name):
        self.classes.remove(name) if name in self.classes else None

    def has_class(self, name):
        return name in self.classes


class Widget:
    """The parts of Gtk.Widget the wizard uses, and a signal of its own."""

    def __init__(self, **kwargs):
        self.kwargs = kwargs
        self.style = StyleContext()
        self.visible = True
        self.sensitive = True
        self.handlers = {}
        self.children = []
        for key, value in kwargs.items():
            setattr(self, key, value)

    def get_style_context(self):
        return self.style

    def connect(self, signal, handler):
        self.handlers.setdefault(signal, []).append(handler)

    def emit(self, signal, *args):
        for handler in self.handlers.get(signal, []):
            handler(self, *args)

    def show_all(self):
        self.visible = True

    def set_visible(self, visible):
        self.visible = visible

    def set_sensitive(self, sensitive):
        self.sensitive = sensitive

    def get_sensitive(self):
        return self.sensitive

    def set_border_width(self, _width):
        pass

    def grab_focus(self):
        self.focused = True

    def set_tooltip_text(self, _text):
        pass

    def add(self, child):
        self.children.append(child)


class Window(Widget):
    def set_title(self, title):
        self.title = title

    def set_position(self, _position):
        pass

    def set_default_size(self, width, height):
        self.default_size = (width, height)

    def set_size_request(self, width, height):
        self.requested_size = (width, height)

    def set_default(self, widget):
        self.default_widget = widget

    def destroy(self):
        self.destroyed = True


class Box(Widget):
    def pack_start(self, child, _expand, _fill, _padding):
        self.children.append(child)

    def pack_end(self, child, _expand, _fill, _padding):
        self.children.append(child)

    def get_children(self):
        return list(self.children)

    def remove(self, child):
        self.children.remove(child)


class Label(Widget):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.text = kwargs.get("label", "")

    def set_text(self, text):
        self.text = text

    def get_text(self):
        return self.text

    def set_line_wrap(self, wrap):
        self.line_wrap = wrap

    def set_ellipsize(self, mode):
        self.ellipsize = mode

    def set_selectable(self, selectable):
        self.selectable = selectable


class Entry(Widget):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.text = kwargs.get("text", "")

    def get_text(self):
        return self.text

    def set_text(self, text):
        self.text = text
        # GTK emits "changed" when the text is set programmatically, and the
        # pages rely on that to re-check what is in the form.
        self.emit("changed")

    def set_placeholder_text(self, text):
        self.placeholder = text

    def set_activates_default(self, value):
        self.activates_default = value

    def set_visibility(self, visible):
        self.visible_text = visible

    def set_input_purpose(self, purpose):
        self.input_purpose = purpose


class ComboBoxText(Widget):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.ids = []
        self.entries = []
        self.active_id = None
        self.child = Entry() if kwargs.get("with_entry") else None

    @classmethod
    def new_with_entry(cls):
        return cls(with_entry=True)

    def append(self, identifier, text):
        self.ids.append(identifier)
        self.entries.append(text)

    def append_text(self, text):
        self.entries.append(text)

    def set_active_id(self, identifier):
        if identifier in self.ids:
            self.active_id = identifier

    def get_active_id(self):
        if self.child is not None:
            return self.child.get_text()
        return self.active_id

    def get_active(self):
        if self.active_id in self.ids:
            return self.ids.index(self.active_id)
        return -1

    def get_child(self):
        return self.child


class Switch(Widget):
    def set_active(self, active):
        self.active = active

    def get_active(self):
        return getattr(self, "active", False)


class Expander(Widget):
    def set_expanded(self, expanded):
        self.expanded = expanded


class ListBoxRow(Widget):
    pass


class ListBox(Box):
    def set_selection_mode(self, _mode):
        pass


class Grid(Widget):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.cells = {}

    def attach(self, child, column, row, width, height):
        self.cells[(column, row)] = child
        self.children.append(child)

    def get_children(self):
        return list(self.children)

    def remove(self, child):
        self.children.remove(child)
        for cell, widget in list(self.cells.items()):
            if widget is child:
                del self.cells[cell]


class ScrolledWindow(Widget):
    def set_policy(self, horizontal, vertical):
        self.policy = (horizontal, vertical)


class Stack(Widget):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.named = {}
        self.visible_child = None

    def add_named(self, child, name):
        self.named[name] = child
        self.children.append(child)

    def set_visible_child_name(self, name):
        self.visible_child = name

    def set_transition_type(self, _kind):
        pass

    def set_transition_duration(self, _duration):
        pass


class ProgressBar(Widget):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.fraction = 0.0

    def set_pulse_step(self, step):
        self.pulse_step = step

    def pulse(self):
        self.pulses = getattr(self, "pulses", 0) + 1

    def set_fraction(self, fraction):
        self.fraction = fraction


class Button(Widget):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.label = kwargs.get("label", "")

    def set_label(self, label):
        self.label = label

    def get_label(self):
        return self.label

    def set_can_default(self, value):
        self.can_default = value

    def set_sensitive(self, sensitive):
        self.sensitive = sensitive


class Dialog(Widget):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.content = Box()
        self.buttons = {}
        self.response = None

    def add_button(self, label, response):
        button = Button(label=label)
        self.buttons[label] = (button, response)
        return button

    def get_content_area(self):
        return self.content

    def set_default_response(self, _response):
        pass

    def set_spacing(self, _spacing):
        pass

    def run(self):
        return self.response

    def destroy(self):
        self.destroyed = True


class MessageDialog(Dialog):
    def format_secondary_text(self, text):
        self.secondary = text


class CssProvider:
    def load_from_data(self, data):
        self.data = data


class Screen:
    def __init__(self, width=1024, height=600):
        self.width = width
        self.height = height

    def get_width(self):
        return self.width

    def get_height(self):
        return self.height


class Idle:
    """GLib's main loop, reduced to a queue the test drains by hand.

    Running the callbacks immediately would hide the asynchrony the wizard is
    built around, and running the timeout would loop forever - pulse() asks to
    be called again for as long as the work is running.
    """

    pending = []
    timeouts = {}
    next_timeout = 1

    @classmethod
    def reset(cls):
        cls.pending = []
        cls.timeouts = {}
        cls.next_timeout = 1

    @classmethod
    def idle_add(cls, function, *args):
        cls.pending.append((function, args))
        return len(cls.pending)

    @classmethod
    def timeout_add(cls, _milliseconds, function):
        identifier = cls.next_timeout
        cls.next_timeout += 1
        cls.timeouts[identifier] = function
        return identifier

    @classmethod
    def source_remove(cls, identifier):
        cls.timeouts.pop(identifier, None)

    @classmethod
    def drain(cls):
        count = 0
        while cls.pending:
            function, args = cls.pending.pop(0)
            function(*args)
            count += 1
        return count


def install_fake_gtk(screen=None):
    """Put a stand-in for gi.repository in sys.modules and return its Gtk."""
    Gtk = types.ModuleType("gi.repository.Gtk")
    Gtk.Window = Window
    Gtk.Box = Box
    Gtk.Label = Label
    Gtk.Entry = Entry
    Gtk.ComboBoxText = ComboBoxText
    Gtk.Switch = Switch
    Gtk.Expander = Expander
    Gtk.ListBox = ListBox
    Gtk.ListBoxRow = ListBoxRow
    Gtk.Grid = Grid
    Gtk.ScrolledWindow = ScrolledWindow
    Gtk.Stack = Stack
    Gtk.ProgressBar = ProgressBar
    Gtk.Button = Button
    Gtk.Dialog = Dialog
    Gtk.MessageDialog = MessageDialog
    Gtk.CssProvider = CssProvider
    Gtk.StyleContext = StyleContext
    Gtk.StyleContext.add_provider_for_screen = lambda *args: None
    Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION = 600
    Gtk.WindowType = types.SimpleNamespace(TOPLEVEL=0)
    Gtk.WindowPosition = types.SimpleNamespace(CENTER=1)
    Gtk.Orientation = types.SimpleNamespace(VERTICAL=0, HORIZONTAL=1)
    Gtk.PolicyType = types.SimpleNamespace(NEVER=0, AUTOMATIC=1)
    Gtk.SelectionMode = types.SimpleNamespace(NONE=0)
    Gtk.InputPurpose = types.SimpleNamespace(PASSWORD=0)
    Gtk.ResponseType = types.SimpleNamespace(CANCEL=0, OK=1)
    Gtk.MessageType = types.SimpleNamespace(WARNING=2)
    Gtk.ButtonsType = types.SimpleNamespace(CLOSE=0)
    Gtk.StackTransitionType = types.SimpleNamespace(SLIDE_LEFT_RIGHT=0)
    Gtk.main = lambda *args: None
    Gtk.main_quit = lambda *args: None

    Pango = types.ModuleType("gi.repository.Pango")
    Pango.EllipsizeMode = types.SimpleNamespace(END=3)

    GLib = types.ModuleType("gi.repository.GLib")
    GLib.idle_add = Idle.idle_add
    GLib.timeout_add = Idle.timeout_add
    GLib.source_remove = Idle.source_remove

    Gdk = types.ModuleType("gi.repository.Gdk")
    Gdk.Screen = types.SimpleNamespace(get_default=lambda: screen or Screen())

    repository = types.ModuleType("gi.repository")
    repository.Gtk = Gtk
    repository.Gdk = Gdk
    repository.GLib = GLib
    repository.Pango = Pango

    gi = types.ModuleType("gi")
    gi.require_version = lambda _name, _version: None
    gi.repository = repository

    sys.modules["gi"] = gi
    sys.modules["gi.repository"] = repository
    sys.modules["gi.repository.Gtk"] = Gtk
    sys.modules["gi.repository.Gdk"] = Gdk
    sys.modules["gi.repository.GLib"] = GLib
    sys.modules["gi.repository.Pango"] = Pango
    return Gtk


def load_wizard_module():
    """Execute jh7110-oobe as a module, with the fake GTK in place."""
    module = types.ModuleType("jh7110_oobe")
    module.__file__ = WIZARD_SOURCE
    source = load_wizard_source()
    exec(compile(source, WIZARD_SOURCE, "exec"), module.__dict__)
    sys.modules["jh7110_oobe"] = module
    # The program imports GTK in main(); the tests build the window directly, so
    # they have to do the same step first.
    error = module.load_gtk()
    if error is not None:
        raise AssertionError("the wizard did not load its toolkit: %s" % error)
    return module


def run_in_background_now(wizard, work, done):
    """The wizard's in_background with the thread taken out (see WizardTests)."""
    try:
        result, error = work(), None
    except Exception as exception:  # noqa: BLE001 - it is shown to the user
        result, error = None, str(exception) or exception.__class__.__name__
    Idle.idle_add(done, result, error)


# ---------------------------------------------------------------------------
class Sandbox(unittest.TestCase):
    def setUp(self):
        self.sandbox = tempfile.mkdtemp(prefix="jh7110-oobe-")
        self.addCleanup(shutil.rmtree, self.sandbox, True)

    def path(self, *parts):
        return os.path.join(self.sandbox, *parts)

    def write(self, relative, content):
        target = self.path(relative)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "w") as stream:
            stream.write(content)
        return target


# ---------------------------------------------------------------------------
# The rules the pages apply
# ---------------------------------------------------------------------------
class ValidationTests(unittest.TestCase):
    def test_usernames_that_are_accepted(self):
        for name in ("jh7110", "user", "a", "user_1", "user-name", "_private", "u" * 32):
            self.assertIsNone(oobe.username_problem(name), name)

    def test_usernames_that_are_refused(self):
        for name in ("", "Root", "root", "1user", "user name", "user.name", "用户", "u" * 33):
            self.assertIsNotNone(oobe.username_problem(name), name)

    def test_root_is_refused_for_its_own_reason(self):
        self.assertIn("root", oobe.username_problem("root"))

    def test_passwords(self):
        self.assertIsNone(oobe.password_problem("12345678", "12345678"))
        self.assertIsNotNone(oobe.password_problem("", ""))
        self.assertIsNotNone(oobe.password_problem("1234567", "1234567"))
        self.assertIsNotNone(oobe.password_problem("12345678", "12345679"))
        # Characters, not bytes: eight Chinese characters are a password.
        self.assertIsNone(oobe.password_problem("一二三四五六七八", "一二三四五六七八"))

    def test_hostnames(self):
        for name in ("jh7110-mars", "mars", "a", "board-1", "X1"):
            self.assertIsNone(oobe.hostname_problem(name), name)
        for name in ("", "-mars", "mars-", "mar s", "马尔斯", "a" * 64, "123"):
            self.assertIsNotNone(oobe.hostname_problem(name), name)

    def test_display_names(self):
        self.assertIsNone(oobe.display_name_problem("番鼠大王"))
        self.assertIsNone(oobe.display_name_problem(""))
        # GECOS is colon and comma separated, so neither can be part of a name.
        for name in ("a:b", "a,b", "a\nb", "x" * 65):
            self.assertIsNotNone(oobe.display_name_problem(name), name)


class ParsingTests(unittest.TestCase):
    def test_escaped_colons_are_one_field(self):
        self.assertEqual(
            oobe.split_escaped(r"*:My\:Net:80:WPA2"), ["*", "My:Net", "80", "WPA2"]
        )
        self.assertEqual(oobe.split_escaped(r"a\\b:c"), ["a\\b", "c"])
        self.assertEqual(oobe.split_escaped(""), [""])


class NetworkTests(Sandbox):
    def setUp(self):
        super().setUp()
        self.calls = []
        self.answers = []
        self.original = oobe.run_command

        def fake(argv, stdin_text=None, timeout=60):
            self.calls.append((list(argv), stdin_text))
            if self.answers:
                return self.answers.pop(0)
            return 0, "", ""

        oobe.run_command = fake
        self.addCleanup(setattr, oobe, "run_command", self.original)

    def test_the_password_never_enters_the_command_line(self):
        argv = oobe.wifi_connect_command("My Net", True)
        self.assertIn("--ask", argv)
        self.assertNotIn("password", argv)
        self.assertEqual(argv.count("My Net"), 1)

    def test_an_open_network_is_joined_without_asking(self):
        argv = oobe.wifi_connect_command("Cafe", False)
        self.assertNotIn("--ask", argv)

    def test_an_ssid_that_looks_like_an_option_is_refused(self):
        for ssid in ("-e", "--ask", ""):
            with self.assertRaises(oobe.BackendError):
                oobe.wifi_connect_command(ssid, True)

    def test_the_password_is_written_to_standard_input(self):
        self.answers = [(0, "Device 'wlan0' successfully activated", "")]
        self.assertIsNone(oobe.wifi_connect("My Net", "hunter22!", secured=True))
        argv, stdin_text = self.calls[-1]
        self.assertEqual(stdin_text, "hunter22!\n")
        self.assertNotIn("hunter22!", argv)

    def test_an_open_network_gets_nothing_on_standard_input(self):
        self.answers = [(0, "", "")]
        self.assertIsNone(oobe.wifi_connect("Cafe", "", secured=False))
        _argv, stdin_text = self.calls[-1]
        self.assertIsNone(stdin_text)

    def test_a_failure_is_reported_with_nmclis_own_last_line(self):
        self.answers = [(4, "", "Error: Connection activation failed.\n")]
        message = oobe.wifi_connect("My Net", "wrong", secured=True)
        self.assertIn("Connection activation failed", message)

    def test_a_timeout_is_reported_as_a_timeout(self):
        self.answers = [(124, "", "timed out")]
        self.assertIn("超时", oobe.wifi_connect("My Net", "wrong", secured=True))

    def test_networks_are_deduplicated_and_sorted_by_signal(self):
        self.answers = [
            (
                0,
                "\n".join(
                    [
                        ":Far:31:WPA2",
                        "*:Near:88:WPA2",
                        ":Near:55:WPA2",
                        ":Open:70:",
                        ":Open:71:--",
                    ]
                ),
                "",
            )
        ]
        networks = oobe.wifi_networks()
        self.assertEqual([network["ssid"] for network in networks], ["Near", "Open", "Far"])
        self.assertEqual(networks[0]["signal"], 88)
        self.assertTrue(networks[0]["connected"])
        self.assertEqual(networks[1]["security"], "")

    def test_a_missing_nmcli_is_not_an_error(self):
        self.answers = [(127, "", "No such file or directory")]
        self.assertEqual(oobe.wifi_devices(), [])
        self.assertEqual(oobe.wifi_networks(), [])
        self.assertFalse(oobe.ethernet_connected())


class HardwareTests(Sandbox):
    def setUp(self):
        super().setUp()
        self.sysfs = self.path("sys")
        self.procfs = self.path("proc")
        self.icd = self.path("etc/vulkan/icd.d")
        self.library = self.path("usr/lib/libVK_IMG.so")

    def test_a_board_with_everything_reports_ok(self):
        self.write("sys/firmware/devicetree/base/model", "Milk-V Mars\n\0")
        self.write("proc/meminfo", "MemTotal:        8123456 kB\n")
        self.write("sys/class/drm/card0-HDMI-A-1/status", "connected\n")
        self.write("sys/class/drm/card0-HDMI-A-1/modes", "1920x1080\n")
        os.makedirs(self.path("sys/class/drm/card0/device"), exist_ok=True)
        os.symlink(
            "/sys/bus/platform/drivers/pvrsrvkm", self.path("sys/class/drm/card0/device/driver")
        )
        self.write("etc/vulkan/icd.d/img.json", "{}")
        self.write("usr/lib/libVK_IMG.so", "")
        self.write("sys/class/net/eth0/device/uevent", "")
        self.write("sys/block/mmcblk1/size", "62865408\n")
        report = oobe.hardware_report(
            sysfs=self.sysfs, procfs=self.procfs, icd_dir=self.icd, vendor_library=self.library
        )
        by_name = {item["name"]: item for item in report["checks"]}
        self.assertEqual(by_name["主板"]["status"], "ok")
        self.assertIn("Milk-V Mars", by_name["主板"]["detail"])
        self.assertIn("7.7 GiB", by_name["内存"]["detail"])
        self.assertEqual(by_name["显示接口"]["status"], "ok")
        self.assertIn("1920x1080", by_name["显示接口"]["detail"])
        self.assertEqual(by_name["GPU"]["status"], "available")
        self.assertIn("pvrsrvkm", by_name["GPU"]["detail"])

    def test_an_empty_machine_reports_missing_things_rather_than_failing(self):
        report = oobe.hardware_report(sysfs=self.sysfs, procfs=self.procfs)
        self.assertTrue(report["checks"])
        self.assertEqual(report["summary"]["error"], 0)
        by_name = {item["name"]: item for item in report["checks"]}
        self.assertEqual(by_name["主板"]["status"], "not-verified")

    def test_a_connector_with_no_display_is_not_a_failure(self):
        self.write("sys/class/drm/card0-HDMI-A-1/status", "disconnected\n")
        result = oobe.check_display(sysfs=self.sysfs)
        self.assertEqual(result["status"], "not-detected")
        self.assertIn("没有接显示器", result["detail"])

    def test_the_gpu_check_does_not_claim_more_than_it_knows(self):
        self.write("etc/vulkan/icd.d/img.json", "{}")
        self.write("usr/lib/libVK_IMG.so", "")
        result = oobe.check_gpu(
            sysfs=self.sysfs, icd_dir=self.icd, vendor_library=self.library
        )
        # The ICD is installed, but nothing here has rendered with it, so the
        # status is not "ok".
        self.assertNotEqual(result["status"], "ok")
        self.assertEqual(result["status"], "not-verified")

    def test_one_broken_check_does_not_stop_the_rest(self):
        def bomb(**_kwargs):
            raise RuntimeError("no such directory")

        original = oobe.HARDWARE_CHECKS
        oobe.HARDWARE_CHECKS = (bomb,) + original
        self.addCleanup(setattr, oobe, "HARDWARE_CHECKS", original)
        report = oobe.hardware_report(sysfs=self.sysfs, procfs=self.procfs)
        self.assertEqual(report["checks"][0]["status"], "error")
        self.assertIn("no such directory", report["checks"][0]["detail"])
        self.assertEqual(len(report["checks"]), len(original) + 1)

    def test_checks_are_only_given_the_paths_they_ask_for(self):
        # check_memory takes procfs and check_display takes sysfs; passing both
        # to each one used to raise TypeError.
        report = oobe.hardware_report(sysfs=self.sysfs, procfs=self.procfs)
        self.assertEqual(report["summary"]["error"], 0)


class ChoiceTests(Sandbox):
    def test_only_real_zones_are_offered(self):
        zoneinfo = self.path("zoneinfo")
        self.write("zoneinfo/Asia/Shanghai", "")
        self.write("zoneinfo/UTC", "")
        self.write("zoneinfo/+VERSION", "2024a\n")
        self.write("zoneinfo/zone.tab", "#\n")
        self.write("zoneinfo/posix/Asia/Shanghai", "")
        os.symlink("Shanghai", self.path("zoneinfo/Asia/Chongqing"))
        zones = oobe.available_timezones(zoneinfo)
        self.assertIn("Asia/Shanghai", zones)
        self.assertIn("Asia/Chongqing", zones)
        self.assertNotIn("+VERSION", zones)
        self.assertNotIn("zone.tab", zones)
        self.assertNotIn("posix/Asia/Shanghai", zones)

    def test_missing_trees_fall_back_to_a_short_list(self):
        zones = oobe.available_timezones(self.path("nothing"))
        self.assertIn("Asia/Shanghai", zones)
        self.assertIn("us", oobe.available_keymaps(self.path("nothing")))

    def test_locales_have_labels(self):
        self.assertEqual(oobe.locale_label("zh_CN.UTF-8"), "简体中文")
        self.assertEqual(oobe.locale_label("xx_XX.UTF-8"), "xx_XX.UTF-8")


# ---------------------------------------------------------------------------
# The client, over a real socket
# ---------------------------------------------------------------------------
class BackendClientTests(Sandbox):
    def setUp(self):
        super().setUp()
        self.socket_path = self.path("oobe.sock")
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(self.socket_path)
        self.server.listen(4)
        self.server.settimeout(5)
        self.requests = []
        self.answer = {"ok": True, "result": {}}
        self.running = True
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop)

    def stop(self):
        self.running = False
        self.server.close()

    def serve(self):
        while self.running:
            try:
                connection, _address = self.server.accept()
            except OSError:
                return
            with connection:
                data = b""
                while b"\n" not in data:
                    chunk = connection.recv(4096)
                    if not chunk:
                        break
                    data += chunk
                if data:
                    self.requests.append(json.loads(data.decode("utf-8")))
                    connection.sendall(json.dumps(self.answer).encode("utf-8") + b"\n")

    def test_a_call_arrives_as_the_documented_request(self):
        self.answer = {"ok": True, "result": {"board_name": "Milk-V Mars"}}
        client = oobe.Backend(self.socket_path)
        self.assertEqual(client.get_board()["board_name"], "Milk-V Mars")
        self.assertEqual(self.requests[-1], {"method": "GetBoard", "params": {}})

    def test_arguments_are_named_and_never_a_command(self):
        client = oobe.Backend(self.socket_path)
        client.set_hostname("jh7110-mars")
        self.assertEqual(
            self.requests[-1], {"method": "SetHostname", "params": {"hostname": "jh7110-mars"}}
        )

    def test_a_refusal_becomes_an_error_with_the_backends_own_words(self):
        self.answer = {"ok": False, "error": "the setup is already finished"}
        client = oobe.Backend(self.socket_path)
        with self.assertRaises(oobe.BackendError) as caught:
            client.create_user("jh7110", "12345678")
        self.assertIn("already finished", str(caught.exception))

    def test_a_missing_socket_is_reported_in_words(self):
        client = oobe.Backend(self.path("nothing.sock"))
        with self.assertRaises(oobe.BackendError) as caught:
            client.get_state()
        # The message names the thing that is missing; the window puts it
        # inside a Chinese sentence when it shows it.
        self.assertIn("setup service", str(caught.exception))
        self.assertIn("No such file", str(caught.exception))

    def test_an_unreadable_answer_is_reported_rather_than_crashing(self):
        self.answer = "not json"
        client = oobe.Backend(self.socket_path)
        # The stand-in server sends whatever it is given; json.dumps of a string
        # produces a JSON string, which is not a response object, so the client
        # has to cope with a document it does not understand.
        with self.assertRaises(oobe.BackendError):
            client.get_state()


# ---------------------------------------------------------------------------
# The order the settings are applied in
# ---------------------------------------------------------------------------
class FakeBackend:
    def __init__(self, board=None, fail_on=None):
        self.board = board or {
            "board_name": "Milk-V Mars",
            "board_id": "mars",
            "default_hostname": "jh7110-mars",
            "default_user": "jh7110",
            "timezone": "Asia/Shanghai",
            "locale": "zh_CN.UTF-8",
        }
        self.state = {}
        self.calls = []
        self.fail_on = fail_on

    def _record(self, method, **params):
        self.calls.append((method, params))
        if method == self.fail_on:
            raise oobe.BackendError("refusing on purpose")
        return {}

    # Reads are not recorded: the tests that assert nothing was changed mean
    # nothing was changed, not that nothing was asked.
    def ping(self):
        return {}

    def get_board(self):
        return self.board

    def get_state(self):
        return self.state

    def set_hostname(self, hostname):
        return self._record("SetHostname", hostname=hostname)

    def create_user(self, username, password, display_name=""):
        return self._record("CreateUser", username=username, password=password,
                            display_name=display_name)

    def set_timezone(self, timezone):
        return self._record("SetTimezone", timezone=timezone)

    def set_locale(self, locale, language=""):
        return self._record("SetLocale", locale=locale)

    def set_keymap(self, keymap):
        return self._record("SetKeymap", keymap=keymap)

    def configure_ssh(self, enabled):
        return self._record("ConfigureSSH", enabled=enabled)

    def save_hardware(self, report):
        return self._record("SaveHardware", report=report)

    def finish(self, network_configured=False):
        return self._record("FinalizeSetup", network_configured=network_configured)


class SessionTests(unittest.TestCase):
    def session(self, backend=None):
        backend = backend or FakeBackend()
        session = oobe.SetupSession(backend)
        session.hostname = "jh7110-test"
        session.username = "tester"
        session.display_name = "测试用户"
        session.timezone = "Asia/Shanghai"
        session.locale = "zh_CN.UTF-8"
        session.keymap = "cn"
        session.ssh_enabled = True
        session.hardware = {"version": 1, "checks": [], "summary": {}}
        return session, backend

    def test_the_defaults_come_from_the_board(self):
        session = oobe.SetupSession(FakeBackend())
        self.assertEqual(session.hostname, "jh7110-mars")
        self.assertEqual(session.username, "jh7110")
        self.assertEqual(session.timezone, "Asia/Shanghai")

    def test_everything_is_applied_in_an_order_that_leaves_a_usable_machine(self):
        session, backend = self.session()
        success, step, message = session.apply_all("correct horse battery")
        self.assertTrue(success, message)
        self.assertEqual(
            [method for method, _params in backend.calls],
            [
                "SetHostname",
                "CreateUser",
                "SetTimezone",
                "SetLocale",
                "SetKeymap",
                "ConfigureSSH",
                "SaveHardware",
                "FinalizeSetup",
            ],
        )
        self.assertEqual(backend.calls[0][1]["hostname"], "jh7110-test")
        self.assertEqual(backend.calls[1][1]["display_name"], "测试用户")

    def test_the_name_is_applied_before_the_account_is_created(self):
        session, backend = self.session()
        session.apply_all("correct horse battery")
        methods = [method for method, _params in backend.calls]
        self.assertLess(methods.index("SetHostname"), methods.index("CreateUser"))

    def test_a_failed_step_names_itself_and_stops_the_sequence(self):
        session, backend = self.session(FakeBackend(fail_on="SetLocale"))
        success, step, message = session.apply_all("correct horse battery")
        self.assertFalse(success)
        self.assertEqual(step, "地区设置")
        self.assertIn("refusing on purpose", message)
        methods = [method for method, _params in backend.calls]
        self.assertIn("SetTimezone", methods)
        self.assertNotIn("ConfigureSSH", methods)
        self.assertNotIn("FinalizeSetup", methods)

    def test_a_retry_after_a_failure_applies_the_rest(self):
        backend = FakeBackend(fail_on="SetLocale")
        session, _backend = self.session(backend)
        self.assertFalse(session.apply_all("correct horse battery")[0])
        backend.fail_on = None
        self.assertTrue(session.apply_all("correct horse battery")[0])

    def test_the_session_never_keeps_the_password(self):
        session, backend = self.session()
        session.apply_all("correct horse battery")
        for value in vars(session).values():
            self.assertNotIn("correct horse battery", repr(value))
        for _method, params in backend.calls:
            password = params.get("password")
            if password is not None:
                self.assertEqual(password, "correct horse battery")

    def test_the_hardware_report_is_only_sent_when_there_is_one(self):
        session, backend = self.session()
        session.hardware = {}
        session.apply_all("correct horse battery")
        self.assertNotIn("SaveHardware", [method for method, _ in backend.calls])

    def test_an_unfinished_sequence_does_not_finalize(self):
        session, _backend = self.session(FakeBackend(fail_on="CreateUser"))
        success, step, _message = session.apply_all("correct horse battery")
        self.assertFalse(success)
        self.assertEqual(step, "用户账户")


class ResetTests(Sandbox):
    def test_resetting_removes_the_markers_but_not_the_account(self):
        state_dir = self.path("var/lib/jh7110")
        home = self.path("home/lightdm")
        os.makedirs(state_dir)
        os.makedirs(home)
        for name in ("oobe.done", "oobe-state.json"):
            with open(os.path.join(state_dir, name), "w") as stream:
                stream.write("{}\n")
        with open(os.path.join(home, ".jh7110-oobe-attempts"), "w") as stream:
            stream.write("2\n")
        removed = oobe.reset(state_dir, home)
        self.assertEqual(len(removed), 3)
        self.assertFalse(os.path.exists(os.path.join(state_dir, "oobe.done")))
        self.assertFalse(os.path.exists(os.path.join(state_dir, "oobe-state.json")))
        self.assertEqual(oobe.setup_attempts(home), 0)

    def test_resetting_an_untouched_machine_removes_nothing(self):
        self.assertEqual(oobe.reset(self.path("var/lib/jh7110"), self.path("home")), [])

    def test_attempts_are_counted_and_cleared(self):
        home = self.path("home")
        os.makedirs(home)
        self.assertEqual(oobe.setup_attempts(home), 0)
        self.assertEqual(oobe.record_attempt(home), 1)
        self.assertEqual(oobe.record_attempt(home), 2)
        self.assertEqual(oobe.setup_attempts(home), 2)
        oobe.clear_attempts(home)
        self.assertEqual(oobe.setup_attempts(home), 0)

    def test_finished_is_what_the_done_file_says(self):
        state_dir = self.path("state")
        os.makedirs(state_dir)
        self.assertFalse(oobe.setup_finished(state_dir))
        with open(os.path.join(state_dir, "oobe.done"), "w") as stream:
            stream.write("done\n")
        self.assertTrue(oobe.setup_finished(state_dir))

    def test_a_socket_that_is_not_a_socket_is_not_ready(self):
        path = self.write("oobe.sock", "")
        self.assertFalse(oobe.oobe_socket_ready(path))
        self.assertFalse(oobe.oobe_socket_ready(self.path("nothing")))


# ---------------------------------------------------------------------------
# The window
# ---------------------------------------------------------------------------
class WizardTests(Sandbox):
    """Drive the real window against a stand-in for GTK."""

    def setUp(self):
        super().setUp()
        Idle.reset()
        install_fake_gtk(Screen(1024, 600))
        self.wizard_module = load_wizard_module()
        # The window hands its slow work to a thread.  A test that raced that
        # thread would be testing the scheduler, so here the work runs where it
        # stands and its result is delivered through the idle queue, which is
        # the same path with the waiting taken out.
        self.real_in_background = self.wizard_module.Wizard.in_background
        self.wizard_module.Wizard.in_background = run_in_background_now
        self.addCleanup(
            setattr, self.wizard_module.Wizard, "in_background", self.real_in_background
        )
        self.backend = FakeBackend()
        self.original_backend = oobe.Backend
        oobe.Backend = lambda *args, **kwargs: self.backend
        self.addCleanup(setattr, oobe, "Backend", self.original_backend)
        self.original_hardware = oobe.hardware_report
        oobe.hardware_report = lambda **kwargs: {
            "version": 1,
            "checks": [{"name": "主板", "detail": "Milk-V Mars", "status": "ok"}],
            "summary": {"ok": 1, "available": 0, "not-detected": 0, "not-verified": 0,
                        "error": 0, "unsupported": 0},
        }
        self.addCleanup(setattr, oobe, "hardware_report", self.original_hardware)
        self.original_wifi_devices = oobe.wifi_devices
        self.original_wifi_networks = oobe.wifi_networks
        self.original_ethernet = oobe.ethernet_connected
        self.original_wifi_connect = oobe.wifi_connect
        oobe.wifi_devices = lambda: []
        oobe.wifi_networks = lambda: []
        oobe.ethernet_connected = lambda: False
        self.addCleanup(setattr, oobe, "wifi_devices", self.original_wifi_devices)
        self.addCleanup(setattr, oobe, "wifi_networks", self.original_wifi_networks)
        self.addCleanup(setattr, oobe, "ethernet_connected", self.original_ethernet)
        self.addCleanup(setattr, oobe, "wifi_connect", self.original_wifi_connect)
        self.log_lines = []
        self.wizard_module.log = lambda message: self.log_lines.append(message)

    def settle(self):
        """Run every callback the wizard has queued, including the ones they queue."""
        for _round in range(50):
            if Idle.drain() == 0:
                return
        self.fail("the wizard kept queueing callbacks: %d left" % len(Idle.pending))

    def wizard(self):
        wizard = self.wizard_module.Wizard()
        self.settle()
        self.addCleanup(wizard.window.destroy)
        return wizard

    def advance(self, wizard):
        """Press "下一步" and let whatever it started finish.

        Going to a page can start work in the background - a network scan, the
        hardware report, the whole setup on the last page - and a test that
        looked at the result before that work came back would be testing the
        timing of a thread rather than the wizard.
        """
        wizard.next_button.emit("clicked")
        self.settle()

    def fill_user_form(self, wizard, password="correct horse battery"):
        wizard.username_entry.set_text("tester")
        wizard.display_entry.set_text("测试用户")
        wizard.password_entry.set_text(password)
        wizard.confirm_entry.set_text(password)

    # ---------------------------------------------------------------- checks
    def test_background_work_really_does_leave_the_main_loop(self):
        # Every other test in this class replaces in_background with a version
        # that runs in place; this one keeps the thread, so that the code the
        # wizard actually ships is exercised at least once.
        wizard = self.wizard()
        seen = []
        self.real_in_background(
            wizard, lambda: "done", lambda result, error: seen.append((result, error))
        )
        for _wait in range(500):
            if Idle.pending:
                break
            time.sleep(0.01)
        self.settle()
        self.assertEqual(seen, [("done", None)])

    def test_every_page_in_the_walkthrough_is_built(self):
        wizard = self.wizard()
        for name, _label in self.wizard_module.STEPS:
            self.assertIn(name, wizard.stack.named, name)
        self.assertEqual(wizard.stack.visible_child, "welcome")

    def test_the_window_fits_the_smallest_supported_screen(self):
        wizard = self.wizard()
        width, height = wizard.window.default_size
        self.assertLessEqual(width, 1024)
        self.assertLessEqual(height, 600)

    def test_no_self_attribute_is_read_before_it_is_set(self):
        source = load_wizard_source()
        assigned = set(re.findall(r"self\.([A-Za-z_]\w*)\s*=", source))
        methods = set(re.findall(r"def ([A-Za-z_]\w*)\(", source))
        used = set(re.findall(r"self\.([A-Za-z_]\w*)", source))
        unknown = sorted(used - assigned - methods)
        self.assertEqual(unknown, [], "attributes used but never assigned: %s" % unknown)

    def test_every_page_and_hook_the_steps_reference_exists(self):
        module = load_wizard_module()
        for name, _label in module.STEPS:
            self.assertTrue(hasattr(module.Wizard, "page_" + name), name)

    def test_the_welcome_page_waits_for_the_backend(self):
        backend = FakeBackend()
        self.backend = backend
        wizard = self.wizard()
        self.assertIn("Milk-V Mars", wizard.subtitle.get_text())
        self.assertFalse(wizard.welcome_error.visible)
        self.assertTrue(wizard.next_button.get_sensitive())

    def test_an_unreachable_backend_is_explained_and_offers_a_retry(self):
        def refuse(*_args, **_kwargs):
            raise oobe.BackendError("the setup service is not running (No such file or directory)")

        self.backend.get_board = refuse
        wizard = self.wizard()
        self.assertIn("无法连接设置服务", wizard.welcome_state.get_text())
        self.assertTrue(wizard.welcome_error.visible)
        self.assertTrue(wizard.retry_button.visible)
        self.assertFalse(wizard.next_button.get_sensitive())

    def test_a_finished_setup_is_not_run_again_by_accident(self):
        self.backend.get_state = lambda: {"finalized": True}
        wizard = self.wizard()
        self.assertIn("--reset", wizard.welcome_error.get_text())
        self.assertFalse(wizard.next_button.get_sensitive())

    # ------------------------------------------------------------ walking it
    def walk_to(self, wizard, target, password="correct horse battery"):
        """Press 下一步 until the named page is showing.

        The user form is filled on the way through, because the walkthrough
        cannot get past that page without it - which is itself the point of the
        page.
        """
        for _step in range(len(self.wizard_module.STEPS) + 4):
            if wizard.current == target:
                return
            if wizard.current == "user":
                self.fill_user_form(wizard, password)
            self.advance(wizard)
        self.fail("the walkthrough never reached %r; it is on %r" % (target, wizard.current))

    def test_a_full_walkthrough_reaches_the_end(self):
        wizard = self.wizard()
        self.assertEqual(wizard.current, "welcome")
        self.walk_to(wizard, "hostname")
        self.assertIn("jh7110-mars", wizard.hostname_entry.get_text())
        self.walk_to(wizard, "user")
        self.assertFalse(wizard.user_error.visible)
        self.walk_to(wizard, "hardware")
        self.assertIn("主板", [child.text for child in wizard.hardware_grid.get_children()])
        self.walk_to(wizard, "confirm")
        self.assertEqual(wizard.next_button.get_label(), "开始设置")
        values = [child.get_text() for child in wizard.confirm_grid.get_children()]
        self.assertIn("jh7110-mars", values)
        self.assertIn("tester", values)
        self.assertNotIn("correct horse battery", values)
        self.walk_to(wizard, "finish")
        self.assertIn("设置完成", wizard.finish_label.get_text())
        self.assertTrue(wizard.next_button.get_sensitive())
        self.assertEqual(wizard.next_button.get_label(), "完成")

    def test_the_walkthrough_applies_what_the_pages_collected(self):
        wizard = self.wizard()
        self.walk_to(wizard, "hostname")
        wizard.hostname_entry.set_text("jh7110-lab")
        self.walk_to(wizard, "region")
        wizard.timezone_combo.get_child().set_text("Asia/Tokyo")
        wizard.keymap_combo.get_child().set_text("jp")
        self.walk_to(wizard, "ssh")
        wizard.ssh_switch.set_active(False)
        self.walk_to(wizard, "finish")
        calls = {method: params for method, params in self.backend.calls}
        self.assertEqual(calls["SetHostname"]["hostname"], "jh7110-lab")
        self.assertEqual(calls["CreateUser"]["username"], "tester")
        self.assertEqual(calls["CreateUser"]["display_name"], "测试用户")
        self.assertEqual(calls["CreateUser"]["password"], "correct horse battery")
        self.assertEqual(calls["SetTimezone"]["timezone"], "Asia/Tokyo")
        self.assertEqual(calls["SetKeymap"]["keymap"], "jp")
        self.assertEqual(calls["ConfigureSSH"]["enabled"], False)
        self.assertIn("FinalizeSetup", calls)

    def test_the_password_never_reaches_the_log(self):
        wizard = self.wizard()
        self.walk_to(wizard, "finish", password="hunter22-hunter22")
        for line in self.log_lines:
            self.assertNotIn("hunter22-hunter22", line)
        # It reached the one call that needs it, and no other.
        carriers = [method for method, params in self.backend.calls if params.get("password")]
        self.assertEqual(carriers, ["CreateUser"])

    def test_the_password_field_is_cleared_when_the_setup_is_done(self):
        wizard = self.wizard()
        self.walk_to(wizard, "finish")
        # The field is not left holding the password while the machine sits at
        # the login prompt.
        self.assertEqual(wizard.password_entry.get_text(), "")
        self.assertEqual(wizard.confirm_entry.get_text(), "")

    def test_the_finalize_page_sends_the_password_and_shows_progress(self):
        wizard = self.wizard()
        self.walk_to(wizard, "finish")
        self.assertEqual(wizard.progress.fraction, 1.0)
        methods = [method for method, _params in self.backend.calls]
        self.assertIn("CreateUser", methods)
        self.assertIn("FinalizeSetup", methods)

    # ------------------------------------------------------------ refusals
    def test_a_short_password_stops_the_walkthrough_at_the_user_page(self):
        wizard = self.wizard()
        self.walk_to(wizard, "user")
        wizard.username_entry.set_text("tester")
        wizard.password_entry.set_text("short")
        wizard.confirm_entry.set_text("short")
        self.advance(wizard)
        self.assertEqual(wizard.current, "user")
        self.assertTrue(wizard.user_error.visible)
        self.assertIn("至少", wizard.user_error.get_text())
        self.assertEqual(self.backend.calls, [])

    def test_two_different_passwords_stop_the_walkthrough(self):
        wizard = self.wizard()
        self.walk_to(wizard, "user")
        wizard.username_entry.set_text("tester")
        wizard.password_entry.set_text("correct horse battery")
        wizard.confirm_entry.set_text("correct horse batteru")
        self.advance(wizard)
        self.assertEqual(wizard.current, "user")
        self.assertIn("不一致", wizard.user_error.get_text())
        self.assertEqual(self.backend.calls, [])

    def test_a_root_username_is_refused_before_anything_else(self):
        wizard = self.wizard()
        self.walk_to(wizard, "user")
        wizard.username_entry.set_text("root")
        wizard.password_entry.set_text("correct horse battery")
        wizard.confirm_entry.set_text("correct horse battery")
        self.advance(wizard)
        self.assertEqual(wizard.current, "user")
        self.assertIn("root", wizard.user_error.get_text())
        self.assertEqual(self.backend.calls, [])

    def test_a_bad_hostname_stops_the_walkthrough_there(self):
        wizard = self.wizard()
        self.walk_to(wizard, "hostname")
        wizard.hostname_entry.set_text("-mars-")
        self.advance(wizard)
        self.assertEqual(wizard.current, "hostname")
        self.assertTrue(wizard.hostname_error.visible)
        self.assertEqual(self.backend.calls, [])

    def test_an_empty_timezone_stops_the_walkthrough_there(self):
        wizard = self.wizard()
        self.walk_to(wizard, "region")
        wizard.timezone_combo.get_child().set_text("")
        self.advance(wizard)
        self.assertEqual(wizard.current, "region")
        self.assertIn("时区", wizard.status.get_text())

    def test_a_failed_step_offers_a_retry_that_continues(self):
        wizard = self.wizard()
        self.backend.fail_on = "SetLocale"
        self.walk_to(wizard, "finish")
        self.assertIn("地区设置", wizard.finish_label.get_text())
        self.assertEqual(wizard.next_button.get_label(), "重试")
        self.backend.fail_on = None
        wizard.next_button.emit("clicked")
        self.settle()
        self.assertIn("设置完成", wizard.finish_label.get_text())

    def test_the_back_button_walks_back(self):
        wizard = self.wizard()
        self.advance(wizard)
        self.assertEqual(wizard.stack.visible_child, "network")
        wizard.back_button.emit("clicked")
        self.assertEqual(wizard.stack.visible_child, "welcome")

    # ------------------------------------------------------------- network
    def test_a_wireless_network_asks_for_the_password_and_sends_it_on_stdin(self):
        oobe.wifi_devices = lambda: ["wlan0"]
        oobe.wifi_networks = lambda: [
            {"ssid": "Cafe", "signal": 70, "security": "WPA2", "connected": False}
        ]
        asked = {}

        def fake_connect(ssid, password="", secured=True, timeout=90):
            asked["ssid"] = ssid
            asked["password"] = password
            asked["secured"] = secured
            return None

        oobe.wifi_connect = fake_connect
        wizard = self.wizard()
        self.advance(wizard)
        self.assertEqual(wizard.stack.visible_child, "network")
        row = wizard.network_list.get_children()[0]
        self.assertEqual(row.network["ssid"], "Cafe")
        # The password dialog is answered by the test rather than by a person.
        wizard.ask_password = lambda ssid: "hunter22!"
        wizard.network_list.emit("row-activated", row)
        self.settle()
        self.assertEqual(asked["ssid"], "Cafe")
        self.assertEqual(asked["password"], "hunter22!")
        self.assertTrue(asked["secured"])
        self.assertIn("Cafe", wizard.status.get_text())

    def test_a_failed_connection_is_reported_on_the_page(self):
        oobe.wifi_devices = lambda: ["wlan0"]
        oobe.wifi_networks = lambda: [
            {"ssid": "Cafe", "signal": 70, "security": "WPA2", "connected": False}
        ]
        oobe.wifi_connect = lambda *args, **kwargs: "密码错误"
        wizard = self.wizard()
        wizard.ask_password = lambda ssid: "wrong"
        self.advance(wizard)
        row = wizard.network_list.get_children()[0]
        wizard.network_list.emit("row-activated", row)
        self.settle()
        self.assertIn("密码错误", wizard.status.get_text())
        self.assertIn("oobe-error", wizard.status.get_style_context().classes)

    def test_cancelling_the_password_dialog_connects_to_nothing(self):
        oobe.wifi_devices = lambda: ["wlan0"]
        oobe.wifi_networks = lambda: [
            {"ssid": "Cafe", "signal": 70, "security": "WPA2", "connected": False}
        ]
        called = []
        oobe.wifi_connect = lambda *args, **kwargs: called.append(args) or None
        wizard = self.wizard()
        wizard.ask_password = lambda ssid: None
        self.advance(wizard)
        row = wizard.network_list.get_children()[0]
        wizard.network_list.emit("row-activated", row)
        self.settle()
        self.assertEqual(called, [])

    def test_a_machine_with_no_wireless_adapter_says_so(self):
        wizard = self.wizard()
        self.advance(wizard)
        self.assertIn("没有检测到无线网卡", wizard.network_hint.get_text())

    def test_an_offline_machine_can_still_be_set_up(self):
        wizard = self.wizard()
        self.advance(wizard)
        self.assertIn("可以跳过", wizard.network_status.get_text())
        self.assertIsNotNone(wizard.session)

    # ------------------------------------------------------------ reset
    def test_reset_refuses_without_root(self):
        status = run_wizard_cli(["--reset", "--state-dir", self.path("state")])
        self.assertEqual(status, 1)

    def test_reset_removes_the_markers(self):
        state_dir = self.path("state")
        os.makedirs(state_dir)
        with open(os.path.join(state_dir, "oobe.done"), "w") as stream:
            stream.write("done\n")
        status = run_wizard_cli(["--reset", "--state-dir", state_dir], as_root=True)
        self.assertEqual(status, 0)
        self.assertFalse(os.path.exists(os.path.join(state_dir, "oobe.done")))

    def test_the_console_fallback_is_named_when_gtk_is_missing(self):
        # Without a usable GTK the wizard has to point at the console path, and
        # it must do so with a message rather than a traceback.
        source = load_wizard_source()
        self.assertIn("jh7110-console-setup", source)
        self.assertIn("--check", source)


def run_wizard_cli(arguments, as_root=False):
    """Run jh7110-oobe as a program with a fake GTK already installed."""
    install_fake_gtk()
    module = load_wizard_module()
    original_argv = sys.argv
    original_geteuid = os.geteuid
    sys.argv = ["jh7110-oobe"] + arguments
    if as_root:
        os.geteuid = lambda: 0
    try:
        return module.main()
    except SystemExit as exit_status:
        return exit_status.code
    finally:
        sys.argv = original_argv
        os.geteuid = original_geteuid


if __name__ == "__main__":
    unittest.main(verbosity=2)
