"""Single source of truth for the successful DCP-03 proof contract."""

from __future__ import annotations

RESULT_SCHEMA_VERSION = 4
ANALYSIS_LEVEL = "native-sleigh-effective-load-image-darwin-register-dataflow-proof"
CONTRACT_COMPLETENESS = "partial-dcp03"

ENGINE_BACKEND_ID = "pypcode-native-sleigh"
ENGINE_COMPONENT_ID = "pypcode-dcp03-proof"
ENGINE_VERSION = "4.0.0"
ENGINE_GIT_REVISION = "2787546a83b42a62dde3a1905deea8b0906e85b5"
ENGINE_LANGUAGE_ALLOWLIST = frozenset({
    "AARCH64:LE:64:AppleSilicon",
    "AARCH64:LE:64:v8A",
})
ENGINE_MINIMUM_RESOURCE_COUNT = 5

CAPABILITY_TRUTH: dict[str, bool] = {
    "instructionDecoding": True,
    "pcodeLifting": True,
    "basicBlockRecovery": True,
    "directCallRecovery": True,
    "imageQualifiedSourceRanges": True,
    "symbolInjection": True,
    "storageHeritage": True,
    "exactStorageSSA": True,
    "memorySSA": True,
    "aarch64GprAliasRecovery": True,
    "aarch64GprSSA": True,
    "darwinAapcs64BaseCallEffects": True,
    "callRegisterInputs": True,
    "relocationApplication": True,
    "aarch64MachORelocationApplication": True,
    "dyldChainedPointerNormalization": True,
    "decompilerHeritage": False,
    "registerSSA": False,
    "registerAliasRecovery": False,
    "callRegisterClobbers": True,
    "recoveredVariables": False,
    "genericTypeRecovery": False,
    "controlFlowStructuring": False,
    "tokenizedPseudocode": False,
}

ANALYSIS_SEMANTICS: dict[str, str] = {
    "heritageOrigin": "macscope-raw-pcode",
    "storageIdentity": "space-offset-size-scope",
    "registerAliasModel": "aarch64-gpr-x-w-zero-extend",
    "registerSsaModel": "canonical-64-bit-gpr-only",
    "simdRegisterSsaModel": "none",
    "phiPlacement": "backward-liveness-multi-input",
    "temporaryScope": "instruction",
    "memoryPartitionModel": "single-unknown",
    "memoryCallModel": "all-memory-clobber",
    "callRegisterInputModel": "darwin-aapcs64-unknown-prototype-x0-x8-x30-sp-v0-v7",
    "callRegisterClobberModel": "darwin-aapcs64-base-x0-x18-x30-v0-v31-nzcv",
    "callExcludedStateModel": "sve-sme-fpsr-fpcr-fpmr-system-registers",
    "loadImageAuthority": "caller-supplied-memory-regions",
    "relocationApplicationModel": "bounded-mach-o-arm64-subset-fail-closed",
    "fixupApplicationModel": (
        "dyld-chained-pointer-normalization-preserve-authentication-evidence"
    ),
    "proofLevel": "conservative",
}


def expected_warnings(
    *,
    unmapped_address_metadata_count: int,
    authenticated_pointer_patch_count: int,
) -> list[dict[str, str]]:
    """Return the exact deterministic warning contract for one result."""

    warnings = [
        {
            "code": "capability.decompiler_heritage_unavailable",
            "message": (
                "Heritage is derived by MacScope from raw SLEIGH p-code; "
                "Ghidra decompiler heritage is not available."
            ),
        },
        {
            "code": "capability.complete_register_ssa_unavailable",
            "message": (
                "Canonical SSA is available for AArch64 general-purpose x/w and "
                "sp/wsp aliases only; SIMD and condition-flag SSA remain unavailable."
            ),
        },
        {
            "code": "capability.type_recovery_unavailable",
            "message": (
                "Type hints are preserved as evidence but are not applied by this "
                "proof backend."
            ),
        },
        {
            "code": "capability.high_level_output_unavailable",
            "message": (
                "Control-flow structuring, recovered variables, HIR, and pseudocode "
                "are intentionally unavailable."
            ),
        },
        {
            "code": "capability.relocation_subset_only",
            "message": (
                "Only the closed DCP-03B2 AArch64 Mach-O relocation subset is applied; "
                "unsupported metadata in mapped memory fails closed."
            ),
        },
    ]
    if unmapped_address_metadata_count:
        warnings.append(
            {
                "code": "input.unmapped_address_metadata_preserved",
                "message": (
                    "Relocation or fixup records outside caller-supplied memory were "
                    "preserved as unmapped evidence and not applied."
                ),
            }
        )
    if authenticated_pointer_patch_count:
        warnings.append(
            {
                "code": "input.authenticated_pointer_normalized",
                "message": (
                    "Authenticated chained pointers were normalized to unsigned target "
                    "addresses while authentication evidence was preserved."
                ),
            }
        )
    return warnings
