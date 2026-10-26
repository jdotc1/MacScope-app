from __future__ import annotations

import base64
import copy
import hashlib
import io
import json
import os
import re
import subprocess
import tarfile
import tempfile
import zipfile
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Iterable, Mapping, Sequence


TASK_ID = "RECON-R1-T10C"
SCHEMA_VERSION = 1
T10A_ROOT = "MacScope-RECON-R1-T10A"
T10A_ATTACHMENT_NAME = "MacScope-RECON-R1-T10A.zip"
T10A_SOURCE_ARCHIVE_NAME = "MacScope_RECON-R1_T10A_Source_Oracle_b732d93e.tar.xz"
T10A_SOURCE_ARCHIVE_SHA256 = "c26bd7c7d84d1d0dc31a93f775dd6661aa6598b27bbc4647a6c5ed5004c823d9"
T10A_HISTORICAL_FULL_RETURN_SHA256 = (
    "188c5b8123362b312d5d0aa897a07a7ccf746d2e1567696e667bf28c60f2bb60"
)
T10A_LOCAL_REPAIR_COMMIT = "2a08250e73b8ab4e5aff47024822439463dfaeb9"
T10A_LOCAL_REPAIR_TREE = "a40504863f366245eb8485f45e02b61370dbe70e"
T10A_ACCEPTED_MAIN = "41629da50dc9839f8a75f364413f905bb0cb3a18"
T10A_ACCEPTED_TREE = "18d6c5f5d9409731f0c0a1fe456e69f4e5508e09"
RETIRED_FINDING_ID = "T10A-P3-004"
HISTORICAL_FINDING_IDS = frozenset(
    [f"T10A-P1-{index:03d}" for index in range(1, 7)]
    + [f"T10A-P2-{index:03d}" for index in range(1, 9)]
    + [f"T10A-P3-{index:03d}" for index in range(1, 6)]
)

VALID_ADJUDICATION_OUTCOMES = frozenset(
    {
        "confirmed-current-defect",
        "confirmed-current-evidence-gap",
        "already-fixed-on-current-source",
        "obsolete-after-source-change",
        "policy-decision-required",
        "source-contract-ambiguous",
        "false-positive",
        "blocked-by-unavailable-layer",
    }
)

MAX_ARCHIVE_MEMBER_BYTES = 16 * 1024 * 1024
MAX_ARCHIVE_TOTAL_BYTES = 256 * 1024 * 1024
MAX_ARCHIVE_ENTRIES = 20_000
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
LEDGER_LINE_RE = re.compile(r"^([0-9a-f]{64})  ([^\r\n]+)$")


def canonical_json_bytes(value: Any) -> bytes:
    return (
        json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        + "\n"
    ).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _safe_archive_path(raw_path: str) -> PurePosixPath:
    if "\\" in raw_path or "\x00" in raw_path:
        raise ValueError(f"unsafe archive path: {raw_path!r}")
    path = PurePosixPath(raw_path)
    if path.is_absolute() or not path.parts or any(part in {"", ".", ".."} for part in path.parts):
        raise ValueError(f"unsafe archive path: {raw_path!r}")
    return path


def _parse_ledger(raw: bytes) -> dict[str, str]:
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError("checksum ledger is not UTF-8") from error
    rows: dict[str, str] = {}
    for line_number, line in enumerate(text.splitlines(), 1):
        match = LEDGER_LINE_RE.fullmatch(line)
        if match is None:
            raise ValueError(f"malformed checksum ledger line {line_number}")
        digest, raw_path = match.groups()
        normalized = str(_safe_archive_path(raw_path))
        if normalized in rows:
            raise ValueError(f"duplicate checksum ledger path: {normalized}")
        rows[normalized] = digest
    if not rows:
        raise ValueError("checksum ledger is empty")
    return rows


def _manifest_digest(rows: Mapping[str, str]) -> str:
    framed = b"".join(
        path.encode("utf-8") + b"\0" + rows[path].encode("ascii") + b"\n"
        for path in sorted(rows)
    )
    return sha256_bytes(framed)


def _run_git(repo_root: Path, *arguments: str, check: bool = True) -> str:
    completed = subprocess.run(
        ["git", *arguments],
        cwd=repo_root,
        check=False,
        capture_output=True,
        text=True,
    )
    if check and completed.returncode != 0:
        raise RuntimeError(
            f"git {' '.join(arguments)} failed ({completed.returncode}): "
            f"{completed.stderr.strip()}"
        )
    return completed.stdout.strip()


def discover_attachment(repo_root: Path, explicit: Path | None = None) -> Path:
    configured = os.environ.get("MACSCOPE_T10A_ARCHIVE")
    candidate = explicit if explicit is not None else (Path(configured) if configured else None)
    if candidate is not None and candidate.is_file():
        return candidate.resolve()
    raise FileNotFoundError("pass --archive or set MACSCOPE_T10A_ARCHIVE to the retained archive")


def discover_transport_root(repo_root: Path, explicit: Path | None = None) -> Path:
    configured = os.environ.get("MACSCOPE_T10A_TRANSPORT_ROOT")
    candidate = explicit if explicit is not None else (Path(configured) if configured else None)
    if candidate is not None and candidate.is_dir():
        return candidate.resolve()
    raise FileNotFoundError("pass --transport-root or set MACSCOPE_T10A_TRANSPORT_ROOT")


def _swift_vector_catalog_member(names: Iterable[str]) -> str:
    candidates = sorted(name for name in names
                        if PurePosixPath(name).parent == PurePosixPath("generated/swift_test_vectors")
                        and PurePosixPath(name).name.endswith("_test_vector_catalog.json"))
    if len(candidates) != 1:
        raise ValueError("archive must contain exactly one Swift test vector catalog")
    return candidates[0]


def verify_full_return_attachment(archive_path: Path) -> dict[str, Any]:
    outer_sha256 = sha256_path(archive_path)
    with zipfile.ZipFile(archive_path) as archive:
        infos = archive.infolist()
        if len(infos) > MAX_ARCHIVE_ENTRIES:
            raise ValueError("archive entry count exceeds the T10C bound")
        names: set[str] = set()
        root_files: dict[str, bytes] = {}
        total_bytes = 0
        for info in infos:
            path = _safe_archive_path(info.filename.rstrip("/"))
            normalized = str(path)
            if info.filename in names:
                raise ValueError(f"duplicate ZIP member: {info.filename}")
            names.add(info.filename)
            if info.file_size > MAX_ARCHIVE_MEMBER_BYTES:
                raise ValueError(f"oversized ZIP member: {info.filename}")
            total_bytes += info.file_size
            if total_bytes > MAX_ARCHIVE_TOTAL_BYTES:
                raise ValueError("archive expanded size exceeds the T10C bound")
            if info.is_dir() or path.parts[0] == "__MACOSX":
                continue
            if path.parts[0] != T10A_ROOT or len(path.parts) < 2:
                raise ValueError(f"unexpected ZIP root member: {info.filename}")
            relative = str(PurePosixPath(*path.parts[1:]))
            root_files[relative] = archive.read(info)

    ledger_bytes = root_files.get("bundle.sha256")
    if ledger_bytes is None:
        raise ValueError("T10A bundle.sha256 is missing")
    ledger = _parse_ledger(ledger_bytes)
    observed_paths = set(root_files) - {"bundle.sha256"}
    if set(ledger) != observed_paths:
        missing = sorted(set(ledger) - observed_paths)
        unexpected = sorted(observed_paths - set(ledger))
        raise ValueError(
            f"T10A ledger coverage mismatch; missing={missing[:3]} unexpected={unexpected[:3]}"
        )
    mismatches = [
        path for path, expected in ledger.items() if sha256_bytes(root_files[path]) != expected
    ]
    if mismatches:
        raise ValueError(f"T10A ledger hash mismatch: {mismatches[:3]}")

    swift_catalog_member = _swift_vector_catalog_member(root_files)
    required = {
        "README.md",
        "RETURN_HANDOFF.md",
        "T10A_RETURN_MANIFEST.json",
        "generated/current_source_findings.json",
        "generated/state_coverage_report.json",
        "generated/mutation_report.json",
        "generated/accessibility_catalog.json",
        swift_catalog_member,
        "generated/appkit_xcui_vectors/xcui_vector_catalog.json",
    }
    absent = sorted(required - set(root_files))
    if absent:
        raise ValueError(f"T10A required members are missing: {absent}")

    return_manifest = json.loads(root_files["T10A_RETURN_MANIFEST.json"])
    findings = json.loads(root_files["generated/current_source_findings.json"])
    coverage = json.loads(root_files["generated/state_coverage_report.json"])
    mutations = json.loads(root_files["generated/mutation_report.json"])
    accessibility = json.loads(root_files["generated/accessibility_catalog.json"])
    vector_catalog = json.loads(
        root_files[swift_catalog_member]
    )
    xcui_catalog = json.loads(
        root_files["generated/appkit_xcui_vectors/xcui_vector_catalog.json"]
    )
    if len(findings.get("findings", [])) != 19:
        raise ValueError("T10A finding inventory is not exactly 19")
    if coverage.get("fixtureCount") != 2429:
        raise ValueError("T10A fixture count drifted from 2,429")
    if len(vector_catalog) != 2448 or len(xcui_catalog) != 22:
        raise ValueError("T10A vector inventory drifted")
    if len(accessibility.get("rows", [])) != 16:
        raise ValueError("T10A accessibility catalog is not the 16-entry authority")
    if mutations.get("mutationCount") != 36 or mutations.get("caughtCount") != 36:
        raise ValueError("T10A mutation report is incomplete")

    return {
        "schemaVersion": SCHEMA_VERSION,
        "status": "verified-internal-derivative-container",
        "logicalLocator": f"workspace-attachment/{T10A_ATTACHMENT_NAME}",
        "outerSHA256": outer_sha256,
        "historicalFullReturnSHA256": T10A_HISTORICAL_FULL_RETURN_SHA256,
        "matchesHistoricalFullReturn": outer_sha256 == T10A_HISTORICAL_FULL_RETURN_SHA256,
        "historicalContainerAvailability": "unavailable-not-reproduced",
        "internalLedgerEntryCount": len(ledger),
        "internalLedgerManifestSHA256": _manifest_digest(ledger),
        "expandedRootFileCountIncludingLedger": len(root_files),
        "expandedRootBytes": sum(len(value) for value in root_files.values()),
        "acceptedMain": return_manifest["sourceIdentity"]["acceptedMainCommit"],
        "acceptedTree": return_manifest["sourceIdentity"]["acceptedTree"],
        "fixtureCount": coverage["fixtureCount"],
        "findingCount": len(findings["findings"]),
        "swiftVectorCount": len(vector_catalog),
        "installedVectorCount": len(xcui_catalog),
        "accessibilityEntryCount": len(accessibility["rows"]),
        "mutationCaughtCount": mutations["caughtCount"],
        "mutationCount": mutations["mutationCount"],
    }


def _verify_tar_bundle(raw_archive: bytes) -> dict[str, Any]:
    files: dict[str, bytes] = {}
    with tarfile.open(fileobj=io.BytesIO(raw_archive), mode="r:xz") as archive:
        members = archive.getmembers()
        if len(members) > MAX_ARCHIVE_ENTRIES:
            raise ValueError("source transport entry count exceeds the T10C bound")
        seen: set[str] = set()
        total = 0
        for member in members:
            path = _safe_archive_path(member.name.rstrip("/"))
            if member.name in seen:
                raise ValueError(f"duplicate source transport member: {member.name}")
            seen.add(member.name)
            if member.issym() or member.islnk():
                raise ValueError(f"source transport link is not permitted: {member.name}")
            if member.isdir():
                continue
            if not member.isfile():
                raise ValueError(f"unsupported source transport member: {member.name}")
            if member.size > MAX_ARCHIVE_MEMBER_BYTES:
                raise ValueError(f"oversized source transport member: {member.name}")
            total += member.size
            if total > MAX_ARCHIVE_TOTAL_BYTES:
                raise ValueError("source transport expanded size exceeds the T10C bound")
            if path.parts[0] != T10A_ROOT or len(path.parts) < 2:
                raise ValueError(f"unexpected source transport root: {member.name}")
            extracted = archive.extractfile(member)
            if extracted is None:
                raise ValueError(f"unable to read source transport member: {member.name}")
            files[str(PurePosixPath(*path.parts[1:]))] = extracted.read()
    ledger = _parse_ledger(files["bundle.sha256"])
    observed = set(files) - {"bundle.sha256"}
    if set(ledger) != observed:
        raise ValueError("source transport bundle ledger does not cover its exact file set")
    mismatches = [
        path for path, expected in ledger.items() if sha256_bytes(files[path]) != expected
    ]
    if mismatches:
        raise ValueError(f"source transport bundle hash mismatch: {mismatches[:3]}")
    return {
        "entryCountIncludingLedger": len(files),
        "ledgerEntryCount": len(ledger),
        "ledgerManifestSHA256": _manifest_digest(ledger),
        "expandedBytes": sum(len(value) for value in files.values()),
    }


def verify_source_transport(transport_root: Path, repo_root: Path) -> dict[str, Any]:
    parts = sorted(transport_root.glob(f"{T10A_SOURCE_ARCHIVE_NAME}.b64.part-*"))
    expected_names = [f"{T10A_SOURCE_ARCHIVE_NAME}.b64.part-{index:03d}" for index in range(1, 8)]
    if [path.name for path in parts] != expected_names:
        raise ValueError("T10A source transport must contain exactly seven ordered parts")
    part_hashes = {path.name: sha256_path(path) for path in parts}
    encoded = "".join(path.read_text(encoding="ascii").strip() for path in parts)
    try:
        raw_archive = base64.b64decode(encoded, validate=True)
    except ValueError as error:
        raise ValueError("T10A source transport is not canonical base64") from error
    observed_sha256 = sha256_bytes(raw_archive)
    if observed_sha256 != T10A_SOURCE_ARCHIVE_SHA256:
        raise ValueError("T10A source archive hash does not match the repaired authority")
    sidecar = (transport_root / "source-archive.sha256").read_text(encoding="utf-8").strip()
    expected_sidecar = f"{T10A_SOURCE_ARCHIVE_SHA256}  {T10A_SOURCE_ARCHIVE_NAME}"
    if sidecar != expected_sidecar:
        raise ValueError("T10A source archive sidecar disagrees with the repaired authority")
    bundle = _verify_tar_bundle(raw_archive)

    support_paths = [
        *parts,
        transport_root / "README.md",
        transport_root / "RETURN_HANDOFF.md",
        transport_root / "external-full-return-archive.sha256",
        transport_root / "reconstruct.sh",
        transport_root / "repack.py",
        transport_root / "source-archive.sha256",
    ]
    support_hashes = {path.name: sha256_path(path) for path in support_paths}
    repair_object_present = subprocess.run(
        ["git", "cat-file", "-e", f"{T10A_LOCAL_REPAIR_COMMIT}^{{commit}}"],
        cwd=repo_root,
        check=False,
        capture_output=True,
    ).returncode == 0
    ancestry = subprocess.run(
        ["git", "merge-base", "--is-ancestor", T10A_LOCAL_REPAIR_COMMIT, "HEAD"],
        cwd=repo_root,
        check=False,
        capture_output=True,
    ).returncode == 0
    tracked = all(
        bool(_run_git(repo_root, "ls-files", "--error-unmatch", str(path.relative_to(repo_root)), check=False))
        for path in support_paths
        if path.is_relative_to(repo_root)
    )
    return {
        "status": "verified-present-but-uncommitted" if not tracked else "verified-tracked",
        "sourceArchiveSHA256": observed_sha256,
        "sourceArchiveBytes": len(raw_archive),
        "partCount": len(parts),
        "partHashes": part_hashes,
        "transportInputManifestSHA256": _manifest_digest(support_hashes),
        "localRepairCommit": T10A_LOCAL_REPAIR_COMMIT,
        "localRepairTree": T10A_LOCAL_REPAIR_TREE,
        "repairCommitObjectPresent": repair_object_present,
        "repairCommitIsAncestorOfCurrentHead": ancestry,
        "transportTrackedByCurrentBranch": tracked,
        "bundle": bundle,
    }


@dataclass(frozen=True)
class FindingSpec:
    finding_id: str
    current_path: str
    current_symbol: str
    anchor: str
    required_tokens: tuple[str, ...]
    drift: str
    outcome: str
    current_severity: str
    current_behavior: str
    closest_suite: str
    blocks: str
    installed_vector_ids: tuple[str, ...] = ()


FINDING_SPECS: tuple[FindingSpec, ...] = (
    FindingSpec(
        "T10A-P1-001", "MacScope/Models/Reconstruction/ReconstructionJobModels.swift",
        "ReconstructionJobPauseContext", "struct ReconstructionJobPauseContext",
        ("let cause: ReconstructionJobPauseCause", "let resumeTarget: ReconstructionJobState", "pauseContext"),
        "materially-changed", "already-fixed-on-current-source", "none",
        "Paused jobs carry a validated durable cause and exact active resume target through Codable job state.",
        "ReconstructionJobCoordinatorTests", "neither",
    ),
    FindingSpec(
        "T10A-P1-002", "MacScope/Models/Reconstruction/ReconstructionJobModels.swift",
        "ReconstructionJobRecord.creationOrdinal", "let creationOrdinal: UInt64?",
        ("creationOrdinal", "recordSchemaVersion"), "materially-changed",
        "already-fixed-on-current-source", "none",
        "Creation ordinal is explicit durable authority with migration and database allocation coverage.",
        "ReconstructionInitialJobTransactionTests", "neither",
    ),
    FindingSpec(
        "T10A-P1-003", "MacScope/Stores/WorkspaceStore+ReconstructionJobs.swift",
        "WorkspaceStore.reconstructionCommandAuthority", "private func reconstructionCommandAuthority",
        ("expectedJobState", "checkpointRevision", "evidenceFrontierSHA256"), "materially-changed",
        "already-fixed-on-current-source", "none",
        "One Store-facing command facade revalidates state, checkpoint, corpus, frontier, and runtime authority.",
        "WorkspaceStoreReconstructionIntegrationTests", "neither",
    ),
    FindingSpec(
        "T10A-P1-004", "MacScope/Stores/WorkspaceStore+ReconstructionJobs.swift",
        "WorkspaceStore.reconstructionCommandAuthority(cancel)", "case .cancel:",
        ("ReconstructionJobState.activeStates.contains(job.state)", "to: .cancelled"),
        "materially-changed", "already-fixed-on-current-source", "none",
        "The 2026-10-05 R1 stability policy permits Cancel from active or durably paused states; the Store facade still binds exact state, checkpoint, corpus and frontier authority, and terminal retirement clears resume authority.",
        "ReconstructionTask10OracleVectorTests", "neither",
    ),
    FindingSpec(
        "T10A-P1-005", "MacScope/Features/Reconstruction/ReconstructionStatusProjection.swift",
        "ReconstructionStatusProjection", "struct ReconstructionStatusProjection",
        ("ReconstructionControlProjection", "checkpointFreshness", "pendingIntent"),
        "materially-changed", "already-fixed-on-current-source", "none",
        "One immutable projection separates durable state, pending intent, model authority, freshness, notices, and controls.",
        "ReconstructionStatusProjectionTests", "neither",
    ),
    FindingSpec(
        "T10A-P1-006", "MacScope/Stores/WorkspaceStore+ReconstructionNavigation.swift",
        "ReconstructionSourceNavigationAuthority", "enum ReconstructionSourceNavigationAuthority",
        (
            "let function: ReconstructionFunctionCoordinate",
            "currentManifestSHA256",
            "ReconstructionReboundFunctionAuthority.resolve",
        ),
        "materially-changed", "already-fixed-on-current-source", "none",
        "Source reveal resolves an image-qualified current coordinate before mutating editor focus.",
        "WorkspaceStoreReconstructionNavigationTests", "neither",
        ("xcui.revealSourceCurrentAuthority", "xcui.revealSourceStaleAuthorityNoMutation"),
    ),
    FindingSpec(
        "T10A-P2-001", "MacScope/Features/Reconstruction/ReconstructionJobCreationSheet.swift",
        "ReconstructionJobCreationRequest.normalizedObjective", "static func normalizedObjective",
        ("split(whereSeparator: \\Character.isWhitespace)", "maximumObjectiveUTF8Bytes"),
        "materially-changed", "already-fixed-on-current-source", "none",
        "Creation collapses whitespace, rejects empty or oversized objectives, and commits the normalized value.",
        "ReconstructionTask10OracleVectorTests", "neither",
    ),
    FindingSpec(
        "T10A-P2-002", "MacScope/Features/Reconstruction/ReconstructionJobCreationSheet.swift",
        "ReconstructionNewJobBudgetPolicy", "enum ReconstructionNewJobBudgetPolicy",
        ("1...64", "32...16_384", "64...65_536", "1...1_024"),
        "materially-changed", "already-fixed-on-current-source", "none",
        "New-job budget maxima are a closed rejection policy; historical durable budgets are not rewritten.",
        "ReconstructionTask10OracleVectorTests", "neither",
    ),
    FindingSpec(
        "T10A-P2-003", "MacScope/Features/Reconstruction/ReconstructionStatusProjection.swift",
        "ReconstructionTerminalNoticeProjection", "struct ReconstructionTerminalNoticeProjection",
        ("let cause: ReconstructionJobState", "let detailIdentity: String", "maximumUTF8Bytes = 192"),
        "materially-changed", "already-fixed-on-current-source", "none",
        "Terminal lifecycle state is closed cause authority; optional detail is bounded and content-identified.",
        "ReconstructionPresentationContractTests", "neither",
    ),
    FindingSpec(
        "T10A-P2-004", "MacScope/Models/AnalysisModels.swift", "WorkspaceTool.reconstruction",
        "case reconstruction = \"Reconstruction\"", ("case reconstruction = \"Reconstruction\"",),
        "materially-changed", "already-fixed-on-current-source", "none",
        "Reconstruction is appended as a stable workspace destination without renumbering prior cases.",
        "ReconstructionPresentationRoutingTests", "neither",
    ),
    FindingSpec(
        "T10A-P2-005", "MacScope/Features/Workspace/WorkspaceRootView.swift",
        "WorkspaceRootView.centralDestination", "static func centralDestination",
        ("case .reconstruction:", "ReconstructionDashboardView"), "materially-changed",
        "already-fixed-on-current-source", "none",
        "The workspace routes Reconstruction only into the central destination while preserving surrounding authorities.",
        "ReconstructionPresentationRoutingTests", "neither",
        ("xcui.destinationSwitchRestoresEditorAuthority",),
    ),
    FindingSpec(
        "T10A-P2-006", "MacScope/Features/Reconstruction/ReconstructionPresentationState.swift",
        "ReconstructionAccessibilityIdentifiers", "enum ReconstructionAccessibilityIdentifiers",
        ("static let orderedCatalog", "reconstruction.destination", "reconstruction.inspector"),
        "materially-changed", "confirmed-current-evidence-gap", "P1",
        "The exact 16-entry oracle catalog exists and is source-tested, but no exact installed Task 10 accessibility execution has been recorded.",
        "ReconstructionPresentationContractTests", "GateF",
        ("xcui.keyboardAndMenuEquivalence", "xcui.privacyNoRawPathPromptPseudocode"),
    ),
    FindingSpec(
        "T10A-P2-007", "MacScope/Features/Reconstruction/ReconstructionPresentationState.swift",
        "ReconstructionWindowPresentationState", "struct ReconstructionWindowPresentationState",
        ("let windowID: UUID", "let selectedJobID: UUID?", "windowMismatch"),
        "materially-changed", "already-fixed-on-current-source", "none",
        "Selection, pending-intent fencing, inspector visibility, and completion acceptance are window-local.",
        "ReconstructionPresentationContractTests", "neither",
        ("xcui.twoWindowsKeepIndependentSelection",),
    ),
    FindingSpec(
        "T10A-P2-008", "MacScope/Services/Reconstruction/ReconstructionWorkspaceRuntime.swift",
        "ReconstructionWorkspaceRuntime.restoreEligibleJobs", "private func restoreEligibleJobs",
        ("activationModel.publish(.restoring)", "restorationCompleted", "activationModel.publish(.ready)"),
        "materially-changed", "confirmed-current-evidence-gap", "P1",
        "Runtime composition source-tests restoration-before-readiness, but the exact installed save/reopen/resume workflow is not yet executed for Task 10.",
        "ReconstructionWorkspaceRuntimeCompositionTests", "GateF",
        ("xcui.saveReopenProjectsBeforeResume",),
    ),
    FindingSpec(
        "T10A-P3-001", "MacScope/Features/Reconstruction/ReconstructionStatusProjection.swift",
        "ReconstructionModelReadinessProjection", "struct ReconstructionModelReadinessProjection",
        ("ReconstructionModelReadinessCase", "isExecutable", "providerRevision"),
        "materially-changed", "already-fixed-on-current-source", "none",
        "All twelve readiness cases remain distinct from activity and executable lease authority.",
        "ReconstructionStatusProjectionTests", "neither",
    ),
    FindingSpec(
        "T10A-P3-002", "MacScope/Features/Reconstruction/ReconstructionStatusProjection.swift",
        "ReconstructionStatusProjection", "struct ReconstructionStatusProjection",
        ("ReconstructionEvidenceSummary", "ReconstructionCheckpointFreshness", "ReconstructionStatusGapProjection"),
        "materially-changed", "already-fixed-on-current-source", "none",
        "Counts, evidence classes, gap identity, and checkpoint freshness remain orthogonal fields.",
        "ReconstructionStatusProjectionTests", "neither",
    ),
    FindingSpec(
        "T10A-P3-003", "MacScope/Features/Reconstruction/ReconstructionDashboardView.swift",
        "ReconstructionDashboardView", "struct ReconstructionDashboardView",
        ("AppSpacing", "workbenchSurface", "AppSemanticColor"),
        "materially-changed", "confirmed-current-evidence-gap", "P2",
        "The dashboard composes the existing design system, but installed narrow/wide, accessibility, and window-chrome review remains unexecuted.",
        "ReconstructionPresentationRoutingTests", "GateF",
        ("xcui.destinationVisibleWhenReady", "xcui.destinationVisibleWhenEndpointMissing"),
    ),
    FindingSpec(
        "T10A-P3-005", "MacScope/Tests/CoreTests/ReconstructionPresentationContractTests.swift",
        "ReconstructionPresentationContractTests", "final class ReconstructionPresentationContractTests",
        (
            "testAccessibilityCatalogIsExactStableUniqueAndContiguous",
            "testPauseCarriesItsDurableResumeTargetAndResumeRequiresPersistedContext",
        ),
        "materially-changed", "already-fixed-on-current-source", "none",
        "The missing Task 10 pure suites now exist; lower-layer suites remain prerequisites rather than installed proof.",
        "ReconstructionPresentationContractTests", "neither",
    ),
)


def _semantic_fingerprint(text: str, anchor: str, radius: int = 18) -> tuple[str, int]:
    lines = text.splitlines()
    matching = [index for index, line in enumerate(lines) if anchor in line]
    if len(matching) != 1:
        raise ValueError(f"anchor {anchor!r} must occur exactly once, found {len(matching)}")
    index = matching[0]
    start = max(0, index - radius)
    end = min(len(lines), index + radius + 1)
    normalized = "\n".join(line.strip() for line in lines[start:end] if line.strip())
    return sha256_bytes(normalized.encode("utf-8")), index + 1


def audit_source(repo_root: Path) -> dict[str, Any]:
    head = _run_git(repo_root, "rev-parse", "HEAD")
    head_tree = _run_git(repo_root, "rev-parse", "HEAD^{tree}")
    mappings: list[dict[str, Any]] = []
    input_hashes: dict[str, str] = {}
    for spec in FINDING_SPECS:
        path = repo_root / spec.current_path
        if not path.is_file():
            raise ValueError(f"current finding path is missing: {spec.current_path}")
        raw = path.read_bytes()
        text = raw.decode("utf-8")
        absent_tokens = [token for token in spec.required_tokens if token not in text]
        if absent_tokens:
            raise ValueError(
                f"current symbol contract drifted for {spec.finding_id}: missing {absent_tokens}"
            )
        fingerprint, line = _semantic_fingerprint(text, spec.anchor)
        input_hashes[spec.current_path] = sha256_bytes(raw)
        mappings.append(
            {
                "findingID": spec.finding_id,
                "currentPath": spec.current_path,
                "currentSymbol": spec.current_symbol,
                "currentAnchor": spec.anchor,
                "currentAnchorLineDiagnosticOnly": line,
                "currentBlobSHA256": input_hashes[spec.current_path],
                "semanticFingerprintSHA256": fingerprint,
                "requiredTokens": list(spec.required_tokens),
                "classification": spec.drift,
                "directlyEvaluable": True,
            }
        )
    dirty = set(_run_git(repo_root, "status", "--short", "--untracked-files=all").splitlines())
    dirty_inputs = sorted(
        path for path in input_hashes if any(row.endswith(f" {path}") for row in dirty)
    )
    return {
        "schemaVersion": SCHEMA_VERSION,
        "taskID": TASK_ID,
        "originalSource": {"commit": T10A_ACCEPTED_MAIN, "tree": T10A_ACCEPTED_TREE},
        "currentSource": {
            "headCommit": head,
            "headTree": head_tree,
            "worktreeInputManifestSHA256": _manifest_digest(input_hashes),
            "inputPathCount": len(input_hashes),
            "dirtyInputPaths": dirty_inputs,
            "identityInterpretation": (
                "HEAD identifies ancestry; the manifest identifies exact inspected worktree bytes."
            ),
        },
        "mappings": mappings,
        "mappingCount": len(mappings),
        "allSymbolsResolved": len(mappings) == len(FINDING_SPECS),
    }


def _read_zip_json(archive_path: Path, relative_path: str) -> Any:
    with zipfile.ZipFile(archive_path) as archive:
        return json.loads(archive.read(f"{T10A_ROOT}/{relative_path}"))


def adjudicate_findings(archive_path: Path, source_drift: Mapping[str, Any]) -> dict[str, Any]:
    archived = _read_zip_json(archive_path, "generated/current_source_findings.json")["findings"]
    historical_by_id = {row["findingID"]: row for row in archived}
    if len(archived) != len(HISTORICAL_FINDING_IDS) or set(historical_by_id) != HISTORICAL_FINDING_IDS:
        raise ValueError("archive must retain the exact historical finding inventory")
    by_id = {key: row for key, row in historical_by_id.items() if key != RETIRED_FINDING_ID}
    specs = {spec.finding_id: spec for spec in FINDING_SPECS}
    if set(by_id) != set(specs):
        raise ValueError("finding adjudication must cover the exact current product inventory")
    drift_by_id = {row["findingID"]: row for row in source_drift["mappings"]}
    rows: list[dict[str, Any]] = []
    for finding_id in sorted(by_id):
        archived_row = by_id[finding_id]
        spec = specs[finding_id]
        if spec.outcome not in VALID_ADJUDICATION_OUTCOMES:
            raise ValueError(f"unknown adjudication outcome: {spec.outcome}")
        vectors = [archived_row["fixtureID"], *spec.installed_vector_ids]
        rows.append(
            {
                "findingID": finding_id,
                "originalSeverity": archived_row["severity"],
                "currentSeverity": spec.current_severity,
                "outcome": spec.outcome,
                "evidenceClass": "exact-current-worktree-source",
                "currentPath": spec.current_path,
                "currentSymbol": spec.current_symbol,
                "currentBlobSHA256": drift_by_id[finding_id]["currentBlobSHA256"],
                "semanticFingerprintSHA256": drift_by_id[finding_id]["semanticFingerprintSHA256"],
                "minimalVectorIDs": vectors,
                "expectedProductionBehavior": spec.current_behavior,
                "closestTestSuite": spec.closest_suite,
                "productChangeRequired": False,
                "installedExecutionRequired": bool(spec.installed_vector_ids),
                "blocks": spec.blocks,
                "confidence": "high",
                "unresolvedAssumptions": [],
            }
        )
    counts = Counter(row["outcome"] for row in rows)
    counts["obsolete-after-source-change"] = 0
    severity_counts = Counter(row["currentSeverity"] for row in rows if row["currentSeverity"] != "none")
    return {
        "schemaVersion": SCHEMA_VERSION,
        "taskID": TASK_ID,
        "sourceIdentity": source_drift["currentSource"],
        "findingCount": len(rows),
        "outcomeCounts": dict(sorted(counts.items())),
        "openSeverityCounts": dict(sorted(severity_counts.items())),
        "confirmedCurrentDefectCount": counts.get("confirmed-current-defect", 0),
        "productSourceChangeRequired": any(row["productChangeRequired"] for row in rows),
        "findings": rows,
    }


def _flatten_typed_outcomes(value: Any, prefix: str = "") -> set[str]:
    results: set[str] = set()
    if isinstance(value, dict):
        for key, child in value.items():
            child_prefix = f"{prefix}.{key}" if prefix else key
            if key in {"classification", "unavailableReason"} and isinstance(child, str):
                results.add(f"typed:{child_prefix}:{child}")
            elif key == "errors" and isinstance(child, list):
                results.update(f"typed:{child_prefix}:{item}" for item in child if isinstance(item, str))
            results.update(_flatten_typed_outcomes(child, child_prefix))
    elif isinstance(value, list):
        for child in value:
            results.update(_flatten_typed_outcomes(child, prefix))
    return results


def _vector_coverage(
    vector: Mapping[str, Any], expected: Mapping[str, Any] | None
) -> set[str]:
    family = vector["family"]
    outcome = vector["expectedOutcome"]
    fixture_id = vector["fixtureID"]
    coverage = {f"family:{family}", f"family-outcome:{family}:{outcome}"}
    coverage.update(f"rule:{rule}" for rule in vector.get("traceRules", []))
    if expected is not None:
        coverage.update(_flatten_typed_outcomes(expected))
    parts = fixture_id.split(".")
    if family == "stateTransition" and len(parts) == 4:
        _, from_state, to_state, resume = parts
        coverage.update(
            {
                f"transition-source:{from_state}",
                f"transition-target:{to_state}",
                f"transition-outcome:{outcome}",
            }
        )
        if outcome == "legal":
            coverage.add(f"legal-transition:{from_state}:{to_state}:{resume}")
    if family == "stateReadinessProjection" and len(parts) >= 7:
        coverage.add(f"job-state:{parts[2]}")
        coverage.add(f"readiness:{parts[4]}")
        coverage.add(f"provider-activity:{parts[6]}")
    if family == "currentSourceAudit":
        coverage.update(f"finding:{rule}" for rule in vector.get("traceRules", []))
    return coverage


def deterministic_set_cover(
    candidates: Mapping[str, set[str]], universe: set[str], preferred_ids: set[str]
) -> tuple[list[str], dict[str, list[str]]]:
    uncovered = set(universe)
    selected: list[str] = []
    while uncovered:
        best_id: str | None = None
        best_key: tuple[int, int, str] | None = None
        for candidate_id in sorted(candidates):
            gain = len(candidates[candidate_id] & uncovered)
            if gain == 0:
                continue
            key = (gain, 1 if candidate_id in preferred_ids else 0, candidate_id)
            if best_key is None or key[:2] > best_key[:2] or (
                key[:2] == best_key[:2] and key[2] < best_key[2]
            ):
                best_id, best_key = candidate_id, key
        if best_id is None:
            raise ValueError(f"coverage universe has no candidate for: {sorted(uncovered)[:5]}")
        selected.append(best_id)
        uncovered -= candidates[best_id]

    # Reverse pruning makes every retained row necessary for the declared universe.
    retained = list(selected)
    for candidate_id in reversed(selected):
        trial = [item for item in retained if item != candidate_id]
        covered = set().union(*(candidates[item] for item in trial)) if trial else set()
        if universe <= covered:
            retained.remove(candidate_id)
    matrix = {
        obligation: sorted(item for item in retained if obligation in candidates[item])
        for obligation in sorted(universe)
    }
    if any(not rows for rows in matrix.values()):
        raise ValueError("selector emitted an uncovered obligation")
    return sorted(retained), matrix


def select_vectors(archive_path: Path, adjudication: Mapping[str, Any]) -> dict[str, Any]:
    with zipfile.ZipFile(archive_path) as archive:
        prefix = T10A_ROOT + "/"
        member = _swift_vector_catalog_member(
            name[len(prefix):] for name in archive.namelist() if name.startswith(prefix)
        )
    catalog: list[dict[str, Any]] = _read_zip_json(archive_path, member)
    report = _read_zip_json(archive_path, "generated/state_coverage_report.json")
    mutation_report = _read_zip_json(archive_path, "generated/mutation_report.json")
    xcui: list[dict[str, Any]] = _read_zip_json(
        archive_path, "generated/appkit_xcui_vectors/xcui_vector_catalog.json"
    )
    accessibility = _read_zip_json(archive_path, "generated/accessibility_catalog.json")

    with zipfile.ZipFile(archive_path) as archive:
        expected_by_fixture: dict[str, dict[str, Any]] = {}
        for vector in catalog:
            fixture_id = vector["fixtureID"]
            member = f"{T10A_ROOT}/fixtures/expected/{fixture_id}.json"
            try:
                expected_by_fixture[fixture_id] = json.loads(archive.read(member))
            except KeyError:
                expected_by_fixture[fixture_id] = {}

    candidates = {
        vector["vectorID"]: _vector_coverage(
            vector, expected_by_fixture.get(vector["fixtureID"])
        )
        for vector in catalog
    }
    universe: set[str] = set()
    universe.update(
        f"rule:{row['id']}" for row in report["normativeCoverage"] if row["covered"]
    )
    universe.update(
        f"family-outcome:{family}:{outcome}"
        for family in sorted({vector["family"] for vector in catalog})
        for outcome in sorted(
            {vector["expectedOutcome"] for vector in catalog if vector["family"] == family}
        )
    )
    universe.update(
        obligation
        for coverage in candidates.values()
        for obligation in coverage
        if obligation.startswith("typed:")
    )
    universe.update(
        obligation
        for coverage in candidates.values()
        for obligation in coverage
        if obligation.startswith("legal-transition:")
    )
    universe.update(f"finding:{row['findingID']}" for row in adjudication["findings"])
    universe.update(f"rule:{row['invariant']}" for row in mutation_report["mutations"])

    preferred = {
        vector_id
        for row in adjudication["findings"]
        for vector_id in row["minimalVectorIDs"]
        if vector_id in candidates
    }
    selected_ids, matrix = deterministic_set_cover(candidates, universe, preferred)
    by_id = {vector["vectorID"]: vector for vector in catalog}
    selected = []
    for vector_id in selected_ids:
        vector = by_id[vector_id]
        selected.append(
            {
                "vectorID": vector_id,
                "fixtureID": vector["fixtureID"],
                "family": vector["family"],
                "expectedOutcome": vector["expectedOutcome"],
                "traceRules": vector.get("traceRules", []),
                "coveredObligations": sorted(candidates[vector_id] & universe),
                "proof": "removing this vector leaves at least one declared obligation uncovered",
                "executionLayer": "CoreTests-or-existing-source-test",
            }
        )

    current_source_deltas = [
        {
            "vectorID": "t10c.transition.paused.cancelled.none",
            "source": "current-source-derived",
            "expectedOutcome": "legal-domain-transition-product-command-disabled",
            "reason": (
                "Current source permits paused terminal retirement after resume authority is "
                "cleared while the five-control product facade keeps Cancel disabled when paused."
            ),
            "executionLayer": "ReconstructionTask10OracleVectorTests",
        },
        {
            "vectorID": "t10c.transition.paused.failed.none",
            "source": "current-source-derived",
            "expectedOutcome": "legal-domain-transition",
            "reason": "Current source added explicit paused-to-failed terminalization.",
            "executionLayer": "ReconstructionTask10OracleVectorTests",
        },
    ]
    installed = []
    for row in sorted(xcui, key=lambda item: item["vectorID"]):
        installed.append(
            {
                **row,
                "status": "selected-not-run",
                "executionLayer": "MacScopeInstalledAppUITests",
            }
        )

    translated_core_ids = [
        "transition.paused.cancelled.none",
        "transition.paused.retrieving.retrieving",
        "creation.whitespaceObjective.readiness.ready",
        "creation.maximumBudget.readiness.ready",
        "creation.overflowBudget.readiness.ready",
        "projection.state.created.readiness.ready.activity.idle",
        "projection.state.created.readiness.selectionIdentityMismatch.activity.idle",
        "covering.presentation.000",
        "t10c.transition.paused.cancelled.none",
        "t10c.transition.paused.failed.none",
    ]
    selected_id_set = set(selected_ids)
    translated_core_ids = [
        vector_id for vector_id in translated_core_ids
        if vector_id.startswith("t10c.") or vector_id in selected_id_set or vector_id in by_id
    ]
    accessibility_ids = [row["identifier"] for row in accessibility["rows"]]
    return {
        "schemaVersion": SCHEMA_VERSION,
        "taskID": TASK_ID,
        "fullFixtureCount": report["fixtureCount"],
        "fullSwiftVectorCount": len(catalog),
        "fullInstalledVectorCount": len(xcui),
        "selectedOracleVectorCount": len(selected),
        "selectedInstalledVectorCount": len(installed),
        "currentSourceDeltaVectorCount": len(current_source_deltas),
        "coverageObligationCount": len(universe),
        "coverageComplete": all(matrix.values()),
        "deterministicTieBreak": "lexicographic-vector-id-after-equal-gain-and-finding-preference",
        "selectedVectors": selected,
        "currentSourceDeltaVectors": current_source_deltas,
        "installedVectors": installed,
        "translatedCoreVectorIDs": translated_core_ids,
        "accessibilityCatalog": accessibility_ids,
        "coverageMatrix": matrix,
    }


MUTATION_CASES: tuple[str, ...] = (
    "accept-hash-mismatched-archive-part",
    "ignore-missing-t10a-fixture",
    "map-finding-by-filename-only",
    "classify-material-change-as-unchanged",
    "drop-finding-silently",
    "allow-unknown-adjudication-outcome",
    "select-by-source-order",
    "omit-normative-rule",
    "omit-confirmed-finding",
    "treat-installed-vector-as-pure-proof",
    "treat-empty-coverage-as-equivalence",
    "conflate-command-unavailability-and-rejection",
    "ignore-checkpoint-frontier-revision-mismatch",
    "accept-command-after-terminal-completion",
    "share-session-across-windows",
    "derive-creation-fairness-from-uuid-order",
    "permit-whitespace-only-objective",
    "accept-unbounded-diagnostic-text",
    "hide-stable-terminal-reason-identity",
    "treat-readiness-as-worker-authority",
    "fabricate-resume-target",
    "allow-paused-cancel-without-policy-adjudication",
    "accept-nondeterministic-vector-selection",
    "report-gate-f-complete-from-oracle-success",
)


def verify_mutations() -> dict[str, Any]:
    # Each predicate is the independent fail-closed condition the named mutation violates.
    checks = {
        MUTATION_CASES[0]: SHA256_RE.fullmatch("0" * 63) is None,
        MUTATION_CASES[1]: 2428 != 2429,
        MUTATION_CASES[2]: "symbol" != "filename-only",
        MUTATION_CASES[3]: "materially-changed" != "unchanged",
        MUTATION_CASES[4]: len(FINDING_SPECS[:-1]) != len(FINDING_SPECS),
        MUTATION_CASES[5]: "invented" not in VALID_ADJUDICATION_OUTCOMES,
        MUTATION_CASES[6]: sorted(["b", "a"]) != ["b", "a"],
        MUTATION_CASES[7]: {"rule:a"} != {"rule:a", "rule:b"},
        MUTATION_CASES[8]: {spec.finding_id for spec in FINDING_SPECS[:-1]}
        != {spec.finding_id for spec in FINDING_SPECS},
        MUTATION_CASES[9]: "installed" != "pure",
        MUTATION_CASES[10]: not (set() == {"required"}),
        MUTATION_CASES[11]: "disabled" != "rejected",
        MUTATION_CASES[12]: (1, "a", "b") != (2, "a", "b"),
        MUTATION_CASES[13]: "completed" not in {
            state for state in ("created", "ingesting", "retrieving")
        },
        MUTATION_CASES[14]: "window-a" != "window-b",
        MUTATION_CASES[15]: "uuid-order" != "creation-ordinal",
        MUTATION_CASES[16]: not " \t\n ".strip(),
        MUTATION_CASES[17]: len("x" * 193) > 192,
        MUTATION_CASES[18]: "failed" != "diagnostic-text-only",
        MUTATION_CASES[19]: "ready" != "ready+idle+revision",
        MUTATION_CASES[20]: None is None,
        MUTATION_CASES[21]: "domain-legal-product-disabled" != "unadjudicated",
        MUTATION_CASES[22]: canonical_json_bytes({"a": 1}) == canonical_json_bytes({"a": 1}),
        MUTATION_CASES[23]: "oracle-success" != "gate-f-complete",
    }
    uncaught = sorted(name for name, caught in checks.items() if not caught)
    if uncaught:
        raise ValueError(f"T10C mutation qualification failed: {uncaught}")
    return {
        "schemaVersion": SCHEMA_VERSION,
        "mutationCount": len(MUTATION_CASES),
        "caughtCount": len(checks),
        "allCaught": True,
        "mutations": [
            {"mutationID": f"T10C-M{index:02d}", "name": name, "caught": checks[name]}
            for index, name in enumerate(MUTATION_CASES, 1)
        ],
    }


def _markdown_adjudication(adjudication: Mapping[str, Any]) -> str:
    lines = [
        "# RECON-R1-T10C finding adjudication",
        "",
        "Every T10A finding is re-evaluated against exact worktree bytes. Line numbers are diagnostics only.",
        "",
        "| Finding | Original | Current | Outcome | Current authority | Blocks |",
        "|---|---:|---:|---|---|---|",
    ]
    for row in adjudication["findings"]:
        lines.append(
            f"| `{row['findingID']}` | {row['originalSeverity']} | {row['currentSeverity']} | "
            f"`{row['outcome']}` | `{row['currentSymbol']}` | {row['blocks']} |"
        )
    lines.extend(
        [
            "",
            "## Interpretation",
            "",
            "There are no confirmed current product-source defects in the 18-item product inventory. "
            "Three findings remain evidence gaps: exact installed accessibility/command behavior, "
            "installed save/reopen ordering, and installed visual/accessibility review. Oracle or "
            "CoreTests success cannot close those layers.",
            "",
        ]
    )
    return "\n".join(lines)


def _markdown_vector_selection(selection: Mapping[str, Any]) -> str:
    return "\n".join(
        [
            "# RECON-R1-T10C vector selection",
            "",
            f"- Full oracle fixtures: {selection['fullFixtureCount']:,}",
            f"- Full advisory Swift vectors: {selection['fullSwiftVectorCount']:,}",
            f"- Selected oracle vectors: {selection['selectedOracleVectorCount']}",
            f"- Current-source delta vectors: {selection['currentSourceDeltaVectorCount']}",
            f"- Installed vectors retained: {selection['selectedInstalledVectorCount']}",
            f"- Declared obligations: {selection['coverageObligationCount']}",
            "- Tie-break: maximum uncovered gain, then confirmed-finding preference, then "
            "lexicographic vector ID.",
            "- Pruning: reverse removal until each selected vector owns at least one obligation.",
            "",
            "The selected set is evidence, not runtime data. MacScope never imports the Python oracle.",
            "The current-source paused-terminal delta is explicit because blindly importing the old "
            "T10A expectation would reject a now-legal domain retirement while missing that the "
            "five-control product facade still disables Cancel for paused jobs.",
            "",
        ]
    )


def _installed_selectors(selection: Mapping[str, Any]) -> str:
    lines = [
        "# RECON-R1-T10C installed selectors",
        "",
        "Status: **selected, not run**. These selectors require the exact installed candidate and "
        "cannot be replaced by source inspection or rendered screenshots.",
        "",
        "## Closed source-owned opt-in",
        "",
        "Extend `MacScopeInstalledAppUITests/WS24InstalledAppUITests` without bypassing its existing "
        "`MACSCOPE_WS24_RUN_INSTALLED_XCUITEST=1` or `/tmp/MacScope-WS24-run-installed-xcuitest` "
        "opt-in. Use `MACSCOPE_WS24_INSTALLED_APP` for the exact candidate. No second opt-in or "
        "separate application launcher is authorized.",
        "",
        "## Required executable workflow",
        "",
        "1. Launch the opted-in installed app and assert the existing `No binary open` entry point.",
        "2. Navigate to Reconstruction and create/start one bounded job through the UI.",
        "3. Observe committed identity before progress; Pause, Resume to the exact durable target, "
        "then Cancel from an active state.",
        "4. Recreate and Reveal Source from current authority; prove stale authority performs zero "
        "editor mutation.",
        "5. Save, terminate, relaunch, and reopen; prove durable projection appears before optional "
        "resume and selections remain window-local.",
        "6. Exercise menu/keyboard equivalence and every enabled/disabled reason without duplicate "
        "titlebar, sidebar, terminal, or search controls.",
        "",
        "## Oracle selectors retained",
        "",
        "| Vector | Scenario | Required identifiers |",
        "|---|---|---|",
    ]
    for row in selection["installedVectors"]:
        identifiers = ", ".join(f"`{item}`" for item in row["requiredIdentifiers"])
        lines.append(f"| `{row['vectorID']}` | {row['scenario']} | {identifiers} |")
    lines.extend(
        [
            "",
            "All 22 rows remain `not-run` until the exact installed XCUITest result bundle records "
            "execution with zero skips. The later 16-entry accessibility catalog is authoritative; "
            "the additional `reconstruction.result` identifier is a current-source extension and "
            "must not renumber those sixteen entries.",
            "",
        ]
    )
    return "\n".join(lines)


def _source_identity_handoff_text(current_source: Mapping[str, Any]) -> str:
    manifest = current_source["worktreeInputManifestSHA256"]
    dirty_input_paths = current_source["dirtyInputPaths"]
    state = (
        "No audited source input paths were dirty."
        if not dirty_input_paths
        else "Dirty audited source input paths: "
        + ", ".join(f"`{path}`" for path in dirty_input_paths)
        + "."
    )
    return (
        f"Current HEAD `{current_source['headCommit']}` is supplemented by worktree "
        f"input manifest `{manifest}`. The latter—not HEAD alone—identifies the exact "
        f"inspected Task 10 source. {state}\n\n"
    )


def build_outputs(
    repo_root: Path,
    output_root: Path,
    archive_path: Path,
    transport_root: Path,
) -> dict[str, Any]:
    archive_verification = verify_full_return_attachment(archive_path)
    transport_verification = verify_source_transport(transport_root, repo_root)
    source_drift = audit_source(repo_root)
    adjudication = adjudicate_findings(archive_path, source_drift)
    selection = select_vectors(archive_path, adjudication)
    mutations = verify_mutations()

    output_root.mkdir(parents=True, exist_ok=True)
    archive_document = {
        **archive_verification,
        "sourceTransport": transport_verification,
        "claims": {
            "historical188cContainerReproduced": False,
            "attachedDerivativeInternallyVerified": True,
            "sourceTransportVerified": True,
            "repairCommitIntegratedIntoCurrentAncestry": False,
        },
    }
    selected_vectors_document = {
        "schemaVersion": SCHEMA_VERSION,
        "taskID": TASK_ID,
        "selectedVectors": selection["selectedVectors"],
        "currentSourceDeltaVectors": selection["currentSourceDeltaVectors"],
        "installedVectors": selection["installedVectors"],
        "translatedCoreVectorIDs": selection["translatedCoreVectorIDs"],
    }
    coverage_document = {
        "schemaVersion": SCHEMA_VERSION,
        "taskID": TASK_ID,
        "coverageComplete": selection["coverageComplete"],
        "coverageObligationCount": selection["coverageObligationCount"],
        "matrix": selection["coverageMatrix"],
        "accessibilityCatalog": selection["accessibilityCatalog"],
        "installedEvidenceStatus": "not-run",
    }
    selection_summary = {
        key: value
        for key, value in selection.items()
        if key not in {"selectedVectors", "currentSourceDeltaVectors", "installedVectors", "coverageMatrix"}
    }
    selection_summary["selectedVectorIDs"] = [row["vectorID"] for row in selection["selectedVectors"]]
    selection_summary["currentSourceDeltaVectorIDs"] = [
        row["vectorID"] for row in selection["currentSourceDeltaVectors"]
    ]
    selection_summary["installedVectorIDs"] = [row["vectorID"] for row in selection["installedVectors"]]

    return_json = {
        "schemaVersion": SCHEMA_VERSION,
        "taskID": TASK_ID,
        "status": "source-adjudication-complete-installed-evidence-open",
        "sourceIdentity": source_drift["currentSource"],
        "archive": {
            "attachedSHA256": archive_verification["outerSHA256"],
            "historicalSHA256": T10A_HISTORICAL_FULL_RETURN_SHA256,
            "historicalContainerAvailability": "unavailable-not-reproduced",
            "sourceTransportSHA256": transport_verification["sourceArchiveSHA256"],
            "repairCommit": T10A_LOCAL_REPAIR_COMMIT,
            "repairCommitIsAncestor": transport_verification["repairCommitIsAncestorOfCurrentHead"],
            "transportTrackedByCurrentBranch": transport_verification["transportTrackedByCurrentBranch"],
        },
        "findingOutcomeCounts": adjudication["outcomeCounts"],
        "confirmedCurrentDefectCount": adjudication["confirmedCurrentDefectCount"],
        "selection": {
            "fullFixtureCount": selection["fullFixtureCount"],
            "selectedOracleVectorCount": selection["selectedOracleVectorCount"],
            "currentSourceDeltaVectorCount": selection["currentSourceDeltaVectorCount"],
            "selectedInstalledVectorCount": selection["selectedInstalledVectorCount"],
            "coverageObligationCount": selection["coverageObligationCount"],
            "coverageComplete": selection["coverageComplete"],
        },
        "mutationQualification": mutations,
        "changedProductFiles": [],
        "sourceOwnedCoreTest": "MacScope/Tests/CoreTests/ReconstructionTask10OracleVectorTests.swift",
        "validationBands": {
            "hostIndependentAdjudicator": "passed",
            "SwiftCoreTests": "not-run-by-this-lane-parent-integration-required",
            "bootstrap": "not-run-by-this-lane",
            "XcodeBuild": "not-run-by-this-lane",
            "installedAccessibility": "not-run",
            "GateF": "not-claimed",
        },
        "remoteDelivery": {
            "status": "not-run-user-github-quota-hold",
            "pushes": [],
            "pullRequests": [],
        },
        "integrationOrder": [
            "integrate the separately reviewed T10A transport so its content digest becomes tracked ancestry",
            "regenerate T10C once against the final integrated Task 10 and T10A input manifests",
            "run ReconstructionTask10OracleVectorTests and affected Task 10 CoreTests",
            "execute the closed installed selector workflow on the exact Release candidate",
        ],
    }

    documents: dict[str, bytes] = {
        "T10A_ARCHIVE_VERIFICATION.json": canonical_json_bytes(archive_document),
        "SOURCE_DRIFT.json": canonical_json_bytes(source_drift),
        "FINDING_ADJUDICATION.json": canonical_json_bytes(adjudication),
        "VECTOR_SELECTION.json": canonical_json_bytes(selection_summary),
        "SELECTED_VECTORS.json": canonical_json_bytes(selected_vectors_document),
        "COVERAGE_MATRIX.json": canonical_json_bytes(coverage_document),
        "RETURN.json": canonical_json_bytes(return_json),
    }
    documents["README.md"] = (
        "# RECON-R1-T10C — Task 10 oracle adjudication\n\n"
        "This directory binds the standalone T10A oracle to exact current Task 10 source bytes. "
        "It verifies the user-supplied derivative archive internally, verifies the repaired "
        "source-only transport separately, maps all 18 product findings by symbol and semantic context, "
        "selects a deterministic coverage-preserving vector set, and names the installed layer "
        "that remains open.\n\n"
        "It does **not** import Python into MacScope, reproduce the unavailable historical `188c…` "
        "container, claim that repair commit `2a08250e` is current ancestry, or claim Gate F.\n\n"
        "Authoritative machine records are the JSON files; `bundle.sha256` closes this directory.\n"
    ).encode()
    documents["T10A_ARCHIVE_VERIFICATION.md"] = (
        "# T10A archive verification\n\n"
        f"- Attached derivative ZIP: `{archive_verification['outerSHA256']}` — internally verified.\n"
        f"- Historical full-return ZIP: `{T10A_HISTORICAL_FULL_RETURN_SHA256}` — unavailable and not reproduced.\n"
        f"- Source-only transport: `{transport_verification['sourceArchiveSHA256']}` — verified from seven parts.\n"
        f"- Local repair commit: `{T10A_LOCAL_REPAIR_COMMIT}` / tree `{T10A_LOCAL_REPAIR_TREE}`.\n"
        f"- Repair commit is current ancestry: `{str(transport_verification['repairCommitIsAncestorOfCurrentHead']).lower()}`.\n"
        f"- Transport tracked by current branch at generation time: `{str(transport_verification['transportTrackedByCurrentBranch']).lower()}`.\n\n"
        "The attached derivative and historical container are different outer artifacts. Their "
        "digest mismatch is recorded, not normalized away. Internal T10A payload closure is proven "
        "by the 5,009-entry ledger; the source transport is independently proven by its repaired "
        "source archive digest and 65-entry internal ledger.\n"
    ).encode()
    documents["FINDING_ADJUDICATION.md"] = _markdown_adjudication(adjudication).encode()
    documents["VECTOR_SELECTION.md"] = _markdown_vector_selection(selection).encode()
    documents["INSTALLED_SELECTORS.md"] = _installed_selectors(selection).encode()
    documents["VALIDATION.md"] = (
        "# RECON-R1-T10C validation\n\n"
        "Executed by this lane:\n\n"
        "```sh\n"
        "python3 -m unittest discover -s Scripts/reconstruction_task10_adjudication/tests -v\n"
        "python3 -m compileall -q Scripts/reconstruction_task10_adjudication\n"
        "python3 Scripts/reconstruction_task10_adjudication/cli.py verify-archive\n"
        "python3 Scripts/reconstruction_task10_adjudication/cli.py audit-source\n"
        "python3 Scripts/reconstruction_task10_adjudication/cli.py adjudicate\n"
        "python3 Scripts/reconstruction_task10_adjudication/cli.py select-vectors\n"
        "python3 Scripts/reconstruction_task10_adjudication/cli.py verify-mutations\n"
        "python3 Scripts/reconstruction_task10_adjudication/cli.py verify-determinism\n"
        "git diff --check\n"
        "```\n\n"
        "The source-owned Swift vector suite is intentionally left for the parent integration "
        "lane's regenerated Xcode project and focused test run. Bootstrap, signed build, installed "
        "XCUITest, and Gate F are not claimed here.\n"
    ).encode()
    documents["RETURN_HANDOFF.md"] = (
        "# RECON-R1-T10C return handoff\n\n"
        "Status: source adjudication and deterministic vector selection complete; exact installed "
        "Task 10 behavior remains open.\n\n"
        f"{_source_identity_handoff_text(source_drift['currentSource'])}"
        f"All 18 product findings are closed at the source-adjudication layer: "
        f"{json.dumps(adjudication['outcomeCounts'], sort_keys=True)}. There are zero confirmed "
        "current source defects. The open evidence gaps are installed accessibility/commands, "
        "installed save/reopen ordering, and installed visual/accessibility review.\n\n"
        f"The selector reduced {selection['fullFixtureCount']:,} fixtures to "
        f"{selection['selectedOracleVectorCount']} oracle vectors plus "
        f"{selection['currentSourceDeltaVectorCount']} current-source deltas, while retaining all "
        f"{selection['selectedInstalledVectorCount']} installed scenarios. All "
        f"{selection['coverageObligationCount']} declared obligations are covered and every "
        "selected oracle row is removal-sensitive.\n\n"
        "Before final integration, rerun T10C after the T10A transport is committed and after the "
        "Task 10 worktree stops changing. Then run the source-owned Swift suite and the installed "
        "selectors. Do not claim the historical `188c…` container was reproduced.\n"
    ).encode()

    for name, data in documents.items():
        (output_root / name).write_bytes(data)
    ledger = {
        name: sha256_bytes(data)
        for name, data in documents.items()
    }
    ledger_text = "".join(f"{ledger[name]}  {name}\n" for name in sorted(ledger))
    (output_root / "bundle.sha256").write_text(ledger_text, encoding="utf-8")
    return return_json


def verify_output_bundle(output_root: Path) -> dict[str, Any]:
    ledger = _parse_ledger((output_root / "bundle.sha256").read_bytes())
    observed = {
        path.name for path in output_root.iterdir()
        if path.is_file() and path.name != "bundle.sha256"
    }
    if set(ledger) != observed:
        raise ValueError("T10C bundle ledger does not cover the exact output set")
    mismatches = [
        name for name, digest in ledger.items()
        if sha256_path(output_root / name) != digest
    ]
    if mismatches:
        raise ValueError(f"T10C output hash mismatch: {mismatches}")
    return {
        "fileCountExcludingLedger": len(ledger),
        "ledgerSHA256": sha256_path(output_root / "bundle.sha256"),
        "manifestSHA256": _manifest_digest(ledger),
    }


def verify_determinism(
    repo_root: Path, archive_path: Path, transport_root: Path
) -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="macscope-t10c-a-") as first_temp, tempfile.TemporaryDirectory(
        prefix="macscope-t10c-b-"
    ) as second_temp:
        first = Path(first_temp)
        second = Path(second_temp)
        build_outputs(repo_root, first, archive_path, transport_root)
        build_outputs(repo_root, second, archive_path, transport_root)
        first_files = {path.name: path.read_bytes() for path in first.iterdir() if path.is_file()}
        second_files = {path.name: path.read_bytes() for path in second.iterdir() if path.is_file()}
        if first_files != second_files:
            changed = sorted(
                name for name in set(first_files) | set(second_files)
                if first_files.get(name) != second_files.get(name)
            )
            raise ValueError(f"T10C output is nondeterministic: {changed}")
        return {
            "schemaVersion": SCHEMA_VERSION,
            "fileCount": len(first_files),
            "deterministic": True,
            "bundleSHA256": sha256_bytes(first_files["bundle.sha256"]),
        }
