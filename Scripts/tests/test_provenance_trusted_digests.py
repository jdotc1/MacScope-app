"""Debug trusted-digest provenance mode: same digests, metadata drift rejected."""
import hashlib
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("trusted_provenance", ROOT / "Scripts/generate_release_build_provenance.py")
provenance = importlib.util.module_from_spec(spec)
sys.modules["trusted_provenance"] = provenance
spec.loader.exec_module(provenance)


class TrustedSealedDigestTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.records = {}
        for index in range(80):
            relative = f"dir{index % 3}/file{index}.txt"
            path = self.root / relative
            path.parent.mkdir(exist_ok=True)
            payload = (f"payload {index}\n" * (index + 1)).encode()
            path.write_bytes(payload)
            path.chmod(0o644)
            self.records[relative] = {"mode": "100644", "sha256": hashlib.sha256(payload).hexdigest(),
                                      "size": len(payload)}

    def hashes(self, trust):
        return provenance.selected_input_hashes(self.root, set(self.records), sealed_records=self.records,
                                                trust_sealed_digests=trust)

    def test_trusted_and_rehashed_digests_are_identical(self):
        self.assertEqual(self.hashes(True), self.hashes(False))

    def test_trusted_mode_rejects_size_and_mode_drift(self):
        target = self.root / "dir0/file0.txt"
        target.write_bytes(b"changed size")
        with self.assertRaises(provenance.ProvenanceError):
            self.hashes(True)
        target.write_bytes(b"x" * self.records["dir0/file0.txt"]["size"])
        self.hashes(True)  # same-size rewrite: trusted mode relies on the qualifier's verification
        with self.assertRaises(provenance.ProvenanceError):
            self.hashes(False)
        target.chmod(0o755)
        with self.assertRaises(provenance.ProvenanceError):
            self.hashes(True)

    def test_release_never_trusts(self):
        source = (ROOT / "Scripts/generate_release_build_provenance.py").read_text()
        self.assertIn('arguments.configuration == "Debug"\n            and os.environ.get(TRUSTED_SEALED_DIGESTS_ENVIRONMENT)', source)
        qualifier = (ROOT / "Scripts/qualify_local_private_build.sh").read_text()
        block = qualifier[qualifier.index('case "${MODE:-}" in\n  smoke|focused-test)'):]
        block = block[:block.index("esac")]
        self.assertIn("MACSCOPE_PROVENANCE_SEALED_DIGESTS=trust-verified-export", block)
        self.assertNotIn("full-test", block)
        self.assertNotIn("release", block)


if __name__ == "__main__":
    unittest.main()
