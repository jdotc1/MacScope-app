#!/usr/bin/env python3

from __future__ import annotations

from pathlib import Path
import re
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
HARNESS = (
    REPOSITORY_ROOT
    / "MacScope"
    / "Tests"
    / "MacScopeInstalledAppUITests"
    / "InstalledAppUITestHarness.swift"
)
FIXTURE = (
    REPOSITORY_ROOT
    / "MacScope"
    / "Tests"
    / "MacScopeInstalledAppUITests"
    / "Task10InstalledWorkspaceFixture.swift"
)
UI_TESTS = HARNESS.with_name("WS24InstalledAppUITests.swift")
FUNCTION_DECLARATION = re.compile(
    r"^\s*(?:private\s+)?(?:static\s+)?func\s+([A-Za-z0-9_]+)\s*\([^)]*\)[^{]*\{",
    re.MULTILINE,
)


def function_body(source: str, name: str, *, parameter: str | None = None) -> str:
    # Empty closure defaults belong to the signature, not the function body.
    source = re.sub(r"(=\s*)\{\s*\}", r"\1__emptyClosureDefault__", source)
    matches = [match for match in FUNCTION_DECLARATION.finditer(source)
               if match.group(1) == name
               and (parameter is None or parameter in match.group(0))]
    if len(matches) != 1:
        raise AssertionError(f"expected one Swift function named {name}, found {len(matches)}")
    match = matches[0]
    depth = 1
    cursor = match.end()
    while cursor < len(source) and depth:
        if source[cursor] == "{":
            depth += 1
        elif source[cursor] == "}":
            depth -= 1
        cursor += 1
    if depth:
        raise AssertionError(f"unterminated Swift function: {name}")
    return source[match.end():cursor - 1]


class InstalledAppUIHarnessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.source = HARNESS.read_text(encoding="utf-8")

    def test_guard_preserves_explicit_opt_in_and_qualification_identity(self) -> None:
        guard = function_body(self.source, "requireOptedInCandidate")
        for fragment in (
            'environment[Self.optInEnvironmentKey] == "1"',
            "FileManager.default.fileExists(atPath: Self.optInFlagPath)",
            "throw XCTSkip(",
            '?? "/Applications/MacScope.app"',
            "provenance.qualificationEligible == true",
            "provenance.repositoryClean == true",
            'provenance.configuration == "Release"',
            "sourceCommit.count == 40",
            "executableSHA256: executableSHA256",
        ):
            self.assertIn(fragment, guard)

    def test_launch_cleanup_and_lookup_stay_bound_to_the_exact_executable(self) -> None:
        self.assertNotIn(
            "XCUIApplication(bundleIdentifier:",
            self.source,
            "installed qualification must never launch or terminate by bundle identifier alone",
        )
        self.assertNotRegex(
            self.source,
            r"\b(?:killall|pkill)\b",
            "installed qualification must never use process-name-wide cleanup",
        )

        launch = function_body(self.source, "launch")
        self.assertIn("XCUIApplication(url: installedAppURL)", launch)
        self.assertIn("try assertCandidateIdentityIsUnchanged()", launch)

        lookup = function_body(self.source, "runningCandidate")
        self.assertIn(
            ".runningApplications(withBundleIdentifier: Self.bundleIdentifier)",
            lookup,
        )
        self.assertIn(
            ".first(where: { $0.executableURL?.path == executableURL.path })",
            lookup,
        )

        cleanup = function_body(self.source, "terminateExactCandidateIfRunning")
        for fragment in (
            "runningCandidate(timeout: 0)",
            "let processIdentifier = runningApplication.processIdentifier",
            "runningApplication.processIdentifier == processIdentifier",
            "runningApplication.executableURL?.path == expectedExecutablePath",
            "runningApplication.forceTerminate()",
        ):
            self.assertIn(fragment, cleanup)

    def test_foreign_application_is_refused_before_xcuitest_can_launch(self) -> None:
        launch = function_body(self.source, "launch")
        self.assertIn("try assertNoForeignRunningApplication()", launch)
        self.assertLess(launch.index("try assertNoForeignRunningApplication()"), launch.index("app.launch()"))
        preflight = function_body(self.source, "assertNoForeignRunningApplication")
        for fragment in (
            ".runningApplications(withBundleIdentifier: Self.bundleIdentifier)",
            "runningApplication.processIdentifier",
            "runningApplication.executableURL",
            "executableURL.path",
            "throw Self.harnessError",
            "PID",
        ):
            self.assertIn(fragment, preflight)
        self.assertNotIn(".terminate(", preflight)
        self.assertNotIn(".forceTerminate(", preflight)

    def test_candidate_identity_is_rechecked_before_product_interaction(self) -> None:
        identity_check = function_body(self.source, "assertCandidateIdentityIsUnchanged")
        self.assertIn("provenance.gitHeadCommit == identity.sourceCommit", identity_check)
        self.assertIn("observedDigest == identity.executableSHA256", identity_check)

        for function_name in (
            "launch",
            "openWorkspacePackage",
            "saveOpenWorkspace",
        ):
            self.assertIn(
                "try assertCandidateIdentityIsUnchanged()",
                function_body(self.source, function_name),
                f"{function_name} must recheck the frozen candidate before interaction",
            )

    def test_exact_ax_diagnostics_stay_in_the_verified_fixture_window_without_fallback(self) -> None:
        source = UI_TESTS.read_text(encoding="utf-8")
        contract = function_body(source, "requireExactAccessibilityContract")
        self.assertIn("harness.waitForFocusedWindow(", contract)
        self.assertIn("titled: expectedWindowTitle", contract)
        self.assertIn("of: window", contract)
        self.assertNotIn("harness.accessibilityApplication()", contract)
        self.assertIn("harness.accessibilityWindowDiagnostic(", contract)
        self.assertIn("attachment.lifetime = .keepAlways", contract)
        self.assertLess(contract.index("add(attachment)"), contract.index("XCTAssertEqual("))
        self.assertIn("attribute: kAXValueAttribute as CFString", contract)
        self.assertNotIn("kAXValueDescriptionAttribute", contract)
        for caller in ("exerciseCorpusCounts", "exerciseCurrentGap", "exerciseTaskEvidenceCounts"):
            body = function_body(source, caller)
            self.assertIn("expectedWindowTitle: fixture.packageURL.deletingPathExtension().lastPathComponent", body)

    def test_raw_ax_diagnostics_preserve_status_type_and_bounded_census(self) -> None:
        observation = function_body(self.source, "accessibilityAttributeObservation")
        for fragment in (
            "AXUIElementCopyAttributeValue", "result.rawValue", "CFGetTypeID",
            "CFCopyTypeIDDescription", "CFStringGetTypeID", "maximumUTF8Bytes: 512",
        ):
            self.assertIn(fragment, observation)
        self.assertNotIn("String(describing:", observation)
        self.assertNotIn("CFCopyDescription", observation)
        diagnostic = function_body(self.source, "accessibilityWindowDiagnostic")
        for fragment in (
            "kAXValueAttribute", "kAXValueDescriptionAttribute", "kAXRoleAttribute",
            "kAXDescriptionAttribute", "kAXHelpAttribute", "kAXTitleAttribute",
            "AXUIElementGetPid", "AXUIElementGetAttributeValueCount",
            "AXUIElementCopyAttributeValues", "remainingElements = 256",
            "matches.count < 8", "wasTruncated", "wasIncomplete",
        ):
            self.assertIn(fragment, diagnostic)
        self.assertNotIn("accessibilityApplication(", diagnostic)
        self.assertNotIn("String(describing:", diagnostic)

    def test_shared_harness_freezes_lifecycle_and_presentation_capabilities(self) -> None:
        for function_name in (
            "openWorkspacePackage",
            "saveOpenWorkspace",
            "terminateRelaunchAndOpenWorkspace",
            "windowScreenshotAttachment",
        ):
            function_body(self.source, function_name)
        governed_resize = function_body(
            self.source, "setFocusedWindowSize", parameter="_ windowSize: WindowSize"
        )
        self.assertIn("try setFocusedWindowSize(windowSize.size, timeout: timeout)", governed_resize)
        exact_resize = function_body(
            self.source, "setFocusedWindowSize", parameter="_ requestedSize: CGSize"
        )
        self.assertIn("try requestFocusedWindowSize(requestedSize, timeout: timeout)", exact_resize)
        self.assertIn("abs(observed.width - requestedSize.width) < 1", exact_resize)
        self.assertIn("abs(observed.height - requestedSize.height) < 1", exact_resize)
        resize_request = function_body(self.source, "requestFocusedWindowSize")
        self.assertIn("try accessibilityApplication(timeout: timeout)", resize_request)
        self.assertIn("requestedSize.width > 0", resize_request)
        self.assertIn("requestedSize.height > 0", resize_request)
        self.assertIn("requestedSize.width.isFinite", resize_request)
        self.assertIn("requestedSize.height.isFinite", resize_request)
        self.assertIn("AXUIElementSetAttributeValue", resize_request)
        self.assertIn("guard result == .success", resize_request)
        self.assertRegex(
            self.source,
            r"func\s+waitForAccessibilityDescendant\s*\(",
        )

        self.assertIn('case automatic = "auto"', self.source)
        self.assertIn("case light", self.source)
        self.assertIn("case dark", self.source)
        self.assertIn("CGSize(width: 1_080, height: 680)", self.source)
        self.assertIn("CGSize(width: 1_440, height: 840)", self.source)

        open_workspace = function_body(self.source, "openWorkspacePackage")
        self.assertIn('commandTitle: "Open Workspace..."', open_workspace)
        self.assertIn('context: "File ▸ Open Workspace"', open_workspace)

        open_panel = function_body(self.source, "chooseFileThroughOpenPanel")
        self.assertIn("try performFileMenuCommand(", open_panel)
        self.assertIn("titled: commandTitle", open_panel)
        self.assertIn("context: context", open_panel)

        file_menu = function_body(self.source, "performFileMenuCommand")
        self.assertIn("runningApplication.executableURL?.path == executableURL.path", file_menu)
        self.assertIn('titled: "File"', file_menu)
        self.assertIn("titled: title", file_menu)
        self.assertIn("try Self.accessibilityPress(command, context: context)", file_menu)

        save_workspace = function_body(self.source, "saveOpenWorkspace")
        self.assertIn('titled: "Save"', save_workspace)

    def test_product_generated_fixture_remains_integrity_checked_and_private(self) -> None:
        fixture = FIXTURE.read_text(encoding="utf-8")
        for fragment in (
            'sidecar.generator == "WorkspaceStore.writeDocumentPackage"',
            'sidecar.workspaceName == "Task 10 persisted workspace"',
            "packageTreeSHA256(at: packageURL) == sidecar.packageTreeSHA256",
            "FileManager.default.temporaryDirectory",
            "func remove()",
        ):
            self.assertIn(fragment, fixture)


if __name__ == "__main__":
    unittest.main()
