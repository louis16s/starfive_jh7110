#!/usr/bin/env python3
"""Every `jh7110-…` a document tells a person to type is one they can type.

The README and the pages in docs/ are what somebody reads at a serial console
when the desktop did not come up, and the commands in them are typed as
written.  A helper that lives under /usr/libexec - where the system keeps what
it runs itself - reads exactly like a command that works, and then fails with
"command not found" at the moment the reader has the least patience for it.

A name counts as typed when it is the command word of a line inside a code
block, with or without `sudo` in front.  Names in prose, in unit names and in
paths are not commands, and are not checked: `/usr/libexec/jh7110-account` is
written with its path on purpose.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
OVERLAY = ROOT / "rootfs" / "overlay"
# The directories a person's PATH has on the board.  sudo keeps /usr/sbin and
# /sbin in its secure_path, and the serial-console recovery is run through
# sudo, so the same list covers both.
PATH_DIRS = ("usr/bin", "usr/sbin", "usr/local/bin", "usr/local/sbin", "bin", "sbin")

COMMAND = re.compile(r"^(?:sudo\s+)?(jh7110-[a-z0-9-]+)(?:\s|$)")
FENCE = re.compile(r"^\s*(?:~~~|```)")


def documented_commands():
    """The command words a person is told to type, as a set of names."""
    commands = set()
    documents = [ROOT / "README.md", *sorted((ROOT / "docs").glob("*.md"))]
    for document in documents:
        inside = False
        for line in document.read_text(encoding="utf-8").splitlines():
            if FENCE.match(line):
                inside = not inside
                continue
            if not inside:
                continue
            match = COMMAND.match(line.strip())
            if match:
                commands.add(match.group(1))
    return commands


class DocumentedCommands(unittest.TestCase):
    def test_every_documented_command_is_on_the_path(self):
        shipped = {
            path.name
            for directory in PATH_DIRS
            if (OVERLAY / directory).is_dir()
            for path in (OVERLAY / directory).iterdir()
        }
        missing = sorted(documented_commands() - shipped)
        self.assertEqual(
            missing,
            [],
            "the documents tell people to run names the image does not put on "
            "their path; ship them or write the full path",
        )

    def test_the_documents_are_read_at_all(self):
        # The check above passes by finding nothing, so a parser that quietly
        # stopped matching would look the same as a tree with no drift in it.
        self.assertGreaterEqual(len(documented_commands()), 5)


if __name__ == "__main__":
    unittest.main()
