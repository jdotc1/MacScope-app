#!/usr/bin/env python3
"""Hermetic transaction tests for local private MacScope installation."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/install_local_private_build.sh"


class InstallLocalPrivateBuildTests(unittest.TestCase):
    def test_governed_interpreter_is_python_3_9(self) -> None:
        result = subprocess.run(
            ["/usr/bin/python3", "-B", "-c",
             "import sys; print('%s.%s' % sys.version_info[:2])"],
            text=True, capture_output=True, check=False, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "3.9\n")

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / "build" / "MacScope.app"
        (self.source / "Contents").mkdir(parents=True)
        (self.source / "Contents/payload").write_text("new", encoding="utf-8")
        self.destination = self.root / "Applications/MacScope.app"
        self.destination.parent.mkdir()
        self.scripts = self.root / "Scripts"
        (self.scripts / "qualification").mkdir(parents=True)
        self.installer = self.scripts / "install_local_private_build.sh"
        shutil.copy2(SCRIPT, self.installer)
        self.preflight = self.scripts / "qualification/install_bundle_receipt.py"
        self.preflight.write_text(
            "#!/usr/bin/env python3\n"
            "import pathlib, sys\n"
            "args = sys.argv[1:]\n"
            "pathlib.Path(__import__('os').environ['PREFLIGHT_LOG']).write_text(' '.join(args))\n"
            "if args[0] == 'compare':\n"
            "  source = pathlib.Path(args[args.index('--source') + 1])\n"
            "  installed = pathlib.Path(args[args.index('--destination') + 1])\n"
            "  if __import__('os').environ.get('FORCE_COMPARISON_FAILURE') == '1' or (source / 'Contents/payload').read_text() != (installed / 'Contents/payload').read_text(): raise SystemExit(1)\n",
            encoding="utf-8",
        )
        self.preflight.chmod(0o755)
        self.ditto = self.root / "ditto"
        self.ditto.write_text("#!/bin/sh\ncp -R \"$4\" \"$5\"\n", encoding="utf-8")
        self.ditto.chmod(0o755)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_installer(self, *, force_comparison_failure: bool = False) -> subprocess.CompletedProcess[str]:
        log = self.root / "preflight.log"
        env = {
            **os.environ,
            "MACSCOPE_INSTALL_DESTINATION": str(self.destination),
            "MACSCOPE_INSTALL_DITTO": str(self.ditto),
            "PREFLIGHT_LOG": str(log),
            "FORCE_COMPARISON_FAILURE": "1" if force_comparison_failure else "0",
        }
        return subprocess.run(
            [str(self.installer), "--app-bundle", str(self.source)],
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )

    def test_install_preserves_prior_app_and_compares_after_move(self) -> None:
        (self.destination / "Contents").mkdir(parents=True)
        (self.destination / "Contents/payload").write_text("old", encoding="utf-8")
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.destination / "Contents/payload").read_text(), "new")
        backups = list(self.destination.parent.glob(".MacScope.previous.*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "Contents/payload").read_text(), "old")
        self.assertIn("--source", (self.root / "preflight.log").read_text())

    def test_comparison_failure_restores_prior_and_quarantines_new(self) -> None:
        (self.destination / "Contents").mkdir(parents=True)
        (self.destination / "Contents/payload").write_text("old", encoding="utf-8")
        result = self.run_installer(force_comparison_failure=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.destination / "Contents/payload").read_text(), "old")
        self.assertEqual(len(list(self.destination.parent.glob(".MacScope.failed.*"))), 1)


class InstalledAcceptanceEntrypointTests(unittest.TestCase):
    gate_ids = (
        "cli",
        "forced-legacy-grid",
        "full-surface",
        "gui",
        "mcp",
        "native-xpc",
        "shellbroker-launchagent",
        "signing",
    )

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.fake_repository = self.root / "fake-repository"
        self.scripts = self.fake_repository / "Scripts"
        self.reconstruction = self.scripts / "reconstruction"
        self.reconstruction.mkdir(parents=True)
        self.wrapper = self.scripts / "install_local_private_build.sh"
        shutil.copy2(SCRIPT, self.wrapper)
        shutil.copy2(
            ROOT / "Scripts/reconstruction/integration_remote_authority.py",
            self.reconstruction / "integration_remote_authority.py",
        )
        self.wrapper.chmod(0o755)

        # A shell metacharacter in the governed path proves argv is never eval'd.
        self.candidate_root = self.root / "candidate;touch PWNED"
        self.candidate_root.mkdir()
        self.candidate = self.candidate_root / "candidate.json"
        self._write_canonical(self.candidate, {})
        self.native_receipt = self.candidate_root / "NativeLivePreparation.receipt.json"
        self._write_canonical(self.native_receipt, {})
        self.source_app = self.candidate_root / "Prepared" / "MacScope.app"
        provenance = self.source_app / "Contents/Resources/MacScopeBuildProvenance.json"
        provenance.parent.mkdir(parents=True)
        self._write_canonical(provenance, {"qualification_eligible": True})
        self.provenance = provenance

        qualification_root = self.root / "qualification"
        qualification_root.mkdir()
        self.qualification_receipt = qualification_root / "QUALIFICATION_INPUTS.json"
        self._write_canonical(self.qualification_receipt, {"schema_version": 4})
        self.work_root = self.root / "acceptance-work"
        self.work_root.mkdir()
        self.helper_log = self.root / "helper.log"
        self.integration_ref = "refs/remotes/next5-local/feature/installed-acceptance"
        self.run_id = "installed-acceptance-run"
        self.run_nonce = "a" * 64
        self.predecessor = "b" * 64
        self._write_helpers()
        self.local_remote = self.root / "MacScope-next5.git"
        subprocess.run(
            ["/usr/bin/git", "init", "-q", "--bare", str(self.local_remote)],
            check=True,
        )
        self._git("init", "-q")
        self._git("config", "user.name", "MacScope Tests")
        self._git("config", "user.email", "macscope-tests@example.invalid")
        self._git("add", "Scripts")
        self._git("commit", "-q", "-m", "fixture")
        self._git("remote", "add", "next5-local", str(self.local_remote))
        self._git(
            "push",
            "-q",
            "next5-local",
            "HEAD:refs/heads/feature/installed-acceptance",
        )
        self._git("fetch", "-q", "next5-local")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _git(self, *arguments: str) -> str:
        return subprocess.run(
            ["/usr/bin/git", "-C", str(self.fake_repository), *arguments],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    @staticmethod
    def _canonical_bytes(value: object) -> bytes:
        return json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")

    @classmethod
    def _write_canonical(cls, path: Path, value: object) -> str:
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = cls._canonical_bytes(value)
        path.write_bytes(payload)
        path.chmod(0o600)
        return hashlib.sha256(payload).hexdigest()

    def _write_helpers(self) -> None:
        compiler = self.reconstruction / "compile_installed_acceptance_gate_plan.py"
        compiler.write_text(
            "#!/usr/bin/env python3\nraise SystemExit('compiler must be driver-owned')\n",
            encoding="utf-8",
        )
        compiler.chmod(0o755)

        driver = self.reconstruction / "run_installed_acceptance_transaction.py"
        driver.write_text(
            textwrap.dedent(
                r'''#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
log = Path(os.environ["HELPER_LOG"])
with log.open("a", encoding="utf-8") as stream:
    stream.write(json.dumps({"name": "driver", "argv": args}, sort_keys=True) + "\n")

def value(flag):
    return args[args.index(flag) + 1]

if os.environ.get("DRIVER_FAILURE") == "1":
    if os.environ.get("DIRTY_DRIVER_STDOUT") == "1":
        print("forbidden failure stdout")
    print("ERROR: mocked gate failure; rollback=rolled-back", file=sys.stderr)
    raise SystemExit(int(os.environ.get("DRIVER_STATUS", "41")))

def canonical_bytes(document):
    return json.dumps(document, ensure_ascii=False, allow_nan=False, sort_keys=True, separators=(",", ":")).encode("utf-8")

def write(path, document):
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = canonical_bytes(document)
    path.write_bytes(payload)
    path.chmod(0o600)
    return hashlib.sha256(payload).hexdigest()

candidate_root = Path(value("--candidate-artifact-root"))
work_root = Path(value("--work-root"))
result_output = Path(value("--result-output"))
candidate = candidate_root / "candidate.json"
candidate_file_sha = hashlib.sha256(candidate.read_bytes()).hexdigest()
source_app = candidate_root / "Prepared" / "MacScope.app"
provenance = source_app / "Contents/Resources/MacScopeBuildProvenance.json"
if os.environ.get("OUTSIDE_CANDIDATE_PATHS") == "1":
    source_app = candidate_root.parent / "outside-candidate" / "MacScope.app"
    provenance = source_app / "Contents/Resources/MacScopeBuildProvenance.json"
    write(provenance, {"qualification_eligible": True})
provenance_sha = hashlib.sha256(provenance.read_bytes()).hexdigest()
identity_sha = "c" * 64
executable_sha = "d" * 64
source_commit = "1" * 40
source_tree = "2" * 40

gate_plan = work_root / "evidence" / "InstalledAcceptanceGate.plan.json"
gate_plan_sha = write(gate_plan, {"plan_kind": "macscope-installed-acceptance-gate-plan", "schema_version": 1})
gate_ids = ["cli", "forced-legacy-grid", "full-surface", "gui", "mcp", "native-xpc", "shellbroker-launchagent", "signing"]
gate_envelopes = []
for gate_id in gate_ids:
    path = work_root / "envelopes" / (gate_id + ".json")
    digest = write(path, {"gate_id": gate_id, "input_kind": "macscope-installer-acceptance-gate", "schema_version": 1})
    gate_envelopes.append({"gate_id": gate_id, "path": str(path), "sha256": digest})

acceptance = work_root / "installer" / "MacScopeInstaller.acceptance-receipt.json"
acceptance_sha = write(acceptance, {"result": "passed"})
terminal = work_root / "terminal" / "transaction.json"
if os.environ.get("OUTSIDE_TRANSACTION_PATH") == "1":
    terminal = candidate_root / "forbidden-transaction" / "transaction.json"
terminal_sha = write(terminal, {"phase": "pending", "schema_version": 3})
commit = work_root / "terminal" / "commit-authority.json"
commit_sha = write(commit, {"phase": "committed", "schema_version": 1})
historical = work_root / "pending" / "transaction.json"

document = {
    "acceptance_receipt": {"path": str(acceptance), "sha256": acceptance_sha},
    "candidate": {
        "application_executable_sha256": executable_sha,
        "artifact_root": str(candidate_root),
        "identity_file_sha256": candidate_file_sha,
        "identity_path": str(candidate),
        "identity_sha256": identity_sha,
        "provenance_path": str(provenance),
        "provenance_sha256": provenance_sha,
        "source_app_path": str(source_app),
        "source_commit": source_commit,
        "source_tree": source_tree,
    },
    "commit_authority": {"path": str(commit), "sha256": commit_sha},
    "gate_envelopes": gate_envelopes,
    "gate_plan": {"path": str(gate_plan), "sha256": gate_plan_sha},
    "pending_state": {"path_at_begin": str(historical), "sha256": terminal_sha, "terminal_path": str(terminal)},
    "produced_at_unix_ns": 300,
    "qualification_run": {"nonce": value("--qualification-run-nonce"), "run_id": value("--qualification-run-id")},
    "result": "passed",
    "result_kind": "macscope-installed-acceptance-transaction",
    "rolled_back": False,
    "schema_version": 1,
    "terminal_committed_state": {"path": str(terminal), "sha256": terminal_sha},
    "transaction": {
        "application_executable_sha256": executable_sha,
        "began_at_unix_ns": 100,
        "build_provenance_sha256": "e" * 64,
        "candidate_file_sha256": candidate_file_sha,
        "candidate_identity_sha256": identity_sha,
        "destination_identity_sha256": "f" * 64,
        "execution_identity_sha256": "3" * 64,
        "exposed_at_unix_ns": 200,
        "predecessor_digest": "4" * 64,
        "predecessor_observations_sha256": value("--predecessor-observations-sha256"),
        "source_commit": source_commit,
        "source_equality_sha256": "5" * 64,
        "source_tree": source_tree,
        "transaction_id": "6" * 64,
        "transaction_nonce": "7" * 64,
    },
    "transaction_phase": "committed",
}
if os.environ.get("INVALID_RESULT") == "1":
    document["unexpected"] = True
payload = canonical_bytes(document)
if os.environ.get("NONCANONICAL_RESULT") == "1":
    payload += b"\n"
result_output.write_bytes(payload)
result_output.chmod(0o600)
if os.environ.get("NO_DRIVER_TRAILING_LF") == "1":
    sys.stdout.write(str(result_output))
elif os.environ.get("EXTRA_DRIVER_TRAILING_LF") == "1":
    sys.stdout.write(str(result_output) + "\n\n")
else:
    print(result_output)
if os.environ.get("DIRTY_DRIVER_SUCCESS_STDOUT") == "1":
    print("forbidden extra stdout")
'''
            ),
            encoding="utf-8",
        )
        driver.chmod(0o644)

        validator = self.reconstruction / "validate_final_local_candidate.py"
        validator.write_text(
            textwrap.dedent(
                r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
with Path(os.environ["HELPER_LOG"]).open("a", encoding="utf-8") as stream:
    stream.write(json.dumps({"name": "validator", "argv": args}, sort_keys=True) + "\n")
if os.environ.get("VALIDATOR_FAILURE") == "1":
    if os.environ.get("DIRTY_VALIDATOR_STDOUT") == "1":
        print("forbidden validator stdout")
    print("ERROR: mocked final validation failure", file=sys.stderr)
    raise SystemExit(43)
output = Path(args[args.index("--output") + 1])
payload = json.dumps({"receipt_kind": "macscope-final-local-candidate", "schema_version": 1}, sort_keys=True, separators=(",", ":")).encode("utf-8")
output.write_bytes(payload)
output.chmod(0o600)
if os.environ.get("NO_VALIDATOR_TRAILING_LF") == "1":
    sys.stdout.write(str(output))
elif os.environ.get("EXTRA_VALIDATOR_TRAILING_LF") == "1":
    sys.stdout.write(str(output) + "\n\n")
else:
    print(output)
if os.environ.get("DIRTY_VALIDATOR_SUCCESS_STDOUT") == "1":
    print("forbidden extra validator stdout")
'''
            ),
            encoding="utf-8",
        )
        validator.chmod(0o644)

    def acceptance_arguments(self) -> list[str]:
        return [
            "--mode", "installed-acceptance",
            "--integration-ref", self.integration_ref,
            "--qualification-receipt", str(self.qualification_receipt),
            "--qualification-run-id", self.run_id,
            "--qualification-run-nonce", self.run_nonce,
            "--predecessor-observations-sha256", self.predecessor,
            "--candidate-artifact-root", str(self.candidate_root),
            "--work-root", str(self.work_root),
            "--destination", "/Applications/MacScope.app",
            "--signing", "development",
            "--begin-timeout-seconds", "12.5",
            "--compiler-timeout-seconds", "13",
            "--report-timeout-seconds", "14.25",
            "--commit-timeout-seconds", "15",
            "--rollback-timeout-seconds", "16",
        ]

    @staticmethod
    def _replace(arguments: list[str], flag: str, value: str) -> list[str]:
        result = list(arguments)
        result[result.index(flag) + 1] = value
        return result

    def run_acceptance(
        self,
        *,
        arguments: list[str] | None = None,
        environment: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        env = {**os.environ, "HELPER_LOG": str(self.helper_log), **(environment or {})}
        return subprocess.run(
            [str(self.wrapper), *(arguments or self.acceptance_arguments())],
            cwd=self.fake_repository,
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )

    def log_records(self) -> list[dict[str, object]]:
        if not self.helper_log.exists():
            return []
        return [json.loads(line) for line in self.helper_log.read_text().splitlines()]

    def reset_work_root(self) -> None:
        if self.work_root.exists():
            shutil.rmtree(self.work_root)
        self.work_root.mkdir()
        if self.helper_log.exists():
            self.helper_log.unlink()

    def test_success_uses_exact_driver_then_validator_argv_and_pure_stdout(self) -> None:
        result = self.run_acceptance()
        final_output = self.work_root / "FinalLocalCandidate.receipt.json"
        transaction_output = self.work_root / "InstalledAcceptanceTransaction.result.json"
        compiler = self.reconstruction / "compile_installed_acceptance_gate_plan.py"
        driver_expected = [
            "--gate-plan-compiler", str(compiler),
            "--qualification-receipt", str(self.qualification_receipt),
            "--qualification-run-id", self.run_id,
            "--qualification-run-nonce", self.run_nonce,
            "--predecessor-observations-sha256", self.predecessor,
            "--candidate-artifact-root", str(self.candidate_root),
            "--work-root", str(self.work_root),
            "--installed-app", "/Applications/MacScope.app",
            "--begin-timeout-seconds", "12.5",
            "--compiler-timeout-seconds", "13",
            "--report-timeout-seconds", "14.25",
            "--commit-timeout-seconds", "15",
            "--rollback-timeout-seconds", "16",
            "--result-output", str(transaction_output),
        ]
        validator_expected = [
            "--transaction-result", str(transaction_output),
            "--integration-ref", self.integration_ref,
            "--qualification-receipt", str(self.qualification_receipt),
            "--candidate-artifact-root", str(self.candidate_root),
            "--output", str(final_output),
        ]
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"{final_output}\n")
        self.assertEqual(result.stderr, "")
        self.assertEqual(
            self.log_records(),
            [{"name": "driver", "argv": driver_expected}, {"name": "validator", "argv": validator_expected}],
        )
        self.assertTrue(transaction_output.is_file())
        self.assertTrue(final_output.is_file())
        self.assertFalse((self.fake_repository / "PWNED").exists())
        self.assertNotIn("eval ", self.wrapper.read_text(encoding="utf-8"))

    def test_gitfox_local_compatibility_ref_remains_accepted(self) -> None:
        self._git("remote", "add", "gitfox-local", str(self.local_remote))
        commit = self._git("rev-parse", "HEAD")
        self._git(
            "update-ref",
            "refs/remotes/gitfox-local/feature/installed-acceptance",
            commit,
        )
        compatibility_ref = "refs/remotes/gitfox-local/feature/installed-acceptance"
        arguments = self._replace(
            self.acceptance_arguments(),
            "--integration-ref",
            compatibility_ref,
        )
        result = self.run_acceptance(arguments=arguments)
        self.assertEqual(result.returncode, 0, result.stderr)
        validator_record = self.log_records()[-1]
        self.assertEqual(validator_record["name"], "validator")
        validator_argv = validator_record["argv"]
        self.assertEqual(
            validator_argv[validator_argv.index("--integration-ref") + 1],
            compatibility_ref,
        )

    def test_rejects_nonlocal_or_ambiguous_remote_before_driver(self) -> None:
        symlink = self.root / "remote-link"
        symlink.symlink_to(self.local_remote, target_is_directory=True)
        ancestor_link = self.root / "parent-link"
        ancestor_link.symlink_to(self.root, target_is_directory=True)
        rejected = (
            "https://example.invalid/MacScope.git",
            "https://github.com.example.invalid/jdotc1/MacScope-app.git",
            "https://github.com/Jdotc1/MacScope-app.git",
            "https://github.com/jdotc1/macscope-app.git",
            "https://github.com/other/MacScope.git",
            "https://github.com/octocat/other.git",
            "https://token@github.com/jdotc1/MacScope-app.git",
            "https://github.com/jdotc1/MacScope-app.git?x=1",
            "https://github.com/jdotc1/MacScope-app.git#main",
            "https://github.com/jdotc1/MacScope-app",
            "https://github.com/jdotc1/MacScope-app.git/",
            "https://GitHub.com/jdotc1/MacScope-app.git",
            "git@github.com:jdotc1/MacScope-app.git",
            "ssh://example.invalid/MacScope.git",
            f"file://{self.local_remote}",
            "../MacScope.git",
            str(self.local_remote) + "/",
            str(self.root) + "//" + self.local_remote.name,
            str(symlink),
            str(ancestor_link / self.local_remote.name),
        )
        for remote_url in rejected:
            with self.subTest(remote_url=remote_url):
                self.reset_work_root()
                self._git("remote", "set-url", "next5-local", remote_url)
                result = self.run_acceptance()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertEqual(self.log_records(), [])
        self._git("remote", "set-url", "next5-local", str(self.local_remote))

        self.reset_work_root()
        self._git("config", "--add", "remote.next5-local.url", str(self.local_remote))
        result = self.run_acceptance()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.log_records(), [])

    def test_canonical_github_ref_is_forwarded_unchanged(self) -> None:
        self._git("remote", "add", "github", "https://github.com/jdotc1/MacScope-app.git")
        integration_ref = "refs/remotes/github/feature/installed-acceptance"
        self._git("update-ref", integration_ref, self._git("rev-parse", "HEAD"))
        arguments = self._replace(self.acceptance_arguments(), "--integration-ref", integration_ref)
        result = self.run_acceptance(arguments=arguments)
        self.assertEqual(result.returncode, 0, result.stderr)
        record = self.log_records()[-1]
        self.assertEqual(record["name"], "validator")
        self.assertEqual(record["argv"][record["argv"].index("--integration-ref") + 1], integration_ref)

    def test_driver_failure_propagates_rollback_and_hides_failure_stdout(self) -> None:
        result = self.run_acceptance(
            environment={"DRIVER_FAILURE": "1", "DIRTY_DRIVER_STDOUT": "1", "DRIVER_STATUS": "41"}
        )
        self.assertEqual(result.returncode, 41)
        self.assertEqual(result.stdout, "")
        self.assertIn("rollback=rolled-back", result.stderr)
        self.assertIn("forbidden stdout", result.stderr)
        self.assertEqual([record["name"] for record in self.log_records()], ["driver"])
        self.assertFalse((self.work_root / "FinalLocalCandidate.receipt.json").exists())

    def test_dirty_driver_stdout_never_invokes_validator(self) -> None:
        for environment in (
            {"DIRTY_DRIVER_SUCCESS_STDOUT": "1"},
            {"NO_DRIVER_TRAILING_LF": "1"},
            {"EXTRA_DRIVER_TRAILING_LF": "1"},
        ):
            with self.subTest(environment=environment):
                self.reset_work_root()
                result = self.run_acceptance(environment=environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertEqual([record["name"] for record in self.log_records()], ["driver"])

    def test_validator_failure_and_stdout_impurity_propagate_without_false_success(self) -> None:
        result = self.run_acceptance(
            environment={"VALIDATOR_FAILURE": "1", "DIRTY_VALIDATOR_STDOUT": "1"}
        )
        self.assertEqual(result.returncode, 43)
        self.assertEqual(result.stdout, "")
        self.assertIn("mocked final validation failure", result.stderr)
        self.assertEqual([record["name"] for record in self.log_records()], ["driver", "validator"])

        for environment in (
            {"DIRTY_VALIDATOR_SUCCESS_STDOUT": "1"},
            {"NO_VALIDATOR_TRAILING_LF": "1"},
            {"EXTRA_VALIDATOR_TRAILING_LF": "1"},
        ):
            with self.subTest(environment=environment):
                self.reset_work_root()
                result = self.run_acceptance(environment=environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertEqual(
                    [record["name"] for record in self.log_records()],
                    ["driver", "validator"],
                )

    def test_rejects_refs_paths_timeouts_mode_mixing_and_unknown_arguments(self) -> None:
        source_tree_work = self.fake_repository / "output"
        source_tree_work.mkdir()
        cases = {
            "origin-ref": self._replace(self.acceptance_arguments(), "--integration-ref", "refs/remotes/origin/main"),
            "revision-expression": self._replace(self.acceptance_arguments(), "--integration-ref", self.integration_ref + "~1"),
            "relative-work": self._replace(self.acceptance_arguments(), "--work-root", "relative"),
            "source-tree-work": self._replace(self.acceptance_arguments(), "--work-root", str(source_tree_work)),
            "nan-timeout": self._replace(self.acceptance_arguments(), "--begin-timeout-seconds", "nan"),
            "large-timeout": self._replace(self.acceptance_arguments(), "--rollback-timeout-seconds", "86400.01"),
            "wrong-signing": self._replace(self.acceptance_arguments(), "--signing", "adhoc"),
            "mode-mixing": [*self.acceptance_arguments(), "--app-bundle", str(self.source_app)],
            "unknown": [*self.acceptance_arguments(), "--mystery", "value"],
            "duplicate": [*self.acceptance_arguments(), "--integration-ref", self.integration_ref],
        }
        for label, arguments in cases.items():
            with self.subTest(label=label):
                result = self.run_acceptance(arguments=arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
        self.assertEqual(self.log_records(), [])

    def test_rejects_missing_helpers_symlink_work_root_and_hardlinked_receipt(self) -> None:
        for name in (
            "compile_installed_acceptance_gate_plan.py",
            "run_installed_acceptance_transaction.py",
            "validate_final_local_candidate.py",
            "integration_remote_authority.py",
        ):
            with self.subTest(helper=name):
                helper = self.reconstruction / name
                held = helper.with_suffix(helper.suffix + ".held")
                helper.rename(held)
                result = self.run_acceptance()
                held.rename(helper)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

        symlink_target = self.root / "empty-target"
        symlink_target.mkdir()
        symlink_work = self.root / "symlink-work"
        symlink_work.symlink_to(symlink_target, target_is_directory=True)
        result = self.run_acceptance(
            arguments=self._replace(self.acceptance_arguments(), "--work-root", str(symlink_work))
        )
        self.assertNotEqual(result.returncode, 0)

        hardlink = self.qualification_receipt.with_name("receipt-hardlink.json")
        os.link(self.qualification_receipt, hardlink)
        result = self.run_acceptance()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.log_records(), [])


if __name__ == "__main__":
    unittest.main()
