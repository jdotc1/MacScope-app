from __future__ import annotations

import contextlib
import hashlib
import io
import json
import os
import plistlib
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from Scripts.check_local_signing_policy import (
    EXPECTED_RELEASE_PROVENANCE_SCALARS,
    RELEASE_PROVENANCE_SHA256_FIELDS,
)
from Scripts.reconstruction import install_release_to_applications as installer
from Scripts.reconstruction_gate_f.canonical_json import (
    canonical_bytes,
    decode_canonical_bytes,
)
from Scripts.reconstruction_gate_f.materialize_candidate_identity import (
    bundle_tree_digests,
)
from Scripts.reconstruction_gate_f.tests import candidate_mapping
from Scripts.reconstruction_gate_f import materialize_candidate_identity as materializer
from Scripts.tests.test_local_signing_policy import set_fixture_xattr


EXPECTED_BUNDLE_IDS = {
    "MacScope": "org.macscope.app",
    "AnalysisWorkerXPCService": "org.macscope.app.AnalysisWorker",
    "AIAgentWorkerXPCService": "org.macscope.app.AIAgentWorker",
    "NativeDecompilerXPCService": "org.macscope.app.NativeDecompiler",
    "ShellBrokerXPCService": "org.macscope.app.ShellBroker",
}
QUALIFICATION_RUN_ID = "task11-installed-installation"
QUALIFICATION_RUN_NONCE = "a" * 64
PREDECESSOR_OBSERVATIONS_SHA256 = "b" * 64


class InstallReleaseToApplicationsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.applications = self.root / "Applications"
        self.applications.mkdir()
        self.source = self.root / "Release" / "MacScope.app"
        self.source.parent.mkdir()
        self.installed = self.applications / "MacScope.app"
        self.candidate = self.root / "candidate.json"
        self.artifacts = self.root / "artifacts"
        self._make_app(self.source, marker=b"candidate")
        self._write_candidate(self.source)
        self.atomic_calls: list[tuple[Path, Path, int]] = []
        self.acceptance_gate_arguments: list[str] = []
        self.predecessor_authority: str | None = None

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _make_bundle(self, bundle: Path, executable_name: str, marker: bytes) -> None:
        executable = bundle / "Contents" / "MacOS" / executable_name
        executable.parent.mkdir(parents=True)
        executable.write_bytes(marker + b":" + executable_name.encode("ascii"))
        executable.chmod(0o755)
        info = {
            "CFBundleIdentifier": EXPECTED_BUNDLE_IDS[executable_name],
            "CFBundleExecutable": executable_name,
        }
        (bundle / "Contents" / "Info.plist").write_bytes(
            plistlib.dumps(info, fmt=plistlib.FMT_BINARY, sort_keys=True)
        )

    def _make_app(self, app: Path, *, marker: bytes) -> None:
        self._make_bundle(app, "MacScope", marker)
        for executable_name in ("ShellBrokerLaunchAgent", "SourceExecutionRunner"):
            executable = app / "Contents" / "MacOS" / executable_name
            executable.write_bytes(marker + b":" + executable_name.encode("ascii"))
            executable.chmod(0o755)
        xpc_root = app / "Contents" / "XPCServices"
        for executable_name in (
            "AnalysisWorkerXPCService",
            "AIAgentWorkerXPCService",
            "NativeDecompilerXPCService",
            "ShellBrokerXPCService",
        ):
            self._make_bundle(
                xpc_root / f"{executable_name}.xpc",
                executable_name,
                marker,
            )
        native_code_resources = (
            xpc_root
            / "NativeDecompilerXPCService.xpc"
            / "Contents"
            / "_CodeSignature"
            / "CodeResources"
        )
        native_code_resources.parent.mkdir(parents=True)
        native_code_resources.write_bytes(marker + b":NativeDecompiler:CodeResources")

        source = candidate_mapping()["source"]
        provenance_document = {
            field: hashlib.sha256(f"fixture:{field}".encode("ascii")).hexdigest()
            for field in RELEASE_PROVENANCE_SHA256_FIELDS
        }
        provenance_document.update(EXPECTED_RELEASE_PROVENANCE_SCALARS)
        provenance_document.update(
            {
                "git_head_commit": source["commit"],
                "git_head_tree": source["tree"],
                "project_yml_sha256": source["project_yml_sha256"],
                "machokit_analysis_worker_executable_sha256": (
                    installer._sha256_file(
                        xpc_root
                        / "AnalysisWorkerXPCService.xpc"
                        / "Contents"
                        / "MacOS"
                        / "AnalysisWorkerXPCService"
                    )
                ),
                "native_decompiler_embedded_service_executable_sha256": (
                    installer._sha256_file(
                        xpc_root
                        / "NativeDecompilerXPCService.xpc"
                        / "Contents"
                        / "MacOS"
                        / "NativeDecompilerXPCService"
                    )
                ),
                "native_decompiler_embedded_service_code_resources_sha256": (
                    installer._sha256_file(native_code_resources)
                ),
            }
        )
        provenance = app / installer.BUILD_PROVENANCE_RELATIVE_PATH
        provenance.parent.mkdir(parents=True, exist_ok=True)
        provenance.write_bytes(
            (
                json.dumps(
                    provenance_document,
                    ensure_ascii=True,
                    allow_nan=False,
                    sort_keys=True,
                    separators=(",", ":"),
                )
                + "\n"
            ).encode("utf-8")
        )
        provenance.chmod(0o644)

    def _write_candidate(self, app: Path) -> None:
        mapping = candidate_mapping()
        digests = bundle_tree_digests(app)
        application = mapping["application"]
        application["bundle_identifier"] = EXPECTED_BUNDLE_IDS["MacScope"]
        application["bundle_sha256"] = digests.content_sha256
        application["closed_tree_sha256"] = digests.closed_tree_sha256
        application["root_mode"] = app.stat().st_mode & 0o7777
        application["executable_sha256"] = installer._sha256_file(
            app / "Contents" / "MacOS" / "MacScope"
        )
        executable_names = {
            "analysis-worker": "AnalysisWorkerXPCService",
            "ai-agent-worker": "AIAgentWorkerXPCService",
            "native-decompiler": "NativeDecompilerXPCService",
            "shell-broker": "ShellBrokerXPCService",
        }
        application["embedded_executables"] = [
            {
                "identity_id": identity_id,
                "sha256": installer._sha256_file(
                    app
                    / "Contents"
                    / "XPCServices"
                    / f"{name}.xpc"
                    / "Contents"
                    / "MacOS"
                    / name
                ),
            }
            for identity_id, name in sorted(executable_names.items())
        ]
        self.candidate.write_bytes(canonical_bytes(mapping))

    def _atomic_rename(self, source: Path, destination: Path, flags: int) -> None:
        self.atomic_calls.append((source, destination, flags))
        if flags == installer.RENAME_EXCL:
            if destination.exists() or destination.is_symlink():
                raise FileExistsError("destination exists")
            os.rename(source, destination)
            return
        if flags != installer.RENAME_SWAP:
            raise AssertionError(f"unexpected rename flags: {flags}")
        temporary = source.with_name(source.name + ".test-swap")
        if temporary.exists():
            raise AssertionError("test swap temporary unexpectedly exists")
        os.rename(source, temporary)
        os.rename(destination, source)
        os.rename(temporary, destination)

    def _run(
        self,
        *,
        collector=installer.collect_installed_source_equality,
        copy_tree=installer._default_copy_tree,
        remove_tree=installer._remove_tree,
        report_writer=installer._write_create_only,
        sync_regular_file=installer._fsync_regular_file,
        sync_directory=installer._fsync_directory,
        atomic_rename=None,
    ):
        stdout = io.StringIO()
        stderr = io.StringIO()
        argv = [
            "--candidate-identity",
            str(self.candidate),
            "--source-app",
            str(self.source),
            "--installed-app",
            str(self.installed),
            "--artifact-root",
            str(self.artifacts),
            "--qualification-run-id",
            QUALIFICATION_RUN_ID,
            "--qualification-run-nonce",
            QUALIFICATION_RUN_NONCE,
            "--predecessor-observations-sha256",
            PREDECESSOR_OBSERVATIONS_SHA256,
        ]
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = installer.main(
                argv,
                _allow_test_destination=True,
                _allow_legacy_one_phase=True,
                _atomic_rename=atomic_rename or self._atomic_rename,
                _equality_collector=collector,
                _copy_tree=copy_tree,
                _remove_tree_function=remove_tree,
                _report_writer=report_writer,
                _sync_regular_file=sync_regular_file,
                _sync_directory=sync_directory,
            )
        return status, stdout.getvalue(), stderr.getvalue()

    def _run_phase(
        self, phase: str, token: str | None = None, *,
        artifact_root: Path | None = None,
        run_id: str = QUALIFICATION_RUN_ID,
        run_nonce: str = QUALIFICATION_RUN_NONCE,
        predecessor_observations: str | None = None,
        copy_tree=installer._default_copy_tree,
        remove_tree=installer._remove_tree,
        atomic_rename=None,
        sync_regular_file=installer._fsync_regular_file,
        sync_directory=installer._fsync_directory,
        transaction_nonce_factory=installer._new_transaction_nonce,
        clock_ns=time.time_ns,
        acceptance_receipt_reader=installer._read_acceptance_receipt_file,
        acceptance_gate_arguments: list[str] | None = None,
    ):
        stdout = io.StringIO()
        stderr = io.StringIO()
        if predecessor_observations is None:
            if phase == "begin":
                pending_state = (
                    self.applications
                    / f".MacScope.pending-{token}"
                    / "transaction.json"
                )
                if token is not None and pending_state.is_file():
                    predecessor_observations = str(
                        decode_canonical_bytes(pending_state.read_bytes())[
                            "predecessor_observations_sha256"
                        ]
                    )
                else:
                    predecessor_observations = (
                        installer.capture_predecessor_observation(
                            self.installed
                        ).sha256
                    )
            else:
                if token is None:
                    raise AssertionError("closeout test requires a transaction token")
                predecessor_observations = self.predecessor_authority
                if predecessor_observations is None:
                    raise AssertionError("closeout test has no transaction authority")
        if phase == "begin":
            self.predecessor_authority = predecessor_observations
        argv = [
            "--phase", phase,
            "--candidate-identity", str(self.candidate),
            "--source-app", str(self.source),
            "--installed-app", str(self.installed),
            "--artifact-root", str(artifact_root or self.artifacts),
            "--qualification-run-id", run_id,
            "--qualification-run-nonce", run_nonce,
            "--predecessor-observations-sha256", predecessor_observations,
        ]
        if token is not None:
            argv.extend(["--transaction-token", token])
        effective_gate_arguments = (
            self.acceptance_gate_arguments
            if acceptance_gate_arguments is None and phase == "commit"
            else []
            if acceptance_gate_arguments is None
            else acceptance_gate_arguments
        )
        for gate_argument in effective_gate_arguments:
            argv.extend(["--acceptance-gate-input", gate_argument])
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = installer.main(
                argv,
                _allow_test_destination=True,
                _atomic_rename=atomic_rename or self._atomic_rename,
                _copy_tree=copy_tree,
                _remove_tree_function=remove_tree,
                _sync_regular_file=sync_regular_file,
                _sync_directory=sync_directory,
                _transaction_nonce_factory=transaction_nonce_factory,
                _clock_ns=clock_ns,
                _acceptance_receipt_reader=acceptance_receipt_reader,
            )
        return status, stdout.getvalue(), stderr.getvalue()

    def _pending(self, token: str) -> tuple[Path, dict[str, object], bytes]:
        root = self.applications / f".MacScope.pending-{token}"
        payload = (root / "transaction.json").read_bytes()
        return root, decode_canonical_bytes(payload), payload

    def _write_acceptance_receipt(
        self,
        token: str,
        *,
        overrides: dict[str, object] | None = None,
        omit_gate: str | None = None,
        gate_overrides: dict[str, dict[str, object]] | None = None,
    ) -> Path:
        _root, state, _state_payload = self._pending(token)
        receipt_path = self.artifacts / installer.ACCEPTANCE_RECEIPT_NAME
        if receipt_path.exists() or receipt_path.is_symlink():
            receipt_path.unlink()
        gate_root = self.root / "acceptance-gate-inputs"
        gate_root.mkdir(exist_ok=True)
        start = max(time.time_ns(), int(state["exposed_at_unix_ns"]))
        destination_identity_sha256 = hashlib.sha256(
            canonical_bytes(state["destination_identity"])
        ).hexdigest()
        self.acceptance_gate_arguments = []
        for gate_id in installer.REQUIRED_ACCEPTANCE_GATES:
            if gate_id == omit_gate:
                continue
            gate: dict[str, object] = {
                "schema_version": installer.ACCEPTANCE_GATE_INPUT_SCHEMA_VERSION,
                "input_kind": installer.ACCEPTANCE_GATE_INPUT_KIND,
                "gate_id": gate_id,
                "started_at_unix_ns": start,
                "ended_at_unix_ns": start + 1,
                "result": "passed",
                "evidence_sha256": hashlib.sha256(
                    f"{state['transaction_id']}:{gate_id}".encode("utf-8")
                ).hexdigest(),
                "transaction_id": state["transaction_id"],
                "transaction_nonce": state["transaction_nonce"],
                "transaction_phase": "pending",
                "rolled_back": False,
                "candidate_identity_sha256": state[
                    "candidate_identity_sha256"
                ],
                "candidate_file_sha256": state["candidate_file_sha256"],
                "source_commit": state["source_commit"],
                "source_tree": state["source_tree"],
                "application_executable_sha256": state[
                    "application_executable_sha256"
                ],
                "build_provenance_sha256": state[
                    "build_provenance_sha256"
                ],
                "source_equality_sha256": state["source_equality_sha256"],
                "execution_identity_sha256": state[
                    "execution_identity_sha256"
                ],
                "qualification_run_id": state["qualification_run_id"],
                "qualification_run_nonce": state["qualification_run_nonce"],
                "destination_identity_sha256": destination_identity_sha256,
            }
            gate.update(overrides or {})
            gate.update((gate_overrides or {}).get(gate_id, {}))
            path = gate_root / f"{gate_id}.json"
            path.write_bytes(canonical_bytes(gate))
            self.acceptance_gate_arguments.append(f"{gate_id}={path}")
        return receipt_path

    def _report(self, name: str):
        return decode_canonical_bytes((self.artifacts / name).read_bytes())

    def _assert_no_transaction_residue(self) -> None:
        residue = tuple(self.applications.glob(".MacScope.app.install-stage-*"))
        self.assertEqual(residue, ())
        self.assertEqual(tuple(self.applications.glob("*.test-swap")), ())
        self.assertEqual(tuple(self.root.glob(".artifacts.report-stage-*")), ())

    def test_begin_rejects_stale_predecessor_authority_before_mutation(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        before = installer.capture_predecessor_observation(self.installed)
        token = installer._load_source_authority(
            self.candidate, self.source
        ).candidate_identity_sha256

        status, stdout, stderr = self._run_phase(
            "begin",
            token,
            predecessor_observations="f" * 64,
        )

        self.assertEqual(status, 1)
        self.assertEqual(stdout, "")
        self.assertIn("differs from the current installed destination", stderr)
        after = installer.capture_predecessor_observation(self.installed)
        self.assertEqual(after.document, before.document)
        self.assertEqual(after.sha256, before.sha256)
        self.assertFalse(self.artifacts.exists())
        self.assertEqual(tuple(self.applications.glob(".MacScope.pending-*")), ())
        self.assertEqual(self.atomic_calls, [])

    def test_stale_authority_cannot_clean_unpublished_pending_root(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        before = installer.capture_predecessor_observation(self.installed)
        token = installer._load_source_authority(
            self.candidate, self.source
        ).candidate_identity_sha256
        pending = self.applications / f".MacScope.pending-{token}"
        pending.mkdir(mode=0o700)
        calls: list[str] = []

        def forbidden_copy(_source: Path, _destination: Path) -> None:
            calls.append("copy")

        def forbidden_remove(_path: Path) -> None:
            calls.append("remove")

        def forbidden_rename(
            _source: Path, _destination: Path, _flags: int
        ) -> None:
            calls.append("rename")

        status, stdout, stderr = self._run_phase(
            "begin",
            token,
            predecessor_observations="f" * 64,
            copy_tree=forbidden_copy,
            remove_tree=forbidden_remove,
            atomic_rename=forbidden_rename,
        )

        self.assertEqual(status, 1)
        self.assertEqual(stdout, "")
        self.assertIn("differs from the current installed destination", stderr)
        self.assertTrue(pending.is_dir())
        self.assertEqual(tuple(pending.iterdir()), ())
        self.assertEqual(calls, [])
        after = installer.capture_predecessor_observation(self.installed)
        self.assertEqual(after.document, before.document)
        self.assertEqual(after.sha256, before.sha256)
        self.assertFalse(self.artifacts.exists())

    def test_begin_is_candidate_bound_idempotent_and_commit_clears_pending(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        predecessor_observations = installer.capture_predecessor_observation(
            self.installed
        ).sha256
        token = installer._load_source_authority(self.candidate, self.source).candidate_identity_sha256
        status, stdout, stderr = self._run_phase("begin", token)
        self.assertEqual(status, 0, stderr)
        pending, state, state_payload = self._pending(token)
        self.assertEqual(
            {
                state["artifact_root"],
                state["qualification_run_id"],
                state["qualification_run_nonce"],
                state["predecessor_observations_sha256"],
            },
            {
                str(self.artifacts),
                QUALIFICATION_RUN_ID,
                QUALIFICATION_RUN_NONCE,
                predecessor_observations,
            },
        )
        authority = installer._load_source_authority(self.candidate, self.source)
        self.assertEqual(state["schema_version"], 3)
        self.assertEqual(state["phase"], "pending")
        self.assertEqual(state["source_commit"], authority.candidate.source.commit)
        self.assertEqual(state["source_tree"], authority.candidate.source.tree)
        self.assertEqual(
            state["application_executable_sha256"], authority.executable_sha256
        )
        self.assertEqual(
            state["build_provenance_sha256"], authority.build_provenance_sha256
        )
        self.assertEqual(len(state["source_equality_sha256"]), 64)
        self.assertEqual(len(state["execution_identity_sha256"]), 64)
        self.assertEqual(len(state["transaction_nonce"]), 64)
        self.assertEqual(len(state["transaction_id"]), 64)
        self.assertEqual(canonical_bytes(state), state_payload)
        self.assertIn("MACSCOPE_INSTALL_RELEASE_PHASE=pending", stdout)
        self.assertIn(
            f"MACSCOPE_INSTALL_RELEASE_TRANSACTION_NONCE={state['transaction_nonce']}",
            stdout,
        )
        self.assertIn(
            "MACSCOPE_INSTALL_RELEASE_PENDING_STATE_SHA256="
            f"{hashlib.sha256(state_payload).hexdigest()}",
            stdout,
        )
        status, _, stderr = self._run_phase("begin", token)
        self.assertEqual(status, 0, stderr)
        self.assertTrue(pending.is_dir())
        self._write_acceptance_receipt(token)
        status, stdout, stderr = self._run_phase("commit", token)
        self.assertEqual(status, 0, stderr)
        self.assertIn("MACSCOPE_INSTALL_RELEASE_PHASE=committed", stdout)
        self.assertFalse(pending.exists())
        self.assertEqual(bundle_tree_digests(self.installed), bundle_tree_digests(self.source))
        receipt = decode_canonical_bytes(
            (self.artifacts / installer.ACCEPTANCE_RECEIPT_NAME).read_bytes()
        )
        self.assertEqual(receipt["schema_version"], 2)
        self.assertEqual(
            receipt["source_equality_sha256"], state["source_equality_sha256"]
        )
        self.assertEqual(
            receipt["execution_identity_sha256"],
            state["execution_identity_sha256"],
        )
        self.assertEqual(tuple(sorted(receipt["gates"])), installer.REQUIRED_ACCEPTANCE_GATES)
        self.assertTrue(
            all(
                len(receipt["gates"][gate_id]["input_sha256"]) == 64
                for gate_id in installer.REQUIRED_ACCEPTANCE_GATES
            )
        )

    def test_wrong_candidate_token_and_interrupted_pending_fail_closed(self) -> None:
        token = installer._load_source_authority(self.candidate, self.source).candidate_identity_sha256
        status, _, stderr = self._run_phase("begin", token)
        self.assertEqual(status, 0, stderr)
        status, _, stderr = self._run_phase("commit", "0" * len(token))
        self.assertEqual(status, 1)
        self.assertIn("transaction token does not match", stderr)
        pending = self.applications / f".MacScope.pending-{token}"
        (pending / "transaction.json").unlink()
        status, _, stderr = self._run_phase("begin", token)
        self.assertEqual(status, 1)
        self.assertIn("pending transaction state is unreadable", stderr)

    def test_rollback_restores_exact_predecessor_and_clears_pending(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        predecessor = bundle_tree_digests(self.installed)
        token = installer._load_source_authority(self.candidate, self.source).candidate_identity_sha256
        status, _, stderr = self._run_phase("begin", token)
        self.assertEqual(status, 0, stderr)
        status, stdout, stderr = self._run_phase("rollback", token)
        self.assertEqual(status, 0, stderr)
        self.assertIn("MACSCOPE_INSTALL_RELEASE_PHASE=rolled-back", stdout)
        self.assertEqual(bundle_tree_digests(self.installed), predecessor)
        self.assertFalse((self.applications / f".MacScope.pending-{token}").exists())

    def test_rollback_retains_four_field_authority_across_app_root_ctime_churn(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        predecessor = installer._capture_exact_bundle(self.installed)
        token = installer._load_source_authority(self.candidate, self.source).candidate_identity_sha256
        status, _, stderr = self._run_phase("begin", token)
        self.assertEqual(status, 0, stderr)
        pending, state, _ = self._pending(token)
        original_digest = materializer.bundle_tree_digests
        changes = 0

        def digest_then_churn(path):
            nonlocal changes
            result = original_digest(path)
            changes += 1
            set_fixture_xattr(path, str(changes).encode("ascii"))
            return result

        with mock.patch.object(materializer, "bundle_tree_digests", digest_then_churn):
            status, stdout, stderr = self._run_phase("rollback", token)
        self.assertEqual(status, 0, stderr)
        self.assertGreater(changes, 0)
        self.assertIn("MACSCOPE_INSTALL_RELEASE_PHASE=rolled-back", stdout)
        self.assertFalse(pending.exists())
        restored = installer._capture_exact_bundle(self.installed)
        self.assertEqual(restored.digests, predecessor.digests)
        self.assertEqual(restored.root_mode, predecessor.root_mode)
        self.assertEqual(restored.directory_identity[:3], predecessor.directory_identity[:3])
        self.assertEqual(len(installer._snapshot_record(restored)["directory_identity"]), 4)
        status, _, stderr = self._run_phase("rollback", token)
        self.assertEqual(status, 0, stderr)

    def test_authority_mismatch_preserves_pending_transaction(self) -> None:
        token = installer._load_source_authority(self.candidate, self.source).candidate_identity_sha256
        status, _, stderr = self._run_phase("begin", token)
        self.assertEqual(status, 0, stderr)
        pending = self.applications / f".MacScope.pending-{token}"
        state_path = pending / "transaction.json"
        original_state = state_path.read_bytes()
        original_installed = bundle_tree_digests(self.installed)
        mismatch_cases = (
            {"artifact_root": self.root / "other-artifacts"},
            {"run_id": "different-run"},
            {"run_nonce": "c" * 64},
            {"predecessor_observations": "d" * 64},
        )
        for overrides in mismatch_cases:
            status, _, stderr = self._run_phase("commit", token, **overrides)
            self.assertEqual(status, 1)
            self.assertIn("pending transaction", stderr)
            self.assertEqual(state_path.read_bytes(), original_state)
            self.assertEqual(bundle_tree_digests(self.installed), original_installed)
        status, _, stderr = self._run_phase("rollback", token)
        self.assertEqual(status, 0, stderr)

    def test_commit_requires_post_install_acceptance_and_preserves_rollback(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        predecessor = bundle_tree_digests(self.installed)
        token = installer._load_source_authority(
            self.candidate, self.source
        ).candidate_identity_sha256
        status, _, stderr = self._run_phase("begin", token)
        self.assertEqual(status, 0, stderr)
        pending, _state, state_payload = self._pending(token)

        status, _, stderr = self._run_phase("commit", token)

        self.assertEqual(status, 1)
        self.assertIn("acceptance", stderr)
        self.assertTrue(pending.is_dir())
        self.assertEqual((pending / "transaction.json").read_bytes(), state_payload)
        self.assertTrue((pending / "predecessor").is_dir())
        status, _, stderr = self._run_phase("rollback", token)
        self.assertEqual(status, 0, stderr)
        self.assertEqual(bundle_tree_digests(self.installed), predecessor)

    def test_acceptance_receipt_rejects_mixed_replay_rolled_back_and_missing_gate(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        token = installer._load_source_authority(
            self.candidate, self.source
        ).candidate_identity_sha256
        status, _, stderr = self._run_phase("begin", token)
        self.assertEqual(status, 0, stderr)
        pending, _state, state_payload = self._pending(token)

        cases = (
            ({"source_commit": "f" * 40}, None, "source_commit"),
            ({"qualification_run_nonce": "c" * 64}, None, "qualification_run_nonce"),
            ({"transaction_nonce": "d" * 64}, None, "transaction_nonce"),
            ({"rolled_back": True}, None, "rolled back"),
            ({"transaction_phase": "rolled-back"}, None, "rolled back"),
            ({}, "mcp", "exactly one authoritative input"),
        )
        for overrides, omitted_gate, diagnostic in cases:
            self._write_acceptance_receipt(
                token, overrides=overrides, omit_gate=omitted_gate
            )
            status, _, stderr = self._run_phase("commit", token)
            self.assertEqual(status, 1)
            self.assertIn(diagnostic, stderr)
            self.assertTrue(pending.is_dir())
            self.assertEqual((pending / "transaction.json").read_bytes(), state_payload)

        self._write_acceptance_receipt(
            token, gate_overrides={"signing": {"result": "failed"}}
        )
        status, _, stderr = self._run_phase("commit", token)
        self.assertEqual(status, 1)
        self.assertIn("acceptance gate signing is not passing", stderr)

        self._write_acceptance_receipt(token)
        status, _, stderr = self._run_phase("commit", token)
        self.assertEqual(status, 0, stderr)
        self.assertFalse(pending.exists())

    def test_acceptance_receipt_rejects_symlink_and_hardlink_evidence(self) -> None:
        token = installer._load_source_authority(
            self.candidate, self.source
        ).candidate_identity_sha256
        status, _, stderr = self._run_phase("begin", token)
        self.assertEqual(status, 0, stderr)
        self._write_acceptance_receipt(token)
        gate_path = Path(self.acceptance_gate_arguments[0].split("=", 1)[1])
        payload = gate_path.read_bytes()
        gate_path.unlink()
        hardlink_source = self.root / "hardlink-source.json"
        hardlink_source.write_bytes(payload)
        os.link(hardlink_source, gate_path)

        status, _, stderr = self._run_phase("commit", token)
        self.assertEqual(status, 1)
        self.assertIn("single-link", stderr)
        gate_path.unlink()
        hardlink_source.unlink()

        self._write_acceptance_receipt(token)
        gate_path = Path(self.acceptance_gate_arguments[0].split("=", 1)[1])
        payload = gate_path.read_bytes()
        gate_path.unlink()
        symlink_target = self.root / "symlink-target.json"
        symlink_target.write_bytes(payload)
        gate_path.symlink_to(symlink_target)
        status, _, stderr = self._run_phase("commit", token)
        self.assertEqual(status, 1)
        self.assertIn("acceptance", stderr)
        gate_path.unlink()
        symlink_target.unlink()

        self._write_acceptance_receipt(token)
        status, _, stderr = self._run_phase("rollback", token)
        self.assertEqual(status, 0, stderr)

    def test_acceptance_receipt_is_bounded_and_strictly_canonical(self) -> None:
        token = installer._load_source_authority(
            self.candidate, self.source
        ).candidate_identity_sha256
        status, _, stderr = self._run_phase("begin", token)
        self.assertEqual(status, 0, stderr)
        self._write_acceptance_receipt(token)
        gate_input = Path(self.acceptance_gate_arguments[0].split("=", 1)[1])
        gate_input.write_bytes(b'{ "schema_version": 1 }')

        status, _, stderr = self._run_phase("commit", token)
        self.assertEqual(status, 1)
        self.assertIn("not canonical JSON", stderr)

        gate_input.write_bytes(
            b"x" * (installer.MAX_ACCEPTANCE_GATE_INPUT_BYTES + 1)
        )
        status, _, stderr = self._run_phase("commit", token)
        self.assertEqual(status, 1)
        self.assertIn("size bound", stderr)
        gate_input.unlink()
        status, _, stderr = self._run_phase("rollback", token)
        self.assertEqual(status, 0, stderr)

    def test_acceptance_gate_arguments_reject_duplicate_gate(self) -> None:
        token = installer._load_source_authority(
            self.candidate, self.source
        ).candidate_identity_sha256
        status, _, stderr = self._run_phase("begin", token)
        self.assertEqual(status, 0, stderr)
        self._write_acceptance_receipt(token)
        duplicate_arguments = [
            *self.acceptance_gate_arguments,
            self.acceptance_gate_arguments[0],
        ]

        status, _, stderr = self._run_phase(
            "commit",
            token,
            acceptance_gate_arguments=duplicate_arguments,
        )

        self.assertEqual(status, 1)
        self.assertIn("duplicate acceptance gate input", stderr)
        self.assertTrue(
            (self.applications / f".MacScope.pending-{token}").is_dir()
        )
        status, _, stderr = self._run_phase("rollback", token)
        self.assertEqual(status, 0, stderr)

    def test_acceptance_receipt_publish_crash_reuses_exact_canonical_receipt(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        token = installer._load_source_authority(
            self.candidate, self.source
        ).candidate_identity_sha256
        status, _, stderr = self._run_phase("begin", token)
        self.assertEqual(status, 0, stderr)
        receipt_path = self._write_acceptance_receipt(token)

        class SimulatedCrash(BaseException):
            pass

        def crash_after_receipt_publish(
            source: Path, destination: Path, flags: int
        ) -> None:
            self._atomic_rename(source, destination, flags)
            if destination == receipt_path:
                raise SimulatedCrash("injected loss after receipt publication")

        with self.assertRaises(SimulatedCrash):
            self._run_phase(
                "commit", token, atomic_rename=crash_after_receipt_publish
            )
        self.assertTrue(receipt_path.is_file())
        self.assertTrue(
            (self.applications / f".MacScope.pending-{token}").is_dir()
        )
        payload = receipt_path.read_bytes()
        self.assertEqual(canonical_bytes(decode_canonical_bytes(payload)), payload)

        status, _, stderr = self._run_phase("commit", token)
        self.assertEqual(status, 0, stderr)
        self.assertEqual(receipt_path.read_bytes(), payload)

    def test_pre_begin_acceptance_receipt_is_rejected_without_exposure(self) -> None:
        self.artifacts.mkdir()
        (self.artifacts / installer.ACCEPTANCE_RECEIPT_NAME).write_bytes(
            canonical_bytes({"state": "historical"})
        )
        token = installer._load_source_authority(
            self.candidate, self.source
        ).candidate_identity_sha256

        status, _, stderr = self._run_phase("begin", token)

        self.assertEqual(status, 1)
        self.assertIn("pre-begin acceptance receipt", stderr)
        self.assertFalse(self.installed.exists())
        self.assertFalse(
            (self.applications / f".MacScope.pending-{token}").exists()
        )

    def test_acceptance_receipt_toctou_mutation_preserves_pending_authority(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        predecessor = bundle_tree_digests(self.installed)
        token = installer._load_source_authority(
            self.candidate, self.source
        ).candidate_identity_sha256
        status, _, stderr = self._run_phase("begin", token)
        self.assertEqual(status, 0, stderr)
        receipt_path = self._write_acceptance_receipt(token)

        def mutate_after_read(path: Path) -> installer.StableFile:
            snapshot = installer._read_acceptance_receipt_file(path)
            document = decode_canonical_bytes(snapshot.payload)
            document["result"] = "failed"
            path.write_bytes(canonical_bytes(document))
            return snapshot

        status, _, stderr = self._run_phase(
            "commit", token, acceptance_receipt_reader=mutate_after_read
        )

        self.assertEqual(status, 1)
        self.assertIn("stable file changed", stderr)
        self.assertTrue(
            (self.applications / f".MacScope.pending-{token}").is_dir()
        )
        receipt_path.unlink()
        status, _, stderr = self._run_phase("rollback", token)
        self.assertEqual(status, 0, stderr)
        self.assertEqual(bundle_tree_digests(self.installed), predecessor)

    def test_acceptance_receipt_artifact_root_swap_is_rejected(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        predecessor = bundle_tree_digests(self.installed)
        token = installer._load_source_authority(
            self.candidate, self.source
        ).candidate_identity_sha256
        status, _, stderr = self._run_phase("begin", token)
        self.assertEqual(status, 0, stderr)
        self._write_acceptance_receipt(token)
        replacement = self.root / "artifacts-original"

        def replace_artifact_root_after_read(path: Path) -> installer.StableFile:
            snapshot = installer._read_acceptance_receipt_file(path)
            os.rename(self.artifacts, replacement)
            self.artifacts.symlink_to(replacement, target_is_directory=True)
            return snapshot

        status, _, stderr = self._run_phase(
            "commit",
            token,
            acceptance_receipt_reader=replace_artifact_root_after_read,
        )

        self.assertEqual(status, 1)
        self.assertIn("artifact root", stderr)
        self.assertTrue(
            (self.applications / f".MacScope.pending-{token}").is_dir()
        )
        self.artifacts.unlink()
        os.rename(replacement, self.artifacts)
        status, _, stderr = self._run_phase("rollback", token)
        self.assertEqual(status, 0, stderr)
        self.assertEqual(bundle_tree_digests(self.installed), predecessor)

    def test_installed_mutation_rejects_commit_and_rollback_preserves_both_trees(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        predecessor = bundle_tree_digests(self.installed)
        token = installer._load_source_authority(
            self.candidate, self.source
        ).candidate_identity_sha256
        status, _, stderr = self._run_phase("begin", token)
        self.assertEqual(status, 0, stderr)
        self._write_acceptance_receipt(token)
        executable = self.installed / "Contents/MacOS/MacScope"
        executable.write_bytes(executable.read_bytes() + b":mutated")

        status, _, stderr = self._run_phase("commit", token)
        self.assertEqual(status, 1)
        self.assertIn("installed candidate", stderr)
        status, _, stderr = self._run_phase("rollback", token)
        self.assertEqual(status, 0, stderr)
        self.assertEqual(bundle_tree_digests(self.installed), predecessor)
        retained_matches = tuple(
            self.applications.glob(f".MacScope.rolled-back-{token}-*")
        )
        self.assertEqual(len(retained_matches), 1)
        retained = retained_matches[0]
        self.assertTrue(retained.is_dir())
        self.assertIn(
            b":mutated",
            (retained / "predecessor/Contents/MacOS/MacScope").read_bytes(),
        )
        status, _, _stderr = self._run_phase("rollback", token)
        self.assertEqual(status, 0)
        self.assertTrue(retained.is_dir())

    def test_prepared_state_survives_exposure_crash_and_resumes_exactly(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        predecessor = bundle_tree_digests(self.installed)
        token = installer._load_source_authority(
            self.candidate, self.source
        ).candidate_identity_sha256
        failed = False

        def fail_first_exposure(source: Path, destination: Path, flags: int) -> None:
            nonlocal failed
            if destination == self.installed and not failed:
                failed = True
                raise OSError("injected exposure crash")
            self._atomic_rename(source, destination, flags)

        status, _, stderr = self._run_phase(
            "begin", token, atomic_rename=fail_first_exposure
        )
        self.assertEqual(status, 1)
        self.assertIn("exposure crash", stderr)
        pending, state, _payload = self._pending(token)
        self.assertEqual(state["phase"], "prepared")
        self.assertEqual(bundle_tree_digests(self.installed), predecessor)
        self.assertTrue((pending / "predecessor").is_dir())

        status, _, stderr = self._run_phase("begin", token)
        self.assertEqual(status, 0, stderr)
        _pending, state, _payload = self._pending(token)
        self.assertEqual(state["phase"], "pending")
        status, _, stderr = self._run_phase("rollback", token)
        self.assertEqual(status, 0, stderr)
        self.assertEqual(bundle_tree_digests(self.installed), predecessor)

    def test_initial_pending_state_publication_crash_is_recovered(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        predecessor = bundle_tree_digests(self.installed)
        token = installer._load_source_authority(
            self.candidate, self.source
        ).candidate_identity_sha256

        class SimulatedCrash(BaseException):
            pass

        def crash_before_state_publish(
            source: Path, destination: Path, flags: int
        ) -> None:
            if destination.name == "transaction.json":
                self.assertTrue(source.name.startswith(".transaction.initial-"))
                self.assertEqual(flags, installer.RENAME_EXCL)
                raise SimulatedCrash("injected crash before state publication")
            self._atomic_rename(source, destination, flags)

        with self.assertRaises(SimulatedCrash):
            self._run_phase(
                "begin", token, atomic_rename=crash_before_state_publish
            )
        pending = self.applications / f".MacScope.pending-{token}"
        self.assertTrue(pending.is_dir())
        self.assertFalse((pending / "transaction.json").exists())
        self.assertEqual(bundle_tree_digests(self.installed), predecessor)

        status, _, stderr = self._run_phase("begin", token)
        self.assertEqual(status, 0, stderr)
        _pending, state, _payload = self._pending(token)
        self.assertEqual(state["phase"], "pending")
        status, _, stderr = self._run_phase("rollback", token)
        self.assertEqual(status, 0, stderr)
        self.assertEqual(bundle_tree_digests(self.installed), predecessor)

    def test_pending_root_parent_barrier_failure_cleans_unpublished_root(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        predecessor = bundle_tree_digests(self.installed)
        token = installer._load_source_authority(
            self.candidate, self.source
        ).candidate_identity_sha256
        failed = False

        def fail_initial_parent_barrier(path: Path) -> None:
            nonlocal failed
            if path == self.applications and not failed:
                failed = True
                raise OSError("injected pending-root parent barrier failure")
            installer._fsync_directory(path)

        status, _, stderr = self._run_phase(
            "begin", token, sync_directory=fail_initial_parent_barrier
        )

        self.assertEqual(status, 1)
        self.assertIn("pending-root parent barrier failure", stderr)
        self.assertFalse(
            (self.applications / f".MacScope.pending-{token}").exists()
        )
        self.assertEqual(bundle_tree_digests(self.installed), predecessor)

    def test_partial_copy_process_loss_recovers_from_initialization_authority(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        predecessor = bundle_tree_digests(self.installed)
        token = installer._load_source_authority(
            self.candidate, self.source
        ).candidate_identity_sha256

        class SimulatedCrash(BaseException):
            pass

        def crash_during_copy(_source: Path, stage: Path) -> None:
            partial = stage / "Contents/MacOS"
            partial.mkdir(parents=True)
            (partial / "MacScope").write_bytes(b"partial")
            raise SimulatedCrash("injected process loss during candidate copy")

        with self.assertRaises(SimulatedCrash):
            self._run_phase("begin", token, copy_tree=crash_during_copy)
        pending = self.applications / f".MacScope.pending-{token}"
        self.assertTrue(
            (pending / installer.INITIALIZATION_AUTHORITY_NAME).is_file()
        )
        self.assertFalse((pending / "transaction.json").exists())
        self.assertEqual(bundle_tree_digests(self.installed), predecessor)

        status, _, stderr = self._run_phase("begin", token)
        self.assertEqual(status, 0, stderr)
        self.assertFalse(
            (pending / installer.INITIALIZATION_AUTHORITY_NAME).exists()
        )
        status, _, stderr = self._run_phase("rollback", token)
        self.assertEqual(status, 0, stderr)
        self.assertEqual(bundle_tree_digests(self.installed), predecessor)

    def test_pending_state_publish_failure_leaves_exact_rollback_authority(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        predecessor = bundle_tree_digests(self.installed)
        token = installer._load_source_authority(
            self.candidate, self.source
        ).candidate_identity_sha256
        state_syncs = 0

        def fail_replaced_state_sync(path: Path) -> None:
            nonlocal state_syncs
            if path.name == "transaction.json":
                state_syncs += 1
                if state_syncs == 2:
                    raise OSError("injected pending-state fsync crash")
            installer._fsync_regular_file(path)

        status, _, stderr = self._run_phase(
            "begin", token, sync_regular_file=fail_replaced_state_sync
        )
        self.assertEqual(status, 1)
        self.assertIn("pending-state fsync crash", stderr)
        pending, state, _payload = self._pending(token)
        self.assertEqual(state["phase"], "pending")
        self.assertTrue((pending / "predecessor").is_dir())

        status, _, stderr = self._run_phase("rollback", token)
        self.assertEqual(status, 0, stderr)
        self.assertEqual(bundle_tree_digests(self.installed), predecessor)

    def test_commit_durability_barriers_precede_terminal_transition(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        token = installer._load_source_authority(
            self.candidate, self.source
        ).candidate_identity_sha256
        status, _, stderr = self._run_phase("begin", token)
        self.assertEqual(status, 0, stderr)
        receipt = self._write_acceptance_receipt(token)
        pending, _state, _payload = self._pending(token)
        events: list[tuple[str, str]] = []

        def sync_file(path: Path) -> None:
            events.append(("file", str(path)))
            installer._fsync_regular_file(path)

        def sync_directory(path: Path) -> None:
            events.append(("directory", str(path)))
            installer._fsync_directory(path)

        def atomic_rename(source: Path, destination: Path, flags: int) -> None:
            events.append(("rename", str(destination)))
            self._atomic_rename(source, destination, flags)

        status, _, stderr = self._run_phase(
            "commit",
            token,
            atomic_rename=atomic_rename,
            sync_regular_file=sync_file,
            sync_directory=sync_directory,
        )
        self.assertEqual(status, 0, stderr)
        transition = next(
            index
            for index, event in enumerate(events)
            if event[0] == "rename" and ".MacScope.committing-" in event[1]
        )
        self.assertLess(events.index(("file", str(receipt))), transition)
        self.assertLess(
            events.index(("file", str(pending / "transaction.json"))),
            transition,
        )
        self.assertLess(events.index(("directory", str(self.artifacts))), transition)

    def test_commit_recovers_a_crash_after_atomic_terminal_rename(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        token = installer._load_source_authority(
            self.candidate, self.source
        ).candidate_identity_sha256
        status, _, stderr = self._run_phase("begin", token)
        self.assertEqual(status, 0, stderr)
        self._write_acceptance_receipt(token)
        pending = self.applications / f".MacScope.pending-{token}"
        committing = self.applications / f".MacScope.committing-{token}"

        class SimulatedCrash(BaseException):
            pass

        def crash_after_commit_rename(
            source: Path, destination: Path, flags: int
        ) -> None:
            self._atomic_rename(source, destination, flags)
            if destination == committing:
                raise SimulatedCrash("injected process loss after commit rename")

        with self.assertRaises(SimulatedCrash):
            self._run_phase(
                "commit", token, atomic_rename=crash_after_commit_rename
            )
        self.assertFalse(pending.exists())
        self.assertTrue(committing.is_dir())
        self.assertTrue((committing / installer.COMMIT_AUTHORITY_NAME).is_file())

        status, _, stderr = self._run_phase("commit", token)

        self.assertEqual(status, 0, stderr)
        self.assertFalse(pending.exists())
        self.assertFalse(committing.exists())
        committed = tuple(
            self.applications.glob(f".MacScope.committed-{token}-*")
        )
        self.assertEqual(len(committed), 1)
        self.assertTrue((committed[0] / "transaction.json").is_file())
        self.assertTrue(
            (committed[0] / installer.COMMIT_AUTHORITY_NAME).is_file()
        )
        self.assertEqual(
            bundle_tree_digests(self.installed), bundle_tree_digests(self.source)
        )

    def test_commit_cleanup_crash_retains_terminal_authority(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        token = installer._load_source_authority(
            self.candidate, self.source
        ).candidate_identity_sha256
        status, _, stderr = self._run_phase("begin", token)
        self.assertEqual(status, 0, stderr)
        self._write_acceptance_receipt(token)

        class SimulatedCrash(BaseException):
            pass

        def crash_during_predecessor_cleanup(path: Path) -> None:
            executable = path / "Contents/MacOS/MacScope"
            executable.unlink()
            raise SimulatedCrash("injected crash during predecessor cleanup")

        with self.assertRaises(SimulatedCrash):
            self._run_phase(
                "commit", token, remove_tree=crash_during_predecessor_cleanup
            )
        committed = tuple(
            self.applications.glob(f".MacScope.committed-{token}-*")
        )
        self.assertEqual(len(committed), 1)
        self.assertTrue((committed[0] / "transaction.json").is_file())
        self.assertTrue(
            (committed[0] / installer.COMMIT_AUTHORITY_NAME).is_file()
        )

        installer._remove_tree(self.source)
        self.candidate.unlink()
        installer._remove_tree(self.artifacts)
        self.acceptance_gate_arguments = []

        status, _, stderr = self._run_phase("commit", token)
        self.assertEqual(status, 0, stderr)
        self.assertTrue((committed[0] / "transaction.json").is_file())
        self.assertTrue((committed[0] / "predecessor").is_dir())

    def test_interrupted_committing_root_revalidates_mutated_candidate(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        predecessor = bundle_tree_digests(self.installed)
        token = installer._load_source_authority(
            self.candidate, self.source
        ).candidate_identity_sha256
        status, _, stderr = self._run_phase("begin", token)
        self.assertEqual(status, 0, stderr)
        self._write_acceptance_receipt(token)

        class SimulatedCrash(BaseException):
            pass

        def crash_and_mutate_at_committing(
            source: Path, destination: Path, flags: int
        ) -> None:
            self._atomic_rename(source, destination, flags)
            if destination.name.startswith(".MacScope.committing-"):
                executable = self.installed / "Contents/MacOS/MacScope"
                executable.write_bytes(executable.read_bytes() + b":crash-mutated")
                raise SimulatedCrash("injected loss before post-transition validation")

        with self.assertRaises(SimulatedCrash):
            self._run_phase(
                "commit", token, atomic_rename=crash_and_mutate_at_committing
            )
        status, _, stderr = self._run_phase("commit", token)
        self.assertEqual(status, 1)
        self.assertIn("installed candidate", stderr)
        self.assertTrue(
            (self.applications / f".MacScope.pending-{token}").is_dir()
        )
        status, _, stderr = self._run_phase("rollback", token)
        self.assertEqual(status, 0, stderr)
        self.assertEqual(bundle_tree_digests(self.installed), predecessor)

    def test_rollback_uses_durable_state_after_live_inputs_are_replaced(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        predecessor = bundle_tree_digests(self.installed)
        token = installer._load_source_authority(
            self.candidate, self.source
        ).candidate_identity_sha256
        status, _, stderr = self._run_phase("begin", token)
        self.assertEqual(status, 0, stderr)

        displaced_target = self.root / "externally-replaced.app"
        self._make_app(displaced_target, marker=b"external")
        installer._remove_tree(self.installed)
        self.installed.symlink_to(displaced_target, target_is_directory=True)
        installer._remove_tree(self.source)
        self.candidate.unlink()
        artifact_target = self.root / "replacement-artifacts"
        artifact_target.mkdir()
        self.artifacts.symlink_to(artifact_target, target_is_directory=True)

        status, _, stderr = self._run_phase("rollback", token)

        self.assertEqual(status, 0, stderr)
        self.assertEqual(bundle_tree_digests(self.installed), predecessor)
        retained = tuple(
            self.applications.glob(f".MacScope.rolled-back-{token}-*")
        )
        self.assertEqual(len(retained), 1)
        self.assertTrue((retained[0] / "predecessor").is_symlink())
        status, _, stderr = self._run_phase("rollback", token)
        self.assertEqual(status, 0, stderr)

    def test_rollback_recovers_crash_after_restoration_and_terminal_rename(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        predecessor = bundle_tree_digests(self.installed)
        token = installer._load_source_authority(
            self.candidate, self.source
        ).candidate_identity_sha256
        status, _, stderr = self._run_phase("begin", token)
        self.assertEqual(status, 0, stderr)

        class SimulatedCrash(BaseException):
            pass

        crashed = False

        def crash_after_restoration(
            source: Path, destination: Path, flags: int
        ) -> None:
            nonlocal crashed
            self._atomic_rename(source, destination, flags)
            if flags == installer.RENAME_SWAP and not crashed:
                crashed = True
                raise SimulatedCrash("injected crash after predecessor restoration")

        with self.assertRaises(SimulatedCrash):
            self._run_phase(
                "rollback", token, atomic_rename=crash_after_restoration
            )
        self.assertEqual(bundle_tree_digests(self.installed), predecessor)

        class TerminalCrash(BaseException):
            pass

        def crash_after_terminal_rename(
            source: Path, destination: Path, flags: int
        ) -> None:
            self._atomic_rename(source, destination, flags)
            if destination.name.startswith(".MacScope.rolled-back-"):
                raise TerminalCrash("injected crash after rollback terminal rename")

        with self.assertRaises(TerminalCrash):
            self._run_phase(
                "rollback", token, atomic_rename=crash_after_terminal_rename
            )
        status, _, stderr = self._run_phase("rollback", token)
        self.assertEqual(status, 0, stderr)
        self.assertEqual(bundle_tree_digests(self.installed), predecessor)

    def test_rollback_retry_selects_current_authority_among_history(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        predecessor = bundle_tree_digests(self.installed)
        token = installer._load_source_authority(
            self.candidate, self.source
        ).candidate_identity_sha256
        status, _, stderr = self._run_phase("begin", token)
        self.assertEqual(status, 0, stderr)
        status, _, stderr = self._run_phase("rollback", token)
        self.assertEqual(status, 0, stderr)

        second_run_id = "second-installation-run"
        second_run_nonce = "c" * 64
        second_predecessor = installer.capture_predecessor_observation(
            self.installed
        ).sha256
        status, _, stderr = self._run_phase(
            "begin",
            token,
            run_id=second_run_id,
            run_nonce=second_run_nonce,
            predecessor_observations=second_predecessor,
        )
        self.assertEqual(status, 0, stderr)

        class SimulatedCrash(BaseException):
            pass

        def crash_after_current_terminal_rename(
            source: Path, destination: Path, flags: int
        ) -> None:
            self._atomic_rename(source, destination, flags)
            if destination.name.startswith(".MacScope.rolled-back-"):
                raise SimulatedCrash("injected loss after current rollback terminal rename")

        with self.assertRaises(SimulatedCrash):
            self._run_phase(
                "rollback",
                token,
                run_id=second_run_id,
                run_nonce=second_run_nonce,
                predecessor_observations=second_predecessor,
                atomic_rename=crash_after_current_terminal_rename,
            )
        self.assertEqual(
            len(tuple(self.applications.glob(f".MacScope.rolled-back-{token}-*"))),
            2,
        )
        status, _, stderr = self._run_phase(
            "rollback",
            token,
            run_id=second_run_id,
            run_nonce=second_run_nonce,
            predecessor_observations=second_predecessor,
        )
        self.assertEqual(status, 0, stderr)
        self.assertEqual(bundle_tree_digests(self.installed), predecessor)

    def test_commit_transition_toctou_restores_pending_for_exact_rollback(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        predecessor = bundle_tree_digests(self.installed)
        token = installer._load_source_authority(
            self.candidate, self.source
        ).candidate_identity_sha256
        status, _, stderr = self._run_phase("begin", token)
        self.assertEqual(status, 0, stderr)
        self._write_acceptance_receipt(token)
        mutated = False

        def mutate_at_transition(source: Path, destination: Path, flags: int) -> None:
            nonlocal mutated
            self._atomic_rename(source, destination, flags)
            if destination.name.startswith(".MacScope.committing-") and not mutated:
                mutated = True
                executable = self.installed / "Contents/MacOS/MacScope"
                executable.write_bytes(executable.read_bytes() + b":transition-mutated")

        status, _, stderr = self._run_phase(
            "commit", token, atomic_rename=mutate_at_transition
        )
        self.assertEqual(status, 1)
        self.assertIn("commit transition", stderr)
        pending = self.applications / f".MacScope.pending-{token}"
        self.assertTrue(pending.is_dir())
        self.assertFalse(
            (self.applications / f".MacScope.committing-{token}").exists()
        )

        status, _, stderr = self._run_phase("rollback", token)
        self.assertEqual(status, 0, stderr)
        self.assertEqual(bundle_tree_digests(self.installed), predecessor)

    def test_terminal_closeout_revalidates_destination_after_atomic_rename(self) -> None:
        test_root = self.root
        for phase in ("commit", "rollback"):
            with self.subTest(phase=phase):
                case_root = test_root / f"terminal-{phase}"
                self.applications = case_root / "Applications"
                self.applications.mkdir(parents=True)
                self.source = case_root / "Release" / "MacScope.app"
                self.source.parent.mkdir()
                self.installed = self.applications / "MacScope.app"
                self.candidate = case_root / "candidate.json"
                self.artifacts = case_root / "artifacts"
                self.atomic_calls = []
                self.acceptance_gate_arguments = []
                self._make_app(self.source, marker=b"candidate")
                self._write_candidate(self.source)
                self._make_app(self.installed, marker=b"predecessor")

                token = installer._load_source_authority(
                    self.candidate, self.source
                ).candidate_identity_sha256
                status, _, stderr = self._run_phase("begin", token)
                self.assertEqual(status, 0, stderr)
                if phase == "commit":
                    self._write_acceptance_receipt(token)

                def mutate_after_terminal_rename(
                    source: Path, destination: Path, flags: int
                ) -> None:
                    self._atomic_rename(source, destination, flags)
                    terminal_prefix = (
                        ".MacScope.committed-"
                        if phase == "commit"
                        else ".MacScope.rolled-back-"
                    )
                    if destination.name.startswith(terminal_prefix):
                        executable = self.installed / "Contents/MacOS/MacScope"
                        executable.write_bytes(
                            executable.read_bytes() + b":terminal-mutated"
                        )

                status, _, stderr = self._run_phase(
                    phase, token, atomic_rename=mutate_after_terminal_rename
                )

                self.assertEqual(status, 1)
                self.assertIn("changed at terminal closeout", stderr)
                self.assertTrue(
                    (self.applications / f".MacScope.pending-{token}").is_dir()
                )
                self.assertFalse(
                    tuple(
                        self.applications.glob(
                            (
                                f".MacScope.committed-{token}-*"
                                if phase == "commit"
                                else f".MacScope.rolled-back-{token}-*"
                            )
                        )
                    )
                )

    def test_commit_parent_durability_failure_retracts_to_pending(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        predecessor = bundle_tree_digests(self.installed)
        token = installer._load_source_authority(
            self.candidate, self.source
        ).candidate_identity_sha256
        status, _, stderr = self._run_phase("begin", token)
        self.assertEqual(status, 0, stderr)
        self._write_acceptance_receipt(token)
        application_syncs = 0

        def fail_transition_parent_sync(path: Path) -> None:
            nonlocal application_syncs
            if path == self.applications:
                application_syncs += 1
                if application_syncs == 2:
                    raise OSError("injected commit-parent fsync failure")
            installer._fsync_directory(path)

        status, _, stderr = self._run_phase(
            "commit", token, sync_directory=fail_transition_parent_sync
        )
        self.assertEqual(status, 1)
        self.assertIn("commit-parent fsync failure", stderr)
        self.assertTrue(
            (self.applications / f".MacScope.pending-{token}").is_dir()
        )
        self.assertFalse(
            (self.applications / f".MacScope.committing-{token}").exists()
        )

        status, _, stderr = self._run_phase("rollback", token)
        self.assertEqual(status, 0, stderr)
        self.assertEqual(bundle_tree_digests(self.installed), predecessor)

    def test_existing_install_uses_swap_and_emits_fixed_create_only_reports(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        predecessor_root_mode = self.installed.stat().st_mode & 0o7777
        status, stdout, stderr = self._run()

        self.assertEqual(status, 0, stderr)
        self.assertEqual(stderr, "")
        self.assertEqual(
            [flags for _, _, flags in self.atomic_calls],
            [installer.RENAME_SWAP, installer.RENAME_EXCL],
        )
        self.assertEqual(
            bundle_tree_digests(self.installed), bundle_tree_digests(self.source)
        )
        self._assert_no_transaction_residue()
        for key, report_name in installer.STDOUT_KEYS:
            self.assertIn(f"{key}={self.artifacts / report_name}\n", stdout)
            payload = (self.artifacts / report_name).read_bytes()
            self.assertEqual(canonical_bytes(decode_canonical_bytes(payload)), payload)
        operation = self._report(installer.OPERATION_REPORT_NAME)
        self.assertEqual(operation["schema_version"], 2)
        self.assertEqual(operation["result"], "passed")
        self.assertEqual(operation["atomic_replacement"]["mode"], "swap-existing")
        self.assertTrue(operation["predecessor"]["present"])
        self.assertTrue(operation["point_of_no_return_reached"])
        self.assertEqual(
            operation["predecessor_clearance"],
            {"started": True, "completed": True},
        )
        self.assertEqual(
            operation["transaction_residue"], {"present": False, "path": None}
        )
        self.assertEqual(
            operation["source_identity"]["root_mode"],
            self.source.stat().st_mode & 0o7777,
        )
        self.assertEqual(
            operation["predecessor"]["identity"]["root_mode"],
            predecessor_root_mode,
        )
        equality = self._report(installer.SOURCE_EQUALITY_REPORT_NAME)
        self.assertEqual(equality["result"], "passed")
        self.assertEqual(
            equality["installed_authority"]["installed_closed_tree_sha256"],
            equality["installed_authority"]["release_closed_tree_sha256"],
        )
        self.assertEqual(
            equality["stage_authority"]["release_root_mode"],
            self.source.stat().st_mode & 0o7777,
        )
        self.assertEqual(
            equality["installed_authority"]["installed_root_mode"],
            self.installed.stat().st_mode & 0o7777,
        )
        execution = self._report(installer.EXECUTION_REPORT_NAME)
        self.assertEqual(execution["schema_version"], 2)
        self.assertEqual(
            execution["qualification_run"],
            {"run_id": QUALIFICATION_RUN_ID, "nonce": QUALIFICATION_RUN_NONCE},
        )
        self.assertEqual(
            execution["predecessor_observations_sha256"],
            PREDECESSOR_OBSERVATIONS_SHA256,
        )
        with self.assertRaises(installer.InstallationError):
            installer._write_create_only(
                self.artifacts / installer.OPERATION_REPORT_NAME, {"changed": True}
            )

    def test_absent_install_uses_exclusive_atomic_rename(self) -> None:
        status, _, stderr = self._run()

        self.assertEqual(status, 0, stderr)
        self.assertEqual(
            [flags for _, _, flags in self.atomic_calls],
            [installer.RENAME_EXCL, installer.RENAME_EXCL],
        )
        self.assertEqual(
            bundle_tree_digests(self.installed), bundle_tree_digests(self.source)
        )
        self._assert_no_transaction_residue()
        operation = self._report(installer.OPERATION_REPORT_NAME)
        self.assertFalse(operation["predecessor"]["present"])
        self.assertEqual(operation["atomic_replacement"]["mode"], "exclusive-absent")

    def test_post_swap_validation_failure_atomically_restores_predecessor(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        predecessor = bundle_tree_digests(self.installed)
        calls = 0

        def fail_post_swap(source: Path, observed: Path):
            nonlocal calls
            calls += 1
            authority, errors = installer.collect_installed_source_equality(
                source, observed
            )
            if calls == 2:
                return authority, ["injected post-swap validation failure"]
            return authority, errors

        status, _, stderr = self._run(collector=fail_post_swap)

        self.assertEqual(status, 1)
        self.assertIn("injected post-swap validation failure", stderr)
        self.assertEqual(
            [flags for _, _, flags in self.atomic_calls],
            [
                installer.RENAME_SWAP,
                installer.RENAME_SWAP,
                installer.RENAME_EXCL,
            ],
        )
        self.assertEqual(bundle_tree_digests(self.installed), predecessor)
        self._assert_no_transaction_residue()
        operation = self._report(installer.OPERATION_REPORT_NAME)
        self.assertEqual(operation["result"], "failed")
        self.assertEqual(
            operation["rollback"], {"attempted": True, "succeeded": True}
        )
        execution = self._report(installer.EXECUTION_REPORT_NAME)
        self.assertEqual(execution["result"], "failed")
        self.assertEqual(execution["exit_code"], 1)

    def test_candidate_mismatch_is_rejected_before_stage_or_destination_mutation(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        predecessor = bundle_tree_digests(self.installed)
        mapping = decode_canonical_bytes(self.candidate.read_bytes())
        mapping["application"]["bundle_sha256"] = "0" * 64
        self.candidate.write_bytes(canonical_bytes(mapping))

        status, _, stderr = self._run()

        self.assertEqual(status, 1)
        self.assertIn("source app bundle SHA-256 differs", stderr)
        self.assertEqual(
            [flags for _, _, flags in self.atomic_calls],
            [installer.RENAME_EXCL],
        )
        self.assertEqual(bundle_tree_digests(self.installed), predecessor)
        self._assert_no_transaction_residue()
        operation = self._report(installer.OPERATION_REPORT_NAME)
        self.assertFalse(operation["staging"]["fresh_sibling"])
        self.assertIsNone(operation["atomic_replacement"]["mode"])

    def test_partial_copy_failure_is_cleaned_and_reports_no_residue(self) -> None:
        def partial_copy(_source: Path, stage: Path) -> None:
            stage.mkdir()
            (stage / "partial").write_bytes(b"partial")
            raise OSError("injected copy failure")

        status, _, stderr = self._run(copy_tree=partial_copy)

        self.assertEqual(status, 1)
        self.assertIn("injected copy failure", stderr)
        self.assertEqual(
            [flags for _, _, flags in self.atomic_calls],
            [installer.RENAME_EXCL],
        )
        self.assertFalse(self.installed.exists())
        self._assert_no_transaction_residue()
        operation = self._report(installer.OPERATION_REPORT_NAME)
        self.assertEqual(operation["result"], "failed")
        self.assertEqual(
            operation["transaction_residue"], {"present": False, "path": None}
        )
        self.assertIn("partial-stage residue present: false", operation["diagnostic"])

    def test_predecessor_cleanup_failure_crosses_point_of_no_return_without_rollback(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")

        def fail_predecessor_cleanup(path: Path) -> None:
            if path.parent == self.applications and path.name.startswith(
                ".MacScope.app.install-stage-"
            ):
                raise OSError("injected predecessor cleanup failure")
            installer._remove_tree(path)

        status, _, stderr = self._run(remove_tree=fail_predecessor_cleanup)

        self.assertEqual(status, 1)
        self.assertIn("injected predecessor cleanup failure", stderr)
        self.assertEqual(
            [flags for _, _, flags in self.atomic_calls],
            [installer.RENAME_SWAP, installer.RENAME_EXCL],
        )
        self.assertEqual(
            bundle_tree_digests(self.installed), bundle_tree_digests(self.source)
        )
        operation = self._report(installer.OPERATION_REPORT_NAME)
        self.assertTrue(operation["point_of_no_return_reached"])
        self.assertEqual(
            operation["predecessor_clearance"],
            {"started": True, "completed": False},
        )
        self.assertEqual(
            operation["rollback"], {"attempted": False, "succeeded": None}
        )
        self.assertTrue(operation["transaction_residue"]["present"])
        residue = Path(operation["transaction_residue"]["path"])
        self.assertTrue(residue.is_dir())
        installer._remove_tree(residue)

    def test_report_write_failure_exposes_no_partial_final_set_and_never_rolls_back(self) -> None:
        writes = 0

        def fail_second_report(path: Path, value: object) -> None:
            nonlocal writes
            writes += 1
            if writes == 2:
                raise OSError("injected report write failure")
            installer._write_create_only(path, value)

        status, stdout, stderr = self._run(report_writer=fail_second_report)

        self.assertEqual(status, 1)
        self.assertEqual(stdout, "")
        self.assertIn("after the point of no return", stderr)
        self.assertIn("injected report write failure", stderr)
        self.assertEqual(
            [flags for _, _, flags in self.atomic_calls],
            [installer.RENAME_EXCL],
        )
        self.assertEqual(
            bundle_tree_digests(self.installed), bundle_tree_digests(self.source)
        )
        self.assertFalse(self.artifacts.exists())
        self._assert_no_transaction_residue()

    def test_clone_replacement_with_equal_digests_fails_directory_identity_gate(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        first_swap = True

        def clone_candidate_on_first_swap(
            source: Path, destination: Path, flags: int
        ) -> None:
            nonlocal first_swap
            if flags == installer.RENAME_SWAP and first_swap:
                first_swap = False
                self.atomic_calls.append((source, destination, flags))
                predecessor = source.with_name(source.name + ".original-predecessor")
                os.rename(destination, predecessor)
                installer._default_copy_tree(source, destination)
                installer._remove_tree(source)
                os.rename(predecessor, source)
                return
            self._atomic_rename(source, destination, flags)

        status, _, stderr = self._run(atomic_rename=clone_candidate_on_first_swap)

        self.assertEqual(status, 1)
        self.assertIn("installed app changed after equality validation", stderr)
        operation = self._report(installer.OPERATION_REPORT_NAME)
        self.assertEqual(operation["result"], "failed")
        self.assertTrue(operation["rollback"]["attempted"])
        self.assertTrue(operation["transaction_residue"]["present"])
        residue = Path(operation["transaction_residue"]["path"])
        installer._remove_tree(residue)

    def test_durability_barriers_follow_serialized_visibility_order(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        events: list[tuple[str, str, int | None]] = []

        def sync_file(path: Path) -> None:
            events.append(("file", str(path), None))
            installer._fsync_regular_file(path)

        def sync_directory(path: Path) -> None:
            events.append(("directory", str(path), None))
            installer._fsync_directory(path)

        def atomic_rename(source: Path, destination: Path, flags: int) -> None:
            events.append(("rename", str(destination), flags))
            self._atomic_rename(source, destination, flags)

        status, _, stderr = self._run(
            atomic_rename=atomic_rename,
            sync_regular_file=sync_file,
            sync_directory=sync_directory,
        )

        self.assertEqual(status, 0, stderr)
        install_rename = next(
            index
            for index, event in enumerate(events)
            if event == ("rename", str(self.installed), installer.RENAME_SWAP)
        )
        application_parent_syncs = [
            index
            for index, event in enumerate(events)
            if event == ("directory", str(self.applications), None)
        ]
        self.assertEqual(len(application_parent_syncs), 2)
        staged_file_syncs = [
            index
            for index, (kind, path, _) in enumerate(events)
            if kind == "file" and ".MacScope.app.install-stage-" in path
        ]
        staged_root_sync = max(
            index
            for index, (kind, path, _) in enumerate(events)
            if kind == "directory"
            and Path(path).parent == self.applications
            and Path(path).name.startswith(".MacScope.app.install-stage-")
        )
        self.assertTrue(staged_file_syncs)
        self.assertLess(max(staged_file_syncs), staged_root_sync)
        self.assertLess(staged_root_sync, install_rename)
        self.assertLess(install_rename, application_parent_syncs[0])
        self.assertLess(application_parent_syncs[0], application_parent_syncs[1])

        report_file_syncs = [
            index
            for index, (kind, path, _) in enumerate(events)
            if kind == "file" and ".artifacts.report-stage-" in path
        ]
        report_stage_sync = next(
            index
            for index, (kind, path, _) in enumerate(events)
            if kind == "directory"
            and Path(path).name.startswith(".artifacts.report-stage-")
        )
        report_rename = next(
            index
            for index, event in enumerate(events)
            if event == ("rename", str(self.artifacts), installer.RENAME_EXCL)
        )
        artifact_parent_sync = next(
            index
            for index, event in enumerate(events)
            if event == ("directory", str(self.root), None)
            and index > report_rename
        )
        self.assertEqual(len(report_file_syncs), 3)
        self.assertLess(application_parent_syncs[1], min(report_file_syncs))
        self.assertLess(max(report_file_syncs), report_stage_sync)
        self.assertLess(report_stage_sync, report_rename)
        self.assertLess(report_rename, artifact_parent_sync)

    def test_predecessor_clearance_parent_sync_failure_is_nonfavorable_without_rollback(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        application_parent_sync_count = 0

        def fail_clearance_sync(path: Path) -> None:
            nonlocal application_parent_sync_count
            if path == self.applications:
                application_parent_sync_count += 1
                if application_parent_sync_count == 2:
                    raise OSError("injected predecessor-clearance parent fsync failure")
            installer._fsync_directory(path)

        status, _, stderr = self._run(sync_directory=fail_clearance_sync)

        self.assertEqual(status, 1)
        self.assertIn("predecessor-clearance parent fsync failure", stderr)
        self.assertEqual(
            [flags for _, _, flags in self.atomic_calls],
            [installer.RENAME_SWAP, installer.RENAME_EXCL],
        )
        self.assertEqual(
            bundle_tree_digests(self.installed), bundle_tree_digests(self.source)
        )
        operation = self._report(installer.OPERATION_REPORT_NAME)
        self.assertEqual(operation["result"], "failed")
        self.assertTrue(operation["point_of_no_return_reached"])
        self.assertEqual(
            operation["rollback"], {"attempted": False, "succeeded": None}
        )
        self.assertEqual(
            operation["transaction_residue"], {"present": False, "path": None}
        )

    def test_exposure_parent_sync_failure_rolls_back_before_point_of_no_return(self) -> None:
        self._make_app(self.installed, marker=b"predecessor")
        predecessor = bundle_tree_digests(self.installed)
        failed = False

        def fail_first_application_parent_sync(path: Path) -> None:
            nonlocal failed
            if path == self.applications and not failed:
                failed = True
                raise OSError("injected exposure parent fsync failure")
            installer._fsync_directory(path)

        status, _, stderr = self._run(
            sync_directory=fail_first_application_parent_sync
        )

        self.assertEqual(status, 1)
        self.assertIn("exposure parent fsync failure", stderr)
        self.assertEqual(bundle_tree_digests(self.installed), predecessor)
        self._assert_no_transaction_residue()
        operation = self._report(installer.OPERATION_REPORT_NAME)
        self.assertEqual(
            operation["rollback"], {"attempted": True, "succeeded": True}
        )
        self.assertEqual(
            [flags for _, _, flags in self.atomic_calls],
            [
                installer.RENAME_SWAP,
                installer.RENAME_SWAP,
                installer.RENAME_EXCL,
            ],
        )

    def test_staged_file_sync_failure_prevents_atomic_exposure(self) -> None:
        failed = False

        def fail_first_staged_file(path: Path) -> None:
            nonlocal failed
            if not failed:
                failed = True
                raise OSError(f"injected staged-file fsync failure: {path.name}")
            installer._fsync_regular_file(path)

        status, _, stderr = self._run(sync_regular_file=fail_first_staged_file)

        self.assertEqual(status, 1)
        self.assertIn("staged-file fsync failure", stderr)
        self.assertFalse(self.installed.exists())
        self._assert_no_transaction_residue()
        self.assertEqual(
            [flags for _, _, flags in self.atomic_calls],
            [installer.RENAME_EXCL],
        )
        operation = self._report(installer.OPERATION_REPORT_NAME)
        self.assertIsNone(operation["atomic_replacement"]["mode"])
        self.assertEqual(operation["result"], "failed")

    def test_report_parent_sync_failure_retracts_all_favorable_reports(self) -> None:
        artifact_parent_failed = False

        def fail_first_artifact_parent_sync(path: Path) -> None:
            nonlocal artifact_parent_failed
            if path == self.root and not artifact_parent_failed:
                artifact_parent_failed = True
                raise OSError("injected artifact-parent fsync failure")
            installer._fsync_directory(path)

        status, stdout, stderr = self._run(
            sync_directory=fail_first_artifact_parent_sync
        )

        self.assertEqual(status, 1)
        self.assertEqual(stdout, "")
        self.assertIn("artifact-parent fsync failure", stderr)
        self.assertFalse(self.artifacts.exists())
        self.assertEqual(
            bundle_tree_digests(self.installed), bundle_tree_digests(self.source)
        )
        self._assert_no_transaction_residue()
        self.assertEqual(
            [flags for _, _, flags in self.atomic_calls],
            [
                installer.RENAME_EXCL,
                installer.RENAME_EXCL,
                installer.RENAME_EXCL,
            ],
        )

    def test_app_root_mode_drift_cannot_pass_install_equality_gate(self) -> None:
        mutated = False

        def mutate_root_mode_before_exposure(
            source: Path, destination: Path, flags: int
        ) -> None:
            nonlocal mutated
            if destination == self.installed and not mutated:
                mutated = True
                source.chmod(0o700)
            self._atomic_rename(source, destination, flags)

        status, _, stderr = self._run(
            atomic_rename=mutate_root_mode_before_exposure
        )

        self.assertEqual(status, 1)
        self.assertIn(
            "installed app signing-policy equality authority differs from the candidate",
            stderr,
        )
        self.assertFalse(self.installed.exists())
        operation = self._report(installer.OPERATION_REPORT_NAME)
        self.assertEqual(operation["result"], "failed")
        self.assertTrue(operation["rollback"]["attempted"])
        self.assertFalse(operation["rollback"]["succeeded"])
        self.assertTrue(operation["transaction_residue"]["present"])
        residue = Path(operation["transaction_residue"]["path"])
        installer._remove_tree(residue)

    def test_public_cli_refuses_non_applications_destination(self) -> None:
        argv = [
            "--candidate-identity",
            str(self.candidate),
            "--source-app",
            str(self.source),
            "--installed-app",
            str(self.installed),
            "--artifact-root",
            str(self.artifacts),
            "--qualification-run-id",
            QUALIFICATION_RUN_ID,
            "--qualification-run-nonce",
            QUALIFICATION_RUN_NONCE,
            "--predecessor-observations-sha256",
            PREDECESSOR_OBSERVATIONS_SHA256,
        ]
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            status = installer.main(argv, _atomic_rename=self._atomic_rename)
        self.assertEqual(status, 1)
        self.assertIn("must be exactly /Applications/MacScope.app", stderr.getvalue())
        self.assertFalse(self.artifacts.exists())
        self.assertFalse(self.installed.exists())

    def test_public_cli_cannot_bypass_attested_closeout_without_phase(self) -> None:
        argv = [
            "--candidate-identity",
            str(self.candidate),
            "--source-app",
            str(self.source),
            "--installed-app",
            str(self.installed),
            "--artifact-root",
            str(self.artifacts),
            "--qualification-run-id",
            QUALIFICATION_RUN_ID,
            "--qualification-run-nonce",
            QUALIFICATION_RUN_NONCE,
            "--predecessor-observations-sha256",
            PREDECESSOR_OBSERVATIONS_SHA256,
        ]
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            status = installer.main(
                argv,
                _allow_test_destination=True,
                _atomic_rename=self._atomic_rename,
            )

        self.assertEqual(status, 1)
        self.assertIn("requires an explicit begin, commit, or rollback phase", stderr.getvalue())
        self.assertFalse(self.artifacts.exists())
        self.assertFalse(self.installed.exists())

    def test_refuses_to_overwrite_existing_artifact_root(self) -> None:
        self.artifacts.mkdir()
        sentinel = self.artifacts / "sentinel"
        sentinel.write_text("preserve", encoding="utf-8")

        status, _, stderr = self._run()

        self.assertEqual(status, 1)
        self.assertIn("refusing to overwrite the artifact root", stderr)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve")
        self.assertFalse(self.installed.exists())
        self.assertEqual(self.atomic_calls, [])


if __name__ == "__main__":
    unittest.main()
