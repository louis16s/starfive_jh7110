#!/usr/bin/env python3
"""The Python the image ships parses, and compiling it changes nothing.

`jh7110-oobe` is the window the first-run setup appears in and
`jh7110-oobe-backend` is the only thing on the board that can change the
machine.  Neither is ever compiled on the board, so a syntax error in either
reaches the person at the keyboard as a board whose setup does not start - and
reaches them after an hour of image building.

The bytecode goes to a path chosen here rather than wherever the compiler would
put it: `compileall` writes next to the source, and the overlay is what the
image is built from, so bytecode from the machine running the tests would be a
file in the image that nothing references and that no board can use.
"""
from pathlib import Path
import py_compile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

SHIPPED = (
    "rootfs/overlay/usr/bin/jh7110-oobe",
    "rootfs/overlay/usr/lib/jh7110/oobe.py",
    "rootfs/overlay/usr/libexec/jh7110-oobe-backend",
)


class ShippedPython(unittest.TestCase):
    def test_every_shipped_file_parses(self):
        with tempfile.TemporaryDirectory() as cache:
            for index, name in enumerate(SHIPPED):
                with self.subTest(name=name):
                    py_compile.compile(
                        str(ROOT / name), cfile=f"{cache}/{index}.pyc", doraise=True
                    )

    def test_the_wizard_window_is_the_one_that_needs_the_toolkit(self):
        # The split is what lets the rules be tested without a display: the
        # module holds the decisions and never imports GTK, and the window
        # holds the widgets and never holds a rule.
        module = (ROOT / "rootfs/overlay/usr/lib/jh7110/oobe.py").read_text()
        self.assertNotIn("import gi", module)
        self.assertNotIn("Gtk", module)

    def test_the_overlay_carries_no_bytecode(self):
        stale = sorted(
            str(path.relative_to(ROOT))
            for path in (ROOT / "rootfs/overlay").rglob("*")
            if path.name == "__pycache__" or path.suffix == ".pyc"
        )
        self.assertEqual(stale, [], "the image would carry bytecode nothing can use")


if __name__ == "__main__":
    unittest.main()
