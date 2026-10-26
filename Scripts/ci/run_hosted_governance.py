#!/usr/bin/env python3
"""Run the host-independent half of the governance suite.

The separate native CI workflow targets a provisioned self-hosted Apple-Silicon
Xcode 27 runner. This hosted lane does not build, sign, or run XCTest.

It covers portable repository contracts including manifest closure,
source-identity pinning, opcode-vocabulary parity and hermetic acceptance fixtures.

Tests that shell out to macOS-only tooling are listed explicitly below. The list
is a denylist rather than an allowlist on purpose: a newly added test is included
by default, so a contributor who adds a macOS-dependent test sees this lane fail
and must classify it deliberately instead of silently losing coverage.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import stat
import sys
import time
import unittest
from collections.abc import Iterable, Mapping
from pathlib import Path
from typing import NamedTuple

ROOT = Path(__file__).resolve().parents[2]
TESTS = ROOT / "Scripts/tests"
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from Scripts.reconstruction.write_execution_report import (  # noqa: E402
    ExecutionReportError,
    document as execution_report_document,
    qualification_run_authority,
    write_create_only,
)
from Scripts.reconstruction_gate_f.canonical_json import (  # noqa: E402
    CanonicalJSONError,
    canonical_sha256,
    decode_canonical_bytes,
    load_canonical_json,
)
from Scripts.reconstruction_gate_f.schema import (  # noqa: E402
    CandidateIdentity,
    candidate_identity_sha256,
    parse_candidate_identity,
)
from Scripts.source_export_provenance import (  # noqa: E402
    FILES_NAME as SOURCE_FILES_NAME,
    PROVENANCE_NAME as SOURCE_PROVENANCE_NAME,
    SourceExportError,
    load_verified_export,
)


COMMAND_ID = "source.hosted-governance"
REPORT_KIND = "hosted-governance-test-results-v2"
TEST_RESULT_SCHEMA_VERSION = 2
MAX_CANDIDATE_IDENTITY_BYTES = 4 * 1024 * 1024
MAX_SOURCE_RECORD_BYTES = 32 * 1024 * 1024
TEST_STATUSES = frozenset(
    {
        "passed",
        "failed",
        "error",
        "skipped",
        "expected-failure",
        "unexpected-success",
    }
)
ADVERSE_STATUSES = TEST_STATUSES - {"passed"}
STATUS_PRIORITY = {
    "passed": 0,
    "skipped": 1,
    "expected-failure": 2,
    "unexpected-success": 3,
    "failed": 4,
    "error": 5,
}

# Each exclusion records the concrete unmocked host boundary found in the audit.
# A mocked mention of a macOS tool is not sufficient reason for exclusion.
MACOS_ONLY_REASONS = {
    "test_install_local_private_build.py": "executes the exact Applications destination admission in the native installation entrypoint",
    "test_xcodegen_materialization.py": "executes the governed Apple Silicon Mach-O XcodeGen tool during verification",
    "test_debugger_candidate_drivers.py": "compiles and launches a Darwin fixture with xcrun clang",
    "test_debugger_darwin_process_backend.py": "contains a Darwin arm64 self-process libproc smoke test",
    "test_debugger_fixture_runtime.py": "compiles and launches a Mach-O debugger fixture with xcrun clang",
    "test_ghostty_build_contract.py": "executes the macOS Ghostty build contract and platform tool shims",
    "test_local_signing_policy.py": "invokes zsh, BSD stat flags, and the real Apple-Silicon host toolchain guard",
    "test_local_private_build_qualification.py": "executes the macOS qualification shell harness",
    "test_native_decompiler_xpc_bridge_runner.py": "executes the native bridge shell runner contract",
    "test_native_decompiler_xpc_target_integration.py": "executes macOS Xcode and Ruby-backed target integration helpers",
    "test_release_build_provenance.py": "exercises macOS bundle and Xcode-generated-project provenance fixtures",
    "test_zig_macos_sdk_overlay.py": "executes the macOS SDK overlay helper and xcrun shim",
    "test_sleigh_aarch64_feature_vectors.py": "executes the vendored macOS arm64 sleigh-lift binary",
    "test_sleigh_aarch64_patch_contract.py": "executes the vendored macOS arm64 SLEIGH compiler through compile_sleigh_aarch64_specs.sh",
}
MACOS_ONLY = frozenset(MACOS_ONLY_REASONS)


class HostedGovernanceError(ValueError):
    """The runner could not produce complete, closed governance evidence."""


class HostedGovernanceDiscovery(NamedTuple):
    discovered_modules: tuple[str, ...]
    macos_only_modules: tuple[tuple[str, str], ...]
    selected_modules: tuple[str, ...]


class CandidateBinding(NamedTuple):
    candidate: CandidateIdentity
    digest: str


class HostedGovernanceSourceAuthority(NamedTuple):
    canonical_source_root: str
    git_head_commit: str
    git_head_tree: str
    source_file_count: int
    source_files_sha256: str
    source_provenance_sha256: str
    test_module_inventory_sha256: str

    def document(self) -> dict[str, object]:
        return {
            "canonical_source_root": self.canonical_source_root,
            "git_head_commit": self.git_head_commit,
            "git_head_tree": self.git_head_tree,
            "source_file_count": self.source_file_count,
            "source_files_sha256": self.source_files_sha256,
            "source_provenance_sha256": self.source_provenance_sha256,
            "test_module_inventory_sha256": self.test_module_inventory_sha256,
        }


def classify_discovered_modules(
    discovered_modules: Iterable[str],
    macos_only_reasons: Mapping[str, str],
) -> HostedGovernanceDiscovery:
    """Return the deterministic module closure without importing or running tests."""

    discovered = tuple(sorted(set(discovered_modules)))
    missing = sorted(set(macos_only_reasons) - set(discovered))
    if missing:
        raise HostedGovernanceError(
            f"denylist names tests that no longer exist: {missing}"
        )
    macos_only = tuple(
        (module, macos_only_reasons[module]) for module in sorted(macos_only_reasons)
    )
    selected = tuple(module for module in discovered if module not in macos_only_reasons)
    if not selected:
        raise HostedGovernanceError("hosted-governance selected-module closure is empty")
    return HostedGovernanceDiscovery(discovered, macos_only, selected)


def discover_test_modules(
    tests_directory: Path = TESTS,
    macos_only_reasons: Mapping[str, str] = MACOS_ONLY_REASONS,
) -> HostedGovernanceDiscovery:
    """Discover and classify test modules without importing or executing them."""

    return classify_discovered_modules(
        (path.name for path in tests_directory.glob("test_*.py")),
        macos_only_reasons,
    )


def build_test_suite(
    selected_modules: Iterable[str],
    *,
    tests_directory: Path = TESTS,
) -> unittest.TestSuite:
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()
    inserted = str(tests_directory)
    sys.path.insert(0, inserted)
    try:
        for name in selected_modules:
            suite.addTests(loader.loadTestsFromName(name[: -len(".py")]))
    finally:
        if sys.path and sys.path[0] == inserted:
            sys.path.pop(0)
        else:
            sys.path.remove(inserted)
    return suite


def _leaf_tests(suite: unittest.TestSuite) -> Iterable[unittest.TestCase]:
    for test in suite:
        if isinstance(test, unittest.TestSuite):
            yield from _leaf_tests(test)
        else:
            yield test


def expected_test_ids(suite: unittest.TestSuite) -> tuple[str, ...]:
    identifiers = [test.id() for test in _leaf_tests(suite)]
    if not identifiers:
        raise HostedGovernanceError("hosted-governance unittest leaf closure is empty")
    if len(identifiers) != len(set(identifiers)):
        duplicates = sorted(
            identifier for identifier in set(identifiers) if identifiers.count(identifier) > 1
        )
        raise HostedGovernanceError(f"unittest discovery contains duplicate leaf IDs: {duplicates}")
    return tuple(sorted(identifiers))


class RecordingTextTestResult(unittest.TextTestResult):
    """Text result that also closes every discovered unittest leaf to one status."""

    def __init__(self, *args: object, **kwargs: object) -> None:
        super().__init__(*args, **kwargs)
        self.status_by_test_id: dict[str, str] = {}

    def _record(self, test: unittest.TestCase, status: str) -> None:
        if status not in TEST_STATUSES:
            raise HostedGovernanceError(f"unknown hosted-governance test status: {status}")
        test_id = test.id()
        previous = self.status_by_test_id.get(test_id)
        if previous is None or STATUS_PRIORITY[status] > STATUS_PRIORITY[previous]:
            self.status_by_test_id[test_id] = status

    def addSuccess(self, test: unittest.TestCase) -> None:  # noqa: N802
        super().addSuccess(test)
        self._record(test, "passed")

    def addFailure(self, test: unittest.TestCase, err: tuple[type[BaseException], BaseException, object]) -> None:  # noqa: N802
        super().addFailure(test, err)
        self._record(test, "failed")

    def addError(self, test: unittest.TestCase, err: tuple[type[BaseException], BaseException, object]) -> None:  # noqa: N802
        super().addError(test, err)
        self._record(test, "error")

    def addSkip(self, test: unittest.TestCase, reason: str) -> None:  # noqa: N802
        super().addSkip(test, reason)
        self._record(test, "skipped")

    def addExpectedFailure(self, test: unittest.TestCase, err: tuple[type[BaseException], BaseException, object]) -> None:  # noqa: N802
        super().addExpectedFailure(test, err)
        self._record(test, "expected-failure")

    def addUnexpectedSuccess(self, test: unittest.TestCase) -> None:  # noqa: N802
        super().addUnexpectedSuccess(test)
        self._record(test, "unexpected-success")

    def addSubTest(  # noqa: N802
        self,
        test: unittest.TestCase,
        subtest: unittest.TestCase,
        err: tuple[type[BaseException], BaseException, object] | None,
    ) -> None:
        super().addSubTest(test, subtest, err)
        if err is None:
            return
        exception_type = err[0]
        status = "failed" if issubclass(exception_type, test.failureException) else "error"
        self._record(test, status)


def _parse_arguments(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--candidate-identity",
        type=Path,
        help="canonical Gate F candidate identity JSON",
    )
    parser.add_argument(
        "--source-root",
        type=Path,
        help="canonical verified sealed source export that contains this runner",
    )
    parser.add_argument(
        "--test-results-output",
        type=Path,
        help="absent absolute path for create-only canonical unittest results",
    )
    parser.add_argument(
        "--execution-report-output",
        type=Path,
        help="absent absolute path for the closed execution-report schema",
    )
    parser.add_argument(
        "--qualification-run-id",
        help="coordinator-issued stable ID for this qualification run",
    )
    parser.add_argument(
        "--qualification-run-nonce",
        help="coordinator-issued 64-hex nonce for this qualification run",
    )
    parser.add_argument(
        "--predecessor-observations-sha256",
        help="coordinator-observed pre-launch predecessor receipt-set digest",
    )
    arguments = parser.parse_args(argv)
    structured = (
        arguments.candidate_identity,
        arguments.source_root,
        arguments.test_results_output,
        arguments.execution_report_output,
        arguments.qualification_run_id,
        arguments.qualification_run_nonce,
        arguments.predecessor_observations_sha256,
    )
    if any(item is not None for item in structured) and not all(
        item is not None for item in structured
    ):
        parser.error(
            "--candidate-identity, --source-root, --test-results-output, and "
            "--execution-report-output, --qualification-run-id, "
            "--qualification-run-nonce, and --predecessor-observations-sha256 "
            "must be supplied together"
        )
    return arguments


def _stable_ordinary_file_bytes(
    path: Path,
    *,
    label: str,
    maximum_bytes: int,
) -> bytes:
    if not path.is_absolute():
        raise HostedGovernanceError(f"{label} must be an absolute path")
    try:
        canonical = path.resolve(strict=True)
        before = path.lstat()
    except OSError as error:
        raise HostedGovernanceError(f"{label} is unavailable: {error}") from error
    if (
        canonical != path
        or not stat.S_ISREG(before.st_mode)
        or stat.S_ISLNK(before.st_mode)
        or before.st_nlink != 1
    ):
        raise HostedGovernanceError(
            f"{label} must be a canonical non-symlink ordinary single-link file"
        )
    if before.st_size <= 0 or before.st_size > maximum_bytes:
        raise HostedGovernanceError(f"{label} has an invalid size")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise HostedGovernanceError(f"{label} cannot be opened safely: {error}") from error
    payload = bytearray()
    stable_fields = (
        "st_dev",
        "st_ino",
        "st_mode",
        "st_nlink",
        "st_size",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    try:
        opened = os.fstat(descriptor)
        if any(getattr(before, field) != getattr(opened, field) for field in stable_fields):
            raise HostedGovernanceError(f"{label} changed before its canonical read")
        while True:
            block = os.read(descriptor, min(1024 * 1024, maximum_bytes + 1 - len(payload)))
            if not block:
                break
            payload.extend(block)
            if len(payload) > maximum_bytes:
                raise HostedGovernanceError(f"{label} exceeds its size bound")
        after_descriptor = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    try:
        after_path = path.lstat()
    except OSError as error:
        raise HostedGovernanceError(f"{label} changed during its canonical read: {error}") from error
    if len(payload) != before.st_size or any(
        getattr(before, field) != getattr(after_descriptor, field)
        or getattr(before, field) != getattr(after_path, field)
        for field in stable_fields
    ):
        raise HostedGovernanceError(f"{label} changed during its canonical read")
    return bytes(payload)


def _candidate_binding(path: Path) -> CandidateBinding:
    payload = _stable_ordinary_file_bytes(
        path,
        label="candidate identity",
        maximum_bytes=MAX_CANDIDATE_IDENTITY_BYTES,
    )
    value = decode_canonical_bytes(payload)
    candidate, issues = parse_candidate_identity(value)
    if candidate is None or issues:
        detail = "; ".join(
            f"{issue.code} at {issue.path}: {issue.message}" for issue in issues
        )
        raise HostedGovernanceError(f"candidate identity is invalid: {detail}")
    return CandidateBinding(candidate, candidate_identity_sha256(candidate))


def _validated_source_authority(
    source_root: Path,
    candidate: CandidateIdentity,
) -> tuple[HostedGovernanceSourceAuthority, HostedGovernanceDiscovery]:
    if not source_root.is_absolute():
        raise HostedGovernanceError("source root must be an absolute path")
    try:
        canonical = source_root.resolve(strict=True)
        metadata = source_root.lstat()
    except OSError as error:
        raise HostedGovernanceError(f"source root is unavailable: {error}") from error
    if (
        canonical != source_root
        or not stat.S_ISDIR(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
    ):
        raise HostedGovernanceError(
            "source root must be a canonical non-symlink directory"
        )
    expected_runner = source_root / "Scripts/ci/run_hosted_governance.py"
    try:
        executed_runner = expected_runner.resolve(strict=True)
    except OSError as error:
        raise HostedGovernanceError(
            f"source root does not contain the executed runner: {error}"
        ) from error
    if executed_runner != Path(__file__).resolve():
        raise HostedGovernanceError(
            "structured mode must execute the runner contained by --source-root"
        )
    try:
        provenance, records = load_verified_export(source_root, require_closed_tree=True)
    except (OSError, SourceExportError) as error:
        raise HostedGovernanceError(f"source root is not a verified sealed export: {error}") from error

    source_files_bytes = _stable_ordinary_file_bytes(
        source_root / SOURCE_FILES_NAME,
        label="source file manifest",
        maximum_bytes=MAX_SOURCE_RECORD_BYTES,
    )
    source_provenance_bytes = _stable_ordinary_file_bytes(
        source_root / SOURCE_PROVENANCE_NAME,
        label="source provenance",
        maximum_bytes=MAX_SOURCE_RECORD_BYTES,
    )
    # Decode both stable reads independently of the exporter verifier.  This closes
    # canonical-byte authority and prevents a pathname-only/self-asserted binding.
    source_files_value = decode_canonical_bytes(source_files_bytes)
    source_provenance_value = decode_canonical_bytes(source_provenance_bytes)
    if not isinstance(source_files_value, dict) or not isinstance(source_provenance_value, dict):
        raise HostedGovernanceError("sealed source records must be canonical JSON objects")
    source_files_sha256 = hashlib.sha256(source_files_bytes).hexdigest()
    if source_provenance_value.get("source_files_sha256") != source_files_sha256:
        raise HostedGovernanceError("source provenance does not bind the verified file manifest")
    if (
        provenance.get("git_head_commit") != candidate.source.commit
        or provenance.get("git_head_tree") != candidate.source.tree
    ):
        raise HostedGovernanceError(
            "source export Git commit/tree does not match the candidate identity"
        )

    test_prefix = "Scripts/tests/"
    discovered_names = tuple(
        sorted(
            relative[len(test_prefix) :]
            for relative in records
            if relative.startswith(test_prefix)
            and "/" not in relative[len(test_prefix) :]
            and relative[len(test_prefix) :].startswith("test_")
            and relative.endswith(".py")
        )
    )
    discovery = classify_discovered_modules(discovered_names, MACOS_ONLY_REASONS)
    if tuple(sorted(discovered_names)) != discovery.discovered_modules:
        raise HostedGovernanceError("sealed source test-module inventory is not exact")
    authority = HostedGovernanceSourceAuthority(
        canonical_source_root=str(source_root),
        git_head_commit=candidate.source.commit,
        git_head_tree=candidate.source.tree,
        source_file_count=len(records),
        source_files_sha256=source_files_sha256,
        source_provenance_sha256=hashlib.sha256(source_provenance_bytes).hexdigest(),
        test_module_inventory_sha256=canonical_sha256(
            list(discovery.discovered_modules)
        ),
    )
    return authority, discovery


def _validate_output_path(path: Path, *, label: str) -> None:
    if not path.is_absolute() or path.exists() or path.is_symlink():
        raise HostedGovernanceError(f"{label} must be an absent absolute path")
    try:
        parent = path.parent.resolve(strict=True)
        metadata = parent.lstat()
    except OSError as error:
        raise HostedGovernanceError(f"{label} parent is unavailable: {error}") from error
    if parent != path.parent or not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise HostedGovernanceError(
            f"{label} parent must be a canonical non-symlink directory"
        )


def test_results_document(
    *,
    discovery: HostedGovernanceDiscovery,
    candidate_digest: str,
    source_authority: HostedGovernanceSourceAuthority,
    expected_ids: tuple[str, ...],
    result: RecordingTextTestResult,
) -> dict[str, object]:
    if expected_ids != tuple(sorted(set(expected_ids))):
        raise HostedGovernanceError("expected unittest leaf IDs must be unique and sorted")
    observed_ids = set(result.status_by_test_id)
    expected_id_set = set(expected_ids)
    if observed_ids != expected_id_set:
        raise HostedGovernanceError(
            "unittest execution did not close the exact discovered leaf set: "
            f"missing={sorted(expected_id_set - observed_ids)}, "
            f"unexpected={sorted(observed_ids - expected_id_set)}"
        )
    rows = [
        {"status": result.status_by_test_id[test_id], "test_id": test_id}
        for test_id in expected_ids
    ]
    counts = {
        status: sum(row["status"] == status for row in rows) for status in TEST_STATUSES
    }
    favorable = len(rows) == len(expected_ids) and all(
        counts[status] == 0 for status in ADVERSE_STATUSES
    )
    exit_code = 0 if favorable else 1
    return {
        "schema_version": TEST_RESULT_SCHEMA_VERSION,
        "report_kind": REPORT_KIND,
        "command_id": COMMAND_ID,
        "candidate_identity_sha256": candidate_digest,
        "source_authority": source_authority.document(),
        "discovered_modules": list(discovery.discovered_modules),
        "macos_only_modules": [
            {"module": module, "reason": reason}
            for module, reason in discovery.macos_only_modules
        ],
        "selected_modules": list(discovery.selected_modules),
        "expected_test_ids": list(expected_ids),
        "expected_test_ids_sha256": canonical_sha256(list(expected_ids)),
        "test_results": rows,
        "expected_test_count": len(expected_ids),
        "executed_test_count": len(rows),
        "passed_test_count": counts["passed"],
        "failed_test_count": counts["failed"],
        "error_test_count": counts["error"],
        "skipped_test_count": counts["skipped"],
        "expected_failure_count": counts["expected-failure"],
        "unexpected_success_count": counts["unexpected-success"],
        "result": "passed" if favorable else "failed",
        "exit_code": exit_code,
    }


def main(argv: list[str] | None = None) -> int:
    arguments = _parse_arguments(argv)
    structured = arguments.candidate_identity is not None
    candidate_digest = None
    source_authority = None
    source_root = ROOT
    try:
        if structured:
            assert arguments.candidate_identity is not None
            assert arguments.source_root is not None
            assert arguments.test_results_output is not None
            assert arguments.execution_report_output is not None
            candidate_binding = _candidate_binding(arguments.candidate_identity)
            candidate_digest = candidate_binding.digest
            source_root = arguments.source_root
            source_authority, discovery = _validated_source_authority(
                source_root,
                candidate_binding.candidate,
            )
            _validate_output_path(arguments.test_results_output, label="test-results output")
            _validate_output_path(
                arguments.execution_report_output,
                label="execution-report output",
            )
            if arguments.test_results_output == arguments.execution_report_output:
                raise HostedGovernanceError("structured outputs must be distinct paths")
        else:
            discovery = discover_test_modules()
    except (CanonicalJSONError, HostedGovernanceError, OSError) as error:
        if structured:
            print(f"ERROR: hosted governance setup failed: {error}", file=sys.stderr)
        else:
            # Preserve the original no-argument denylist failure contract.
            print(f"ERROR: {error}", file=sys.stderr)
        return 2

    print(
        "hosted governance lane: "
        f"{len(discovery.selected_modules)} of {len(discovery.discovered_modules)} test modules"
    )
    previous_working_directory = Path.cwd()
    try:
        if structured:
            os.chdir(source_root)
        try:
            suite = build_test_suite(
                discovery.selected_modules,
                tests_directory=source_root / "Scripts/tests",
            )
            expected_ids = expected_test_ids(suite)
        except HostedGovernanceError as error:
            print(f"ERROR: hosted governance discovery failed: {error}", file=sys.stderr)
            return 2
        started_at_unix_ms = time.time_ns() // 1_000_000
        # Emit each test name before execution so a timeout identifies its active case.
        runner = unittest.TextTestRunner(verbosity=2, resultclass=RecordingTextTestResult)
        result = runner.run(suite)
        ended_at_unix_ms = time.time_ns() // 1_000_000
    finally:
        if structured:
            os.chdir(previous_working_directory)

    if not structured:
        return 0 if result.wasSuccessful() else 1

    assert candidate_digest is not None
    assert source_authority is not None
    assert isinstance(result, RecordingTextTestResult)
    assert arguments.test_results_output is not None
    assert arguments.execution_report_output is not None
    try:
        post_execution_authority, post_execution_discovery = _validated_source_authority(
            source_root,
            candidate_binding.candidate,
        )
        if (
            post_execution_authority != source_authority
            or post_execution_discovery != discovery
        ):
            raise HostedGovernanceError(
                "sealed source authority or test inventory changed during execution"
            )
        test_results = test_results_document(
            discovery=discovery,
            candidate_digest=candidate_digest,
            source_authority=source_authority,
            expected_ids=expected_ids,
            result=result,
        )
        execution_report = execution_report_document(
            argparse.Namespace(
                started_at_unix_ms=started_at_unix_ms,
                ended_at_unix_ms=ended_at_unix_ms,
                result=test_results["result"],
                exit_code=test_results["exit_code"],
            ),
            qualification_run=qualification_run_authority(arguments),
            predecessor_observations_sha256=(
                arguments.predecessor_observations_sha256
            ),
        )
        write_create_only(arguments.test_results_output, test_results)
        write_create_only(arguments.execution_report_output, execution_report)
    except (ExecutionReportError, HostedGovernanceError, OSError) as error:
        print(f"ERROR: hosted governance evidence emission failed: {error}", file=sys.stderr)
        return 2
    print(f"MACSCOPE_TEST_RESULTS={arguments.test_results_output}")
    print(f"MACSCOPE_EXECUTION_REPORT={arguments.execution_report_output}")
    return int(test_results["exit_code"])


if __name__ == "__main__":
    raise SystemExit(main())
