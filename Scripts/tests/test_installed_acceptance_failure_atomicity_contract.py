from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path
from types import ModuleType, SimpleNamespace
from unittest import mock


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_DRIVER = (
    REPOSITORY_ROOT
    / "Scripts/reconstruction/run_installed_acceptance_transaction.py"
)
DEFAULT_COMPILER = (
    REPOSITORY_ROOT
    / "Scripts/reconstruction/compile_installed_acceptance_gate_plan.py"
)


def _target_path(environment_name: str, default: Path) -> Path:
    override = os.environ.get(environment_name)
    return Path(override).resolve() if override else default


def _load_target(name: str, path: Path) -> ModuleType:
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise AssertionError(f"cannot load installed-acceptance target: {path}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


class InstalledAcceptanceFailureAtomicityContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.driver_path = _target_path(
            "MACSCOPE_ACCEPTANCE_DRIVER_CONTRACT_TARGET", DEFAULT_DRIVER
        )
        cls.compiler_path = _target_path(
            "MACSCOPE_ACCEPTANCE_COMPILER_CONTRACT_TARGET", DEFAULT_COMPILER
        )
        missing = [
            str(path)
            for path in (cls.driver_path, cls.compiler_path)
            if not path.is_file()
        ]
        if missing:
            raise unittest.SkipTest(
                "installed-acceptance compiler/driver integration seam is not "
                f"present at this dependency cut: {', '.join(missing)}"
            )
        cls.transaction = _load_target(
            "macscope_installed_acceptance_transaction_contract_target",
            cls.driver_path,
        )
        cls.compiler = _load_target(
            "macscope_installed_acceptance_compiler_contract_target",
            cls.compiler_path,
        )
        cls.ws24 = cls.transaction.ws24

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="macscope-installed-acceptance-atomicity."
        )
        self.root = Path(self.temporary.name).resolve()
        self.token = "a" * 64
        self.pending = SimpleNamespace(
            state_file=SimpleNamespace(path=self.root / "pending.json")
        )
        self.plan = SimpleNamespace(snapshot=object())
        self.report_plan = SimpleNamespace(path=self.root / "aggregate.json")
        self.gate_plans = tuple(
            (
                gate_id,
                SimpleNamespace(path=self.root / f"{gate_id}.acceptance-gate.json"),
            )
            for gate_id in self.transaction.REQUIRED_ACCEPTANCE_GATES
        )
        self.outcome = self.transaction.TransactionOutcome(
            self.root / self.transaction.RESULT_NAME,
            {"result": "passed"},
        )
        self.request = SimpleNamespace(
            python_executable=Path("/usr/bin/python3"),
            installer_script=self.root / "install_release_to_applications.py",
            gate_plan_compiler=self.compiler_path,
            qualification_receipt=SimpleNamespace(
                path=self.root / "QUALIFICATION_INPUTS.json"
            ),
            candidate_artifact_root=self.root / "candidate-artifacts",
            candidate_identity=self.root / "candidate-artifacts/candidate.json",
            source_app=self.root / "source/MacScope.app",
            installed_app=self.root / "Applications/MacScope.app",
            artifact_root=self.root / "MacScopeInstaller.acceptance-artifacts",
            evidence_root=self.root / "InstalledAcceptanceGate.evidence",
            qualification_root=self.root / "InstalledAcceptanceQualification.evidence",
            work_root=self.root,
            gate_plan_path=(
                self.root
                / "InstalledAcceptanceGate.evidence/InstalledAcceptanceGate.plan.json"
            ),
            result_output=SimpleNamespace(
                path=self.root / self.transaction.RESULT_NAME
            ),
            qualification_run=SimpleNamespace(
                run_id="atomicity-contract", nonce="b" * 64
            ),
            predecessor_observations_sha256="c" * 64,
            candidate_token=self.token,
            timeouts=self.transaction.Timeouts(
                begin=11.0,
                compiler=22.0,
                report=33.0,
                commit=44.0,
                rollback=55.0,
            ),
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _installer_argv(
        self,
        request: object,
        phase: str,
        *,
        gate_inputs: tuple[tuple[str, Path], ...] = (),
    ) -> tuple[str, ...]:
        argv = ["installer", phase, request.candidate_token]
        argv.extend(f"{gate_id}={path}" for gate_id, path in gate_inputs)
        return tuple(argv)

    def _stdout_fields(self, _payload: bytes, *, label: str, **_kwargs: object) -> dict[str, str]:
        if label == "installer commit":
            return {
                "MACSCOPE_INSTALL_RELEASE_PHASE": "committed",
                "MACSCOPE_INSTALL_RELEASE_CANDIDATE_TOKEN": self.token,
            }
        if label == "installer rollback":
            return {
                "MACSCOPE_INSTALL_RELEASE_PHASE": "rolled-back",
                "MACSCOPE_INSTALL_RELEASE_CANDIDATE_TOKEN": self.token,
            }
        return {"begin": "bound"}

    def _execute_with_contract_mocks(
        self,
        *,
        failing_helper: str | None = None,
        failing_stage: str | None = None,
        compiler_stdout: bytes | None = None,
        events: list[str] | None = None,
    ) -> tuple[BaseException | None, list[tuple[tuple[str, ...], float, dict[str, str]]]]:
        transaction = self.transaction
        calls: list[tuple[tuple[str, ...], float, dict[str, str]]] = []
        observed_events = events if events is not None else []

        def runner(
            argv: tuple[str, ...],
            timeout_seconds: float,
            environment: dict[str, str],
        ) -> object:
            calls.append((argv, timeout_seconds, dict(environment)))
            stage = "compiler" if argv[0] == "compiler" else argv[1]
            observed_events.append(stage)
            if stage == failing_stage:
                return transaction.CommandResult(
                    argv, 73, b"private failure stdout", b"injected failure"
                )
            stdout = b""
            if stage == "compiler":
                stdout = (
                    compiler_stdout
                    if compiler_stdout is not None
                    else f"{self.request.gate_plan_path}\n".encode("utf-8")
                )
            return transaction.CommandResult(argv, 0, stdout, b"")

        def publish(*_args: object, **_kwargs: object) -> object:
            observed_events.append("publish-result")
            return self.outcome

        def validate(*_args: object, **_kwargs: object) -> object:
            observed_events.append("validate-commit")
            return object()

        def load_plan(*_args: object, **_kwargs: object) -> object:
            observed_events.append("load-plan")
            return self.plan

        helpers: dict[str, object] = {
            # Contract commands/apps are synthetic, including rollback. Keep
            # their census boundary separate from the host's running apps.
            "require_app_quiescent": lambda *_args: None,
            "_installer_argv": self._installer_argv,
            "_compiler_argv": lambda *_args, **_kwargs: ("compiler",),
            "_parse_key_value_stdout": self._stdout_fields,
            "_load_pending_binding": lambda *_args, **_kwargs: self.pending,
            "_create_private_directory": lambda *_args, **_kwargs: None,
            "_assert_pending_unchanged": lambda *_args, **_kwargs: None,
            "_load_gate_plan": load_plan,
            "_qualification_plans": lambda *_args, **_kwargs: (
                self.report_plan,
                self.gate_plans,
            ),
            "_run_task10_prerequisite": lambda *_args, **_kwargs: object(),
            "_execute_gate_plan": lambda *_args, **_kwargs: transaction.GateExecution(
                outputs=(), publication=object()
            ),
            "_assert_snapshot_unchanged": lambda *_args, **_kwargs: None,
            "_validate_terminal_commit": validate,
            "_publish_result": publish,
        }
        if failing_helper is not None:
            helpers[failing_helper] = mock.Mock(
                side_effect=RuntimeError(f"injected {failing_helper} failure")
            )

        caught: BaseException | None = None
        with contextlib.ExitStack() as stack:
            for name, replacement in helpers.items():
                stack.enter_context(mock.patch.object(transaction, name, replacement))
            try:
                transaction.execute_transaction(self.request, runner=runner)
            except BaseException as error:  # asserted by each adversarial caller
                caught = error
        return caught, calls

    def test_every_post_begin_failure_attempts_the_exact_rollback(self) -> None:
        helper_boundaries = (
            "_load_pending_binding",
            "_create_private_directory",
            "_assert_pending_unchanged",
            "_load_gate_plan",
            "_qualification_plans",
            "_run_task10_prerequisite",
            "_execute_gate_plan",
            "_assert_snapshot_unchanged",
            "_validate_terminal_commit",
            "_publish_result",
        )
        for boundary in helper_boundaries:
            with self.subTest(helper=boundary):
                error, calls = self._execute_with_contract_mocks(
                    failing_helper=boundary
                )
                self.assertIsInstance(error, self.transaction.TransactionFailed)
                self.assertTrue(error.rollback_attempted)
                self.assertTrue(error.rollback_succeeded)
                self.assertEqual(
                    calls[-1],
                    (
                        ("installer", "rollback", self.token),
                        self.request.timeouts.rollback,
                        self.transaction.BASE_ENVIRONMENT,
                    ),
                )
                self.assertFalse(self.request.result_output.path.exists())

        for stage in ("begin", "compiler", "commit"):
            with self.subTest(command=stage):
                error, calls = self._execute_with_contract_mocks(
                    failing_stage=stage
                )
                self.assertIsInstance(error, self.transaction.TransactionFailed)
                self.assertTrue(error.rollback_attempted)
                self.assertEqual(calls[-1][0], ("installer", "rollback", self.token))
                self.assertFalse(self.request.result_output.path.exists())

    def test_rollback_argv_is_the_unmodified_pending_transaction_authority(self) -> None:
        observed = self.transaction._installer_argv(self.request, "rollback")
        self.assertEqual(
            observed,
            (
                "/usr/bin/python3",
                "-B",
                str(self.request.installer_script),
                "--phase",
                "rollback",
                "--transaction-token",
                self.token,
                "--candidate-identity",
                str(self.request.candidate_identity),
                "--source-app",
                str(self.request.source_app),
                "--installed-app",
                str(self.request.installed_app),
                "--artifact-root",
                str(self.request.artifact_root),
                "--qualification-run-id",
                self.request.qualification_run.run_id,
                "--qualification-run-nonce",
                self.request.qualification_run.nonce,
                "--predecessor-observations-sha256",
                self.request.predecessor_observations_sha256,
            ),
        )
        self.assertNotIn("--acceptance-gate-input", observed)

    def test_compiler_stdout_is_status_only_and_never_plan_authority(self) -> None:
        hostile = (
            f"{self.request.gate_plan_path}\n"
            '{"authority":"attacker-controlled-stdout"}\n'
        ).encode("utf-8")
        events: list[str] = []
        error, calls = self._execute_with_contract_mocks(
            compiler_stdout=hostile, events=events
        )
        self.assertIsInstance(error, self.transaction.TransactionFailed)
        self.assertNotIn("load-plan", events)
        self.assertEqual(calls[-1][0], ("installer", "rollback", self.token))
        self.assertIn("status contract", error.primary)

    def test_success_result_follows_commit_validation_and_never_precedes_it(self) -> None:
        events: list[str] = []
        error, _calls = self._execute_with_contract_mocks(events=events)
        self.assertIsNone(error)
        self.assertLess(events.index("commit"), events.index("validate-commit"))
        self.assertLess(
            events.index("validate-commit"), events.index("publish-result")
        )

        events = []
        error, calls = self._execute_with_contract_mocks(
            failing_helper="_validate_terminal_commit", events=events
        )
        self.assertIsInstance(error, self.transaction.TransactionFailed)
        self.assertNotIn("publish-result", events)
        self.assertEqual(calls[-1][0], ("installer", "rollback", self.token))
        self.assertFalse(self.request.result_output.path.exists())

    def test_every_create_only_writer_rejects_replacement(self) -> None:
        compiler_output = self.root / "compiler-plan.json"
        compiler_output.write_bytes(b"preexisting compiler authority")
        with self.assertRaises(self.compiler.PlanCompilationError):
            self.compiler._publish_plan(compiler_output, {"replacement": True})
        self.assertEqual(
            compiler_output.read_bytes(), b"preexisting compiler authority"
        )

        transaction_output = self.root / "transaction-result.json"
        plan = self.transaction._plan_absent_file(
            transaction_output,
            label="transaction result",
            maximum_bytes=1024,
        )
        transaction_output.write_bytes(b"preexisting transaction authority")
        with self.assertRaises(self.transaction.TransactionError):
            self.transaction._write_create_only_bytes(
                plan, b"replacement", label="transaction result"
            )
        self.assertEqual(
            transaction_output.read_bytes(), b"preexisting transaction authority"
        )

        ws24_output = self.root / "acceptance-envelope.json"
        ws24_output.write_bytes(b"preexisting envelope authority")
        with self.assertRaises(self.ws24.ReportError):
            self.ws24._write_create_only(
                ws24_output, b"replacement", label="acceptance envelope"
            )
        self.assertEqual(
            ws24_output.read_bytes(), b"preexisting envelope authority"
        )

    def test_task10_network_root_is_lowercase_across_compiler_and_driver(self) -> None:
        expected = self.root / "installed-task10-network"
        request = SimpleNamespace(evidence_root=self.root)
        authority = self.transaction._task10_authority_paths(request)
        paths = self.transaction._task10_paths(request)
        self.assertEqual(
            self.transaction.TASK10_NETWORK_ROOT_NAME,
            "installed-task10-network",
        )
        self.assertEqual(paths.network_root, expected)
        self.assertEqual(
            authority["installed_task10_network_artifact_root"], str(expected)
        )
        compiler_source = self.compiler_path.read_text(encoding="utf-8")
        self.assertIn(
            'network_root = evidence_root / "installed-task10-network"',
            compiler_source,
        )
        self.assertNotIn('evidence_root / "InstalledTask10.network"', compiler_source)

    def _ws24_publication_case(self, accepted: bool) -> tuple[int, list[str], list[Path]]:
        ws24 = self.ws24
        publication_root = self.root / ("accepted" if accepted else "rejected")
        publication_root.mkdir()
        aggregate = publication_root / "WS24.installed-qualification.json"
        outputs = {
            gate_id: publication_root / f"{gate_id}.acceptance-gate.json"
            for gate_id in ws24.REQUIRED_ACCEPTANCE_GATES
        }
        parsed = SimpleNamespace(
            output=aggregate,
            acceptance_gate_output=[],
            cli_gui_operability_report=publication_root / "cli.json",
            mcp_operability_report=publication_root / "mcp.json",
            evidence_json=publication_root / "live.json",
        )
        authority = {"transaction": "bound"}
        state = {
            "application_executable_sha256": "1" * 64,
            "build_provenance_sha256": "2" * 64,
            "candidate_file_sha256": "3" * 64,
            "candidate_identity_sha256": "4" * 64,
            "destination_identity": {"path": "/Applications/MacScope.app"},
            "execution_identity_sha256": "5" * 64,
            "exposed_at_unix_ns": 1,
            "qualification_run_id": "atomicity-contract",
            "qualification_run_nonce": "6" * 64,
            "source_commit": "7" * 40,
            "source_equality_sha256": "8" * 64,
            "source_tree": "9" * 40,
            "transaction_id": "a" * 64,
            "transaction_nonce": "b" * 64,
        }
        initial_gate_ids = (
            "cli",
            "forced-legacy-grid",
            "full-surface",
            "gui",
            "mcp",
            "native-xpc",
        )
        gate_evidence = {
            gate_id: (hashlib.sha256(gate_id.encode("utf-8")).hexdigest(), 2, 2)
            for gate_id in initial_gate_ids
        }
        report = {
            "accepted": accepted,
            "deficiencies": [] if accepted else [{"code": "injected"}],
            "liveEvidenceSHA256": "c" * 64,
            "operabilityAuthority": authority,
        }
        events: list[str] = []

        def write_report(document: dict[str, object], output: Path) -> tuple[str, int, int]:
            events.append("aggregate")
            payload = ws24.canonical_bytes(document)
            mtime = ws24._write_create_only(
                output, payload, label="installed qualification report"
            )
            return hashlib.sha256(payload).hexdigest(), len(payload), mtime

        original_write_envelopes = ws24.write_acceptance_gate_outputs

        def write_envelopes(*args: object, **kwargs: object) -> None:
            self.assertTrue(aggregate.is_file())
            events.append("envelopes")
            original_write_envelopes(*args, **kwargs)

        post_gate_evidence = {
            key: value
            for key, value in gate_evidence.items()
            if key in {"full-surface", "forced-legacy-grid", "native-xpc"}
        }
        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            mock.patch.object(ws24, "parse_arguments", return_value=parsed),
            mock.patch.object(
                ws24, "parse_acceptance_gate_outputs", return_value=outputs
            ),
            mock.patch.object(
                ws24,
                "build_report",
                return_value=(report, state, dict(gate_evidence)),
            ),
            mock.patch.object(ws24, "_validate_qualification_evidence_root"),
            mock.patch.object(ws24, "write_report", side_effect=write_report),
            mock.patch.object(
                ws24,
                "operability_authority_from_arguments",
                return_value=(authority, state, post_gate_evidence),
            ),
            mock.patch.object(ws24, "_fresh_evidence_time"),
            mock.patch.object(
                ws24,
                "write_acceptance_gate_outputs",
                side_effect=write_envelopes,
            ) as envelope_writer,
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            status = ws24.main([])
        if accepted:
            envelope_writer.assert_called_once()
        else:
            envelope_writer.assert_not_called()
        return status, events, list(outputs.values())

    def test_eight_envelopes_publish_only_after_aggregate_acceptance(self) -> None:
        status, events, outputs = self._ws24_publication_case(False)
        self.assertEqual(status, 1)
        self.assertEqual(events, ["aggregate"])
        self.assertTrue(all(not path.exists() for path in outputs))

        status, events, outputs = self._ws24_publication_case(True)
        self.assertEqual(status, 0)
        self.assertEqual(events, ["aggregate", "envelopes"])
        self.assertEqual(len(outputs), 8)
        self.assertTrue(all(path.is_file() for path in outputs))


if __name__ == "__main__":
    unittest.main()
