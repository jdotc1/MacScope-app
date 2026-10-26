"""Frozen Gate F vocabulary and exact candidate-identity schema.

This module is the narrow common seam shared by later compiler lanes.  It has no
filesystem, subprocess, platform, or application-runtime dependency.
"""

from __future__ import annotations

import dataclasses
import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from enum import Enum
from typing import Any, TypeVar

from .canonical_json import canonical_sha256, to_primitive

CANDIDATE_SCHEMA_VERSION = 3
GIT_OBJECT_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
STABLE_ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
BUNDLE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]{1,254}$")
TEAM_ID_RE = re.compile(r"^[A-Z0-9]{10}$")


class DecisionStatus(str, Enum):
    BLOCKED_PREREQUISITE = "blocked-prerequisite"
    NOT_RUN = "not-run"
    RUNNING_RECEIPTS_INCOMPLETE = "running-receipts-incomplete"
    FAILED = "failed"
    INVALID_EVIDENCE = "invalid-evidence"
    QUALIFIED_PREMERGE = "qualified-premerge"
    MERGED_POSTMERGE_PENDING = "merged-postmerge-pending"
    COMPLETE = "complete"


DECISION_STATUSES = tuple(status.value for status in DecisionStatus)


class EvidenceLayer(str, Enum):
    SOURCE_GOVERNANCE = "source-governance"
    HOSTED_PURE = "hosted-pure"
    NATIVE_NORMAL = "native-normal"
    NATIVE_ASAN = "native-asan"
    NATIVE_UBSAN = "native-ubsan"
    XCODE_FOCUSED = "xcode-focused"
    XCODE_FULL_CORETESTS = "xcode-full-coretests"
    SIGNED_XPC = "signed-xpc"
    RELEASE_BUILD = "release-build"
    STRICT_SIGNING = "strict-signing"
    INSTALLED_SOURCE_EQUALITY = "installed-source-equality"
    INSTALLED_LAUNCH_LOG = "installed-launch-log"
    INSTALLED_WORKFLOW = "installed-workflow"
    INSTALLED_ACCESSIBILITY = "installed-accessibility"
    STRESS_RECOVERY = "stress-recovery"
    INDEPENDENT_REVIEW = "independent-review"
    PROSPECTIVE_MERGE_TREE = "prospective-merge-tree"
    POST_MERGE = "post-merge"


EVIDENCE_LAYER_IDS = tuple(layer.value for layer in EvidenceLayer)


class EvidenceStatus(str, Enum):
    NOT_RUN = "not-run"
    UNAVAILABLE = "unavailable"
    FAILED = "failed"
    STALE = "stale"
    INVALID = "invalid"
    SUPERSEDED = "superseded"
    PASSED = "passed"


class SelectorStatus(str, Enum):
    NOT_RUN = "not-run"
    FAILED = "failed"
    SKIPPED = "skipped"
    PASSED = "passed"


class QualificationPhase(str, Enum):
    PREMERGE = "premerge"
    POSTMERGE = "postmerge"


class CandidateSubjectKind(str, Enum):
    CANDIDATE = "candidate"
    PROSPECTIVE_MERGE = "prospective-merge"
    POST_MERGE = "post-merge"


class ReceiptType(str, Enum):
    COMMAND_EXECUTION = "command-execution"
    TEST_RESULT = "test-result"
    ALLOWED_SKIP = "allowed-skip"
    ARTIFACT_MANIFEST = "artifact-manifest"
    NATIVE_SANITIZER = "native-sanitizer"
    SIGNED_XPC = "signed-xpc"
    RELEASE_BUILD = "release-build"
    STRICT_SIGNING = "strict-signing"
    INSTALLED_SOURCE_EQUALITY = "installed-source-equality"
    INSTALLED_LAUNCH_LOG = "installed-launch-log"
    INSTALLED_WORKFLOW = "installed-workflow"
    INSTALLED_ACCESSIBILITY = "installed-accessibility"
    STRESS_RECOVERY = "stress-recovery"
    INDEPENDENT_REVIEW = "independent-review"
    PROSPECTIVE_MERGE_TREE = "prospective-merge-tree"
    POST_MERGE = "post-merge"
    FINAL_DECISION = "final-decision"


class ArtifactKind(str, Enum):
    JSON = "json"
    TEST_RESULTS = "test-results"
    XCRESULT = "xcresult"
    SANITIZER_REPORT = "sanitizer-report"
    SIGNED_EXECUTABLE = "signed-executable"
    APP_BUNDLE = "app-bundle"
    SIGNING_REPORT = "signing-report"
    SOURCE_EQUALITY_REPORT = "source-equality-report"
    LAUNCH_LOG = "launch-log"
    WORKFLOW_REPORT = "workflow-report"
    ACCESSIBILITY_REPORT = "accessibility-report"
    STRESS_REPORT = "stress-report"
    REVIEW_REPORT = "review-report"
    MERGE_PROOF = "merge-proof"
    PROTOCOL_MANIFEST = "protocol-manifest"
    PACKAGE_MANIFEST = "package-manifest"
    SCHEMA_MANIFEST = "schema-manifest"


class ExecutorPlatform(str, Enum):
    MACOS = "macos"
    LINUX = "linux"


class ExecutorArchitecture(str, Enum):
    ARM64 = "arm64"
    X86_64 = "x86_64"


@dataclass(frozen=True, order=True)
class ValidationIssue:
    code: str
    path: str
    message: str


@dataclass(frozen=True)
class PrerequisiteIdentity:
    prerequisite_id: str
    commit: str
    tree: str
    evidence_sha256: str


@dataclass(frozen=True)
class SourceIdentity:
    repository: str
    branch_label: str
    commit: str
    tree: str
    base_commit: str
    base_tree: str
    dirty: bool
    project_yml_sha256: str
    generated_project_sha256: str
    semantic_prerequisites: tuple[PrerequisiteIdentity, ...]


@dataclass(frozen=True)
class ToolIdentity:
    tool_id: str
    version: str
    identity_sha256: str


@dataclass(frozen=True)
class DependencyIdentity:
    dependency_id: str
    source_revision: str
    source_tree_sha256: str
    manifest_sha256: str
    artifact_sha256: str


@dataclass(frozen=True)
class NamedDigestIdentity:
    identity_id: str
    sha256: str


@dataclass(frozen=True)
class QualificationExecutableIdentity:
    identity_id: str
    bundle_identifier: str
    sha256: str


@dataclass(frozen=True)
class ApplicationIdentity:
    bundle_identifier: str
    bundle_sha256: str
    closed_tree_sha256: str
    root_mode: int
    executable_sha256: str
    signing_certificate_sha256: str
    signing_subject_sha256: str
    team_identifier: str
    entitlements_sha256: str
    designated_requirement_sha256: str
    hardened_runtime: bool
    embedded_executables: tuple[NamedDigestIdentity, ...]
    qualification_executables: tuple[QualificationExecutableIdentity, ...]


@dataclass(frozen=True)
class ProtocolIdentity:
    protocol_id: str
    version: int
    manifest_sha256: str


@dataclass(frozen=True)
class PackageIdentity:
    package_id: str
    manifest_sha256: str
    tree_sha256: str


@dataclass(frozen=True)
class SchemaIdentity:
    schema_id: str
    version: int
    content_sha256: str


@dataclass(frozen=True)
class CandidateIdentity:
    schema_version: int
    subject_kind: CandidateSubjectKind
    source: SourceIdentity
    tools: tuple[ToolIdentity, ...]
    dependencies: tuple[DependencyIdentity, ...]
    application: ApplicationIdentity
    protocols: tuple[ProtocolIdentity, ...]
    packages: tuple[PackageIdentity, ...]
    schemas: tuple[SchemaIdentity, ...]
    selector_catalog_sha256: str
    prospective_merge_commit: str | None
    prospective_merge_tree: str | None
    accepted_postmerge_commit: str | None
    accepted_postmerge_tree: str | None


REQUIRED_TOOL_IDS = frozenset(
    {"xcode", "swift", "sdk", "clang", "cmake", "ninja", "python", "zig"}
)
REQUIRED_DEPENDENCY_IDS = frozenset({"ghostty-vt", "sleigh-native"})
REQUIRED_EMBEDDED_EXECUTABLE_IDS = frozenset(
    {"analysis-worker", "ai-agent-worker", "native-decompiler", "shell-broker"}
)
REQUIRED_PROTOCOL_IDS = frozenset({"reconstruction-round-output"})
REQUIRED_PACKAGE_IDS = frozenset({"native-sleigh"})
REQUIRED_SCHEMA_IDS = frozenset({"gate-f-compiler"})

SOURCE_FIELDS = frozenset(
    {
        "repository",
        "branch_label",
        "commit",
        "tree",
        "base_commit",
        "base_tree",
        "dirty",
        "project_yml_sha256",
        "generated_project_sha256",
        "semantic_prerequisites",
    }
)
PREREQUISITE_FIELDS = frozenset(
    {"prerequisite_id", "commit", "tree", "evidence_sha256"}
)
TOOL_FIELDS = frozenset({"tool_id", "version", "identity_sha256"})
DEPENDENCY_FIELDS = frozenset(
    {
        "dependency_id",
        "source_revision",
        "source_tree_sha256",
        "manifest_sha256",
        "artifact_sha256",
    }
)
NAMED_DIGEST_FIELDS = frozenset({"identity_id", "sha256"})
QUALIFICATION_EXECUTABLE_FIELDS = frozenset(
    {"identity_id", "bundle_identifier", "sha256"}
)
REQUIRED_QUALIFICATION_EXECUTABLE_IDS = frozenset(
    {"app", "ai-agent-worker", "native-live-app", "native-decompiler"}
)
APPLICATION_FIELDS = frozenset(
    {
        "bundle_identifier",
        "bundle_sha256",
        "closed_tree_sha256",
        "root_mode",
        "executable_sha256",
        "signing_certificate_sha256",
        "signing_subject_sha256",
        "team_identifier",
        "entitlements_sha256",
        "designated_requirement_sha256",
        "hardened_runtime",
        "embedded_executables",
        "qualification_executables",
    }
)
PROTOCOL_FIELDS = frozenset({"protocol_id", "version", "manifest_sha256"})
PACKAGE_FIELDS = frozenset({"package_id", "manifest_sha256", "tree_sha256"})
SCHEMA_FIELDS = frozenset({"schema_id", "version", "content_sha256"})
CANDIDATE_FIELDS = frozenset(
    {
        "schema_version",
        "subject_kind",
        "source",
        "tools",
        "dependencies",
        "application",
        "protocols",
        "packages",
        "schemas",
        "selector_catalog_sha256",
        "prospective_merge_commit",
        "prospective_merge_tree",
        "accepted_postmerge_commit",
        "accepted_postmerge_tree",
    }
)


def is_git_object(value: object) -> bool:
    return isinstance(value, str) and GIT_OBJECT_RE.fullmatch(value) is not None


def is_sha256(value: object) -> bool:
    return isinstance(value, str) and SHA256_RE.fullmatch(value) is not None


def is_integer(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def closed_record(
    value: object,
    fields: frozenset[str],
    *,
    path: str,
) -> tuple[Mapping[str, Any] | None, list[ValidationIssue]]:
    if not isinstance(value, Mapping):
        return None, [ValidationIssue("record-type", path, "must be an object")]
    keys = set(value)
    issues = [
        ValidationIssue("unknown-field", f"{path}.{key}", "field is not in the closed schema")
        for key in sorted(keys - fields)
    ]
    issues.extend(
        ValidationIssue("missing-field", f"{path}.{key}", "required field is missing")
        for key in sorted(fields - keys)
    )
    return value, issues


def _stable_text(value: object, *, path: str, identifier: bool = False) -> list[ValidationIssue]:
    try:
        encoded_size = len(value.encode("utf-8")) if isinstance(value, str) else 0
    except UnicodeEncodeError:
        encoded_size = 513
    if not isinstance(value, str) or not value or encoded_size > 512:
        return [ValidationIssue("text-type", path, "must be bounded nonempty UTF-8 text")]
    if identifier and STABLE_ID_RE.fullmatch(value) is None:
        return [ValidationIssue("stable-id", path, "must be a canonical lowercase stable ID")]
    return []


def _digest(value: object, *, path: str) -> list[ValidationIssue]:
    if not is_sha256(value):
        return [ValidationIssue("sha256", path, "must be a lowercase 64-hex SHA-256")]
    return []


def _git(value: object, *, path: str, nullable: bool = False) -> list[ValidationIssue]:
    if nullable and value is None:
        return []
    if not is_git_object(value):
        return [ValidationIssue("git-object", path, "must be a lowercase 40-hex Git identity")]
    return []


def _positive_integer(value: object, *, path: str) -> list[ValidationIssue]:
    if not is_integer(value) or value < 1:
        return [ValidationIssue("positive-integer", path, "must be a positive integer")]
    return []


def _parse_list(
    value: object,
    *,
    path: str,
    parser: Any,
) -> tuple[list[Any], list[ValidationIssue]]:
    if not isinstance(value, list):
        return [], [ValidationIssue("array-type", path, "must be an array")]
    parsed: list[Any] = []
    issues: list[ValidationIssue] = []
    for index, item in enumerate(value):
        result, item_issues = parser(item, path=f"{path}[{index}]")
        issues.extend(item_issues)
        if result is not None:
            parsed.append(result)
    return parsed, issues


def _parse_source(value: object, *, path: str) -> tuple[SourceIdentity | None, list[ValidationIssue]]:
    record, issues = closed_record(value, SOURCE_FIELDS, path=path)
    if record is None or issues:
        return None, issues
    issues.extend(_stable_text(record["repository"], path=f"{path}.repository"))
    issues.extend(_stable_text(record["branch_label"], path=f"{path}.branch_label"))
    for name in ("commit", "tree", "base_commit", "base_tree"):
        issues.extend(_git(record[name], path=f"{path}.{name}"))
    for name in ("project_yml_sha256", "generated_project_sha256"):
        issues.extend(_digest(record[name], path=f"{path}.{name}"))
    if not isinstance(record["dirty"], bool):
        issues.append(ValidationIssue("boolean-type", f"{path}.dirty", "must be Boolean"))
    elif record["dirty"]:
        issues.append(ValidationIssue("candidate-dirty", f"{path}.dirty", "candidate must be clean"))
    prerequisites, nested = _parse_list(
        record["semantic_prerequisites"],
        path=f"{path}.semantic_prerequisites",
        parser=_parse_prerequisite,
    )
    issues.extend(nested)
    issues.extend(
        _require_nonempty_unique(
            prerequisites,
            "prerequisite_id",
            path=f"{path}.semantic_prerequisites",
        )
    )
    if issues:
        return None, issues
    return SourceIdentity(
        repository=record["repository"],
        branch_label=record["branch_label"],
        commit=record["commit"],
        tree=record["tree"],
        base_commit=record["base_commit"],
        base_tree=record["base_tree"],
        dirty=record["dirty"],
        project_yml_sha256=record["project_yml_sha256"],
        generated_project_sha256=record["generated_project_sha256"],
        semantic_prerequisites=tuple(
            sorted(prerequisites, key=lambda item: item.prerequisite_id)
        ),
    ), []


def _parse_prerequisite(
    value: object, *, path: str
) -> tuple[PrerequisiteIdentity | None, list[ValidationIssue]]:
    record, issues = closed_record(value, PREREQUISITE_FIELDS, path=path)
    if record is None or issues:
        return None, issues
    issues.extend(
        _stable_text(
            record["prerequisite_id"],
            path=f"{path}.prerequisite_id",
            identifier=True,
        )
    )
    for name in ("commit", "tree"):
        issues.extend(_git(record[name], path=f"{path}.{name}"))
    issues.extend(_digest(record["evidence_sha256"], path=f"{path}.evidence_sha256"))
    return (PrerequisiteIdentity(**record), []) if not issues else (None, issues)


def _parse_tool(value: object, *, path: str) -> tuple[ToolIdentity | None, list[ValidationIssue]]:
    record, issues = closed_record(value, TOOL_FIELDS, path=path)
    if record is None or issues:
        return None, issues
    issues.extend(_stable_text(record["tool_id"], path=f"{path}.tool_id", identifier=True))
    issues.extend(_stable_text(record["version"], path=f"{path}.version"))
    issues.extend(_digest(record["identity_sha256"], path=f"{path}.identity_sha256"))
    return (ToolIdentity(**record), []) if not issues else (None, issues)


def _parse_dependency(
    value: object, *, path: str
) -> tuple[DependencyIdentity | None, list[ValidationIssue]]:
    record, issues = closed_record(value, DEPENDENCY_FIELDS, path=path)
    if record is None or issues:
        return None, issues
    issues.extend(
        _stable_text(record["dependency_id"], path=f"{path}.dependency_id", identifier=True)
    )
    issues.extend(
        _stable_text(record["source_revision"], path=f"{path}.source_revision")
    )
    for name in ("source_tree_sha256", "manifest_sha256", "artifact_sha256"):
        issues.extend(_digest(record[name], path=f"{path}.{name}"))
    return (DependencyIdentity(**record), []) if not issues else (None, issues)


def _parse_named_digest(
    value: object, *, path: str
) -> tuple[NamedDigestIdentity | None, list[ValidationIssue]]:
    record, issues = closed_record(value, NAMED_DIGEST_FIELDS, path=path)
    if record is None or issues:
        return None, issues
    issues.extend(_stable_text(record["identity_id"], path=f"{path}.identity_id", identifier=True))
    issues.extend(_digest(record["sha256"], path=f"{path}.sha256"))
    return (NamedDigestIdentity(**record), []) if not issues else (None, issues)


def _parse_qualification_executable(
    value: object, *, path: str
) -> tuple[QualificationExecutableIdentity | None, list[ValidationIssue]]:
    record, issues = closed_record(
        value,
        QUALIFICATION_EXECUTABLE_FIELDS,
        path=path,
    )
    if record is None or issues:
        return None, issues
    issues.extend(
        _stable_text(record["identity_id"], path=f"{path}.identity_id", identifier=True)
    )
    bundle_identifier = record["bundle_identifier"]
    if (
        not isinstance(bundle_identifier, str)
        or BUNDLE_ID_RE.fullmatch(bundle_identifier) is None
    ):
        issues.append(
            ValidationIssue(
                "bundle-id",
                f"{path}.bundle_identifier",
                "invalid bundle ID",
            )
        )
    issues.extend(_digest(record["sha256"], path=f"{path}.sha256"))
    return (
        QualificationExecutableIdentity(**record),
        [],
    ) if not issues else (None, issues)


def _parse_application(
    value: object, *, path: str
) -> tuple[ApplicationIdentity | None, list[ValidationIssue]]:
    record, issues = closed_record(value, APPLICATION_FIELDS, path=path)
    if record is None or issues:
        return None, issues
    bundle = record["bundle_identifier"]
    if not isinstance(bundle, str) or BUNDLE_ID_RE.fullmatch(bundle) is None:
        issues.append(ValidationIssue("bundle-id", f"{path}.bundle_identifier", "invalid bundle ID"))
    for name in (
        "bundle_sha256",
        "closed_tree_sha256",
        "executable_sha256",
        "signing_certificate_sha256",
        "signing_subject_sha256",
        "entitlements_sha256",
        "designated_requirement_sha256",
    ):
        issues.extend(_digest(record[name], path=f"{path}.{name}"))
    if (
        not is_integer(record["root_mode"])
        or record["root_mode"] < 0
        or record["root_mode"] > 0o7777
    ):
        issues.append(
            ValidationIssue(
                "root-mode",
                f"{path}.root_mode",
                "must be a POSIX permission mode from 0 through 0o7777",
            )
        )
    if not isinstance(record["team_identifier"], str) or TEAM_ID_RE.fullmatch(record["team_identifier"]) is None:
        issues.append(
            ValidationIssue("team-id", f"{path}.team_identifier", "must be a 10-character Team ID")
        )
    if record["hardened_runtime"] is not True:
        issues.append(
            ValidationIssue(
                "hardened-runtime",
                f"{path}.hardened_runtime",
                "candidate application must use hardened runtime",
            )
        )
    embedded, nested = _parse_list(
        record["embedded_executables"],
        path=f"{path}.embedded_executables",
        parser=_parse_named_digest,
    )
    issues.extend(nested)
    issues.extend(_require_nonempty_unique(embedded, "identity_id", path=f"{path}.embedded_executables"))
    embedded_ids = {item.identity_id for item in embedded}
    if not REQUIRED_EMBEDDED_EXECUTABLE_IDS.issubset(embedded_ids):
        issues.append(
            ValidationIssue(
                "required-embedded-executable",
                f"{path}.embedded_executables",
                "candidate must bind every embedded production XPC executable",
            )
        )
    qualification, nested = _parse_list(
        record["qualification_executables"],
        path=f"{path}.qualification_executables",
        parser=_parse_qualification_executable,
    )
    issues.extend(nested)
    issues.extend(
        _require_nonempty_unique(
            qualification,
            "identity_id",
            path=f"{path}.qualification_executables",
        )
    )
    qualification_ids = {item.identity_id for item in qualification}
    if not REQUIRED_QUALIFICATION_EXECUTABLE_IDS.issubset(qualification_ids):
        issues.append(
            ValidationIssue(
                "required-qualification-executable",
                f"{path}.qualification_executables",
                "candidate must bind the regular Debug app/AI worker and the separately compiled native-live app/service executables",
            )
        )
    if issues:
        return None, issues
    return ApplicationIdentity(
        bundle_identifier=bundle,
        bundle_sha256=record["bundle_sha256"],
        closed_tree_sha256=record["closed_tree_sha256"],
        root_mode=record["root_mode"],
        executable_sha256=record["executable_sha256"],
        signing_certificate_sha256=record["signing_certificate_sha256"],
        signing_subject_sha256=record["signing_subject_sha256"],
        team_identifier=record["team_identifier"],
        entitlements_sha256=record["entitlements_sha256"],
        designated_requirement_sha256=record["designated_requirement_sha256"],
        hardened_runtime=record["hardened_runtime"],
        embedded_executables=tuple(sorted(embedded, key=lambda item: item.identity_id)),
        qualification_executables=tuple(
            sorted(qualification, key=lambda item: item.identity_id)
        ),
    ), []


def _parse_protocol(
    value: object, *, path: str
) -> tuple[ProtocolIdentity | None, list[ValidationIssue]]:
    record, issues = closed_record(value, PROTOCOL_FIELDS, path=path)
    if record is None or issues:
        return None, issues
    issues.extend(_stable_text(record["protocol_id"], path=f"{path}.protocol_id", identifier=True))
    issues.extend(_positive_integer(record["version"], path=f"{path}.version"))
    issues.extend(_digest(record["manifest_sha256"], path=f"{path}.manifest_sha256"))
    return (ProtocolIdentity(**record), []) if not issues else (None, issues)


def _parse_package(
    value: object, *, path: str
) -> tuple[PackageIdentity | None, list[ValidationIssue]]:
    record, issues = closed_record(value, PACKAGE_FIELDS, path=path)
    if record is None or issues:
        return None, issues
    issues.extend(_stable_text(record["package_id"], path=f"{path}.package_id", identifier=True))
    for name in ("manifest_sha256", "tree_sha256"):
        issues.extend(_digest(record[name], path=f"{path}.{name}"))
    return (PackageIdentity(**record), []) if not issues else (None, issues)


def _parse_schema(value: object, *, path: str) -> tuple[SchemaIdentity | None, list[ValidationIssue]]:
    record, issues = closed_record(value, SCHEMA_FIELDS, path=path)
    if record is None or issues:
        return None, issues
    issues.extend(_stable_text(record["schema_id"], path=f"{path}.schema_id", identifier=True))
    issues.extend(_positive_integer(record["version"], path=f"{path}.version"))
    issues.extend(_digest(record["content_sha256"], path=f"{path}.content_sha256"))
    return (SchemaIdentity(**record), []) if not issues else (None, issues)


T = TypeVar("T")


def _require_nonempty_unique(
    values: Sequence[T],
    attribute: str,
    *,
    path: str,
) -> list[ValidationIssue]:
    if not values:
        return [ValidationIssue("empty-catalog", path, "catalog must not be empty")]
    seen: set[object] = set()
    issues: list[ValidationIssue] = []
    for index, value in enumerate(values):
        identity = getattr(value, attribute)
        if identity in seen:
            issues.append(
                ValidationIssue("duplicate-id", f"{path}[{index}].{attribute}", "duplicate stable ID")
            )
        seen.add(identity)
    return issues


def parse_candidate_identity(
    value: object, *, path: str = "$.candidate_identity"
) -> tuple[CandidateIdentity | None, tuple[ValidationIssue, ...]]:
    record, issues = closed_record(value, CANDIDATE_FIELDS, path=path)
    if record is None or issues:
        return None, tuple(sorted(issues))
    if not is_integer(record["schema_version"]) or record["schema_version"] != CANDIDATE_SCHEMA_VERSION:
        issues.append(
            ValidationIssue("schema-version", f"{path}.schema_version", "unsupported candidate schema")
        )
    subject_kind, nested = enum_value(
        CandidateSubjectKind,
        record["subject_kind"],
        path=f"{path}.subject_kind",
    )
    issues.extend(nested)
    source, nested = _parse_source(record["source"], path=f"{path}.source")
    issues.extend(nested)
    tools, nested = _parse_list(record["tools"], path=f"{path}.tools", parser=_parse_tool)
    issues.extend(nested)
    dependencies, nested = _parse_list(
        record["dependencies"], path=f"{path}.dependencies", parser=_parse_dependency
    )
    issues.extend(nested)
    application, nested = _parse_application(record["application"], path=f"{path}.application")
    issues.extend(nested)
    protocols, nested = _parse_list(
        record["protocols"], path=f"{path}.protocols", parser=_parse_protocol
    )
    issues.extend(nested)
    packages, nested = _parse_list(record["packages"], path=f"{path}.packages", parser=_parse_package)
    issues.extend(nested)
    schemas, nested = _parse_list(record["schemas"], path=f"{path}.schemas", parser=_parse_schema)
    issues.extend(nested)

    issues.extend(_require_nonempty_unique(tools, "tool_id", path=f"{path}.tools"))
    issues.extend(
        _require_nonempty_unique(dependencies, "dependency_id", path=f"{path}.dependencies")
    )
    issues.extend(_require_nonempty_unique(protocols, "protocol_id", path=f"{path}.protocols"))
    issues.extend(_require_nonempty_unique(packages, "package_id", path=f"{path}.packages"))
    issues.extend(_require_nonempty_unique(schemas, "schema_id", path=f"{path}.schemas"))
    issues.extend(_digest(record["selector_catalog_sha256"], path=f"{path}.selector_catalog_sha256"))
    tool_ids = {tool.tool_id for tool in tools}
    if not REQUIRED_TOOL_IDS.issubset(tool_ids):
        issues.append(
            ValidationIssue(
                "required-tool-identity",
                f"{path}.tools",
                "candidate must bind Xcode, Swift, SDK, clang, CMake, Ninja, Python, and Zig",
            )
        )
    required_catalogs = (
        (dependencies, "dependency_id", REQUIRED_DEPENDENCY_IDS, "required-dependency-identity", "dependencies"),
        (protocols, "protocol_id", REQUIRED_PROTOCOL_IDS, "required-protocol-identity", "protocols"),
        (packages, "package_id", REQUIRED_PACKAGE_IDS, "required-package-identity", "packages"),
        (schemas, "schema_id", REQUIRED_SCHEMA_IDS, "required-schema-identity", "schemas"),
    )
    for values, attribute, required, code, field in required_catalogs:
        if not required.issubset({getattr(item, attribute) for item in values}):
            issues.append(
                ValidationIssue(
                    code,
                    f"{path}.{field}",
                    "candidate omits a required authority identity",
                )
            )

    for prefix in ("prospective_merge", "accepted_postmerge"):
        commit = record[f"{prefix}_commit"]
        tree = record[f"{prefix}_tree"]
        if (commit is None) != (tree is None):
            issues.append(
                ValidationIssue("identity-pair", f"{path}.{prefix}", "commit and tree must appear together")
            )
        issues.extend(_git(commit, path=f"{path}.{prefix}_commit", nullable=True))
        issues.extend(_git(tree, path=f"{path}.{prefix}_tree", nullable=True))

    prospective_present = record["prospective_merge_commit"] is not None
    accepted_present = record["accepted_postmerge_commit"] is not None
    expected_presence = {
        CandidateSubjectKind.CANDIDATE: (False, False),
        CandidateSubjectKind.PROSPECTIVE_MERGE: (True, False),
        CandidateSubjectKind.POST_MERGE: (True, True),
    }
    if subject_kind is not None and (prospective_present, accepted_present) != expected_presence[subject_kind]:
        issues.append(
            ValidationIssue(
                "subject-phase-identity",
                path,
                "subject kind and merge identity axes are inconsistent",
            )
        )

    if issues or subject_kind is None or source is None or application is None:
        return None, tuple(sorted(set(issues)))
    candidate = CandidateIdentity(
        schema_version=record["schema_version"],
        subject_kind=subject_kind,
        source=source,
        tools=tuple(sorted(tools, key=lambda item: item.tool_id)),
        dependencies=tuple(sorted(dependencies, key=lambda item: item.dependency_id)),
        application=application,
        protocols=tuple(sorted(protocols, key=lambda item: item.protocol_id)),
        packages=tuple(sorted(packages, key=lambda item: item.package_id)),
        schemas=tuple(sorted(schemas, key=lambda item: item.schema_id)),
        selector_catalog_sha256=record["selector_catalog_sha256"],
        prospective_merge_commit=record["prospective_merge_commit"],
        prospective_merge_tree=record["prospective_merge_tree"],
        accepted_postmerge_commit=record["accepted_postmerge_commit"],
        accepted_postmerge_tree=record["accepted_postmerge_tree"],
    )
    return candidate, ()


def validate_candidate_identity(value: object) -> tuple[ValidationIssue, ...]:
    return parse_candidate_identity(value)[1]


def candidate_to_mapping(candidate: CandidateIdentity) -> dict[str, Any]:
    return to_primitive(candidate)


def candidate_authority_mapping(candidate: CandidateIdentity) -> dict[str, Any]:
    payload = candidate_to_mapping(candidate)
    # A branch is a mutable navigation aid, never a substitute for commit + tree.
    payload["source"] = dict(payload["source"])
    payload["source"].pop("branch_label")
    return payload


def candidate_identity_sha256(candidate: CandidateIdentity) -> str:
    return canonical_sha256(candidate_authority_mapping(candidate))


def same_candidate_authority(left: CandidateIdentity, right: CandidateIdentity) -> bool:
    return candidate_authority_mapping(left) == candidate_authority_mapping(right)


def enum_value(enum_type: type[Enum], value: object, *, path: str) -> tuple[Enum | None, list[ValidationIssue]]:
    if not isinstance(value, str):
        return None, [ValidationIssue("enum-type", path, "must be a string enum value")]
    try:
        return enum_type(value), []
    except ValueError:
        return None, [ValidationIssue("enum-value", path, "unknown closed enum value")]


assert len(DECISION_STATUSES) == 8
assert len(EVIDENCE_LAYER_IDS) >= 18
