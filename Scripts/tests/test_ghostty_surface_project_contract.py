from __future__ import annotations

import json
import os
import pathlib
import re
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
PROJECT = ROOT / "MacScope/project.yml"
DEPENDENCY_ROOTS = ROOT / "MacScope/DependencyRoots.xcconfig"
BOOTSTRAP = ROOT / "Scripts/bootstrap.sh"

GST01_PRODUCT_SOURCES = (
    "Features/Shell/GhosttySurface/MacScopeGhosttyActionRouter.swift",
    "Features/Shell/GhosttySurface/MacScopeGhosttyConfiguration.swift",
    "Features/Shell/GhosttySurface/MacScopeGhosttyExternalIOBridge.swift",
    "Features/Shell/GhosttySurface/MacScopeGhosttyLinkedSurfaceAdapter.swift",
    "Features/Shell/GhosttySurface/MacScopeGhosttyRuntime.swift",
    "Features/Shell/GhosttySurface/MacScopeGhosttySurfaceCoordinator.swift",
    "Features/Shell/GhosttySurface/MacScopeGhosttySurfaceDiagnostics.swift",
    "Features/Shell/GhosttySurface/MacScopeGhosttySurfaceFeature.swift",
    "Features/Shell/GhosttySurface/MacScopeGhosttySurfaceHostView.swift",
    "Features/Shell/GhosttySurface/MacScopeGhosttySurfaceRepresentable.swift",
    "Features/Shell/Phase2GhosttyBrokerSurface.swift",
    "Services/Phase2/Phase2ContinuousShellTranscriptController.swift",
)

GST01_TEST_SOURCES = (
    "Tests/Phase2Tests/MacScopeGhosttyActionRouterTests.swift",
    "Tests/Phase2Tests/MacScopeGhosttyExternalIOBridgeSaturationTests.swift",
    "Tests/Phase2Tests/MacScopeGhosttyExternalIOBridgeTests.swift",
    "Tests/Phase2Tests/MacScopeGhosttyLifecycleProcessOwnershipTests.swift",
    "Tests/Phase2Tests/MacScopeGhosttyLifecycleTests.swift",
    "Tests/Phase2Tests/MacScopeGhosttyLinkedSurfaceAdapterTests.swift",
    "Tests/Phase2Tests/MacScopeGhosttyRendererEvidenceDiagnosticsTests.swift",
    "Tests/Phase2Tests/MacScopeGhosttyRendererSelectionTests.swift",
    "Tests/Phase2Tests/MacScopeGhosttyResizeTests.swift",
    "Tests/Phase2Tests/MacScopeGhosttyRuntimeTests.swift",
    "Tests/Phase2Tests/MacScopeGhosttyTranscriptAdmissionTests.swift",
    "Tests/Phase2Tests/Phase2ContinuousShellTranscriptControllerTests.swift",
    "Tests/Phase2Tests/Phase2GhosttyBrokerSurfaceTests.swift",
)

TEST_BUNDLES = ("CoreTests", "Phase2Tests")

EXPLICIT_SERVICE_TARGETS = (
    "PluginXPCService",
    "AnalysisWorkerXPCService",
    "AIAgentWorkerXPCService",
    "NativeDecompilerXPCService",
    "ShellBrokerXPCService",
    "ShellBrokerLaunchAgent",
)

EXPECTED_SHELL_BROKER_SOURCES = (
    "Models/REA/REAProcessCaptureModels.swift",
    "Models/REA/REAAssetCatalogCaptureModels.swift",
    "Models/REA/REAInspectionModels.swift",
    "Services/XPC/REAInspectionWireCodec.swift",
    "AIAgentWorkerCore/Phase2ProductionJSONSchema.swift",
    "Services/REA/REAScenarioCapture.swift",
    "ShellBrokerService/REAScenarioCaptureService.swift",
    "ShellBrokerService/REAAssetCatalogCaptureService.swift",
    "Models/Phase2/Phase2HumanPTYTranscript.swift",
    "Models/Phase2/Phase2HumanPTYBroker.swift",
    "Models/Reconstruction/ReconstructionSourceProfile.swift",
    "Models/Phase2/Phase2ShellBrokerXPCProtocol.swift",
    "Models/Phase2/Phase2ShellBrokerLifecycle.swift",
    "Models/Phase2/Phase2DurableShellBrokerIdentity.swift",
    "ShellBrokerService/Phase2ShellBrokerProcessAdapter.swift",
    "ShellBrokerService/ReconstructionSourceExecutionLease.swift",
    "ShellBrokerService/Phase2DurableShellBrokerRegistry.swift",
    "ShellBrokerService/main.swift",
    "ShellBrokerService/Phase2ShellBrokerPrincipal.swift",
)


class GhosttySurfaceProjectContractTests(unittest.TestCase):
    def project(self) -> dict[str, object]:
        cached = getattr(self, "_project_cache", None)
        if cached is not None:
            return cached

        result = subprocess.run(
            [
                "/usr/bin/ruby",
                "-ryaml",
                "-rjson",
                "-e",
                (
                    "value=YAML.safe_load(File.read(ARGV.fetch(0)), "
                    "permitted_classes: [], aliases: false); "
                    "STDOUT.write(JSON.generate(value))"
                ),
                str(PROJECT),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        self.assertIsInstance(value, dict)
        self._project_cache = value
        return value

    def phase(
        self,
        target_name: str,
        collection: str,
        phase_name: str,
    ) -> dict[str, object]:
        target = self.project()["targets"][target_name]
        matches = [
            phase
            for phase in target.get(collection, [])
            if phase.get("name") == phase_name
        ]
        self.assertEqual(len(matches), 1, (target_name, collection, phase_name))
        return matches[0]

    def source_paths(self, target_name: str) -> list[str]:
        target = self.project()["targets"][target_name]
        return [
            entry if isinstance(entry, str) else entry["path"]
            for entry in target.get("sources", [])
        ]

    def source_coverage_count(self, target_name: str, relative_path: str) -> int:
        target = self.project()["targets"][target_name]
        count = 0
        for entry in target.get("sources", []):
            if isinstance(entry, str):
                source_path = entry
                excludes: list[str] = []
            else:
                source_path = entry["path"]
                excludes = entry.get("excludes", [])

            source_on_disk = ROOT / "MacScope" / source_path
            if source_on_disk.is_dir():
                prefix = source_path.rstrip("/") + "/"
                if not relative_path.startswith(prefix):
                    continue
                descendant = relative_path[len(prefix) :]
                if any(pathlib.PurePosixPath(descendant).match(pattern) for pattern in excludes):
                    continue
                count += 1
            elif relative_path == source_path:
                count += 1
        return count

    def assert_shell_syntax(self, script: str) -> None:
        result = subprocess.run(
            ["/bin/bash", "-n"],
            input=script,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_gst01_sources_have_exact_app_test_and_service_ownership(self) -> None:
        expected_surface_sources = {
            relative_path
            for relative_path in GST01_PRODUCT_SOURCES
            if relative_path.startswith("Features/Shell/GhosttySurface/")
        }
        discovered_surface_sources = {
            path.relative_to(ROOT / "MacScope").as_posix()
            for path in (ROOT / "MacScope/Features/Shell/GhosttySurface").glob("*.swift")
        }
        self.assertEqual(discovered_surface_sources, expected_surface_sources)

        expected_macscope_ghostty_tests = {
            relative_path
            for relative_path in GST01_TEST_SOURCES
            if pathlib.PurePosixPath(relative_path).name.startswith("MacScopeGhostty")
        }
        discovered_macscope_ghostty_tests = {
            path.relative_to(ROOT / "MacScope").as_posix()
            for bundle in TEST_BUNDLES
            for path in (ROOT / "MacScope/Tests" / bundle).glob(
                "MacScopeGhostty*Tests.swift"
            )
        }
        self.assertEqual(
            discovered_macscope_ghostty_tests,
            expected_macscope_ghostty_tests,
        )

        expected_phase2_ghostty_sources = {
            "Features/Shell/Phase2GhosttyBrokerSurface.swift",
            "Features/Shell/Phase2GhosttyTerminalGridView.swift",
            "Features/Shell/Phase2GhosttyTerminalModel.swift",
            "Features/Shell/Phase2GhosttyTerminalSurface.swift",
            "Features/Shell/Phase2GhosttyVTTranscriptRenderer.swift",
        }
        discovered_phase2_ghostty_sources = {
            path.relative_to(ROOT / "MacScope").as_posix()
            for path in (ROOT / "MacScope/Features/Shell").glob("Phase2Ghostty*.swift")
        }
        self.assertEqual(
            discovered_phase2_ghostty_sources,
            expected_phase2_ghostty_sources,
        )

        expected_ghostty_tests = expected_macscope_ghostty_tests | {
            "Tests/Phase2Tests/Phase2GhosttyBrokerSurfaceTests.swift",
            "Tests/Phase2Tests/Phase2GhosttyTerminalModelTests.swift",
            "Tests/Phase2Tests/Phase2GhosttyTerminalSurfaceTests.swift",
        }
        discovered_ghostty_tests = {
            path.relative_to(ROOT / "MacScope").as_posix()
            for bundle in TEST_BUNDLES
            for path in (ROOT / "MacScope/Tests" / bundle).glob("*Ghostty*Tests.swift")
        }
        self.assertEqual(discovered_ghostty_tests, expected_ghostty_tests)

        for relative_path in GST01_PRODUCT_SOURCES + GST01_TEST_SOURCES:
            with self.subTest(file=relative_path):
                self.assertTrue((ROOT / "MacScope" / relative_path).is_file())

        for relative_path in GST01_PRODUCT_SOURCES:
            with self.subTest(target="MacScopeApp", file=relative_path):
                self.assertEqual(
                    self.source_coverage_count("MacScopeApp", relative_path),
                    1,
                )
            for bundle in TEST_BUNDLES:
                with self.subTest(target=bundle, file=relative_path):
                    self.assertEqual(self.source_coverage_count(bundle, relative_path), 0)

        for relative_path in GST01_TEST_SOURCES:
            with self.subTest(target="test bundles", file=relative_path):
                # Exactly one hosted test bundle (CoreTests or Phase2Tests, D12 layer 3) owns it.
                self.assertEqual(
                    sum(self.source_coverage_count(bundle, relative_path) for bundle in TEST_BUNDLES), 1
                )
            with self.subTest(target="MacScopeApp", file=relative_path):
                self.assertEqual(self.source_coverage_count("MacScopeApp", relative_path), 0)

        for target_name in EXPLICIT_SERVICE_TARGETS:
            for relative_path in GST01_PRODUCT_SOURCES + GST01_TEST_SOURCES:
                with self.subTest(target=target_name, file=relative_path):
                    self.assertEqual(
                        self.source_coverage_count(target_name, relative_path),
                        0,
                    )

        expected_broker_sources = list(EXPECTED_SHELL_BROKER_SOURCES)
        self.assertEqual(
            self.source_paths("ShellBrokerXPCService"),
            expected_broker_sources,
        )
        self.assertEqual(
            self.source_paths("ShellBrokerLaunchAgent"),
            expected_broker_sources,
        )

    def test_generated_roots_are_machine_local_and_fail_closed(self) -> None:
        dependency_text = DEPENDENCY_ROOTS.read_text(encoding="utf-8")
        include_index = dependency_text.index('#include? "DependencyRoots.local.xcconfig"')

        for setting in (
            "MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR",
            "MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT",
            "MACSCOPE_GHOSTTY_SURFACE_FRAMEWORK",
            "MACSCOPE_GHOSTTY_SURFACE_ENABLED",
        ):
            declaration = f"{setting} =\n"
            self.assertEqual(dependency_text.count(declaration), 1)
            self.assertLess(dependency_text.index(declaration), include_index)

        for producer_only_setting in (
            "MACSCOPE_GHOSTTY_VT_WORK_ROOT",
            "MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT",
        ):
            self.assertNotIn(f"{producer_only_setting} =", dependency_text)

        app_settings = self.project()["targets"]["MacScopeApp"]["settings"]["base"]
        for bootstrap_owned_setting in (
            "MACSCOPE_GHOSTTY_VT_WORK_ROOT",
            "MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT",
            "MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR",
            "MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT",
            "MACSCOPE_GHOSTTY_SURFACE_FRAMEWORK",
        ):
            self.assertNotIn(bootstrap_owned_setting, app_settings)

    def test_app_and_core_tests_build_vt_from_source_and_stage_surface_only(self) -> None:
        targets = self.project()["targets"]
        app_settings = targets["MacScopeApp"]["settings"]["base"]
        core_settings = targets["CoreTests"]["settings"]["base"]

        expected_app_settings = {
            "MACSCOPE_GHOSTTY_VT_BUILD_ROOT": "$(CONFIGURATION_TEMP_DIR)/MacScopeGhosttyVT",
            "MACSCOPE_GHOSTTY_SURFACE_INPUT_HEADER": "$(MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT)/macos-arm64/Headers/ghostty.h",
            "MACSCOPE_GHOSTTY_SURFACE_INPUT_MODULE_MAP": "$(MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT)/macos-arm64/Headers/module.modulemap",
            "MACSCOPE_GHOSTTY_SURFACE_INPUT_ARCHIVE": "$(MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT)/macos-arm64/libghostty-internal.a",
            "MACSCOPE_GHOSTTY_SURFACE_MANIFEST": "$(MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR)/macos/.macscope-ghostty-surface-manifest",
            "MACSCOPE_GHOSTTY_SURFACE_STAGED_ROOT": "$(PROJECT_TEMP_DIR)/MacScopeGhosttySurface",
            "MACSCOPE_GHOSTTY_SURFACE_STAGED_DESCRIPTOR": "$(MACSCOPE_GHOSTTY_SURFACE_STAGED_ROOT)/STAGED_GHOSTTY_SURFACE.json",
            "MACSCOPE_GHOSTTY_SURFACE_HEADER": "$(MACSCOPE_GHOSTTY_SURFACE_STAGED_ROOT)/Headers/ghostty.h",
            "MACSCOPE_GHOSTTY_SURFACE_MODULE_MAP": "$(MACSCOPE_GHOSTTY_SURFACE_STAGED_ROOT)/Headers/module.modulemap",
            "MACSCOPE_GHOSTTY_SURFACE_ARCHIVE": "$(MACSCOPE_GHOSTTY_SURFACE_STAGED_ROOT)/libghostty-internal.a",
            "HEADER_SEARCH_PATHS": '$(inherited) "$(MACSCOPE_GHOSTTY_VT_BUILD_ROOT)/artifacts/include" "$(MACSCOPE_GHOSTTY_SURFACE_STAGED_ROOT)/Headers"',
            "LIBRARY_SEARCH_PATHS": '$(inherited) "$(MACSCOPE_GHOSTTY_VT_BUILD_ROOT)/artifacts/lib"',
            "OTHER_LDFLAGS": "$(inherited) -force_load $(BUILT_PRODUCTS_DIR)/libMacScopeAnalysisCore.a -force_load $(BUILT_PRODUCTS_DIR)/libMacScopeDebuggerCore.a -lghostty-vt $(MACSCOPE_GHOSTTY_SURFACE_ARCHIVE) -lc++ -framework Carbon -framework GameController",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) $(MACSCOPE_NATIVE_DECOMPILER_LIVE_TEST_CONDITION) $(MACSCOPE_GHOSTTY_SURFACE_ENABLED)",
            "SWIFT_INCLUDE_PATHS": '$(inherited) "$(MACSCOPE_GHOSTTY_VT_BUILD_ROOT)/artifacts/include" "$(MACSCOPE_GHOSTTY_SURFACE_STAGED_ROOT)/Headers"',
        }
        for setting, expected in expected_app_settings.items():
            with self.subTest(target="MacScopeApp", setting=setting):
                self.assertEqual(app_settings.get(setting), expected)

        expected_core_settings = {
            "MACSCOPE_GHOSTTY_VT_BUILD_ROOT": "$(CONFIGURATION_TEMP_DIR)/MacScopeGhosttyVT",
            "MACSCOPE_GHOSTTY_SURFACE_STAGED_ROOT": "$(PROJECT_TEMP_DIR)/MacScopeGhosttySurface",
            "MACSCOPE_GHOSTTY_SURFACE_ARCHIVE": "$(MACSCOPE_GHOSTTY_SURFACE_STAGED_ROOT)/libghostty-internal.a",
            "HEADER_SEARCH_PATHS": '$(inherited) "$(MACSCOPE_GHOSTTY_VT_BUILD_ROOT)/artifacts/include" "$(MACSCOPE_GHOSTTY_SURFACE_STAGED_ROOT)/Headers"',
            "LIBRARY_SEARCH_PATHS": '$(inherited) "$(MACSCOPE_GHOSTTY_VT_BUILD_ROOT)/artifacts/lib"',
            "OTHER_LDFLAGS": "$(inherited) $(MACSCOPE_GHOSTTY_SURFACE_ARCHIVE) -lc++ -framework Carbon -framework GameController $(MACSCOPE_PARSER_ENGINES_LDFLAGS)",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) TESTING_PARSER_ENGINES TESTING_REA_WORKER_HOST TESTING_WORKER_PRINCIPAL TESTING_SHELL_BROKER_PRINCIPAL TESTING_NATIVE_DECOMPILER_SERVICE_COMPOSITION $(MACSCOPE_NATIVE_DECOMPILER_LIVE_TEST_CONDITION) $(MACSCOPE_GHOSTTY_SURFACE_ENABLED)",
            "SWIFT_INCLUDE_PATHS": '$(inherited) "$(MACSCOPE_GHOSTTY_VT_BUILD_ROOT)/artifacts/include" "$(MACSCOPE_GHOSTTY_SURFACE_STAGED_ROOT)/Headers" $(MACSCOPE_PARSER_ENGINES_INCLUDE) "$(SRCROOT)/Support/ChildProcessC"',
        }
        for setting, expected in expected_core_settings.items():
            with self.subTest(target="CoreTests", setting=setting):
                self.assertEqual(core_settings.get(setting), expected)

        for dead_setting in (
            "MACSCOPE_ZIG_ROOT",
            "MACSCOPE_ZIG",
            "MACSCOPE_ZIG_RECEIPT",
            "FRAMEWORK_SEARCH_PATHS",
            "MACSCOPE_GHOSTTY_VT_INPUT_MANIFEST",
            "MACSCOPE_GHOSTTY_VT_INPUT_DYLIB",
            "MACSCOPE_GHOSTTY_VT_INPUT_HEADER",
            "MACSCOPE_GHOSTTY_VT_INPUT_MODULE_MAP",
            "MACSCOPE_GHOSTTY_VT_STAGED_MANIFEST",
            "MACSCOPE_GHOSTTY_VT_STAGED_DYLIB",
            "MACSCOPE_GHOSTTY_VT_STAGED_HEADER",
            "MACSCOPE_GHOSTTY_VT_STAGED_MODULE_MAP",
            "MACSCOPE_GHOSTTY_VT_STAGED_ROOT",
        ):
            self.assertNotIn(dead_setting, app_settings)

        for settings in (app_settings, core_settings):
            for consumer_setting in (
                "HEADER_SEARCH_PATHS",
                "LIBRARY_SEARCH_PATHS",
                "SWIFT_INCLUDE_PATHS",
                "OTHER_LDFLAGS",
            ):
                self.assertNotIn(
                    "MACSCOPE_GHOSTTY_VT_WORK_ROOT",
                    settings[consumer_setting],
                )
                self.assertNotIn(
                    "MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT",
                    settings[consumer_setting],
                )

        allowed_external_settings = {
            ("MacScopeApp", "MACSCOPE_GHOSTTY_SURFACE_INPUT_HEADER"),
            ("MacScopeApp", "MACSCOPE_GHOSTTY_SURFACE_INPUT_MODULE_MAP"),
            ("MacScopeApp", "MACSCOPE_GHOSTTY_SURFACE_INPUT_ARCHIVE"),
            ("MacScopeApp", "MACSCOPE_GHOSTTY_SURFACE_MANIFEST"),
        }
        setting_owners = {
            "Project": self.project()["settings"],
            "MacScopeApp": targets["MacScopeApp"]["settings"],
            "CoreTests": targets["CoreTests"]["settings"],
        }
        for owner, settings in setting_owners.items():
            scopes = [("base", settings.get("base", {}))]
            scopes.extend(
                (f"configs.{configuration}", values)
                for configuration, values in settings.get("configs", {}).items()
            )
            for scope_name, values in scopes:
                for setting, value in values.items():
                    if not isinstance(value, str):
                        continue
                    if any(
                        external in value
                        for external in (
                            "MACSCOPE_GHOSTTY_VT_WORK_ROOT",
                            "MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT",
                            "MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR",
                        )
                    ):
                        self.assertEqual(scope_name, "base")
                        self.assertIn((owner, setting), allowed_external_settings)

    def test_vt_phase_stages_qualified_closure_or_builds_repository_source_in_derived_data(self) -> None:
        phase = self.phase(
            "MacScopeApp",
            "preBuildScripts",
            "Build repository-owned Ghostty VT",
        )
        self.assertFalse(phase["basedOnDependencyAnalysis"])
        self.assertEqual(
            phase["inputFiles"],
            [
                "$(SRCROOT)/../Scripts/build_ghostty_vt.sh",
                "$(SRCROOT)/../Scripts/dependencies/stage_verified_ghostty_vt.py",
                "$(SRCROOT)/../Scripts/dependencies/stage_verified_ghostty_surface.py",
                "$(SRCROOT)/../Scripts/ghostty-vt-source.contract",
                "$(SRCROOT)/../Scripts/dependencies/zig_toolchain_receipt.py",
                "$(SRCROOT)/../Scripts/qualification/dev_dependency_cache.py",
                "$(SRCROOT)/../Scripts/qualification/dependency_cache.py",
                "$(SRCROOT)/../ThirdParty/GhosttyVT/Source/build.zig",
                "$(SRCROOT)/../ThirdParty/GhosttyVT/Source/build.zig.zon",
            ],
        )
        self.assertEqual(
            phase["outputFiles"],
            [
                "$(MACSCOPE_GHOSTTY_VT_BUILD_ROOT)/artifacts/lib/.macscope-ghostty-vt-manifest",
                "$(MACSCOPE_GHOSTTY_VT_BUILD_ROOT)/artifacts/lib/libghostty-vt.dylib",
                "$(MACSCOPE_GHOSTTY_VT_BUILD_ROOT)/artifacts/include/ghostty/vt.h",
                "$(MACSCOPE_GHOSTTY_VT_BUILD_ROOT)/artifacts/include/module.modulemap",
                "$(TARGET_BUILD_DIR)/$(FRAMEWORKS_FOLDER_PATH)/libghostty-vt.dylib",
            ],
        )

        script = phase["script"]
        self.assert_shell_syntax(script)
        self.assertEqual(
            script.count(
                '"$SRCROOT/../Scripts/build_ghostty_vt.sh" \\\n'
                '    --work-root "$MACSCOPE_GHOSTTY_VT_BUILD_ROOT"'
            ),
            1,
        )
        self.assertIn('stage_verified_ghostty_vt.py', script)
        # Qualification-supplied verified inputs win; routine Debug may instead
        # resolve the same content-addressed entry from the shared cache.
        self.assertIn('VT_ARTIFACT_ROOT="${MACSCOPE_GHOSTTY_VT_VERIFIED_ARTIFACT_ROOT:-}"', script)
        self.assertIn('VT_DESCRIPTOR="${MACSCOPE_GHOSTTY_VT_VERIFIED_DESCRIPTOR:-}"', script)
        self.assertIn('VT_DESCRIPTOR_SHA256="${MACSCOPE_GHOSTTY_VT_VERIFIED_DESCRIPTOR_SHA256:-}"', script)
        self.assertIn('--descriptor-sha256 "${VT_DESCRIPTOR_SHA256:?}"', script)
        self.assertIn('--artifact-root "${VT_ARTIFACT_ROOT:?}"', script)
        self.assertIn('--descriptor "${VT_DESCRIPTOR:?}"', script)
        self.assertIn('resolve --component ghostty-vt --repository-root "$SRCROOT/.."', script)
        self.assertIn('[ -n "$PHASE_STAMP" ]', script)
        self.assertLess(script.index('VT_ARTIFACT_ROOT="${MACSCOPE_GHOSTTY_VT_VERIFIED_ARTIFACT_ROOT:-}"'),
                        script.index('dev_dependency_cache.py'))
        self.assertIn('--destination "$MACSCOPE_GHOSTTY_VT_BUILD_ROOT/artifacts"', script)
        self.assertIn('--allowed-root "$MACSCOPE_GHOSTTY_VT_BUILD_ROOT"', script)
        self.assertLess(script.index('stage_verified_ghostty_vt.py'), script.index('else\n'))
        self.assertIn(
            'EXPECTED_BUILD_ROOT="$CONFIGURATION_TEMP_DIR/MacScopeGhosttyVT"',
            script,
        )
        self.assertIn(
            '/bin/cp -f "$MACSCOPE_GHOSTTY_VT_BUILD_ROOT/artifacts/lib/'
            'libghostty-vt.dylib" "$BUNDLE_TEMPORARY"',
            script,
        )
        self.assertIn(
            '/usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY"',
            script,
        )
        self.assertNotIn("MACSCOPE_GHOSTTY_VT_WORK_ROOT", script)
        self.assertNotIn("STAGED_GHOSTTY_VT", script)
        self.assertNotIn("SNAPSHOT_ROOT", script)
        self.assertNotIn("readlink", script)

    def test_vt_phase_builds_and_embeds_without_external_staging(self) -> None:
        phase_script = self.phase(
            "MacScopeApp",
            "preBuildScripts",
            "Build repository-owned Ghostty VT",
        )["script"]

        with tempfile.TemporaryDirectory(
            prefix="macscope-ghostty-vt-project-phase-"
        ) as temporary_directory:
            root = pathlib.Path(temporary_directory)
            repository = root / "repository"
            source_root = repository / "MacScope"
            scripts = repository / "Scripts"
            scripts.mkdir(parents=True)
            source_root.mkdir(parents=True)
            builder = scripts / "build_ghostty_vt.sh"
            builder.write_text(
                "#!/bin/bash\n"
                "set -euo pipefail\n"
                "[ \"$1\" = \"--work-root\" ]\n"
                "root=$2\n"
                "mkdir -p \"$root/artifacts/lib\" \"$root/artifacts/include/ghostty\"\n"
                "printf manifest > \"$root/artifacts/lib/.macscope-ghostty-vt-manifest\"\n"
                "printf dylib > \"$root/artifacts/lib/libghostty-vt.dylib\"\n"
                "printf header > \"$root/artifacts/include/ghostty/vt.h\"\n"
                "printf module > \"$root/artifacts/include/module.modulemap\"\n",
                encoding="utf-8",
            )
            builder.chmod(0o755)

            configuration_temp = root / "derived-data/Build/Intermediates/Debug"
            build_root = configuration_temp / "MacScopeGhosttyVT"
            target_build = root / "derived-data/Build/Products/Debug"
            environment = os.environ.copy()
            environment.update(
                {
                    "SRCROOT": str(source_root),
                    "CONFIGURATION_TEMP_DIR": str(configuration_temp),
                    "MACSCOPE_GHOSTTY_VT_BUILD_ROOT": str(build_root),
                    "TARGET_BUILD_DIR": str(target_build),
                    "FRAMEWORKS_FOLDER_PATH": "MacScope.app/Contents/Frameworks",
                    "CODE_SIGNING_ALLOWED": "NO",
                    "EXPANDED_CODE_SIGN_IDENTITY": "",
                }
            )

            result = subprocess.run(
                ["/bin/bash", "-c", phase_script],
                cwd=root,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(
                (
                    target_build
                    / "MacScope.app/Contents/Frameworks/libghostty-vt.dylib"
                ).read_text(encoding="utf-8"),
                "dylib",
            )
            self.assertTrue(
                (build_root / "artifacts/include/ghostty/vt.h").is_file()
            )

            victim = root / "victim"
            victim.mkdir()
            sentinel = victim / "sentinel"
            sentinel.write_text("preserve\n", encoding="utf-8")
            rejected_environment = environment.copy()
            rejected_environment["MACSCOPE_GHOSTTY_VT_BUILD_ROOT"] = str(victim)
            rejected = subprocess.run(
                ["/bin/bash", "-c", phase_script],
                cwd=root,
                env=rejected_environment,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(rejected.returncode, 0)
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve\n")

    def test_surface_phase_has_exact_verified_staging_contract(self) -> None:
        phase = self.phase(
            "MacScopeApp",
            "preBuildScripts",
            "Stage verified Ghostty surface build inputs",
        )
        self.assertTrue(phase["basedOnDependencyAnalysis"])
        self.assertEqual(
            phase["inputFiles"],
            [
                "$(SRCROOT)/../Scripts/dependencies/stage_verified_ghostty_surface.py",
                "$(MACSCOPE_GHOSTTY_SURFACE_MANIFEST)",
                "$(MACSCOPE_GHOSTTY_SURFACE_INPUT_ARCHIVE)",
                "$(MACSCOPE_GHOSTTY_SURFACE_INPUT_HEADER)",
                "$(MACSCOPE_GHOSTTY_SURFACE_INPUT_MODULE_MAP)",
            ],
        )
        self.assertEqual(
            phase["outputFiles"],
            [
                "$(MACSCOPE_GHOSTTY_SURFACE_STAGED_DESCRIPTOR)",
                "$(MACSCOPE_GHOSTTY_SURFACE_ARCHIVE)",
                "$(MACSCOPE_GHOSTTY_SURFACE_HEADER)",
                "$(MACSCOPE_GHOSTTY_SURFACE_MODULE_MAP)",
            ],
        )
        self.assertEqual(
            phase["script"].splitlines(),
            [
                "set -euo pipefail",
                # Native Release installation reuses the retained phase receipt (fff93dcc9).
                'if [ -n "${MACSCOPE_NATIVE_RELEASE_ADMISSION:-}" ]; then',
                '  /usr/bin/python3 -B "$SRCROOT/../Scripts/qualification/release_phase_receipt_reuse.py" \\',
                "    --phase ghostty-surface --current-release",
                "  exit 0",
                "fi",
                'if [ -z "${MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT:-}" ] || \\',
                '   [ -z "${MACSCOPE_GHOSTTY_SURFACE_MANIFEST:-}" ]; then',
                '  echo "ERROR: verified Ghostty surface inputs are required" >&2',
                "  exit 1",
                "fi",
                '/bin/mkdir -p "$PROJECT_TEMP_DIR"',
                '/usr/bin/python3 -B "$SRCROOT/../Scripts/dependencies/stage_verified_ghostty_surface.py" \\',
                '  --manifest "$MACSCOPE_GHOSTTY_SURFACE_MANIFEST" \\',
                '  --artifact-root "$MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT" \\',
                '  --destination "$MACSCOPE_GHOSTTY_SURFACE_STAGED_ROOT" \\',
                '  --allowed-root "$PROJECT_TEMP_DIR"',
            ],
        )
        self.assertTrue(phase["script"].endswith("\n"))
        self.assert_shell_syntax(phase["script"])

    def test_xcode_build_phases_are_offline_and_source_owned(self) -> None:
        project = self.project()
        scripts: list[str] = []
        for target in project["targets"].values():
            for collection in ("preBuildScripts", "postBuildScripts"):
                scripts.extend(
                    phase.get("script", "") for phase in target.get(collection, [])
                )
        project_scripts = "\n".join(scripts)

        allowed_external_phases = {
            ("MacScopeApp", "Stage verified Ghostty surface build inputs"),
            ("MacScopeApp", "Generate sealed Release build provenance"),
        }
        for target_name, target in project["targets"].items():
            for collection in ("preBuildScripts", "postBuildScripts"):
                for phase in target.get(collection, []):
                    script = phase.get("script", "")
                    if any(
                        external in script
                        for external in (
                            "MACSCOPE_GHOSTTY_VT_WORK_ROOT",
                            "MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT",
                            "MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR",
                            "MACSCOPE_GHOSTTY_SOURCE_DIR",
                        )
                    ):
                        self.assertIn(
                            (target_name, phase["name"]),
                            allowed_external_phases,
                        )

        self.assertIsNone(
            re.search(
                r"(?im)(?:^|[\s;&|])(?:[^\s;&|]*/)?(?:curl|wget)(?=$|[\s;&|])",
                project_scripts,
            )
        )
        self.assertIsNone(re.search(r"(?i)\bgit\s+clone\b", project_scripts))
        self.assertNotIn("materialize_ghostty_surface.sh", project_scripts)
        self.assertNotIn("build_vendored_ghostty_surface.sh", project_scripts)
        self.assertNotIn("build_ghostty_surface.sh", project_scripts)
        self.assertEqual(project_scripts.count("build_ghostty_vt.sh"), 1)
        self.assertEqual(
            project_scripts.count(
                '"$SRCROOT/../Scripts/build_ghostty_vt.sh" \\\n'
                '    --work-root "$MACSCOPE_GHOSTTY_VT_BUILD_ROOT"'
            ),
            1,
        )
        self.assertNotIn("MACSCOPE_GHOSTTY_VT_WORK_ROOT", project_scripts)

        self.assertEqual(
            project.get("packages", {}),
            {
                "Lumen": {"path": "../ThirdParty/Lumen"},
                "MachOKit": {"path": "LocalPackages/MachOKit"},
                "RecoveryKit": {"path": "../Packages/RecoveryKit"},
            },
        )
        package_path = pathlib.PurePosixPath("LocalPackages/MachOKit")
        self.assertFalse(package_path.is_absolute())
        self.assertNotIn("..", package_path.parts)

        bootstrap = BOOTSTRAP.read_text(encoding="utf-8")
        machokit_start = 'echo "==> Verifying MachOKit direct-source materialization ..."'
        machokit_publish = "publish-read-only"
        # link admits the pinned read-only root and reuses publication's
        # receipt; there is no separate verify call (883379a18).
        machokit_verify = 'link \\\n  --materialization-root "${MACHOKIT_ROOT}"'
        machokit_link = "--macscope-directory \"${MACSCOPE_DIR}\""
        self.assertEqual(bootstrap.count(machokit_start), 1)
        self.assertEqual(bootstrap.count(machokit_publish), 1)
        self.assertEqual(bootstrap.count(machokit_verify), 1)
        self.assertEqual(bootstrap.count(machokit_link), 1)
        self.assertLess(
            bootstrap.index(machokit_start),
            bootstrap.index(machokit_publish),
        )
        self.assertLess(
            bootstrap.index(machokit_publish),
            bootstrap.index(machokit_verify),
        )
        self.assertLess(
            bootstrap.index(machokit_verify),
            bootstrap.index(machokit_link),
        )
        self.assertLess(
            bootstrap.index(machokit_link),
            bootstrap.index('echo "==> Generating Xcode project (xcodegen generate) ..."'),
        )

        local_packages = ROOT / "MacScope/LocalPackages"
        local_package = local_packages / "MachOKit"
        if local_packages.exists() or local_packages.is_symlink():
            self.assertTrue(local_packages.is_symlink())
            resolved_packages = local_packages.resolve(strict=True)
            self.assertTrue(resolved_packages.is_dir())
            self.assertFalse(resolved_packages.is_relative_to(ROOT.resolve()))
            self.assertFalse(local_package.is_symlink())
            resolved_package = local_package.resolve(strict=True)
            self.assertTrue(resolved_package.is_dir())
            self.assertEqual(resolved_package, resolved_packages / "MachOKit")

        offline_validator = ROOT / "Scripts/dependencies/validate_offline_build_surface.py"
        result = subprocess.run(
            ["/usr/bin/python3", "-B", str(offline_validator)],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_bootstrap_leaves_vt_build_to_xcode_and_publishes_surface(self) -> None:
        bootstrap = BOOTSTRAP.read_text(encoding="utf-8")
        vt_call = '"${SCRIPT_DIR}/build_ghostty_vt.sh"'
        surface_call = '"${SCRIPT_DIR}/dependencies/build_vendored_ghostty_surface.sh"'

        self.assertEqual(bootstrap.count(vt_call), 0)
        self.assertEqual(bootstrap.count(surface_call), 1)
        self.assertNotIn(f"{surface_call} --verify-only", bootstrap)
        self.assertNotIn("MACSCOPE_GHOSTTY_VT_WORK_ROOT", bootstrap)
        self.assertNotIn("GHOSTTY_VT_PRODUCER_PID", bootstrap)
        self.assertIn(
            'GHOSTTY_SURFACE_WORK_ROOT="${MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT:-${TMPDIR:-/tmp}/MacScope}"',
            bootstrap,
        )
        self.assertIn("canonical_external_ghostty_root()", bootstrap)
        self.assertIn('--work-root "${GHOSTTY_SURFACE_WORK_ROOT}"', bootstrap)

        for published in (
            "MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT = ${GHOSTTY_SURFACE_WORK_ROOT}",
            "MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR = ${GHOSTTY_SURFACE_SOURCE_DIR}",
            "MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT = ${GHOSTTY_SURFACE_ARTIFACT_ROOT}",
            "MACSCOPE_GHOSTTY_SURFACE_FRAMEWORK = ${GHOSTTY_SURFACE_FRAMEWORK}",
            "MACSCOPE_GHOSTTY_SURFACE_ENABLED = MACSCOPE_FULL_GHOSTTY_SURFACE",
        ):
            self.assertIn(published, bootstrap)

        self.assertLess(bootstrap.index(surface_call), bootstrap.index("xcodegen generate"))


if __name__ == "__main__":
    unittest.main()
