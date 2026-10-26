"""Closed command vocabulary and live Gate F command templates.

Every executable vector names an entrypoint that exists in the repository at
the frozen Lane A source.  Operations with no canonical automation surface are
represented as ``executor-required`` with an empty argv; no imaginary helper is
introduced to make the plan look complete.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, replace
from enum import Enum
from types import MappingProxyType

from Scripts.reconstruction.installed_matrix_receipt import PRESENTATION_VARIANTS

from .schema import EvidenceLayer

COMMAND_SCHEMA_VERSION = 2

REQUIRED_RECEIPT_BINDING_FIELDS = (
    "candidate_identity_sha256",
    "command_id",
    "command_plan_sha256",
    "command_record_sha256",
    "evidence_layer",
    "execution_interval",
)


class CampaignProfile(str, Enum):
    EXISTING = "existing-command-campaign-v1"
    BOOTSTRAP_VERIFIER = "bootstrap-verifier-campaign-v1"


BOOTSTRAP_COMMAND_SUBSTITUTIONS: Mapping[str, str] = MappingProxyType({
    "xcode.full-coretests": "qualification.verify-bootstrap-fullsuite",
    "release.build": "qualification.verify-bootstrap-products",
})
BOOTSTRAP_STATIC_INPUT_NAMES = frozenset({
    "bootstrap_artifact_root", "bootstrap_admission_path",
    "bootstrap_fullsuite_artifact_root", "bootstrap_products_artifact_root",
})
INSTALLED_CAPTURE_COMMANDS = frozenset({
    "install.release-to-applications",
    "signing.strict-release", "installed.source-equality", "installed.shell-smoke",
    "installed.xcuitest-preflight", "installed.emit-report",
})
def installed_gate_output_slots():
    # Bootstrap-only lazy import avoids the installer's receipt/catalogue cycle.
    from Scripts.reconstruction.install_release_to_applications import REQUIRED_ACCEPTANCE_GATES
    gates = REQUIRED_ACCEPTANCE_GATES
    if type(gates) is not tuple or len(gates) != 8 or gates != tuple(sorted(set(gates))):
        raise RuntimeError("installer acceptance gate declaration is not a closed eight-gate tuple")
    return tuple((gate, "installed_acceptance_" + gate.replace("-", "_") + "_output") for gate in gates)


def campaign_command_id(command_id: str, *, profile: CampaignProfile = CampaignProfile.EXISTING) -> str:
    if type(profile) is not CampaignProfile:
        raise ValueError("campaign profile must be an explicit CampaignProfile")
    return (BOOTSTRAP_COMMAND_SUBSTITUTIONS.get(command_id, command_id)
            if profile is CampaignProfile.BOOTSTRAP_VERIFIER else command_id)


def campaign_profile_for_inputs(inputs: Mapping[str, str]) -> CampaignProfile:
    """Select only from an independently admitted complete static input mapping.

    Consumers with an explicit operator profile must additionally assert equality.
    Receipt/report contents and command IDs are never profile selectors.
    """
    present = BOOTSTRAP_STATIC_INPUT_NAMES.intersection(inputs)
    if present and present != BOOTSTRAP_STATIC_INPUT_NAMES:
        raise ValueError("bootstrap profile inputs must contain the complete four-path set")
    return CampaignProfile.BOOTSTRAP_VERIFIER if present else CampaignProfile.EXISTING


class CommandExecutionMode(str, Enum):
    RUNNABLE = "runnable"
    VECTOR_ONLY = "vector-only"
    EXECUTOR_REQUIRED = "executor-required"


class CommandHost(str, Enum):
    HOST_INDEPENDENT = "host-independent"
    MACOS_ARM64_XCODE27 = "macos-arm64-xcode27"
    MACOS_ARM64_XCODE27_TCC = "macos-arm64-xcode27-tcc"
    INDEPENDENT_REVIEWER = "independent-reviewer"
    MERGE_AUTHORITY = "merge-authority"


class CommandMutationState(str, Enum):
    READ_ONLY = "read-only"
    BUILD_OUTPUT = "build-output"
    INSTALL_STATE = "install-state"
    GIT_STATE = "git-state"


@dataclass(frozen=True, order=True)
class ExpectedExit:
    code: int
    classification: str


DEFAULT_EXPECTED_EXITS = (
    ExpectedExit(0, "passed"),
    ExpectedExit(1, "qualification-failed"),
    ExpectedExit(2, "usage-or-input-invalid"),
)
XCODE_EXPECTED_EXITS = DEFAULT_EXPECTED_EXITS + (
    ExpectedExit(65, "xcode-build-or-test-failed"),
)

INSTALLED_ACCESSIBILITY_SCREENSHOT_OUTPUTS = tuple(
    "stdout-path:MACSCOPE_INSTALLED_ACCESSIBILITY_SCREENSHOT_"
    + "_".join(
        part.upper().replace("-", "_")
        for part in (presentation_state, appearance, window_size)
    )
    for presentation_state, appearance, window_size, _width, _height
    in PRESENTATION_VARIANTS
)
CTEST_EXPECTED_EXITS = DEFAULT_EXPECTED_EXITS + (
    ExpectedExit(8, "ctest-failed"),
)


@dataclass(frozen=True)
class CommandTemplate:
    schema_version: int
    command_id: str
    command_groups: tuple[str, ...]
    argv: tuple[str, ...]
    working_directory: str
    environment: tuple[tuple[str, str], ...]
    host: CommandHost
    evidence_layer: EvidenceLayer
    prerequisite_ids: tuple[str, ...]
    expected_exits: tuple[ExpectedExit, ...]
    timeout_seconds: int
    generated_artifacts: tuple[str, ...]
    generated_logs: tuple[str, ...]
    receipt_fields: tuple[str, ...]
    mutation_state: CommandMutationState
    cleanup_rollback: tuple[str, ...]
    stop_on_failure: bool
    execution_mode: CommandExecutionMode
    unavailability_reason: str | None


def _template(
    command_id: str,
    groups: tuple[str, ...],
    argv: tuple[str, ...],
    *,
    layer: EvidenceLayer,
    host: CommandHost = CommandHost.MACOS_ARM64_XCODE27,
    environment: tuple[tuple[str, str], ...] = (),
    prerequisites: tuple[str, ...] = ("candidate-identity-accepted",),
    timeout: int = 900,
    artifacts: tuple[str, ...] = (),
    logs: tuple[str, ...] = (),
    receipt_fields: tuple[str, ...] = REQUIRED_RECEIPT_BINDING_FIELDS,
    mutation: CommandMutationState = CommandMutationState.READ_ONLY,
    cleanup: tuple[str, ...] = (),
    mode: CommandExecutionMode = CommandExecutionMode.VECTOR_ONLY,
    unavailable: str | None = None,
    expected_exits: tuple[ExpectedExit, ...] = DEFAULT_EXPECTED_EXITS,
) -> CommandTemplate:
    return CommandTemplate(
        schema_version=COMMAND_SCHEMA_VERSION,
        command_id=command_id,
        command_groups=tuple(sorted(set(groups))),
        argv=argv,
        working_directory="@repository_root@",
        environment=tuple(sorted(environment)),
        host=host,
        evidence_layer=layer,
        prerequisite_ids=tuple(sorted(set(prerequisites))),
        expected_exits=tuple(sorted(set(expected_exits))),
        timeout_seconds=timeout,
        generated_artifacts=tuple(sorted(set(artifacts))),
        generated_logs=tuple(sorted(set(logs))),
        receipt_fields=tuple(sorted(set(receipt_fields))),
        mutation_state=mutation,
        cleanup_rollback=cleanup,
        stop_on_failure=True,
        execution_mode=mode,
        unavailability_reason=unavailable,
    )


def _qualifier(
    command_id: str,
    groups: tuple[str, ...],
    mode: str,
    *,
    selector: str | None = None,
    layer: EvidenceLayer = EvidenceLayer.XCODE_FOCUSED,
    timeout: int = 3_600,
    signing: str = "development",
    artifacts: tuple[str, ...] = ("stdout-path:MACSCOPE_QUALIFICATION_RECEIPT",),
) -> CommandTemplate:
    argv = [
        "./Scripts/qualify_local_private_build.sh",
        "--source-root",
        "@repository_root@",
        "--work-root",
        "@qualification_work_root@",
        "--dependency-cache-root",
        "@dependency_cache_root@",
        "--mode",
        mode,
    ]
    if selector is not None:
        argv.extend(("--only-testing", selector))
    if mode == "focused-test":
        artifacts = (*artifacts, "stdout-path:MACSCOPE_TEST_RESULTS")
    argv.extend(("--signing", signing, "--integration-ref", "@integration_ref@"))
    return _template(
        command_id,
        groups,
        tuple(argv),
        layer=layer,
        timeout=timeout,
        artifacts=artifacts,
        logs=("executor-captured:qualification-stdout-stderr",),
        mutation=CommandMutationState.BUILD_OUTPUT,
        cleanup=("Preserve the sealed receipt and result bundle; remove only executor-owned work roots after receipt validation.",),
        mode=CommandExecutionMode.RUNNABLE,
        expected_exits=XCODE_EXPECTED_EXITS,
    )


def _executor_required(
    command_id: str,
    groups: tuple[str, ...],
    *,
    layer: EvidenceLayer,
    host: CommandHost,
    reason: str,
    mutation: CommandMutationState = CommandMutationState.READ_ONLY,
    artifacts: tuple[str, ...] = (),
    logs: tuple[str, ...] = (),
) -> CommandTemplate:
    return _template(
        command_id,
        groups,
        (),
        layer=layer,
        host=host,
        timeout=1,
        mode=CommandExecutionMode.EXECUTOR_REQUIRED,
        unavailable=reason,
        mutation=mutation,
        artifacts=artifacts,
        logs=logs,
        cleanup=("Follow the executor-owned rollback recorded in the resulting receipt.",),
    )


_FOCUSED_COMMAND_IDS = (
    "xcode.focused.batch-scheduler",
    "xcode.focused.crash-resume",
    "xcode.focused.initial-transaction",
    "xcode.focused.installed-contracts",
    "xcode.focused.model-rounds",
    "xcode.focused.provider-cancellation-race",
    "xcode.focused.provider-pool",
    "xcode.focused.session-resolver",
    "xcode.focused.task10-projection",
    "xcode.focused.task10-state-machine",
    "xcode.focused.task8-bundle",
    "xcode.focused.task8-handler",
    "xcode.focused.task8-wire",
    "xcode.focused.workspace-database",
)

INDEPENDENT_REVIEW_COMMAND_LENSES: Mapping[str, str] = MappingProxyType(
    {
        "review.independent.ai-protocol-signed-xpc": "ai-protocol-signed-xpc",
        "review.independent.corpus-package-persistence": "corpus-package-persistence",
        "review.independent.evidence-retrieval-scheduling": "evidence-retrieval-scheduling",
        "review.independent.scope-installed-ui-governance": "scope-installed-ui-governance",
    }
)

_INDEPENDENT_REVIEW_PREREQUISITES = (
    "evidence.t10c-current-source-adjudication",
    "installed.emit-report",
    "native.golden",
    "reconstruction.deterministic-evidence",
    "release.build",
    "signed-xpc.complete-truncated-content",
    "signed-xpc.error-cancellation",
    "signed-xpc.supervision",
    "source.hosted-governance",
    "stress.reconstruction-authority-races",
    "task8.signed-worker-parity",
    "xcode.full-coretests",
)

COMMAND_PREREQUISITES: dict[str, tuple[str, ...]] = {
    "source.create-sealed-export": ("candidate-identity-accepted",),
    "source.verify-sealed-export": ("source.create-sealed-export",),
    "source.hosted-governance": ("source.verify-sealed-export",),
    "xcode.smoke": ("source.hosted-governance",),
    **{command_id: ("xcode.smoke",) for command_id in _FOCUSED_COMMAND_IDS},
    "xcode.full-coretests": _FOCUSED_COMMAND_IDS,
    "reconstruction.deterministic-evidence": ("xcode.full-coretests",),
    "native.normal": ("source.hosted-governance",),
    "native.asan": ("native.normal",),
    "native.ubsan": ("native.normal",),
    "native.golden": ("native.asan", "native.normal", "native.ubsan"),
    "task8.signed-worker-parity": (
        "xcode.focused.task8-bundle",
        "xcode.focused.task8-handler",
        "xcode.focused.task8-wire",
    ),
    "signed-xpc.supervision": ("native.golden", "xcode.full-coretests"),
    "signed-xpc.complete-truncated-content": (
        "native.golden",
        "xcode.full-coretests",
    ),
    "signed-xpc.error-cancellation": ("native.golden", "xcode.full-coretests"),
    "release.build": (
        "native.golden",
        "signed-xpc.complete-truncated-content",
        "signed-xpc.error-cancellation",
        "signed-xpc.supervision",
        "task8.signed-worker-parity",
        "xcode.full-coretests",
    ),
    "signing.strict-release": ("release.build",),
    "install.release-to-applications": ("signing.strict-release",),
    "installed.source-equality": ("install.release-to-applications",),
    "installed.shell-smoke": ("installed.source-equality",),
    "installed.xcuitest-preflight": ("install.release-to-applications",),
    "installed.task10-workflow": (
        "installed.source-equality",
        "installed.xcuitest-preflight",
    ),
    "installed.accessibility-semantics": (
        "installed.task10-workflow",
    ),
    "installed.emit-report": (
        "installed.accessibility-semantics",
        "installed.shell-smoke",
        "installed.source-equality",
        "installed.task10-workflow",
    ),
    "stress.reconstruction-authority-races": ("xcode.full-coretests",),
    "evidence.t10c-current-source-adjudication": (
        "xcode.focused.task10-projection",
        "xcode.focused.task10-state-machine",
        "xcode.full-coretests",
    ),
    **{
        command_id: _INDEPENDENT_REVIEW_PREREQUISITES
        for command_id in INDEPENDENT_REVIEW_COMMAND_LENSES
    },
    "review.independent": tuple(INDEPENDENT_REVIEW_COMMAND_LENSES),
    "merge.prospective-tree": ("review.independent",),
    "postmerge.exact-tree-proof": ("merge.prospective-tree",),
}

# A runnable signed-XPC command is not interchangeable with another candidate
# executable merely because both are signed.  Keep the expected service in the
# command catalog, alongside the command vector it qualifies.
SIGNED_XPC_SERVICE_IDENTITIES: dict[str, str] = {
    "signed-xpc.complete-truncated-content": "native-decompiler",
    "signed-xpc.error-cancellation": "native-decompiler",
    "signed-xpc.supervision": "native-decompiler",
    "task8.signed-worker-parity": "ai-agent-worker",
}


def command_templates(*, profile: CampaignProfile = CampaignProfile.EXISTING) -> tuple[CommandTemplate, ...]:
    """Return the exact stable command catalog, sorted by command ID."""

    campaign_command_id("", profile=profile)
    templates = [
        _template(
            "source.create-sealed-export",
            ("source-governance",),
            (
                "/usr/bin/python3",
                "-B",
                "Scripts/source_export_provenance.py",
                "create",
                "--repository-root",
                "@repository_root@",
                "--destination",
                "@source_export_root@",
                "--integration-ref",
                "@integration_ref@",
            ),
            layer=EvidenceLayer.SOURCE_GOVERNANCE,
            host=CommandHost.HOST_INDEPENDENT,
            timeout=300,
            artifacts=(
                "@source_export_root@/SOURCE_PROVENANCE.json",
                "@source_export_root@/SOURCE_FILES.json",
            ),
            logs=("executor-captured:source-export-create-stdout-stderr",),
            mutation=CommandMutationState.BUILD_OUTPUT,
            cleanup=("Remove only the executor-owned source export after every declared artifact and receipt has been hashed.",),
            mode=CommandExecutionMode.RUNNABLE,
        ),
        _template(
            "source.verify-sealed-export",
            ("source-governance",),
            (
                "/usr/bin/python3",
                "-B",
                "Scripts/source_export_provenance.py",
                "verify",
                "--source-root",
                "@source_export_root@",
            ),
            layer=EvidenceLayer.SOURCE_GOVERNANCE,
            host=CommandHost.HOST_INDEPENDENT,
            timeout=300,
            artifacts=(
                "@source_export_root@/SOURCE_PROVENANCE.json",
                "@source_export_root@/SOURCE_FILES.json",
            ),
            logs=("executor-captured:source-export-verify-stdout-stderr",),
            mode=CommandExecutionMode.RUNNABLE,
        ),
        _template(
            "source.hosted-governance",
            ("source-governance",),
            (
                "/usr/bin/python3",
                "-B",
                "@hosted_governance_runner@",
                "--candidate-identity",
                "@candidate_identity_path@",
                "--source-root",
                "@source_export_root@",
                "--test-results-output",
                "@hosted_governance_test_results@",
                "--execution-report-output",
                "@hosted_governance_execution_report@",
                "--qualification-run-id",
                "@qualification_run_id@",
                "--qualification-run-nonce",
                "@qualification_run_nonce@",
                "--predecessor-observations-sha256",
                "@hosted_governance_predecessor_observations_sha256@",
            ),
            layer=EvidenceLayer.HOSTED_PURE,
            host=CommandHost.HOST_INDEPENDENT,
            timeout=300,
            artifacts=(
                "stdout-path:MACSCOPE_EXECUTION_REPORT",
                "stdout-path:MACSCOPE_TEST_RESULTS",
            ),
            logs=("executor-captured:hosted-governance-stdout-stderr",),
            mode=CommandExecutionMode.RUNNABLE,
        ),
        _qualifier(
            "xcode.smoke",
            ("source-governance",),
            "smoke",
            layer=EvidenceLayer.XCODE_FOCUSED,
            timeout=3_600,
        ),
        _qualifier(
            "xcode.focused.provider-pool",
            ("reconstruction-concurrency",),
            "focused-test",
            selector="CoreTests/ReconstructionAnalysisProviderPoolTests",
        ),
        _qualifier(
            "xcode.focused.provider-cancellation-race",
            ("reconstruction-concurrency",),
            "focused-test",
            selector="CoreTests/ReconstructionProviderPoolCancellationRaceTests",
        ),
        _qualifier(
            "xcode.focused.batch-scheduler",
            ("reconstruction-concurrency",),
            "focused-test",
            selector="CoreTests/ReconstructionBatchSchedulerTests",
        ),
        _qualifier(
            "xcode.focused.session-resolver",
            ("reconstruction-session", "reconstruction-concurrency"),
            "focused-test",
            selector="CoreTests/ReconstructionDestinationSessionResolverTests",
        ),
        _qualifier(
            "xcode.focused.initial-transaction",
            ("reconstruction-persistence",),
            "focused-test",
            selector="CoreTests/ReconstructionInitialJobTransactionTests",
        ),
        _qualifier(
            "xcode.focused.crash-resume",
            ("reconstruction-persistence",),
            "focused-test",
            selector="CoreTests/ReconstructionCrashResumeTests",
        ),
        _qualifier(
            "xcode.focused.workspace-database",
            ("reconstruction-persistence",),
            "focused-test",
            selector="CoreTests/ReconstructionWorkspaceDatabaseTests",
        ),
        _qualifier(
            "xcode.focused.model-rounds",
            ("reconstruction-rounds",),
            "focused-test",
            selector="CoreTests/ReconstructionModelRoundSchedulerTests",
        ),
        _qualifier(
            "xcode.focused.task8-wire",
            ("reconstruction-task8",),
            "focused-test",
            selector="CoreTests/ReconstructionAIWorkerWireTests",
        ),
        _qualifier(
            "xcode.focused.task8-handler",
            ("reconstruction-task8",),
            "focused-test",
            selector="CoreTests/ReconstructionAIWorkerHandlerTests",
        ),
        _qualifier(
            "xcode.focused.task8-bundle",
            ("reconstruction-task8",),
            "focused-test",
            selector="CoreTests/ReconstructionAIProtocolBundleTests",
        ),
        _qualifier(
            "xcode.focused.task10-projection",
            ("reconstruction-task10",),
            "focused-test",
            selector="CoreTests/ReconstructionStatusProjectionTests",
        ),
        _qualifier(
            "xcode.focused.task10-state-machine",
            ("reconstruction-task10",),
            "focused-test",
            selector="CoreTests/ReconstructionStateMachineTests",
        ),
        _qualifier(
            "xcode.focused.installed-contracts",
            ("installed-equality", "installed-launch", "installed-task10", "installed-accessibility"),
            "focused-test",
            selector="CoreTests/WS24InstalledAppQualificationTests",
        ),
        _qualifier(
            "xcode.full-coretests",
            (
                "reconstruction-concurrency",
                "reconstruction-session",
                "reconstruction-persistence",
                "reconstruction-rounds",
                "reconstruction-task8",
                "reconstruction-task10",
                "source-governance",
            ),
            "full-test",
            layer=EvidenceLayer.XCODE_FULL_CORETESTS,
            timeout=7_200,
            artifacts=(
                "stdout-path:MACSCOPE_QUALIFICATION_RECEIPT",
                "stdout-path:MACSCOPE_TEST_RESULTS",
                "stdout-path:MACSCOPE_COVERAGE_JSON",
            ),
        ),
        _qualifier(
            "release.build",
            ("release",),
            "release",
            layer=EvidenceLayer.RELEASE_BUILD,
            timeout=7_200,
            artifacts=(
                "stdout-path:MACSCOPE_QUALIFICATION_RECEIPT",
                "receipt-derived-path:DerivedData/Build/Products/Release/MacScope.app",
                "receipt-derived-path:DerivedData/Build/Products/Release/MacScope.app/Contents/Resources/MacScopeBuildProvenance.json",
            ),
        ),
        _template(
            "reconstruction.deterministic-evidence",
            ("reconstruction-persistence", "reconstruction-rounds"),
            (
                "./Scripts/reconstruction/run_deterministic_evidence_tests.sh",
                "--candidate-identity",
                "@candidate_identity_path@",
                "--preparation-receipt",
                "@native_live_preparation_receipt@",
                "--xctestrun",
                "@native_live_xctestrun@",
                "--candidate-app",
                "@native_live_app@",
                "--result-bundle-root",
                "@deterministic_evidence_result_bundle_root@",
                "--artifact-root",
                "@deterministic_evidence_artifact_root@",
                "--qualification-run-id",
                "@qualification_run_id@",
                "--qualification-run-nonce",
                "@qualification_run_nonce@",
                "--predecessor-observations-sha256",
                "@deterministic_evidence_predecessor_observations_sha256@",
            ),
            layer=EvidenceLayer.XCODE_FOCUSED,
            host=CommandHost.MACOS_ARM64_XCODE27,
            timeout=900,
            artifacts=(
                "stdout-path:MACSCOPE_DETERMINISTIC_EVIDENCE_CHECKPOINT",
                "stdout-path:MACSCOPE_DETERMINISTIC_EVIDENCE_CHECKPOINT_TWO",
                "stdout-path:MACSCOPE_DETERMINISTIC_EVIDENCE_COMPARISON",
                "stdout-path:MACSCOPE_DETERMINISTIC_EVIDENCE_CORPUS",
                "stdout-path:MACSCOPE_DETERMINISTIC_EVIDENCE_CORPUS_TWO",
                "stdout-path:MACSCOPE_DETERMINISTIC_EVIDENCE_EXECUTION_REPORT",
                "stdout-path:MACSCOPE_DETERMINISTIC_EVIDENCE_FRONTIER",
                "stdout-path:MACSCOPE_DETERMINISTIC_EVIDENCE_FRONTIER_TWO",
                "stdout-path:MACSCOPE_DETERMINISTIC_EVIDENCE_RECEIPT",
                "stdout-path:MACSCOPE_DETERMINISTIC_EVIDENCE_RECEIPT_TWO",
                "stdout-path:MACSCOPE_DETERMINISTIC_EVIDENCE_RETRIEVAL_PACKET",
                "stdout-path:MACSCOPE_DETERMINISTIC_EVIDENCE_RETRIEVAL_PACKET_TWO",
                "stdout-path:MACSCOPE_DETERMINISTIC_EVIDENCE_TEST_RESULTS_ONE",
                "stdout-path:MACSCOPE_DETERMINISTIC_EVIDENCE_TEST_RESULTS_TWO",
            ),
            logs=("executor-captured:deterministic-evidence-stdout-stderr",),
            mutation=CommandMutationState.BUILD_OUTPUT,
            cleanup=(
                "Preserve both fresh-process result bundles, exact artifact sets, comparison manifest, and execution report until receipt validation completes.",
            ),
            mode=CommandExecutionMode.RUNNABLE,
            expected_exits=XCODE_EXPECTED_EXITS,
        ),
        _template(
            "native.normal",
            ("native-normal",),
            (
                "./Scripts/native-decompiler-xpc/build_native_bridge.sh",
                "--source-root",
                "@native_source_root@",
                "--build-root",
                "@native_build_root@",
                "--materialization-root",
                "@sleigh_materialization_root@",
                "--wrapper-revision",
                "@native_wrapper_revision@",
                "--configuration",
                "Release",
            ),
            layer=EvidenceLayer.NATIVE_NORMAL,
            timeout=7_200,
            artifacts=("@native_build_root@/libmacscope_native_decompiler_contract.a",),
            logs=("@output_root@/native-normal.log",),
            mutation=CommandMutationState.BUILD_OUTPUT,
            cleanup=("Remove only the executor-owned native build root after hashing all declared artifacts.",),
            expected_exits=CTEST_EXPECTED_EXITS,
        ),
        _template(
            "native.asan",
            ("native-asan",),
            (
                "./Scripts/native-decompiler-xpc/run_native_bridge_sanitizers.sh",
                "--source-root",
                "@native_source_root@",
                "--build-root",
                "@native_sanitizer_build_root@",
                "--sanitizer",
                "address",
                "--materialization-root",
                "@sleigh_materialization_root@",
            ),
            layer=EvidenceLayer.NATIVE_ASAN,
            environment=(("ASAN_OPTIONS", "detect_leaks=0:halt_on_error=1:abort_on_error=1"),),
            timeout=7_200,
            logs=("executor-captured:native-asan-stdout-stderr",),
            mutation=CommandMutationState.BUILD_OUTPUT,
            cleanup=("Remove only the executor-owned address-sanitizer build root after report validation.",),
            expected_exits=CTEST_EXPECTED_EXITS,
        ),
        _template(
            "native.ubsan",
            ("native-ubsan",),
            (
                "./Scripts/native-decompiler-xpc/run_native_bridge_sanitizers.sh",
                "--source-root",
                "@native_source_root@",
                "--build-root",
                "@native_sanitizer_build_root@",
                "--sanitizer",
                "undefined",
                "--materialization-root",
                "@sleigh_materialization_root@",
            ),
            layer=EvidenceLayer.NATIVE_UBSAN,
            environment=(("UBSAN_OPTIONS", "halt_on_error=1:print_stacktrace=1"),),
            timeout=7_200,
            logs=("executor-captured:native-ubsan-stdout-stderr",),
            mutation=CommandMutationState.BUILD_OUTPUT,
            cleanup=("Remove only the executor-owned undefined-sanitizer build root after report validation.",),
            expected_exits=CTEST_EXPECTED_EXITS,
        ),
        _template(
            "native.golden",
            ("native-golden",),
            (
                "./Scripts/native-decompiler-xpc/run_native_bridge_golden.sh",
                "--build-root",
                "@native_golden_build_root@",
                "--materialization-root",
                "@sleigh_materialization_root@",
                "--native-archive-root",
                "@native_build_root@",
                "--stage-stamp",
                "@native_stage_stamp@",
                "--developer-dir",
                "@developer_dir@",
                "--sdk-root",
                "@sdk_root@",
                "--sdk-name",
                "@sdk_name@",
                "--target-build-dir",
                "@target_build_dir@",
                "--project-temp-dir",
                "@project_temp_dir@",
                "--result",
                "@native_golden_result@",
            ),
            layer=EvidenceLayer.NATIVE_NORMAL,
            timeout=7_200,
            artifacts=("@native_golden_result@",),
            logs=("@output_root@/native-golden.log",),
            mutation=CommandMutationState.BUILD_OUTPUT,
            cleanup=("Remove only executor-owned golden temporaries after the governed result is hashed.",),
        ),
        _template(
            "signed-xpc.supervision",
            ("signed-xpc-supervision",),
            (
                "./Scripts/native-decompiler-xpc/run_live_xpc_tests.sh",
                "--execute-prepared",
                "--preparation-receipt",
                "@native_live_preparation_receipt@",
                "--xctestrun",
                "@native_live_xctestrun@",
                "--candidate-app",
                "@native_live_app@",
                "--only-testing",
                "CoreTests/NativeDecompilerLiveXPCTests/testSignedServiceHonorsSupervisionAndRelaunchContract",
                "--candidate-identity",
                "@candidate_identity_path@",
                "--result-bundle-path",
                "@signed_xpc_supervision_result_bundle@",
                "--artifact-root",
                "@signed_xpc_supervision_artifact_root@",
                "--qualification-run-id",
                "@qualification_run_id@",
                "--qualification-run-nonce",
                "@qualification_run_nonce@",
                "--predecessor-observations-sha256",
                "@signed_xpc_supervision_predecessor_observations_sha256@",
            ),
            layer=EvidenceLayer.SIGNED_XPC,
            timeout=3_600,
            artifacts=(
                "stdout-path:MACSCOPE_SIGNED_NATIVE_EXECUTABLE",
                "stdout-path:MACSCOPE_SIGNED_NATIVE_EXECUTION_REPORT",
                "stdout-path:MACSCOPE_SIGNED_NATIVE_TEST_RESULTS",
            ),
            logs=("executor-captured:signed-xpc-stdout-stderr",),
            mutation=CommandMutationState.BUILD_OUTPUT,
            cleanup=("Preserve the prepared native-live product, ordinary signed-native artifacts, and result bundle until receipt validation completes.",),
            mode=CommandExecutionMode.RUNNABLE,
            expected_exits=XCODE_EXPECTED_EXITS,
        ),
        _template(
            "task8.signed-worker-parity",
            ("task8-signed-worker",),
            (
                "./Scripts/reconstruction/run_signed_reconstruction_worker_tests.sh",
                "--candidate-identity",
                "@candidate_identity_path@",
                "--preparation-receipt",
                "@native_live_preparation_receipt@",
                "--xctestrun",
                "@native_live_xctestrun@",
                "--candidate-app",
                "@native_live_app@",
                "--result-bundle-path",
                "@signed_reconstruction_result_bundle@",
                "--artifact-root",
                "@signed_reconstruction_artifact_root@",
                "--qualification-run-id",
                "@qualification_run_id@",
                "--qualification-run-nonce",
                "@qualification_run_nonce@",
                "--predecessor-observations-sha256",
                "@signed_reconstruction_predecessor_observations_sha256@",
            ),
            layer=EvidenceLayer.SIGNED_XPC,
            host=CommandHost.MACOS_ARM64_XCODE27,
            timeout=600,
            artifacts=(
                "stdout-path:MACSCOPE_SIGNED_RECONSTRUCTION_EXECUTABLE",
                "stdout-path:MACSCOPE_SIGNED_RECONSTRUCTION_EXECUTION_REPORT",
                "stdout-path:MACSCOPE_SIGNED_RECONSTRUCTION_TEST_RESULTS",
            ),
            logs=("executor-captured:signed-reconstruction-worker-stdout-stderr",),
            mutation=CommandMutationState.BUILD_OUTPUT,
            cleanup=("Preserve the ordinary signed-worker artifacts and result bundle; remove only executor-owned roots after receipt validation.",),
            mode=CommandExecutionMode.RUNNABLE,
            expected_exits=XCODE_EXPECTED_EXITS,
        ),
        _template(
            "signed-xpc.complete-truncated-content",
            ("signed-xpc-content",),
            (
                "./Scripts/native-decompiler-xpc/run_live_xpc_tests.sh",
                "--execute-prepared",
                "--preparation-receipt",
                "@native_live_preparation_receipt@",
                "--xctestrun",
                "@native_live_xctestrun@",
                "--candidate-app",
                "@native_live_app@",
                "--only-testing",
                "CoreTests/NativeDecompilerLiveXPCTests/testSignedProviderTokenAndSourceScalarsProjectForCompleteAndTruncatedDocuments",
                "--candidate-identity",
                "@candidate_identity_path@",
                "--result-bundle-path",
                "@signed_xpc_content_result_bundle@",
                "--artifact-root",
                "@signed_xpc_content_artifact_root@",
                "--qualification-run-id",
                "@qualification_run_id@",
                "--qualification-run-nonce",
                "@qualification_run_nonce@",
                "--predecessor-observations-sha256",
                "@signed_xpc_content_predecessor_observations_sha256@",
            ),
            layer=EvidenceLayer.SIGNED_XPC,
            timeout=3_600,
            artifacts=(
                "stdout-path:MACSCOPE_SIGNED_NATIVE_EXECUTABLE",
                "stdout-path:MACSCOPE_SIGNED_NATIVE_EXECUTION_REPORT",
                "stdout-path:MACSCOPE_SIGNED_NATIVE_TEST_RESULTS",
            ),
            logs=("executor-captured:signed-xpc-content-stdout-stderr",),
            mutation=CommandMutationState.BUILD_OUTPUT,
            cleanup=("Preserve the prepared native-live product, ordinary signed-native artifacts, and result bundle until receipt validation completes.",),
            mode=CommandExecutionMode.RUNNABLE,
            expected_exits=XCODE_EXPECTED_EXITS,
        ),
        _template(
            "signed-xpc.error-cancellation",
            ("signed-xpc-error-cancellation",),
            (
                "./Scripts/native-decompiler-xpc/run_live_xpc_tests.sh",
                "--execute-prepared",
                "--preparation-receipt",
                "@native_live_preparation_receipt@",
                "--xctestrun",
                "@native_live_xctestrun@",
                "--candidate-app",
                "@native_live_app@",
                "--only-testing",
                "CoreTests/NativeDecompilerLiveXPCTests/testSignedServiceReturnsMalformedFailureAndHonorsCooperativeCancellation",
                "--candidate-identity",
                "@candidate_identity_path@",
                "--result-bundle-path",
                "@signed_xpc_error_cancellation_result_bundle@",
                "--artifact-root",
                "@signed_xpc_error_cancellation_artifact_root@",
                "--qualification-run-id",
                "@qualification_run_id@",
                "--qualification-run-nonce",
                "@qualification_run_nonce@",
                "--predecessor-observations-sha256",
                "@signed_xpc_error_cancellation_predecessor_observations_sha256@",
            ),
            layer=EvidenceLayer.SIGNED_XPC,
            host=CommandHost.MACOS_ARM64_XCODE27,
            timeout=3_600,
            artifacts=(
                "stdout-path:MACSCOPE_SIGNED_NATIVE_EXECUTABLE",
                "stdout-path:MACSCOPE_SIGNED_NATIVE_EXECUTION_REPORT",
                "stdout-path:MACSCOPE_SIGNED_NATIVE_TEST_RESULTS",
            ),
            logs=("executor-captured:signed-xpc-error-cancellation-stdout-stderr",),
            mutation=CommandMutationState.BUILD_OUTPUT,
            cleanup=("Preserve the prepared native-live product, ordinary signed-native artifacts, and result bundle until receipt validation completes.",),
            mode=CommandExecutionMode.RUNNABLE,
            expected_exits=XCODE_EXPECTED_EXITS,
        ),
        _template(
            "signing.strict-release",
            ("strict-signing",),
            (
                "/usr/bin/python3",
                "-B",
                "Scripts/check_local_signing_policy.py",
                "--configuration",
                "Release",
                "--app-bundle",
                "@source_release_app@",
            ),
            layer=EvidenceLayer.STRICT_SIGNING,
            timeout=300,
            logs=("executor-captured:strict-signing-stdout-stderr",),
        ),
        _template(
            "installed.source-equality",
            ("installed-equality",),
            (
                "/usr/bin/python3",
                "-B",
                "Scripts/check_local_signing_policy.py",
                "--configuration",
                "Release",
                "--app-bundle",
                "@installed_app@",
                "--source-app-bundle",
                "@source_release_app@",
            ),
            layer=EvidenceLayer.INSTALLED_SOURCE_EQUALITY,
            host=CommandHost.MACOS_ARM64_XCODE27_TCC,
            timeout=300,
            artifacts=("stdout-json:source-equality-report",),
            logs=("executor-captured:installed-source-equality-stdout-stderr",),
        ),
        _template(
            "installed.shell-smoke",
            ("installed-launch",),
            (
                "/usr/bin/python3",
                "-B",
                "Scripts/phase2/run_installed_shell_smoke.py",
                "--app",
                "@installed_app@",
                "--output",
                "@installed_shell_smoke_report@",
            ),
            layer=EvidenceLayer.INSTALLED_LAUNCH_LOG,
            host=CommandHost.MACOS_ARM64_XCODE27_TCC,
            timeout=300,
            artifacts=("@installed_shell_smoke_report@",),
            logs=("@output_root@/installed-shell-smoke.log",),
            mutation=CommandMutationState.INSTALL_STATE,
            cleanup=("The runner terminates only its PID-bound test-owned app process and preserves bounded evidence.",),
        ),
        _template(
            "installed.xcuitest-preflight",
            ("installed-task10", "installed-accessibility"),
            (
                "/usr/bin/python3",
                "-B",
                "Scripts/ws24_check_xcuitest_host.py",
                "--runner-app",
                "@installed_ui_runner_app@",
                "--generated-at-unix-ms",
                "@generated_at_unix_ms@",
            ),
            layer=EvidenceLayer.INSTALLED_ACCESSIBILITY,
            host=CommandHost.MACOS_ARM64_XCODE27_TCC,
            timeout=60,
            artifacts=("stdout-json:xcuitest-preflight",),
            logs=("executor-captured:xcuitest-preflight-stderr",),
        ),
        _template(
            "installed.emit-report",
            ("installed-equality", "installed-launch", "installed-task10", "installed-accessibility"),
            (
                "/usr/bin/python3",
                "-B",
                "Scripts/ws24_emit_installed_qualification_report.py",
                "--installed-app",
                "@installed_app@",
                "--source-app",
                "@source_release_app@",
                "--evidence-json",
                "@installed_evidence_json@",
                "--candidate-identity",
                "@candidate_identity_path@",
                "--output",
                "@installed_report@",
                "--expected-source-commit",
                "@candidate_commit@",
                "--generated-at-unix-ms",
                "@generated_at_unix_ms@",
                "--xcode-developer-dir",
                "@developer_dir@",
            ),
            layer=EvidenceLayer.INSTALLED_WORKFLOW,
            host=CommandHost.MACOS_ARM64_XCODE27_TCC,
            timeout=300,
            artifacts=("@installed_report@",),
            logs=("@output_root@/installed-report.log",),
        ),
        _template(
            "install.release-to-applications",
            ("installed-equality", "installed-launch", "installed-task10", "installed-accessibility"),
            (
                "/usr/bin/python3",
                "-B",
                "Scripts/reconstruction/install_release_to_applications.py",
                "--candidate-identity",
                "@candidate_identity_path@",
                "--source-app",
                "@source_release_app@",
                "--installed-app",
                "/Applications/MacScope.app",
                "--artifact-root",
                "@install_release_artifact_root@",
                "--qualification-run-id",
                "@qualification_run_id@",
                "--qualification-run-nonce",
                "@qualification_run_nonce@",
                "--predecessor-observations-sha256",
                "@install_release_predecessor_observations_sha256@",
            ),
            layer=EvidenceLayer.INSTALLED_SOURCE_EQUALITY,
            host=CommandHost.MACOS_ARM64_XCODE27_TCC,
            timeout=900,
            artifacts=(
                "stdout-path:MACSCOPE_INSTALL_RELEASE_EXECUTION_REPORT",
                "stdout-path:MACSCOPE_INSTALL_RELEASE_OPERATION_REPORT",
                "stdout-path:MACSCOPE_INSTALL_RELEASE_SOURCE_EQUALITY_REPORT",
            ),
            logs=("executor-captured:install-release-to-applications-stdout-stderr",),
            mutation=CommandMutationState.INSTALL_STATE,
            cleanup=(
                "The runner owns its fresh sibling stage, atomically restores any predecessor after a post-exposure failure, and preserves all three reports.",
            ),
            mode=CommandExecutionMode.RUNNABLE,
        ),
        _template(
            "installed.task10-workflow",
            ("installed-network-audit", "installed-task10"),
            (
                "/usr/bin/python3",
                "-B",
                "Scripts/reconstruction/run_installed_task10_matrix.py",
                "--candidate-identity",
                "@candidate_identity_path@",
                "--preparation-receipt",
                "@installed_ui_preparation_receipt@",
                "--installed-app",
                "@installed_app@",
                "--xctestrun",
                "@installed_ui_xctestrun@",
                "--test-bundle",
                "@installed_ui_test_bundle@",
                "--ui-runner",
                "@installed_ui_runner_app@",
                "--xcresult",
                "@installed_matrix_xcresult@",
                "--xcresult-semantic-manifest",
                "@installed_matrix_xcresult_semantic_manifest@",
                "--receipt-output",
                "@installed_matrix_receipt@",
                "--network-artifact-root",
                "@installed_network_audit_artifact_root@",
                "--qualification-run-id",
                "@qualification_run_id@",
                "--qualification-run-nonce",
                "@qualification_run_nonce@",
                "--predecessor-observations-sha256",
                "@installed_task10_predecessor_observations_sha256@",
                "--developer-dir",
                "@developer_dir@",
            ),
            layer=EvidenceLayer.INSTALLED_WORKFLOW,
            host=CommandHost.MACOS_ARM64_XCODE27_TCC,
            timeout=1_800,
            artifacts=(
                "stdout-json:installed-task10-matrix-summary",
                "@installed_matrix_receipt@",
                "@installed_matrix_xcresult_semantic_manifest@",
                "@installed_network_audit_artifact_root@/InstalledNetworkAcquisition.audit.json",
                "@installed_network_audit_artifact_root@/InstalledNetworkAcquisition.execution-report.json",
                "@installed_network_audit_artifact_root@/InstalledNetworkAcquisition.nettop.csv",
            ),
            logs=("executor-captured:installed-task10-matrix-stdout-stderr",),
            mutation=CommandMutationState.INSTALL_STATE,
            cleanup=("Preserve the sealed UI preparation receipt, matrix receipt, and xcresult until installed report validation completes.",),
            mode=CommandExecutionMode.RUNNABLE,
            expected_exits=XCODE_EXPECTED_EXITS,
        ),
        _template(
            "installed.accessibility-semantics",
            ("installed-accessibility",),
            (
                "/usr/bin/python3",
                "-B",
                "Scripts/reconstruction/emit_installed_accessibility_report.py",
                "--candidate-identity",
                "@candidate_identity_path@",
                "--matrix-receipt",
                "@installed_matrix_receipt@",
                "--xcresult-semantic-manifest",
                "@installed_matrix_xcresult_semantic_manifest@",
                "--artifact-root",
                "@installed_accessibility_artifact_root@",
                "--qualification-run-id",
                "@qualification_run_id@",
                "--qualification-run-nonce",
                "@qualification_run_nonce@",
                "--predecessor-observations-sha256",
                "@installed_accessibility_predecessor_observations_sha256@",
            ),
            layer=EvidenceLayer.INSTALLED_ACCESSIBILITY,
            host=CommandHost.MACOS_ARM64_XCODE27_TCC,
            timeout=300,
            artifacts=(
                "stdout-path:MACSCOPE_INSTALLED_ACCESSIBILITY_EXECUTION_REPORT",
                "stdout-path:MACSCOPE_INSTALLED_ACCESSIBILITY_PRESENTATION_MANIFEST",
                "stdout-path:MACSCOPE_INSTALLED_ACCESSIBILITY_REPORT",
                *INSTALLED_ACCESSIBILITY_SCREENSHOT_OUTPUTS,
            ),
            logs=("executor-captured:installed-accessibility-stdout-stderr",),
            mutation=CommandMutationState.READ_ONLY,
            cleanup=(
                "Preserve the exact matrix receipt, semantic manifest, accessibility report, and all 28 distinct state-qualified presentation screenshots.",
            ),
            mode=CommandExecutionMode.RUNNABLE,
        ),
        _template(
            "stress.reconstruction-authority-races",
            ("stress-recovery",),
            (
                "./Scripts/reconstruction/run_authority_stress_tests.sh",
                "--candidate-identity",
                "@candidate_identity_path@",
                "--preparation-receipt",
                "@native_live_preparation_receipt@",
                "--xctestrun",
                "@native_live_xctestrun@",
                "--candidate-app",
                "@native_live_app@",
                "--result-bundle-path",
                "@authority_stress_result_bundle@",
                "--artifact-root",
                "@authority_stress_artifact_root@",
                "--qualification-run-id",
                "@qualification_run_id@",
                "--qualification-run-nonce",
                "@qualification_run_nonce@",
                "--predecessor-observations",
                "@authority_stress_predecessor_observations@",
            ),
            layer=EvidenceLayer.STRESS_RECOVERY,
            host=CommandHost.MACOS_ARM64_XCODE27,
            timeout=3_600,
            artifacts=(
                "stdout-path:MACSCOPE_AUTHORITY_STRESS_ATTEMPT_LEDGER",
                "stdout-path:MACSCOPE_AUTHORITY_STRESS_PLAN",
                "stdout-path:MACSCOPE_AUTHORITY_STRESS_PREPARATION_RECEIPT",
                "stdout-path:MACSCOPE_AUTHORITY_STRESS_PREPARED_XCTESTRUN",
                "stdout-path:MACSCOPE_AUTHORITY_STRESS_REPORT",
                "stdout-path:MACSCOPE_AUTHORITY_STRESS_TEST_RESULTS",
                "stdout-path:MACSCOPE_AUTHORITY_STRESS_XCTESTRUN",
            ),
            logs=("executor-captured:authority-stress-stdout-stderr",),
            mutation=CommandMutationState.BUILD_OUTPUT,
            cleanup=("Preserve the ordinary plan, test-results, and stress-report artifacts plus the result bundle until receipt validation completes.",),
            mode=CommandExecutionMode.RUNNABLE,
            expected_exits=XCODE_EXPECTED_EXITS,
        ),
        _executor_required(
            "evidence.t10c-current-source-adjudication",
            ("reconstruction-task10",),
            layer=EvidenceLayer.INDEPENDENT_REVIEW,
            host=CommandHost.INDEPENDENT_REVIEWER,
            reason="T10C is external current-source evidence and has no accepted repository command on this source; it must be independently adjudicated and identity-bound.",
            artifacts=(
                "executor-output:t10c/FINDING_ADJUDICATION.json",
                "executor-output:t10c/SOURCE_DRIFT.json",
                "executor-output:t10c/bundle.sha256",
                "executor-output:t10c/current-source-independent-review.json",
                "executor-output:t10c/current-source-review-execution-report.json",
            ),
        ),
        *(
            _executor_required(
                command_id,
                ("merge-qualification",),
                layer=EvidenceLayer.INDEPENDENT_REVIEW,
                host=CommandHost.INDEPENDENT_REVIEWER,
                reason=(
                    f"Independent review lens {lens_id} is a separate executor authority "
                    "and cannot be self-executed by the qualification compiler."
                ),
                artifacts=(
                    f"executor-output:review/{lens_id}-review-execution-report.json",
                    f"executor-output:review/{lens_id}-review-report.json",
                ),
            )
            for command_id, lens_id in INDEPENDENT_REVIEW_COMMAND_LENSES.items()
        ),
        _executor_required(
            "review.independent",
            ("merge-qualification",),
            layer=EvidenceLayer.INDEPENDENT_REVIEW,
            host=CommandHost.INDEPENDENT_REVIEWER,
            reason="Independent review aggregation binds four separately executed lens receipts.",
            artifacts=tuple(
                f"executor-output:review/{lens_id}-review-receipt.json"
                for lens_id in INDEPENDENT_REVIEW_COMMAND_LENSES.values()
            )
            + ("executor-output:review/independent-review-execution-report.json",),
        ),
        _executor_required(
            "merge.prospective-tree",
            ("merge-qualification",),
            layer=EvidenceLayer.PROSPECTIVE_MERGE_TREE,
            host=CommandHost.MERGE_AUTHORITY,
            reason="No canonical repository script constructs and accepts a prospective merge tree; merge authority must provide both parents, commit, tree, and governed-file diff evidence.",
            mutation=CommandMutationState.GIT_STATE,
            artifacts=(
                "executor-output:prospective-governed-diff",
                "executor-output:prospective-merge-authority",
                "executor-output:prospective-merge-execution-report",
                "executor-output:prospective-merge-observation",
            ),
        ),
        _executor_required(
            "postmerge.exact-tree-proof",
            ("postmerge-qualification",),
            layer=EvidenceLayer.POST_MERGE,
            host=CommandHost.MERGE_AUTHORITY,
            reason="Post-merge proof requires the accepted remote merge identity and workflow run, which do not exist at compile time.",
            mutation=CommandMutationState.GIT_STATE,
            artifacts=(
                "executor-output:postmerge-authority",
                "executor-output:postmerge-execution-report",
                "executor-output:postmerge-observation",
                "executor-output:postmerge-workflow",
            ),
        ),
    ]
    template_ids = {item.command_id for item in templates}
    if set(COMMAND_PREREQUISITES) != template_ids:
        raise RuntimeError("command prerequisite catalog is not exact")
    templates = [
        replace(
            template,
            prerequisite_ids=tuple(sorted(COMMAND_PREREQUISITES[template.command_id])),
        )
        for template in templates
    ]
    if profile is CampaignProfile.BOOTSTRAP_VERIFIER:
        replaced = []
        for template in templates:
            old_id = template.command_id
            if old_id in INSTALLED_CAPTURE_COMMANDS:
                template = replace(template, execution_mode=CommandExecutionMode.RUNNABLE)
                if old_id == "install.release-to-applications":
                    template = replace(template,
                        argv=tuple('Scripts/reconstruction_gate_f/begin_installed_candidate.py' if value == 'Scripts/reconstruction/install_release_to_applications.py'
                            else '--command-predecessor-observations-sha256' if value == '--predecessor-observations-sha256'
                            else '@installed_app@' if value == '/Applications/MacScope.app'
                            else value for value in template.argv),
                        generated_artifacts=('@install_release_artifact_root@/GateFInstalledBegin.projection.json',
                            '@install_release_artifact_root@/GateFInstalledBegin.source-equality.json'),
                        cleanup_rollback=('Fresh pending BEGIN only; wrapper failures roll back its exact transaction. The operator owns timeout recovery and eight-gate commit.',))
                elif old_id == "installed.shell-smoke":
                    template = replace(template,
                        argv=template.argv + ("--single-launch", "--expected-source-commit", "@candidate_commit@"),
                        generated_artifacts=tuple(sorted(template.generated_artifacts + ("@installed_legacy_grid_report@",))))
                elif old_id == "installed.emit-report":
                    extra = (
                        ("qualification-run-id", "qualification_run_id"),
                        ("qualification-run-nonce", "qualification_run_nonce"),
                        ("installation-pending-state", "installed_pending_state"),
                        ("full-surface-report", "installed_full_surface_report"),
                        ("legacy-grid-report", "installed_legacy_grid_report"),
                        ("cli-gui-operability-report", "installed_cli_gui_operability_report"),
                        ("mcp-operability-report", "installed_mcp_operability_report"),
                        ("native-xpc-execution-report", "installed_native_xpc_execution_report"),
                    )
                    template = replace(template,
                        argv=template.argv + tuple(v for flag, name in extra for v in ("--" + flag, "@" + name + "@"))
                            + tuple(v for gate, name in installed_gate_output_slots() for v in ("--acceptance-gate-output", gate + "=@" + name + "@")),
                        generated_artifacts=tuple(sorted(template.generated_artifacts + tuple("@" + name + "@" for _, name in installed_gate_output_slots()))))
            elif old_id == "source.hosted-governance":
                template = replace(template, timeout_seconds=1800)
            elif old_id == "evidence.t10c-current-source-adjudication":
                template = replace(template, prerequisite_ids=tuple(sorted(template.prerequisite_ids + (
                    "installed.task10-workflow", "installed.accessibility-semantics", "installed.source-equality",
                    "installed.shell-smoke", "installed.emit-report"))))
            if old_id in BOOTSTRAP_COMMAND_SUBSTITUTIONS:
                kind = "fullsuite" if old_id == "xcode.full-coretests" else "products"
                prefix = kind.upper()
                projection = "XCRESULT" if kind == "fullsuite" else "APP"
                template = replace(template,
                    argv=("/usr/bin/python3", "-B", "-m", "Scripts.reconstruction_gate_f.bootstrap_verifier", kind,
                        "--candidate-identity", "@candidate_identity_path@",
                        "--repository-root", "@repository_root@", "--integration-ref", "@integration_ref@",
                        "--bootstrap-root", "@bootstrap_artifact_root@",
                        "--bootstrap-admission", "@bootstrap_admission_path@",
                        "--artifact-root", "@bootstrap_" + kind + "_artifact_root@",
                        "--qualification-run-id", "@qualification_run_id@",
                        "--qualification-run-nonce", "@qualification_run_nonce@",
                        "--predecessor-observations-sha256", "@bootstrap_" + kind + "_predecessor_observations_sha256@"),
                    expected_exits=DEFAULT_EXPECTED_EXITS,
                    timeout_seconds=900,
                    generated_artifacts=tuple(sorted((
                        "stdout-path:MACSCOPE_BOOTSTRAP_" + prefix + "_EXECUTION_REPORT",
                        "stdout-path:MACSCOPE_BOOTSTRAP_" + prefix + "_SEMANTIC_REPORT",
                        "stdout-path:MACSCOPE_BOOTSTRAP_" + prefix + "_" + projection + "_PROJECTION"))),
                    generated_logs=("executor-captured:bootstrap-" + kind + "-verifier-stdout-stderr",),
                    mutation_state=CommandMutationState.READ_ONLY,
                    cleanup_rollback=("Preserve original bootstrap evidence and independently created verifier outputs.",),
                    execution_mode=CommandExecutionMode.RUNNABLE)
            elif old_id in {"native.normal", "native.asan", "native.ubsan", "native.golden"}:
                suffix = old_id.removeprefix("native.")
                if suffix == "golden":
                    argv = ("/usr/bin/python3", "-B",
                        "./Scripts/native-decompiler-xpc/run_gatef_native_golden.py",
                        "--source-materialization-root", "@sleigh_materialization_root@",
                        "--native-archive-root", "@native_build_root@",
                        "--work-root", "@native_golden_work_root@",
                        "--developer-dir", "@developer_dir@",
                        "--sdk-root", "@sdk_root@", "--sdk-name", "@sdk_name@")
                    artifacts = tuple(sorted((
                        "stdout-path:MACSCOPE_NATIVE_GOLDEN_RESULT",
                        "stdout-path:MACSCOPE_NATIVE_GOLDEN_STAGE_STAMP",
                        "stdout-path:MACSCOPE_NATIVE_GOLDEN_MATERIALIZATION")))
                else:
                    argv = template.argv + ("--qualification-report-dir", "@native_" + suffix + "_report_dir@")
                    artifacts = ("stdout-path:MACSCOPE_NATIVE_QUALIFICATION_REPORT",)
                template = replace(template, argv=argv,
                    environment=tuple(sorted(template.environment + (("DEVELOPER_DIR", "@developer_dir@"),))),
                    generated_artifacts=artifacts,
                    generated_logs=("executor-captured:native-" + suffix + "-stdout-stderr",),
                    execution_mode=CommandExecutionMode.RUNNABLE)
            replaced.append(replace(template,
                command_id=campaign_command_id(old_id, profile=profile),
                prerequisite_ids=tuple(sorted(campaign_command_id(value, profile=profile)
                                              for value in template.prerequisite_ids))))
        templates = replaced
    return tuple(sorted(templates, key=lambda item: item.command_id))


COMMAND_IDS = tuple(item.command_id for item in command_templates())
