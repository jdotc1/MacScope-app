import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class CacheReleasePackageImportTests(unittest.TestCase):
    def test_validator_package_import_without_qualification_pythonpath(self):
        root = Path(__file__).resolve().parents[2]
        environment = os.environ.copy()
        environment.pop("PYTHONPATH", None)
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        with tempfile.TemporaryDirectory() as temporary:
            result = subprocess.run([sys.executable, "-B", "-c",
                "import sys; sys.path.insert(0, sys.argv[1]); from Scripts.qualification import cache_release_inputs; assert cache_release_inputs.devices.__file__", str(root)],
                cwd=temporary, env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
