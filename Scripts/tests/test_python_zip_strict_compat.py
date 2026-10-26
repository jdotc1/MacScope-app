#!/usr/bin/env python3
"""Compatibility tests for closed equal-length pairing on hosted Python."""

from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parents[2]
CORE_PROOF_ROOT = ROOT / "Tools" / "DecompilerCoreProof"
PILOT_ROOT = ROOT / "Tools" / "NativeDecompilerPilot"
sys.path.insert(0, str(CORE_PROOF_ROOT))
sys.path.insert(0, str(PILOT_ROOT))

from macscope_decompiler_proof.result_validation import (  # noqa: E402
    ResultValidationError,
    _zip_equal_length as zip_validated_result_sequences,
)
from macscope_native_decompiler_pilot.carrier import (  # noqa: E402
    _zip_equal_length as zip_carrier_sequences,
)
from macscope_native_decompiler_pilot.errors import CarrierBuildError  # noqa: E402


class PythonZipStrictCompatibilityTests(unittest.TestCase):
    def test_result_validation_pairing_preserves_order_and_rejects_length_drift(self) -> None:
        self.assertEqual(
            list(
                zip_validated_result_sequences(
                    ["left-0", "left-1"],
                    ["right-0", "right-1"],
                    mismatch_message="result sequence count drifted",
                )
            ),
            [("left-0", "right-0"), ("left-1", "right-1")],
        )
        with self.assertRaisesRegex(ResultValidationError, "result sequence count drifted"):
            list(
                zip_validated_result_sequences(
                    ["left-0", "left-1"],
                    ["right-0"],
                    mismatch_message="result sequence count drifted",
                )
            )

    def test_carrier_pairing_preserves_order_and_rejects_length_drift(self) -> None:
        self.assertEqual(
            list(
                zip_carrier_sequences(
                    ["region-0", "region-1"],
                    [b"bytes-0", b"bytes-1"],
                    mismatch_message="carrier region count drifted",
                )
            ),
            [("region-0", b"bytes-0"), ("region-1", b"bytes-1")],
        )
        with self.assertRaisesRegex(CarrierBuildError, "carrier region count drifted"):
            list(
                zip_carrier_sequences(
                    ["region-0", "region-1"],
                    [b"bytes-0"],
                    mismatch_message="carrier region count drifted",
                )
            )


if __name__ == "__main__":
    unittest.main()
