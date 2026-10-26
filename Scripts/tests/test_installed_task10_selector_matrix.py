#!/usr/bin/env python3

from __future__ import annotations

import json
from pathlib import Path
import re
import unittest

from Scripts.reconstruction import installed_matrix_receipt as matrix_receipt


ROOT = Path(__file__).resolve().parents[2]
VECTOR_SELECTION = (
    ROOT
    / "docs"
    / "qualification"
    / "reconstruction"
    / "RECON-R1-T10C"
    / "VECTOR_SELECTION.json"
)
INSTALLED_SELECTORS = VECTOR_SELECTION.with_name("INSTALLED_SELECTORS.md")
UI_TESTS = (
    ROOT
    / "MacScope"
    / "Tests"
    / "MacScopeInstalledAppUITests"
    / "WS24InstalledAppUITests.swift"
)
HARNESS = UI_TESTS.with_name("InstalledAppUITestHarness.swift")
SOURCE_REVEAL_BARRIER = (
    ROOT
    / "MacScope"
    / "Services"
    / "Reconstruction"
    / "ReconstructionInstalledSourceRevealQualificationBarrier.swift"
)
WORKSPACE_ROOT = (
    ROOT / "MacScope" / "Features" / "Workspace" / "WorkspaceRootView.swift"
)
NAVIGATION_STORE = (
    ROOT / "MacScope" / "Stores" / "WorkspaceStore+ReconstructionNavigation.swift"
)
SIDEBAR = ROOT / "MacScope" / "Features" / "Sidebar" / "SidebarView.swift"
WORKSPACE_STORE = ROOT / "MacScope" / "Stores" / "WorkspaceStore.swift"
PAUSE_COORDINATOR = (
    ROOT / "MacScope" / "Services" / "Reconstruction" / "ReconstructionJobCoordinator.swift"
)
PROJECT = ROOT / "MacScope" / "project.yml"
TEST_DECLARATION = re.compile(
    r"^\s*func\s+(testTask10C[A-Za-z0-9_]+)\s*\([^)]*\)[^{]*\{",
    re.MULTILINE,
)


def expected_scenarios() -> list[str]:
    value = json.loads(VECTOR_SELECTION.read_text(encoding="utf-8"))
    vectors = value["installedVectorIDs"]
    if value["selectedInstalledVectorCount"] != 22 or len(vectors) != 22:
        raise AssertionError("the canonical installed selector catalog must contain exactly 22 rows")
    prefix = "xcui."
    if any(not vector.startswith(prefix) for vector in vectors):
        raise AssertionError("an installed vector is outside the canonical xcui namespace")
    scenarios = [vector[len(prefix):] for vector in vectors]
    if scenarios != sorted(scenarios) or len(set(scenarios)) != len(scenarios):
        raise AssertionError("the installed selector scenarios must be sorted and unique")
    return scenarios


def method_name(scenario: str) -> str:
    return "testTask10C" + scenario[0].upper() + scenario[1:]


def method_bodies(source: str) -> dict[str, str]:
    bodies: dict[str, str] = {}
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
        if match.group(1) in bodies:
            raise AssertionError(f"duplicate Swift test method: {match.group(1)}")
        bodies[match.group(1)] = source[match.end():cursor - 1]
    return bodies


class InstalledTask10SelectorMatrixTests(unittest.TestCase):
    def test_swift_target_implements_the_exact_canonical_22_selector_set(self) -> None:
        source = UI_TESTS.read_text(encoding="utf-8")
        scenarios = expected_scenarios()
        expected = {method_name(scenario) for scenario in scenarios}
        observed = set(method_bodies(source))
        self.assertEqual(len(observed), 22)
        self.assertEqual(
            observed,
            expected,
            "WS24InstalledAppUITests must implement every canonical Task 10 C selector exactly once",
        )

    def test_each_selector_routes_through_the_guarded_scenario_executor_without_skips(self) -> None:
        source = UI_TESTS.read_text(encoding="utf-8")
        bodies = method_bodies(source)
        for scenario in expected_scenarios():
            name = method_name(scenario)
            body = bodies[name]
            self.assertIn(
                f"try runTask10CScenario(.{scenario})",
                body,
                f"{name} must bind exactly one catalog scenario to the shared installed executor",
            )
            self.assertNotIn("XCTSkip", body, f"{name} must never downgrade execution to a skip")

        self.assertIn(
            "InstalledAppUITestHarness.requireOptedInCandidate()",
            source,
            "the shared selector executor must preserve the existing explicit installed-app guard",
        )
        self.assertNotIn(
            "MACSCOPE_TASK10_RUN_INSTALLED",
            source,
            "the Task 10 matrix must not add a second opt-in path",
        )

    def test_selector_document_and_vector_catalog_remain_in_exact_parity(self) -> None:
        document = INSTALLED_SELECTORS.read_text(encoding="utf-8")
        rows = re.findall(r"^\| `xcui\.([A-Za-z0-9]+)` \| ([A-Za-z0-9]+) \|", document, re.MULTILINE)
        scenarios = expected_scenarios()
        self.assertEqual([vector for vector, _scenario in rows], scenarios)
        self.assertEqual([scenario for _vector, scenario in rows], scenarios)

    def test_pause_barrier_launch_environment_is_bounded_and_installed_before_launch(self) -> None:
        source = HARNESS.read_text(encoding="utf-8")
        launch_start = source.index("    func launch(\n")
        validation_start = source.index(
            "    private static func validatedLaunchEnvironment(\n",
            launch_start,
        )
        launch_body = source[launch_start:validation_start]
        self.assertIn("launchEnvironment: [String: String] = [:]", launch_body)
        self.assertIn(
            '"MACSCOPE_WS24_RECONSTRUCTION_PAUSE_BARRIER_ROOT"',
            source,
        )
        self.assertIn(
            '"MACSCOPE_WS24_RECONSTRUCTION_PAUSE_CANDIDATE_SHA256"',
            source,
        )
        self.assertIn("approvedLaunchEnvironmentKeys.contains(key)", source)
        self.assertIn('key.hasPrefix("MACSCOPE_")', source)
        self.assertIn('!value.contains("\\0")', source)
        self.assertIn('!value.contains("\\n")', source)
        self.assertIn('!value.contains("\\r")', source)
        self.assertIn('"MacScope-Task10-PauseBarrier-"', source)
        self.assertIn('"MacScope-Task10-RevealBarrier-"', source)
        self.assertIn('parent == "/private/tmp" || parent == runnerTemporaryDirectory?.path', source)
        self.assertIn("getpwuid_r(getuid()", source)
        self.assertIn("observed.path == expected.path", source)
        self.assertIn("O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW", source)
        self.assertIn("AT_SYMLINK_NOFOLLOW", source)
        self.assertIn("before.st_uid == getuid()", source)
        self.assertIn("before.st_mode & 0o7777 == 0o700", source)
        self.assertIn("opened.st_dev == before.st_dev, opened.st_ino == before.st_ino", source)
        self.assertIn("Darwin.mkdirat(parent, $0, mode_t(0o700))", source)
        self.assertIn("UUID(uuidString: String(name.dropFirst(prefix.count))) != nil", source)
        ui_source = UI_TESTS.read_text(encoding="utf-8")
        self.assertIn("O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW", ui_source)
        self.assertNotIn(
            "FileManager.default.createFile(\n            atPath: releaseURL.path",
            ui_source,
            "the release handshake must be create-only and refuse pre-existing paths",
        )
        validation_call = launch_body.index(
            "for (key, value) in try Self.validatedLaunchEnvironment(launchEnvironment)"
        )
        launch_call = launch_body.index("        app.launch()")
        self.assertLess(
            validation_call,
            launch_call,
            "pause barrier environment must be validated and installed before process launch",
        )

    def test_stale_after_render_reveal_barrier_is_private_candidate_bound_and_fail_closed(self) -> None:
        barrier = SOURCE_REVEAL_BARRIER.read_text(encoding="utf-8")
        workspace = WORKSPACE_ROOT.read_text(encoding="utf-8")
        store = NAVIGATION_STORE.read_text(encoding="utf-8")
        harness = HARNESS.read_text(encoding="utf-8")
        source = UI_TESTS.read_text(encoding="utf-8")

        self.assertNotIn("#if DEBUG", barrier)
        self.assertNotIn("public ", barrier)
        self.assertIn('"MACSCOPE_WS24_RUN_INSTALLED_XCUITEST"', barrier)
        self.assertIn('"MACSCOPE_WS24_RECONSTRUCTION_REVEAL_BARRIER_ROOT"', barrier)
        self.assertIn(
            '"MACSCOPE_WS24_RECONSTRUCTION_REVEAL_CANDIDATE_SHA256"',
            barrier,
        )
        self.assertIn("observedCandidateSHA256 == expectedCandidateSHA256", barrier)
        self.assertIn("O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW", barrier)
        self.assertIn("metadata.st_nlink == 1", barrier)
        self.assertIn("metadata.st_size == 0", barrier)
        self.assertIn('"analysisFingerprintSHA256"', barrier)
        for prohibited_receipt_field in ("prompt", "pseudocode", "path"):
            receipt_start = barrier.index("        let receipt: [String: Any] = [")
            receipt_end = barrier.index("        ]", receipt_start)
            self.assertNotIn(prohibited_receipt_field, barrier[receipt_start:receipt_end].lower())

        self.assertIn("approvedLaunchEnvironmentKeys.contains(key)", harness)
        self.assertIn("reconstructionRevealBarrierRootEnvironmentKey", harness)
        self.assertIn("reconstructionRevealCandidateSHA256EnvironmentKey", harness)
        launch_start = harness.index("    func launch(\n")
        launch_end = harness.index("    private static func validatedLaunchEnvironment", launch_start)
        launch_body = harness[launch_start:launch_end]
        self.assertLess(
            launch_body.index("Self.validatedLaunchEnvironment(launchEnvironment)"),
            launch_body.index("app.launch()"),
        )

        reveal_start = workspace.index(
            "    private func revealReconstructionEvidenceSource(_ evidenceID: UUID) {"
        )
        reveal_end = workspace.index("\n    /// Re-resolves source authority", reveal_start)
        reveal_body = workspace[reveal_start:reveal_end]
        self.assertLess(
            reveal_body.index("waitIfRequested("),
            reveal_body.index("retireReconstructionSourceAuthorityForInstalledQualification("),
        )
        released_start = reveal_body.index("case .released:")
        refused_start = reveal_body.index("case .refused:", released_start)
        released = reveal_body[released_start:refused_start]
        self.assertIn("retireReconstructionSourceAuthorityForInstalledQualification(", released)
        self.assertIn("reconstructionSourceNavigationRefusal(", released)
        self.assertLess(
            released.index("retireReconstructionSourceAuthorityForInstalledQualification("),
            released.index("reconstructionSourceNavigationRefusal("),
        )
        self.assertIn("currentRequest: {", reveal_body)
        self.assertIn("snapshot: store.snapshot", reveal_body)
        self.assertIn("return", reveal_body[reveal_body.index("case .refused:"):])

        self.assertNotIn("#if DEBUG", store)
        self.assertIn("var retiredSnapshot = priorSnapshot", store)
        self.assertIn("retiredAnalysis.functions.removeAll", store)
        self.assertIn("snapshot = retiredSnapshot", store)
        self.assertIn("defer { snapshot = priorSnapshot }", store)
        self.assertIn("isDirty == priorDirtyState", store)
        self.assertLess(
            store.index("snapshot = retiredSnapshot"),
            store.index("defer { snapshot = priorSnapshot }"),
        )
        self.assertIn("return authorityWasRetired && presentationWasPreserved", store)

        stale_start = source.index("    func exerciseStaleSourceReveal(")
        stale_end = source.index("\n    func exerciseSaveReopen(", stale_start)
        stale = source[stale_start:stale_end]
        self.assertIn("let retainedReveal", stale)
        self.assertIn("try barrier.waitForArrival(expectedEvidenceID: evidenceID)", stale)
        self.assertIn("try barrier.release()", stale)
        self.assertIn('containing: "Source reveal refused"', stale)
        self.assertIn("try packageTreeSHA256(at: fixture.packageURL)", stale)
        self.assertIn("try exerciseDestinationSwitch(fixture: fixture, app: app)", stale)

        current_start = source.index("    func exerciseCurrentSourceReveal(")
        current_end = source.index("\n    func expectedFunctionID(", current_start)
        current = source[current_start:current_end]
        self.assertIn("let revealedFunction = try requireElement(", current)
        self.assertIn("try requireSelectedAndKeyboardFocused(", current)
        self.assertIn("function:\\(functionID.uuidString)", current)
        self.assertIn(
            "let accessibilityElement = try harness.waitForAccessibilityDescendant(",
            source,
        )
        self.assertIn(
            "element.exists && element.isSelected && accessibilityFocused(accessibilityElement)",
            source,
        )
        self.assertIn("func accessibilityFocused(_ element: AXUIElement) -> Bool", source)
        self.assertIn("AXUIElementCopyAttributeValue(", source)
        self.assertIn("kAXFocusedAttribute as CFString", source)
        self.assertIn(") == .success else {\n            return false", source)
        self.assertIn("return (value as? NSNumber)?.boolValue == true", source)
        self.assertNotIn(".hasKeyboardFocus", source)

        sidebar = SIDEBAR.read_text(encoding="utf-8")
        workspace_store = WORKSPACE_STORE.read_text(encoding="utf-8")
        self.assertIn("sidebarKeyboardFocusRequestID", sidebar)
        self.assertIn("keyboardFocusRequestID: store.sidebarKeyboardFocusRequestID", sidebar)
        self.assertIn(".onAppear { acceptKeyboardFocusRequest(keyboardFocusRequestID) }", sidebar)
        self.assertIn(".onChange(of: keyboardFocusRequestID)", sidebar)
        self.assertIn("isFocused = true", sidebar)
        self.assertIn("acknowledgeKeyboardFocusRequest(item.id)", sidebar)
        self.assertIn("guard requestID == item.id, isSelected else { return }", sidebar)
        self.assertIn("@Published private(set) var sidebarKeyboardFocusRequestID", workspace_store)
        self.assertIn("func requestSidebarKeyboardFocus(for itemID: SidebarItem.ID)", workspace_store)
        self.assertIn("func acknowledgeSidebarKeyboardFocusRequest(for itemID: SidebarItem.ID)", workspace_store)
        self.assertIn("requestSidebarKeyboardFocus(for: functionSidebarItemID)", store)

    def test_qualification_retirement_is_scoped_before_dirty_save_and_autosave_reopen(self) -> None:
        tests = (ROOT / "MacScope/Tests/CoreTests/WorkspaceStoreReconstructionNavigationTests.swift").read_text(
            encoding="utf-8"
        )
        start = tests.index(
            "    func testInstalledQualificationRetirementRestoresBeforeDirtySaveAutosaveAndReopen()"
        )
        end = tests.index("\n    }\n}", start) + len("\n    }")
        proof = tests[start:end]
        for fragment in (
            "store.setCustomName",
            "store.retireReconstructionSourceAuthorityForInstalledQualification(request)",
            "store.writeDocumentPackage(to: seed.packageURL)",
            "WorkspaceStore.restoredPackage(from: seed.packageURL)",
            "autosave.firePending()",
            "assertFunctionAuthority(functionID, request: request, survivesIn: afterExplicitSave)",
            "assertFunctionAuthority(functionID, request: request, survivesIn: afterAutosave)",
            "Mutation RED: remove `defer { snapshot = priorSnapshot }`",
        ):
            self.assertIn(fragment, proof)

    def test_installed_qualification_barriers_compile_into_release_without_debug(self) -> None:
        project = PROJECT.read_text(encoding="utf-8")
        pause = PAUSE_COORDINATOR.read_text(encoding="utf-8")
        reveal = SOURCE_REVEAL_BARRIER.read_text(encoding="utf-8")
        workspace = WORKSPACE_ROOT.read_text(encoding="utf-8")
        store = NAVIGATION_STORE.read_text(encoding="utf-8")

        release_start = project.index("    Release:\n", project.index("  configs:\n"))
        release_end = project.index("\ntargets:\n", release_start)
        release_configuration = project[release_start:release_end]
        self.assertNotIn("DEBUG", release_configuration)

        register_start = pause.index("    private func registerControl(")
        register_end = pause.index("\n    private func run(", register_start)
        register_control = pause[register_start:register_end]
        barrier_start = pause.index("enum ReconstructionInstalledPauseQualificationBarrier")
        barrier_end = pause.index(
            "\nstruct ReconstructionDatabaseJobPersistence:", barrier_start
        )
        pause_barrier = pause[barrier_start:barrier_end]
        reveal_start = workspace.index(
            "    private func revealReconstructionEvidenceSource(_ evidenceID: UUID) {"
        )
        reveal_end = workspace.index("\n    /// Re-resolves source authority", reveal_start)
        reveal_dispatch = workspace[reveal_start:reveal_end]
        mutation_start = store.index(
            "    func retireReconstructionSourceAuthorityForInstalledQualification("
        )
        mutation_end = store.index("\n    }", mutation_start) + len("\n    }")
        source_mutation = store[mutation_start:mutation_end]

        for name, production_surface in (
            ("pause registration", register_control),
            ("pause barrier", pause_barrier),
            ("source reveal barrier", reveal),
            ("source reveal dispatch", reveal_dispatch),
            ("source authority mutation", source_mutation),
        ):
            self.assertNotIn(
                "#if DEBUG",
                production_surface,
                f"{name} must be compiled into the signed Release qualification candidate",
            )

        self.assertIn('"MACSCOPE_WS24_RUN_INSTALLED_XCUITEST"', pause_barrier)
        self.assertIn(
            '"MACSCOPE_WS24_RECONSTRUCTION_PAUSE_CANDIDATE_SHA256"',
            pause_barrier,
        )
        self.assertIn("observedCandidateSHA256 == expectedCandidateSHA256", pause_barrier)
        self.assertIn('"MACSCOPE_WS24_RUN_INSTALLED_XCUITEST"', reveal)
        self.assertIn("observedCandidateSHA256 == expectedCandidateSHA256", reveal)

    def test_installed_accessibility_and_privacy_contracts_are_exact_and_fixture_bound(self) -> None:
        source = UI_TESTS.read_text(encoding="utf-8")
        for identifier in (
            'identifier: "reconstruction.corpusSummary"',
            'identifier: "reconstruction.currentGap"',
            'identifier: "reconstruction.evidenceSummary"',
        ):
            self.assertIn(identifier, source)
        for fixture_field in (
            "expectedCorpusOccurrenceCount",
            "expectedCorpusUniqueContentCount",
            "expectedCorpusRelationCount",
            "expectedCorpusUnresolvedRelationCount",
            "expectedEvidenceCurrentCount",
            "expectedEvidenceHistoricalCount",
            "expectedEvidenceStaleCount",
            "expectedEvidenceUnavailableCount",
            "expectedCurrentGapOperationID",
            "expectedFunctionAddress",
            "expectedFocusedImageName",
            "expectedEditorMode",
            "forbiddenRawPathCanary",
            "forbiddenRawPromptCanary",
            "forbiddenRawPseudocodeCanary",
        ):
            self.assertIn(f"fixture.{fixture_field}", source)
        self.assertIn('identified: "reconstruction.primaryAction"', source)
        self.assertGreaterEqual(
            source.count('identified: "reconstruction.primaryAction"'),
            2,
        )
        self.assertIn('identified: "reconstruction.inspector"', source)
        self.assertIn("boundedAccessibilityAttributeStrings", source)
        self.assertIn("let canaries = try [", source)
        self.assertIn("packageContainsUTF8Canary", source)

    def test_privacy_scan_refuses_truncated_ax_traversal(self) -> None:
        harness = HARNESS.read_text(encoding="utf-8")
        source = UI_TESTS.read_text(encoding="utf-8")

        self.assertIn("struct BoundedAccessibilityAttributeStrings", harness)
        self.assertIn("let wasTruncated: Bool", harness)
        self.assertIn("let wasIncomplete: Bool", harness)
        self.assertIn(") -> BoundedAccessibilityAttributeStrings", harness)
        self.assertIn("wasTruncated: &wasTruncated", harness)
        self.assertIn("wasIncomplete: &wasIncomplete", harness)
        self.assertIn("remainingElements: &remainingElements", harness)
        self.assertIn("guard remainingElements > 0 else {", harness)
        self.assertIn("remainingElements -= 1", harness)
        self.assertIn("case .attributeUnsupported, .noValue:", harness)
        self.assertIn("default:\n            wasIncomplete = true", harness)
        self.assertIn("guard strings.count < limit else {\n            wasTruncated = true", harness)
        self.assertIn("if strings.count == limit {\n                wasTruncated = true", harness)
        self.assertIn("guard depth > 0 else {", harness)
        self.assertIn("if !children.isEmpty {\n                wasTruncated = true", harness)
        self.assertIn("guard !wasTruncated, !wasIncomplete else { return }", harness)

        privacy_start = source.index("    func exercisePrivacy(")
        privacy_end = source.index("\n    func exerciseResumeExactTarget(", privacy_start)
        privacy = source[privacy_start:privacy_end]
        self.assertIn("let boundedStrings = harness.boundedAccessibilityAttributeStrings(", privacy)
        self.assertIn(
            "guard !boundedStrings.wasTruncated, !boundedStrings.wasIncomplete else {",
            privacy,
        )
        self.assertIn("refusing to treat a partial scan as absence proof", privacy)
        self.assertIn("surfacedStrings.append(contentsOf: boundedStrings.strings)", privacy)

    def test_save_open_workspace_requires_the_real_ax_edit_completion_fence(self) -> None:
        harness = HARNESS.read_text(encoding="utf-8")
        source = UI_TESTS.read_text(encoding="utf-8")
        save_start = harness.index("    func saveOpenWorkspace() throws {")
        save_end = harness.index("\n    /// Provides the lifecycle sequence", save_start)
        save = harness[save_start:save_end]

        self.assertIn("let application = AXUIElementCreateApplication(runningApplication.processIdentifier)", save)
        self.assertIn("let documentWindow = try Self.accessibilityElement(", save)
        self.assertIn("kAXFocusedWindowAttribute as CFString", save)
        self.assertIn("guard try Task10DocumentEditedReader.read(", save)
        self.assertIn("window: documentWindow, expectedPID: runningApplication.processIdentifier", save)
        self.assertIn("refusing to claim that Save persisted a new workspace state", save)
        self.assertIn('titled: "Save"', save)
        self.assertLess(
            save.index("guard try Task10DocumentEditedReader.read("),
            save.index('titled: "Save"'),
            "the focused document must be observed dirty before the real File ▸ Save command",
        )
        self.assertIn("let deadline = Date().addingTimeInterval(10)", save)
        self.assertIn("if try !Task10DocumentEditedReader.read(", save)
        self.assertIn("RunLoop.current.run(until: Date().addingTimeInterval(0.1))", save)
        self.assertIn("refusing to terminate before production save completion", save)
        self.assertNotIn("Thread.sleep", save)

        lifecycle_start = harness.index("    func terminateExactCandidateGracefully(")
        lifecycle_end = harness.index("\n    /// Drives the shipping File", lifecycle_start)
        lifecycle = harness[lifecycle_start:lifecycle_end]
        self.assertIn("guard runningApplication.terminate() else {", lifecycle)
        self.assertIn("Self.waitForTermination(", lifecycle)
        self.assertNotIn("forceTerminate", lifecycle)

        reopen_start = harness.index("    func terminateRelaunchAndOpenWorkspace(")
        reopen_end = harness.index("\n    func accessibilityApplication", reopen_start)
        reopen = harness[reopen_start:reopen_end]
        self.assertIn("try terminateExactCandidateGracefully()", reopen)
        self.assertNotIn("terminateExactCandidateIfRunning", reopen)

        edited_reader = UI_TESTS.with_name("Task10CreationHistoryVerifier.swift").read_text(encoding="utf-8")
        self.assertIn("kAXCloseButtonAttribute as CFString", edited_reader)
        self.assertIn("attribute(close, kAXEditedAttribute as CFString)", edited_reader)
        self.assertIn("CFGetTypeID(value) == CFBooleanGetTypeID()", edited_reader)

        scenario_start = source.index("    func exerciseSaveReopen(")
        scenario_end = source.index("\n    func exerciseStaleCheckpoint(", scenario_start)
        scenario = source[scenario_start:scenario_end]
        self.assertIn("let expectedPackage = try Task10SavedPackageObservation.capture(", scenario)
        self.assertIn("verifyContents: verifySavedPause", scenario)
        self.assertIn("publication.before.rootIdentity.inode", scenario)
        self.assertIn("publication.after.rootIdentity.inode", scenario)
        self.assertIn("publication.after.documentID", scenario)
        self.assertIn("publication.after.workspaceID", scenario)
        self.assertLess(
            scenario.index("let expectedPackage = try Task10SavedPackageObservation.capture("),
            scenario.index("try exercisePauseFromActive(app: originalApp)"),
        )
        self.assertLess(
            scenario.index("try harness.saveOpenWorkspacePackage("),
            scenario.index("try verifySavedPause(publication.after)"),
        )
        self.assertLess(
            scenario.index("try verifySavedPause(publication.after)"),
            scenario.index("try harness.terminateRelaunchAndOpenWorkspace("),
        )

    def test_control_and_menu_retain_cancel_while_keyboard_never_claims_escape_cancel(self) -> None:
        source = UI_TESTS.read_text(encoding="utf-8")
        start = source.index("    func exerciseKeyboardAndMenuEquivalence(\n")
        end = source.index("\n    func exercisePauseFromActive(", start)
        body = source[start:end]
        self.assertIn("for route in Task10CCommandRoute.allCases", body)
        self.assertIn('catalog.copyScenario("no-job")', body)
        self.assertIn("try preference.clearForIsolatedLaunch()", body)
        self.assertLess(
            body.index("try createJobWithoutExecutableProvider(in: app)"),
            body.index("InstalledDeterministicLocalAIProvider.start("),
            "each route must create a durable ready job before provider readiness can auto-start it",
        )
        self.assertIn('identified: "reconstruction.primaryAction"', body)
        self.assertIn(
            'referenceNonterminalOutcomes,\n            ["retrieving", "paused", "retrieving"]',
            body,
        )
        for command in ("Start", "Pause", "Resume"):
            self.assertIn(f'("{command}", "', body)
        self.assertIn(
            'commands = commandsWithGlobalShortcuts + [("Cancel", "cancelled")]',
            body,
        )
        self.assertIn('case .control, .menu:', body)
        self.assertIn('case .keyboard:', body)
        self.assertIn("control.click()", body)
        self.assertIn("routedItem.click()", body)
        self.assertIn("app.typeKey(.return, modifierFlags: .command)", body)
        self.assertIn('app.typeKey("p", modifierFlags: [.command, .option])', body)
        self.assertIn('app.typeKey("r", modifierFlags: [.command, .option])', body)
        keyboard_dispatch = body[body.index("        case .keyboard:", body.index(
            "    func dispatchReconstructionCommand("
        )):]
        self.assertNotIn("app.typeKey(.escape, modifierFlags: [])", keyboard_dispatch)
        self.assertIn(
            "Cancel intentionally has no global keyboard shortcut",
            keyboard_dispatch,
        )

    def test_shared_executor_dispatches_every_catalog_scenario_without_failure_placeholders(self) -> None:
        source = UI_TESTS.read_text(encoding="utf-8")
        start = source.index(
            "    private func runTask10CScenario(_ scenario: Task10CScenario) throws {"
        )
        end = source.index("\n    }\n}\n\n@MainActor\nprivate extension", start)
        executor = source[start:end]
        for scenario in expected_scenarios():
            self.assertIn(
                f"case .{scenario}:",
                executor,
                f"shared installed executor does not dispatch {scenario}",
            )
        self.assertNotIn("XCTSkip", executor)
        self.assertNotIn("requires an installed pause-command barrier", executor)
        self.assertIn(
            "try exercisePendingPauseNotCommitted(\n"
            "                barrier: try XCTUnwrap(pauseBarrier),",
            executor,
        )
        empty_entry = executor.index(
            'NSPredicate(format: "value BEGINSWITH %@", "No binary open")'
        )
        fixture_open = executor.index("try harness.openWorkspacePackage(fixture.packageURL, in: app)")
        self.assertLess(
            empty_entry,
            fixture_open,
            "the installed matrix must prove its empty-workspace launch before opening a fixture",
        )

    def test_governed_full_window_screenshot_matrix_is_physically_attached(self) -> None:
        source = UI_TESTS.read_text(encoding="utf-8")
        harness = HARNESS.read_text(encoding="utf-8")
        self.assertIn(
            "if scenario == .taskEvidenceCountsAccessible {\n"
            "            // Freeze the selector-bound AX observation before the independent 28-capture\n"
            "            // presentation matrix resolves additional state-specific accessibility surfaces.\n"
            "            try attachTask10AccessibilityObservation()\n"
            "            activeTask10AccessibilityObservation = nil\n"
            "            try captureGovernedPresentationMatrix(",
            source,
        )
        self.assertIn(
            "let appearances: [InstalledAppUITestHarness.Appearance] = [.light, .dark]",
            source,
        )
        self.assertIn(
            "let sizes: [InstalledAppUITestHarness.WindowSize] = [.minimum, .wide]",
            source,
        )
        self.assertEqual(len(matrix_receipt.PRESENTATION_STATES), 7)
        for state_id, fixture_id in matrix_receipt.PRESENTATION_STATES:
            self.assertIn(f'"{state_id}"', source)
            self.assertIn(f'"{fixture_id}"', source)
        self.assertIn(
            "for presentationState in Task10CPresentationState.allCases",
            source,
        )
        self.assertIn("for appearance in appearances", source)
        self.assertIn("for size in sizes", source)
        self.assertIn(
            '+ "-" + presentationState.rawValue,',
            source,
            "the physical attachment name must bind the exact presentation state",
        )
        self.assertIn("try harness.setFocusedWindowSize(size)", source)
        self.assertIn("let screenshot = try harness.windowScreenshotAttachment(", source)
        self.assertIn("add(screenshot)", source)
        self.assertIn("case .createdActiveExecution:", source)
        self.assertIn("try requireCreatedActiveExecution(", source)
        self.assertIn("case .reopenResume:", source)
        self.assertIn("return (try exerciseSaveReopen(", source)
        self.assertIn("attachment.lifetime = .keepAlways", harness)
        self.assertIn(
            '"\\(identity.sourceCommit)-\\(identity.executableSHA256)"',
            harness,
            "attachment identity must bind scenario, appearance, size, source, and executable",
        )
        self.assertIn("try Self.assertEffectiveAppearance(appearance, in: screenshot)", harness)
        self.assertIn("medianLuminance >= 0.55", harness)
        self.assertIn("medianLuminance <= 0.45", harness)

    def test_workspace_open_waits_for_go_to_folder_before_pressing_open(self) -> None:
        harness = HARNESS.read_text(encoding="utf-8")
        start = harness.index(
            "    func openWorkspacePackage(_ packageURL: URL, in app: XCUIApplication) throws {"
        )
        end = harness.index("\n    }\n\n    /// Uses the production File", start)
        open_workspace = harness[start:end]
        path_return = open_workspace.index("pathField.typeKey(.return, modifierFlags: [])")
        sheet_closed = open_workspace.index("goToFolderSheet.waitForNonExistence(timeout: 10)")
        open_action = open_workspace.index('let openButton = openPanel.buttons["Open"]')
        self.assertLess(path_return, sheet_closed)
        self.assertLess(
            sheet_closed,
            open_action,
            "the Go to Folder sheet must be gone before resolving the Open panel action",
        )

    def test_ordering_lifecycle_and_stale_navigation_cannot_false_green(self) -> None:
        source = UI_TESTS.read_text(encoding="utf-8")
        self.assertIn(
            'if executionVisible && !identityCommitted {',
            source,
            "a single sample containing identity and progress cannot prove commit-before-progress",
        )
        self.assertIn(
            'if identityCommitted && executionVisible {',
            source,
            "creation must observe committed identity and actual automated execution",
        )
        self.assertIn("Task10CreationHistoryVerifier.verify(", source)
        self.assertIn("let publication = try harness.saveOpenWorkspacePackage(", source)
        self.assertIn("let proof = try verifySavedCreation(publication.after)", source)
        self.assertRegex(
            source,
            r'case \.saveReopenProjectsBeforeResume:\s*"active-retrieving"',
        )
        save_start = source.index("    func exerciseSaveReopen(")
        save_end = source.index("\n    func exerciseStaleCheckpoint(", save_start)
        save_body = source[save_start:save_end]
        self.assertLess(
            save_body.index("try exercisePauseFromActive(app: originalApp)"),
            save_body.index("try harness.saveOpenWorkspacePackage("),
            "save/reopen must create a new paused state before invoking Save",
        )
        self.assertIn("try verifySavedPause(publication.after)", save_body)
        self.assertIn('let resumeTarget = try XCTUnwrap(initial.job["state"] as? String)', save_body)
        self.assertNotIn("fixture.expectedResumeTarget", save_body)
        self.assertIn('attachSaveObservation(observation, name: "rejected-pause-observation")', save_body)
        self.assertIn('attachSaveObservation(finalObservation, name: "final-before-fixture-cleanup")', save_body)
        for diagnostic in ("state=", "pauseContextPresent=", "cause=", "resumeTarget=", "currentCheckpointID="):
            self.assertIn(diagnostic, save_body)
        self.assertIn('pause["resumeTarget"] as? String == resumeTarget', save_body)
        self.assertIn('child["parentCheckpointSHA256"] as? String == parentSHA256', save_body)
        self.assertIn("try harness.terminateRelaunchAndOpenWorkspace(", save_body)
        self.assertNotIn("try harness.saveOpenWorkspace()", save_body)
        stale_start = source.index("    func exerciseStaleSourceReveal(")
        stale_end = source.index("\n    func exerciseSaveReopen(", stale_start)
        stale_body = source[stale_start:stale_end]
        self.assertIn("fixture.expectedNavigableEvidenceID", stale_body)
        self.assertIn("selected != before", stale_body)
        self.assertIn("let retainedReveal", stale_body)
        self.assertIn("try barrier.waitForArrival(expectedEvidenceID: evidenceID)", stale_body)
        self.assertIn("try barrier.release()", stale_body)
        self.assertIn(
            'identified: "reconstruction.terminalNotice"',
            stale_body,
            "stale-after-render refusal must reach the exact bounded notice surface",
        )

        current_start = source.index("    func exerciseCurrentSourceReveal(")
        current_end = source.index("\n    func expectedFunctionID(", current_start)
        current_body = source[current_start:current_end]
        self.assertIn("fixture.expectedStartingImageName", current_body)
        self.assertIn("fixture.expectedStartingFunctionAddress", current_body)
        self.assertIn("XCTAssertNotEqual(startingImageName, fixture.expectedFocusedImageName)", current_body)
        self.assertIn("XCTAssertNotEqual(startingAddress, address)", current_body)
        self.assertIn("let startingContext = try expectedFunctionContext(", current_body)
        self.assertLess(
            current_body.index("startingImage.click()"),
            current_body.index('goToField.typeText(String(format: "0x%llx", startingAddress))'),
        )
        self.assertLess(
            current_body.index('goToField.typeKey(.return, modifierFlags: [])'),
            current_body.index("startingEditor.waitForExistence(timeout: 10)"),
        )
        self.assertIn('"Disassembly, \\(startingImageName), \\(startingContext.name), "', current_body)
        self.assertIn('identified: "disassembly.breakpoint.\\(startingContext.slot)."', current_body)
        self.assertNotIn("startingFunctionID", current_body)
        self.assertNotIn("address + 4", current_body)
        self.assertLess(
            current_body.index("startingEditor.waitForExistence(timeout: 10)"),
            current_body.index("reveal.click()"),
        )
        self.assertNotIn("let hexViewer", current_body)
        self.assertLess(
            current_body.index("startingEditor.waitForExistence(timeout: 10)"),
            current_body.index("hexMode.click()"),
        )
        self.assertLess(
            current_body.index("try requireRadioSelection(hexMode,"),
            current_body.index("reconstruction.click()"),
        )
        self.assertIn('"Disassembly, \\(fixture.expectedFocusedImageName), "', current_body)
        self.assertIn('"Select acceptedCurrent evidence", "structuredJSON"', current_body)
        self.assertIn("for step in 0..<12", current_body)
        self.assertIn("destination.scroll(byDeltaX: 0, deltaY: -300)", current_body)
        self.assertIn("if matches.count > 1 { break }", current_body)
        self.assertIn("let reveal = try visibleDashboardButton(", current_body)
        self.assertIn("XCTAttachment(screenshot: app.screenshot())", current_body)
        self.assertIn("XCTAttachment(string: app.debugDescription)", current_body)
        self.assertIn('"selected instruction \\(renderedAddress),"', current_body)
        self.assertIn('app.radioButtons[fixture.expectedEditorMode]', current_body)
        self.assertIn('try requireRadioSelection(mode,', current_body)
        self.assertIn('try requireRadioSelection(hexMode,', current_body)
        radio_start = source.index("    func requireRadioSelection(")
        radio_end = source.index("\n    func accessibilityFocused(", radio_start)
        radio_body = source[radio_start:radio_end]
        self.assertIn("value as? NSNumber", radio_body)
        self.assertIn("number == NSNumber(value: 1)", radio_body)
        self.assertIn('(value as? String) == "1"', radio_body)
        self.assertIn("guard selected else", radio_body)
        self.assertIn("fixture.expectedEditorMode", current_body)
        self.assertIn("fixture.expectedFocusedImageName", current_body)
        self.assertIn('identified: "function:\\(functionID.uuidString)"', current_body)

    def test_current_source_reveal_rejects_the_old_same_image_address_canary(self) -> None:
        """A schema-3 cross-image proof must not degrade to the old `address + 4` same-image move."""
        source = UI_TESTS.read_text(encoding="utf-8")
        current_start = source.index("    func exerciseCurrentSourceReveal(")
        current_end = source.index("\n    func expectedFunctionID(", current_start)
        current_body = source[current_start:current_end]
        for fragment in (
            "fixture.expectedStartingImageName",
            "fixture.expectedStartingFunctionAddress",
            "XCTAssertNotEqual(startingImageName, fixture.expectedFocusedImageName)",
            "XCTAssertNotEqual(startingAddress, address)",
            "let startingContext = try expectedFunctionContext(",
            'identified: "disassembly.breakpoint.\\(startingContext.slot)."',
            "startingEditor.waitForExistence(timeout: 10)",
        ):
            self.assertIn(fragment, current_body)
        self.assertNotRegex(
            current_body,
            r"(?:distinctStartingAddress|startingAddress)\s*=\s*address\s*\+\s*\d+",
            "the historical same-image address arithmetic must not satisfy schema-3 transfer proof",
        )


if __name__ == "__main__":
    unittest.main()
