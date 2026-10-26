#!/usr/bin/env python3
"""Whole-branch, build-free contract checks for GST-01 Task 4.

This harness intentionally audits source and command seams rather than invoking
Xcode, Ghostty, or an installed application.  It is safe to run before the
primary integrator performs the serialized generated-project/build boundary.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "MacScope" / "project.yml"
DEPENDENCY_ROOTS = ROOT / "MacScope" / "DependencyRoots.xcconfig"
BOOTSTRAP = ROOT / "Scripts" / "bootstrap.sh"
SURFACE_CONTRACT = ROOT / "Scripts" / "ghostty-surface-source.contract"
SURFACE_BUILD = ROOT / "Scripts" / "dependencies" / "build_ghostty_surface.sh"
SURFACE_MATERIALIZER = ROOT / "Scripts" / "dependencies" / "materialize_ghostty_surface.sh"
VENDORED_SURFACE_BUILD = (
    ROOT / "Scripts" / "dependencies" / "build_vendored_ghostty_surface.sh"
)
TEST_DRIVER = ROOT / "Scripts" / "test.sh"
SMOKE_SCRIPT = ROOT / "Scripts" / "phase2" / "run_installed_shell_smoke.py"

GHOSTTY_DIR = ROOT / "MacScope" / "Features" / "Shell" / "GhosttySurface"
TERMINAL_VIEW = ROOT / "MacScope" / "Features" / "Shell" / "Phase2TerminalEmulatorView.swift"
BROKER_SURFACE = ROOT / "MacScope" / "Features" / "Shell" / "Phase2GhosttyBrokerSurface.swift"
SHELL_AFFORDANCE = ROOT / "MacScope" / "Features" / "Shell" / "Phase2ShellAffordanceView.swift"
BROKER_CLIENT = ROOT / "MacScope" / "Services" / "Phase2" / "Phase2HumanPTYShellSessionClient.swift"
BROKER_SERVICE = ROOT / "MacScope" / "ShellBrokerService"
WORKSPACE_SHELL = ROOT / "MacScope" / "Stores" / "WorkspaceStore+Phase2ShellSession.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def load_smoke_module():
    spec = importlib.util.spec_from_file_location("installed_shell_smoke", SMOKE_SCRIPT)
    if spec is None or spec.loader is None:
        raise AssertionError("could not load installed shell smoke script")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class GST01Task4WholeBranchContractTests(unittest.TestCase):
    def test_surface_provenance_is_exact_and_separate_from_legacy_vt(self) -> None:
        contract = read(SURFACE_CONTRACT)
        for name, value in {
            "EXPECTED_GHOSTTY_SURFACE_REVISION": '"f64f4aca2c29b554d111b36c3d946a9bddd159ff"',
            "EXPECTED_GHOSTTY_SURFACE_BASE_TREE": '"fa514474cca4b9bdceecb168d818b12b3bab0f1c"',
            "EXPECTED_GHOSTTY_SURFACE_BASE_SHA256": '"a9702b7a9646f86e19d1938f16ca5701d57ff91476c3121d65a1a04431e773f5"',
            "EXPECTED_GHOSTTY_SURFACE_PATCHED_TREE": '"de6cd65b35a423d5d6854c6af3a90be20a52d7eb"',
            "EXPECTED_GHOSTTY_SURFACE_PATCHED_SHA256": '"ead5d48a8cda07addb59af1f35c6c9f7226bbdbd977b7330afd9714ecec6d8ab"',
            "EXPECTED_GHOSTTY_EXTERNAL_IO_ABI_VERSION": '"1"',
        }.items():
            self.assertRegex(contract, re.compile(rf"^{name}={re.escape(value)}$", re.MULTILINE))
        self.assertNotEqual(contract, read(ROOT / "Scripts" / "ghostty-vt-source.contract"))
        self.assertIn("GHOSTTY_EXTERNAL_IO_ABI_VERSION 1", read(SURFACE_BUILD))
        for symbol in (
            "_ghostty_surface_new_external",
            "_ghostty_surface_external_feed",
            "_ghostty_surface_external_set_process_state",
            "_ghostty_surface_is_external_io",
        ):
            self.assertIn(symbol, read(SURFACE_BUILD))
        for resource in ("Info.plist", "libghostty-internal.a", "ghostty.h", "module.modulemap"):
            self.assertIn(resource, read(SURFACE_BUILD))

    def test_ordinary_bootstrap_builds_the_vendored_offline_surface(self) -> None:
        materializer = read(SURFACE_MATERIALIZER)
        builder = read(SURFACE_BUILD)
        vendored_builder = read(VENDORED_SURFACE_BUILD)
        bootstrap = read(BOOTSTRAP)
        self.assertIn("DESTINATION=", materializer)
        self.assertIn("if [[ -e \"${DESTINATION}\" ]]", materializer)
        self.assertIn("git clone", materializer)
        self.assertIn("${SOURCE_ROOT}", builder)
        self.assertIn("MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR", builder)
        self.assertIn("MACSCOPE_ZIG_ROOT", builder)
        self.assertIn("--verify-only", builder)
        self.assertIn("verify_source_checkout", builder)
        self.assertIn("verify_complete", builder)

        # Network-backed acquisition remains an explicit operator tool. The
        # ordinary producer consumes only the checked-in source/package/toolchain
        # closure, verifies it, and installs its output under the external root.
        for value in (
            "ThirdParty/GhosttySurface/Source",
            "ThirdParty/GhosttySurface/zig-pkg",
            "ThirdParty/Zig/zig-0.16.0",
            'OUTPUT_ROOT="${WORK_ROOT}/GhosttySurface"',
            '"${BUILDER}" --verify-only',
            '"${BUILDER}"',
        ):
            self.assertIn(value, vendored_builder)
        self.assertNotIn("git clone", vendored_builder)
        self.assertNotRegex(vendored_builder, r"\bcurl\b|\bwget\b")
        self.assertEqual(bootstrap.count("build_vendored_ghostty_surface.sh"), 1)
        self.assertRegex(
            bootstrap,
            r'build_vendored_ghostty_surface\.sh"\s*\\\s*\n\s*--work-root '
            r'"\$\{GHOSTTY_SURFACE_WORK_ROOT\}"',
        )
        self.assertNotRegex(
            bootstrap,
            r'build_vendored_ghostty_surface\.sh[^&]+--verify-only',
        )

        # Shared settings stay blank and fail closed until bootstrap publishes
        # the exact produced roots through the ignored machine-local xcconfig.
        roots = read(DEPENDENCY_ROOTS)
        for setting in (
            "MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR",
            "MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT",
            "MACSCOPE_GHOSTTY_SURFACE_FRAMEWORK",
            "MACSCOPE_GHOSTTY_SURFACE_ENABLED",
        ):
            self.assertRegex(roots, re.compile(rf"^{setting} =\s*$", re.MULTILINE))
            self.assertRegex(bootstrap, re.compile(rf"^{setting} = .+$", re.MULTILINE))
        self.assertIn(
            "MACSCOPE_GHOSTTY_SURFACE_ENABLED = MACSCOPE_FULL_GHOSTTY_SURFACE",
            bootstrap,
        )
        self.assertNotIn("materialize_ghostty_surface.sh", read(PROJECT))
        self.assertNotIn("build_ghostty_surface.sh", read(PROJECT))
        self.assertNotIn("MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR", read(TEST_DRIVER))

    def test_build_outputs_are_redirected_outside_repository(self) -> None:
        project = read(PROJECT)
        driver = read(TEST_DRIVER)
        bootstrap = read(BOOTSTRAP)
        vendored_builder = read(VENDORED_SURFACE_BUILD)
        self.assertRegex(driver, r"-derivedDataPath \"\$\{TEST_DERIVED_DATA\}\"")
        self.assertIn("must remain outside the repository", driver)
        self.assertNotRegex(project, r"(?m)^\s*derivedDataPath:\s*[^$\n]+")
        self.assertNotIn('DerivedData/<', project)
        self.assertIn("canonical_external_ghostty_root", bootstrap)
        self.assertIn("must remain outside the repository", vendored_builder)
        self.assertIn('[[ "${WORK_ROOT}" == /* ]]', vendored_builder)
        self.assertIn(
            'MACSCOPE_GHOSTTY_SURFACE_STAGED_ROOT: "$(PROJECT_TEMP_DIR)/MacScopeGhosttySurface"',
            project,
        )
        # Immutable producer inputs remain external qualification inputs. Only
        # their manifest-verified compiler/linker snapshot is copied into
        # Xcode's external DerivedData-owned target-intermediate directory.
        for line in project.splitlines():
            if any(
                setting in line
                for setting in (
                    "MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR",
                    "MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT",
                )
            ):
                self.assertNotIn("PROJECT_TEMP_DIR", line)
        # No Ghostty builder output is rooted in the checkout.
        self.assertNotIn('"${REPO_ROOT}/macos/GhosttyKit.xcframework"', read(SURFACE_BUILD))

    def test_linked_surface_has_exact_abi_and_no_process_or_pty_authority(self) -> None:
        adapter = read(GHOSTTY_DIR / "MacScopeGhosttyLinkedSurfaceAdapter.swift")
        self.assertIn("#if canImport(GhosttyKit) && MACSCOPE_FULL_GHOSTTY_SURFACE", adapter)
        self.assertIn("ghostty_surface_new_external", adapter)
        self.assertIn("ghostty_surface_is_external_io", adapter)
        self.assertIn("GHOSTTY_EXTERNAL_IO_ABI_VERSION", adapter)
        for forbidden in (
            r"\bProcess\s*\(",
            r"\bfork\s*\(",
            r"\bexec[a-z]*\s*\(",
            r"\bposix_spawn\s*\(",
            r"\bopenpty\s*\(",
            r"\bioctl\s*\(",
            r"TIOCSWINSZ",
            r"kill\s*\(",
            r"waitpid\s*\(",
        ):
            self.assertIsNone(re.search(forbidden, adapter), forbidden)
        self.assertIn("Phase2HumanPTYShellSessionClient", read(BROKER_CLIENT))
        broker_files = "\n".join(read(path) for path in BROKER_SERVICE.glob("*.swift"))
        self.assertRegex(broker_files, r"Phase2ShellBrokerPTYAllocator|Phase2ShellBrokerProcessAdapter")
        self.assertIn("ptyOwner == .shellBrokerLaunchAgent", read(WORKSPACE_SHELL))

    def test_session_request_generation_fencing_and_ordered_teardown_are_visible(self) -> None:
        sources = "\n".join(read(path) for path in GHOSTTY_DIR.glob("*.swift"))
        for token in ("sessionID", "requestID", "generation", "staleOrRetiredGeneration"):
            self.assertIn(token, sources)
        coordinator = read(GHOSTTY_DIR / "MacScopeGhosttySurfaceCoordinator.swift")
        for token in (
            "fence.permits(candidate)",
            "fence.retire()",
            "stopFeed",
            "invalidateCallbacks",
            "detachDisplayAndWakeup",
            "destroySurface",
            "releaseBridgeBox",
        ):
            self.assertIn(token, coordinator)
        self.assertLess(coordinator.index("retireGeneration"), coordinator.index("stopFeed"))
        self.assertLess(coordinator.index("stopFeed"), coordinator.index("invalidateCallbacks"))
        self.assertLess(coordinator.index("invalidateCallbacks"), coordinator.index("destroySurface"))
        view = read(TERMINAL_VIEW)
        for token in ("sessionID", "requestID", "generation", "gap", "replay"):
            self.assertIn(token, view)
        self.assertIn("inputHandler", view)
        self.assertIn("resizeHandler", view)
        self.assertIn("writeInput", read(WORKSPACE_SHELL))
        self.assertIn("resize", read(WORKSPACE_SHELL))

    def test_service_smoke_cli_and_gui_source_seams_are_distinct(self) -> None:
        smoke = load_smoke_module()
        smoke_source = read(SMOKE_SCRIPT)
        affordance = read(SHELL_AFFORDANCE)
        broker_surface = read(BROKER_SURFACE)
        arguments = smoke.parse_arguments(["--app", "/Applications/MacScope.app"])
        self.assertEqual(arguments.restart_wait_seconds, smoke.OLD_DETACHED_GRACE_SECONDS + 1.0)
        self.assertEqual(arguments.timeout_seconds, 15.0)
        self.assertTrue((ROOT / "Scripts" / "phase2" / "run_installed_shell_smoke.py").is_file())
        help_result = subprocess.run(
            [str(SMOKE_SCRIPT), "--help"], capture_output=True, text=True, check=False
        )
        self.assertEqual(help_result.returncode, 0, help_result.stderr)
        self.assertIn("--single-launch", help_result.stdout)
        self.assertIn("--restart-wait-seconds", help_result.stdout)
        self.assertIn("ShellBroker", smoke_source)
        self.assertIn("schemaVersion", smoke_source)
        self.assertIn("does not use Accessibility or XCUITest", smoke_source)

        # The installed smoke proves the service/CLI evidence path. The GUI
        # render seam is separately visible in product source and remains fed
        # from the authoritative broker transcript with coordinate fencing.
        for token in (
            "fullSurfaceRendererFactory",
            "context.transcript.coordinate == coordinate.rendererCoordinate",
            "Phase2GhosttyBrokerSurface(",
            "transcriptEvents: presentation.terminalTranscriptEvents",
            "store.writePhase2ShellInput(bytes, from: coordinate)",
        ):
            self.assertIn(token, affordance)
        self.assertIn("MacScopeGhosttySurfaceRepresentable(", broker_surface)
        self.assertIn("feedCursor.feed(latestTranscript, budget: feedBudget)", broker_surface)
        self.assertIn("return Phase2GhosttyTranscriptProjection(", read(TERMINAL_VIEW))


if __name__ == "__main__":
    unittest.main()
