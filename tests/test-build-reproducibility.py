#!/usr/bin/env python3
"""Builds of one commit must produce identical bytes.

Two boards built from the same commit used to differ in the U-Boot version
string, in the kernel's built-in initramfs mtimes and in the FIT's /timestamp
property, which made comparing two builds useless and leaked the CI runner's
hostname into every released kernel banner.  These tests pin the wiring that
fixes it and execute the FIT patch itself against a synthetic blob, because
that patch is a raw byte write into a boot payload: an off-by-one there is a
board that does not come up.
"""
import datetime
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

FDT_BEGIN_NODE = 1
FDT_END_NODE = 2
FDT_PROP = 3
FDT_END = 9
FDT_MAGIC = 0xD00DFEED
# Ten-word header, then the empty memory reservation block.
OFF_STRUCT = 40 + 16


def build_dtb(root_props, child_props=()):
    """Return (blob, {(node, name): value offset}) for a minimal device tree.

    The layout is a real one: header, reservation block, structure block, then
    the strings block.  Node names and property values are padded to four
    bytes, which is exactly the detail a hand-written walker gets wrong.
    """
    strings = bytearray()
    name_offsets = {}
    structure = bytearray()
    offsets = {}

    def align():
        while len(structure) % 4:
            structure.append(0)

    def prop(name, value, node):
        if name not in name_offsets:
            name_offsets[name] = len(strings)
            strings.extend(name.encode() + b'\0')
        structure.extend(struct.pack('>III', FDT_PROP, len(value), name_offsets[name]))
        offsets[(node, name)] = OFF_STRUCT + len(structure)
        structure.extend(value)
        align()

    def begin(name):
        structure.extend(struct.pack('>I', FDT_BEGIN_NODE))
        structure.extend(name.encode() + b'\0')
        align()

    def end():
        structure.extend(struct.pack('>I', FDT_END_NODE))

    begin('')
    for name, value in root_props:
        prop(name, value, '')
    if child_props:
        begin('images')
        for name, value in child_props:
            prop(name, value, 'images')
        end()
    end()
    structure.extend(struct.pack('>I', FDT_END))
    align()

    off_strings = OFF_STRUCT + len(structure)
    total = off_strings + len(strings)
    header = struct.pack('>10I', FDT_MAGIC, total, OFF_STRUCT, off_strings,
                         OFF_STRUCT - 16, 17, 16, 0, len(strings), len(structure))
    return bytes(header) + b'\0' * 16 + bytes(structure) + bytes(strings), offsets


def heredoc_body(source, marker):
    """Extract the python heredoc of the shell command line containing marker.

    Read out of the script that ships rather than copied here: a copy would
    keep passing after the real patcher had changed.
    """
    lines = (ROOT / source).read_text().splitlines()
    start = next(n for n, line in enumerate(lines)
                 if "<<'PY'" in line and marker in line)
    while lines[start].rstrip().endswith('\\'):
        start += 1
    end = next(n for n in range(start + 1, len(lines)) if lines[n] == 'PY')
    return '\n'.join(lines[start + 1:end]) + '\n'


class FitTimestampPatch(unittest.TestCase):
    """The FIT /timestamp rewrite, run the way the build runs it."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        patcher = self.root / 'fit-timestamp.py'
        patcher.write_text(heredoc_body('scripts/build-uboot.sh', 'payload'))
        self.patcher = patcher

    def fit(self):
        """A FIT-shaped blob: root timestamp plus a nested one that must not move."""
        return build_dtb(
            [('description', b'test FIT\0'),
             ('timestamp', struct.pack('>I', 0x12345678))],
            [('description', b'images\0'),
             ('data', b'odd'),                       # padding behind the value
             ('timestamp', struct.pack('>I', 0x0BADF00D))])

    def run_patch(self, blob, epoch):
        target = self.root / 'fit.itb'
        target.write_bytes(blob)
        before = target.read_bytes()
        result = subprocess.run([sys.executable, str(self.patcher), str(target), str(epoch)],
                                text=True, capture_output=True)
        return result, target, before

    def test_root_timestamp_is_rewritten_in_place(self):
        blob, offsets = self.fit()
        value_offset = offsets[('', 'timestamp')]
        epoch = 1700000000
        result, target, before = self.run_patch(blob, epoch)
        self.assertEqual(result.returncode, 0, result.stderr)

        after = target.read_bytes()
        self.assertEqual(len(after), len(before), 'the patch must not resize the FIT')
        changed = [n for n, (old, new) in enumerate(zip(before, after)) if old != new]
        self.assertEqual(changed, list(range(value_offset, value_offset + 4)),
                         'the patch moved bytes outside the /timestamp value')
        self.assertEqual(struct.unpack_from('>I', after, value_offset)[0], epoch)

    def test_nested_timestamp_is_left_alone(self):
        blob, offsets = self.fit()
        child = offsets[('images', 'timestamp')]
        result, target, _ = self.run_patch(blob, 1700000000)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(struct.unpack_from('>I', target.read_bytes(), child)[0], 0x0BADF00D)

    def test_already_pinned_is_not_an_error(self):
        # A rebuild inside the epoch's own second leaves the value unchanged,
        # and that tree still has to be releasable.
        blob, offsets = self.fit()
        epoch = struct.unpack_from('>I', blob, offsets[('', 'timestamp')])[0]
        result, target, before = self.run_patch(blob, epoch)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(target.read_bytes(), before)

    def test_missing_timestamp_is_tolerated(self):
        blob, _ = build_dtb([('description', b'no stamp\0')])
        result, target, before = self.run_patch(blob, 1700000000)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('timestamp', result.stderr)
        self.assertEqual(target.read_bytes(), before)

    def test_odd_sized_timestamp_is_rejected(self):
        blob, _ = build_dtb([('timestamp', b'\x00\x00\x00\x00\x00\x00\x00\x01')])
        result, target, before = self.run_patch(blob, 1700000000)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_bytes(), before)

    def test_non_device_tree_is_rejected(self):
        result, target, before = self.run_patch(b'not a device tree at all', 1700000000)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_bytes(), before)


class PinnedTimestamps(unittest.TestCase):
    """scripts/lib/build-timestamps.sh: the values both payload builds inherit."""

    def run_pin(self, **overrides):
        env = dict(os.environ, REPO_ROOT=str(ROOT))
        for key in ('SOURCE_DATE_EPOCH', 'KBUILD_BUILD_TIMESTAMP',
                    'KBUILD_BUILD_USER', 'KBUILD_BUILD_HOST'):
            env.pop(key, None)
        for key, value in overrides.items():
            if value is not None:
                env[key] = value
        script = (
            'die() { echo "die: $*" >&2; exit 1; }\n'
            'source "$REPO_ROOT/scripts/lib/build-timestamps.sh"\n'
            'pin_build_timestamps\n'
            'printf "%s\\n%s\\n%s\\n%s\\n" "$SOURCE_DATE_EPOCH" '
            '"$KBUILD_BUILD_TIMESTAMP" "$KBUILD_BUILD_USER" "$KBUILD_BUILD_HOST"\n'
        )
        return subprocess.run(['bash', '-c', script], cwd=ROOT, env=env,
                              text=True, capture_output=True)

    def test_timestamp_is_the_epoch_in_utc(self):
        # The kernel hands this string to `date -d`, which reads it in the
        # build machine's timezone unless the zone is named in the value.
        epoch = 1700000000
        expected = datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc)
        for zone in ('UTC', 'Asia/Shanghai', 'America/New_York'):
            with self.subTest(zone=zone):
                result = self.run_pin(SOURCE_DATE_EPOCH=str(epoch), TZ=zone)
                self.assertEqual(result.returncode, 0, result.stderr)
                epoch_out, timestamp, user, host = result.stdout.splitlines()
                self.assertEqual(epoch_out, str(epoch))
                self.assertEqual(timestamp, expected.strftime('%Y-%m-%d %H:%M:%S UTC'))
                self.assertEqual(user, 'builder')
                self.assertEqual(host, 'jh7110-desktop')

    def test_epoch_falls_back_to_the_commit_date(self):
        # A published artifact has to be rebuildable from the manifest alone,
        # so the epoch is the commit's own date when nothing else sets it.
        commit_date = subprocess.run(
            ['git', '-C', str(ROOT), 'log', '-1', '--pretty=%ct'],
            text=True, capture_output=True, check=True).stdout.strip()
        result = self.run_pin(SOURCE_DATE_EPOCH=None)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[0], commit_date)

    def test_caller_supplied_user_and_host_are_kept(self):
        result = self.run_pin(SOURCE_DATE_EPOCH='1700000000',
                              KBUILD_BUILD_USER='ci', KBUILD_BUILD_HOST='runner')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[2:], ['ci', 'runner'])

    def test_non_numeric_epoch_fails_the_build(self):
        result = self.run_pin(SOURCE_DATE_EPOCH='yesterday')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('SOURCE_DATE_EPOCH', result.stderr)


class BuildWiring(unittest.TestCase):
    """The scripts that have to use those values, and the checks around them."""

    def test_payload_builds_pin_their_timestamps(self):
        for script in ('scripts/build-uboot.sh', 'scripts/build-kernel.sh'):
            with self.subTest(script=script):
                text = (ROOT / script).read_text()
                self.assertIn('source "$REPO_ROOT/scripts/lib/build-timestamps.sh"', text)
                self.assertIn('\npin_build_timestamps\n', text)

    def test_manifest_records_the_epoch(self):
        text = (ROOT / 'scripts/generate-manifest.sh').read_text()
        self.assertIn("printf 'source_date_epoch=%s\\n' \"$SOURCE_DATE_EPOCH\"", text)
        self.assertIn('\npin_build_timestamps\n', text)

    def test_shellcheck_covers_the_shared_library(self):
        text = (ROOT / '.github/workflows/build.yml').read_text()
        self.assertIn('scripts/lib/*.sh', text)

    def test_gpu_package_ships_md5sums(self):
        text = (ROOT / 'scripts/build-gpu-package.sh').read_text()
        self.assertIn('DEBIAN/md5sums', text)
        self.assertIn('for command_name in curl dpkg-deb md5sum python3 rsync sha256sum tar; do',
                      text)

    def test_gpu_package_leaves_no_empty_init_d(self):
        # dpkg records directories as it finds them; the emptied init.d would
        # otherwise be shipped even though /etc already provides it.
        text = (ROOT / 'scripts/build-gpu-package.sh').read_text()
        self.assertIn('find "$stage_dir/etc/init.d" -depth -type d -empty -delete', text)


if __name__ == '__main__':
    unittest.main()
