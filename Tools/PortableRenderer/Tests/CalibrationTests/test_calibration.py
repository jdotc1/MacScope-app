import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


class CalibrationTests(unittest.TestCase):
    def testProductionEntryPointCalibration(self):
        harness = Path(__file__).resolve().parents[2]
        # Explicit paths permit both admitted trees to use the same retained harness.
        baseline = Path(os.environ["PORTABLE_REFERENCE_DUMP"])
        binary = Path(os.environ["PORTABLE_BINARY"])
        with tempfile.TemporaryDirectory() as output:
            target = Path(os.environ.get("PORTABLE_CALIBRATION_OUT", str(Path(output) / "pseudocode-all.txt")))
            target.parent.mkdir(parents=True, exist_ok=True)
            self.assertFalse(target.exists(), "Refuse to overwrite retained calibration evidence")
            subprocess.run([str(harness / "render-all"), str(binary), str(target)], check=True)
            expected = self.functions(baseline.read_bytes())
            actual = self.functions(target.read_bytes())
            self.assertEqual(len(expected), 914)
            self.assertEqual(list(actual), list(expected))
            self.assertGreaterEqual(sum(actual[key] == value for key, value in expected.items()), 914)

    @staticmethod
    def functions(data):
        matches = list(re.finditer(rb"^// FUNCTION name=(.*?) start=(0x[0-9a-f]+)\n", data, re.M))
        return {(m[1], m[2]): data[m.end():matches[i + 1].start() if i + 1 < len(matches) else len(data)]
                for i, m in enumerate(matches)}


if __name__ == "__main__":
    unittest.main(verbosity=2)
