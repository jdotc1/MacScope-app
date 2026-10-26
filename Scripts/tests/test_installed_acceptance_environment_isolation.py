#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import os
from pathlib import Path

from Scripts.tests.installed_acceptance_host_fixture import macos_interpreter_files
import subprocess
from unittest import mock
import unittest

from Scripts.reconstruction import compile_installed_acceptance_gate_plan as compiler
from Scripts.reconstruction import install_release_to_applications as installer
from Scripts.reconstruction import run_installed_acceptance_transaction as transaction
from Scripts.reconstruction_gate_f.receipt_validator import QualificationRunAuthority
from Scripts.tests.test_compile_installed_acceptance_gate_plan import CompilerFixture


EXPECTED_BASE_ENVIRONMENT = {
    "LANG": "C",
    "LC_ALL": "C",
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "NO_PROXY": "*",
    "no_proxy": "*",
}

HOSTILE_INHERITED_ENVIRONMENT = {
    "ALL_PROXY": "http://proxy-user:proxy-password@proxy.invalid:8080",
    "AWS_SECRET_ACCESS_KEY": "inherited-secret",
    "DYLD_FRAMEWORK_PATH": "/tmp/untrusted-frameworks",
    "DYLD_INSERT_LIBRARIES": "/tmp/untrusted.dylib",
    "DYLD_LIBRARY_PATH": "/tmp/untrusted-libraries",
    "GIT_PROXY_COMMAND": "/tmp/untrusted-proxy-command",
    "HOME": "/Users/developer",
    "HTTP_PROXY": "http://proxy-user:proxy-password@proxy.invalid:8080",
    "HTTPS_PROXY": "http://proxy-user:proxy-password@proxy.invalid:8080",
    "MACSCOPE_NETWORK_ALLOWED": "1",
    "PATH": "/opt/homebrew/bin:/usr/local/bin:/developer/tools:/usr/bin",
    "PIP_INDEX_URL": "https://token@packages.invalid/simple",
    "PYTHONHOME": "/tmp/untrusted-python-home",
    "PYTHONPATH": "/tmp/untrusted-python-path",
    "SECRET_TOKEN": "inherited-token",
    "SSH_AUTH_SOCK": "/tmp/inherited-agent.sock",
    "http_proxy": "http://proxy-user:proxy-password@proxy.invalid:8080",
    "https_proxy": "http://proxy-user:proxy-password@proxy.invalid:8080",
}


class InstalledAcceptanceEnvironmentIsolationTests(unittest.TestCase):
    maxDiff = None

    @staticmethod
    def _snapshot(path: Path, *, label: str) -> transaction.FileSnapshot:
        return transaction._read_stable_file(
            path,
            label=label,
            maximum_bytes=32 * 1024 * 1024,
        )

    def _driver_bindings(
        self,
        fixture: CompilerFixture,
        inputs: compiler.CompilationInputs,
    ) -> tuple[transaction.BoundRequest, transaction.PendingBinding]:
        state = inputs.pending_state
        pending_payload = inputs.pending_state_file.payload
        qualification_run = QualificationRunAuthority(
            run_id=str(state["qualification_run_id"]),
            nonce=str(state["qualification_run_nonce"]),
        )
        provenance = (
            inputs.source_app / installer.BUILD_PROVENANCE_RELATIVE_PATH
        )
        request = transaction.BoundRequest(
            python_executable=transaction.SYSTEM_PYTHON,
            installer_script=transaction.INSTALLER_SCRIPT,
            report_script=transaction.WS24_REPORT_SCRIPT,
            gate_plan_compiler=transaction.EXPECTED_GATE_PLAN_COMPILER,
            task10_matrix_script=transaction.TASK10_MATRIX_SCRIPT,
            incremental_xcuitest_script=transaction.INCREMENTAL_XCUITEST_SCRIPT,
            qualification_receipt=self._snapshot(
                inputs.qualification_receipt.path,
                label="qualification receipt fixture",
            ),
            candidate_artifact_root=inputs.candidate_artifact_root,
            candidate_identity=inputs.candidate_file.path,
            preparation_receipt=self._snapshot(
                inputs.native_preparation_receipt.path,
                label="native preparation receipt fixture",
            ),
            installed_ui_preparation_receipt=self._snapshot(
                inputs.installed_ui_preparation_receipt.path,
                label="installed UI preparation receipt fixture",
            ),
            installed_ui_preparation_document=(
                inputs.installed_ui_preparation_document
            ),
            installed_ui_prepared_app=inputs.source_app,
            installed_ui_xctestrun=self._snapshot(
                inputs.installed_ui_xctestrun.path,
                label="installed UI xctestrun fixture",
            ),
            installed_ui_test_bundle=fixture.installed_ui_test_bundle,
            installed_ui_runner=fixture.installed_ui_runner,
            native_xctestrun=self._snapshot(
                inputs.native_xctestrun.path,
                label="native xctestrun fixture",
            ),
            source_app=inputs.source_app,
            installed_app=inputs.installed_app,
            work_root=fixture.work_root,
            artifact_root=Path(str(state["artifact_root"])),
            evidence_root=inputs.evidence_root,
            qualification_root=inputs.qualification_output_root,
            gate_plan_path=inputs.output_path,
            result_output=transaction._plan_absent_file(
                fixture.work_root / transaction.RESULT_NAME,
                label="transaction result fixture",
                maximum_bytes=transaction.MAX_RESULT_BYTES,
            ),
            qualification_run=qualification_run,
            predecessor_observations_sha256=str(
                state["predecessor_observations_sha256"]
            ),
            xcode_developer_dir=fixture.xcode_developer_dir,
            source_authority=inputs.source_authority,
            candidate_token=str(state["candidate_token"]),
            candidate_identity_snapshot=self._snapshot(
                inputs.candidate_file.path,
                label="candidate identity fixture",
            ),
            provenance_snapshot=self._snapshot(
                provenance,
                label="build provenance fixture",
            ),
            timeouts=transaction.Timeouts(
                begin=10.0,
                compiler=10.0,
                report=10.0,
                commit=10.0,
                rollback=10.0,
            ),
        )
        pending = transaction.PendingBinding(
            state=state,
            state_file=inputs.pending_state_file,
            state_sha256=hashlib.sha256(pending_payload).hexdigest(),
            transaction_id=str(state["transaction_id"]),
            transaction_nonce=str(state["transaction_nonce"]),
            acceptance_receipt=Path(str(state["acceptance_receipt_path"])),
        )
        return request, pending

    def test_compiler_driver_and_launcher_keep_every_gate_closed(self) -> None:
        with CompilerFixture() as fixture, macos_interpreter_files(fixture.root), mock.patch.dict(
            os.environ,
            HOSTILE_INHERITED_ENVIRONMENT,
            clear=False,
        ):
            inputs = fixture.inputs()
            published = compiler.compile_and_publish(fixture.namespace())
            self.assertEqual(published, fixture.output)

            request, pending = self._driver_bindings(fixture, inputs)
            admitted = transaction._load_gate_plan(request, pending)
            self.assertEqual(
                tuple(gate.gate_id for gate in admitted.gates),
                transaction.REQUIRED_ACCEPTANCE_GATES,
            )

            expected_environment = {
                **EXPECTED_BASE_ENVIRONMENT,
                "MACSCOPE_ACCEPTANCE_AUTHORITY_SHA256": (
                    admitted.authority_sha256
                ),
            }
            self.assertEqual(
                admitted.authority_sha256,
                hashlib.sha256(
                    compiler.canonical_bytes(dict(admitted.authority))
                ).hexdigest(),
            )
            for gate in admitted.gates:
                with self.subTest(gate=gate.gate_id, seam="plan admission"):
                    self.assertEqual(gate.environment, expected_environment)
                    self.assertEqual(
                        set(gate.environment),
                        compiler.ENVIRONMENT_KEYS,
                    )
                    self.assertEqual(
                        gate.environment[
                            "MACSCOPE_ACCEPTANCE_AUTHORITY_SHA256"
                        ],
                        admitted.authority_sha256,
                    )
                    self.assertTrue(
                        (
                            set(HOSTILE_INHERITED_ENVIRONMENT) - {"PATH"}
                        ).isdisjoint(gate.environment)
                    )

            marker = fixture.root / "shell-eval-must-not-exist"
            launched_argv: list[list[str]] = []
            with mock.patch.object(
                transaction.subprocess,
                "Popen",
                wraps=subprocess.Popen,
            ) as popen:
                for gate in admitted.gates:
                    argv = ("/usr/bin/env",)
                    result = transaction._run_command(
                        argv,
                        10.0,
                        gate.environment,
                    )
                    with self.subTest(gate=gate.gate_id, seam="process launch"):
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertFalse(result.timed_out)
                        self.assertEqual(result.stderr, b"")
                        self.assertEqual(
                            dict(
                                line.split("=", 1)
                                for line in result.stdout.decode("utf-8").splitlines()
                            ),
                            expected_environment,
                        )
                    launched_argv.append(list(argv))

                literal_tokens = [
                    "two words",
                    "*.app",
                    ";",
                    "&&",
                    "$SECRET_TOKEN",
                    f"$(/usr/bin/touch {marker})",
                ]
                literal_argv = ("/usr/bin/printf", "%s\\0", *literal_tokens)
                literal_result = transaction._run_command(
                    literal_argv,
                    10.0,
                    expected_environment,
                )
                self.assertEqual(literal_result.returncode, 0, literal_result.stderr)
                self.assertEqual(literal_result.stderr, b"")
                self.assertEqual(
                    literal_result.stdout.split(b"\0")[:-1],
                    [token.encode("utf-8") for token in literal_tokens],
                )
                launched_argv.append(list(literal_argv))

            self.assertFalse(marker.exists())
            self.assertEqual(popen.call_count, len(admitted.gates) + 1)
            for call, exact_argv in zip(popen.call_args_list, launched_argv):
                self.assertEqual(call.args[0], exact_argv)
                self.assertIs(call.kwargs["shell"], False)
                self.assertEqual(call.kwargs["env"], expected_environment)
                self.assertTrue(call.kwargs["close_fds"])


if __name__ == "__main__":
    unittest.main()
