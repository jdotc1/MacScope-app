"""Frozen DCP-03B3 pilot contract and dependency identity.

The package version and the embedded local-service protocol version are
intentionally separate. libghidra v0.0.2 reports local service version 1.0.0.
The v0.0.2 local backend provides address-driven pseudocode, function records,
and instruction records. Token/local records are not populated by the qualified
path. Basic-block and CFG APIs are deliberately outside this pilot because they
have not passed the same source-fidelity and determinism qualification.
"""

from __future__ import annotations

from dataclasses import dataclass

RESULT_SCHEMA_VERSION = 2
ANALYSIS_LEVEL = "libghidra-native-effective-image-pseudocode-instruction-pilot"
CONTRACT_COMPLETENESS = "partial-dcp03b3"

ENGINE_BACKEND_ID = "libghidra-local-native"
ENGINE_COMPONENT_ID = "libghidra-dcp03b3-pilot"
ENGINE_VERSION = "0.0.2"
ENGINE_GIT_REVISION = "61b37fa2d99aa5cf0da450b84f2abd797fb6a27c"
ENGINE_SERVICE_NAME = "local-decompiler"
ENGINE_SERVICE_VERSION = "1.0.0"
ENGINE_LANGUAGE_ID = "AARCH64:LE:64:v8A"
ENGINE_COMPILER_SPEC_ID = "default"
ENGINE_FORMAT = "macho"
ENGINE_HOST_MODE = "local"
ENGINE_RELEASE_BASE = "https://github.com/0xeb/libghidra/releases/download/v0.0.2"


@dataclass(frozen=True)
class ApprovedWheel:
    filename: str
    sha256: str
    platform: str

    @property
    def url(self) -> str:
        return f"{ENGINE_RELEASE_BASE}/{self.filename}"


MACOS_ARM64_WHEEL = "libghidra-0.0.2-cp312-abi3-macosx_15_0_arm64.whl"
MACOS_ARM64_WHEEL_SHA256 = "c96f2266c66d16302b917ce2645d5ba08ca90bac30f44d957a7e16ad40d40fee"
LINUX_X86_64_WHEEL = (
    "libghidra-0.0.2-cp312-abi3-manylinux_2_27_x86_64."
    "manylinux_2_28_x86_64.whl"
)
LINUX_X86_64_WHEEL_SHA256 = "aeb32952ad1ba30f87d480c3ab56eb0346f199470c2584ebe67e05d03d4e6c78"

APPROVED_WHEELS: dict[str, ApprovedWheel] = {
    MACOS_ARM64_WHEEL: ApprovedWheel(
        filename=MACOS_ARM64_WHEEL,
        sha256=MACOS_ARM64_WHEEL_SHA256,
        platform="macosx_15_0_arm64",
    ),
    LINUX_X86_64_WHEEL: ApprovedWheel(
        filename=LINUX_X86_64_WHEEL,
        sha256=LINUX_X86_64_WHEEL_SHA256,
        platform="manylinux_2_28_x86_64",
    ),
}
ALLOWED_WHEEL_SHA256 = frozenset(item.sha256 for item in APPROVED_WHEELS.values())

REQUIRED_NATIVE_CAPABILITIES: dict[str, str] = {
    "health": "supported",
    "session": "supported",
    "decompiler": "supported",
    "functions": "supported",
    "listing": "supported",
}

MAX_MATERIALIZATION_BYTES = 64 * 1024
MAX_PSEUDOCODE_BYTES = 4 * 1024 * 1024
MAX_INSTRUCTION_COUNT = 1_000_000
MAX_CAPABILITY_COUNT = 512
MAX_TEXT = 16 * 1024
MAX_SHORT_TEXT = 1024
MAX_CARRIER_BYTES = 300 * 1024 * 1024
MAX_CARRIER_SECTIONS = 255

# A true value means a validated result from this exact tranche proves the
# capability. Long-term bridge fields may exist while their capability remains
# false. Rendered C is never reparsed to manufacture semantic records.
CAPABILITY_TRUTH: dict[str, bool] = {
    "nativeGhidraDecompiler": True,
    "callerOwnedByteCarrier": True,
    "effectiveLoadImageCarrier": True,
    "deterministicMachOCarrier": True,
    "carrierSymbolTable": True,
    "nativeFunctionRecord": True,
    "decompiledPseudocode": True,
    "structuredInstructions": True,
    "imageQualifiedFunctionSourceRange": True,
    "imageQualifiedInstructionSourceRanges": True,
    "tokenizedPseudocode": False,
    "recoveredVariables": False,
    "surfaceTypeCandidates": False,
    "nativeBasicBlocks": False,
    "nativeCFGEdges": False,
    "imageQualifiedBasicBlockAddresses": False,
    "imageQualifiedBasicBlockSourceRanges": False,
    "imageQualifiedTokenSourceRanges": False,
    "nativeHeritageExport": False,
    "nativeSSAExport": False,
    "nativeMemorySSAExport": False,
    "structuredRegions": False,
    "structuredCallSites": False,
    "completeTypeRecovery": False,
    "typeHintInjection": False,
    "relocationApplication": True,
    "aarch64MachORelocationApplication": True,
    "fixupApplication": True,
    "dyldChainedPointerNormalization": True,
    "macIR2Import": False,
    "signedXPCIntegration": False,
    "applicationIntegration": False,
}

ANALYSIS_SEMANTICS: dict[str, str] = {
    "binaryAuthority": "caller-owned-memory-regions",
    "effectiveByteModel": "dcp03b2-bounded-relocation-fixup-view",
    "carrierModel": "deterministic-thin-macho64-arm64-effective-bytes-without-entrypoint-claim",
    "semanticImport": "structured-libghidra-function-and-instruction-records-only",
    "pseudocodeRole": "presentation-not-semantic-input",
    "instructionModel": "address-driven-native-listing-bound-to-effective-bytes",
    "tokenModel": "unavailable-libghidra-v0.0.2-local-client",
    "variableModel": "unavailable-libghidra-v0.0.2-local-client",
    "typeCandidateModel": "unavailable-without-structured-type-records",
    "cfgModel": "not-accepted-in-dcp03b3-address-driven-contract",
    "timeoutModel": "external-supervisor-hard-deadline",
    "proofLevel": "shadow-pilot",
}
