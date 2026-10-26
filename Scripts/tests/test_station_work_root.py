"""Default station pools must refuse roots that their token format cannot hold."""
import os
from pathlib import Path
import subprocess
import unittest


class StationWorkRootTests(unittest.TestCase):
    def test_default_pool_refuses_whitespace_before_listing(self):
        environment = dict(os.environ, MACSCOPE_WORK_ROOT="/tmp/has space")
        environment.pop("MACSCOPE_STATIONS", None)
        result = subprocess.run(
            [str(Path(__file__).resolve().parents[1] / "station.sh"), "list"],
            env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn("station work root must not contain whitespace", result.stderr)


if __name__ == "__main__":
    unittest.main()
