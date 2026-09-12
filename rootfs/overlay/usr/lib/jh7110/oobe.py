"""The parts of the first-run wizard that are not the window.

The wizard is a GTK program, and GTK is the one thing in this project that
cannot be tested on the build host: it needs a display, and a test that needs a
display is a test that runs on the board or not at all.  Everything that can be
decided without drawing anything therefore lives here - the backend client, the
validation the pages use while the user types, the NetworkManager calls, the
hardware report and the order the settings are applied in.

usr/bin/jh7110-oobe is the window: it draws these values and calls these
methods, and holds no rules of its own.  tests/test-oobe-wizard.py drives this
module against a fake backend and a sandbox of files.
"""
import inspect
import json
import os
import pwd
import re
import socket
import stat
import subprocess

# The wizard talks to the privileged backend over this socket.  It is owned by
# root and readable by the greeter account, which is what the wizard runs as.
SOCKET_PATH = "/run/jh7110/oobe.sock"
STATE_DIR = "/var/lib/jh7110"
DONE_FILE = os.path.join(STATE_DIR, "oobe.done")
STATE_FILE = os.path.join(STATE_DIR, "oobe-state.json")
HARDWARE_FILE = os.path.join(STATE_DIR, "hardware.json")

MIN_PASSWORD_LENGTH = 8

# Where the wizard writes a count of runs that ended without finishing the
# setup, so a wizard that cannot start does not restart for ever.  It lives in
# the greeter account's home because that is where the greeter can write.
ATTEMPT_LIMIT = 3

# The account the greeter runs as, which the polkit rule names too.  Its home
# is where the count above ends up, and it is the one home a reset run with
# sudo does not itself have.
GREETER_USER = "lightdm"


class BackendError(Exception):
    """A refusal from the backend, shown to the user as it is."""


# ---------------------------------------------------------------------------
# Talking to the backend
# ---------------------------------------------------------------------------
class Backend:
    """One request per connection, one line of JSON in and out.

    The socket is the only way the wizard can change the machine, and this
    class is the only place the wizard touches it, so the protocol and the
    error handling exist once.
    """

    def __init__(self, socket_path=SOCKET_PATH, timeout=120):
        self.socket_path = socket_path
        self.timeout = timeout

    def call(self, method, **params):
        request = json.dumps({"method": method, "params": params}) + "\n"
        try:
            connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            connection.settimeout(self.timeout)
            connection.connect(self.socket_path)
        except OSError as error:
            raise BackendError(
                "the setup service is not running (%s)" % error.strerror
            )
        try:
            connection.sendall(request.encode("utf-8"))
            data = b""
            while b"\n" not in data:
                chunk = connection.recv(65536)
                if not chunk:
                    break
                data += chunk
        except OSError as error:
            raise BackendError("the setup service stopped answering (%s)" % error)
        finally:
            connection.close()
        line = data.split(b"\n", 1)[0]
        if not line:
            raise BackendError("the setup service did not answer")
        try:
            response = json.loads(line.decode("utf-8", "replace"))
        except ValueError:
            raise BackendError("the setup service answered something unreadable")
        if not isinstance(response, dict):
            raise BackendError("the setup service answered something unreadable")
        if not response.get("ok"):
            raise BackendError(response.get("error") or "the step could not be completed")
        return response.get("result") or {}

    # The methods, spelled once each.  A page calls one of these rather than
    # building a request, so a method name that is not in the backend's table
    # cannot be typed into a page by accident.
    def ping(self):
        return self.call("Ping")

    def get_board(self):
        return self.call("GetBoard")

    def get_state(self):
        return self.call("GetState")

    def set_hostname(self, hostname):
        return self.call("SetHostname", hostname=hostname)

    def create_user(self, username, password, display_name=""):
        return self.call(
            "CreateUser", username=username, password=password, display_name=display_name
        )

    def set_timezone(self, timezone):
        return self.call("SetTimezone", timezone=timezone)

    def set_locale(self, locale, language=""):
        return self.call("SetLocale", locale=locale, language=language)

    def set_keymap(self, keymap):
        return self.call("SetKeymap", keymap=keymap)

    def configure_ssh(self, enabled):
        return self.call("ConfigureSSH", enabled=enabled)

    def save_hardware(self, report):
        return self.call("SaveHardware", report=report)

    def finish(self, network_configured=False):
        return self.call("FinalizeSetup", network_configured=network_configured)


# ---------------------------------------------------------------------------
# What a page checks while the user is typing
# ---------------------------------------------------------------------------
USERNAME_RE = re.compile(r"^[a-z_][a-z0-9_-]*$")
HOSTNAME_RE = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$")


def username_problem(name):
    """None when the name is usable, otherwise the reason to show.

    The rules are the ones jh7110-account enforces on the board; this copy is
    only so the window can answer while the user is still typing, and the
    account tool is what decides in the end.
    """
    if not name:
        return "请填写用户名"
    if len(name) > 32:
        return "用户名不能超过 32 个字符"
    if not USERNAME_RE.match(name):
        return "只能使用小写字母、数字、下划线和连字符，且以字母或下划线开头"
    if name == "root":
        return "root 账户是锁定状态，请换一个名字"
    return None


def password_problem(password, confirmation):
    """None when the password and its repetition are acceptable."""
    if not password:
        return "请设置密码"
    # Counted in characters: a password typed in Chinese is not shorter for
    # being encoded in more bytes, and the board counts characters too.
    if len(password) < MIN_PASSWORD_LENGTH:
        return "密码至少需要 %d 个字符" % MIN_PASSWORD_LENGTH
    if password != confirmation:
        return "两次输入的密码不一致"
    return None


def hostname_problem(name):
    if not name:
        return "请填写设备名称"
    if len(name) > 63:
        return "设备名称不能超过 63 个字符"
    if not HOSTNAME_RE.match(name):
        return "只能使用字母、数字和连字符，且以字母或数字开头和结尾"
    if name.isdigit():
        return "设备名称不能全是数字"
    return None


def display_name_problem(name):
    """A display name is optional; when given it must survive the GECOS field."""
    if not name:
        return None
    if len(name) > 64:
        return "显示名称不能超过 64 个字符"
    if any(character in name for character in (",", ":")):
        return "显示名称不能包含逗号或冒号"
    if any(character in name for character in ("\n", "\r", "\0")):
        return "显示名称不能包含控制字符"
    return None


# ---------------------------------------------------------------------------
# NetworkManager
# ---------------------------------------------------------------------------
def run_command(argv, stdin_text=None, timeout=60):
    """Run a program and return (status, stdout, stderr).

    Every caller passes a list.  There is no shell anywhere in this file: the
    values that reach these lists come from a user typing into a wizard, and a
    shell would be the one place where that could turn into a command.
    """
    try:
        result = subprocess.run(
            argv,
            input=stdin_text,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return 124, "", "timed out"
    except OSError as error:
        return 127, "", error.strerror or str(error)
    return result.returncode, result.stdout or "", result.stderr or ""


def split_escaped(line):
    """Split one --terse nmcli line on its unescaped colons."""
    fields = []
    current = ""
    escaped = False
    for character in line:
        if escaped:
            current += character
            escaped = False
        elif character == "\\":
            escaped = True
        elif character == ":":
            fields.append(current)
            current = ""
        else:
            current += character
    fields.append(current)
    return fields


def wifi_devices():
    """The wireless interfaces NetworkManager knows about."""
    status, out, _err = run_command(
        ["nmcli", "--terse", "--fields", "DEVICE,TYPE", "device", "status"], timeout=20
    )
    if status != 0:
        return []
    return [fields[0] for fields in map(split_escaped, out.splitlines())
            if len(fields) >= 2 and fields[1] == "wifi"]


def ethernet_connected():
    status, out, _err = run_command(
        ["nmcli", "--terse", "--fields", "DEVICE,TYPE,STATE", "device", "status"],
        timeout=20,
    )
    if status != 0:
        return False
    for line in out.splitlines():
        fields = split_escaped(line)
        if len(fields) >= 3 and fields[1] == "ethernet" and fields[2] == "connected":
            return True
    return False


def wifi_networks():
    """The visible networks, strongest first, with the connected one marked."""
    status, out, _err = run_command(
        [
            "nmcli",
            "--terse",
            "--fields",
            "IN-USE,SSID,SIGNAL,SECURITY",
            "device",
            "wifi",
            "list",
            "--rescan",
            "yes",
        ],
        timeout=45,
    )
    if status != 0:
        return []
    networks = []
    seen = set()
    for line in out.splitlines():
        fields = split_escaped(line)
        if len(fields) < 4:
            continue
        in_use, ssid, signal, security = fields[0], fields[1], fields[2], fields[3]
        if not ssid or ssid in seen:
            # A network with several access points is one network to the user;
            # the first line is its strongest radio.
            continue
        seen.add(ssid)
        try:
            strength = int(signal)
        except ValueError:
            strength = 0
        networks.append(
            {
                "ssid": ssid,
                "signal": strength,
                "security": security if security not in ("", "--") else "",
                "connected": in_use.strip() == "*",
            }
        )
    networks.sort(key=lambda network: network["signal"], reverse=True)
    return networks


def wifi_connect_command(ssid, secured):
    """The command that joins a network, with the secret kept off it.

    `--ask` makes nmcli read the password from standard input.  The alternative
    - `nmcli device wifi connect SSID password PSK` - would put the passphrase
    of the user's network in ps, where every process on the board can read it.
    """
    if not ssid or ssid.startswith("-"):
        raise BackendError("这个网络名称不能在设置向导里连接")
    if secured:
        return ["nmcli", "--ask", "device", "wifi", "connect", ssid]
    return ["nmcli", "device", "wifi", "connect", ssid]


def wifi_connect(ssid, password="", secured=True, timeout=90):
    """Join a network; returns None on success or the reason it failed."""
    try:
        argv = wifi_connect_command(ssid, secured)
    except BackendError as error:
        return str(error)
    stdin_text = (password + "\n") if secured else None
    status, _out, err = run_command(argv, stdin_text=stdin_text, timeout=timeout)
    if status == 0:
        return None
    if status == 124:
        return "连接超时，请确认密码或信号强度"
    message = err.strip().splitlines()
    if message:
        return message[-1]
    return "无法连接到这个网络"


def default_route_present():
    """Whether anything is actually carrying traffic right now."""
    status, out, _err = run_command(
        ["nmcli", "--terse", "--fields", "DEVICE,TYPE,STATE", "device", "status"],
        timeout=20,
    )
    if status != 0:
        return False
    return any(
        len(fields) >= 3 and fields[2] == "connected" and fields[1] in ("wifi", "ethernet")
        for fields in map(split_escaped, out.splitlines())
    )


# ---------------------------------------------------------------------------
# The choices the region page offers
# ---------------------------------------------------------------------------
LOCALE_LABELS = {
    "zh_CN.UTF-8": "简体中文",
    "zh_TW.UTF-8": "繁體中文",
    "en_US.UTF-8": "English (United States)",
    "en_GB.UTF-8": "English (United Kingdom)",
    "ja_JP.UTF-8": "日本語",
    "ko_KR.UTF-8": "한국어",
    "de_DE.UTF-8": "Deutsch",
    "fr_FR.UTF-8": "Français",
    "es_ES.UTF-8": "Español",
    "ru_RU.UTF-8": "Русский",
}

# The zones the page suggests before the user types.  The list of everything
# the system knows is long; these are the ones a board in this project's
# default region is likely to want, and the field accepts any of the others.
COMMON_TIMEZONES = [
    "Asia/Shanghai",
    "Asia/Hong_Kong",
    "Asia/Taipei",
    "Asia/Tokyo",
    "Asia/Seoul",
    "Asia/Singapore",
    "UTC",
    "Europe/London",
    "Europe/Berlin",
    "America/New_York",
    "America/Los_Angeles",
]

# Files in /usr/share/zoneinfo that are not zones.
ZONEINFO_FILES = {
    "iso3166.tab",
    "leap-seconds.list",
    "leapseconds",
    "tzdata.zi",
    "zone.tab",
    "zone1970.tab",
    "zonenow.tab",
    "posixrules",
}
ZONEINFO_DIRS = {"posix", "right"}


def available_timezones(zoneinfo="/usr/share/zoneinfo"):
    """Every zone this system knows, as the names a user would type."""
    zones = []
    if not os.path.isdir(zoneinfo):
        return list(COMMON_TIMEZONES)
    for root, directories, files in os.walk(zoneinfo):
        directories[:] = [d for d in directories if d not in ZONEINFO_DIRS]
        for name in files:
            # `+VERSION` is tzdata's build stamp sitting next to the zones, and
            # a zone name is never anything but a place, so the name has to
            # start like one.
            if name in ZONEINFO_FILES or not re.match(r"^[A-Za-z]", name):
                continue
            path = os.path.join(root, name)
            if os.path.islink(path) or os.path.isfile(path):
                zones.append(os.path.relpath(path, zoneinfo))
    return sorted(zones) or list(COMMON_TIMEZONES)


def available_keymaps(symbols="/usr/share/X11/xkb/symbols"):
    """The keyboard layouts X knows, by the names /etc/default/keyboard uses."""
    names = []
    if not os.path.isdir(symbols):
        return ["us", "cn", "de", "fr", "gb", "jp", "es", "ru"]
    for name in os.listdir(symbols):
        if name.startswith(".") or not re.match(r"^[a-z][a-z0-9_]*$", name):
            continue
        # A layout is a plain file or a directory of variants; the short
        # metadata files xkb ships are not layouts.
        if name in ("compose", "keypad", "pc", "srvr_ctrl"):
            continue
        names.append(name)
    return sorted(names)


def locale_label(locale):
    return LOCALE_LABELS.get(locale, locale)


# ---------------------------------------------------------------------------
# What the board turned out to be
# ---------------------------------------------------------------------------
STATUS_OK = "ok"
STATUS_AVAILABLE = "available"
STATUS_NOT_DETECTED = "not-detected"
STATUS_NOT_VERIFIED = "not-verified"
STATUS_ERROR = "error"
STATUS_UNSUPPORTED = "unsupported"

STATUS_LABELS = {
    STATUS_OK: "正常",
    STATUS_AVAILABLE: "可用",
    STATUS_NOT_DETECTED: "未检测",
    STATUS_NOT_VERIFIED: "未验证",
    STATUS_ERROR: "异常",
    STATUS_UNSUPPORTED: "不支持",
}


def read_text(path):
    try:
        with open(path, "r", errors="replace") as stream:
            return stream.read().strip("\0 \n\t")
    except OSError:
        return ""


def check(name, detail, status):
    return {"name": name, "detail": detail, "status": status}


def check_board(sysfs="/sys", procfs="/proc"):
    model = (
        read_text(os.path.join(sysfs, "firmware/devicetree/base/model"))
        or read_text(os.path.join(procfs, "device-tree/model"))
        or read_text(os.path.join(sysfs, "firmware/devicetree/base/compatible"))
    )
    if model:
        return check("主板", model, STATUS_OK)
    return check("主板", "没有读到设备树型号", STATUS_NOT_VERIFIED)


def check_memory(procfs="/proc"):
    meminfo = read_text(os.path.join(procfs, "meminfo"))
    for line in meminfo.splitlines():
        if line.startswith("MemTotal:"):
            parts = line.split()
            if len(parts) >= 2 and parts[1].isdigit():
                kib = int(parts[1])
                return check(
                    "内存", "%.1f GiB" % (kib / 1024.0 / 1024.0), STATUS_OK
                )
    return check("内存", "没有读到内存大小", STATUS_NOT_VERIFIED)


def check_display(sysfs="/sys"):
    """The connectors a display can be attached to, and what is on them."""
    drm = os.path.join(sysfs, "class/drm")
    if not os.path.isdir(drm):
        return check("显示接口", "没有 DRM 设备", STATUS_NOT_DETECTED)
    connected = []
    connectors = []
    try:
        entries = sorted(os.listdir(drm))
    except OSError:
        return check("显示接口", "无法读取 DRM 目录", STATUS_ERROR)
    for entry in entries:
        # Connectors are named card0-HDMI-A-1; the bare card0 and renderD128
        # entries are the devices themselves, not something to plug into.
        if "-" not in entry:
            continue
        status = read_text(os.path.join(drm, entry, "status"))
        if not status:
            continue
        connectors.append(entry)
        if status == "connected":
            # The mode the display is actually running at, when the kernel
            # knows it: a connected-but-unconfigured output is the black
            # screen people write bug reports about.
            modes = read_text(os.path.join(drm, entry, "modes")).splitlines()
            summary = "%s (%s)" % (entry, modes[0]) if modes else entry
            connected.append(summary)
    if connected:
        return check("显示接口", "、".join(connected), STATUS_OK)
    if connectors:
        return check("显示接口", "接口存在，但没有接显示器", STATUS_NOT_DETECTED)
    return check("显示接口", "没有找到显示接口", STATUS_NOT_VERIFIED)


def check_gpu(sysfs="/sys", icd_dir="/etc/vulkan/icd.d", vendor_library="/usr/lib/libVK_IMG.so"):
    """Whether the vendor stack is there, and whether it is being used.

    Nothing here proves hardware rendering: that needs a Vulkan device and an
    application, which is jh7110-test-graphics' job.  What this can honestly
    say is that the driver and the ICD are installed - and it says exactly
    that, rather than turning an installed file into a passed test.
    """
    driver = ""
    for card in ("card0", "card1"):
        link = os.path.join(sysfs, "class/drm", card, "device/driver")
        if os.path.islink(link):
            driver = os.path.basename(os.readlink(link))
            break
    icd = ""
    try:
        for name in sorted(os.listdir(icd_dir)):
            if name.endswith(".json"):
                icd = os.path.join(icd_dir, name)
                break
    except OSError:
        icd = ""
    if not driver and not icd:
        return check("GPU", "没有找到 GPU 驱动或 Vulkan ICD", STATUS_NOT_DETECTED)
    parts = []
    if driver:
        parts.append("内核驱动 %s" % driver)
    if icd and os.path.exists(vendor_library):
        parts.append("Vulkan ICD 已安装")
    elif os.path.exists(vendor_library):
        parts.append("厂商库已安装，没有 ICD")
    else:
        parts.append("没有找到厂商库")
    status = STATUS_AVAILABLE if driver else STATUS_NOT_VERIFIED
    return check("GPU", "，".join(parts), status)


def check_storage(sysfs="/sys"):
    devices = []
    block = os.path.join(sysfs, "block")
    try:
        entries = sorted(os.listdir(block))
    except OSError:
        return check("存储", "没有读到块设备", STATUS_NOT_VERIFIED)
    for entry in entries:
        if entry.startswith(("mmcblk", "nvme", "sd")):
            sectors = read_text(os.path.join(block, entry, "size"))
            if sectors.isdigit():
                devices.append("%s %.1f GiB" % (entry, int(sectors) * 512 / 1024.0**3))
    if devices:
        return check("存储", "，".join(devices), STATUS_AVAILABLE)
    return check("存储", "没有找到存储设备", STATUS_NOT_DETECTED)


def check_network(sysfs="/sys"):
    interfaces = []
    net = os.path.join(sysfs, "class/net")
    try:
        entries = sorted(os.listdir(net))
    except OSError:
        return check("网络", "没有读到网络接口", STATUS_NOT_VERIFIED)
    for entry in entries:
        if entry == "lo":
            continue
        # An interface with a device link is real hardware; the virtual ones
        # NetworkManager creates are not what this check is about.
        if os.path.exists(os.path.join(net, entry, "device")):
            interfaces.append(entry)
    if interfaces:
        return check("网络", "，".join(interfaces), STATUS_AVAILABLE)
    return check("网络", "没有找到有线或无线接口", STATUS_NOT_DETECTED)


def check_usb(sysfs="/sys"):
    usb = os.path.join(sysfs, "bus/usb/devices")
    try:
        entries = [entry for entry in os.listdir(usb) if ":" not in entry and "-" in entry]
    except OSError:
        return check("USB", "没有读到 USB 设备", STATUS_NOT_DETECTED)
    if entries:
        return check("USB", "%d 个设备" % len(entries), STATUS_OK)
    return check("USB", "没有接 USB 设备", STATUS_NOT_DETECTED)


def check_audio(procfs="/proc"):
    cards = read_text(os.path.join(procfs, "asound/cards"))
    if cards:
        names = [
            line.split(":", 1)[1].strip()
            for line in cards.splitlines()
            if ":" in line
        ]
        return check("音频", "，".join(names) or cards, STATUS_AVAILABLE)
    return check("音频", "没有找到声卡", STATUS_NOT_DETECTED)


def check_firmware(sysfs="/sys"):
    mtd = read_text(os.path.join(sysfs, "class/mtd/mtd0/name"))
    if mtd:
        return check("SPI 固件", mtd, STATUS_OK)
    return check("SPI 固件", "没有读到 SPI 存储", STATUS_NOT_VERIFIED)


HARDWARE_CHECKS = (
    check_board,
    check_memory,
    check_display,
    check_gpu,
    check_storage,
    check_network,
    check_usb,
    check_audio,
    check_firmware,
)


def hardware_report(**paths):
    """Run every check; one that raises is reported and never stops the rest.

    The page this feeds is the last thing before the summary, and a board whose
    USB check failed to read a directory still has an account to create and a
    desktop to start.  Nothing here may raise.
    """
    results = []
    for function in HARDWARE_CHECKS:
        # Each check reads the one tree it is about; a caller testing a single
        # check against a sandbox passes only that tree, and the rest of the
        # checks are handed nothing they did not ask for.
        accepted = inspect.signature(function).parameters
        try:
            results.append(
                function(**{key: value for key, value in paths.items() if key in accepted})
            )
        except Exception as error:  # noqa: BLE001 - see the docstring
            results.append(
                check(function.__name__.replace("check_", ""), str(error), STATUS_ERROR)
            )
    return {
        "version": 1,
        "checks": results,
        "summary": {
            status: sum(1 for result in results if result["status"] == status)
            for status in STATUS_LABELS
        },
    }


# ---------------------------------------------------------------------------
# The order the settings are applied in
# ---------------------------------------------------------------------------
class SetupSession:
    """What the pages collect, and the order it is handed to the backend.

    Two rules shape this class.  The password passes through it and is never
    stored in it - `apply_account` takes it, uses it and drops it - and the
    settings are applied in an order where every step leaves the board in a
    state the next one can build on: the name first, because the account's
    prompt shows it; the account next, because without it there is no way in;
    the region and ssh afterwards, because they are preferences rather than
    access.
    """

    def __init__(self, backend, board=None):
        self.backend = backend
        self.board = board or backend.get_board()
        self.hostname = self.board.get("default_hostname") or ""
        self.username = self.board.get("default_user") or ""
        self.display_name = ""
        self.timezone = self.board.get("timezone") or "UTC"
        self.locale = self.board.get("locale") or "en_US.UTF-8"
        self.keymap = "us"
        self.ssh_enabled = True
        self.network_configured = False
        self.hardware = {}
        self.applied = []

    def apply_hostname(self):
        result = self.backend.set_hostname(self.hostname)
        self.applied.append("hostname")
        return result

    def apply_account(self, password):
        try:
            result = self.backend.create_user(
                self.username, password, display_name=self.display_name
            )
        finally:
            del password
        self.applied.append("account")
        return result

    def apply_region(self):
        result = self.backend.set_timezone(self.timezone)
        self.backend.set_locale(self.locale)
        if self.keymap:
            self.backend.set_keymap(self.keymap)
        self.applied.append("region")
        return result

    def apply_ssh(self):
        result = self.backend.configure_ssh(self.ssh_enabled)
        self.applied.append("ssh")
        return result

    def apply_hardware(self):
        if not self.hardware:
            return {}
        result = self.backend.save_hardware(self.hardware)
        self.applied.append("hardware")
        return result

    def apply_all(self, password):
        """Run every step, in order.

        A failure stops the sequence and says which step it was: the wizard
        shows that step again, and everything already applied stays applied -
        every method is idempotent, so the retry is safe.
        """
        steps = (
            ("设备名称", self.apply_hostname, None),
            ("用户账户", self.apply_account, password),
            ("地区设置", self.apply_region, None),
            ("SSH", self.apply_ssh, None),
            ("硬件报告", self.apply_hardware, None),
        )
        for label, function, argument in steps:
            try:
                if argument is None:
                    function()
                else:
                    function(argument)
            except BackendError as error:
                return False, label, str(error)
        try:
            self.backend.finish(network_configured=self.network_configured)
        except BackendError as error:
            return False, "完成设置", str(error)
        return True, "", ""


# ---------------------------------------------------------------------------
# Running the setup again
# ---------------------------------------------------------------------------
def greeter_attempts_file(greeter_home=None):
    """The count of unfinished runs, where the next login will read it.

    The greeter runs as the greeter account and counts there, so this is that
    account's home.  `None` when this host has no such account and none was
    given, in which case there is no second file to remove.
    """
    if greeter_home is None:
        try:
            greeter_home = pwd.getpwnam(GREETER_USER).pw_dir
        except KeyError:
            return None
    return os.path.join(greeter_home, ".jh7110-oobe-attempts")


def attempts_files(home, greeter_home=None):
    """Every file the count of unfinished runs can be in.

    A reset is normally run by a person with `sudo`, whose home is root's, so
    the file in its own home is not the one that stops the setup from running
    again.  Leaving the greeter's count alone would keep the board at the
    limit, and the next login would go to the console recovery instead of the
    wizard this was run to get back.

    JH7110_ATTEMPTS_FILE moves the greeter's file (the greeter reads the same
    name), so when it is set it is the only file there is.
    """
    override = os.environ.get("JH7110_ATTEMPTS_FILE")
    if override:
        return [override]
    files = [os.path.join(home, ".jh7110-oobe-attempts")]
    greeter_file = greeter_attempts_file(greeter_home)
    if greeter_file is not None and greeter_file not in files:
        files.append(greeter_file)
    return files


def reset_paths(state_dir=STATE_DIR, home=None, greeter_home=None):
    if home is None:
        # Read when this runs rather than when the module is imported: a
        # caller run through sudo has a different home from the one that
        # imported it, and that is the whole reason this is not a constant.
        home = os.path.expanduser("~")
    return [
        os.path.join(state_dir, "oobe.done"),
        os.path.join(state_dir, "oobe-state.json"),
        *attempts_files(home, greeter_home),
    ]


def reset(state_dir=STATE_DIR, home=None, greeter_home=None):
    """Let the next boot run the setup again.

    The done file and the state are what stop it; removing those, and the
    greeter's count of unfinished runs, is the whole operation, and the
    account that exists stays.  A caller running the setup again therefore
    repairs the account it finds rather than creating a second one.
    """
    removed = []
    for path in reset_paths(state_dir, home, greeter_home):
        try:
            os.unlink(path)
            removed.append(path)
        except FileNotFoundError:
            continue
    return removed


def setup_attempts(home=os.path.expanduser("~")):
    try:
        with open(os.path.join(home, ".jh7110-oobe-attempts")) as stream:
            return int(stream.read().strip() or 0)
    except (OSError, ValueError):
        return 0


def record_attempt(home=os.path.expanduser("~")):
    """Count a run that ended without a finished setup, and return the count."""
    attempts = setup_attempts(home) + 1
    try:
        with open(os.path.join(home, ".jh7110-oobe-attempts"), "w") as stream:
            stream.write("%d\n" % attempts)
    except OSError:
        pass
    return attempts


def clear_attempts(home=os.path.expanduser("~")):
    try:
        os.unlink(os.path.join(home, ".jh7110-oobe-attempts"))
    except FileNotFoundError:
        pass
    except OSError:
        pass


def setup_finished(state_dir=STATE_DIR):
    return os.path.exists(os.path.join(state_dir, "oobe.done"))


def oobe_socket_ready(path=SOCKET_PATH):
    """Whether the backend socket is there and usable, without calling it."""
    try:
        info = os.stat(path)
    except OSError:
        return False
    return stat.S_ISSOCK(info.st_mode)
