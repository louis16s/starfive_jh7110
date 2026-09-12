#!/usr/bin/env python3
"""Execute both workflows' release staging and verify their actual asset sets."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

REPO = Path(__file__).resolve().parents[1]

# Everything upload-artifact captures for one board, laid out the way
# download-artifact restores it: an artifact keeps the paths below the least
# common ancestor of its upload list, which is build/<board>.
ARTIFACTS = {
    'image/jh7110-desktop-{board}-8g.img.xz': b'compressed image',
    'packages/linux-image-6.12_1_riscv64.deb': b'kernel package',
    'packages/jh7110-pvr-rogue_1_riscv64.deb': b'gpu package',
    'u-boot/u-boot.bin': b'u-boot',
    'u-boot/u-boot.itb': b'u-boot fit',
    'u-boot/spl/u-boot-spl.bin.normal.out': b'spl',
    'opensbi/fw_dynamic.bin': b'opensbi',
    'release/jh7110-{dtb}.dtb': b'dtb',
    'build-manifest.txt': b'manifest',
}
BOARD_DTB = {'mars': 'milkv-mars', 'visionfive2': 'starfish-visionfive-2-v1.3b'}
STAGING_STEPS = ("Prefix release assets by board", "Determine release assets")


class ReleaseAssets(unittest.TestCase):
    def job(self, workflow, name):
        return yaml.safe_load((REPO / ".github/workflows" / workflow).read_text())["jobs"][name]

    def step(self, job, name):
        return next(s for s in job["steps"] if s.get("name") == name)

    def stage(self, root, boards):
        """Recreate what the download-artifact steps leave on disk."""
        for board in boards:
            for relative, data in ARTIFACTS.items():
                path = root / "release" / board / relative.format(board=board, dtb=BOARD_DTB[board])
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            image = root / "release" / board / "image" / f"jh7110-desktop-{board}-8g.img.xz"
            digest = hashlib.sha256(image.read_bytes()).hexdigest()
            image.with_name(image.name + ".sha256").write_text(f"{digest}  {image.name}\n")

    def run_staging(self, job, root, env, output):
        """Run the staging steps and return the enumerated release assets."""
        env = dict(env, GITHUB_OUTPUT=str(output))
        for name in STAGING_STEPS:
            subprocess.run(["bash", "-Eeuo", "pipefail", "-c", self.step(job, name)["run"]],
                           cwd=root, env=env, check=True)
        return self.parse_output(output)

    @staticmethod
    def parse_output(output):
        """Read the files= heredoc out of a $GITHUB_OUTPUT capture."""
        lines = output.read_text().splitlines()
        start = lines.index("files<<RELEASE_ASSETS")
        end = lines.index("RELEASE_ASSETS", start)
        return lines[start + 1:end]

    def run_determine_step(self, job, root, env, output):
        """Run only the enumeration step, to observe its failure modes."""
        return subprocess.run(
            ["bash", "-Eeuo", "pipefail", "-c", self.step(job, "Determine release assets")["run"]],
            cwd=root, env=dict(env, GITHUB_OUTPUT=str(output)),
            text=True, capture_output=True)

    def test_build_workflow_assets(self):
        job = self.job("build.yml", "publish")
        for board, staged in (("mars", ["mars"]), ("all", ["mars", "visionfive2"])):
            with self.subTest(board=board), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self.stage(root, staged)
                assets = self.run_staging(job, root, {"BOARD": board}, root / "assets.txt")
                self.assertTrue(assets)
                # Every listed path is handed to the release action verbatim, so
                # one that does not exist fails fail_on_unmatched_files.
                for asset in assets:
                    self.assertTrue((root / asset).is_file(), asset)
                # One image per staged board, and no board's assets leak into a
                # board-specific run.
                boards = {Path(a).parts[1] for a in assets}
                self.assertEqual(boards, set(staged))
                self.assertEqual(sorted(a for a in assets if a.endswith(".img.xz")), sorted(
                    f"release/{b}/image/jh7110-desktop-{b}-8g.img.xz" for b in staged))
                # The images already carry the board in their filename; every
                # other asset has to gain the prefix so both boards can share a
                # single release without colliding.
                for asset in assets:
                    name = os.path.basename(asset)
                    if name.endswith(".img.xz") or name.endswith(".img.xz.sha256"):
                        continue
                    self.assertTrue(name.startswith("jh7110-"), asset)

    def test_build_workflow_rejects_unknown_board(self):
        # workflow_call passes a free-form board.  It must fail here rather
        # than reach the action with no assets and report a green job.
        job = self.job("build.yml", "publish")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result = self.run_determine_step(job, root, {"BOARD": "visionfive3"}, root / "assets.txt")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unsupported board", result.stderr)

    def test_build_workflow_rejects_empty_staging(self):
        # This is the failure the strict unmatched-files check exists for.
        job = self.job("build.yml", "publish")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result = self.run_determine_step(job, root, {"BOARD": "mars"}, root / "assets.txt")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("no release assets", result.stderr)

    def test_release_workflow_assets(self):
        job = self.job("release.yml", "release")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.stage(root, ["mars", "visionfive2"])
            assets = self.run_staging(job, root, {}, root / "assets.txt")
            self.assertTrue(assets)
            for asset in assets:
                self.assertTrue((root / asset).is_file(), asset)
            # A tag release always builds both boards, and both must be there.
            self.assertEqual({Path(a).parts[1] for a in assets}, {"mars", "visionfive2"})

    def test_release_workflow_rejects_empty_staging(self):
        job = self.job("release.yml", "release")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result = self.run_determine_step(job, root, {}, root / "assets.txt")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("no release assets", result.stderr)

    def test_checksum_sidecars_stay_paired(self):
        # The prefixing step renames the manifest, DTB and bootloader assets.
        # The image and its checksum must survive untouched: the sidecar is what
        # a flashed card is verified against.
        for workflow, job_name, boards in (("build.yml", "publish", ["mars"]),
                                           ("release.yml", "release", ["mars", "visionfive2"])):
            with self.subTest(workflow=workflow), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self.stage(root, boards)
                assets = self.run_staging(self.job(workflow, job_name), root, {"BOARD": "all"},
                                          root / "assets.txt")
                checksums = [a for a in assets if a.endswith(".sha256")]
                self.assertEqual(len(checksums), len(boards), workflow)
                for checksum in checksums:
                    expected, name = (root / checksum).read_text().split()
                    image = (root / checksum).parent / name
                    self.assertTrue(image.is_file(), image)
                    self.assertEqual(hashlib.sha256(image.read_bytes()).hexdigest(), expected)

    def test_workflows_agree_on_the_prefixing_rule(self):
        # Two copies of the same staging logic is a bug waiting to happen, so
        # at least pin them to identical behaviour on the same input.
        build = self.job("build.yml", "publish")
        release = self.job("release.yml", "release")
        self.assertEqual(self.step(build, "Prefix release assets by board")["run"],
                         self.step(release, "Prefix release assets by board")["run"])


if __name__ == "__main__":
    unittest.main()
