#!/usr/bin/env python3
"""Fast source-boundary contracts for the Phase 2 R1 typed-read kernel."""

from pathlib import Path
import hashlib
import re
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
PROJECT_YML = REPO_ROOT / "MacScope" / "project.yml"
SWIFT_SOURCE_ROOTS = (
    "AIAgentWorkerCore",
    "AIAgentWorkerService",
    "AIWorkerProtocol",
    "AnalysisWorkerService",
    "App",
    "Bridges",
    "DesignSystem",
    "Features",
    "Models",
    "Plugins",
    "Services",
    "Stores",
    "Tests",
    "XPCService",
)

PHASE2_KERNEL_SOURCES = (
    "Models/Phase2/Phase2ReadIdentity.swift",
    "Models/Phase2/Phase2ReadOperation.swift",
    "Services/Phase2/TypedReadRegistry.swift",
    "Services/Phase2/Phase2EvidenceAcceptor.swift",
)

# Shared analyst envelopes use only neutral values, not app-owned read/inference authority.
ANALYSIS_SHARED_PHASE2_VALUE_SOURCES = (
    "Models/Phase2/Phase2GroundedContext.swift",
    "Models/Phase2/Phase2ReadIdentity.swift",
    "Models/Phase2/Phase2ReadOperation.swift",
    "Models/Phase2/Phase2DebuggerReadOperationID.swift",
)

PROJECTION_SOURCES = (
    "Models/Phase2/Phase2ReadProjection.swift",
    "Services/Phase2/Phase2ReadProjector.swift",
)

STORE_COORDINATOR_SOURCES = (
    "Models/Phase2/Phase2ReadRevisionLedger.swift",
    "Stores/WorkspaceStore+Phase2Read.swift",
)

GROUNDED_CONTEXT_SOURCES = (
    "Models/Phase2/Phase2GroundedContext.swift",
    "Services/Phase2/Phase2GroundedContextCompiler.swift",
)

INFERENCE_TURN_BOUNDARY_SOURCES = (
    "Models/Phase2/Phase2Inference.swift",
    "Services/Phase2/Phase2InferenceProviding.swift",
    "Services/Phase2/Phase2InferenceRunner.swift",
)

AI_PROVIDER_CONFIGURATION_APP_SOURCES = (
    "Models/Phase2/Phase2AIProviderConfiguration.swift",
    "Services/Phase2/Phase2AIWorkerConfigurationAppCodec.swift",
)

AI_PROVIDER_DISCOVERY_APP_SOURCES = (
    "Models/Phase2/Phase2LocalProviderEndpoint.swift",
    "Models/Phase2/Phase2LocalModelInventory.swift",
    "Services/Phase2/Phase2LocalModelDiscovering.swift",
    "Services/Phase2/Phase2AIWorkerModelDiscoveryAppCodec.swift",
    "Services/Phase2/AIAgentXPCModelDiscoveryTransport.swift",
    "Services/Phase2/AIAgentXPCModelDiscoveryService.swift",
)

AI_PROVIDER_LIFECYCLE_APP_SOURCES = (
    "Models/Phase2/Phase2LocalModelLifecycle.swift",
    "Services/Phase2/Phase2LocalModelLifecycleControlling.swift",
    "Services/Phase2/Phase2AIWorkerModelLifecycleAppCodec.swift",
    "Services/Phase2/AIAgentXPCModelLifecycleTransport.swift",
    "Services/Phase2/AIAgentXPCModelLifecycleService.swift",
)

AI_PROVIDER_SELECTION_APP_SOURCES = (
    "Models/Phase2/Phase2LocalAISelection.swift",
    "Services/Phase2/Phase2LocalAIProviderController.swift",
    "Features/Settings/LocalAIProviderSettingsView.swift",
)

AI_PROVIDER_SELECTION_PERSISTENCE_APP_SOURCES = (
    "Models/Phase2/Phase2LocalAIProviderPreference.swift",
    "Services/Phase2/Phase2LocalAIProviderPreferenceStore.swift",
)

AI_PROVIDER_SELECTION_INTEGRATION_APP_SOURCES = (
    "App/MacScopeApp.swift",
    "DesignSystem/AppDesignSystem.swift",
    "Features/Settings/SettingsView.swift",
)

AI_PROVIDER_SELECTION_ALL_APP_SOURCES = (
    AI_PROVIDER_SELECTION_APP_SOURCES
    + AI_PROVIDER_SELECTION_PERSISTENCE_APP_SOURCES
    + AI_PROVIDER_SELECTION_INTEGRATION_APP_SOURCES
)

READY_INFERENCE_COMPOSITION_APP_SOURCES = (
    "Services/Phase2/Phase2ReadyInferenceCoordinator.swift",
)

MODEL_QUALIFICATION_APP_SOURCES = (
    "Models/Phase2/Phase2ModelProfile.swift",
    "Models/Phase2/Phase2ModelQualification.swift",
    "Services/Phase2/Phase2ModelProfileCanonicalizer.swift",
    "Services/Phase2/Phase2ModelProfileMatcher.swift",
    "Services/Phase2/Phase2ModelQualificationEvaluator.swift",
)

MODEL_QUALIFICATION_CORE_TEST_SOURCES = (
    "Services/Phase2/Phase2ModelQualificationHarness.swift",
    "Services/Phase2/QualificationGate/Phase2ModelQualificationReport.swift",
)

F4B_SHARED_PROTOCOL_SOURCES = (
    "AIWorkerProtocol/Phase2AIWorkerProductionProtocol.swift",
    "AIWorkerProtocol/Phase2ProductionProtocolProbeCatalog.swift",
)

# REA's authenticated AnalysisWorker boundary reuses only this neutral parser/value
# implementation. This is not permission to compile inference or execution authority.
ANALYSIS_AND_AI_WORKER_SHARED_NEUTRAL_JSON_SOURCE = "AIAgentWorkerCore/Phase2ProductionJSONSchema.swift"

F4B_WORKER_CORE_SOURCES = (
    "AIAgentWorkerCore/Phase2ProductionJSONSchema.swift",
    "AIAgentWorkerCore/Phase2ProductionToolRegistry.swift",
    "AIAgentWorkerCore/Phase2GroundedPromptModules.swift",
    "AIAgentWorkerCore/Phase2OpenAIToolCallAssembler.swift",
)

F4B_APP_AUTHORITY_SOURCES = (
    "Models/Phase2/Phase2Inference.swift",
    "Services/Phase2/Phase2AIWorkerAppCodec.swift",
    "Services/Phase2/Phase2InferenceRunner.swift",
    "Services/Phase2/Phase2ReadyInferenceCoordinator.swift",
)

F4B_WORKER_PROTOCOL_BOUNDARY_SOURCES = (
    F4B_SHARED_PROTOCOL_SOURCES
    + F4B_WORKER_CORE_SOURCES
    + (
        "AIWorkerProtocol/Phase2AIWorkerWireModels.swift",
        "AIWorkerProtocol/Phase2AIWorkerWireCodec.swift",
        "AIAgentWorkerCore/Phase2GroundedPromptCompiler.swift",
        "AIAgentWorkerCore/Phase2GroundedOutputDecoder.swift",
        "AIAgentWorkerCore/Phase2OpenAIChatRequestEncoder.swift",
        "AIAgentWorkerCore/Phase2OpenAIChatStreamDecoder.swift",
    )
)

F4C_VERSIONED_IDENTITY_SOURCE_DIGESTS = {
    "Models/Phase2/Phase2ModelProfile.swift":
        "d952f60bb7dc0e50d5ee9f44f79bc371e421b01b1a0ba9c8dd8aaed0d432ec1f",
    "Services/Phase2/Phase2ModelProfileCanonicalizer.swift":
        "dd8788d3c98b88ca3f41c1d3bacfddc0e539f81c4f0931fdfe600cdad1d3269a",
}

F4C_ACCEPTED_APP_AUTHORITY_SOURCES = (
    "Models/Phase2/Phase2LiveQualification.swift",
    "Models/Phase2/Phase2LiveQualificationScenario.swift",
    "Models/Phase2/Phase2QualificationEnvironmentV2.swift",
    "Models/Phase2/Phase2QualificationRuntimeProvenance.swift",
    "Services/Phase2/Phase2LiveQualificationObservationCollector.swift",
    "Services/Phase2/Phase2LiveQualificationScenarioCatalog.swift",
    "Services/Phase2/Phase2LiveQualificationRequestFactory.swift",
    "Services/Phase2/Phase2LiveQualificationRunner.swift",
    "Services/Phase2/Phase2LiveQualificationPreflight.swift",
    "Services/Phase2/Phase2ProductionQualificationPolicy.swift",
    "Services/Phase2/Phase2QualificationMeasurementCollector.swift",
    "Services/Phase2/Phase2QualificationProcessScopeSampler.swift",
    "Services/Phase2/Phase2QualificationRunBuilder.swift",
    "Services/Phase2/Phase2StandardModelProfileFactory.swift",
)

AI_WORKER_SHARED_SOURCES = (
    "AIWorkerProtocol/Phase2AIWorkerXPCProtocol.swift",
    "AIWorkerProtocol/Phase2AIWorkerWireModels.swift",
    "AIWorkerProtocol/Phase2AIWorkerWireCodec.swift",
    "AIWorkerProtocol/Phase2LocalInferencePolicy.swift",
    "AIWorkerProtocol/Phase2AIWorkerConfigurationWireModels.swift",
    "AIWorkerProtocol/Phase2AIWorkerConfigurationWireCodec.swift",
    "AIWorkerProtocol/Phase2AIWorkerModelDiscoveryWireModels.swift",
    "AIWorkerProtocol/Phase2AIWorkerModelDiscoveryWireCodec.swift",
    "AIWorkerProtocol/Phase2AIWorkerModelLifecycleWireModels.swift",
    "AIWorkerProtocol/Phase2AIWorkerModelLifecycleWireCodec.swift",
) + F4B_SHARED_PROTOCOL_SOURCES

AI_WORKER_RUNTIME_ONLY_SOURCES = (
    "AIAgentWorkerService/main.swift",
)

AI_WORKER_DIRECT_TEST_SOURCES = (
    "AIAgentWorkerService/Phase2AIWorkerPrincipal.swift",
    "AIAgentWorkerService/Phase2AIWorkerHandler.swift",
    "AIAgentWorkerService/Phase2ReconstructionAIWorkerHandler.swift",
    "AIAgentWorkerService/Phase2AIWorkerModelLifecycleHandler.swift",
)

AI_WORKER_ONLY_SOURCES = AI_WORKER_RUNTIME_ONLY_SOURCES + AI_WORKER_DIRECT_TEST_SOURCES

ANALYSIS_AND_AI_WORKER_SHARED_RECONSTRUCTION_MODEL_SOURCES = (
    # Neutral image/function coordinates shared by source requests and analysis results.
    "Models/ImageSlot.swift",
    "Models/MachOConstants.swift",
    "Models/MachOSliceArtifactIdentity.swift",
    "Models/Reconstruction/ReconstructionIdentity.swift",
    "Models/Reconstruction/ReconstructionOperationID.swift",
    "Models/Reconstruction/ReconstructionFinalSynthesisKind.swift",
    # Neutral handle DTOs also validate persisted evidence-read receipts in AnalysisWorker.
    "Models/Reconstruction/ReconstructionToolModels.swift",
    # Closed profile/version vocabulary, not source-execution authority.
    "Models/Reconstruction/ReconstructionSourceProfile.swift",
)

RECONSTRUCTION_AI_WORKER_MODEL_SOURCES = (
    ANALYSIS_AND_AI_WORKER_SHARED_RECONSTRUCTION_MODEL_SOURCES
    + (
        "Models/Reconstruction/ReconstructionInference.swift",
        "Models/Reconstruction/ReconstructionSourceInference.swift",
        "AIWorkerProtocol/Phase2ReconstructionAIWorkerWireModels.swift",
        "AIWorkerProtocol/Phase2ReconstructionAIWorkerWireCodec.swift",
    )
)

RECONSTRUCTION_AI_WORKER_CORE_SOURCES = (
    "AIAgentWorkerCore/Phase2ReconstructionProductionToolRegistry.swift",
    "AIAgentWorkerCore/Phase2ReconstructionOutputSchemas.swift",
    "AIAgentWorkerCore/Phase2ReconstructionSourceOutput.swift",
    "AIAgentWorkerCore/Phase2ReconstructionPromptModules.swift",
    "AIAgentWorkerCore/Phase2ReconstructionRoundAccumulator.swift",
    "AIAgentWorkerCore/Phase2ReconstructionOpenAIChatRequestEncoder.swift",
)

RECONSTRUCTION_AI_WORKER_PROJECTION_SOURCES = (
    "Services/Reconstruction/ReconstructionReadablePromptProjection.swift",
)

AI_WORKER_CORE_SOURCES = (
    "AIAgentWorkerCore/Phase2LoopbackEndpoint.swift",
    "AIAgentWorkerCore/Phase2GroundedPromptCompiler.swift",
    "AIAgentWorkerCore/Phase2GroundedOutputDecoder.swift",
    "AIAgentWorkerCore/Phase2OpenAIChatRequestEncoder.swift",
    "AIAgentWorkerCore/Phase2OpenAIChatStreamDecoder.swift",
    "AIAgentWorkerCore/Phase2OpenAIChatHTTPClient.swift",
    "AIAgentWorkerCore/Phase2NativeModelCatalogDecoder.swift",
    "AIAgentWorkerCore/Phase2MTPLXModelCatalogDecoder.swift",
    "AIAgentWorkerCore/Phase2NativeModelDiscoveryHTTPClient.swift",
    "AIAgentWorkerCore/Phase2NativeModelLifecycleHTTPClient.swift",
    "AIAgentWorkerCore/Phase2SSEDecoder.swift",
) + F4B_WORKER_CORE_SOURCES

AI_WORKER_APP_GATE_SUPPORT_SOURCES = (
    "AIAgentWorkerCore/Phase2LoopbackEndpoint.swift",
    "AIAgentWorkerCore/Phase2ProductionJSONSchema.swift",
    "AIAgentWorkerCore/Phase2ProductionToolRegistry.swift",
    "AIAgentWorkerCore/Phase2GroundedPromptModules.swift",
    "AIAgentWorkerCore/Phase2OpenAIToolCallAssembler.swift",
    "AIAgentWorkerCore/Phase2GroundedPromptCompiler.swift",
    "AIAgentWorkerCore/Phase2GroundedOutputDecoder.swift",
    "AIAgentWorkerCore/Phase2OpenAIChatRequestEncoder.swift",
    "AIAgentWorkerCore/Phase2OpenAIChatStreamDecoder.swift",
    "AIAgentWorkerCore/Phase2NativeModelCatalogDecoder.swift",
    "AIAgentWorkerCore/Phase2SSEDecoder.swift",
)

AI_WORKER_APP_FORBIDDEN_RUNTIME_SOURCES = (
    "AIAgentWorkerCore/Phase2OpenAIChatHTTPClient.swift",
    "AIAgentWorkerCore/Phase2NativeModelDiscoveryHTTPClient.swift",
    "AIAgentWorkerCore/Phase2NativeModelLifecycleHTTPClient.swift",
) + AI_WORKER_DIRECT_TEST_SOURCES

AI_WORKER_SOURCES = (
    AI_WORKER_SHARED_SOURCES
    + AI_WORKER_ONLY_SOURCES
    + AI_WORKER_CORE_SOURCES
    + RECONSTRUCTION_AI_WORKER_MODEL_SOURCES
    + RECONSTRUCTION_AI_WORKER_CORE_SOURCES
    + RECONSTRUCTION_AI_WORKER_PROJECTION_SOURCES
)

PHASE2_SOURCES = (
    PHASE2_KERNEL_SOURCES
    + PROJECTION_SOURCES
    + STORE_COORDINATOR_SOURCES
    + GROUNDED_CONTEXT_SOURCES
    + INFERENCE_TURN_BOUNDARY_SOURCES
    + AI_PROVIDER_CONFIGURATION_APP_SOURCES
    + AI_PROVIDER_DISCOVERY_APP_SOURCES
    + AI_PROVIDER_LIFECYCLE_APP_SOURCES
    + AI_PROVIDER_SELECTION_APP_SOURCES
    + AI_PROVIDER_SELECTION_PERSISTENCE_APP_SOURCES
    + MODEL_QUALIFICATION_APP_SOURCES
)

FORBIDDEN_PROJECTION_CAPABILITIES = re.compile(
    r"\b(?:WorkspaceScriptingAPI|ScriptValue|MCPServer|MCPLauncher|CLIRunner|"
    r"AppleScript|AppleEvent|NSScriptCommand|ScriptingHost|MacScopeScriptCommand|"
    r"FileManager|FileHandle|URLSession|URLRequest|NWConnection|Process|NSTask|"
    r"posix_spawn|fork|exec|system|popen|dlopen|dlsym|NSWorkspace|NSAppleScript)\b"
)

FORBIDDEN_CONTEXT_CAPABILITIES = re.compile(
    r"\b(?:WorkspaceStore|WorkspaceDatabase|WorkspaceScriptingAPI|ScriptValue|"
    r"MCPServer|MCPLauncher|CLIRunner|AppleScript|AppleEvent|NSScriptCommand|"
    r"FileManager|FileHandle|URLSession|URLRequest|NWConnection|Process|NSTask|"
    r"posix_spawn|fork|exec|system|popen|NSWorkspace|NSAppleScript)\b"
)

FORBIDDEN_INFERENCE_TURN_CAPABILITIES = re.compile(
    r"\b(?:WorkspaceStore|WorkspaceDatabase|WorkspaceCommand|DocumentDirtyTracker|"
    r"MachOPatchWriter|WorkspaceScriptingAPI|ScriptValue|MCPServer|MCPLauncher|CLIRunner|"
    r"AppleScript|AppleEvent|NSScriptCommand|ScriptingHost|MacScopeScriptCommand|"
    r"FileManager|FileHandle|InputStream|OutputStream|URLSession|URLRequest|URLProtocol|"
    r"NWConnection|NWListener|Process|NSTask|posix_spawn|fork|exec|system|popen|"
    r"NSWorkspace|NSAppleScript|UserDefaults|NSManagedObjectContext|ModelContext|"
    r"Debugger[A-Za-z0-9_]*|UndoManager|NSPasteboard|markDocumentMutated|patchBytes|"
    r"setPatch|removePatch|writeMemory|writeRegister|setBreakpoint|removeBreakpoint)\b"
)


def target_block(project: str, target: str) -> str:
    match = re.search(
        rf"(?ms)^  {re.escape(target)}:\n(?P<body>.*?)(?=^  [A-Za-z0-9_]+:|^schemes:|\Z)",
        project,
    )
    if match is None:
        raise AssertionError(f"target {target} is missing from MacScope/project.yml")
    return match.group("body")


def source_paths(block: str) -> tuple[str, ...]:
    sources = re.search(r"(?ms)^    sources:\n(?P<body>.*?)(?=^    [A-Za-z0-9_]+:|\Z)", block)
    if sources is None:
        raise AssertionError("target is missing its sources list")
    return tuple(re.findall(r"(?m)^      - path: ([^\n]+)$", sources.group("body")))


def covering_source_entries(source: str, entries: set[str]) -> list[str]:
    return [
        entry
        for entry in entries
        if source == entry or source.startswith(entry.rstrip("/") + "/")
    ]


def without_swift_comments(source: str) -> str:
    source = re.sub(r"(?s)/\*.*?\*/", "", source)
    return re.sub(r"(?m)//[^\n]*$", "", source)


class Phase2R1SourceBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.project = PROJECT_YML.read_text(encoding="utf-8")

    def analysis_core_sources(self) -> set[str]:
        # D12 layer 3: sources compiled once in the MacScopeAnalysisCore static library, which
        # both MacScopeApp and AnalysisWorkerXPCService link; count them as both closures.
        if not re.search(r"(?m)^  MacScopeAnalysisCore:\n", self.project):
            return set()
        return set(source_paths(target_block(self.project, "MacScopeAnalysisCore")))

    def debugger_core_sources(self) -> set[str]:
        # The app also links MacScopeDebuggerCore (D12 layer 3).
        if not re.search(r"(?m)^  MacScopeDebuggerCore:\n", self.project):
            return set()
        return set(source_paths(target_block(self.project, "MacScopeDebuggerCore")))

    def app_closure(self) -> set[str]:
        return (set(source_paths(target_block(self.project, "MacScopeApp"))) | self.analysis_core_sources()
                | self.debugger_core_sources())

    def analysis_worker_closure(self) -> set[str]:
        return (set(source_paths(target_block(self.project, "AnalysisWorkerXPCService")))
                | self.analysis_core_sources())

    def test_frozen_phase2_sources_exist(self) -> None:
        for source in PHASE2_SOURCES:
            with self.subTest(source=source):
                self.assertTrue(
                    (REPO_ROOT / "MacScope" / source).is_file(),
                    f"frozen R1 source is missing: MacScope/{source}",
                )

    def test_app_target_directory_globs_cover_all_frozen_sources(self) -> None:
        app_sources = set(source_paths(target_block(self.project, "MacScopeApp")))
        self.assertIn("Models", app_sources)
        self.assertIn("Services", app_sources)
        for source in PHASE2_SOURCES:
            with self.subTest(source=source):
                source_root = source.split("/", maxsplit=1)[0]
                self.assertIn(source_root, app_sources)

    def test_analysis_worker_closed_source_list_excludes_phase2_kernel(self) -> None:
        worker_sources = set(
            source_paths(target_block(self.project, "AnalysisWorkerXPCService"))
        )
        for source in PHASE2_SOURCES:
            with self.subTest(source=source):
                self.assertNotIn(source, worker_sources)
        for source in STORE_COORDINATOR_SOURCES:
            with self.subTest(app_only_source=source):
                covering_entries = [
                    entry
                    for entry in worker_sources
                    if source == entry or source.startswith(entry.rstrip("/") + "/")
                ]
                self.assertEqual(
                    covering_entries,
                    [],
                    f"app-only coordinator source is covered by worker entries: {source}",
                )
        self.assertNotIn("Models", worker_sources)
        self.assertNotIn("Services", worker_sources)
        self.assertNotIn("Stores", worker_sources)
        closure = self.analysis_worker_closure()
        for source in ANALYSIS_SHARED_PHASE2_VALUE_SOURCES:
            with self.subTest(shared_value=source):
                self.assertEqual(covering_source_entries(source, closure), [source])
                text = without_swift_comments((REPO_ROOT / "MacScope" / source).read_text(encoding="utf-8"))
                self.assertEqual(set(re.findall(r"(?m)^import\s+(\w+)\s*$", text)), {"Foundation"})
                self.assertNotRegex(text, r"\b(?:WorkspaceStore|WorkspaceDatabase|TypedReadRegistry|"
                                    r"Phase2EvidenceAcceptor|Phase2InferenceRunner|NSXPCConnection|"
                                    r"URLSession|URLRequest|Process|NSTask|FileManager|FileHandle)\b")
        for source in PHASE2_SOURCES + READY_INFERENCE_COMPOSITION_APP_SOURCES:
            if source not in ANALYSIS_SHARED_PHASE2_VALUE_SOURCES:
                with self.subTest(app_authority=source):
                    self.assertEqual(covering_source_entries(source, closure), [])

    def test_xpc_targets_preserve_phase2_app_authority(self) -> None:
        xpc_targets = {
            target
            for target in re.findall(r"(?m)^  ([A-Za-z0-9_]+):\n", self.project)
            if re.search(
                r"(?m)^    type: xpc-service$",
                target_block(self.project, target),
            )
        }
        self.assertIn("AIAgentWorkerXPCService", xpc_targets)
        for target in xpc_targets:
            entries = set(source_paths(target_block(self.project, target)))
            for source in PHASE2_SOURCES:
                with self.subTest(target=target, app_authority_source=source):
                    self.assertEqual(
                        covering_source_entries(source, entries),
                        [],
                        f"app-only Phase 2 source is covered by {target}: {source}",
                    )

    def test_f4a_model_qualification_evaluation_sources_are_app_only(self) -> None:
        app_sources = set(source_paths(target_block(self.project, "MacScopeApp")))
        xpc_targets = (
            "PluginXPCService",
            "AnalysisWorkerXPCService",
            "AIAgentWorkerXPCService",
        )
        for source in MODEL_QUALIFICATION_APP_SOURCES:
            with self.subTest(source=source):
                self.assertTrue((REPO_ROOT / "MacScope" / source).is_file())
                self.assertNotEqual(covering_source_entries(source, app_sources), [])
                for target in xpc_targets:
                    target_sources = set(source_paths(target_block(self.project, target)))
                    self.assertEqual(
                        covering_source_entries(source, target_sources),
                        [],
                        f"F4A app-owned source is covered by {target}: {source}",
                    )

    def test_f4a_model_qualification_sources_have_no_runtime_or_persistence_authority(self) -> None:
        forbidden = re.compile(
            r"\b(?:SwiftUI|AppKit|URLSession|URLRequest|URLProtocol|NWConnection|NWListener|"
            r"NSXPCConnection|NSXPCInterface|NSXPCListener|UserDefaults|AppStorage|SceneStorage|"
            r"FileManager|FileHandle|InputStream|OutputStream|NSManagedObjectContext|ModelContext|"
            r"ProcessInfo|Bundle|Date|UUID|NotificationCenter|DistributedNotificationCenter|"
            r"NSUbiquitousKeyValueStore|HTTPCookieStorage|URLCache|"
            r"Codable|JSONEncoder|JSONDecoder|JSONSerialization|"
            r"PropertyListEncoder|PropertyListDecoder|URLComponents|URL|"
            r"WorkspaceStore|WorkspaceDatabase|WorkspaceCommand|DocumentDirtyTracker|"
            r"Phase2LocalAIProviderController|Phase2ReadyInferenceCoordinator|"
            r"AIAgentXPCInferenceProvider|Phase2InferenceRunner|Process|NSTask|posix_spawn|fork|"
            r"exec|popen|Authorization|Keychain|Bearer|loadModel|unloadModel|downloadModel|"
            r"executeTool|performTool|ToolExecutor|Shell|Debugger|writeMemory|writeRegister|"
            r"setBreakpoint|removeBreakpoint|patchBytes|markDocumentMutated)\b|"
            r"\bsystem\s*\(|"
            r"(?:Data|String)\s*\(\s*contentsOf\s*:"
        )
        allowed_imports = {"Foundation", "CryptoKit", "MacScope"}
        sources = MODEL_QUALIFICATION_APP_SOURCES + MODEL_QUALIFICATION_CORE_TEST_SOURCES
        for source in sources:
            with self.subTest(source=source):
                path = REPO_ROOT / "MacScope" / source
                text = without_swift_comments(path.read_text(encoding="utf-8"))
                imports = set(re.findall(r"(?m)^import\s+([A-Za-z0-9_.]+)\s*$", text))
                self.assertLessEqual(imports, allowed_imports)
                self.assertIsNone(forbidden.search(text))

    def test_f4a_report_composition_is_owned_by_signed_app_and_imported_by_coretests(self) -> None:
        app_block = target_block(self.project, "MacScopeApp")
        app_sources = set(source_paths(app_block))
        core_test_sources = set(source_paths(target_block(self.project, "CoreTests")))
        worker_targets = (
            "PluginXPCService",
            "AnalysisWorkerXPCService",
            "AIAgentWorkerXPCService",
        )
        harness_source, report_source = MODEL_QUALIFICATION_CORE_TEST_SOURCES

        self.assertCountEqual(
            covering_source_entries(harness_source, app_sources),
            ["Services", harness_source],
        )
        self.assertRegex(
            app_block,
            r"(?m)^      - path: Services\n"
            r"(?:        excludes:\n)?"
            r"(?:          - .+\n)*"
            r"          - Phase2/Phase2ModelQualificationHarness\.swift$",
        )
        self.assertEqual(covering_source_entries(harness_source, core_test_sources), [])
        self.assertCountEqual(
            covering_source_entries(report_source, app_sources),
            ["Services", "Services/Phase2/QualificationGate"],
        )
        self.assertEqual(covering_source_entries(report_source, core_test_sources), [])
        self.assertNotIn("Services/Phase2/QualificationGate", core_test_sources)
        for target in worker_targets:
            target_sources = set(source_paths(target_block(self.project, target)))
            for source in MODEL_QUALIFICATION_CORE_TEST_SOURCES:
                with self.subTest(target=target, coretests_authority_source=source):
                    self.assertEqual(covering_source_entries(source, target_sources), [])

    def test_release_app_contains_closed_signed_gate_report_authority(self) -> None:
        source = without_swift_comments(
            (REPO_ROOT / "MacScope/Models/Phase2/Phase2ModelQualification.swift")
            .read_text(encoding="utf-8")
        )
        self.assertNotIn("#if DEBUG", source)
        release_source = source
        self.assertRegex(
            release_source,
            r"init\(\s*environment:\s*Phase2QualificationEnvironmentV2,\s*"
            r"runtimeProvenance:\s*Phase2QualificationRuntimeProvenance,\s*"
            r"execution:\s*Phase2LiveQualificationExecution,\s*policy:\s*"
            r"Phase2ModelQualificationPolicy,\s*metricPlan:\s*Phase2QualificationMetricPlan",
        )
        self.assertIn(
            "execution: Phase2LiveQualificationExecution,\n        policy:",
            release_source,
        )
        self.assertIn(
            "evidenceBundle: Phase2QualificationEvidenceBundle,",
            release_source,
        )
        self.assertIn("guard version == 1", release_source)
        self.assertIn("guard version == 2", release_source)
        self.assertNotIn("Phase2ModelQualificationReport", release_source)

        harness = without_swift_comments(
            (REPO_ROOT / "MacScope/Services/Phase2/Phase2ModelQualificationHarness.swift")
            .read_text(encoding="utf-8")
        )
        self.assertNotIn("#if !DEBUG", harness)
        self.assertIn("@testable import MacScope", harness)
        self.assertIn("Phase2ModelQualificationEvaluator().evaluate", harness)

        report = without_swift_comments(
            (REPO_ROOT / "MacScope/Services/Phase2/QualificationGate/Phase2ModelQualificationReport.swift")
            .read_text(encoding="utf-8")
        )
        self.assertIn("struct Phase2ModelQualificationReportID", report)
        self.assertIn("struct Phase2ModelQualificationReport", report)
        self.assertIn("@testable import MacScope", report)

    def test_f4a_profile_and_qualification_do_not_expand_provider_preference(self) -> None:
        preference_store = (
            REPO_ROOT
            / "MacScope/Services/Phase2/Phase2LocalAIProviderPreferenceStore.swift"
        ).read_text(encoding="utf-8")
        forbidden_persisted_state = (
            "qualificationStatus",
            "qualificationReport",
            "modelProfile",
            "profileIdentity",
            "backingHash",
            "measuredMemory",
            "hardwareTier",
            "loadedConfiguration",
            "promptPolicyVersion",
            "toolSchemaVersion",
        )
        for field in forbidden_persisted_state:
            with self.subTest(field=field):
                self.assertNotIn(field, preference_store)

    def test_f4c_freezes_versioned_profile_and_canonical_format_sources(self) -> None:
        for source, expected_digest in F4C_VERSIONED_IDENTITY_SOURCE_DIGESTS.items():
            with self.subTest(source=source):
                path = REPO_ROOT / "MacScope" / source
                self.assertTrue(path.is_file(), f"F4A identity source is missing: MacScope/{source}")
                actual_digest = hashlib.sha256(path.read_bytes()).hexdigest()
                self.assertEqual(
                    actual_digest,
                    expected_digest,
                    f"F4C versioned identity source drifted outside its literal compatibility gates: {source}",
                )

    def test_f4c_accepted_authority_sources_are_app_only(self) -> None:
        app_sources = set(source_paths(target_block(self.project, "MacScopeApp")))
        core_test_sources = set(source_paths(target_block(self.project, "CoreTests")))
        worker_targets = (
            "AIAgentWorkerXPCService",
            "AnalysisWorkerXPCService",
            "PluginXPCService",
        )

        for source in F4C_ACCEPTED_APP_AUTHORITY_SOURCES:
            with self.subTest(source=source):
                self.assertTrue(
                    (REPO_ROOT / "MacScope" / source).is_file(),
                    f"accepted F4C app authority source is missing: MacScope/{source}",
                )
                self.assertNotEqual(covering_source_entries(source, app_sources), [])
                self.assertEqual(
                    covering_source_entries(source, core_test_sources),
                    [],
                    f"F4C app authority source is compiled directly into CoreTests: {source}",
                )
                for target in worker_targets:
                    target_sources = set(source_paths(target_block(self.project, target)))
                    self.assertEqual(
                        covering_source_entries(source, target_sources),
                        [],
                        f"F4C app authority source escaped into {target}: {source}",
                    )

    def test_f4b_frozen_sources_exist(self) -> None:
        for source in (
            F4B_SHARED_PROTOCOL_SOURCES
            + F4B_WORKER_CORE_SOURCES
            + F4B_APP_AUTHORITY_SOURCES
        ):
            with self.subTest(source=source):
                self.assertTrue(
                    (REPO_ROOT / "MacScope" / source).is_file(),
                    f"frozen F4B source is missing: MacScope/{source}",
                )

    def test_f4b_shared_protocol_has_exact_target_membership(self) -> None:
        app_sources = set(source_paths(target_block(self.project, "MacScopeApp")))
        ai_worker_sources = set(
            source_paths(target_block(self.project, "AIAgentWorkerXPCService"))
        )
        core_test_sources = set(source_paths(target_block(self.project, "CoreTests")))
        excluded_targets = ("AnalysisWorkerXPCService", "PluginXPCService")

        for source in F4B_SHARED_PROTOCOL_SOURCES:
            with self.subTest(source=source):
                self.assertEqual(covering_source_entries(source, app_sources), ["AIWorkerProtocol"])
                self.assertEqual(covering_source_entries(source, ai_worker_sources), [source])
                expected_core_test_entries = (
                    [source]
                    if source == "AIWorkerProtocol/Phase2ProductionProtocolProbeCatalog.swift"
                    else []
                )
                self.assertEqual(
                    covering_source_entries(source, core_test_sources),
                    expected_core_test_entries,
                    "only the shared probe catalog is compiled directly into CoreTests",
                )
                for target in excluded_targets:
                    entries = set(source_paths(target_block(self.project, target)))
                    self.assertEqual(covering_source_entries(source, entries), [])

    def test_f4b_worker_core_has_exact_target_membership(self) -> None:
        app_sources = self.app_closure()
        ai_worker_sources = set(
            source_paths(target_block(self.project, "AIAgentWorkerXPCService"))
        )
        core_test_sources = set(source_paths(target_block(self.project, "CoreTests")))
        excluded_targets = ("AnalysisWorkerXPCService", "PluginXPCService")

        for source in F4B_WORKER_CORE_SOURCES:
            with self.subTest(source=source):
                self.assertEqual(covering_source_entries(source, app_sources), [source])
                self.assertEqual(covering_source_entries(source, ai_worker_sources), [source])
                self.assertEqual(covering_source_entries(source, core_test_sources), [source])
                for target in excluded_targets:
                    entries = (self.analysis_worker_closure() if target == "AnalysisWorkerXPCService"
                               else set(source_paths(target_block(self.project, target))))
                    expected = [source] if (
                        target == "AnalysisWorkerXPCService"
                        and source == ANALYSIS_AND_AI_WORKER_SHARED_NEUTRAL_JSON_SOURCE
                    ) else []
                    self.assertEqual(covering_source_entries(source, entries), expected)

    def test_f4b_app_authority_sources_compile_into_no_worker(self) -> None:
        app_sources = set(source_paths(target_block(self.project, "MacScopeApp")))
        worker_targets = (
            "AIAgentWorkerXPCService",
            "AnalysisWorkerXPCService",
            "PluginXPCService",
        )
        for source in F4B_APP_AUTHORITY_SOURCES:
            with self.subTest(source=source):
                self.assertNotEqual(covering_source_entries(source, app_sources), [])
                for target in worker_targets:
                    entries = set(source_paths(target_block(self.project, target)))
                    self.assertEqual(
                        covering_source_entries(source, entries),
                        [],
                        f"app-owned F4B authority escaped into {target}: {source}",
                    )

    def test_f4b_worker_protocol_has_no_read_execution_or_escalated_authority(self) -> None:
        forbidden = re.compile(
            r"\b(?:SwiftUI|AppKit|WorkspaceStore|WorkspaceDatabase|WorkspaceCommand|"
            r"TypedReadRegistry|Phase2ReadProjector|Phase2EvidenceAcceptor|"
            r"Phase2ReadAuthorization|PreparedPhase2Read|ReadExecutor|ToolExecutor|"
            r"executeTool|performTool|authorizeRead|acceptEvidence|"
            r"FileManager|FileHandle|InputStream|OutputStream|Process|NSTask|posix_spawn|"
            r"fork|exec|popen|NSWorkspace|WorkspaceScriptingAPI|ScriptValue|MCPServer|"
            r"MCPLauncher|CLIRunner|AppleScript|AppleEvent|NSScriptCommand|NSAppleScript|"
            r"Debugger[A-Za-z0-9_]*|LocalLLDBDebuggerClient|MachOPatchWriter|writeMemory|"
            r"writeRegister|setBreakpoint|removeBreakpoint|patchBytes|markDocumentMutated|"
            r"UserDefaults|AppStorage|SceneStorage|NSManagedObjectContext|ModelContext|"
            r"Keychain|SecItem[A-Za-z0-9_]*|URLCredential|Authorization|Bearer|apiToken|"
            r"loadModel|unloadModel|downloadModel|discoverModels|performModelLifecycle|"
            r"Retry[A-Za-z0-9_]*|retry|fallback|Fallback[A-Za-z0-9_]*)\b|"
            r"\bsystem\s*\("
        )
        for source in F4B_WORKER_PROTOCOL_BOUNDARY_SOURCES:
            with self.subTest(source=source):
                path = REPO_ROOT / "MacScope" / source
                self.assertTrue(path.is_file(), f"F4B boundary source is missing: MacScope/{source}")
                text = without_swift_comments(path.read_text(encoding="utf-8"))
                self.assertIsNone(forbidden.search(text))

    def test_f4b_new_protocol_artifacts_have_no_network_or_endpoint_authority(self) -> None:
        forbidden = re.compile(
            r"(?:https?://|/api/|/v1/|\b(?:URL|URLComponents|URLRequest|URLSession|"
            r"URLProtocol|HTTPCookieStorage|URLCache|NWConnection|NWListener|Network)\b)"
        )
        for source in F4B_SHARED_PROTOCOL_SOURCES + F4B_WORKER_CORE_SOURCES:
            with self.subTest(source=source):
                path = REPO_ROOT / "MacScope" / source
                self.assertTrue(path.is_file(), f"F4B protocol source is missing: MacScope/{source}")
                text = without_swift_comments(path.read_text(encoding="utf-8"))
                self.assertIsNone(forbidden.search(text))

    def test_registry_exposes_only_qualified_workspace_decompiler_debugger_and_rea_read_tools(self) -> None:
        source = REPO_ROOT / "MacScope/AIAgentWorkerCore/Phase2ProductionToolRegistry.swift"
        self.assertTrue(source.is_file(), "F4B production tool registry source is missing")
        text = without_swift_comments(source.read_text(encoding="utf-8"))

        operation_literals = set(
            re.findall(r'operationID:\s*"([^"]+)"', text)
        )
        self.assertEqual(
            operation_literals,
            {
                "workspace.summary", "selection.explain", "function.review",
                "decompiler.native.result", "decompiler.macscope.result", "decompiler.compare",
                "debugger.summary", "debugger.frames", "debugger.registers",
                "debugger.variables", "debugger.memory",
                "rea.results.list", "rea.results.get",
            },
        )
        workspace_block = re.search(
            r"let workspaceEntries:.*?= \[(.*?)\]\s*let debuggerEntries:",
            text,
            re.DOTALL,
        )
        debugger_block = re.search(
            r"let debuggerEntries:.*?= \[(.*?)\]\s*let reaEntries:",
            text,
            re.DOTALL,
        )
        self.assertIsNotNone(workspace_block)
        self.assertIsNotNone(debugger_block)
        self.assertEqual(
            set(re.findall(r'operationID:\s*"([^"]+)"', workspace_block.group(1))),
            {
                "workspace.summary", "selection.explain", "function.review",
                "decompiler.native.result", "decompiler.macscope.result",
                "decompiler.compare",
            },
            "the active registry may expose only the qualified workspace and decompiler reads",
        )
        self.assertEqual(
            set(re.findall(r'operationID:\s*"([^"]+)"', debugger_block.group(1))),
            {
                "debugger.summary", "debugger.frames", "debugger.registers",
                "debugger.variables", "debugger.memory",
            },
            "R2 may add only the five bounded debugger-read tools",
        )
        rea_block = re.search(
            r"let reaEntries:.*?= \[(.*?)\]\s*entries =", text, re.DOTALL
        )
        self.assertIsNotNone(rea_block)
        self.assertEqual(
            set(re.findall(r'operationID:\s*"([^"]+)"', rea_block.group(1))),
            {"rea.results.list", "rea.results.get"},
            "R2 REA reads are bounded accepted-evidence list and exact-page retrieval only",
        )
        self.assertIn(
            "entries = workspaceEntries + (version == .assistantR2 ? debuggerEntries + reaEntries : [])",
            text,
        )
        function_literals = set(
            re.findall(
                r'functionName:\s*"(macscope_[a-z0-9_]+_v[0-9]+)"',
                text,
            )
        )
        self.assertEqual(
            function_literals,
            {
                "macscope_workspace_summary_v1",
                "macscope_selection_explain_v1",
                "macscope_function_review_v1",
                "macscope_native_decompilation_v1",
                "macscope_decompilation_v1",
                "macscope_decompiler_compare_v1",
                "macscope_debugger_summary_v1",
                "macscope_debugger_frames_v1",
                "macscope_debugger_registers_v1",
                "macscope_debugger_variables_v1",
                "macscope_debugger_memory_v1",
                "macscope_rea_results_list_v1", "macscope_rea_results_get_v1",
            },
        )
        self.assertIsNone(
            re.search(
                r"(?i)\b(?:generic|dynamic|arbitrary|query|sql|script|shell|filesystem|"
                r"mutation|write)[A-Za-z0-9_]*(?:tool|function|registry)\b",
                text,
            )
        )

    def test_f4b_preserves_only_literal_loopback_chat_network_route(self) -> None:
        endpoint = without_swift_comments(
            (REPO_ROOT / "MacScope/AIAgentWorkerCore/Phase2LoopbackEndpoint.swift")
            .read_text(encoding="utf-8")
        )
        client = without_swift_comments(
            (REPO_ROOT / "MacScope/AIAgentWorkerCore/Phase2OpenAIChatHTTPClient.swift")
            .read_text(encoding="utf-8")
        )
        self.assertIn('case ipv4 = "127.0.0.1"', endpoint)
        self.assertIn('case ipv6 = "::1"', endpoint)
        self.assertIn('components.scheme == "http"', endpoint)
        self.assertNotIn("https://", endpoint)
        self.assertIn('endpoint + "/v1/chat/completions"', client)
        provider_routes = set(re.findall(r'"(/v1/[A-Za-z0-9_./-]+)"', client))
        self.assertEqual(provider_routes, {"/v1/chat/completions"})

    def test_ai_worker_has_only_its_frozen_explicit_sources(self) -> None:
        worker_sources = set(
            source_paths(target_block(self.project, "AIAgentWorkerXPCService"))
        )
        self.assertEqual(worker_sources, set(AI_WORKER_SOURCES))
        profile = without_swift_comments((REPO_ROOT / "MacScope/Models/Reconstruction/"
                                         "ReconstructionSourceProfile.swift").read_text(encoding="utf-8"))
        self.assertEqual(set(re.findall(r"(?m)^import\s+(\w+)\s*$", profile)), {"Foundation"})
        self.assertNotRegex(profile, r"\b(?:Process|NSTask|posix_spawn|exec|FileManager|"
                            r"FileHandle|URLSession|NSXPCConnection|WorkspaceStore)\b")
        self.assertIn("guard profile == .scalarU32V1 else { throw Failure.disabledProfile }", profile)

    def test_reconstruction_prompt_projection_has_exact_target_membership(self) -> None:
        app_sources = set(source_paths(target_block(self.project, "MacScopeApp")))
        for source in RECONSTRUCTION_AI_WORKER_PROJECTION_SOURCES:
            with self.subTest(source=source):
                self.assertTrue((REPO_ROOT / "MacScope" / source).is_file())
                self.assertEqual(covering_source_entries(source, app_sources), ["Services"])
                for target in ("AIAgentWorkerXPCService", "CoreTests"):
                    entries = set(source_paths(target_block(self.project, target)))
                    self.assertEqual(covering_source_entries(source, entries), [source])

    def test_app_globs_exclude_ai_worker_only_sources(self) -> None:
        app_sources = set(source_paths(target_block(self.project, "MacScopeApp")))
        for source in AI_WORKER_RUNTIME_ONLY_SOURCES:
            with self.subTest(worker_only_source=source):
                self.assertEqual(
                    covering_source_entries(source, app_sources),
                    [],
                    f"worker-only AI source is covered by app source entries: {source}",
                )

    def test_ai_worker_core_has_closed_app_gate_support_membership(self) -> None:
        app_sources = self.app_closure()
        core_test_sources = set(source_paths(target_block(self.project, "CoreTests")))
        ai_worker_sources = set(
            source_paths(target_block(self.project, "AIAgentWorkerXPCService"))
        )
        for source in AI_WORKER_CORE_SOURCES:
            with self.subTest(source=source):
                self.assertTrue((REPO_ROOT / "MacScope" / source).is_file())
                expected_app_entries = (
                    [source] if source in AI_WORKER_APP_GATE_SUPPORT_SOURCES else []
                )
                self.assertEqual(
                    covering_source_entries(source, app_sources),
                    expected_app_entries,
                )
                self.assertEqual(covering_source_entries(source, ai_worker_sources), [source])
                self.assertEqual(covering_source_entries(source, core_test_sources), [source])

    def test_ai_worker_direct_test_sources_have_exact_target_membership(self) -> None:
        app_sources = set(source_paths(target_block(self.project, "MacScopeApp")))
        core_test_sources = set(source_paths(target_block(self.project, "CoreTests")))
        ai_worker_sources = set(
            source_paths(target_block(self.project, "AIAgentWorkerXPCService"))
        )
        for source in AI_WORKER_DIRECT_TEST_SOURCES:
            with self.subTest(source=source):
                self.assertTrue((REPO_ROOT / "MacScope" / source).is_file())
                self.assertEqual(covering_source_entries(source, app_sources), [])
                self.assertEqual(covering_source_entries(source, ai_worker_sources), [source])
                self.assertEqual(covering_source_entries(source, core_test_sources), [source])

    def test_app_rejects_ai_worker_runtime_implementations(self) -> None:
        app_sources = set(source_paths(target_block(self.project, "MacScopeApp")))
        for source in AI_WORKER_APP_FORBIDDEN_RUNTIME_SOURCES:
            with self.subTest(source=source):
                self.assertEqual(
                    covering_source_entries(source, app_sources),
                    [],
                    f"AI worker runtime implementation escaped into MacScopeApp: {source}",
                )

    def test_provider_discovery_app_authority_has_no_network_or_mutation_surface(self) -> None:
        forbidden = re.compile(
            r"\b(?:URLSession|URLRequest|URLProtocol|NWConnection|NWListener|Process|NSTask|"
            r"posix_spawn|fork|exec|popen|WorkspaceStore|WorkspaceDatabase|MachOPatchWriter|"
            r"loadModel|unloadModel|downloadModel|Authorization|Bearer|Keychain)\b"
        )
        for source in AI_PROVIDER_DISCOVERY_APP_SOURCES:
            with self.subTest(source=source):
                path = REPO_ROOT / "MacScope" / source
                self.assertTrue(path.is_file(), f"provider discovery source is missing: MacScope/{source}")
                text = without_swift_comments(path.read_text(encoding="utf-8"))
                self.assertIsNone(forbidden.search(text))

    def test_provider_inventory_worker_core_excludes_lifecycle_and_remote_authority(self) -> None:
        inventory_sources = (
            "AIAgentWorkerCore/Phase2NativeModelCatalogDecoder.swift",
            "AIAgentWorkerCore/Phase2NativeModelDiscoveryHTTPClient.swift",
        )
        forbidden = re.compile(
            r"(?:/api/v1/models/(?:load|unload|download)|\b(?:Authorization|Bearer|Keychain|"
            r"WorkspaceStore|WorkspaceDatabase|Process|NSTask|posix_spawn|fork|exec|popen)\b)"
        )
        for source in inventory_sources:
            with self.subTest(source=source):
                path = REPO_ROOT / "MacScope" / source
                self.assertTrue(path.is_file(), f"provider inventory source is missing: MacScope/{source}")
                text = without_swift_comments(path.read_text(encoding="utf-8"))
                self.assertIsNone(forbidden.search(text))

    def test_provider_lifecycle_app_authority_has_no_network_provider_route_or_persistence(self) -> None:
        forbidden = re.compile(
            r"(?:/api/v1/models/(?:load|unload|download)|\b(?:URLSession|URLRequest|URLProtocol|"
            r"NWConnection|NWListener|Process|NSTask|posix_spawn|fork|exec|popen|FileManager|"
            r"FileHandle|WorkspaceStore|WorkspaceDatabase|MachOPatchWriter|UserDefaults|"
            r"NSManagedObjectContext|ModelContext|Authorization|Bearer|Keychain)\b)"
        )
        for source in AI_PROVIDER_LIFECYCLE_APP_SOURCES:
            with self.subTest(source=source):
                path = REPO_ROOT / "MacScope" / source
                self.assertTrue(
                    path.is_file(),
                    f"provider lifecycle app source is missing: MacScope/{source}",
                )
                text = without_swift_comments(path.read_text(encoding="utf-8"))
                self.assertIsNone(forbidden.search(text))

    def test_provider_lifecycle_worker_core_has_only_fixed_mutation_routes(self) -> None:
        source = "AIAgentWorkerCore/Phase2NativeModelLifecycleHTTPClient.swift"
        path = REPO_ROOT / "MacScope" / source
        self.assertTrue(
            path.is_file(),
            f"provider lifecycle worker source is missing: MacScope/{source}",
        )
        text = without_swift_comments(path.read_text(encoding="utf-8"))
        routes = set(
            re.findall(
                r'''["'](/api/v1/models/[A-Za-z0-9_/-]+)["']''',
                text,
            )
        )
        self.assertEqual(
            routes,
            {"/api/v1/models/load", "/api/v1/models/unload"},
        )
        forbidden = re.compile(
            r"(?:/api/v1/models/download|\b(?:Authorization|Bearer|Keychain|FileManager|"
            r"FileHandle|WorkspaceStore|WorkspaceDatabase|Process|NSTask|posix_spawn|fork|"
            r"exec|popen|UserDefaults|NSManagedObjectContext|ModelContext)\b)"
        )
        self.assertIsNone(forbidden.search(text))

    def test_provider_selection_readiness_sources_are_app_only(self) -> None:
        app_sources = set(source_paths(target_block(self.project, "MacScopeApp")))
        xpc_targets = {
            target
            for target in re.findall(r"(?m)^  ([A-Za-z0-9_]+):\n", self.project)
            if re.search(
                r"(?m)^    type: xpc-service$",
                target_block(self.project, target),
            )
        }
        xpc_sources = {
            target: set(source_paths(target_block(self.project, target)))
            for target in xpc_targets
        }

        for source in AI_PROVIDER_SELECTION_ALL_APP_SOURCES:
            with self.subTest(source=source):
                path = REPO_ROOT / "MacScope" / source
                self.assertTrue(
                    path.is_file(),
                    f"provider selection/readiness source is missing: MacScope/{source}",
                )
                self.assertIn(source.split("/", maxsplit=1)[0], app_sources)
                for target, entries in xpc_sources.items():
                    self.assertEqual(
                        covering_source_entries(source, entries),
                        [],
                        f"app-only provider selection source is covered by {target}: {source}",
                    )

    def test_provider_selection_readiness_has_no_provider_or_inference_authority(self) -> None:
        forbidden = re.compile(
            r"(?:/api/v1/(?:models|chat)|/v1/chat/completions|"
            r"\b(?:URLSession|URLRequest|URLProtocol|NWConnection|NWListener|NSXPCConnection|"
            r"Authorization|Bearer|Keychain|SecItem[A-Za-z0-9_]*|URLCredential|apiToken|"
            r"downloadModel|modelDownload|Process|NSTask|posix_spawn|fork|exec|system|popen|"
            r"NSWorkspace|AIAgentXPCInferenceProvider|Phase2InferenceRunner|"
            r"Phase2InferenceProviding|Phase2AIWorkerConfiguration|runInference)\b|"
            r"proxy\.(?:configure|run)\b)"
        )
        for source in AI_PROVIDER_SELECTION_APP_SOURCES:
            with self.subTest(source=source):
                path = REPO_ROOT / "MacScope" / source
                self.assertTrue(
                    path.is_file(),
                    f"provider selection/readiness source is missing: MacScope/{source}",
                )
                text = without_swift_comments(path.read_text(encoding="utf-8"))
                self.assertIsNone(forbidden.search(text))

    def test_provider_selection_integration_adds_no_local_ai_authority(self) -> None:
        # These integration files contain older, unrelated ProcessInfo/AppStorage usage, so scan
        # ("Process" followed by a lowercase word is UI prose such as "Process spawning")
        # the complete files for concrete provider authority while excluding those broad tokens.
        forbidden_authority = re.compile(
            r"(?:/api/v1/(?:models|chat)|/v1/chat/completions|"
            r"\b(?:URLSession|URLRequest|URLProtocol|NWConnection|NWListener|NSXPCConnection|"
            r"Authorization|Bearer|Keychain|SecItem[A-Za-z0-9_]*|URLCredential|apiToken|"
            r"downloadModel|modelDownload|Process(?!Info)(?! +[a-z])|NSTask|posix_spawn|fork|exec|popen|NSWorkspace|"
            r"AIAgentXPCInferenceProvider|Phase2InferenceRunner|Phase2InferenceProviding|"
            r"Phase2AIWorkerConfiguration|runInference)\b|proxy\.(?:configure|run)\b)"
            r"|\bsystem\s*\(\s*(?:#?\"|#?')"
        )
        for source in AI_PROVIDER_SELECTION_INTEGRATION_APP_SOURCES:
            with self.subTest(source=source):
                path = REPO_ROOT / "MacScope" / source
                self.assertTrue(
                    path.is_file(),
                    f"provider selection integration source is missing: MacScope/{source}",
                )
                text = without_swift_comments(path.read_text(encoding="utf-8"))
                self.assertIsNone(forbidden_authority.search(text))

    def test_provider_selection_persistence_authority_is_exclusive(self) -> None:
        persistence_authority = re.compile(
            r"\b(?:UserDefaults|Codable|JSONEncoder|JSONDecoder|JSONSerialization)\b"
        )
        allowed = set(AI_PROVIDER_SELECTION_PERSISTENCE_APP_SOURCES)
        guarded_sources = (
            AI_PROVIDER_SELECTION_ALL_APP_SOURCES
            + AI_PROVIDER_CONFIGURATION_APP_SOURCES
        )
        authority_owners: set[str] = set()

        for source in guarded_sources:
            with self.subTest(source=source):
                path = REPO_ROOT / "MacScope" / source
                self.assertTrue(path.is_file(), f"F3F source is missing: MacScope/{source}")
                text = without_swift_comments(path.read_text(encoding="utf-8"))
                if persistence_authority.search(text):
                    authority_owners.add(source)
                    self.assertIn(
                        source,
                        allowed,
                        f"persistence authority escaped the designated F3F seam: {source}",
                    )

        self.assertIn(
            "Services/Phase2/Phase2LocalAIProviderPreferenceStore.swift",
            authority_owners,
        )

    def test_provider_selection_runtime_and_integration_do_not_persist_state(self) -> None:
        runtime_sources = (
            AI_PROVIDER_SELECTION_APP_SOURCES
            + AI_PROVIDER_CONFIGURATION_APP_SOURCES
        )
        forbidden_runtime_persistence = re.compile(
            r"(?:@(?:AppStorage|SceneStorage)\b|"
            r"\b(?:UserDefaults|Codable|JSONEncoder|JSONDecoder|JSONSerialization|FileManager|"
            r"FileHandle|NSManagedObjectContext|ModelContext)\b|\.write\s*\()"
        )
        for source in runtime_sources:
            with self.subTest(runtime_source=source):
                text = without_swift_comments(
                    (REPO_ROOT / "MacScope" / source).read_text(encoding="utf-8")
                )
                self.assertIsNone(forbidden_runtime_persistence.search(text))

        # Shared integration files contain unrelated legacy AppStorage preferences. They may
        # compose the designated store type, but may not implement a second local-AI store.
        forbidden_integration_persistence = re.compile(
            r"\bUserDefaults\b\s*(?:\.|\()|"
            r"\b(?:Codable|JSONEncoder|JSONDecoder|JSONSerialization|FileManager|"
            r"FileHandle|NSManagedObjectContext|ModelContext)\b|\.write\s*\(|"
            r"@(?:AppStorage|SceneStorage)\s*\(\s*[#]*[\"'][^\"']*"
            r"(?i:local.?ai|providerPreference)[^\"']*[\"']",
        )
        for source in AI_PROVIDER_SELECTION_INTEGRATION_APP_SOURCES:
            with self.subTest(integration_source=source):
                text = without_swift_comments(
                    (REPO_ROOT / "MacScope" / source).read_text(encoding="utf-8")
                )
                self.assertIsNone(forbidden_integration_persistence.search(text))

    def test_provider_selection_persisted_schema_has_only_desired_fields(self) -> None:
        preference = without_swift_comments(
            (
                REPO_ROOT
                / "MacScope/Models/Phase2/Phase2LocalAIProviderPreference.swift"
            ).read_text(encoding="utf-8")
        )
        store = without_swift_comments(
            (
                REPO_ROOT
                / "MacScope/Services/Phase2/Phase2LocalAIProviderPreferenceStore.swift"
            ).read_text(encoding="utf-8")
        )

        desired_fields = set(
            re.findall(
                r"(?m)^    let ([A-Za-z_][A-Za-z0-9_]*):",
                preference[
                    preference.index("struct Phase2LocalAIDesiredSelection"):
                    preference.index("struct Phase2LocalAIProviderPreference")
                ],
            )
        )
        preference_fields = set(
            re.findall(
                r"(?m)^    let ([A-Za-z_][A-Za-z0-9_]*):",
                preference[preference.index("struct Phase2LocalAIProviderPreference"):],
            )
        )
        self.assertEqual(desired_fields, {"modelKey", "maximumTokens"})
        self.assertEqual(
            preference_fields,
            {
                "endpointOrigin",
                "requestTimeoutMilliseconds",
                "resourceTimeoutMilliseconds",
                "desiredSelection",
                "inferencePolicy",
            },
        )

        wire_match = re.search(
            r"(?ms)^    private struct Wire: Codable \{(?P<body>.*?)^    \}",
            store,
        )
        self.assertIsNotNone(wire_match, "versioned preference Wire schema is missing")
        wire = wire_match.group("body") if wire_match is not None else ""
        wire_fields = set(
            re.findall(r"(?m)^        let ([A-Za-z_][A-Za-z0-9_]*):", wire)
        )
        self.assertEqual(
            wire_fields,
            {
                "schemaVersion",
                "endpointOrigin",
                "requestTimeoutMilliseconds",
                "resourceTimeoutMilliseconds",
                "desiredModelKey",
                "maximumTokens",
                "inferencePolicy",
            },
        )
        forbidden_persisted_state = re.compile(
            r"(?i)\b(?:profileID|generation|inventory|loadedInstances?|ownedInstances?|ownership|"
            r"readiness|ready|diagnostic|activity|revision|credential|"
            r"Phase2AIProviderConfiguration)\b"
        )
        self.assertIsNone(forbidden_persisted_state.search(wire))

    def test_provider_selection_domain_and_view_do_not_compose_concrete_services(self) -> None:
        presentation_sources = (
            "Models/Phase2/Phase2LocalAISelection.swift",
            "Features/Settings/LocalAIProviderSettingsView.swift",
        )
        forbidden = re.compile(
            r"\b(?:AIAgentXPCModelDiscoveryService|AIAgentXPCModelLifecycleService|"
            r"AIAgentXPCModelDiscoveryTransport|AIAgentXPCModelLifecycleTransport)\b"
        )
        for source in presentation_sources:
            with self.subTest(source=source):
                path = REPO_ROOT / "MacScope" / source
                self.assertTrue(
                    path.is_file(),
                    f"provider selection presentation source is missing: MacScope/{source}",
                )
                text = without_swift_comments(path.read_text(encoding="utf-8"))
                self.assertIsNone(forbidden.search(text))

    def test_ready_inference_composition_has_one_exact_app_only_source(self) -> None:
        self.assertEqual(
            READY_INFERENCE_COMPOSITION_APP_SOURCES,
            ("Services/Phase2/Phase2ReadyInferenceCoordinator.swift",),
        )
        app_sources = set(source_paths(target_block(self.project, "MacScopeApp")))
        xpc_targets = {
            target
            for target in re.findall(r"(?m)^  ([A-Za-z0-9_]+):\n", self.project)
            if re.search(
                r"(?m)^    type: xpc-service$",
                target_block(self.project, target),
            )
        }

        for source in READY_INFERENCE_COMPOSITION_APP_SOURCES:
            with self.subTest(source=source):
                path = REPO_ROOT / "MacScope" / source
                self.assertTrue(
                    path.is_file(),
                    f"ready-inference composition source is missing: MacScope/{source}",
                )
                self.assertEqual(
                    covering_source_entries(source, app_sources),
                    ["Services"],
                )
                for target in xpc_targets:
                    entries = set(source_paths(target_block(self.project, target)))
                    self.assertEqual(
                        covering_source_entries(source, entries),
                        [],
                        f"app-only ready-inference coordinator is covered by {target}: {source}",
                    )

    def test_ready_inference_coordinator_exclusively_owns_concrete_composition(self) -> None:
        allowed_owners = {
            "Services/Phase2/Phase2ReadyInferenceCoordinator.swift",
            "Services/Phase2/Phase2InferenceRunner.swift",
            "Services/Phase2/AIAgentXPCInferenceProvider.swift",
            "Tests/CoreTests/AIAgentXPCWorkerProcessReceiptTests.swift",
            "Tests/Phase2Tests/AIAgentXPCInferenceProviderTests.swift",
            "Tests/Phase2Tests/Phase2InferenceBoundaryTests.swift",
            "Tests/CoreTests/Phase2LiveAIAgentXPCProductionGateTests.swift",
            "Tests/Phase2Tests/Phase2QualificationInferenceMeasurementObserverTests.swift",
            "Services/Phase2/QualificationGate/Phase2ProductionProtocolFixtureExecutor.swift",
            # App-only bounded hypothesis service: production uses the existing coordinator;
            # its injected-provider overload and request validation support deterministic tests.
            "Services/ObjectiveC/ObjCSignatureHypothesisInference.swift",
            "Tests/Phase2Tests/ObjCSignatureHypothesisInferenceTests.swift",
        }
        concrete_composition = re.compile(
            r"\b(?:AIAgentXPCInferenceProvider|Phase2InferenceRunner)\b"
        )
        owners: set[str] = set()

        for root in SWIFT_SOURCE_ROOTS:
            for path in (REPO_ROOT / "MacScope" / root).rglob("*.swift"):
                source = path.relative_to(REPO_ROOT / "MacScope").as_posix()
                text = without_swift_comments(path.read_text(encoding="utf-8"))
                if concrete_composition.search(text):
                    owners.add(source)
                    self.assertIn(
                        source,
                        allowed_owners,
                        f"concrete ready-inference composition escaped its coordinator: {source}",
                    )

        self.assertIn(
            "Services/Phase2/Phase2ReadyInferenceCoordinator.swift",
            owners,
        )
        hypothesis_source = "Services/ObjectiveC/ObjCSignatureHypothesisInference.swift"
        hypothesis = without_swift_comments(
            (REPO_ROOT / "MacScope" / hypothesis_source).read_text(encoding="utf-8")
        )
        self.assertNotRegex(hypothesis, r"\b(?:AIAgentXPCInferenceProvider|AIAgentXPCTransport|"
                            r"NSXPCConnection|URLSession|URLRequest)\b")
        self.assertIn("coordinator: any Phase2AssistantInferenceCoordinating", hypothesis)
        self.assertIn("coordinator.run(request: request)", hypothesis)
        self.assertIn("provider: (any Phase2InferenceProviding)?", hypothesis)
        self.assertIn("request.toolHandles.isEmpty", hypothesis)
        def bounded_hypothesis_composition(text: str) -> bool:
            # A runner may be constructed only in the injected-provider test seam, never in
            # the production coordinator overload. Pin the common refusal guard as well.
            provider_body = re.search(
                r"provider: \(any Phase2InferenceProviding\)\?\s*\) async -> Result \{\s*"
                r"guard let provider else \{ return \.unavailable \}\s*"
                r"return await boundedRun\(request: request\) \{\s*"
                r"Self\.result\(from: await Phase2InferenceRunner\(\)\.run\("
                r"request: request, provider: provider\)\)\s*\}\s*\}", text
            )
            coordinator_body = re.search(
                r"coordinator: any Phase2AssistantInferenceCoordinating\s*\) async -> Result \{\s*"
                r"await boundedRun\(request: request\) \{\s*"
                r"switch await coordinator\.run\(request: request\) \{\s*"
                r"case \.notReady, \.busy: return \.unavailable\s*"
                r'case \.invalidRequest: return \.failed\("The hypothesis request was refused\."\)\s*'
                r"case \.providerAuthorityChanged: return \.unavailable\s*"
                r"case \.finished\(_, let outcome\): return Self\.result\(from: outcome\)\s*"
                r"\}\s*\}\s*\}", text
            )
            guard = re.search(
                r"private func boundedRun\(\s*request: Phase2InferenceRequest,\s*"
                r"operation: @escaping @MainActor @Sendable \(\) async -> Result\s*"
                r"\) async -> Result \{\s*guard !Task\.isCancelled else \{ return \.cancelled \}\s*"
                r"guard request\.maximumOutputTokens == Self\.maximumOutputTokens,\s*"
                r"request\.phase == \.finalization,\s*request\.toolHandles\.isEmpty,\s*"
                r"Phase2InferenceRunner\.requestIsValid\(request\) else \{\s*"
                r'return \.failed\("The hypothesis request was refused\."\)\s*\}', text
            )
            return (provider_body is not None and coordinator_body is not None and guard is not None
                    and len(re.findall(r"\bPhase2InferenceRunner\b", text)) == 2)

        self.assertTrue(bounded_hypothesis_composition(hypothesis))
        for removed in ("Phase2InferenceRunner.requestIsValid(request)",
                        "request.phase == .finalization",
                        "request.maximumOutputTokens == Self.maximumOutputTokens",
                        "request.toolHandles.isEmpty"):
            with self.subTest(hypothesis_guard=removed):
                self.assertFalse(bounded_hypothesis_composition(hypothesis.replace(removed, "true")))
        self.assertFalse(bounded_hypothesis_composition(hypothesis.replace(
            "switch await coordinator.run(request: request)",
            "_ = await Phase2InferenceRunner().run(request: request, provider: provider)\n"
            "            switch await coordinator.run(request: request)",
        )))
        self.assertFalse(bounded_hypothesis_composition(hypothesis.replace(
            "await boundedRun(request: request) {", "do {", 1,
        )))
        store = without_swift_comments(
            (REPO_ROOT / "MacScope/Stores/WorkspaceStore+ObjCSignatureCandidates.swift")
            .read_text(encoding="utf-8")
        )
        self.assertIn(".run(request: request, coordinator: coordinator)", store)
        self.assertNotRegex(store, r"ObjCSignatureHypothesisInference\(\)\s*\.run\([^)]*provider:")
        for target in ("MacScopeAnalysisCore", "AIAgentWorkerXPCService", "PluginXPCService"):
            self.assertEqual(covering_source_entries(
                hypothesis_source, set(source_paths(target_block(self.project, target)))
            ), [], f"app-only hypothesis inference escaped into {target}")
        self.assertEqual(covering_source_entries(hypothesis_source, self.analysis_worker_closure()), [])

    def test_app_owns_exactly_one_inert_process_global_coordinator(self) -> None:
        source = without_swift_comments(
            (REPO_ROOT / "MacScope/App/MacScopeApp.swift").read_text(encoding="utf-8")
        )
        self.assertEqual(source.count("Phase2ReadyInferenceCoordinator"), 2)
        self.assertRegex(
            source,
            r"@StateObject\s+private\s+var\s+readyInferenceCoordinator:\s*"
            r"Phase2ReadyInferenceCoordinator",
        )

    def test_ui_settings_and_app_have_no_direct_ready_inference_authority(self) -> None:
        direct_authority = re.compile(
            r"\b(?:AIAgentXPCInferenceProvider|Phase2InferenceRunner|"
            r"Phase2InferenceProviding|Phase2AIWorkerConfiguration)\b|"
            r"\b(?:runInference|runReadyInference)\s*\("
        )
        for path in (REPO_ROOT / "MacScope/App").rglob("*.swift"):
            source = path.relative_to(REPO_ROOT / "MacScope").as_posix()
            with self.subTest(source=source):
                text = without_swift_comments(path.read_text(encoding="utf-8"))
                self.assertIsNone(direct_authority.search(text))
                self.assertNotRegex(text, r"readyInferenceCoordinator\s*\.\s*run\s*\(")

        feature_authority = re.compile(
            direct_authority.pattern + r"|\bPhase2ReadyInferenceCoordinator\b"
        )
        for path in (REPO_ROOT / "MacScope/Features").rglob("*.swift"):
            source = path.relative_to(REPO_ROOT / "MacScope").as_posix()
            with self.subTest(source=source):
                text = without_swift_comments(path.read_text(encoding="utf-8"))
                self.assertIsNone(feature_authority.search(text))

    def test_ready_inference_coordinator_has_no_escalated_capability_surface(self) -> None:
        source = READY_INFERENCE_COMPOSITION_APP_SOURCES[0]
        path = REPO_ROOT / "MacScope" / source
        self.assertTrue(
            path.is_file(),
            f"ready-inference composition source is missing: MacScope/{source}",
        )
        text = without_swift_comments(path.read_text(encoding="utf-8"))
        forbidden = re.compile(
            r"(?:/api/|/v1/|https?://|"
            r"\b(?:URLSession|URLRequest|URLProtocol|NWConnection|NWListener|"
            r"NSXPCConnection|NSXPCInterface|NSXPCListener|Phase2AIWorkerXPCProtocol|"
            r"AIAgentXPCTransport|proxy|configure|handshake|"
            r"Authorization|Bearer|Keychain|SecItem[A-Za-z0-9_]*|URLCredential|"
            r"apiToken|credential|secret|"
            r"UserDefaults|AppStorage|SceneStorage|Codable|JSONEncoder|JSONDecoder|"
            r"JSONSerialization|NSManagedObjectContext|ModelContext|"
            r"Process|NSTask|posix_spawn|fork|exec|system|popen|NSWorkspace|"
            r"FileManager|FileHandle|InputStream|OutputStream|"
            r"Debugger[A-Za-z0-9_]*|LocalLLDBDebuggerClient|MachOPatchWriter|"
            r"WorkspaceStore|WorkspaceDatabase|WorkspaceCommand|DocumentDirtyTracker|"
            r"UndoManager|NSPasteboard|markDocumentMutated|patchBytes|setPatch|"
            r"removePatch|writeMemory|writeRegister|setBreakpoint|removeBreakpoint|"
            r"Retry[A-Za-z0-9_]*|retry|Queue[A-Za-z0-9_]*|enqueue|"
            r"ToolExecutor|ToolExecution|executeTool|performTool|"
            r"AIAgentXPCModelDiscovery[A-Za-z0-9_]*|AIAgentXPCModelLifecycle[A-Za-z0-9_]*|"
            r"Phase2LocalModelDiscovering|Phase2LocalModelLifecycleControlling|"
            r"discoverModels|performModelLifecycle|loadModel|unloadModel|downloadModel)\b)"
        )
        self.assertIsNone(forbidden.search(text))

    def test_f3c_chat_codec_remains_pure_and_worker_only(self) -> None:
        codec_sources = (
            "AIAgentWorkerCore/Phase2OpenAIChatRequestEncoder.swift",
            "AIAgentWorkerCore/Phase2OpenAIChatStreamDecoder.swift",
        )
        forbidden = re.compile(
            r"\b(?:FileManager|FileHandle|InputStream|OutputStream|URLSession|URLRequest|"
            r"URLProtocol|NWConnection|NWListener|Process|NSTask|posix_spawn|fork|exec|"
            r"popen|UserDefaults)\b"
        )
        for source in codec_sources:
            with self.subTest(source=source):
                path = REPO_ROOT / "MacScope" / source
                self.assertTrue(path.is_file(), f"F3C codec source is missing: MacScope/{source}")
                text = without_swift_comments(path.read_text(encoding="utf-8"))
                imports = set(re.findall(r"(?m)^import\s+([A-Za-z0-9_.]+)\s*$", text))
                self.assertLessEqual(imports, {"Foundation"})
                self.assertIsNone(forbidden.search(text))

    def test_shared_neutral_json_parser_has_no_execution_network_or_workspace_authority(self) -> None:
        source = ANALYSIS_AND_AI_WORKER_SHARED_NEUTRAL_JSON_SOURCE
        text = without_swift_comments((REPO_ROOT / "MacScope" / source).read_text(encoding="utf-8"))
        imports = set(re.findall(r"(?m)^import\s+([A-Za-z0-9_.]+)\s*$", text))
        self.assertEqual(imports, {"Foundation"})
        forbidden = re.compile(
            r"\b(?:SwiftUI|AppKit|WorkspaceStore|WorkspaceDatabase|WorkspaceCommand|"
            r"URLSession|URLRequest|URLProtocol|NWConnection|NWListener|NSXPCConnection|"
            r"FileManager|FileHandle|InputStream|OutputStream|Process|NSTask|"
            r"posix_spawn|fork|exec|popen|UserDefaults|Phase2InferenceRunner|"
            r"Phase2OpenAIChatHTTPClient|Phase2ProductionToolRegistry)\b"
        )
        self.assertIsNone(forbidden.search(text))
        self.assertEqual(covering_source_entries(source, self.analysis_worker_closure()), [source])

    def test_non_ai_workers_exclude_all_ai_sources(self) -> None:
        for target in ("PluginXPCService", "AnalysisWorkerXPCService"):
            entries = (self.analysis_worker_closure() if target == "AnalysisWorkerXPCService"
                       else set(source_paths(target_block(self.project, target))))
            for source in AI_WORKER_SOURCES:
                if target == "AnalysisWorkerXPCService" and source in (
                    ANALYSIS_AND_AI_WORKER_SHARED_RECONSTRUCTION_MODEL_SOURCES
                    + (ANALYSIS_AND_AI_WORKER_SHARED_NEUTRAL_JSON_SOURCE,)
                ):
                    continue
                with self.subTest(target=target, ai_source=source):
                    self.assertEqual(
                        covering_source_entries(source, entries),
                        [],
                        f"AI source is covered by {target}: {source}",
                    )

    def test_ai_worker_requires_mutual_peer_identity_before_resume(self) -> None:
        worker_main = (REPO_ROOT / "MacScope/AIAgentWorkerService/main.swift").read_text(
            encoding="utf-8"
        )
        app_transport = (
            REPO_ROOT / "MacScope/Services/Phase2/AIAgentXPCTransport.swift"
        ).read_text(encoding="utf-8")
        discovery_transport = (
            REPO_ROOT
            / "MacScope/Services/Phase2/AIAgentXPCModelDiscoveryTransport.swift"
        ).read_text(encoding="utf-8")
        lifecycle_transport_path = (
            REPO_ROOT
            / "MacScope/Services/Phase2/AIAgentXPCModelLifecycleTransport.swift"
        )
        self.assertTrue(
            lifecycle_transport_path.is_file(),
            "signed model lifecycle transport is missing",
        )
        lifecycle_transport = lifecycle_transport_path.read_text(encoding="utf-8")
        self.assertIn(
            "newConnection.setCodeSigningRequirement(Phase2AIWorkerPeerRequirement.app)",
            worker_main,
        )
        self.assertLess(
            worker_main.index("newConnection.setCodeSigningRequirement"),
            worker_main.index("newConnection.resume()"),
        )
        self.assertIn(
            "connection.setCodeSigningRequirement(Phase2AIWorkerPeerRequirement.worker)",
            app_transport,
        )
        production_connection = app_transport.split(
            "private final class AIAgentNSXPCConnection:", 1
        )[1]
        self.assertLess(
            production_connection.index("connection.setCodeSigningRequirement"),
            production_connection.index("connection.resume()"),
        )
        self.assertIn(
            "connection.setCodeSigningRequirement(Phase2AIWorkerPeerRequirement.worker)",
            discovery_transport,
        )
        self.assertLess(
            discovery_transport.index("connection.setCodeSigningRequirement"),
            discovery_transport.index("connection.resume()"),
        )
        self.assertIn("proxy.handshake", discovery_transport)
        self.assertIn("proxy.discoverModels", discovery_transport)
        self.assertNotIn("proxy.configure", discovery_transport)
        self.assertNotIn("proxy.run", discovery_transport)
        self.assertIn(
            "connection.setCodeSigningRequirement(Phase2AIWorkerPeerRequirement.worker)",
            lifecycle_transport,
        )
        self.assertIn(
            "serviceName: NSXPCAIWorkerModelLifecycleTransport.serviceName",
            lifecycle_transport,
        )
        lifecycle_connection_wrapper = lifecycle_transport.index(
            "private final class Phase2AIWorkerModelLifecycleNSXPCConnection"
        )
        self.assertLess(
            lifecycle_transport.index(
                "connection.setCodeSigningRequirement", lifecycle_connection_wrapper
            ),
            lifecycle_transport.index("self.connection = connection", lifecycle_connection_wrapper),
        )
        self.assertIn("proxy.handshake", lifecycle_transport)
        self.assertIn("proxy.performModelLifecycle", lifecycle_transport)
        self.assertNotIn("proxy.configure", lifecycle_transport)
        self.assertNotIn("proxy.run", lifecycle_transport)
        self.assertNotIn("proxy.discoverModels", lifecycle_transport)

    def test_projection_sources_have_no_external_capability_surface(self) -> None:
        for source in PROJECTION_SOURCES:
            with self.subTest(source=source):
                path = REPO_ROOT / "MacScope" / source
                self.assertTrue(path.is_file(), f"projection source is missing: MacScope/{source}")
                text = without_swift_comments(
                    path.read_text(encoding="utf-8")
                )
                imports = set(re.findall(r"(?m)^import\s+([A-Za-z0-9_.]+)\s*$", text))
                self.assertLessEqual(imports, {"Foundation"})
                self.assertIsNone(FORBIDDEN_PROJECTION_CAPABILITIES.search(text))

    def test_grounded_context_sources_are_pure_and_app_only(self) -> None:
        for source in GROUNDED_CONTEXT_SOURCES:
            with self.subTest(source=source):
                path = REPO_ROOT / "MacScope" / source
                self.assertTrue(path.is_file(), f"context source is missing: MacScope/{source}")
                text = without_swift_comments(path.read_text(encoding="utf-8"))
                imports = set(re.findall(r"(?m)^import\s+([A-Za-z0-9_.]+)\s*$", text))
                self.assertLessEqual(imports, {"Foundation", "CryptoKit"})
                self.assertIsNone(FORBIDDEN_CONTEXT_CAPABILITIES.search(text))

    def test_inference_turn_boundary_is_pure_and_app_only(self) -> None:
        xpc_targets = {
            target
            for target in re.findall(r"(?m)^  ([A-Za-z0-9_]+):\n", self.project)
            if re.search(
                r"(?m)^    type: xpc-service$",
                target_block(self.project, target),
            )
        }
        xpc_sources = {
            target: set(source_paths(target_block(self.project, target)))
            for target in xpc_targets
        }
        for source in INFERENCE_TURN_BOUNDARY_SOURCES:
            with self.subTest(source=source):
                path = REPO_ROOT / "MacScope" / source
                self.assertTrue(
                    path.is_file(),
                    f"inference turn-boundary source is missing: MacScope/{source}",
                )
                text = without_swift_comments(path.read_text(encoding="utf-8"))
                imports = set(re.findall(r"(?m)^import\s+([A-Za-z0-9_.]+)\s*$", text))
                self.assertLessEqual(imports, {"Foundation", "CryptoKit"})
                self.assertIsNone(FORBIDDEN_INFERENCE_TURN_CAPABILITIES.search(text))

                for target, entries in xpc_sources.items():
                    covering_entries = [
                        entry
                        for entry in entries
                        if source == entry or source.startswith(entry.rstrip("/") + "/")
                    ]
                    self.assertEqual(
                        covering_entries,
                        [],
                        f"app-only inference source is covered by {target}: {source}",
                    )


if __name__ == "__main__":
    unittest.main()
