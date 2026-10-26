"""Portable unit tests for the macscope client (no MacScope binary or pytest needed)."""
from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import macscope  # noqa: E402


class PortableClientTests(unittest.TestCase):
    def test_coerce_only_converts_address_fields(self) -> None:
        # Address fields become ints; free-text fields that merely LOOK hex stay strings.
        rec = macscope._coerce({"address": "0x1000", "operands": "0x100000abc",
                                "value": "0xFF0000", "name": "0xdeadbeef",
                                "bytes": "00 a0 01 91", "kind": "call"})
        self.assertEqual(rec.address, 0x1000)
        self.assertIsInstance(rec.address, int)
        self.assertEqual(rec.operands, "0x100000abc")  # branch target: stays a string
        self.assertEqual(rec.value, "0xFF0000")  # string literal: stays a string
        self.assertEqual(rec.name, "0xdeadbeef")
        # Nested address fields (e.g. a basic block's successors) also convert.
        nested = macscope._coerce({"start": "0x10", "successors": [{"to": "0x20", "kind": "branch"}]})
        self.assertEqual(nested.start, 0x10)
        self.assertEqual(nested.successors[0].to, 0x20)
        self.assertEqual(nested.successors[0].kind, "branch")

    def test_handshake_failure_raises_cleanly(self) -> None:
        # An executable that exits immediately -> stdout EOF during the handshake. open()
        # must raise (and, per the finalizer, not orphan the child) rather than hang.
        false = "/usr/bin/false" if os.path.exists("/usr/bin/false") else "/bin/false"
        if not os.path.exists(false):
            self.skipTest("no false(1) executable")
        with self.assertRaises(macscope.MacScopeError):
            macscope.open("/bin/ls", executable=false)


if __name__ == "__main__":
    unittest.main()
