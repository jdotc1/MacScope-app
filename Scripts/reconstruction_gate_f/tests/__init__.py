"""Deterministic fixtures for the host-independent Gate F compiler tests."""

from __future__ import annotations

from copy import deepcopy
from typing import Any

from Scripts.reconstruction_gate_f.schema import (
    CandidateIdentity,
    CandidateSubjectKind,
    parse_candidate_identity,
)


def sha(character: str) -> str:
    return character * 64


def git_object(character: str) -> str:
    return character * 40


def candidate_mapping(
    subject_kind: CandidateSubjectKind = CandidateSubjectKind.CANDIDATE,
) -> dict[str, Any]:
    prospective_commit = None
    prospective_tree = None
    accepted_commit = None
    accepted_tree = None
    if subject_kind in {
        CandidateSubjectKind.PROSPECTIVE_MERGE,
        CandidateSubjectKind.POST_MERGE,
    }:
        prospective_commit = git_object("a")
        prospective_tree = git_object("b")
    if subject_kind is CandidateSubjectKind.POST_MERGE:
        accepted_commit = git_object("c")
        accepted_tree = git_object("d")
    tool_ids = ("xcode", "swift", "sdk", "clang", "cmake", "ninja", "python", "zig")
    tool_digest_characters = "12345678"
    if len(tool_ids) != len(tool_digest_characters):
        raise AssertionError("Gate F fixture tool catalog has mismatched arity")
    tools = [
        {
            "tool_id": tool_id,
            "version": f"{tool_id}-version-1",
            "identity_sha256": sha(character),
        }
        for tool_id, character in zip(tool_ids, tool_digest_characters)
    ]
    return {
        "schema_version": 3,
        "subject_kind": subject_kind.value,
        "source": {
            "repository": "https://github.com/jdotc1/MacScope-app",
            "branch_label": "feature/reconstruction-r1-task11-compiler",
            "commit": git_object("1"),
            "tree": git_object("2"),
            "base_commit": git_object("3"),
            "base_tree": git_object("4"),
            "dirty": False,
            "project_yml_sha256": sha("9"),
            "generated_project_sha256": sha("a"),
            "semantic_prerequisites": [
                {
                    "prerequisite_id": "task-10",
                    "commit": git_object("5"),
                    "tree": git_object("6"),
                    "evidence_sha256": sha("b"),
                }
            ],
        },
        "tools": tools,
        "dependencies": [
            {
                "dependency_id": "ghostty-vt",
                "source_revision": git_object("7"),
                "source_tree_sha256": sha("8"),
                "manifest_sha256": sha("c"),
                "artifact_sha256": sha("d"),
            },
            {
                "dependency_id": "sleigh-native",
                "source_revision": git_object("9"),
                "source_tree_sha256": sha("a"),
                "manifest_sha256": sha("e"),
                "artifact_sha256": sha("f"),
            },
        ],
        "application": {
            "bundle_identifier": "org.macscope.app",
            "bundle_sha256": sha("0"),
            "closed_tree_sha256": sha("1"),
            "root_mode": 0o755,
            "executable_sha256": sha("2"),
            "signing_certificate_sha256": sha("3"),
            "signing_subject_sha256": sha("4"),
            "team_identifier": "TEAM000000",
            "entitlements_sha256": sha("5"),
            "designated_requirement_sha256": sha("6"),
            "hardened_runtime": True,
            "embedded_executables": [
                {"identity_id": "analysis-worker", "sha256": sha("7")},
                {"identity_id": "native-decompiler", "sha256": sha("8")},
                {"identity_id": "ai-agent-worker", "sha256": sha("a")},
                {"identity_id": "shell-broker", "sha256": sha("e")},
            ],
            "qualification_executables": [
                {
                    "identity_id": "app",
                    "bundle_identifier": "org.macscope.app",
                    "sha256": sha("b"),
                },
                {
                    "identity_id": "ai-agent-worker",
                    "bundle_identifier": "org.macscope.app.AIAgentWorker",
                    "sha256": sha("c"),
                },
                {
                    "identity_id": "native-live-app",
                    "bundle_identifier": "org.macscope.app",
                    "sha256": sha("e"),
                },
                {
                    "identity_id": "native-decompiler",
                    "bundle_identifier": "org.macscope.app.NativeDecompiler",
                    "sha256": sha("d"),
                },
            ],
        },
        "protocols": [
            {
                "protocol_id": "reconstruction-round-output",
                "version": 8,
                "manifest_sha256": sha("9"),
            }
        ],
        "packages": [
            {
                "package_id": "native-sleigh",
                "manifest_sha256": sha("a"),
                "tree_sha256": sha("b"),
            }
        ],
        "schemas": [
            {
                "schema_id": "gate-f-compiler",
                "version": 1,
                "content_sha256": sha("c"),
            }
        ],
        "selector_catalog_sha256": sha("d"),
        "prospective_merge_commit": prospective_commit,
        "prospective_merge_tree": prospective_tree,
        "accepted_postmerge_commit": accepted_commit,
        "accepted_postmerge_tree": accepted_tree,
    }


def parsed_candidate(
    subject_kind: CandidateSubjectKind = CandidateSubjectKind.CANDIDATE,
) -> CandidateIdentity:
    candidate, issues = parse_candidate_identity(candidate_mapping(subject_kind))
    if issues or candidate is None:
        raise AssertionError(issues)
    return candidate


def clone(value: Any) -> Any:
    return deepcopy(value)
