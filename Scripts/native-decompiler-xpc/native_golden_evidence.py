"""Closed payload validation shared by standalone and embedded golden owners.

Expected identities must be constructed by the owner from observed inputs. This
module validates bytes only; it grants no filesystem or execution authority.
"""

from __future__ import annotations

import json
import re


IDENTITY_KEYS = frozenset({
    "architecture", "backendID", "contractArchiveSHA256", "contractBuildIdentitySHA256",
    "decompilerArchiveSHA256", "deploymentTarget", "engineGitRevision", "engineVersion",
    "goldenSourceSHA256", "materializationManifestSHA256", "materializationTreeSHA256",
    "sdkBuild", "sdkName", "sdkVersion", "sleighArchiveSHA256", "stageStampSHA256",
    "swiftCompilerVersion", "swiftTargetTriple", "wrapperGitRevision", "wrapperVersion",
    "xcodeBuild", "xcodeVersion",
})
OUTCOME_KEYS = frozenset({
    "objcMappingSHA256", "objcReplySHA256", "objcRequestSHA256", "packageBackedReplySHA256",
    "packageBackedRequestSHA256", "packageBackedSwiftReplySHA256", "swiftReplySHA256",
})
GOLDEN_KEYS = IDENTITY_KEYS | OUTCOME_KEYS | {"passed", "schemaVersion"}
COMMON_IDENTITY_KEYS = IDENTITY_KEYS - {
    "contractArchiveSHA256", "contractBuildIdentitySHA256", "decompilerArchiveSHA256",
    "materializationManifestSHA256", "materializationTreeSHA256", "sleighArchiveSHA256",
    "stageStampSHA256",
}
PINNED_IDENTITY = {
    "architecture": "arm64", "deploymentTarget": "27.0", "backendID": "ghidra-native-decompiler",
    "engineVersion": "12.1.2", "engineGitRevision": "c0f584bf229fffba61b36431f3ce30c0c3e4e682",
    "wrapperVersion": "dcp05c-v1",
}


class GoldenEvidenceError(RuntimeError):
    """Golden bytes do not describe the exact observed successful execution."""


def _closed_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise GoldenEvidenceError("golden result has duplicate fields")
        result[key] = value
    return result


def validate_golden_payload(payload: bytes, *, expected_identity: dict[str, object]) -> dict[str, object]:
    if not isinstance(payload, bytes) or len(payload) > 64 * 1024:
        raise GoldenEvidenceError("golden result exceeds its bounded byte contract")
    try:
        value = json.loads(payload, object_pairs_hook=_closed_object)
    except (UnicodeError, ValueError) as error:
        raise GoldenEvidenceError("golden result is malformed") from error
    if not isinstance(value, dict) or set(value) != GOLDEN_KEYS:
        raise GoldenEvidenceError("golden result has unsupported fields")
    canonical = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
    if payload != canonical:
        raise GoldenEvidenceError("golden result is not canonical JSON")
    if type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1 or value["passed"] is not True:
        raise GoldenEvidenceError("golden result did not pass")
    for key in GOLDEN_KEYS - {"schemaVersion", "passed"}:
        if not isinstance(value[key], str) or not value[key]:
            raise GoldenEvidenceError(f"golden result has invalid {key}")
        if key.endswith("SHA256"):
            if re.fullmatch(r"[0-9a-f]{64}", value[key]) is None:
                raise GoldenEvidenceError(f"golden result has invalid {key}")
    if (not isinstance(expected_identity, dict)
            or not COMMON_IDENTITY_KEYS <= set(expected_identity)
            or not set(expected_identity) <= IDENTITY_KEYS):
        raise GoldenEvidenceError("golden validation requires independently observed identity fields")
    for key, expected in {**expected_identity, **PINNED_IDENTITY}.items():
        if value[key] != expected or (key in PINNED_IDENTITY and expected_identity.get(key) != expected):
            raise GoldenEvidenceError(f"golden result {key} differs from the build")
    if re.fullmatch(r"[0-9a-f]{64}", value["wrapperGitRevision"]) is None:
        raise GoldenEvidenceError("golden result has invalid wrapperGitRevision")
    if any(marker in payload.decode("utf-8") for marker in ("/Users/", "/private/tmp/", "/home/")):
        raise GoldenEvidenceError("golden result contains a local path")
    return value
