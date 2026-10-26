"""RX-04: the BinExport2 schema table is current and the schema stays pinned upstream."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GENERATOR = ROOT / "Scripts/dependencies/generate_binexport2_schema.py"
SCHEMA = ROOT / "ThirdParty/BinExport/binexport2.proto"
TEST_COPY = ROOT / "MacScope/Tests/CoreTests/Resources/binexport2.proto"
UPSTREAM_BLOB = "7e1dc3b3eb04d6f3238f5371c01f0abbaffe5ce5"


def git_blob_id(data: bytes) -> str:
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


class BinExport2SchemaTests(unittest.TestCase):
    def test_vendored_schema_is_the_pinned_upstream_blob(self) -> None:
        data = SCHEMA.read_bytes()
        self.assertEqual(git_blob_id(data), UPSTREAM_BLOB)
        self.assertEqual(TEST_COPY.read_bytes(), data)

    def test_generated_table_is_current(self) -> None:
        result = subprocess.run([sys.executable, "-B", str(GENERATOR), "--check"],
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_component_is_registered_with_the_schema_digest(self) -> None:
        inventory = json.loads((ROOT / "THIRD_PARTY_COMPONENTS.yml").read_text(encoding="utf-8"))
        component = next(c for c in inventory["components"] if c["id"] == "binexport2-schema")
        self.assertEqual(component["pin"]["source_archive_sha256"], hashlib.sha256(SCHEMA.read_bytes()).hexdigest())
        self.assertIn("MacScopeApp", component["targets"])


if __name__ == "__main__":
    unittest.main()
