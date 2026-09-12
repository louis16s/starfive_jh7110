#!/usr/bin/env python3
"""Execute maintainer scripts and graphics probes against isolated fixtures."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Runtime(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=f'{self.bin}:/usr/bin:/bin', DISPLAY=':0')
        self.env.pop('DESTDIR', None)

    def write(self, path, data):
        p = self.root / path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(data)
        return p

    def command(self, name, body):
        p = self.write('bin/' + name, '#!/bin/sh\n' + body + '\n')
        p.chmod(0o755)

    def run_script(self, source, replacements=(), args=()):
        text = (ROOT / source).read_text()
        for old, new in replacements:
            text = text.replace(old, new)
        return subprocess.run(['bash', '-c', text, source, *args],
                              env=self.env, text=True, capture_output=True)

    def test_postinst_without_initrd(self):
        self.command('ldconfig', 'exit 0')
        self.command('update-initramfs', 'exit 77')
        result = self.run_script('packages/gpu/postinst',
                                 [('/boot/', str(self.root / 'boot') + '/')], ['configure'])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_postinst_propagates_update_failure(self):
        self.command('ldconfig', 'exit 0')
        self.command('update-initramfs', 'exit 77')
        self.write('boot/initrd.img-test', 'initrd')
        result = self.run_script('packages/gpu/postinst',
                                 [('/boot/', str(self.root / 'boot') + '/')], ['configure'])
        self.assertEqual(result.returncode, 77)

    def test_hook_prereqs_needs_no_files_or_destination(self):
        result = self.run_script('packages/gpu/initramfs-hook', args=['prereqs'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '')

    def test_hook_refuses_missing_destination(self):
        result = self.run_script('packages/gpu/initramfs-hook')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('destination is required', result.stderr)

    def graphics(self, renderer='PowerVR Rogue', connected=True, firmware=True,
                 vulkan_renderer=None, drop=()):
        (self.root / 'sys/module/pvrsrvkm').mkdir(parents=True)
        for name in ['rgx.fw.36.50.54.182', 'rgx.sh.36.50.54.182']:
            if firmware or name.startswith('rgx.fw'):
                self.write('lib/firmware/' + name, 'firmware')
        self.write('usr/lib/libVK_IMG.so', 'ELF')
        self.write('etc/vulkan/icd.d/icdconf.json', '{}')
        self.write('dev/dri/card0', '')
        self.write('dev/dri/renderD128', '')
        if connected:
            for field, data in [('status', 'connected'), ('enabled', 'enabled'), ('modes', '1920x1080')]:
                self.write('sys/class/drm/card0-HDMI-A-1/' + field, data)
        # No matching dmesg lines must not terminate the diagnostic early.
        self.command('dmesg', 'echo "unrelated kernel message"')
        self.command('timeout', 'shift; exec "$@"')
        # The Vulkan probe runs through env, which has to drop the VAR=value
        # arguments before exec'ing the real command.
        self.command('env', 'while [ $# -gt 0 ]; do case $1 in *=*) shift ;; *) break ;; esac; done; exec "$@"')
        for command in ['vulkaninfo', 'glxinfo', 'eglinfo']:
            rendered = vulkan_renderer if command == 'vulkaninfo' and vulkan_renderer else renderer
            self.command(command, f'echo "{rendered}"')
        for command in ['drm_info', 'xrandr']:
            self.command(command, 'echo OK')
        # Simulate a tool the image did not ship, after the stubs exist.
        for command in drop:
            (self.bin / command).unlink()
        # Longest prefix first prevents replacing /lib inside /usr/lib twice.
        replacements = [(p, str(self.root) + p) for p in ['/sys/', '/dev/', '/etc/']]
        text = (ROOT / 'rootfs/overlay/usr/bin/jh7110-test-graphics').read_text()
        import re
        text = re.sub(r'(?<![\w/])(/usr/lib/|/lib/)', lambda m: str(self.root) + m[0], text)
        for old, new in replacements:
            text = text.replace(old, new)
        return subprocess.run(['bash', '-c', text], env=self.env, text=True, capture_output=True)

    def test_hardware_fixture_reaches_summary(self):
        result = self.graphics()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn('诊断失败计数: 0', result.stdout)

    def test_software_renderer_fails(self):
        result = self.graphics(renderer='llvmpipe')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('FAIL Vulkan', result.stdout)

    def test_unidentified_renderer_fails(self):
        result = self.graphics(renderer='enumeration succeeded')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('FAIL OpenGL', result.stdout)

    def test_missing_hdmi_fails(self):
        result = self.graphics(connected=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('FAIL HDMI', result.stdout)

    def test_partial_firmware_fails(self):
        result = self.graphics(firmware=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('firmware is missing', result.stdout)

    def test_x11_software_renderer_is_a_warning(self):
        # The image configures modesetting with AccelMethod none on purpose, so
        # a software GLX/EGL renderer is the designed X11 path.  It must not be
        # reported as GPU acceleration, and it must not fail the run either:
        # Vulkan is what proves the GPU works.
        result = self.graphics(renderer='llvmpipe', vulkan_renderer='PowerVR Rogue')
        self.assertIn('PASS Vulkan', result.stdout)
        self.assertIn('WARN OpenGL', result.stdout)
        self.assertNotIn('FAIL OpenGL', result.stdout)
        self.assertIn('诊断失败计数: 0', result.stdout)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_display_does_not_fail_the_run(self):
        # Serial or SSH sessions have no DISPLAY; that is an untestable path,
        # not a hardware defect.
        self.env.pop('DISPLAY')
        result = self.graphics()
        self.assertIn('WARN: 未设置 DISPLAY', result.stdout)
        self.assertIn('诊断失败计数: 0', result.stdout)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_vulkaninfo_reports_the_command(self):
        # probe() runs the Vulkan check through env; it must look past the
        # wrapper and the VAR=value arguments when it decides what is missing.
        result = self.graphics(drop=['vulkaninfo'])
        self.assertIn('FAIL Vulkan: 未安装 vulkaninfo', result.stdout)
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
