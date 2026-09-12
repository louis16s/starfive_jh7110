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
import re
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

    def test_build_scripts_pin_their_timestamps(self):
        # The GPU package too: it is assembled entirely from files whose mtimes
        # are either the vendor's or the packaging run's.
        for script in ('scripts/build-uboot.sh', 'scripts/build-kernel.sh',
                       'scripts/build-gpu-package.sh'):
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

    def test_rootfs_build_pins_its_timestamps(self):
        # The rootfs is where the image's files come from, and its chroot runs
        # tools that stamp the moment they ran; the epoch has to reach them, and
        # env -i drops everything that is not named on the command line.
        text = (ROOT / 'scripts/build-rootfs.sh').read_text()
        self.assertIn('source "$REPO_ROOT/scripts/lib/build-timestamps.sh"', text)
        self.assertIn('\npin_build_timestamps\n', text)
        self.assertIn('SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH"', text)
        self.assertLess(text.index('\npin_build_timestamps\n'),
                        text.index('SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH"'))

    def test_rootfs_build_leaves_no_log_of_when_it_ran(self):
        # A log line is content, not metadata, so nothing the image build does
        # afterwards can pin it: two builds of one commit would ship different
        # bytes in /var/log for the same package set.
        # Joined first, so that a line continuation in the script is not read
        # as a path that is missing from the command that follows it.
        text = (ROOT / 'scripts/build-rootfs.sh').read_text().replace('\\\n', ' ')
        for log in ('/var/log/dpkg.log', '/var/log/alternatives.log',
                    '/var/log/bootstrap.log', '/var/log/apt/*'):
            with self.subTest(log=log):
                self.assertRegex(text, rf'rm -f [^\n]*{re.escape(log)}')

    def test_host_dependencies_cover_the_image_tools(self):
        # dosfstools, e2fsprogs and util-linux are what make, check and rewrite
        # the two filesystems; the runner image is not a dependency.
        text = (ROOT / '.github/workflows/build.yml').read_text()
        for package in ('dosfstools', 'e2fsprogs', 'util-linux'):
            with self.subTest(package=package):
                self.assertIn(f' {package} ', text.replace('\n', ' '))
        # The host check is what a local build runs before it starts; without
        # these the image build dies at its own required-command loop, once the
        # kernel and the rootfs have already been built.
        host_check = (ROOT / 'scripts/host-check.sh').read_text()
        for command in ('mkfs.vfat', 'mkfs.ext4', 'debugfs', 'dumpe2fs',
                        'e2fsck', 'fsck.fat', 'tune2fs'):
            with self.subTest(command=command):
                self.assertRegex(host_check, rf'\b{re.escape(command)}\b')

    def test_gpu_package_pins_before_it_archives(self):
        # The helper only exports the environment, so it has to run before
        # dpkg-deb reads it; behind the --build call the package would quietly
        # go back to packaging-time stamps on both boards.
        text = (ROOT / 'scripts/build-gpu-package.sh').read_text()
        self.assertLess(text.index('\npin_build_timestamps\n'),
                        text.index('dpkg-deb --build'))


class ImageIdentifiers(unittest.TestCase):
    """The identifiers every build of a board has to derive to the same value.

    They become the PARTUUIDs the bootloader and /etc/fstab point at and the
    UUID and hash seed the ext4 metadata is derived from, so a change here
    changes what a board boots from - and the two boards sharing one would be
    worse than either.  The expected values are frozen rather than recomputed:
    a test that derives them the way the script does would agree with any
    mistake the script made.
    """

    GOLDEN = {
        'mars': '4f50b104-904a-54eb-813d-a6fa7ed6fb59 '
                'a82a8ddd-8e0b-54f1-a217-a828db826193 '
                'c0786468-5a8a-569f-99ac-db6db141c3b3 '
                '96cf9a91-fce5-5dbf-83d8-6040ee743c14 '
                'de3ddb45-a951-527d-96b8-99ac7d7c2764 ec6fecc3',
        'visionfive2': '3da50bd0-18dc-5716-ae0c-ed1be9d087c5 '
                       '660db473-ec26-5a02-afe4-c6447c6e878d '
                       '895e482b-4426-5fd1-93a3-1f80bc729d33 '
                       'cf172299-ea24-59e5-8400-85dd9ee6c811 '
                       '58b4ec72-df7f-517c-927e-b17148094488 841a7137',
    }

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.script = Path(self.temp.name) / 'image-identifiers.py'
        self.script.write_text(heredoc_body('scripts/build-image.sh', 'image-identifiers'))

    def derive(self, board):
        result = subprocess.run([sys.executable, str(self.script), board],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_each_board_derives_the_frozen_identifiers(self):
        for board, expected in self.GOLDEN.items():
            with self.subTest(board=board):
                self.assertEqual(self.derive(board), expected)

    def test_the_boards_share_no_identifier(self):
        mars = self.derive('mars').split()
        visionfive2 = self.derive('visionfive2').split()
        self.assertEqual(len(mars), len(visionfive2))
        self.assertFalse(set(mars) & set(visionfive2),
                         'the two boards would answer to the same PARTUUIDs')


class ImageNormalisation(unittest.TestCase):
    """The passes that make the finished image a function of the commit.

    Every one of them is a raw write into a filesystem the script has just
    unmounted, and each is followed by a read-back that goes to the offsets the
    on-disk format defines rather than to the tool that wrote them - debugfs
    reports a field it did not accept on its opening line and carries on, so its
    status says nothing.  What is pinned here is the wiring: which pass exists,
    what it runs against, and in which order.
    """

    def setUp(self):
        self.text = (ROOT / 'scripts/build-image.sh').read_text()

    def pass_body(self, marker):
        return heredoc_body('scripts/build-image.sh', marker)

    def test_every_pass_is_a_python_heredoc_that_parses(self):
        # These run inside scripts/build-image.sh, which no test executes;
        # a syntax error there is a build that dies after it has already
        # partitioned a loop device.
        for marker in ('image-identifiers', 'esp-times', 'inode-times',
                       'superblock-times', 'inode-times-check'):
            with self.subTest(marker=marker):
                compile(self.pass_body(marker), marker, 'exec')

    def test_the_epoch_reaches_the_tools_that_take_a_fake_time(self):
        # mke2fs and debugfs read E2FSPROGS_FAKE_TIME first: without it, the
        # flush debugfs performs when it closes the filesystem puts the wall
        # clock back into s_wtime after the pass has written it.
        self.assertIn('export E2FSPROGS_FAKE_TIME="$SOURCE_DATE_EPOCH"', self.text)

    def test_the_inode_pass_runs_before_the_superblock_pass(self):
        # The superblock pass has to be the last writer: it is the one that
        # leaves s_wtime holding the epoch.
        self.assertLess(self.text.index('# inode-times\n'),
                        self.text.index('# superblock-times'))

    def test_wtime_is_written_last_of_the_superblock_times(self):
        self.assertIn('for field in mkfs_time lastcheck mtime first_error_time '
                      'last_error_time wtime; do', self.text)

    def test_the_inode_pass_is_not_read_through_a_pipe(self):
        # debugfs echoes every command, and a reader that closes early - head -
        # kills it with SIGPIPE part way through the writes.  Its output goes to
        # the null device instead, and the read-back is the check.
        for line in self.text.splitlines():
            if line.startswith('debugfs ') and 'inode_commands' in line:
                self.assertIn('> /dev/null', line)
                self.assertNotIn('|', line)
                break
        else:
            self.fail('the inode pass no longer runs debugfs')

    def test_the_commands_the_image_build_needs_are_required_up_front(self):
        # The list is the gate, not the file: a command that appears somewhere
        # in the script but is missing from the loop fails the build after it
        # has partitioned a loop device, and a whole-file search cannot tell
        # the two apart.
        for line in self.text.splitlines():
            if line.startswith('for command_name in '):
                self.assertTrue(line.endswith('; do'), line)
                required = line.split(' in ', 1)[1].split(';')[0].split()
                break
        else:
            self.fail('the image build no longer requires its commands up front')
        for command in ('sfdisk', 'losetup', 'mkfs.vfat', 'mkfs.ext4', 'mount',
                        'umount', 'blkid', 'rsync', 'python3', 'debugfs',
                        'dumpe2fs', 'e2fsck', 'fsck.fat', 'tune2fs'):
            with self.subTest(command=command):
                self.assertIn(command, required)

    def test_the_boot_filesystem_is_made_from_pinned_values(self):
        self.assertIn('mkfs.vfat --invariant -i "$esp_serial" -n "$BOOT_PARTITION_LABEL"',
                      self.text)
        self.assertIn('mkfs.ext4 -L "$ROOT_PARTITION_LABEL" -U "$rootfs_uuid"', self.text)
        self.assertIn('-E hash_seed="$hash_seed"', self.text)

    def test_both_free_cluster_summaries_are_written(self):
        # mkfs.fat writes the boot sector and the free-cluster summary twice,
        # the second pair starting at BPB_BkBootSec.  dosfsck reads the first
        # and nothing else looks at the second, so an image built before this
        # shipped the count from the empty filesystem beside a current one, and
        # a repair tool falling back to the copy would take the stale number.
        body = self.pass_body('esp-times')
        self.assertIn('boot, 0x32', body)
        self.assertIn('summaries.append(backup_boot + fsinfo_sector)', body)
        self.assertEqual(body.count('for sector in summaries:'), 2,
                         'the summary has to be written and read back')

    def test_the_journal_is_created_after_the_rootfs_is_copied_in(self):
        # A journaled mount fills the journal's ring buffer with the
        # transactions it committed - inode table blocks and superblocks
        # carrying the wall clock of the run - and a clean unmount leaves them
        # there: jbd2 writes s_start = 0 into the journal superblock and
        # nothing else.  No pass below can reach that area, so the filesystem
        # is made without a journal and tune2fs adds one to the populated,
        # normalised filesystem instead.
        self.assertIn('-O ^has_journal "$root_device"', self.text)
        self.assertIn('mount "$root_device" "$root_mount"', self.text)
        self.assertIn('tune2fs -O has_journal "$root_device"', self.text)
        journal = self.text.index('tune2fs -O has_journal')
        self.assertLess(self.text.index('umount "$root_mount"\n'), journal)
        # tune2fs writes the copies of the superblock in the other block groups
        # from the primary, so it belongs after the pass that pins the primary
        # and before the read-back that checks those copies.
        self.assertLess(self.text.index('for field in mkfs_time lastcheck'), journal)
        self.assertLess(journal, self.text.index('# superblock-times'))

    def test_nothing_is_written_to_either_device_before_they_are_unmounted(self):
        # The trap in cleanup() unmounts as well and comes first in the file,
        # so anchoring on the line that ends there is what tells the pass
        # ordering from the way out of a failed build.
        unmounted = self.text.index('umount "$root_mount"\n')
        for marker in ('# esp-times', '# inode-times', '# superblock-times'):
            with self.subTest(marker=marker):
                self.assertLess(unmounted, self.text.index(marker))


if __name__ == '__main__':
    unittest.main()
