"""Static contract coverage for unforgeable native-heritage failure paths."""

from __future__ import annotations

import pathlib
import unittest


class NativeDecompilerHeritageContractTests(unittest.TestCase):
    def test_provider_requires_bidirectional_native_heritage_evidence(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[2]
        source = (repository / "Tools/NativeDecompilerBridge/src/GhidraProvider.cpp").read_text()

        self.assertIn("input->isHeritageKnown()", source)
        self.assertIn("validateNativeHeritage", source)
        self.assertIn("native->beginDescend()", source)
        self.assertIn("native-provider-heritage-input-use-omitted", source)
        self.assertIn("native-provider-heritage-descendant-unresolved", source)


if __name__ == "__main__":
    unittest.main()
