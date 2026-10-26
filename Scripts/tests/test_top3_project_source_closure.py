#!/usr/bin/env python3
"""Hosted-safe source-closure gates for the unified MachOKit/Top3 integration."""

from __future__ import annotations

import json
import pathlib
import re
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
PROJECT = ROOT / "MacScope" / "project.yml"
SWIFT_ASSEMBLY_IDENTITY = (
    ROOT / "ThirdParty" / "SwiftAssemblyVendor" / "SOURCE_IDENTITY.json"
)
DYLD_PROVIDER_SEAM = (
    ROOT / "MacScope" / "Services" / "DyldCacheAnalysis"
    / "DyldCacheAnalysisProviding.swift"
)
MACHOKIT_WORKER_PROVIDER = (
    ROOT / "MacScope" / "AnalysisWorkerService"
    / "MachOKitDyldCacheAnalysisProvider.swift"
)
DYLD_WIRE_CODEC = ROOT / "MacScope" / "Services" / "XPC" / "DyldCacheAnalysisWireCodec.swift"
DYLD_WORKER_SERVICE = (
    ROOT / "MacScope" / "Services" / "XPC" / "DyldCacheAnalysisWorkerService.swift"
)

# The worker target's own sources: its service tail and resources (exact). Everything else it
# compiles comes from the MacScopeAnalysisCore static library it links (D12 layer 3).
WORKER_OWN_SOURCES = frozenset({
    "../ThirdParty/REA/generated/MacScopeREAKernel.js",
    "../ThirdParty/REA/licenses",
    "AnalysisWorkerService/MachOKitDyldCacheAnalysisProvider.swift",
    "AnalysisWorkerService/NativeParserEngines.swift",
    "AnalysisWorkerService/AnalysisWorkerProcessControl.swift",
    "AnalysisWorkerService/PatternNativeJob.swift",
    "AnalysisWorkerService/REAJavaScriptHost.swift",
    "AnalysisWorkerService/main.swift",
    "Services/XPC/OwnedChildWire.swift",
    "Services/XPC/PosixChildProcessOps.swift",
    "Resources/SDKCallSignaturePack.json",
})

# MacScopeAnalysisCore is bounded structurally rather than file by file (a per-file pin went red
# on main three times as analysis lanes added engine files): every core source lives under the
# engine folders Models/ and Services/, outside the app-only areas below, or is one of the
# reviewed cross-folder sources. WORKER_FORBIDDEN stays explicit.
CORE_ENGINE_ROOTS = ("Models/", "Services/")
CORE_APP_ONLY_ROOTS = (
    "Models/Documents/",
    "Models/Phase2/",
    "Services/Debugger/",
    "Services/DebugSymbols/",
    "Services/Documents/",
    "Services/NativeDecompilerXPC/",
    "Services/Phase2/",
    "Services/Scripting/",
)
CORE_CROSS_FOLDER_SOURCES = frozenset({
    # Neutral strict JSON parser shared with the AI worker (no authority; phase2_r1 pins it).
    "AIAgentWorkerCore/Phase2ProductionJSONSchema.swift",
    # Generated REA identity the worker's REA host checks.
    "../ThirdParty/REA/generated/REAEmbeddedIdentity.swift",
    # Terminal runtime authority model the analysis XPC principal reads.
    "Models/Phase2/Phase2TerminalRuntimeAuthority.swift",
    # Analyst finding envelopes carry these neutral values across the analysis boundary.
    # Registry, evidence acceptance, context compilation and inference stay app-owned.
    "Models/Phase2/Phase2GroundedContext.swift",
    "Models/Phase2/Phase2ReadIdentity.swift",
    "Models/Phase2/Phase2ReadOperation.swift",
    "Models/Phase2/Phase2DebuggerReadOperationID.swift",
})

WORKER_FORBIDDEN = {
    "Services/DyldCacheAnalysis/DyldCacheCatalogDifferentialComparator.swift",
    "Services/XPC/DyldCacheAnalysisTransport.swift",
    "Services/XPC/XPCDyldCacheAnalysisProvider.swift",
    "Services/Assembler/ARM64AssemblyRouter.swift",
    "Services/Assembler/SwiftAssemblyARM64FallbackBackend.swift",
    "Services/ObjectiveC/ObjCSignatureHypothesisInference.swift",
}

BOUNDED_DIRECTORY_LEAVES = {
    "Services/Decompiler/SecurityTriage": frozenset({"SecurityTriage.swift"}),
    "Services/Decompiler/Structuring": frozenset({
        "DecodedScalarCFGPlan.swift",
        "DecodedScalarNativeControlPlan.swift",
        "DecodedScalarNativeEmissionContext.swift",
        "DecodedScalarNativeValuePlan.swift",
        "DecodedScalarRegionPlan.swift",
        "EntryLoopCarryPlan.swift",
        "EntryLoopNativeValuePlan.swift",
        "RegionalBoundaryPlan.swift",
        "RegionalOrdinaryControlPlan.swift",
        "RegionalOrdinaryEmissionContext.swift",
        "RegionalOrdinaryValuePlan.swift",
        "RegionalPhysicalStatePlan.swift",
        "RegionalRecoveryEmitter.swift",
        "RegionalRefusal.swift",
        "RegionalSingleCMPConditionPlan.swift",
        "RegionalTypedSwitchPlan.swift",
        "TerminalSuffixRegionPlan.swift",
    }),
    "../ThirdParty/REA/licenses": frozenset({
        "REA/LICENSE", "base64-js/LICENSE", "buffer/LICENSE", "canonicalize/LICENSE",
        "ieee754/LICENSE", "zod/LICENSE",
    }),
}


def expanded_worker_sources(paths: list[str], source_root: pathlib.Path) -> list[str]:
    expanded = []
    for path in paths:
        source = source_root / path
        if path not in BOUNDED_DIRECTORY_LEAVES:
            if not source.is_file():
                raise AssertionError(f"required source is not a file: {path}")
            expanded.append(path)
            continue
        if not source.is_dir():
            raise AssertionError(f"required source directory is missing: {path}")
        expected = BOUNDED_DIRECTORY_LEAVES[path]
        actual = {leaf.relative_to(source).as_posix()
                  for leaf in source.rglob("*") if leaf.is_file()}
        if actual != expected:
            raise AssertionError(f"directory leaves differ: {path}: {sorted(actual)}")
        expanded.extend(f"{path}/{leaf}" for leaf in sorted(expected))
    return expanded


def core_sources_outside_engine(paths: list[str]) -> list[str]:
    """MacScopeAnalysisCore sources that break the structural rule (or are explicitly forbidden)."""
    return sorted(
        path for path in paths
        if path in WORKER_FORBIDDEN or (
            path not in CORE_CROSS_FOLDER_SOURCES
            and (not path.startswith(CORE_ENGINE_ROOTS) or path.startswith(CORE_APP_ONLY_ROOTS))
        )
    )


def top_level_section(text: str, name: str) -> str:
    match = re.search(rf"(?m)^{re.escape(name)}:\s*$", text)
    if match is None:
        raise AssertionError(f"missing top-level {name}: section")
    tail = text[match.start():]
    first_newline = tail.index("\n") + 1
    boundary = re.search(r"(?m)^\S[^\n]*:\s*$", tail[first_newline:])
    return tail if boundary is None else tail[: first_newline + boundary.start()]


def target_section(text: str, target: str) -> str:
    targets = top_level_section(text, "targets")
    match = re.search(rf"(?m)^  {re.escape(target)}:\s*$", targets)
    if match is None:
        raise AssertionError(f"missing target {target}")
    tail = targets[match.start():]
    first_newline = tail.index("\n") + 1
    boundary = re.search(
        r"(?m)^  [A-Za-z0-9_][A-Za-z0-9_-]*:\s*$", tail[first_newline:]
    )
    return tail if boundary is None else tail[: first_newline + boundary.start()]


def source_paths(section: str) -> list[str]:
    return re.findall(r"(?m)^\s+- path: ([^\n]+)$", section)


def all_target_sections(text: str) -> dict[str, str]:
    targets = top_level_section(text, "targets")
    names = re.findall(r"(?m)^  ([A-Za-z0-9_][A-Za-z0-9_-]*):\s*$", targets)
    return {name: target_section(text, name) for name in names}


def expanded_third_party_source_owners(text: str) -> dict[str, list[str]]:
    owners: dict[str, list[str]] = {}
    for target, section in all_target_sections(text).items():
        for raw_path in source_paths(section):
            resolved = (ROOT / "MacScope" / raw_path).resolve()
            third_party = (ROOT / "ThirdParty").resolve()
            if resolved != third_party and third_party not in resolved.parents:
                continue
            files = [resolved] if resolved.is_file() else sorted(
                path for path in resolved.rglob("*") if path.is_file()
            )
            for path in files:
                relative = path.relative_to(ROOT).as_posix()
                owners.setdefault(relative, []).append(target)
    return owners


class Top3ProjectSourceClosureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.project = PROJECT.read_text(encoding="utf-8")

    def test_machokit_is_one_local_package_owned_only_by_analysis_worker(self) -> None:
        packages = top_level_section(self.project, "packages")
        self.assertEqual(packages.count("  MachOKit:\n"), 1)
        self.assertEqual(packages.count("    path: LocalPackages/MachOKit\n"), 1)
        self.assertEqual(self.project.count("- package: MachOKit\n"), 1)
        worker = target_section(self.project, "AnalysisWorkerXPCService")
        self.assertIn("- package: MachOKit\n", worker)
        self.assertIn("  product: MachOKit\n", worker)
        app = target_section(self.project, "MacScopeApp")
        self.assertNotIn("package: MachOKit", app)
        self.assertNotIn("package: MachOKit", target_section(self.project, "MacScopeAnalysisCore"))
        self.assertNotRegex(self.project, r"(?i)MachOKit[^\n]*(?:xcframework|binaryTarget)")

    def test_swift_assembly_has_one_compile_owner_and_one_shipping_consumer(self) -> None:
        vendor = target_section(self.project, "SwiftAssemblyVendor")
        self.assertIn("type: library.static", vendor)
        self.assertEqual(
            source_paths(vendor), ["../ThirdParty/SwiftAssemblyVendor/Sources"]
        )
        self.assertIn("SKIP_INSTALL: YES", vendor)
        self.assertNotIn("embed: true", vendor)
        self.assertNotIn("codeSign: true", vendor)
        self.assertEqual(self.project.count("- target: SwiftAssemblyVendor\n"), 1)
        self.assertIn("- target: SwiftAssemblyVendor\n", target_section(self.project, "MacScopeApp"))
        owners = {path: owners for path, owners in expanded_third_party_source_owners(self.project).items()
                  if path.startswith("ThirdParty/SwiftAssemblyVendor/")}
        self.assertTrue(owners, "SwiftAssembly vendor source closure is empty")
        self.assertEqual(
            sorted({owner for target_owners in owners.values() for owner in target_owners}),
            ["SwiftAssemblyVendor"],
        )
        multiply_linked = {
            path: target_owners
            for path, target_owners in owners.items()
            if len(target_owners) != 1
        }
        self.assertEqual(multiply_linked, {})

    def test_worker_source_closure_is_exactly_bounded(self) -> None:
        # The worker's closure is its own source list plus the MacScopeAnalysisCore static
        # library it links (D12 layer 3); each closure file is compiled by exactly one of them.
        worker = target_section(self.project, "AnalysisWorkerXPCService")
        core = target_section(self.project, "MacScopeAnalysisCore")
        self.assertIn("- target: MacScopeAnalysisCore\n", worker)
        self.assertIn("type: library.static", core)
        worker_paths = source_paths(worker)
        core_paths = source_paths(core)
        paths = worker_paths + core_paths
        duplicates = sorted(path for path in set(paths) if paths.count(path) != 1)
        self.assertEqual(duplicates, [], f"duplicate worker sources: {duplicates}")
        self.assertEqual(set(worker_paths), WORKER_OWN_SOURCES)
        outside = core_sources_outside_engine(core_paths)
        self.assertEqual(outside, [], f"MacScopeAnalysisCore sources outside the engine folders: {outside}")
        self.assertEqual(sorted(WORKER_FORBIDDEN & set(paths)), [])
        self.assertNotIn("Models", paths)
        self.assertNotIn("Services", paths)
        self.assertNotIn("../ThirdParty", paths)
        expanded_core = expanded_worker_sources(core_paths, ROOT / "MacScope")
        expanded = expanded_worker_sources(worker_paths, ROOT / "MacScope") + expanded_core
        duplicates = sorted(path for path in set(expanded) if expanded.count(path) != 1)
        self.assertEqual(duplicates, [], f"duplicate worker source leaves: {duplicates}")
        self.assertEqual(core_sources_outside_engine(expanded_core), [])
        self.assertEqual(sorted(WORKER_FORBIDDEN & set(expanded)), [])

    def test_source_expansion_rejects_missing_files_and_undeclared_directories(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            (root / "Services/Undeclared").mkdir(parents=True)
            (root / "Services/Decompiler/SecurityTriage").mkdir(parents=True)
            for path, error in (
                ("Services/Missing.swift", "required source is not a file"),
                ("Services/Undeclared", "required source is not a file"),
                ("Services/Decompiler/SecurityTriage", "directory leaves differ"),
            ):
                with self.subTest(path=path):
                    with self.assertRaisesRegex(AssertionError, error):
                        expanded_worker_sources([path], root)

    def test_core_rule_rejects_app_only_and_forbidden_sources(self) -> None:
        core = target_section(self.project, "MacScopeAnalysisCore")
        for injected in ("Stores/WorkspaceStore.swift", "Services/Phase2/Phase2InferenceRunner.swift",
                         "Features/Editor/EditorSurfaceView.swift",
                         "Models/Phase2/Phase2Inference.swift",
                         "Models/Phase2/UnreviewedReadModel.swift",
                         "Services/Phase2/TypedReadRegistry.swift",
                         "Services/Phase2/Phase2EvidenceAcceptor.swift",
                         "Services/Phase2/Phase2GroundedContextCompiler.swift",
                         "Services/ObjectiveC/ObjCSignatureHypothesisInference.swift"):
            with self.subTest(injected=injected):
                mutated = core.replace("    sources:\n", f"    sources:\n      - path: {injected}\n", 1)
                self.assertEqual(core_sources_outside_engine(source_paths(mutated)), [injected])
        transport = "Services/XPC/DyldCacheAnalysisTransport.swift"  # engine folder, but WORKER_FORBIDDEN
        mutated = core.replace("    sources:\n", f"    sources:\n      - path: {transport}\n", 1)
        self.assertEqual(core_sources_outside_engine(source_paths(mutated)), [transport])

    def test_worker_rejects_exact_app_transport_path(self) -> None:
        worker = target_section(self.project, "AnalysisWorkerXPCService")
        injected_path = "Services/XPC/DyldCacheAnalysisTransport.swift"
        mutated_worker = worker.replace(
            "    sources:\n",
            f"    sources:\n      - path: {injected_path}\n",
            1,
        )
        self.assertIn(injected_path, source_paths(mutated_worker))
        self.assertEqual(sorted(WORKER_FORBIDDEN & set(source_paths(mutated_worker))), [
            injected_path
        ])

    def test_dyld_result_validation_crosses_both_xpc_boundaries(self) -> None:
        provider = DYLD_PROVIDER_SEAM.read_text(encoding="utf-8")
        codec = DYLD_WIRE_CODEC.read_text(encoding="utf-8")
        worker = DYLD_WORKER_SERVICE.read_text(encoding="utf-8")
        self.assertIn(
            "return try result.validated(requestedCategories: categories, limits: limits)",
            provider,
        )
        self.assertIn("if let validated = try? value.validated()", codec)
        self.assertIn("return try result.validated()", codec)
        self.assertRegex(
            worker,
            r"catch is DyldCacheAnalysisModelError \{\s*"
            r"(?://[^\n]*\n\s*)*return codec\.encodeReply\(\.failure\("
            r"DyldCacheAnalysisWorkerServiceError\.providerRejectedInput\)\)",
        )

    def test_vendor_identity_and_repository_source_closure_match(self) -> None:
        identity = json.loads(SWIFT_ASSEMBLY_IDENTITY.read_text(encoding="utf-8"))
        expected = sorted(row["vendorPath"] for row in identity["sourceFiles"])
        actual = sorted(
            path.relative_to(ROOT / "ThirdParty" / "SwiftAssemblyVendor").as_posix()
            for path in (ROOT / "ThirdParty" / "SwiftAssemblyVendor" / "Sources").rglob("*.swift")
        )
        self.assertEqual(actual, expected)
        imports = []
        for path in (ROOT / "MacScope").rglob("*.swift"):
            if re.search(r"(?m)^import MachOKit\s*$", path.read_text(encoding="utf-8")):
                imports.append(path.relative_to(ROOT / "MacScope").as_posix())
        self.assertEqual(
            imports,
            ["AnalysisWorkerService/MachOKitDyldCacheAnalysisProvider.swift"],
        )

    def test_worker_verifies_exact_materialization_on_every_build(self) -> None:
        worker = target_section(self.project, "AnalysisWorkerXPCService")
        marker = "- name: Verify exact MachOKit source materialization"
        self.assertEqual(worker.count(marker), 1)
        phase = worker[worker.index(marker):]
        self.assertIn("basedOnDependencyAnalysis: false", phase)
        self.assertIn(
            '"$(MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT)/MATERIALIZATION.json"',
            phase,
        )
        self.assertIn("machokit_source_identity.py\" verify", phase)
        self.assertIn('cd "$SRCROOT/LocalPackages"', phase)
        self.assertIn('if [ "$VERIFIED_ROOT" != "$PACKAGE_ROOT" ]', phase)

    def test_worker_binds_the_compiled_machokit_identity(self) -> None:
        worker = target_section(self.project, "AnalysisWorkerXPCService")
        app = target_section(self.project, "MacScopeApp")
        provider = MACHOKIT_WORKER_PROVIDER.read_text(encoding="utf-8")
        marker = "- name: Verify compiled MachOKit identity in AnalysisWorker"
        self.assertEqual(worker.count(marker), 1)
        phase = worker[worker.index(marker):]
        self.assertIn("basedOnDependencyAnalysis: false", phase)
        self.assertIn("verify_machokit_analysis_worker_identity.py", phase)
        self.assertIn('"$TARGET_BUILD_DIR/$EXECUTABLE_PATH"', phase)
        self.assertIn("MacScopeMachOKitBuildIdentity.marker", provider)
        self.assertIn("expectedMachOKitMarkerPrefix", provider)
        self.assertIn("expectedMachOKitRevision", provider)
        self.assertIn("expectedMachOKitGovernedSourceIdentity", provider)
        self.assertIn("--analysis-worker-executable", app)
        self.assertIn(
            "XPCServices/AnalysisWorkerXPCService.xpc/Contents/MacOS/AnalysisWorkerXPCService",
            app,
        )
        self.assertRegex(
            provider,
            r"guard buildIdentity\.count == 3,\s*"
            r"buildIdentity\[0\] == Self\.expectedMachOKitMarkerPrefix,\s*"
            r"buildIdentity\[1\] == Self\.expectedMachOKitRevision,\s*"
            r"buildIdentity\[2\] == Self\.expectedMachOKitGovernedSourceIdentity else \{\s*"
            r"throw DyldCacheAnalysisProviderError\.providerUnavailable",
        )

    def test_dependency_roots_remain_config_file_bound_and_fail_closed(self) -> None:
        self.assertRegex(
            self.project,
            r"(?m)^configFiles:\n  Debug: DependencyRoots\.xcconfig\n"
            r"  Release: DependencyRoots\.xcconfig$",
        )
        base = top_level_section(self.project, "settings")
        self.assertNotRegex(base, r"(?m)^\s+MACSCOPE_(?:GHOSTTY|SLEIGH|MACHOKIT)_.+:\s*")


if __name__ == "__main__":
    unittest.main()
