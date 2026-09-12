#!/usr/bin/env python3
"""Run jh7110-info against a fake board tree and check what it reports."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
KERNEL_RELEASE = '6.12.0-jh7110'

# jh7110-firstboot records this output under `set -e`, so the diagnostic has to
# survive a board that is missing any single attribute.
MEMINFO = """MemTotal:        8123456 kB
MemFree:         6123456 kB
CmaTotal:         524288 kB
CmaFree:          520000 kB
"""
KERNEL_CONFIG = """CONFIG_HZ=250
# CONFIG_HZ_100 is not set
CONFIG_CMA=y
CONFIG_DMA_CMA=y
CONFIG_CMA_SIZE_MBYTES=512
CONFIG_SECCOMP=y
CONFIG_SECCOMP_FILTER=y
CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y
CONFIG_CPU_FREQ_DEFAULT_GOV_ONDEMAND=y
CONFIG_UNRELATED_OPTION=y
"""


class BoardInfo(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        # The script redirects to /dev/null, and the path rewriting below turns
        # that into a fixture path: give the fixture a real one, or every
        # redirection fails and the checks silently fall back to "unknown".
        (self.root / 'dev').mkdir()
        (self.root / 'dev/null').write_text('')
        self.env = dict(os.environ, PATH=f'{self.bin}:/usr/bin:/bin')
        self.env.pop('DESTDIR', None)

    def write(self, path, data):
        p = self.root / path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(data)
        return p

    def command(self, name, body):
        p = self.write('bin/' + name, '#!/bin/sh\n' + body + '\n')
        p.chmod(0o755)

    def mars_board(self, meminfo=MEMINFO, kernel_config=KERNEL_CONFIG, drm=True, gpu=True):
        self.command('uname', f'echo {KERNEL_RELEASE}')
        self.command('nproc', 'echo 4')
        self.command('findmnt', 'echo "/dev/mmcblk1p4 ext4 7.2G"')
        self.write('proc/meminfo', meminfo)
        self.write('proc/cpuinfo', 'processor\t: 0\nuarch\t\t: sifive,u74-mc\n')
        self.write('sys/firmware/devicetree/base/model', 'Milk-V Mars\x00')
        self.write('sys/firmware/devicetree/base/compatible', 'milkv,mars\x00starfive,jh7110\x00')
        self.write('sys/firmware/devicetree/base/chosen/bootargs',
                   'root=UUID=abcd console=ttyS0,115200\x00')
        self.write('etc/jh7110/board.conf', "BOARD_ID=mars\nBOARD_NAME='Milk-V Mars 8GB'\n")
        self.write('sys/devices/system/cpu/cpufreq/policy0/scaling_governor', 'schedutil\n')
        self.write('sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq', '1500000\n')
        if kernel_config is not None:
            self.write(f'boot/config-{KERNEL_RELEASE}', kernel_config)
        if drm:
            self.write('sys/class/drm/card0/dev', '226:0\n')
            driver = self.write('sys/bus/platform/drivers/starfive-video/bind', '')
            (self.root / 'sys/class/drm/card0/device').mkdir(parents=True, exist_ok=True)
            (self.root / 'sys/class/drm/card0/device/driver').symlink_to(driver.parent)
            self.write('sys/class/drm/card0-HDMI-A-1/status', 'connected\n')
            self.write('sys/class/drm/card0-HDMI-A-1/enabled', 'enabled\n')
        if gpu:
            (self.root / 'sys/module/pvrsrvkm').mkdir(parents=True, exist_ok=True)
            self.write('lib/firmware/rgx.fw.36.50.54.182', 'firmware')
            self.write('lib/firmware/rgx.sh.36.50.54.182', 'firmware')
            self.write('usr/lib/libVK_IMG.so', 'ELF')
            self.write('etc/vulkan/icd.d/icdconf.json', '{}')
            self.write('dev/dri/renderD128', '')

    def info(self, **kwargs):
        self.mars_board(**kwargs)
        text = (ROOT / 'rootfs/overlay/usr/bin/jh7110-info').read_text()
        # Longest prefix first, and never mid-token, so /usr/lib/ is not
        # rewritten twice by the /lib/ rule.
        text = re.sub(r'(?<![\w/])(/usr/lib/|/lib/|/sys/|/dev/|/etc/|/proc/|/boot/)',
                      lambda m: str(self.root) + m[0], text)
        result = subprocess.run(['bash', '-c', text], env=self.env,
                                text=True, capture_output=True)
        # Messages that name a path would otherwise only match the fixture.
        result.stdout = result.stdout.replace(str(self.root), '')
        return result

    def test_reports_board_identity_from_the_device_tree(self):
        result = self.info()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Milk-V Mars', result.stdout)
        self.assertIn('milkv,mars starfive,jh7110', result.stdout)
        self.assertIn('board profile', result.stdout)

    def test_reports_the_cma_pool(self):
        # The pool is what the display and GPU allocate from, so it has to be
        # visible in the report rather than only in the DTB.
        result = self.info()
        self.assertIn('CmaTotal', result.stdout)
        self.assertIn('524288 kB', result.stdout)
        self.assertNotIn('kernel was built without CMA', result.stdout)

    def test_missing_cma_is_reported_as_a_skip(self):
        result = self.info(meminfo='MemTotal: 8123456 kB\n')
        self.assertIn('SKIP: kernel was built without CMA', result.stdout)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_reports_kernel_tuning(self):
        result = self.info()
        self.assertIn('CONFIG_HZ=250', result.stdout)
        self.assertIn('CONFIG_CMA_SIZE_MBYTES=512', result.stdout)
        self.assertIn('CONFIG_SECCOMP=y', result.stdout)
        self.assertIn('schedutil @ 1500000 kHz', result.stdout)
        # An unrelated option must not be echoed back.
        self.assertNotIn('CONFIG_UNRELATED_OPTION', result.stdout)

    def test_reports_display_and_gpu_state(self):
        result = self.info()
        self.assertIn('driver=starfive-video', result.stdout)
        self.assertIn('status=connected enabled=enabled', result.stdout)
        self.assertIn('LOADED', result.stdout)
        self.assertIn('rgx.fw.36.50.54.182', result.stdout)
        self.assertIn('rgx.sh.36.50.54.182', result.stdout)
        self.assertIn('render node renderD128', result.stdout)

    def test_absent_hardware_is_skipped_not_faked(self):
        result = self.info(drm=False, gpu=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('SKIP: no DRM device', result.stdout)
        self.assertIn('SKIP: IMG BXE firmware is not installed', result.stdout)
        self.assertIn('SKIP: no /dev/dri/renderD*', result.stdout)
        self.assertNotIn('LOADED', result.stdout)

    def test_uninstalled_kernel_config_is_skipped(self):
        result = self.info(kernel_config=None)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('SKIP:', result.stdout)

    def test_runs_on_a_host_without_any_board(self):
        # Degrading to unknown/SKIP everywhere is the only acceptable failure
        # mode for a tool firstboot calls under `set -e`.
        text = (ROOT / 'rootfs/overlay/usr/bin/jh7110-info').read_text()
        result = subprocess.run(['bash', '-c', text], env=self.env,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('unknown', result.stdout)


if __name__ == '__main__':
    unittest.main()
