#!/usr/bin/env python3
"""Cache keys computed concurrently stay exact; synthetic records, no cache or builds.

The native stager admits the source and the staged copy in two threads, and both
compute the SLEIGH key. Capturing key_command's stdout swapped the process-wide
sys.stdout, so one thread read an empty key ("dependency cache key is malformed").
"""
from __future__ import annotations

import concurrent.futures
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "macscope_dev_dependency_cache_key_threads", ROOT / "Scripts/qualification/dev_dependency_cache.py")
DEV = importlib.util.module_from_spec(spec)
spec.loader.exec_module(DEV)


class ConcurrentKeyTests(unittest.TestCase):
    def test_concurrent_component_keys_are_identical_and_print_nothing(self):
        prefixes = DEV.COMPONENTS["sleigh-native-source"]["prefixes"]
        records = sorted(({"blob_oid": "0" * 40, "mode": "100644", "path": prefix + "/f",
                           "sha256": "0" * 64, "size": 1} for prefix in prefixes),
                         key=lambda record: record["path"].encode())
        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch.object(DEV, "source_records", return_value=records), \
                mock.patch.object(DEV, "platform_identity", return_value="p"), \
                mock.patch.object(DEV, "native_tools_identity", return_value="t"), \
                mock.patch("sys.stdout") as stdout:
            view_root = Path(temporary)
            compute = lambda _: DEV.component_key("sleigh-native-source", ROOT, view_root)
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
                keys = list(executor.map(compute, range(64)))
        self.assertEqual(len(set(keys)), 1, keys)
        self.assertRegex(keys[0], "^[0-9a-f]{64}$")
        stdout.write.assert_not_called()


if __name__ == "__main__":
    unittest.main()
