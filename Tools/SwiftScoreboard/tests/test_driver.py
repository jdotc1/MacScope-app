"""Driver checks use temporary synthetic corpora and never launch the app."""
import csv
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("scoreboard_driver", Path(__file__).parents[1] / "run_scoreboard.py")
driver = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = driver
SPEC.loader.exec_module(driver)


class DriverTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def corpus(self):
        corpus = self.root / "corpus"
        repositories = []
        rows = []
        for repo, name in (("sample-app", "SampleApp"), ("sample-tool", "SampleTool"),
                           ("swift-argument-parser", "math")):
            products = []
            for opt in ("O", "Osize"):
                inputs = corpus / "inputs" / repo / opt
                oracle = corpus / "oracle" / repo / opt
                inputs.mkdir(parents=True)
                (oracle / "align-dwarfdump").mkdir(parents=True)
                binary = inputs / name
                binary.write_bytes(b"executable")
                twin = inputs / (name + ".unstripped")
                twin.write_bytes(b"symbols")
                nm = oracle / (name + ".nm.txt")
                nm.write_text("0000000100000010 T _main\n")
                (oracle / "align-dwarfdump" / (name + ".json")).write_text('{"functions": []}')
                product = {"name": name, "path": str(binary), "unstripped_path": str(twin),
                           "sha256": "expected", "unstripped_sha256": "twin-digest", "nm_file": str(nm),
                           "main_executable": True}
                products.append(product)
                receipt = oracle / "build-2.json"
                receipt.write_text(json.dumps({"status": "built", "products": [product]}))
                rows.append({"name": repo, "opt": opt, "status": "built", "receipt": str(receipt)})
            repositories.append({"name": repo, "products": products})
        (corpus / "manifest.json").write_text(json.dumps(repositories))
        (corpus / "toolchain.json").write_text('{"swift": "synthetic"}')
        (corpus / "receipts").mkdir()
        with (corpus / "receipts/builds.csv").open("w", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=["name", "opt", "status", "receipt"])
            writer.writeheader()
            writer.writerows(rows)
        return corpus

    def test_manifest_mains_join_recorded_build_receipt(self):
        corpus = self.corpus()
        products = driver.discover_products(corpus, expected_count=6)
        self.assertEqual(len(products), 6)
        self.assertTrue(all(p["build_receipt"].endswith("build-2.json") for p in products))
        controls = driver.control_products(products)
        self.assertEqual([p["product"] for p in controls], ["SampleApp", "SampleTool", "math"])
        self.assertEqual({p["opt"] for p in controls}, {"O"})

    def test_changed_main_set_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Expected 24 main executables, found 6"):
            driver.discover_products(self.corpus())

    def test_manifest_build_digest_disagreement_is_rejected_without_hashing(self):
        corpus = self.corpus()
        manifest = driver.read_json(corpus / "manifest.json")
        manifest[0]["products"][0]["sha256"] = "changed"
        driver.write_json(corpus / "manifest.json", manifest)
        with mock.patch.object(driver, "sha256", side_effect=AssertionError("must not hash")):
            with self.assertRaisesRegex(ValueError, "digest mismatch"):
                driver.discover_products(corpus, expected_count=6)

    def test_failed_collection_receipt_can_supply_main_provenance(self):
        corpus = self.corpus()
        oracle = corpus / "oracle/sample-app/O"
        receipt = driver.read_json(oracle / "build-2.json")
        receipt.update(status="failed", build_succeeded=True, fail_reason="other product failed")
        receipt["products"][0]["uuid"] = "receipt-only-uuid"
        driver.write_json(oracle / "build.json", receipt)
        driver.write_json(oracle / "build-2.json", {"status": "built", "products": [
            {"name": "Other", "path": "other", "sha256": "other"}]})
        with mock.patch.object(driver, "sha256", side_effect=AssertionError("must not hash")):
            product = driver.discover_products(corpus, expected_count=6)[0]
        self.assertTrue(product["build_receipt"].endswith("build.json"))
        self.assertEqual(product["build_status"], "failed")
        self.assertTrue(product["build_succeeded"])
        self.assertEqual(product["fail_reason"], "other product failed")
        self.assertIsNone(product["uuid"])

    def test_multiple_receipts_prefer_built_and_record_all_names(self):
        corpus = self.corpus()
        oracle = corpus / "oracle/sample-app/O"
        receipt = driver.read_json(oracle / "build-2.json")
        receipt["status"] = "failed"
        driver.write_json(oracle / "build-1.json", receipt)
        # An invalid CSV proves discovery no longer reads this former authority.
        (corpus / "receipts/builds.csv").write_bytes(b"\xff")
        product = driver.discover_products(corpus, expected_count=6)[0]
        self.assertTrue(product["build_receipt"].endswith("build-2.json"))
        self.assertEqual(product["build_status"], "built")
        self.assertEqual(product["build_receipts"], ["build-1.json", "build-2.json"])
        self.assertIsNone(product["build_succeeded"])
        self.assertIsNone(product["fail_reason"])

    def test_main_absent_from_all_receipts_is_rejected(self):
        corpus = self.corpus()
        driver.write_json(corpus / "oracle/sample-app/O/build-2.json",
                          {"status": "built", "products": []})
        with self.assertRaisesRegex(ValueError, "No build receipt lists"):
            driver.discover_products(corpus, expected_count=6)

    def test_receipt_digest_disagreement_is_rejected(self):
        for field in ("sha256", "unstripped_sha256"):
            with self.subTest(field=field):
                corpus = self.corpus() if field == "sha256" else self.root / "corpus"
                path = corpus / "oracle/sample-app/O/build-2.json"
                receipt = driver.read_json(path)
                receipt["products"][0].update(sha256="expected", unstripped_sha256="twin-digest")
                receipt["products"][0][field] = "different"
                driver.write_json(path, receipt)
                with self.assertRaisesRegex(ValueError, "Manifest/build digest mismatch"):
                    driver.discover_products(corpus, expected_count=6)

    def test_explicit_expected_count_mismatch_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Expected 7 main executables, found 6"):
            driver.discover_products(self.corpus(), expected_count=7)

    def test_environment_is_exactly_three_entries(self):
        with mock.patch.dict(os.environ, {"PATH": "/bin", "HOME": "/home/example", "SECRET": "excluded"}, clear=True):
            self.assertEqual(driver.process_environment(),
                             {"PATH": "/bin", "HOME": "/home/example", "MACSCOPE_SSA_LIFTER": "1"})

    def test_cpu_time_and_descendant_selection(self):
        self.assertEqual(driver.cpu_seconds("1-01:02:03.50"), 90123.5)
        output = "10 1 0:01.50\n11 10 0:02.00\n12 11 0:03.00\n20 1 9:00.00\n"
        with mock.patch.object(driver.subprocess, "run", return_value=mock.Mock(stdout=output)):
            self.assertEqual(driver.process_cpu_tree(10), {10: 1.5, 11: 2.0, 12: 3.0})

    def test_script_requests_complete_four_command_snapshot(self):
        self.assertEqual(driver.SCRIPT, [{"command": name, "arguments": {}}
                                        for name in ("sections", "functions", "symbols", "exports")])

    def test_capture_preserves_stdout_and_stderr_and_exact_app_environment(self):
        app_process = mock.Mock(pid=100)
        app_process.poll.return_value = 0
        app_process.wait.return_value = 7
        app_process.returncode = 7
        watcher = mock.Mock(pid=200)
        watcher.poll.return_value = 0
        calls = []

        def start(command, **kwargs):
            calls.append((command, kwargs))
            if len(calls) == 1:
                kwargs["stdout"].write(b'[\n  {"verbatim": true}\n]\n')
                kwargs["stderr"].write(b"first error\nsecond error\n")
                return app_process
            return watcher

        environment = {"PATH": "/bin", "HOME": "/home/example", "MACSCOPE_SSA_LIFTER": "1"}
        output = self.root / "capture.functions.json"
        with mock.patch.object(driver.subprocess, "Popen", side_effect=start):
            result = driver.capture(Path("/build/Debug/MacScope.app/Contents/MacOS/MacScope"),
                                    "/inputs/SampleApp", "/output/script.json", output,
                                    environment, "/tools/progress-watch.sh")
        self.assertEqual(output.read_bytes(), b'[\n  {"verbatim": true}\n]\n')
        self.assertEqual(result["first_stderr_line"], "first error")
        self.assertEqual(result["exit_code"], 7)
        self.assertEqual(calls[0][1]["env"], environment)
        self.assertEqual(calls[0][0][1:], ["--run-script", "/output/script.json", "/inputs/SampleApp"])
        self.assertEqual(calls[1][0][4], "5")

    def test_idle_and_wall_timeout_sample_and_terminate_both_process_groups(self):
        class Process:
            def __init__(self, pid):
                self.pid = pid
                self.returncode = None

            def poll(self):
                return self.returncode

            def wait(self, timeout=None):
                self.returncode = -15
                return self.returncode

        for elapsed, reason in ((301, "no_cpu_progress"), (1801, "timeout")):
            with self.subTest(reason=reason):
                app, watcher = Process(100), Process(200)
                output = self.root / (reason + ".functions.json")
                with mock.patch.object(driver.subprocess, "Popen", side_effect=[app, watcher]), \
                        mock.patch.object(driver, "process_cpu_tree", return_value={100: 0}), \
                        mock.patch.object(driver.time, "monotonic", side_effect=[0, elapsed, elapsed + 1]), \
                        mock.patch.object(driver.subprocess, "run") as sample, \
                        mock.patch.object(driver.os, "killpg") as kill:
                    result = driver.capture(Path("/build/Debug/MacScope.app/Contents/MacOS/MacScope"),
                                            "/input", "/script", output, {}, "/watch")
                self.assertEqual(result["stop_reason"], reason)
                self.assertEqual(result["exit_code"], -15)
                self.assertEqual(sample.call_args.args[0], ["/usr/bin/sample", "100", "1"])
                self.assertEqual(kill.call_args_list,
                                 [mock.call(100, driver.signal.SIGTERM), mock.call(200, driver.signal.SIGTERM)])

    def test_launch_failure_is_recorded(self):
        with mock.patch.object(driver.subprocess, "Popen", side_effect=OSError("cannot launch executable")):
            result = driver.capture(Path("/build/Debug/MacScope.app/Contents/MacOS/MacScope"),
                                    "/input", "/script", self.root / "failed.functions.json", {}, "/watch")
        self.assertEqual(result["stop_reason"], "launch_error")
        self.assertEqual(result["first_stderr_line"], "cannot launch executable")
        self.assertIsNone(result["exit_code"])

    def run_arguments(self, corpus):
        app = self.root / "app"
        app.write_bytes(b"app")
        return mock.Mock(corpus=corpus, output=self.root / "output", app=app,
                         git_sha="1" * 40, progress_watch=self.root / "progress-watch.sh",
                         capture_only=True, score_only=False, rescore=False, only=[])

    def test_only_one_main_is_captured_and_scored_without_controls(self):
        corpus = self.corpus()
        products = driver.discover_products(corpus, expected_count=6)
        args = self.run_arguments(corpus)
        args.only = ["sample-app/O/SampleApp"]
        args.capture_only = False
        scorer = mock.Mock()
        with mock.patch.object(driver, "discover_products", return_value=products), \
                mock.patch.object(driver, "installed_toolchain", return_value={}), \
                mock.patch.object(driver, "sha256", return_value="expected"), \
                mock.patch.object(driver, "import_scorer", return_value=scorer), \
                mock.patch.object(driver, "capture", return_value={
                    "exit_code": 0, "wall_seconds": 1, "stop_reason": None,
                    "stdout": str(args.output / "capture.json")}) as capture:
            self.assertEqual(driver.run(args), 0)
        self.assertEqual(capture.call_count, 1)
        self.assertEqual(capture.call_args.args[1], products[0]["binary"])
        self.assertEqual(scorer.score_capture.call_count, 1)
        record = driver.read_json(args.output / "run.json")
        self.assertEqual(record["only"], args.only)
        self.assertEqual(len(record["products"]), 6)
        self.assertEqual([a["key"] for a in record["analyses"]], args.only)

    def test_only_explicit_control_and_multiple_identifiers(self):
        corpus = self.corpus()
        products = driver.discover_products(corpus, expected_count=6)
        args = self.run_arguments(corpus)
        args.only = ["sample-app/Osize/SampleApp", "control/sample-tool/O/SampleTool"]
        with mock.patch.object(driver, "discover_products", return_value=products), \
                mock.patch.object(driver, "installed_toolchain", return_value={}), \
                mock.patch.object(driver, "sha256", return_value="expected"), \
                mock.patch.object(driver, "capture", return_value={
                    "exit_code": 0, "wall_seconds": 1, "stop_reason": None}) as capture:
            self.assertEqual(driver.run(args), 0)
        self.assertEqual([call.args[1] for call in capture.call_args_list],
                         [products[1]["binary"], products[2]["twin"]])

    def test_only_unknown_identifier_is_rejected(self):
        corpus = self.corpus()
        products = driver.discover_products(corpus, expected_count=6)
        args = self.run_arguments(corpus)
        args.only = ["unknown"]
        with mock.patch.object(driver, "discover_products", return_value=products):
            with self.assertRaisesRegex(ValueError, "Unknown product identifier"):
                driver.run(args)
        self.assertFalse(args.output.exists())

    def test_only_preserves_full_manifest_validation(self):
        args = self.run_arguments(self.corpus())
        args.only = ["sample-app/O/SampleApp"]
        with self.assertRaisesRegex(ValueError, "Expected 24 main executables, found 6"):
            driver.run(args)
        products = driver.discover_products(args.corpus, expected_count=6)
        with mock.patch.object(driver, "discover_products", return_value=products[:2]):
            with self.assertRaisesRegex(ValueError, "Expected one -O control for sample-tool"):
                driver.run(args)
        with self.assertRaisesRegex(ValueError, "outside the read-only corpus"):
            args.output = args.corpus / "output"
            driver.run(args)

    def test_completed_and_failed_captures_are_reused_without_hash_or_execution(self):
        corpus = self.corpus()
        products = driver.discover_products(corpus, expected_count=6)
        args = self.run_arguments(corpus)
        captures = []

        def capture(*positional, **kwargs):
            captures.append(positional)
            destination = positional[3]
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(b"[]\n")
            return {"exit_code": 9 if len(captures) == 2 else 0, "wall_seconds": 1,
                    "first_stderr_line": "failed" if len(captures) == 2 else "", "stop_reason": None,
                    "stdout": str(destination)}

        with mock.patch.object(driver, "discover_products", return_value=products), \
                mock.patch.object(driver, "installed_toolchain", return_value={"swift": "synthetic"}), \
                mock.patch.object(driver, "sha256", return_value="expected") as digest, \
                mock.patch.object(driver, "capture", side_effect=capture):
            self.assertEqual(driver.run(args), 1)
            self.assertEqual(len(captures), 9)
            self.assertEqual(digest.call_args_list, [mock.call(args.app.resolve())])  # corpus inputs are never hashed
        with mock.patch.object(driver, "discover_products", return_value=products), \
                mock.patch.object(driver, "sha256", side_effect=AssertionError("repeat digest")), \
                mock.patch.object(driver, "capture", side_effect=AssertionError("repeat capture")):
            self.assertEqual(driver.run(args), 1)

    def test_interrupted_capture_requires_review_without_rerun(self):
        corpus = self.corpus()
        products = driver.discover_products(corpus, expected_count=6)
        args = self.run_arguments(corpus)
        args.output.mkdir()
        driver.write_json(args.output / "run.json", {
            "app_identity": driver.file_identity(args.app), "git_sha": args.git_sha,
            "environment": driver.process_environment(), "products": products,
            "analyses": [{"key": "sample-app/O/SampleApp", "status": "running"}], "sha_checks": {}})
        with mock.patch.object(driver, "discover_products", return_value=products), \
                mock.patch.object(driver, "capture", side_effect=AssertionError("must not rerun")):
            with self.assertRaisesRegex(ValueError, "Interrupted capture requires operator review"):
                driver.run(args)


    def test_missing_capture_is_reported_as_score_failure_without_execution(self):
        corpus = self.corpus()
        products = driver.discover_products(corpus, expected_count=6)
        args = self.run_arguments(corpus)
        args.capture_only = False
        args.score_only = True
        args.output.mkdir()
        record = {"key": "sample-app/O/SampleApp", "status": "captured", "binary": "SampleApp",
                  "opt": "O", "control": False, "stdout": str(args.output / "missing.functions.json")}
        driver.write_json(args.output / "run.json", {
            "app_identity": driver.file_identity(args.app), "git_sha": args.git_sha,
            "environment": driver.process_environment(), "products": products,
            "analyses": [record], "sha_checks": {}})
        scorer = mock.Mock()
        scorer.score_capture.side_effect = FileNotFoundError("missing capture")
        with mock.patch.object(driver, "discover_products", return_value=products), \
                mock.patch.object(driver, "import_scorer", return_value=scorer), \
                mock.patch.object(driver, "capture", side_effect=AssertionError("must not capture")), \
                mock.patch.object(driver, "sha256", side_effect=AssertionError("must not hash")):
            self.assertEqual(driver.run(args), 1)
        saved = driver.read_json(args.output / "run.json")["analyses"][0]
        self.assertEqual(saved["status"], "score_failed")
        self.assertEqual(saved["score_error"], "missing capture")
        self.assertEqual(len(scorer.write_aggregate.call_args.kwargs["failures"]), 1)


if __name__ == "__main__":
    unittest.main()
