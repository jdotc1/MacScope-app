#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import io
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "Scripts" / "ci" / "run_hosted_governance.py"
SPEC = importlib.util.spec_from_file_location("run_hosted_governance_evidence", RUNNER)
assert SPEC is not None and SPEC.loader is not None
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


EXPECTED_TOP_LEVEL_FIELDS = {
    "schema_version",
    "report_kind",
    "command_id",
    "candidate_identity_sha256",
    "source_authority",
    "discovered_modules",
    "macos_only_modules",
    "selected_modules",
    "expected_test_ids",
    "expected_test_ids_sha256",
    "test_results",
    "expected_test_count",
    "executed_test_count",
    "passed_test_count",
    "failed_test_count",
    "error_test_count",
    "skipped_test_count",
    "expected_failure_count",
    "unexpected_success_count",
    "result",
    "exit_code",
}


def source_authority(root: Path = ROOT) -> module.HostedGovernanceSourceAuthority:
    return module.HostedGovernanceSourceAuthority(
        canonical_source_root=str(root),
        git_head_commit="1" * 40,
        git_head_tree="2" * 40,
        source_file_count=3,
        source_files_sha256="3" * 64,
        source_provenance_sha256="4" * 64,
        test_module_inventory_sha256="5" * 64,
    )


def run_suite(suite: unittest.TestSuite) -> module.RecordingTextTestResult:
    runner = unittest.TextTestRunner(
        stream=io.StringIO(),
        verbosity=0,
        resultclass=module.RecordingTextTestResult,
    )
    result = runner.run(suite)
    assert isinstance(result, module.RecordingTextTestResult)
    return result


class HostedGovernanceRunnerTests(unittest.TestCase):
    def test_pure_module_classification_is_unique_sorted_and_exact(self) -> None:
        discovery = module.classify_discovered_modules(
            ["test_z.py", "test_a.py", "test_z.py", "test_macos.py"],
            {"test_macos.py": "uses one exact unmocked host boundary"},
        )
        self.assertEqual(
            discovery.discovered_modules,
            ("test_a.py", "test_macos.py", "test_z.py"),
        )
        self.assertEqual(
            discovery.macos_only_modules,
            (("test_macos.py", "uses one exact unmocked host boundary"),),
        )
        self.assertEqual(discovery.selected_modules, ("test_a.py", "test_z.py"))
        with self.assertRaisesRegex(module.HostedGovernanceError, "no longer exist"):
            module.classify_discovered_modules(
                ["test_a.py"],
                {"test_missing.py": "uses one exact unmocked host boundary"},
            )
        with self.assertRaisesRegex(module.HostedGovernanceError, "selected-module closure is empty"):
            module.classify_discovered_modules(
                ["test_macos.py"],
                {"test_macos.py": "uses one exact unmocked host boundary"},
            )

    def test_leaf_closure_rejects_duplicates_and_sorts_ids(self) -> None:
        class First(unittest.TestCase):
            def test_z(self) -> None:
                pass

        class Second(unittest.TestCase):
            def test_a(self) -> None:
                pass

        suite = unittest.TestSuite([First("test_z"), Second("test_a")])
        identifiers = module.expected_test_ids(suite)
        self.assertEqual(identifiers, tuple(sorted(identifiers)))

        duplicate = unittest.TestSuite([First("test_z"), First("test_z")])
        with self.assertRaisesRegex(module.HostedGovernanceError, "duplicate leaf IDs"):
            module.expected_test_ids(duplicate)
        with self.assertRaisesRegex(module.HostedGovernanceError, "leaf closure is empty"):
            module.expected_test_ids(unittest.TestSuite())

    def test_all_six_leaf_statuses_are_closed_and_every_adverse_status_fails(self) -> None:
        class StatusCases(unittest.TestCase):
            def test_passed(self) -> None:
                pass

            def test_failed(self) -> None:
                self.fail("deliberate")

            def test_error(self) -> None:
                raise RuntimeError("deliberate")

            @unittest.skip("deliberate")
            def test_skipped(self) -> None:
                pass

            @unittest.expectedFailure
            def test_expected_failure(self) -> None:
                self.fail("deliberate")

            @unittest.expectedFailure
            def test_unexpected_success(self) -> None:
                pass

        suite = unittest.defaultTestLoader.loadTestsFromTestCase(StatusCases)
        expected_ids = module.expected_test_ids(suite)
        result = run_suite(suite)
        discovery = module.HostedGovernanceDiscovery(
            ("test_status.py",),
            (("test_macos.py", "uses one exact unmocked host boundary"),),
            ("test_status.py",),
        )
        document = module.test_results_document(
            discovery=discovery,
            candidate_digest="a" * 64,
            source_authority=source_authority(),
            expected_ids=expected_ids,
            result=result,
        )

        self.assertEqual(set(document), EXPECTED_TOP_LEVEL_FIELDS)
        self.assertEqual(
            {row["status"] for row in document["test_results"]},
            module.TEST_STATUSES,
        )
        self.assertEqual(
            [row["test_id"] for row in document["test_results"]],
            sorted(expected_ids),
        )
        for count_field in (
            "passed_test_count",
            "failed_test_count",
            "error_test_count",
            "skipped_test_count",
            "expected_failure_count",
            "unexpected_success_count",
        ):
            self.assertEqual(document[count_field], 1, count_field)
        self.assertEqual(document["expected_test_count"], 6)
        self.assertEqual(document["executed_test_count"], 6)
        self.assertEqual(document["result"], "failed")
        self.assertEqual(document["exit_code"], 1)

    def test_subtest_failure_closes_the_parent_leaf_as_failed(self) -> None:
        class SubtestCase(unittest.TestCase):
            def test_parent(self) -> None:
                with self.subTest(value=1):
                    self.assertEqual(1, 2)

        suite = unittest.defaultTestLoader.loadTestsFromTestCase(SubtestCase)
        expected_ids = module.expected_test_ids(suite)
        result = run_suite(suite)
        self.assertEqual(result.status_by_test_id, {expected_ids[0]: "failed"})

    def test_only_an_all_passed_complete_closure_is_favorable(self) -> None:
        class PassingCase(unittest.TestCase):
            def test_passed(self) -> None:
                pass

        suite = unittest.defaultTestLoader.loadTestsFromTestCase(PassingCase)
        expected_ids = module.expected_test_ids(suite)
        result = run_suite(suite)
        discovery = module.HostedGovernanceDiscovery(
            ("test_pass.py",), (), ("test_pass.py",)
        )
        document = module.test_results_document(
            discovery=discovery,
            candidate_digest="b" * 64,
            source_authority=source_authority(),
            expected_ids=expected_ids,
            result=result,
        )
        self.assertEqual(document["result"], "passed")
        self.assertEqual(document["exit_code"], 0)
        self.assertEqual(document["passed_test_count"], 1)

        result.status_by_test_id.clear()
        with self.assertRaisesRegex(module.HostedGovernanceError, "exact discovered leaf set"):
            module.test_results_document(
                discovery=discovery,
                candidate_digest="b" * 64,
                source_authority=source_authority(),
                expected_ids=expected_ids,
                result=result,
            )

    def test_structured_cli_writes_canonical_create_only_outputs(self) -> None:
        class PassingCase(unittest.TestCase):
            def test_passed(self) -> None:
                pass

        discovery = module.HostedGovernanceDiscovery(
            ("test_pass.py",),
            (("test_macos.py", "uses one exact unmocked host boundary"),),
            ("test_pass.py",),
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            candidate = root / "candidate.json"
            test_results_path = root / "test-results.json"
            execution_report_path = root / "execution-report.json"
            argv = [
                "--candidate-identity",
                str(candidate),
                "--source-root",
                str(ROOT),
                "--test-results-output",
                str(test_results_path),
                "--execution-report-output",
                str(execution_report_path),
                "--qualification-run-id",
                "task11-local-qualification",
                "--qualification-run-nonce",
                "6" * 64,
                "--predecessor-observations-sha256",
                "7" * 64,
            ]
            binding = module.CandidateBinding(mock.sentinel.candidate, "c" * 64)
            authority = source_authority()
            with (
                mock.patch.object(module, "_candidate_binding", return_value=binding),
                mock.patch.object(
                    module,
                    "_validated_source_authority",
                    return_value=(authority, discovery),
                ) as validate_source,
                mock.patch.object(
                    module,
                    "build_test_suite",
                    side_effect=lambda selected, **_kwargs: unittest.TestSuite(
                        [PassingCase("test_passed")]
                    ),
                ),
                mock.patch("sys.stdout", new_callable=io.StringIO),
                mock.patch("sys.stderr", new_callable=io.StringIO),
            ):
                self.assertEqual(module.main(argv), 0)
            self.assertEqual(validate_source.call_count, 2)

            test_results = module.load_canonical_json(test_results_path)
            execution_report = module.load_canonical_json(execution_report_path)
            self.assertEqual(set(test_results), EXPECTED_TOP_LEVEL_FIELDS)
            self.assertEqual(test_results["candidate_identity_sha256"], "c" * 64)
            self.assertEqual(test_results["source_authority"], authority.document())
            self.assertEqual(
                test_results["expected_test_ids_sha256"],
                module.canonical_sha256(test_results["expected_test_ids"]),
            )
            self.assertEqual(test_results["result"], "passed")
            self.assertEqual(
                execution_report,
                {
                    "ended_at_unix_ms": execution_report["ended_at_unix_ms"],
                    "exit_code": 0,
                    "predecessor_observations_sha256": "7" * 64,
                    "qualification_run": {
                        "nonce": "6" * 64,
                        "run_id": "task11-local-qualification",
                    },
                    "result": "passed",
                    "schema_version": 2,
                    "started_at_unix_ms": execution_report["started_at_unix_ms"],
                    "stress": None,
                },
            )
            self.assertLessEqual(
                execution_report["started_at_unix_ms"],
                execution_report["ended_at_unix_ms"],
            )

            with (
                mock.patch.object(module, "_candidate_binding", return_value=binding),
                mock.patch.object(
                    module,
                    "_validated_source_authority",
                    return_value=(authority, discovery),
                ),
                mock.patch("sys.stdout", new_callable=io.StringIO),
                mock.patch("sys.stderr", new_callable=io.StringIO),
            ):
                self.assertEqual(module.main(argv), 2)

    def test_structured_cli_arguments_are_all_or_none(self) -> None:
        with (
            mock.patch("sys.stderr", new_callable=io.StringIO),
            self.assertRaises(SystemExit) as raised,
        ):
            module._parse_arguments(["--candidate-identity", "/tmp/candidate.json"])
        self.assertEqual(raised.exception.code, 2)

    def test_candidate_identity_read_rejects_links_and_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            candidate = root / "candidate.json"
            candidate.write_bytes(b"{}")

            hardlink = root / "hardlink.json"
            module.os.link(candidate, hardlink)
            with self.assertRaisesRegex(module.HostedGovernanceError, "single-link"):
                module._stable_ordinary_file_bytes(
                    candidate,
                    label="candidate identity",
                    maximum_bytes=1024,
                )
            hardlink.unlink()

            symlink = root / "symlink.json"
            symlink.symlink_to(candidate)
            with self.assertRaisesRegex(module.HostedGovernanceError, "non-symlink"):
                module._stable_ordinary_file_bytes(
                    symlink,
                    label="candidate identity",
                    maximum_bytes=1024,
                )

            original_read = module.os.read
            changed = False

            def mutating_read(descriptor: int, size: int) -> bytes:
                nonlocal changed
                payload = original_read(descriptor, size)
                if payload and not changed:
                    candidate.write_bytes(b'{"changed":true}')
                    changed = True
                return payload

            with (
                mock.patch.object(module.os, "read", side_effect=mutating_read),
                self.assertRaisesRegex(module.HostedGovernanceError, "changed during"),
            ):
                module._stable_ordinary_file_bytes(
                    candidate,
                    label="candidate identity",
                    maximum_bytes=1024,
                )

    def test_structured_source_root_must_be_canonical_and_own_the_runner(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            unrelated = Path(directory).resolve()
            with self.assertRaisesRegex(module.HostedGovernanceError, "contain.*runner"):
                module._validated_source_authority(unrelated, mock.sentinel.candidate)

            linked = unrelated.parent / f"{unrelated.name}-linked"
            linked.symlink_to(unrelated, target_is_directory=True)
            try:
                with self.assertRaisesRegex(module.HostedGovernanceError, "canonical non-symlink"):
                    module._validated_source_authority(linked, mock.sentinel.candidate)
            finally:
                linked.unlink()


if __name__ == "__main__":
    unittest.main()
