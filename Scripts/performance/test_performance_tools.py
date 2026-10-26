#!/usr/bin/env python3
"""Deterministic tool-contract tests. Synthetic numbers are never performance evidence."""
import hashlib
import json
from pathlib import Path
import plistlib
import tempfile
import unittest

import compare_results as comparison
import make_manifest
import run_benchmark


class PerformanceToolTests(unittest.TestCase):
    def fixture(self, root, multiplier=1.0):
        root.mkdir()
        manifest = {"schemaVersion": 1, "warmupIterations": 1, "measuredIterations": 20,
                    "inputs": [{"id": "fixture", "mode": "inProcess", "sha256": "a" * 64}]}
        payload = json.dumps(manifest, sort_keys=True).encode()
        (root / "corpus.json").write_bytes(payload)
        context = {"schemaVersion": 1, "status": "complete", "runID": "fixture",
                   "manifestSHA256": hashlib.sha256(payload).hexdigest(),
                   "identity": {"xcode": "fixture", "swift": "fixture", "sdk": "fixture",
                                "configuration": "Release", "coverage": False, "testability": True,
                                "sourceCommit": "fixture"},
                   "buildSettings": {"MacScopeApp": {"SWIFT_OPTIMIZATION_LEVEL": "-O", "ARCHS": "arm64"}},
                   "hardware": {key: "fixture" for key in ("hw.model", "machdep.cpu.brand_string", "hw.memsize", "hw.logicalcpu", "macOSBuild")}}
        (root / "context.json").write_text(json.dumps(context))
        rows = []
        for index in range(21):
            row = {"schemaVersion": 1, "runID": "fixture", "inputID": "fixture",
                   "inputSHA256": "a" * 64, "mode": "inProcess", "iteration": index,
                   "warmup": index == 0, "thermalState": 0, "lowPowerMode": False,
                   "facetSHA256": "b" * 64, "instructionCount": 100, "procedureCount": 2,
                   "listingRowCount": 110}
            row.update({key: 100.0 * multiplier for key in comparison.METRICS})
            rows.append(row)
        (root / "samples.jsonl").write_text("\n".join(json.dumps(row) for row in rows) + "\n")
        return rows

    def testPairedImprovementAndRegression(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root / "a")
            self.fixture(root / "b", 0.8)
            result = comparison.compare(comparison.load_run(root / "a"), comparison.load_run(root / "b"))
            self.assertFalse(result["hardRegressions"])
            self.assertAlmostEqual(result["inputs"]["fixture"]["analyzeMS"]["p50Ratio"], 0.8)
            self.fixture(root / "c", 1.2)
            result = comparison.compare(comparison.load_run(root / "a"), comparison.load_run(root / "c"))
            self.assertTrue(result["hardRegressions"])

    def testRejectsDuplicateMissingHotAndChangedSemanticSamples(self):
        for mutation in ("duplicate", "missing", "thermal", "semantics", "negative", "nan"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / "run"
                rows = self.fixture(root)
                if mutation == "duplicate": rows[-1] = rows[-2]
                elif mutation == "missing": rows.pop()
                elif mutation == "thermal": rows[-1]["thermalState"] = 2
                elif mutation == "semantics": rows[-1]["facetSHA256"] = "c" * 64
                elif mutation == "negative": rows[-1]["analyzeMS"] = -1
                elif mutation == "nan": rows[-1]["analyzeMS"] = float("nan")
                (root / "samples.jsonl").write_text("\n".join(json.dumps(row) for row in rows))
                with self.assertRaises(ValueError): comparison.load_run(root)

    def testManifestHashTamperingIsRejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "run"
            self.fixture(root)
            with (root / "corpus.json").open("a") as stream: stream.write(" ")
            with self.assertRaises(ValueError): comparison.load_run(root)

    def testManifestBindsExactInputBytesWithoutReplacingSource(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "input"
            path.write_bytes(b"synthetic fixture")
            manifest = make_manifest.build_manifest([path], ["inProcess", "xpc"], 2, 20, None)
            self.assertEqual(manifest["inputs"][0]["sha256"], hashlib.sha256(path.read_bytes()).hexdigest())
            self.assertEqual(len(manifest["inputs"]), 2)
            self.assertEqual(path.read_bytes(), b"synthetic fixture")

    def testXctestrunEnvironmentAndTestrootAreExplicitAndOriginalIsUntouched(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = root / "original.xctestrun"
            value = {"TestConfigurations": [{"TestTargets": [{"BlueprintName": "CoreTests",
                      "TestBundlePath": "__TESTROOT__/Release/CoreTests.xctest",
                      "EnvironmentVariables": {"EXISTING": "kept"}}]}]}
            original.write_bytes(plistlib.dumps(value))
            before = original.read_bytes()
            destination = root / "prepared.xctestrun"
            run_benchmark.prepared_xctestrun(original, destination, {"MACSCOPE_PERF_RUN": "1"})
            prepared = plistlib.loads(destination.read_bytes())
            target = run_benchmark.test_targets(prepared)[0]
            self.assertEqual(target["EnvironmentVariables"]["EXISTING"], "kept")
            self.assertEqual(target["EnvironmentVariables"]["MACSCOPE_PERF_RUN"], "1")
            self.assertEqual(target["TestBundlePath"], str(root / "Release/CoreTests.xctest"))
            self.assertEqual(original.read_bytes(), before)

    def testOnlyListedExperimentSwitchesAreForwarded(self):
        environment = {"MACSCOPE_DYNAMIC_TILING": "1", "PATH": "/usr/bin", "MACSCOPE_OTHER": "x"}
        self.assertEqual(run_benchmark.experiment_environment(environment), {"MACSCOPE_DYNAMIC_TILING": "1"})
        self.assertEqual(run_benchmark.experiment_environment({"PATH": "/usr/bin"}), {})

    def testQuantileAndBootstrapAreDeterministic(self):
        self.assertEqual(comparison.percentile(list(range(1, 21)), 0.95), 19)
        self.assertEqual(comparison.bootstrap_ratio([100] * 20, [80] * 20), [0.8, 0.8])


if __name__ == "__main__":
    unittest.main()
