#!/usr/bin/env python3
"""Every build has to be a function of the commit, not of when or where it ran.

Two boards built from the same commit used to differ in the U-Boot version
string, in the kernel's built-in initramfs mtimes and in the FIT's /timestamp
property, which made comparing two builds useless and leaked the CI runner's
hostname into every released kernel banner.  These tests pin the wiring that
fixes it and execute the FIT patch itself against a synthetic blob, because
that patch is a raw byte write into a boot payload: an off-by-one there is a
board that does not come up.

What they cannot reach is what the kernel decides while the image is assembled:
the inode numbers and directory-entry order it chooses for the ext4 are part of
the assembled image, which is why two runs of one commit have different
artifact digests and why the build prints what it does ship - see the payload
fingerprint below and "CI and reproducibility" in docs/architecture.md.
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
        # are either the vendor's or the packaging run's.  The kernel
        # installation as well, because mkinitramfs writes the initrd.
        for script in ('scripts/build-uboot.sh', 'scripts/build-kernel.sh',
                       'scripts/build-gpu-package.sh',
                       'scripts/install-kernel-into-rootfs.sh'):
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

    def test_the_initrd_is_generated_with_the_epoch_in_its_environment(self):
        # mkinitramfs writes the mtime it finds on every file it packs into the
        # initrd, and it passes cpio --reproducible - which drops the inode and
        # device numbers the archive would otherwise carry - only when
        # SOURCE_DATE_EPOCH is set.  It runs behind env -i, which drops
        # everything the command line does not name, so the variable has to be
        # named there: pinning it in the script's own environment reaches the
        # chroot not at all.
        text = (ROOT / 'scripts/install-kernel-into-rootfs.sh').read_text()
        self.assertIn('SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH"', text)
        self.assertLess(text.index('\npin_build_timestamps\n'),
                        text.index('SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH"'))
        self.assertLess(text.index('SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH"'),
                        text.index('/usr/sbin/mkinitramfs'))

    def test_rootfs_build_ships_no_resolver_of_the_machine_that_built_it(self):
        # mmdebstrap --mode=root copies the host copy of /etc/resolv.conf into
        # the target so that the chroot can reach its mirror, and what it names
        # is the build host's resolver: a different address between two runs,
        # and one that answers nowhere the board is used.  NetworkManager
        # writes this file on the board, so the image does not have to.
        text = (ROOT / 'scripts/build-rootfs.sh').read_text().replace('\\\n', ' ')
        self.assertRegex(text, r'rm -f /etc/resolv\.conf')

    def test_rootfs_build_ships_no_nvme_identity_of_the_machine_that_built_it(
            self):
        # nvme-cli's postinst generates a host NQN and a host id when the
        # package is installed, and both are random.  Generated in the image
        # they would be the same identity on every board the image is written
        # to, and a different one between two builds of one commit; the
        # first-boot unit makes them on the board instead.
        text = (ROOT / 'scripts/build-rootfs.sh').read_text().replace('\\\n', ' ')
        self.assertRegex(text, r'rm -f /etc/nvme/hostnqn /etc/nvme/hostid')

    def test_the_wizard_check_leaves_no_bytecode_in_the_image(self):
        # Importing the wizard module writes __pycache__/oobe.cpython-312.pyc
        # beside it, and a .pyc header records the mtime of the source it was
        # compiled from - a file rsync had just brought from the build host.
        # The image build pins inode times afterwards, which is not the time
        # the header remembers, so the file would differ between two builds of
        # one commit and describe a moment that no longer exists.
        text = (ROOT / 'scripts/build-rootfs.sh').read_text()
        self.assertRegex(text, r'PYTHONDONTWRITEBYTECODE=1 jh7110-oobe --check')

    def test_rootfs_build_leaves_no_ldconfig_cache_of_the_build_host(self):
        # ldconfig writes this file to remember which directories it has
        # already scanned, so the copy in the target describes the tree the
        # build host unpacked into it rather than the one being assembled.  The
        # loader reads /etc/ld.so.cache, which is written from the library list
        # and does not differ between two builds; nothing reads this one.
        text = (ROOT / 'scripts/build-rootfs.sh').read_text()
        self.assertRegex(text, r'rm -f /var/cache/ldconfig/aux-cache')

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

    def test_kernel_packaging_runs_under_the_pinned_date(self):
        # mkdebian's `date -R` is the one call that puts the packaging clock
        # into the kernel's packages, and the changelog it writes ships inside
        # the image; the shim goes on PATH for that call alone - the build
        # around it asks the clock what time it is and has to hear the truth.
        text = (ROOT / 'scripts/build-kernel.sh').read_text()
        self.assertIn('install -m 0755 "$REPO_ROOT/scripts/lib/pinned-date.sh" '
                      '"$date_shim/date"', text)
        self.assertLess(text.index('PATH="$date_shim:$PATH"'),
                        text.index('bindeb-pkg'))

    def test_kernel_packages_are_reported_by_their_own_digest(self):
        # Pinning the packaging clock is half of it: what says whether two runs
        # agreed on the packages is what the build prints about them, and
        # nothing else prints these files - they are published beside the image
        # rather than inside it, and the image's digest is not a comparison.
        text = (ROOT / 'scripts/build-kernel.sh').read_text()
        self.assertLess(text.index('bindeb-pkg'), text.index('*.changes'))
        for suffix in ('*.deb', '*.buildinfo', '*.changes'):
            with self.subTest(suffix=suffix):
                self.assertIn(suffix, text)
        # The format the two logs are compared on, spelled out rather than
        # matched loosely: this line is the comparison.
        self.assertIn("'kernel package: %s is %s bytes, sha256 %s\\n'", text)
        self.assertIn('sha256sum "$package_file"', text)

    def test_gpu_package_pins_before_it_archives(self):
        # The helper only exports the environment, so it has to run before
        # dpkg-deb reads it; behind the --build call the package would quietly
        # go back to packaging-time stamps on both boards.
        text = (ROOT / 'scripts/build-gpu-package.sh').read_text()
        self.assertLess(text.index('\npin_build_timestamps\n'),
                        text.index('dpkg-deb --build'))


class PinnedDate(unittest.TestCase):
    """The `date` the kernel packaging step runs under.

    mkdebian stamps debian/changelog with `date -R`, which takes the packaging
    clock and ignores the epoch - and the changelog ships in the image,
    compressed, as /usr/share/doc/linux-image-*/changelog.Debian.gz, which is
    where two builds of one commit left a one-byte difference in
    /usr/share/doc.  The shim is run here the way the build runs it, as a
    program found under the name `date` in front of everything else on PATH,
    because the thing it exists to stop is an almost-right answer.
    """

    SHIM = ROOT / 'scripts/lib/pinned-date.sh'
    EPOCH = '1700000000'
    # Frozen rather than derived from the epoch: a test that formats it the way
    # the shim does would agree with any mistake the shim made.
    EXPECTED = 'Tue, 14 Nov 2023 22:13:20 +0000'

    def run_shim(self, *arguments, epoch=EPOCH, zone='UTC'):
        environment = dict(os.environ)
        environment['TZ'] = zone
        if epoch is None:
            environment.pop('SOURCE_DATE_EPOCH', None)
        else:
            environment['SOURCE_DATE_EPOCH'] = epoch
        return subprocess.run([str(self.SHIM), *arguments], text=True,
                              capture_output=True, env=environment)

    def test_the_changelog_date_is_the_epoch_in_utc(self):
        # -R prints the local time in the machine's own zone, so the same build
        # would package a different changelog on a runner set to anything but
        # UTC; the answer here does not depend on where it runs.
        for zone in ('UTC', 'Asia/Shanghai', 'America/New_York'):
            with self.subTest(zone=zone):
                result = self.run_shim('-R', zone=zone)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), self.EXPECTED)

    def test_the_long_spellings_of_the_same_form_agree(self):
        for argument in ('--rfc-2822', '--rfc-email'):
            with self.subTest(argument=argument):
                result = self.run_shim(argument)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), self.EXPECTED)

    def test_every_other_call_is_the_system_clock(self):
        # A build that asks what time it is gets the time it is: the shim is
        # only in the way of the one form mkdebian asks for.
        result = self.run_shim('+%Y')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout.strip(), r'^\d{4}$')
        self.assertNotEqual(result.stdout.strip(), self.EXPECTED[12:16])

    def test_an_unset_epoch_leaves_the_answer_to_the_system(self):
        # Without an epoch there is nothing to pin to, and a date that failed
        # or printed an empty line would take the changelog line with it.
        for epoch in (None, ''):
            with self.subTest(epoch=epoch):
                result = self.run_shim('-R', epoch=epoch)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertRegex(result.stdout.strip(),
                                 r'^\w{3}, \d{2} \w{3} \d{4} \d{2}:\d{2}:\d{2} ')
                self.assertNotEqual(result.stdout.strip(), self.EXPECTED)


class PayloadFingerprint(unittest.TestCase):
    """The one line two build logs can be compared on.

    The artifact digest cannot be that line: the ext4 underneath it carries
    inode numbers and directory-entry order that the kernel chose while the
    rootfs was copied in, so it moves between two builds of one commit for
    reasons that have nothing to do with what they ship.  The build therefore
    prints a fingerprint of what went in, and these tests run it the way the
    build does - from the heredoc that ships, over a tree built here.
    """

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'rootfs'
        self.root.mkdir()
        self.script = Path(self.temp.name) / 'payload-fingerprint.py'
        self.script.write_text(
            heredoc_body('scripts/build-image.sh', 'payload-fingerprint'))

    def write(self, relative, content):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content if isinstance(content, bytes) else content.encode())
        return path

    def fingerprint(self):
        result = subprocess.run([sys.executable, str(self.script), str(self.root)],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertRegex(lines[-1],
                         r'^build-image: rootfs payload: \d+ files, \d+ directories, '
                         r'\d+ symlinks, sha256 [0-9a-f]{64}$')
        for line in lines[:-1]:
            self.assertRegex(line,
                             r'^build-image: rootfs payload (subtree \S+: \d+ files, '
                             r'\d+ bytes|file \S+: [0-7]+ \d+:\d+ \d+ bytes), '
                             r'sha256 [0-9a-f]{64}$')
        return result.stdout.strip()

    def digest(self):
        return self.fingerprint().splitlines()[-1].split('sha256 ')[1]

    def subtrees(self):
        """{directory: sha256} for the per-directory lines the build prints."""
        return {line.split(' payload subtree ')[1].split(':')[0]: line.split('sha256 ')[1]
                for line in self.fingerprint().splitlines()[:-1]
                if ' payload subtree ' in line}

    def watched(self):
        """{file: line} for the generated files named with their own value."""
        return {line.split(' payload file ')[1].split(':')[0]: line
                for line in self.fingerprint().splitlines()[:-1]
                if ' payload file ' in line}

    def test_a_file_that_only_moved_in_time_has_not_moved(self):
        # The image build pins the mtimes of everything it writes afterwards,
        # so a tree that differs in nothing else is the same payload.
        path = self.write('etc/hostname', 'jh7110\n')
        before = self.digest()
        os.utime(path, (1700000000, 1700000000))
        self.assertEqual(self.digest(), before)

    def test_content_and_symlink_targets_are_what_it_covers(self):
        self.write('etc/hostname', 'jh7110\n')
        (self.root / 'usr/bin/jh7110-prepare').parent.mkdir(parents=True)
        (self.root / 'usr/bin/jh7110-prepare').symlink_to('../libexec/jh7110-prepare')
        before = self.digest()
        self.write('etc/hostname', 'jh7111\n')
        after = self.digest()
        self.assertNotEqual(after, before)
        self.write('etc/hostname', 'jh7110\n')
        self.assertEqual(self.digest(), before)
        (self.root / 'usr/bin/jh7110-prepare').unlink()
        (self.root / 'usr/bin/jh7110-prepare').symlink_to('../libexec/jh7110-setup')
        self.assertNotEqual(self.digest(), before)

    def test_the_boot_directory_is_left_out_of_both_the_copy_and_the_count(self):
        # rsync is told to skip /boot, and the kernel and the initrd are
        # installed into the boot partition instead, so a file there is not
        # part of what this measures - the initrd it deliberately holds is the
        # one file the build cannot make deterministic from the tree alone.
        self.write('etc/hostname', 'jh7110\n')
        self.write('boot/initrd.img', 'not copied into the image\n')
        (self.root / 'usr/bin').mkdir(parents=True)
        output = self.fingerprint()
        self.assertIn('1 files, 3 directories, 0 symlinks,', output)

    def test_a_change_is_localized_to_the_branch_that_holds_it(self):
        # The summary says the payload moved; these lines say which branch, so
        # that the run that has the difference also says where it is.  A cache
        # generated on the build host is the kind of file that moves, and it
        # sits deep enough that only a directory value can point at it.
        self.write('etc/hostname', 'jh7110\n')
        self.write('usr/share/icons/Adwaita/icon-theme.cache', b'cache')
        before = self.subtrees()
        self.write('usr/share/icons/Adwaita/icon-theme.cache', b'cachf')
        after = self.subtrees()
        self.assertEqual(after['etc'], before['etc'])
        for name in ('usr', 'usr/share', 'usr/share/icons'):
            self.assertNotEqual(after[name], before[name])

    def test_a_subtree_line_counts_what_is_below_it(self):
        # Files and bytes next to the digest, because a value that moved with
        # both of those unchanged is a file rewritten in place - an ordering -
        # while one that moved with the size is a file whose content grew.
        self.write('usr/share/doc/a/changelog.Debian.gz', b'12345678')
        self.write('usr/share/doc/b/changelog.Debian.gz', b'1234')
        lines = [line for line in self.fingerprint().splitlines()
                 if line.startswith('build-image: rootfs payload subtree usr/share/doc:')]
        self.assertEqual(len(lines), 1)
        self.assertIn('2 files, 12 bytes,', lines[0])

    def test_a_generated_cache_is_named_with_its_own_value(self):
        # A directory value says which branch moved; this says whether the file
        # in it that a tool generates is the one that moved.  Matching is by
        # path, so a file the list does not name gets no line of its own.
        self.write('var/cache/fontconfig/abcd-le64.cache-7', b'cache')
        self.write('usr/share/icons/Adwaita/icon-theme.cache', b'fast')
        self.write('etc/hostname', 'jh7110\n')
        before = self.watched()
        self.assertEqual(sorted(before), ['usr/share/icons/Adwaita/icon-theme.cache',
                                          'var/cache/fontconfig/abcd-le64.cache-7'])
        self.assertIn(' 4 bytes,', before['usr/share/icons/Adwaita/icon-theme.cache'])
        self.assertIn(' 5 bytes,', before['var/cache/fontconfig/abcd-le64.cache-7'])
        self.write('var/cache/fontconfig/abcd-le64.cache-7', b'cachf')
        after = self.watched()
        self.assertEqual(after['usr/share/icons/Adwaita/icon-theme.cache'],
                         before['usr/share/icons/Adwaita/icon-theme.cache'])
        self.assertNotEqual(after['var/cache/fontconfig/abcd-le64.cache-7'],
                            before['var/cache/fontconfig/abcd-le64.cache-7'])

    def test_a_watched_file_line_says_what_its_value_covers(self):
        # The record a watched value is taken over holds the mode and the owner
        # as well as the bytes, so both are printed beside it: without them a
        # file whose permissions moved and one whose content moved read the
        # same, and the two want different answers.
        path = self.write('etc/ld.so.cache', b'cache')
        path.chmod(0o644)
        before = self.watched()['etc/ld.so.cache']
        self.assertRegex(before,
                         r'^build-image: rootfs payload file etc/ld\.so\.cache: '
                         r'100644 \d+:\d+ 5 bytes, sha256 [0-9a-f]{64}$')
        path.chmod(0o600)
        after = self.watched()['etc/ld.so.cache']
        self.assertNotEqual(after, before)
        self.assertIn(' 100600 ', after)

    def test_the_module_lists_are_named_where_they_are(self):
        # The pattern is matched against the real path, and in a merged-usr
        # rootfs the module tree is under usr/lib: /lib is a symlink to it, so
        # a pattern written against the path a reader resolves it to matches
        # nothing at all and prints no line.
        self.write('usr/lib/modules/6.12.5+/modules.dep', b'kernel/drivers/x.ko:\n')
        self.write('usr/lib/modules/6.12.5+/modules.alias', b'alias pci:v d x *\n')
        self.assertEqual(sorted(self.watched()),
                         ['usr/lib/modules/6.12.5+/modules.alias',
                          'usr/lib/modules/6.12.5+/modules.dep'])


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
                       'superblock-times', 'inode-times-check',
                       'payload-fingerprint'):
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

    def test_the_state_the_kernel_released_is_checked_before_a_pass_edits_it(self):
        # The repair after the inode pass answers every question e2fsck asks, so
        # damage that was in the image before that line would be repaired rather
        # than reported, and a build would publish it.  The filesystem the kernel
        # handed over is checked first, by a pass that writes nothing - the -n is
        # the whole point of it, and it is also what forces the full check, since
        # a filesystem that is marked clean is otherwise passed over unread.
        unmounted = self.text.index('umount "$root_mount"\n')
        guard = self.text.index(
            'e2fsck -fn "$root_device" \\\n'
            '    || die "the root filesystem was not clean when the kernel released it"')
        self.assertLess(unmounted, guard)
        self.assertLess(guard, self.text.index('# esp-times'))

    def test_the_generation_change_is_repaired_before_the_superblock_is_pinned(self):
        # The generation is not private to the inode: the kernel folds it into
        # the seed of every directory block, htree index block and extent tree
        # block it writes, so the inode pass leaves those checksums over a value
        # that is no longer there.  That is what failed CI, and this is the line
        # that answers it.  It has to come after the write that caused it and
        # before the pass that pins the superblock, which stamps the times of
        # what it repaired and counts what it wrote into the lifetime counter the
        # loop below zeroes.
        write = self.text.index(
            'debugfs -w -f "$inode_commands" "$root_device"')
        repair = self.text.index('e2fsck -f -y "$root_device"')
        self.assertLess(write, repair)
        self.assertLess(repair, self.text.index('# superblock-times'))
        # 0 and 1 both say the filesystem is in agreement at the end of the run;
        # 4 and above say it is not, and the build has to stop there rather than
        # publish a filesystem e2fsck has given up on.
        self.assertIn('(( e2fsck_status < 4 ))', self.text)
        # The read-only check at the end is still the gate, and still runs after
        # the last write to either device.
        self.assertIn('e2fsck -fn "$root_device" || die "the root filesystem did '
                      'not pass e2fsck -fn"', self.text)


if __name__ == '__main__':
    unittest.main()
