#!/usr/bin/env python3
"""Execute both workflows' release staging and verify their actual asset sets."""
import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

REPO = Path(__file__).resolve().parents[1]


class ReleaseAssets(unittest.TestCase):
    def test_staging_and_upload_patterns(self):
        for workflow, job in (("build.yml", "publish"), ("release.yml", "release")):
            steps = yaml.safe_load((REPO / ".github/workflows" / workflow).read_text())["jobs"][job]["steps"]
            stage = next(s["run"] for s in steps if s.get("name") == "Prefix release assets by board")
            patterns = next(s["with"]["files"] for s in steps if s.get("uses", "").startswith("softprops/"))
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                for board in ("mars", "visionfive2"):
                    folder = root / "release" / board / "image"
                    folder.mkdir(parents=True)
                    filename = f"jh7110-desktop-{board}-8g.img.xz"
                    data = board.encode()
                    (folder / filename).write_bytes(data)
                    (folder / (filename + ".sha256")).write_text(f"{hashlib.sha256(data).hexdigest()}  {filename}\n")
                    for name in ("build-manifest.txt", "u-boot.bin", "linux-image.deb"):
                        (folder / name).write_bytes(data)
                subprocess.run(["bash", "-Eeuo", "pipefail", "-c", stage], cwd=root, check=True)
                assets = [p for pattern in patterns.splitlines() if pattern for p in root.glob(pattern)]
                self.assertEqual(len(assets), 10, workflow)
                self.assertEqual(len({p.name for p in assets}), len(assets), workflow)
                for checksum in (p for p in assets if p.name.endswith(".sha256")):
                    expected, name = checksum.read_text().split()
                    self.assertEqual(hashlib.sha256((checksum.parent / name).read_bytes()).hexdigest(), expected)


if __name__ == "__main__":
    unittest.main()
