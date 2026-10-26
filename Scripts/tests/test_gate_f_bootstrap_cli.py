"""Closed CLI parsing and library dispatch; never launches qualification."""
from contextlib import redirect_stdout, redirect_stderr
import io
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from Scripts.reconstruction_gate_f import bootstrap_cli as cli
from Scripts.reconstruction_gate_f import bootstrap_qualification as bootstrap


class BootstrapCLITests(unittest.TestCase):
    def common(self, operation):
        return [operation, "--repository-root", "/source", "--integration-ref", "refs/remotes/github/main",
            "--source-commit", "a" * 40, "--source-tree", "b" * 40,
            "--qualification-run-id", "qualification-cli", "--qualification-run-nonce", "c" * 64,
            "--artifact-root", "/artifacts"]

    def execute_args(self):
        return self.common("execute") + ["--qualification-work-root", "/artifacts/work",
            "--dependency-cache-root", "/cache", "--developer-dir", "/Xcode/Contents/Developer"]

    def test_cli_rejects_execution_assertions_and_arbitrary_vectors(self):
        for option in ("--started-at", "--exit-code", "--passed", "--argv", "--product-sha256", "--resume-run", "--materialize-dependencies", "--artifact-ro"):
            with self.subTest(option=option), redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                cli.parser().parse_args(self.execute_args() + [option, "0"])

    def test_execute_dispatches_exact_authorities(self):
        retained = SimpleNamespace(intent_path=Path("/artifacts/bootstrap.intent.json"), capture_path=Path("/artifacts/bootstrap.capture.json"))
        output = io.StringIO()
        with patch.object(bootstrap, "execute_bootstrap_qualification", return_value=retained) as execute, redirect_stdout(output):
            self.assertEqual(cli.main(self.execute_args()), 0)
        source, run, configuration = execute.call_args.args
        self.assertEqual(source, bootstrap.BootstrapSourceAuthority(Path("/source"), "refs/remotes/github/main", "a" * 40, "b" * 40))
        self.assertEqual(run.nonce, "c" * 64)
        self.assertEqual(configuration.qualification_work_root, Path("/artifacts/work"))
        self.assertEqual(execute.call_args.kwargs, {})
        self.assertIn("MACSCOPE_BOOTSTRAP_CAPTURE=/artifacts/bootstrap.capture.json", output.getvalue())

    def test_admit_dispatches_retained_records_and_independent_candidate(self):
        args = self.common("admit") + ["--intent", "bootstrap.intent.json", "--capture", "bootstrap.capture.json",
            "--candidate-identity", "/candidate.json", "--output", "/artifacts/admission.json"]
        invocation = dict(qualification_work_root="/artifacts/work", dependency_cache_root="/cache", developer_dir="/Xcode/Contents/Developer")
        candidate = object()
        with patch.object(cli, "read_descriptor_relative_bytes", return_value=(b"intent", None, None)), \
             patch.object(bootstrap, "parse_bootstrap_intent", return_value={"invocation": invocation}), \
             patch.object(cli, "_candidate", return_value=candidate), \
             patch.object(bootstrap, "admit_bootstrap_qualification", return_value=SimpleNamespace(admission_path=Path("/artifacts/admission.json"))) as admit, redirect_stdout(io.StringIO()):
            self.assertEqual(cli.main(args), 0)
        retained, actual_candidate = admit.call_args.args
        self.assertIs(actual_candidate, candidate)
        self.assertEqual(retained.source.commit, "a" * 40)
        self.assertEqual(retained.qualification_run.nonce, "c" * 64)
        self.assertEqual(retained.intent_path, Path("/artifacts/bootstrap.intent.json"))
        self.assertEqual(admit.call_args.kwargs, dict(output=Path("/artifacts/admission.json")))

    def test_verify_dispatches_expected_source_and_run_and_errors_fail_closed(self):
        args = self.common("verify") + ["--admission", "admission.json", "--candidate-identity", "/candidate.json"]
        candidate = object()
        with patch.object(cli, "_candidate", return_value=candidate), \
             patch.object(bootstrap, "load_and_revalidate_bootstrap_qualification", return_value=SimpleNamespace(admission_path=Path("/artifacts/admission.json"))) as verify, redirect_stdout(io.StringIO()):
            self.assertEqual(cli.main(args), 0)
        self.assertIs(verify.call_args.kwargs["candidate"], candidate)
        self.assertEqual(verify.call_args.kwargs["expected_source"].tree, "b" * 40)
        self.assertEqual(verify.call_args.kwargs["expected_run"].nonce, "c" * 64)
        with patch.object(cli, "_candidate", side_effect=ValueError("invalid candidate")), redirect_stderr(io.StringIO()):
            self.assertEqual(cli.main(args), 2)


if __name__ == "__main__":
    unittest.main()
