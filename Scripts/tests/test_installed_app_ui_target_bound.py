#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
from pathlib import Path
import re
import unittest
from unittest import mock

from Scripts import next5_adaptive_pane_acceptance as adaptive_panes


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
PROJECT_YML = REPOSITORY_ROOT / "MacScope" / "project.yml"
UI_TEST_ROOT = (
    REPOSITORY_ROOT
    / "MacScope"
    / "Tests"
    / "MacScopeInstalledAppUITests"
)
REPORT_SCRIPT = REPOSITORY_ROOT / "Scripts" / "ws24_emit_installed_qualification_report.py"
BASE_TEST_METHODS = {
    "testForegroundEditorMenuAndKeyboardParity",
    "testForegroundPaletteAddressAndEditorHandoffsAcceptTyping",
    "testAdaptivePanesRemainInsideWideAndMinimumWindows",
    "testNativeDividersMoveClampAndPreserveKeyboardFocus",
    "testPaneWidthsRestoreAndRemainIndependentAcrossWindows",

    "testOptInInstalledAppLaunchesAndExposesDebuggerDeck",
    "testOptInInstalledAppAttachSheetReachabilityAndDiagnostics",
    "testOptInInstalledAppOpensPersistedWorkspaceAndReachesReconstruction",
    "testOptInInstalledAppRequiresExplicitELFArchiveMemberSelection",
    "testBundledTask10PersistedWorkspaceFixtureHasRecordedIntegrity",
}
BASE_OPT_IN_TEST_METHODS = {
    "testForegroundEditorMenuAndKeyboardParity",
    "testForegroundPaletteAddressAndEditorHandoffsAcceptTyping",
    "testAdaptivePanesRemainInsideWideAndMinimumWindows",
    "testNativeDividersMoveClampAndPreserveKeyboardFocus",
    "testPaneWidthsRestoreAndRemainIndependentAcrossWindows",

    "testOptInInstalledAppLaunchesAndExposesDebuggerDeck",
    "testOptInInstalledAppAttachSheetReachabilityAndDiagnostics",
    "testOptInInstalledAppOpensPersistedWorkspaceAndReachesReconstruction",
    "testOptInInstalledAppRequiresExplicitELFArchiveMemberSelection",
}
# This host-seeded preference probe is a diagnostic, not a Task 10 acceptance
# selector. Keep registration exact and require its separate safety boundary.
DIAGNOSTIC_TEST_METHODS = {"testInstalledSharedPreferenceDomainRoundTrip"}
TEST_DECLARATION = re.compile(r"^\s*func\s+(test[A-Za-z0-9_]+)\s*\([^)]*\)[^{]*\{", re.MULTILINE)


def load_report_module():
    specification = importlib.util.spec_from_file_location(
        "ws24_emit_installed_qualification_report_target_bound",
        REPORT_SCRIPT,
    )
    if specification is None or specification.loader is None:
        raise AssertionError("could not load installed qualification report module")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


ws24_report = load_report_module()
SELECTOR_TEST_METHODS = {
    selector["method"] for selector in ws24_report.load_installed_selector_catalog()
}
ADAPTIVE_TEST_METHODS = {
    selector.split("/", 1)[1].removesuffix("()")
    for selector in adaptive_panes.SELECTORS
}


def method_bodies(source: str) -> list[tuple[str, str]]:
    bodies: list[tuple[str, str]] = []
    for match in TEST_DECLARATION.finditer(source):
        depth = 1
        cursor = match.end()
        while cursor < len(source) and depth:
            if source[cursor] == "{":
                depth += 1
            elif source[cursor] == "}":
                depth -= 1
            cursor += 1
        if depth:
            raise AssertionError(f"unterminated Swift test method: {match.group(1)}")
        bodies.append((match.group(1), source[match.end():cursor - 1]))
    return bodies


class InstalledAppUITargetBoundTests(unittest.TestCase):
    def test_adaptive_pane_runner_compiles_single_production_layout_authority(self) -> None:
        project = PROJECT_YML.read_text(encoding="utf-8")
        target = project.split("  MacScopeInstalledAppUITests:\n", 1)[1].split("\nschemes:", 1)[0]
        self.assertIn("      - path: DesignSystem/AppLayout.swift\n", target)
        self.assertIn("      - target: MacScopeApp\n", target)
        self.assertNotIn("TEST_HOST:", target)
        self.assertNotIn("BUNDLE_LOADER:", target)
        self.assertNotIn("Ghostty", target)
        source = (UI_TEST_ROOT / "WorkspaceAdaptivePaneInstalledAppUITests.swift").read_text(encoding="utf-8")
        self.assertNotIn("import MacScope", source)
        self.assertNotIn("canImport(MacScope)", source)
        self.assertNotIn("CGFloat.nan", source)
        for name in ("sidebarMinWidth", "sidebarMaxWidth", "inspectorMinWidth",
                     "inspectorMaxWidth", "editorMinimumReadableWidth"):
            self.assertIn(f"AppLayout.{name}", source)
        layout = REPOSITORY_ROOT / "MacScope/DesignSystem/AppLayout.swift"
        self.assertTrue(layout.is_file())
        for declaration in ("enum AppLayout {", "struct WorkspacePaneMetrics {"):
            owners = [path for path in (REPOSITORY_ROOT / "MacScope").rglob("*.swift")
                      if declaration in path.read_text(encoding="utf-8")]
            self.assertEqual(owners, [layout])

    def test_scanner_root_matches_the_recursive_xcodegen_target_source(self) -> None:
        project_text = PROJECT_YML.read_text(encoding="utf-8")
        self.assertIn(
            "  MacScopeInstalledAppUITests:\n"
            "    type: bundle.ui-testing\n",
            project_text,
        )
        target_start = project_text.index("  MacScopeInstalledAppUITests:\n")
        next_target = re.search(
            r"^  [A-Za-z][A-Za-z0-9_]*:\s*$",
            project_text[target_start + 1:],
            re.MULTILINE,
        )
        target_end = (
            target_start + 1 + next_target.start()
            if next_target is not None
            else len(project_text)
        )
        target_text = project_text[target_start:target_end]
        self.assertIn(
            "      - path: Tests/MacScopeInstalledAppUITests\n",
            target_text,
            "scanner root must stay bound to the recursively compiled UI target source",
        )

    def test_installed_app_ui_target_declares_only_catalog_bound_opt_in_methods(self) -> None:
        methods = [
            method
            for source_path in sorted(UI_TEST_ROOT.rglob("*.swift"))
            for method in method_bodies(source_path.read_text(encoding="utf-8"))
        ]
        method_names = [name for name, _body in methods]

        observed_methods = set(method_names)
        self.assertTrue(
            DIAGNOSTIC_TEST_METHODS.isdisjoint(BASE_TEST_METHODS | SELECTOR_TEST_METHODS | ADAPTIVE_TEST_METHODS),
            "installed preference diagnostic must remain separate from acceptance catalogs",
        )
        self.assertTrue(
            BASE_TEST_METHODS.issubset(observed_methods),
            "installed-app UI target removed a previously governed base test",
        )
        self.assertTrue(
            observed_methods.issubset(BASE_TEST_METHODS | SELECTOR_TEST_METHODS | ADAPTIVE_TEST_METHODS | DIAGNOSTIC_TEST_METHODS),
            "installed-app UI target added a test that is neither a governed base "
            "test, an exact registered diagnostic, nor derived from the canonical "
            "T10C or adaptive-pane selector catalogs",
        )
        self.assertEqual(
            len(method_names),
            len(observed_methods),
            "installed-app UI target must not duplicate an approved test method",
        )
        observed_selector_methods = observed_methods & SELECTOR_TEST_METHODS
        self.assertEqual(
            observed_selector_methods,
            SELECTOR_TEST_METHODS,
            "the installed-app target must implement every canonical Task 10 selector",
        )
        self.assertTrue(ADAPTIVE_TEST_METHODS.issubset(observed_methods))
        self.assertTrue(DIAGNOSTIC_TEST_METHODS.issubset(observed_methods))
        for method_name, body in methods:
            if method_name in BASE_OPT_IN_TEST_METHODS | SELECTOR_TEST_METHODS | ADAPTIVE_TEST_METHODS | DIAGNOSTIC_TEST_METHODS:
                self.assertIn(
                    "InstalledAppUITestHarness.requireOptedInCandidate()",
                    body,
                    f"{method_name} must route through the installed-app opt-in guard",
                )
                guard_offset = body.index(
                    "InstalledAppUITestHarness.requireOptedInCandidate()"
                )
                driving_offsets = [
                    body.index(marker)
                    for marker in (
                        ".terminateExactCandidateIfRunning()",
                        ".launch()",
                        ".openBinary(",
                        ".openWorkspacePackage(",
                    )
                    if marker in body
                ]
                if method_name in DIAGNOSTIC_TEST_METHODS:
                    nonce_markers = (
                        "MACSCOPE_WS24_PREFERENCES_PROBE_NONCE",
                        "UUID(uuidString: nonce) != nil",
                        "throw XCTSkip(",
                    )
                    for marker in nonce_markers:
                        self.assertIn(
                            marker, body,
                            "preference diagnostic must require its explicit host-seeded UUID nonce",
                        )
                    preference_offset = body.index("Task10CAppPreferenceDomain.")
                    self.assertLess(
                        guard_offset, preference_offset,
                        "preference diagnostic must opt in before any preference access",
                    )
                    for marker in nonce_markers:
                        self.assertLess(
                            body.index(marker), preference_offset,
                            "preference diagnostic must require its host-seeded UUID nonce before preference access",
                        )
                    self.assertFalse(
                        driving_offsets,
                        "preference diagnostic must not drive the installed app",
                    )
                    continue
                self.assertTrue(
                    driving_offsets,
                    f"{method_name} must exercise an installed-app driving operation",
                )
                self.assertLess(
                    guard_offset,
                    min(driving_offsets),
                    f"{method_name} must opt in before its first installed-app driving operation",
                )

    def test_target_catalog_contract_still_rejects_unknown_selector(self) -> None:
        original = method_bodies
        with mock.patch.dict(globals(), {
            "method_bodies": lambda source: original(source) + [("testUnregisteredSelector", "")],
        }):
            with self.assertRaisesRegex(AssertionError, "neither a governed base"):
                self.test_installed_app_ui_target_declares_only_catalog_bound_opt_in_methods()

    def test_workspace_command_proofs_reject_missing_or_late_opt_in(self) -> None:
        original = method_bodies
        guard = "InstalledAppUITestHarness.requireOptedInCandidate()"
        for method in (
            "testForegroundEditorMenuAndKeyboardParity",
            "testForegroundPaletteAddressAndEditorHandoffsAcceptTyping",
        ):
            for mutation, diagnostic in (
                (lambda body: body.replace(guard, "unguardedCandidate()"), "must route through.*opt-in guard"),
                (lambda body: "harness.launch()\n" + body, "must opt in before.*driving operation"),
            ):
                with self.subTest(method=method, diagnostic=diagnostic):
                    def mutated_methods(source):
                        return [
                            (name, mutation(body) if name == method else body)
                            for name, body in original(source)
                        ]

                    with mock.patch.dict(globals(), {"method_bodies": mutated_methods}):
                        with self.assertRaisesRegex(AssertionError, diagnostic):
                            self.test_installed_app_ui_target_declares_only_catalog_bound_opt_in_methods()

    def assert_preference_diagnostic_rejected(self, mutate_body, diagnostic: str) -> None:
        original = method_bodies

        def mutated_methods(source):
            return [
                (name, mutate_body(body) if name == "testInstalledSharedPreferenceDomainRoundTrip" else body)
                for name, body in original(source)
            ]

        with mock.patch.dict(globals(), {"method_bodies": mutated_methods}):
            with self.assertRaisesRegex(AssertionError, diagnostic):
                self.test_installed_app_ui_target_declares_only_catalog_bound_opt_in_methods()

    def test_preference_diagnostic_rejects_domain_access_before_opt_in(self) -> None:
        self.assert_preference_diagnostic_rejected(
            lambda body: "try Task10CAppPreferenceDomain.synchronize()\n" + body,
            "must opt in before.*preference",
        )

    def test_preference_diagnostic_rejects_missing_opt_in(self) -> None:
        self.assert_preference_diagnostic_rejected(
            lambda body: body.replace("InstalledAppUITestHarness.requireOptedInCandidate()", "unguardedCandidate()"),
            "must route through.*opt-in guard",
        )

    def test_preference_diagnostic_rejects_missing_or_unvalidated_host_nonce(self) -> None:
        for original, replacement in (
            ("MACSCOPE_WS24_PREFERENCES_PROBE_NONCE", "OTHER_NONCE"),
            ("UUID(uuidString: nonce) != nil", "nonce.isEmpty == false"),
            ("XCTSkip(", "XCTFail("),
        ):
            with self.subTest(original=original):
                self.assert_preference_diagnostic_rejected(
                    lambda body: body.replace(original, replacement),
                    "must require.*host-seeded UUID nonce",
                )

    def test_preference_diagnostic_rejects_app_driving_operation(self) -> None:
        self.assert_preference_diagnostic_rejected(
            lambda body: body + "\nharness.launch()\n",
            "diagnostic must not drive the installed app",
        )

    def test_preference_diagnostic_cannot_become_a_required_acceptance_selector(self) -> None:
        with mock.patch.dict(globals(), {
            "SELECTOR_TEST_METHODS": SELECTOR_TEST_METHODS | {"testInstalledSharedPreferenceDomainRoundTrip"},
        }):
            with self.assertRaisesRegex(AssertionError, "diagnostic.*acceptance"):
                self.test_installed_app_ui_target_declares_only_catalog_bound_opt_in_methods()

    def test_archive_picker_installed_selector_freezes_accessibility_and_authority_contract(self) -> None:
        sheet = (
            REPOSITORY_ROOT / "MacScope" / "Features" / "Loader" / "LoaderOptionsSheet.swift"
        ).read_text(encoding="utf-8")
        tests = (
            UI_TEST_ROOT / "WS24InstalledAppUITests.swift"
        ).read_text(encoding="utf-8")
        fixture = (
            UI_TEST_ROOT / "InstalledELFArchiveFixture.swift"
        ).read_text(encoding="utf-8")
        harness = (
            UI_TEST_ROOT / "InstalledAppUITestHarness.swift"
        ).read_text(encoding="utf-8")
        archive_method = dict(method_bodies(tests))[
            "testOptInInstalledAppRequiresExplicitELFArchiveMemberSelection"
        ]

        for identifier in (
            "loader.options.sheet",
            "loader.archive.members",
            "loader.archive.member.\\(member.index)",
            "loader.options.open",
            "loader.options.cancel",
        ):
            self.assertIn(identifier, sheet)
        self.assertIn(
            "func testOptInInstalledAppRequiresExplicitELFArchiveMemberSelection()",
            tests,
        )
        self.assertIn("XCTAssertFalse(\n            openButton.isEnabled", archive_method)
        self.assertIn("InstalledELFArchiveFixture.selectedMemberName", archive_method)
        self.assertIn("XCTAssertEqual(app.state, .runningForeground)", archive_method)
        self.assertIn("XCUIScreen.main.screenshot()", archive_method)
        self.assertNotIn("disassembly.row.", archive_method)
        self.assertNotIn("workspace.titlebar.document-name", archive_method)
        post_confirmation = archive_method.split("openButton.click()", maxsplit=1)[1]
        self.assertNotIn(
            "loader.options.sheet",
            post_confirmation,
            "post-confirmation qualification must observe the loaded product result instead of "
            "querying a destroyed SwiftUI accessibility node",
        )
        self.assertNotIn(
            "picker.",
            post_confirmation,
            "post-confirmation qualification must not retain or query the destroyed picker node",
        )
        self.assertIn("selectedBinary.waitForExistence", post_confirmation)
        self.assertNotIn("selectedPayloadRow", post_confirmation)
        self.assertIn('static let selectedEntryPointAddress = "0x1000"', fixture)
        self.assertIn('static let selectedEntryPointMnemonic = "nop"', fixture)
        self.assertIn('static let unselectedEntryPointMnemonic = "ret"', fixture)
        self.assertIn('(firstMemberName)/", makeMinimalELF(marker: 0xc3)', fixture)
        self.assertIn('(selectedMemberName)/", makeMinimalELF(marker: 0x90)', fixture)
        self.assertIn("func openBinary(_ binaryURL: URL, in app: XCUIApplication)", harness)
        self.assertNotIn(
            "testOptInInstalledAppRequiresExplicitELFArchiveMemberSelection",
            "\n".join(selector["method"] for selector in ws24_report.load_installed_selector_catalog()),
            "archive qualification must remain independent of the frozen Task 10 selector matrix",
        )

    def test_disassembly_accessibility_avoids_swiftui_parent_label_cycles(self) -> None:
        editor = (
            REPOSITORY_ROOT / "MacScope" / "Features" / "Editor" / "EditorSurfaceView.swift"
        ).read_text(encoding="utf-8")
        native_leaf = (
            REPOSITORY_ROOT
            / "MacScope"
            / "Bridges"
            / "DisassemblyRowAccessibilityLeaf.swift"
        ).read_text(encoding="utf-8")
        native_host_start = native_leaf.index(
            "final class DisassemblyRowAccessibilityLeafNSView: NSView"
        )
        native_element_start = native_leaf.index(
            "final class DisassemblyRowAccessibilityElement: NSView"
        )
        native_host = native_leaf[native_host_start:native_element_start]
        native_element = native_leaf[native_element_start:]
        view_start = editor.index("struct DisassemblyView: View")
        view_end = editor.index("/// Immutable identity for one rendered disassembly row", view_start)
        view = editor[view_start:view_end]
        # The rows became internal for LumenSurfaceStepsConformanceTests (1758990bd).
        header_start = editor.index("struct DisassemblyHeaderRow: View")
        header_end = editor.index("struct DisassemblyListingRow: View", header_start)
        header = editor[header_start:header_end]
        row_start = header_end
        row_end = editor.index("struct DisassemblySectionHeaderRow: View", row_start)
        row = editor[row_start:row_end]

        self.assertNotIn(".accessibilityElement(children: .contain)", view)
        self.assertNotIn(
            ".accessibilityLabel(AppAccessibilityText.disassemblyTableLabel)",
            view,
        )
        self.assertNotIn(".accessibilityElement(", header)
        self.assertNotIn(".accessibilityLabel(", header)
        self.assertNotIn(".accessibilityValue(", header)
        self.assertNotIn("disassemblyAccessibilityIdentifier", row)
        self.assertIn(
            ".accessibilityIdentifier(breakpointControlAccessibility.identifier)",
            row,
        )
        visual_start = row.index("ZStack {")
        outer_frame = row.index(
            "\n        .frame(height: AppEditorChrome.disassemblyRowHeight)",
            visual_start,
        )
        for modifier in (".onTapGesture", ".contextMenu", ".focusable(true)"):
            self.assertIn(modifier, row[visual_start:outer_frame])
            self.assertNotIn(modifier, row[outer_frame:])
        # Only selectable visual text is hidden. Its native sibling owns the
        # stored row semantics; neither the breakpoint nor the outer row is hidden.
        leaf_start = row.index("DisassemblyRowAccessibilityLeaf(", visual_start)
        self.assertLess(leaf_start, outer_frame)
        self.assertEqual(row.count("DisassemblyRowAccessibilityLeaf("), 1)
        self.assertEqual(row[visual_start:leaf_start].count(".accessibilityHidden(true)"), 1)
        # The decorative live-PC marker inside the breakpoint button (U2) is the
        # one hidden child before the visual stack; the button itself is not hidden.
        pre_visual = row[:visual_start]
        self.assertLessEqual(pre_visual.count(".accessibilityHidden("), 1)
        if ".accessibilityHidden(" in pre_visual:
            self.assertRegex(
                pre_visual,
                r"LumenProgramCounterMarker\(\)\n(?:\s+\.frame\([^\n]*\)\n)?"
                r"\s+\.accessibilityHidden\(true\)",
            )
        self.assertNotIn(".accessibilityHidden(", row[leaf_start:])
        native_sibling = row[leaf_start:outer_frame]
        self.assertIn("label: rowAccessibilityLabel", native_sibling)
        self.assertIn('identifier: "disassembly.row.\\(breakpointTarget.slot.rawValue).\\(row.address.hexAddress)"', native_sibling)
        self.assertIn("press: { _ = select() }", native_sibling)
        self.assertIn(".allowsHitTesting(false)", native_sibling)
        self.assertNotIn(".accessibilityLabel(", row[visual_start:outer_frame])
        self.assertIn("setAccessibilityElement(false)", native_host)
        self.assertIn(
            "let instructionAccessibilityElement = DisassemblyRowAccessibilityElement()",
            native_host,
        )
        self.assertIn(
            "setAccessibilityChildren([instructionAccessibilityElement])",
            native_host,
        )
        for forbidden_host_setter in (
            "setAccessibilityRole(",
            "setAccessibilityLabel(",
            "setAccessibilityValue(",
            "setAccessibilityIdentifier(",
        ):
            self.assertNotIn(forbidden_host_setter, native_host)
        self.assertIn("setAccessibilityRole(.staticText)", native_element)
        self.assertIn("setAccessibilityElement(true)", native_element)
        self.assertIn("setAccessibilityValue(label)", native_element)
        self.assertIn("setAccessibilityChildren([])", native_element)
        self.assertIn("override func accessibilityChildren() -> [Any]?", native_element)
        self.assertIn("override func accessibilityPerformPress() -> Bool", native_element)
        self.assertIn("override func hitTest(_ point: NSPoint) -> NSView?", native_host)
        self.assertNotIn(
            ".accessibilityElement(children: .contain)",
            row,
            "the row must expose its breakpoint button and explicit listing leaf without "
            "wrapping them in an implicit-label accessibility container",
        )


if __name__ == "__main__":
    unittest.main()
