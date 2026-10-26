import AppKit
import ApplicationServices
import CryptoKit
import CoreFoundation
import Darwin
import XCTest

final class WS24InstalledAppUITests: XCTestCase {
    private var activeTask10AccessibilityObservation: Task10CAccessibilityObservation?

    @MainActor
    func testInstalledSharedPreferenceDomainRoundTrip() throws {
        continueAfterFailure = false
        _ = try InstalledAppUITestHarness.requireOptedInCandidate()
        guard let nonce = ProcessInfo.processInfo.environment[
            "MACSCOPE_WS24_PREFERENCES_PROBE_NONCE"
        ], UUID(uuidString: nonce) != nil else {
            throw XCTSkip("The isolated preference probe requires a host-seeded UUID nonce.")
        }
        let appDomainBefore = UserDefaults.standard.persistentDomain(forName: "org.macscope.app") as NSDictionary?
        let (suiteName, defaults) = try Task10CAppPreferenceDomain.makeIsolatedSuite()
        addTeardownBlock { @MainActor in
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
            let appDomainAfter = UserDefaults.standard.persistentDomain(forName: "org.macscope.app") as NSDictionary?
            XCTAssertEqual(appDomainAfter, appDomainBefore, "The isolated round-trip must not change the app domain.")
        }
        let key = "phase2.localAI.installedTestDomainProbe.v1"
        defaults.set(nonce, forKey: key)
        defaults.removeObject(forKey: key)
        XCTAssertNil(defaults.object(forKey: key))
        defaults.set(nonce, forKey: key)
        XCTAssertEqual(defaults.object(forKey: key) as? String, nonce)
    }

    @MainActor
    func testTask10CCancelFromActive() throws {
        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        harness.terminateExactCandidateIfRunning()
        try runTask10CScenario(.cancelFromActive)
    }

    @MainActor
    func testOptInInstalledAppLaunchesAndExposesDebuggerDeck() throws {
        continueAfterFailure = false
        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        harness.terminateExactCandidateIfRunning()
        defer { harness.terminateExactCandidateIfRunning() }

        let app = try harness.launch()

        XCTAssertTrue(
            app.windows.element(boundBy: 0).waitForExistence(timeout: 15),
            "Installed MacScope.app did not expose a main window."
        )
        let emptyWorkspaceTitle = app.staticTexts.matching(
            NSPredicate(format: "value BEGINSWITH %@", "No binary open")
        ).firstMatch
        XCTAssertTrue(
            emptyWorkspaceTitle.waitForExistence(timeout: 10),
            "The installed app did not reach the empty-workspace entry point."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["debugger.deck"].waitForExistence(timeout: 10),
            "The installed app did not expose the debugger deck entry point."
        )
        let compactDebuggerStatus = app.staticTexts.matching(
            NSPredicate(format: "value == %@", "Not attached")
        ).firstMatch
        XCTAssertTrue(
            compactDebuggerStatus.waitForExistence(timeout: 10),
            "The installed app did not expose the compact debugger status deck."
        )
    }

    /// Installed product proof for the multi-member archive boundary. This must use the shipping
    /// menu, file importer, picker, and worker-backed analysis path; no test-only store injection.
    @MainActor
    func testOptInInstalledAppRequiresExplicitELFArchiveMemberSelection() throws {
        continueAfterFailure = false
        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        let fixture = try InstalledELFArchiveFixture.create()
        defer { fixture.remove() }
        harness.terminateExactCandidateIfRunning()
        defer { harness.terminateExactCandidateIfRunning() }

        let app = try harness.launch()
        try harness.openBinary(fixture.archiveURL, in: app)

        let picker = app.descendants(matching: .any)["loader.options.sheet"]
        XCTAssertTrue(
            picker.waitForExistence(timeout: 15),
            "The installed app did not present the archive member picker."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["loader.archive.members"].waitForExistence(timeout: 10),
            "The archive picker did not expose its bounded member list."
        )
        let memberRows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "loader.archive.member.")
        )
        let firstMember = memberRows["loader.archive.member.0"]
        let selectedMember = memberRows["loader.archive.member.1"]
        XCTAssertTrue(firstMember.waitForExistence(timeout: 10))
        XCTAssertTrue(selectedMember.waitForExistence(timeout: 10))
        XCTAssertEqual(memberRows.count, 2, "The archive picker must expose exactly two members.")
        XCTAssertEqual(
            firstMember.value as? String,
            "\(InstalledELFArchiveFixture.firstMemberName), archive member 0"
        )
        XCTAssertEqual(
            selectedMember.value as? String,
            "\(InstalledELFArchiveFixture.selectedMemberName), archive member 1"
        )
        XCTAssertTrue(app.buttons["loader.options.cancel"].waitForExistence(timeout: 10))
        let openButton = app.buttons["loader.options.open"]
        XCTAssertTrue(openButton.waitForExistence(timeout: 10))
        XCTAssertFalse(
            openButton.isEnabled,
            "A multi-member archive must not fabricate an initial member selection."
        )

        selectedMember.click()
        let enabledExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: openButton
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enabledExpectation], timeout: 10), .completed)
        openButton.click()

        let selectedBinary = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "\(InstalledELFArchiveFixture.selectedMemberName), ")
        ).firstMatch
        XCTAssertTrue(
            selectedBinary.waitForExistence(timeout: 30),
            "The installed app did not load the explicitly selected second archive member."
        )
        let unselectedBinary = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "\(InstalledELFArchiveFixture.firstMemberName), ")
        ).firstMatch
        XCTAssertFalse(
            unselectedBinary.exists,
            "The installed app loaded the unselected first archive member."
        )

        // Do not request a synthetic accessibility snapshot of the virtualized disassembly.
        // Xcode 27 recursively resolves SwiftUI labels for that query and terminates the app.
        // The standard GUI contract is proven by the explicit picker interaction above and by
        // the selected image remaining visible and operable after the editor transition.
        XCTAssertEqual(app.state, .runningForeground)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Selected ELF archive member loaded"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testBundledTask10PersistedWorkspaceFixtureHasRecordedIntegrity() throws {
        let fixture = try Task10InstalledWorkspaceFixture.copyIntoTemporaryDirectory()
        defer { fixture.remove() }

        XCTAssertEqual(fixture.workspaceName, "Task 10 persisted workspace")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.packageURL.path),
            "The copied Task 10 fixture package is missing."
        )
    }

    @MainActor
    func testOptInInstalledAppAttachSheetReachabilityAndDiagnostics() throws {
        continueAfterFailure = false
        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        harness.terminateExactCandidateIfRunning()
        defer { harness.terminateExactCandidateIfRunning() }

        let app = try harness.launch()

        let attachButton = app.buttons["debugger.attachLocalProcess"]
        XCTAssertTrue(
            attachButton.waitForExistence(timeout: 15),
            "The installed app did not expose the local process attach affordance."
        )
        attachButton.click()

        let attachSheet = app.descendants(matching: .any)["localProcessAttach.sheet"]
        XCTAssertTrue(
            attachSheet.waitForExistence(timeout: 15),
            "The local process attach sheet was not reachable from the installed app."
        )
        let processSearch = app.textFields.matching(
            NSPredicate(format: "label == %@", "Search local processes")
        ).firstMatch
        XCTAssertTrue(
            processSearch.waitForExistence(timeout: 10),
            "The attach sheet did not expose process search."
        )
        XCTAssertTrue(
            app.buttons["Refresh"].waitForExistence(timeout: 10),
            "The attach sheet did not expose process-refresh diagnostics."
        )
        XCTAssertTrue(
            app.buttons["Attach"].waitForExistence(timeout: 10),
            "The attach sheet did not expose the final attach action."
        )
    }

    /// Task 10's installed-app proof deliberately writes a real workspace through the
    /// production persistence seam, then selects it through File ▸ Open Workspace. It must
    /// not bypass the open coordinator with a launch argument or a test-only store injection.
    @MainActor
    func testOptInInstalledAppOpensPersistedWorkspaceAndReachesReconstruction() throws {
        continueAfterFailure = false
        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        let fixture = try Task10InstalledWorkspaceFixture.copyIntoTemporaryDirectory()
        defer { fixture.remove() }
        harness.terminateExactCandidateIfRunning()
        defer { harness.terminateExactCandidateIfRunning() }

        let app = try harness.launch()
        try harness.openWorkspacePackage(fixture.packageURL, in: app)

        let runningApp = try harness.requireRunningCandidate(
            timeout: 10,
            context: "the completed File ▸ Open Workspace command"
        )
        let accessibilityApplication = AXUIElementCreateApplication(runningApp.processIdentifier)
        _ = try harness.waitForFocusedWindow(
            titled: fixture.packageURL.deletingPathExtension().lastPathComponent,
            timeout: 15,
            context: "the package title restored by File ▸ Open Workspace"
        )
        let reconstructionNavigation = try harness.waitForAccessibilityDescendant(
            identified: "reconstruction.navigation",
            of: accessibilityApplication,
            depth: 8,
            timeout: 10,
            context: "Reconstruction navigation"
        )
        try harness.accessibilityPress(
            reconstructionNavigation,
            context: "Reconstruction navigation"
        )
        let dashboard = try harness.waitForAccessibilityDescendant(
            identified: "reconstruction.destination",
            of: accessibilityApplication,
            depth: 10,
            timeout: 15,
            context: "the persisted workspace's Reconstruction destination"
        )
        let emptyJobIdentity = try harness.waitForAccessibilityDescendant(
            identified: "reconstruction.job.identity",
            of: dashboard,
            depth: 8,
            timeout: 10,
            context: "the bounded empty Reconstruction state"
        )
        let emptyStateText = [
            harness.accessibilityTitle(of: emptyJobIdentity),
            harness.accessibilityString(
                attribute: kAXDescriptionAttribute as CFString,
                of: emptyJobIdentity
            ),
            harness.accessibilityString(
                attribute: kAXValueAttribute as CFString,
                of: emptyJobIdentity
            ),
        ].compactMap { $0 }
        XCTAssertTrue(
            emptyStateText.contains { $0.contains("No reconstruction job") },
            "The persisted workspace did not render the bounded empty Reconstruction state; "
                + "AX text was \(emptyStateText)."
        )
    }
}

private enum Task10CScenario: String, CaseIterable {
    case cancelFromActive
    case corpusCountsAccessible
    case createCommitsBeforeAutoStart
    case createRejectsEmptySelection
    case createRejectsWhitespaceObjective
    case currentGapAccessible
    case destinationSwitchRestoresEditorAuthority
    case destinationVisibleWhenEndpointMissing
    case destinationVisibleWhenReady
    case keyboardAndMenuEquivalence
    case pauseFromActive
    case pausedModelUnavailableIsResumable
    case pendingPauseNotCommitted
    case privacyNoRawPathPromptPseudocode
    case resumeExactTarget
    case revealSourceCurrentAuthority
    case revealSourceStaleAuthorityNoMutation
    case saveReopenProjectsBeforeResume
    case staleCheckpointDisablesCommands
    case taskEvidenceCountsAccessible
    case terminalControlsDisabled
    case twoWindowsKeepIndependentSelection

    var requiredAccessibilityIdentifiers: Set<String> {
        switch self {
        case .cancelFromActive:
            ["reconstruction.cancel"]
        case .corpusCountsAccessible:
            ["reconstruction.corpusSummary"]
        case .createCommitsBeforeAutoStart:
            ["reconstruction.job.state", "reconstruction.progress"]
        case .createRejectsEmptySelection, .createRejectsWhitespaceObjective:
            ["reconstruction.primaryAction"]
        case .currentGapAccessible:
            ["reconstruction.currentGap"]
        case .destinationSwitchRestoresEditorAuthority:
            ["reconstruction.destination"]
        case .destinationVisibleWhenEndpointMissing:
            ["reconstruction.destination", "reconstruction.terminalNotice"]
        case .destinationVisibleWhenReady:
            ["reconstruction.destination", "reconstruction.dashboard"]
        case .keyboardAndMenuEquivalence:
            [
                "reconstruction.primaryAction",
                "reconstruction.pause",
                "reconstruction.resume",
                "reconstruction.cancel",
            ]
        case .pauseFromActive:
            ["reconstruction.pause"]
        case .pausedModelUnavailableIsResumable:
            ["reconstruction.job.state", "reconstruction.resume"]
        case .pendingPauseNotCommitted:
            ["reconstruction.terminalNotice", "reconstruction.job.state"]
        case .privacyNoRawPathPromptPseudocode:
            [
                "reconstruction.dashboard",
                "reconstruction.terminalNotice",
                "reconstruction.inspector",
            ]
        case .resumeExactTarget:
            ["reconstruction.resume"]
        case .revealSourceCurrentAuthority:
            ["reconstruction.details"]
        case .revealSourceStaleAuthorityNoMutation:
            ["reconstruction.details", "reconstruction.terminalNotice"]
        case .saveReopenProjectsBeforeResume:
            ["reconstruction.dashboard", "reconstruction.job.state"]
        case .staleCheckpointDisablesCommands:
            ["reconstruction.terminalNotice", "reconstruction.primaryAction"]
        case .taskEvidenceCountsAccessible:
            ["reconstruction.taskSummary", "reconstruction.evidenceSummary"]
        case .terminalControlsDisabled:
            [
                "reconstruction.primaryAction",
                "reconstruction.pause",
                "reconstruction.resume",
                "reconstruction.cancel",
            ]
        case .twoWindowsKeepIndependentSelection:
            ["reconstruction.details", "reconstruction.inspector"]
        }
    }

    var testIdentifier: String {
        let suffix = rawValue.prefix(1).uppercased() + String(rawValue.dropFirst())
        return "WS24InstalledAppUITests/testTask10C\(suffix)()"
    }

    var fixtureScenarioID: String {
        switch self {
        case .cancelFromActive:
            "active-executing-reads"
        case .createCommitsBeforeAutoStart,
             .createRejectsEmptySelection,
             .createRejectsWhitespaceObjective,
             .destinationVisibleWhenEndpointMissing,
             .destinationVisibleWhenReady,
             .keyboardAndMenuEquivalence:
            "no-job"
        case .destinationSwitchRestoresEditorAuthority:
            // This single-image fixture has the exact persisted editor selection
            // asserted after leaving Reconstruction; no-job has no address oracle.
            "navigation-stale"
        case .pauseFromActive, .pendingPauseNotCommitted:
            "active-retrieving"
        case .pausedModelUnavailableIsResumable:
            "paused-model-unavailable-awaiting-model"
        case .resumeExactTarget:
            "paused-user-retrieving"
        case .saveReopenProjectsBeforeResume:
            "active-retrieving"
        case .terminalControlsDisabled:
            "terminal-completed"
        case .corpusCountsAccessible,
             .currentGapAccessible,
             .privacyNoRawPathPromptPseudocode,
             .revealSourceCurrentAuthority,
             .taskEvidenceCountsAccessible,
             .twoWindowsKeepIndependentSelection:
            "navigation-current"
        case .revealSourceStaleAuthorityNoMutation:
            "navigation-current"
        case .staleCheckpointDisablesCommands:
            "checkpoint-stale"
        }
    }

    var requiresReadyProvider: Bool {
        switch self {
        case .cancelFromActive, .createCommitsBeforeAutoStart, .destinationVisibleWhenReady,
             .pauseFromActive, .pendingPauseNotCommitted, .resumeExactTarget,
             .saveReopenProjectsBeforeResume:
            true
        default:
            false
        }
    }

    var holdsChatRoute: Bool {
        switch self {
        case .cancelFromActive, .createCommitsBeforeAutoStart, .pauseFromActive,
             .pendingPauseNotCommitted, .resumeExactTarget,
             .saveReopenProjectsBeforeResume:
            true
        default:
            false
        }
    }
}

/// Mirrors the current receipt-owned seven-variant presentation catalog, not seven distinct
/// durable phases. Every required screenshot retains its exact origin, label and fixture.
private enum Task10CPresentationState: String, CaseIterable {
    case empty
    case createdActiveExecution = "created-active-execution"
    case awaitingModelPaused = "awaiting-model-paused"
    case activeModelRound = "active-model-round"
    case partialFailure = "partial-failure"
    case completed
    case reopenResume = "reopen-resume"

    var fixtureScenarioID: String {
        switch self {
        case .empty, .createdActiveExecution:
            "no-job"
        case .awaitingModelPaused:
            "paused-model-unavailable-awaiting-model"
        case .activeModelRound:
            "active-executing-reads"
        case .partialFailure:
            "navigation-current"
        case .completed:
            "terminal-completed"
        case .reopenResume:
            "active-retrieving"
        }
    }

    var requiresReadyProvider: Bool {
        switch self {
        case .createdActiveExecution, .activeModelRound, .reopenResume:
            true
        case .empty, .awaitingModelPaused, .partialFailure, .completed:
            false
        }
    }
}

private struct Task10CAccessibilityObservation {
    let scenario: Task10CScenario
    var observedIdentifiers: Set<String> = []
}

private struct Task10CAccessibilityObservationAttachment: Encodable {
    let schemaVersion = 1
    let vectorID: String
    let testIdentifier: String
    let observedIdentifiers: [String]
}

private struct Task10CAccessibilityContract {
    let label: String
    let value: String
    let help: String
}

private enum Task10CCommandRoute: String, CaseIterable {
    case control
    case menu
    case keyboard
}

@MainActor
private final class Task10CCleanup {
    private let operation: @MainActor () throws -> Void
    private var completed = false

    init(operation: @escaping @MainActor () throws -> Void) {
        self.operation = operation
    }

    func perform() throws {
        guard !completed else { return }
        try operation()
        completed = true
    }
}

@MainActor
private extension XCTestCase {
    /// XCTest interruption can bypass Swift defers. Retain an independent teardown
    /// owner, while allowing loop-scoped cleanup to complete this token immediately.
    func registerTask10Cleanup(
        _ operation: @escaping @MainActor () throws -> Void
    ) -> Task10CCleanup {
        let cleanup = Task10CCleanup(operation: operation)
        addTeardownBlock { @MainActor in
            // Existing cleanup assertions must remain recorded, but cannot interrupt
            // cleanup of the remaining resources or the final preference fence.
            self.continueAfterFailure = true
            try cleanup.perform()
        }
        return cleanup
    }
}

@MainActor
private enum Task10CAppPreferenceDomain {
    static func makeIsolatedSuite() throws -> (String, UserDefaults) {
        let name = "org.macscope.app.tests." + UUID().uuidString
        return (name, try XCTUnwrap(UserDefaults(suiteName: name)))
    }
}

@MainActor
private struct Task10CProviderPreferenceSnapshot {
    private static let key = "phase2.localAI.providerPreference.v1"

    private let harness: InstalledAppUITestHarness
    private let appPreferenceBefore: NSDictionary

    static func capture(harness: InstalledAppUITestHarness) throws -> Self {
        let appPreference = UserDefaults.standard.persistentDomain(forName: "org.macscope.app")?[key]
        let fingerprint: NSDictionary = appPreference.map { [key: $0] as NSDictionary } ?? [:]
        return Self(harness: harness, appPreferenceBefore: fingerprint)
    }

    func restore() throws {
        // Remove only test-owned suites. App-side container remnants are never reused.
        harness.removeIsolatedProviderPreferences()
        let appPreference = UserDefaults.standard.persistentDomain(forName: "org.macscope.app")?[Self.key]
        let fingerprint: NSDictionary = appPreference.map { [Self.key: $0] as NSDictionary } ?? [:]
        XCTAssertEqual(fingerprint, appPreferenceBefore, "The isolated provider suite must not change the app preference.")
    }

    func clearForIsolatedLaunch() throws {
        // Do not assume that deleting a runner-domain value reaches the app container.
        harness.beginIsolatedProviderPreferenceScope()
    }
}

@MainActor
private struct Task10CPauseBarrier {
    static let rootEnvironmentKey = "MACSCOPE_WS24_RECONSTRUCTION_PAUSE_BARRIER_ROOT"
    static let candidateSHA256EnvironmentKey =
        "MACSCOPE_WS24_RECONSTRUCTION_PAUSE_CANDIDATE_SHA256"
    private static let arrivalName = "pause-control-arrived.json"
    private static let releaseName = "pause-control-release"

    let rootURL: URL
    let candidateSHA256: String

    static func create(candidateSHA256: String) throws -> Self {
        let rootURL = try InstalledAppUITestHarness.createQualificationBarrierRoot(
            prefix: "MacScope-Task10-PauseBarrier-"
        )
        return Self(rootURL: rootURL, candidateSHA256: candidateSHA256)
    }

    var launchEnvironment: [String: String] {
        [
            Self.rootEnvironmentKey: rootURL.path,
            Self.candidateSHA256EnvironmentKey: candidateSHA256,
        ]
    }

    func waitForArrival(timeout: TimeInterval = 10) throws {
        let arrivalURL = rootURL.appendingPathComponent(Self.arrivalName)
        guard waitUntil(timeout: timeout, predicate: {
            FileManager.default.fileExists(atPath: arrivalURL.path)
        }) else {
            throw task10CFailure("The pause command did not reach its owned coordinator barrier.")
        }
        let values = try arrivalURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: arrivalURL.path)
        let data = try Data(contentsOf: arrivalURL, options: .mappedIfSafe)
        let object = try? JSONSerialization.jsonObject(with: data)
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              attributes[.ownerAccountID] as? NSNumber == NSNumber(value: getuid()),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              (1...4_096).contains(data.count),
              let receipt = object as? [String: Any],
              receipt["candidateSHA256"] as? String == candidateSHA256 else {
            throw task10CFailure("The pause barrier arrival receipt failed its ownership contract.")
        }
    }

    func release() throws {
        let releaseURL = rootURL.appendingPathComponent(Self.releaseName)
        let descriptor = open(
            releaseURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw task10CFailure("The pause barrier release file was not created exactly once.")
        }
        guard close(descriptor) == 0 else {
            throw task10CFailure("The pause barrier release file could not be closed safely.")
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

@MainActor
private struct Task10CSourceRevealBarrier {
    static let rootEnvironmentKey =
        "MACSCOPE_WS24_RECONSTRUCTION_REVEAL_BARRIER_ROOT"
    static let candidateSHA256EnvironmentKey =
        "MACSCOPE_WS24_RECONSTRUCTION_REVEAL_CANDIDATE_SHA256"
    private static let arrivalName = "source-reveal-action-rendered.json"
    private static let releaseName = "source-reveal-invalidate-release"

    let rootURL: URL
    let candidateSHA256: String

    static func create(candidateSHA256: String) throws -> Self {
        let rootURL = try InstalledAppUITestHarness.createQualificationBarrierRoot(
            prefix: "MacScope-Task10-RevealBarrier-"
        )
        return Self(rootURL: rootURL, candidateSHA256: candidateSHA256)
    }

    var launchEnvironment: [String: String] {
        [
            Self.rootEnvironmentKey: rootURL.path,
            Self.candidateSHA256EnvironmentKey: candidateSHA256,
        ]
    }

    func waitForArrival(
        expectedEvidenceID: UUID,
        timeout: TimeInterval = 10
    ) throws {
        let arrivalURL = rootURL.appendingPathComponent(Self.arrivalName)
        guard waitUntil(timeout: timeout, predicate: {
            FileManager.default.fileExists(atPath: arrivalURL.path)
        }) else {
            throw task10CFailure(
                "Reveal Source did not reach its candidate-bound post-render barrier."
            )
        }
        let values = try arrivalURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: arrivalURL.path)
        let data = try Data(contentsOf: arrivalURL, options: .mappedIfSafe)
        let receipt = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "Reveal Source barrier receipt was not a JSON object."
        )
        XCTAssertEqual(receipt["kind"] as? String, "source-reveal-action-rendered")
        XCTAssertEqual(receipt["candidateSHA256"] as? String, candidateSHA256)
        XCTAssertEqual(
            receipt["evidenceID"] as? String,
            expectedEvidenceID.uuidString.lowercased()
        )
        XCTAssertNotNil(
            (receipt["workspaceID"] as? String).flatMap(UUID.init(uuidString:)),
            "Reveal Source readiness did not bind a workspace identifier."
        )
        let allowedKeys = Set([
            "analysisFingerprintSHA256", "binaryID", "candidateSHA256", "evidenceID",
            "imageSlot", "kind", "projectID", "workspaceID",
        ])
        XCTAssertEqual(
            Set(receipt.keys),
            allowedKeys,
            "Reveal Source readiness must disclose identifiers and hashes only."
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              attributes[.ownerAccountID] as? NSNumber == NSNumber(value: getuid()),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              (1...4_096).contains(data.count) else {
            throw task10CFailure(
                "Reveal Source arrival receipt failed its ownership and byte-bound contract."
            )
        }
    }

    func release() throws {
        let releaseURL = rootURL.appendingPathComponent(Self.releaseName)
        let descriptor = open(
            releaseURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw task10CFailure(
                "Reveal Source barrier release file was not created exactly once."
            )
        }
        guard close(descriptor) == 0 else {
            throw task10CFailure("Reveal Source barrier release could not be closed safely.")
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

extension WS24InstalledAppUITests {
    @MainActor
    func testTask10CCorpusCountsAccessible() throws {
        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        harness.terminateExactCandidateIfRunning()
        try runTask10CScenario(.corpusCountsAccessible)
    }

    @MainActor
    func testTask10CCreateCommitsBeforeAutoStart() throws {
        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        harness.terminateExactCandidateIfRunning()
        try runTask10CScenario(.createCommitsBeforeAutoStart)
    }

    @MainActor
    func testTask10CCreateRejectsEmptySelection() throws {
        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        harness.terminateExactCandidateIfRunning()
        try runTask10CScenario(.createRejectsEmptySelection)
    }

    @MainActor
    func testTask10CCreateRejectsWhitespaceObjective() throws {
        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        harness.terminateExactCandidateIfRunning()
        try runTask10CScenario(.createRejectsWhitespaceObjective)
    }

    @MainActor
    func testTask10CCurrentGapAccessible() throws {
        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        harness.terminateExactCandidateIfRunning()
        try runTask10CScenario(.currentGapAccessible)
    }

    @MainActor
    func testTask10CDestinationSwitchRestoresEditorAuthority() throws {
        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        harness.terminateExactCandidateIfRunning()
        try runTask10CScenario(.destinationSwitchRestoresEditorAuthority)
    }

    @MainActor
    func testTask10CDestinationVisibleWhenEndpointMissing() throws {
        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        harness.terminateExactCandidateIfRunning()
        try runTask10CScenario(.destinationVisibleWhenEndpointMissing)
    }

    @MainActor
    func testTask10CDestinationVisibleWhenReady() throws {
        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        harness.terminateExactCandidateIfRunning()
        try runTask10CScenario(.destinationVisibleWhenReady)
    }

    @MainActor
    func testTask10CKeyboardAndMenuEquivalence() throws {
        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        harness.terminateExactCandidateIfRunning()
        try runTask10CScenario(.keyboardAndMenuEquivalence)
    }

    @MainActor
    func testTask10CPauseFromActive() throws {
        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        harness.terminateExactCandidateIfRunning()
        try runTask10CScenario(.pauseFromActive)
    }

    @MainActor
    func testTask10CPausedModelUnavailableIsResumable() throws {
        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        harness.terminateExactCandidateIfRunning()
        try runTask10CScenario(.pausedModelUnavailableIsResumable)
    }

    @MainActor
    func testTask10CPendingPauseNotCommitted() throws {
        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        harness.terminateExactCandidateIfRunning()
        try runTask10CScenario(.pendingPauseNotCommitted)
    }

    @MainActor
    func testTask10CPrivacyNoRawPathPromptPseudocode() throws {
        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        harness.terminateExactCandidateIfRunning()
        try runTask10CScenario(.privacyNoRawPathPromptPseudocode)
    }

    @MainActor
    func testTask10CResumeExactTarget() throws {
        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        harness.terminateExactCandidateIfRunning()
        try runTask10CScenario(.resumeExactTarget)
    }

    @MainActor
    func testTask10CRevealSourceCurrentAuthority() throws {
        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        harness.terminateExactCandidateIfRunning()
        try runTask10CScenario(.revealSourceCurrentAuthority)
    }

    @MainActor
    func testTask10CRevealSourceStaleAuthorityNoMutation() throws {
        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        harness.terminateExactCandidateIfRunning()
        try runTask10CScenario(.revealSourceStaleAuthorityNoMutation)
    }

    @MainActor
    func testTask10CSaveReopenProjectsBeforeResume() throws {
        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        harness.terminateExactCandidateIfRunning()
        try runTask10CScenario(.saveReopenProjectsBeforeResume)
    }

    @MainActor
    func testTask10CStaleCheckpointDisablesCommands() throws {
        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        harness.terminateExactCandidateIfRunning()
        try runTask10CScenario(.staleCheckpointDisablesCommands)
    }

    @MainActor
    func testTask10CTaskEvidenceCountsAccessible() throws {
        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        harness.terminateExactCandidateIfRunning()
        try runTask10CScenario(.taskEvidenceCountsAccessible)
    }

    @MainActor
    func testTask10CTerminalControlsDisabled() throws {
        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        harness.terminateExactCandidateIfRunning()
        try runTask10CScenario(.terminalControlsDisabled)
    }

    @MainActor
    func testTask10CTwoWindowsKeepIndependentSelection() throws {
        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        harness.terminateExactCandidateIfRunning()
        try runTask10CScenario(.twoWindowsKeepIndependentSelection)
    }

    @MainActor
    private func runTask10CScenario(_ scenario: Task10CScenario) throws {
        continueAfterFailure = false
        activeTask10AccessibilityObservation = Task10CAccessibilityObservation(
            scenario: scenario
        )
        _ = registerTask10Cleanup { self.activeTask10AccessibilityObservation = nil }

        let harness = try InstalledAppUITestHarness.requireOptedInCandidate()
        let preference = try Task10CProviderPreferenceSnapshot.capture(harness: harness)
        _ = registerTask10Cleanup { try preference.restore() }
        try preference.clearForIsolatedLaunch()

        let catalog = try Task10InstalledScenarioFixtureCatalog.load()
        if scenario == .keyboardAndMenuEquivalence {
            try exerciseKeyboardAndMenuEquivalence(
                harness: harness,
                catalog: catalog,
                preference: preference
            )
            try attachTask10AccessibilityObservation()
            return
        }
        let fixture = try catalog.copyScenario(scenario.fixtureScenarioID)
        let fixtureCleanup = registerTask10Cleanup { fixture.remove() }
        defer { try? fixtureCleanup.perform() }

        let pauseBarrier = scenario == .pendingPauseNotCommitted
            ? try Task10CPauseBarrier.create(
                candidateSHA256: harness.identity.executableSHA256
              )
            : nil
        let pauseBarrierCleanup = registerTask10Cleanup { pauseBarrier?.remove() }
        defer { try? pauseBarrierCleanup.perform() }
        let sourceRevealBarrier = scenario == .revealSourceStaleAuthorityNoMutation
            ? try Task10CSourceRevealBarrier.create(
                candidateSHA256: harness.identity.executableSHA256
              )
            : nil
        let sourceRevealBarrierCleanup = registerTask10Cleanup { sourceRevealBarrier?.remove() }
        defer { try? sourceRevealBarrierCleanup.perform() }

        let provider = scenario.requiresReadyProvider
            ? try InstalledDeterministicLocalAIProvider.start(oracle: catalog.provider)
            : nil
        let providerCleanup = registerTask10Cleanup { provider?.stopExactOwnedProcessIfNeeded() }
        defer { try? providerCleanup.perform() }
        if scenario.holdsChatRoute {
            try provider?.hold(.chat)
        }

        let candidateCleanup = registerTask10Cleanup { harness.terminateExactCandidateIfRunning() }
        defer { try? candidateCleanup.perform() }
        harness.terminateExactCandidateIfRunning()
        var launchEnvironment = pauseBarrier?.launchEnvironment ?? [:]
        if let sourceRevealBarrier {
            launchEnvironment.merge(
                sourceRevealBarrier.launchEnvironment,
                uniquingKeysWith: { _, qualified in qualified }
            )
        }
        let app = try harness.launch(launchEnvironment: launchEnvironment)
        let emptyWorkspaceTitle = app.staticTexts.matching(
            NSPredicate(format: "value BEGINSWITH %@", "No binary open")
        ).firstMatch
        XCTAssertTrue(
            emptyWorkspaceTitle.waitForExistence(timeout: 10),
            "The installed Task 10 matrix did not begin at the empty-workspace entry point."
        )
        if let provider {
            try configureInstalledProvider(
                provider,
                oracle: catalog.provider,
                harness: harness,
                in: app
            )
        }
        try harness.openWorkspacePackage(fixture.packageURL, in: app)
        let dashboard = try openReconstructionDashboard(
            harness: harness,
            fixture: fixture,
            app: app
        )

        switch scenario {
        case .cancelFromActive:
            try exerciseCancelFromActive(app: app, dashboard: dashboard)
        case .corpusCountsAccessible:
            try exerciseCorpusCounts(harness: harness, fixture: fixture, app: app)
        case .createCommitsBeforeAutoStart:
            guard let provider else { throw task10CFailure("Create requires its owned ready provider.") }
            try exerciseCreationCommit(harness: harness, fixture: fixture, provider: provider, app: app)
        case .createRejectsEmptySelection:
            try exerciseInvalidCreation(app: app, whitespaceObjective: false)
        case .createRejectsWhitespaceObjective:
            try exerciseInvalidCreation(app: app, whitespaceObjective: true)
        case .currentGapAccessible:
            try exerciseCurrentGap(harness: harness, fixture: fixture, app: app)
        case .destinationSwitchRestoresEditorAuthority:
            try exerciseDestinationSwitch(fixture: fixture, app: app)
        case .destinationVisibleWhenEndpointMissing:
            try exerciseEndpointMissing(app: app, dashboard: dashboard)
        case .destinationVisibleWhenReady:
            try exerciseDestinationReady(app: app, dashboard: dashboard)
        case .keyboardAndMenuEquivalence:
            preconditionFailure("Command-route parity owns its own fresh package launches.")
        case .pauseFromActive:
            try exercisePauseFromActive(app: app)
        case .pausedModelUnavailableIsResumable:
            try exercisePausedModelUnavailable(
                harness: harness,
                fixture: fixture,
                app: app
            )
        case .pendingPauseNotCommitted:
            try exercisePendingPauseNotCommitted(
                barrier: try XCTUnwrap(pauseBarrier),
                app: app
            )
        case .privacyNoRawPathPromptPseudocode:
            try exercisePrivacy(harness: harness, fixture: fixture, app: app)
        case .resumeExactTarget:
            try exerciseResumeExactTarget(fixture: fixture, app: app)
        case .revealSourceCurrentAuthority:
            try exerciseCurrentSourceReveal(harness: harness, fixture: fixture, app: app)
        case .revealSourceStaleAuthorityNoMutation:
            try exerciseStaleSourceReveal(
                barrier: try XCTUnwrap(sourceRevealBarrier),
                fixture: fixture,
                app: app
            )
        case .saveReopenProjectsBeforeResume:
            _ = try exerciseSaveReopen(
                harness: harness,
                fixture: fixture,
                originalApp: app
            )
        case .staleCheckpointDisablesCommands:
            try exerciseStaleCheckpoint(fixture: fixture, app: app)
        case .taskEvidenceCountsAccessible:
            try exerciseTaskEvidenceCounts(harness: harness, fixture: fixture, app: app)
        case .terminalControlsDisabled:
            try exerciseTerminalControls(app: app)
        case .twoWindowsKeepIndependentSelection:
            try exerciseTwoWindowSelection(
                harness: harness,
                catalog: catalog,
                firstFixture: fixture,
                app: app
            )
        }

        if scenario == .taskEvidenceCountsAccessible {
            // Freeze the selector-bound AX observation before the independent 28-capture
            // presentation matrix resolves additional state-specific accessibility surfaces.
            try attachTask10AccessibilityObservation()
            activeTask10AccessibilityObservation = nil
            try captureGovernedPresentationMatrix(
                harness: harness,
                catalog: catalog
            )
        } else {
            try attachTask10AccessibilityObservation()
        }
    }
}

@MainActor
private extension WS24InstalledAppUITests {
    func captureGovernedPresentationMatrix(
        harness: InstalledAppUITestHarness,
        catalog: Task10InstalledScenarioFixtureCatalog
    ) throws {
        let appearances: [InstalledAppUITestHarness.Appearance] = [.light, .dark]
        let sizes: [InstalledAppUITestHarness.WindowSize] = [.minimum, .wide]

        for presentationState in Task10CPresentationState.allCases {
            for appearance in appearances {
                try captureGovernedPresentationState(
                    presentationState,
                    harness: harness,
                    catalog: catalog,
                    appearance: appearance,
                    sizes: sizes
                )
            }
        }
    }

    func captureGovernedPresentationState(
        _ presentationState: Task10CPresentationState,
        harness: InstalledAppUITestHarness,
        catalog: Task10InstalledScenarioFixtureCatalog,
        appearance: InstalledAppUITestHarness.Appearance,
        sizes: [InstalledAppUITestHarness.WindowSize]
    ) throws {
        let fixture = try catalog.copyScenario(presentationState.fixtureScenarioID)
        let fixtureCleanup = registerTask10Cleanup { fixture.remove() }
        defer { try? fixtureCleanup.perform() }
        let provider = presentationState.requiresReadyProvider
            ? try InstalledDeterministicLocalAIProvider.start(oracle: catalog.provider)
            : nil
        let providerCleanup = registerTask10Cleanup { provider?.stopExactOwnedProcessIfNeeded() }
        defer { try? providerCleanup.perform() }
        if presentationState.requiresReadyProvider {
            try provider?.hold(.chat)
        }

        let candidateCleanup = registerTask10Cleanup { harness.terminateExactCandidateIfRunning() }
        defer { try? candidateCleanup.perform() }
        harness.terminateExactCandidateIfRunning()
        var app = try harness.launch(appearance: appearance)
        if let provider {
            try configureInstalledProvider(
                provider,
                oracle: catalog.provider,
                harness: harness,
                in: app
            )
        }
        try harness.openWorkspacePackage(fixture.packageURL, in: app)
        _ = try openReconstructionDashboard(
            harness: harness,
            fixture: fixture,
            app: app
        )
        let prepared = try prepareGovernedPresentationState(
            presentationState,
            harness: harness,
            fixture: fixture,
            app: app,
            appearance: appearance,
            provider: provider
        )
        app = prepared.app

        for size in sizes {
            try harness.setFocusedWindowSize(size)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            if presentationState == .createdActiveExecution {
                try requireCreatedActiveExecution(
                    app: app, jobID: try XCTUnwrap(prepared.createdJobID),
                    provider: try XCTUnwrap(provider)
                )
            } else if presentationState == .activeModelRound {
                try requireRestoredActiveModelRound(
                    app: app, jobID: try XCTUnwrap(fixture.expectedJobID),
                    provider: try XCTUnwrap(provider)
                )
            }
            let screenshot = try harness.windowScreenshotAttachment(
                from: app,
                scenario: Task10CScenario.taskEvidenceCountsAccessible.rawValue
                    + "-" + presentationState.rawValue,
                appearance: appearance,
                size: size
            )
            if presentationState == .createdActiveExecution {
                try requireCreatedActiveExecution(
                    app: app, jobID: try XCTUnwrap(prepared.createdJobID),
                    provider: try XCTUnwrap(provider)
                )
            } else if presentationState == .activeModelRound {
                try requireRestoredActiveModelRound(
                    app: app, jobID: try XCTUnwrap(fixture.expectedJobID),
                    provider: try XCTUnwrap(provider)
                )
            }
            // Attach only after both observations accept the actual captured job/phase. This
            // brackets the image; it does not claim AX queries and pixels form one atomic frame.
            add(screenshot)
        }
    }

    func prepareGovernedPresentationState(
        _ presentationState: Task10CPresentationState,
        harness: InstalledAppUITestHarness,
        fixture: Task10InstalledScenarioFixtureCatalog.Fixture,
        app: XCUIApplication,
        appearance: InstalledAppUITestHarness.Appearance,
        provider: InstalledDeterministicLocalAIProvider?
    ) throws -> (app: XCUIApplication, createdJobID: UUID?) {
        var createdJobID: UUID?
        switch presentationState {
        case .empty:
            let identity = try requireElement(
                identified: "reconstruction.job.identity",
                in: app,
                timeout: 5,
                context: "the frozen empty presentation state"
            )
            try requireText(
                identity,
                containing: "No reconstruction job",
                timeout: 5,
                context: "empty"
            )
        case .createdActiveExecution:
            // Observe genuine newly-created execution at the existing held model response.
            // The same shipping Save/history oracle binds the exact UUID; no early-phase hold
            // or delay is introduced to manufacture ingestion/indexing visual coverage.
            createdJobID = try exerciseCreationCommit(
                harness: harness, fixture: fixture,
                provider: try XCTUnwrap(provider), app: app
            )
            try requireCreatedActiveExecution(
                app: app, jobID: try XCTUnwrap(createdJobID),
                provider: try XCTUnwrap(provider)
            )
        case .awaitingModelPaused:
            try exercisePausedModelUnavailable(
                harness: harness,
                fixture: fixture,
                app: app
            )
        case .activeModelRound:
            let expectedJobID = try XCTUnwrap(fixture.expectedJobID)
            let jobRow = try requireElement(
                identified: "reconstruction:job:\(expectedJobID.uuidString)",
                in: app, timeout: 5, context: "the exact restored active-model job"
            )
            jobRow.click()
            let state = try requireElement(
                identified: "reconstruction.job.state",
                in: app,
                timeout: 5,
                context: "the frozen active-model-round presentation state"
            )
            guard waitUntil(timeout: 5, predicate: {
                (state.value as? String) == "executingReads"
            }) else {
                throw task10CFailure("Restored active-model capture did not expose executingReads.")
            }
            _ = try XCTUnwrap(provider).waitForRequest(path: "/v1/chat/completions", timeout: 10)
            try requireRestoredActiveModelRound(
                app: app, jobID: expectedJobID, provider: try XCTUnwrap(provider)
            )
        case .partialFailure:
            guard fixture.expectedEvidenceStaleCount > 0,
                  fixture.expectedEvidenceUnavailableCount > 0 else {
                throw task10CFailure("The partial-failure fixture lacks mixed failed evidence.")
            }
            try exerciseTaskEvidenceCounts(harness: harness, fixture: fixture, app: app)
        case .completed:
            let state = try requireElement(
                identified: "reconstruction.job.state",
                in: app,
                timeout: 5,
                context: "the frozen completed presentation state"
            )
            try requireText(
                state,
                containing: "completed",
                timeout: 5,
                context: "completed"
            )
            try exerciseTerminalControls(app: app)
        case .reopenResume:
            return (try exerciseSaveReopen(
                harness: harness,
                fixture: fixture,
                originalApp: app,
                appearance: appearance
            ), nil)
        }
        return (app, createdJobID)
    }

    func requireCreatedActiveExecution(
        app: XCUIApplication,
        jobID: UUID,
        provider: InstalledDeterministicLocalAIProvider
    ) throws {
        try requireExecutingReadsModelRequest(app: app, provider: provider)
        let identity = app.descendants(matching: .any)["reconstruction.job.identity"]
        guard identity.exists,
              accessibilityText(of: identity).components(separatedBy: " | ").contains("Job 1") else {
            throw task10CFailure("Created-active-execution image lost its newly-created Job 1.")
        }
        let jobRows = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "reconstruction:job:"
        ))
        guard jobRows.count == 1 else {
            throw task10CFailure("Created-active-execution image lost its one exact navigator job.")
        }
        let row = jobRows.element(boundBy: 0)
        guard try Task10CreationHistoryVerifier.selectedNavigatorJobID(
            identifier: row.identifier, label: row.label, isSelected: row.isSelected,
            expectedObjective: "Reconstruct the installed deterministic target",
            visibleCreationOrdinal: 1
        ) == jobID else {
            throw task10CFailure("Created-active-execution image differs from its saved job UUID.")
        }
    }

    func requireRestoredActiveModelRound(
        app: XCUIApplication,
        jobID: UUID,
        provider: InstalledDeterministicLocalAIProvider
    ) throws {
        try requireExecutingReadsModelRequest(app: app, provider: provider)
        let jobRows = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "reconstruction:job:"
        ))
        let row = app.buttons["reconstruction:job:\(jobID.uuidString)"]
        guard jobRows.count == 1, row.exists, row.isSelected else {
            throw task10CFailure("Active-model image lost its exact restored fixture job selection.")
        }
    }

    func requireExecutingReadsModelRequest(
        app: XCUIApplication,
        provider: InstalledDeterministicLocalAIProvider
    ) throws {
        let state = app.descendants(matching: .any)["reconstruction.job.state"]
        let progress = app.descendants(matching: .any)["reconstruction.progress"]
        guard state.exists, (state.value as? String) == "executingReads",
              progress.exists,
              try Task10CreationHistoryVerifier.hasAutomatedProgress(accessibilityText(of: progress)),
              try provider.requestSummary().contains(where: {
                  $0.method == "POST" && $0.path == "/v1/chat/completions" && $0.bodyBytes > 0
              }) else {
            throw task10CFailure(
                "Active execution image lost committed executingReads, genuine progress, "
                    + "or the real model POST."
            )
        }
    }

    func openReconstructionDashboard(
        harness: InstalledAppUITestHarness,
        fixture: Task10InstalledScenarioFixtureCatalog.Fixture,
        app: XCUIApplication
    ) throws -> XCUIElement {
        let runningApp = try harness.requireRunningCandidate(
            timeout: 10,
            context: "the completed Task 10 fixture open"
        )
        let accessibilityApplication = AXUIElementCreateApplication(
            runningApp.processIdentifier
        )
        _ = try harness.waitForFocusedWindow(
            titled: fixture.packageURL.deletingPathExtension().lastPathComponent,
            timeout: 15,
            context: "the Task 10 scenario package"
        )
        let navigation = try harness.waitForAccessibilityDescendant(
            identified: "reconstruction.navigation",
            of: accessibilityApplication,
            depth: 8,
            timeout: 10,
            context: "Task 10 Reconstruction navigation"
        )
        try harness.accessibilityPress(navigation, context: "Task 10 Reconstruction navigation")
        return try requireElement(
            identified: "reconstruction.destination",
            in: app,
            timeout: 15,
            context: "the installed Reconstruction destination"
        )
    }

    func configureInstalledProvider(
        _ provider: InstalledDeterministicLocalAIProvider,
        oracle: Task10InstalledScenarioFixtureCatalog.ProviderOracle,
        harness: InstalledAppUITestHarness,
        in app: XCUIApplication
    ) throws {
        try openInstalledSettings(harness: harness, in: app)
        // SwiftUI titles this window after the selected category (for example,
        // Analysis or Local AI), while its native accessibility identity is stable.
        let settingsWindow = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 10))
        let localAICategory = try requireElement(
            identified: "settings.category.localAI",
            in: app,
            timeout: 10,
            context: "the Local AI settings category"
        )
        localAICategory.click()
        _ = try requireElement(
            identified: "settings.local-ai",
            in: app,
            timeout: 10,
            context: "the Local AI settings pane"
        )

        let endpoint = try requireElement(
            identified: "local-ai.endpoint.origin",
            in: app,
            timeout: 10,
            context: "the loopback endpoint field"
        )
        endpoint.click()
        endpoint.typeKey("a", modifierFlags: .command)
        endpoint.typeText(provider.endpointOrigin)

        let apply = try requireElement(
            identified: "local-ai.endpoint.apply",
            in: app,
            timeout: 5,
            context: "Apply Endpoint"
        )
        try requireEnabled(apply, context: "Apply Endpoint")
        apply.click()

        let refresh = try requireElement(
            identified: "local-ai.inventory.refresh",
            in: app,
            timeout: 10,
            context: "Refresh Models"
        )
        try requireEnabled(refresh, timeout: 10, context: "Refresh Models")
        refresh.click()

        _ = try requireElement(
            identified: "local-ai.model.\(oracle.modelKey)",
            in: app,
            timeout: 10,
            context: "the deterministic model row"
        )
        let load = try requireElement(
            identified: "local-ai.model.\(oracle.modelKey).load",
            in: app,
            timeout: 5,
            context: "Load deterministic model"
        )
        try requireEnabled(load, timeout: 10, context: "Load deterministic model")
        load.click()
        _ = try provider.waitForRequest(path: "/api/v1/models/load", timeout: 10)

        let use = try requireElement(
            identified: "local-ai.model.\(oracle.modelKey).use",
            in: app,
            timeout: 10,
            context: "Use deterministic model"
        )
        try requireEnabled(use, timeout: 10, context: "Use deterministic model")
        use.click()

        let readiness = try requireElement(
            identified: "local-ai.readiness.status",
            in: app,
            timeout: 10,
            context: "the deterministic provider readiness status"
        )
        try requireText(
            readiness,
            containing: "ready",
            timeout: 10,
            context: "the configured deterministic provider"
        )
        // Cmd-W can remain routed through a settings field; another window's mere
        // existence does not prove that Settings closed or document commands work.
        let closeSettings = settingsWindow.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(closeSettings.waitForExistence(timeout: 5))
        closeSettings.click()
        XCTAssertTrue(
            settingsWindow.waitForNonExistence(timeout: 5),
            "The exact Settings window did not close."
        )
        let documentWindow = try harness.focusedAccessibilityWindow()
        _ = try harness.waitForAccessibilityDescendant(
            identified: InstalledAppUITestHarness.workspaceRootAccessibilityIdentifier,
            of: documentWindow,
            depth: 10,
            timeout: 5,
            context: "the focused document after closing Settings"
        )
    }

    func openInstalledSettings(
        harness: InstalledAppUITestHarness,
        in app: XCUIApplication
    ) throws {
        app.activate()
        guard app.wait(for: .runningForeground, timeout: 5) else {
            throw task10CFailure("The installed candidate did not become foreground-active.")
        }

        try harness.performApplicationMenuCommand(titled: "Settings…")
    }

    func exerciseCancelFromActive(app: XCUIApplication, dashboard: XCUIElement) throws {
        let cancel = try requireElement(
            identified: "reconstruction.cancel",
            in: dashboard,
            timeout: 10,
            context: "Cancel from an active job"
        )
        try requireEnabled(cancel, timeout: 10, context: "Cancel from an active job")
        cancel.click()
        let state = try requireElement(
            identified: "reconstruction.job.state",
            in: app,
            timeout: 5,
            context: "the committed cancelled state"
        )
        try requireText(state, containing: "cancelled", timeout: 10, context: "Cancel")
    }

    func exerciseCorpusCounts(
        harness: InstalledAppUITestHarness,
        fixture: Task10InstalledScenarioFixtureCatalog.Fixture,
        app: XCUIApplication
    ) throws {
        let expectedValue = "\(fixture.expectedCorpusOccurrenceCount) occurrences, "
            + "\(fixture.expectedCorpusUniqueContentCount) unique content items, "
            + "\(fixture.expectedCorpusRelationCount) relations, "
            + "\(fixture.expectedCorpusUnresolvedRelationCount) unresolved relations"
        _ = try requireExactAccessibilityContract(
            harness: harness,
            identifier: "reconstruction.corpusSummary",
            expectedWindowTitle: fixture.packageURL.deletingPathExtension().lastPathComponent,
            expected: Task10CAccessibilityContract(
                label: "Corpus summary",
                value: expectedValue,
                help: "Reports occurrence, unique-content, relation, and unresolved-relation "
                    + "counts for the selected job."
            ),
            context: "the exact corpus summary"
        )
    }

    @discardableResult
    func exerciseCreationCommit(
        harness: InstalledAppUITestHarness,
        fixture: Task10InstalledScenarioFixtureCatalog.Fixture,
        provider: InstalledDeterministicLocalAIProvider,
        app: XCUIApplication
    ) throws -> UUID {
        let expectedPackage = try Task10SavedPackageObservation.capture(
            at: fixture.packageURL.resolvingSymlinksInPath()
        )
        func attachPackageObservation(_ observation: Task10SavedPackageObservation, name: String) {
            for (suffix, bytes) in [("manifest", observation.workspaceManifest),
                                    ("checkpoint-manifest", observation.checkpointManifest)] {
                let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.json")
                attachment.name = "Create-\(name)-\(suffix)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        defer {
            // Keep the decisive package bytes before fixture cleanup, including on a failed Save.
            if let last = try? Task10SavedPackageObservation.capture(at: expectedPackage.packageURL) {
                attachPackageObservation(last, name: "final-observation")
            }
        }
        let objective = try submitInstalledCreation(app: app)
        let identity = app.descendants(matching: .any)["reconstruction.job.identity"]
        let progress = app.descendants(matching: .any)["reconstruction.progress"]

        let deadline = Date().addingTimeInterval(10)
        var observedIdentityAndExecution = false
        repeat {
            // AX queries are not an atomic frame. Read identity after progress so a valid
            // publication crossing the query boundary is not mistaken for orphan execution.
            let executionVisible = try Task10CreationHistoryVerifier.hasAutomatedProgress(
                accessibilityText(of: progress)
            )
            let identityCommitted = accessibilityText(of: identity)
                .components(separatedBy: " | ").contains("Job 1")
            if executionVisible && !identityCommitted {
                throw task10CFailure(
                    "Creation exposed automated progress before committed job identity."
                )
            }
            if identityCommitted && executionVisible {
                observedIdentityAndExecution = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while Date() < deadline
        guard observedIdentityAndExecution else {
            throw task10CFailure("Creation did not expose committed Job 1 and actual automated execution.")
        }
        // The dashboard header overrides its combined children's AX label/value. The selected
        // navigator row is the existing objective/ordinal surface and exposes the exact job UUID.
        let jobRows = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "reconstruction:job:"
        ))
        guard waitUntil(timeout: 5, predicate: {
            jobRows.count == 1 && jobRows.element(boundBy: 0).isSelected
        }) else {
            throw task10CFailure("Creation did not expose one selected committed navigator job.")
        }
        let navigatorRow = jobRows.element(boundBy: 0)
        let navigatorIdentifier = navigatorRow.identifier
        let navigatorJobID = try Task10CreationHistoryVerifier.selectedNavigatorJobID(
            identifier: navigatorIdentifier, label: navigatorRow.label,
            isSelected: navigatorRow.isSelected, expectedObjective: objective,
            visibleCreationOrdinal: 1
        )
        // The existing held chat route allows real automatic work through model admission, then
        // stabilizes Save. It is not a creation/start barrier or a substitute for executed tasks.
        _ = try provider.waitForRequest(path: "/v1/chat/completions", timeout: 10)
        func verifySavedCreation(_ observation: Task10SavedPackageObservation) throws -> Task10CreationHistoryVerifier.Proof {
            let proof = try Task10CreationHistoryVerifier.verify(
                workspaceManifest: observation.workspaceManifest,
                checkpointManifest: observation.checkpointManifest,
                expectedProjectID: try task10CreationUUID("10000000-0000-0000-0000-000000000004"),
                expectedOccurrenceID: try task10CreationUUID("10000000-0000-0000-0000-000000000005"),
                expectedObjective: objective, visibleCreationOrdinal: 1
            )
            guard proof.jobID == navigatorJobID else {
                throw task10CFailure("The saved creation package did not belong to the selected job.")
            }
            return proof
        }
        let publication = try harness.saveOpenWorkspacePackage(
            matching: expectedPackage, in: app,
            verifyContents: { _ = try verifySavedCreation($0) }
        )
        attachPackageObservation(publication.before, name: "before-explicit-save")
        attachPackageObservation(publication.after, name: "after-explicit-save")
        let generation = XCTAttachment(string:
            "File > Save package publication: device/inode "
                + "\(publication.before.rootIdentity.device)/\(publication.before.rootIdentity.inode) -> "
                + "\(publication.after.rootIdentity.device)/\(publication.after.rootIdentity.inode); "
                + "document \(publication.after.documentID); workspace \(publication.after.workspaceID)"
        )
        generation.name = "Create-explicit-save-physical-publication"
        generation.lifetime = .keepAlways
        add(generation)
        let proof = try verifySavedCreation(publication.after)
        XCTAssertEqual(proof.creationOrdinal, 1)
        XCTAssertEqual(proof.jobID, navigatorJobID)
        XCTAssertEqual(proof.initialTaskCount, 3)
        XCTAssertGreaterThan(proof.currentRevision, 0)
        let savedNavigatorRow = app.buttons[navigatorIdentifier]
        guard savedNavigatorRow.exists else {
            throw task10CFailure("Saved job lost its exact selected navigator identity.")
        }
        XCTAssertEqual(try Task10CreationHistoryVerifier.selectedNavigatorJobID(
            identifier: savedNavigatorRow.identifier, label: savedNavigatorRow.label,
            isSelected: savedNavigatorRow.isSelected, expectedObjective: objective,
            visibleCreationOrdinal: proof.creationOrdinal
        ), proof.jobID)
        guard accessibilityText(of: identity).components(separatedBy: " | ").contains("Job 1"),
              try Task10CreationHistoryVerifier.hasAutomatedProgress(accessibilityText(of: progress)) else {
            throw task10CFailure("Saved creation history no longer matches the visible identity/execution.")
        }
        // The saved canonical revision-zero parent chain proves durable commit-before-execution.
        // Store integration separately gates publication-before-start. Neither proves that XCTest
        // captured two distinct rendered frames; no artificial delay is introduced to force one.
        return proof.jobID
    }

    /// Shared shipping UI submission only. Callers retain their own later-state obligations.
    @discardableResult
    private func submitInstalledCreation(app: XCUIApplication) throws -> String {
        try openCreationSheet(in: app)
        let identity = app.descendants(matching: .any)["reconstruction.job.identity"]
        let state = app.descendants(matching: .any)["reconstruction.job.state"]
        let progress = app.descendants(matching: .any)["reconstruction.progress"]
        XCTAssertTrue(identity.waitForExistence(timeout: 5))
        guard state.waitForExistence(timeout: 5), progress.waitForExistence(timeout: 5) else {
            throw task10CFailure(
                "Creation did not expose the governed state and progress accessibility surfaces."
            )
        }
        recordSuccessfulAccessibilityResolution("reconstruction.job.state")
        recordSuccessfulAccessibilityResolution("reconstruction.progress")
        guard Task10CreationHistoryVerifier.hasEmptyIdentity(accessibilityText(of: identity)),
              !(try Task10CreationHistoryVerifier.hasAutomatedProgress(accessibilityText(of: progress))) else {
            throw task10CFailure("Create must begin with no committed job and no executed tasks.")
        }
        let item = try requireElement(
            identified: "reconstruction.creation.item.10000000-0000-0000-0000-000000000005",
            in: app,
            timeout: 5,
            context: "the committed creation item"
        )
        item.click()
        let objective = "Reconstruct the installed deterministic target"
        try enterObjective(objective, in: app)
        let submit = try requireElement(
            identified: "reconstruction.creation.submit",
            in: app,
            timeout: 5,
            context: "Create and Start"
        )
        try requireEnabled(submit, context: "Create and Start")
        submit.click()
        return objective
    }

    private func task10CreationUUID(_ literal: String) throws -> UUID {
        guard let uuid = UUID(uuidString: literal) else { throw task10CFailure("Invalid creation fixture UUID.") }
        return uuid
    }

    func exerciseInvalidCreation(app: XCUIApplication, whitespaceObjective: Bool) throws {
        _ = try requireElement(
            identified: "reconstruction.primaryAction",
            in: app,
            timeout: 5,
            context: "the governed primary Reconstruction command group"
        )
        try openCreationSheet(in: app)
        if whitespaceObjective {
            let item = try requireElement(
                identified: "reconstruction.creation.item.10000000-0000-0000-0000-000000000005",
                in: app,
                timeout: 5,
                context: "the committed creation item"
            )
            item.click()
            try enterObjective("   \t   ", in: app)
        } else {
            try enterObjective("A valid bounded objective", in: app)
        }
        let submit = try requireElement(
            identified: "reconstruction.creation.submit",
            in: app,
            timeout: 5,
            context: "the guarded creation submission"
        )
        XCTAssertFalse(
            submit.isEnabled,
            whitespaceObjective
                ? "Whitespace-only objectives must remain rejected."
                : "An empty artifact selection must remain rejected."
        )
        app.typeKey(.escape, modifierFlags: [])
    }

    func exerciseCurrentGap(
        harness: InstalledAppUITestHarness,
        fixture: Task10InstalledScenarioFixtureCatalog.Fixture,
        app: XCUIApplication
    ) throws {
        XCTAssertEqual(fixture.expectedGapCount, 1)
        let operationID = try XCTUnwrap(fixture.expectedCurrentGapOperationID)
        _ = try requireExactAccessibilityContract(
            harness: harness,
            identifier: "reconstruction.currentGap",
            expectedWindowTitle: fixture.packageURL.deletingPathExtension().lastPathComponent,
            expected: Task10CAccessibilityContract(
                label: "Current unresolved gap",
                value: "One current evidence gap remains unresolved. Operation \(operationID)",
                help: "Reports the current bounded operation identity."
            ),
            context: "the exact current unresolved gap"
        )
    }

    func exerciseDestinationSwitch(
        fixture: Task10InstalledScenarioFixtureCatalog.Fixture,
        app: XCUIApplication
    ) throws {
        let windowTitle = app.windows.element(boundBy: 0).title
        let project = try requireElement(
            identified: "workspace.tool.project",
            in: app,
            timeout: 5,
            context: "Project navigation"
        )
        project.click()
        guard waitUntil(timeout: 5, predicate: {
            !app.descendants(matching: .any)["reconstruction.destination"].exists
        }) else {
            throw task10CFailure("Leaving Reconstruction did not restore the editor destination.")
        }
        let expectedAddress = String(
            format: "0x%016llx",
            try XCTUnwrap(fixture.expectedFunctionAddress)
        )
        // The native segmented picker exposes selection on its radio button;
        // its containing SwiftUI group does not reliably export an AX value.
        let mode = app.radioButtons[fixture.expectedEditorMode]
        XCTAssertTrue(mode.waitForExistence(timeout: 10), "The editor mode was not restored.")
        try requireRadioSelection(mode, context: "the restored exact editor mode")
        // The editor context bar's combined label is the selected-instruction
        // authority exposed by the installed native surface.
        let disassembly = app.groups.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Disassembly, ")
        ).firstMatch
        XCTAssertTrue(
            disassembly.waitForExistence(timeout: 10),
            "Destination switching did not restore the editor-owned disassembly surface."
        )
        XCTAssertTrue(
            disassembly.label.contains(", selected instruction \(expectedAddress),"),
            "Destination switching did not restore selected address \(expectedAddress); "
                + "AX label was \(disassembly.label)."
        )
        let focusedImage = app.buttons.matching(
            NSPredicate(
                format: "label BEGINSWITH %@",
                fixture.expectedFocusedImageName + ", "
            )
        ).firstMatch
        XCTAssertTrue(
            focusedImage.waitForExistence(timeout: 10),
            "Destination switching did not restore focused image "
                + fixture.expectedFocusedImageName + "."
        )
        XCTAssertTrue(focusedImage.isSelected, "The expected image is not selected in the navigator.")
        let reconstruction = try requireElement(
            identified: "reconstruction.navigation",
            in: app,
            timeout: 5,
            context: "Reconstruction navigation after editor restoration"
        )
        reconstruction.click()
        _ = try requireElement(
            identified: "reconstruction.destination",
            in: app,
            timeout: 10,
            context: "Reconstruction after a destination round trip"
        )
        XCTAssertEqual(app.windows.element(boundBy: 0).title, windowTitle)
    }

    func exerciseEndpointMissing(app: XCUIApplication, dashboard: XCUIElement) throws {
        XCTAssertTrue(dashboard.exists)
        _ = try requireElement(
            identified: "reconstruction.terminalNotice",
            in: app,
            timeout: 5,
            context: "the bounded no-job notice"
        )
        try requireText(
            dashboard,
            containing: "Model endpoint missing",
            timeout: 5,
            context: "endpoint-missing readiness"
        )
    }

    func exerciseDestinationReady(app: XCUIApplication, dashboard: XCUIElement) throws {
        XCTAssertTrue(dashboard.exists)
        _ = try requireElement(
            identified: "reconstruction.dashboard",
            in: app,
            timeout: 5,
            context: "the ready Reconstruction dashboard"
        )
        try requireText(dashboard, containing: "Model ready", timeout: 5, context: "ready model")
    }

    func exerciseKeyboardAndMenuEquivalence(
        harness: InstalledAppUITestHarness,
        catalog: Task10InstalledScenarioFixtureCatalog,
        preference: Task10CProviderPreferenceSnapshot
    ) throws {
        var referenceNonterminalOutcomes: [String]?
        for route in Task10CCommandRoute.allCases {
            try preference.clearForIsolatedLaunch()
            let fixture = try catalog.copyScenario("no-job")
            let fixtureCleanup = registerTask10Cleanup { fixture.remove() }
            defer { try? fixtureCleanup.perform() }
            let candidateCleanup = registerTask10Cleanup {
                harness.terminateExactCandidateIfRunning()
            }
            defer { try? candidateCleanup.perform() }
            harness.terminateExactCandidateIfRunning()
            let app = try harness.launch()

            do {
                try harness.openWorkspacePackage(fixture.packageURL, in: app)
                _ = try openReconstructionDashboard(
                    harness: harness,
                    fixture: fixture,
                    app: app
                )
                _ = try requireElement(
                    identified: "reconstruction.primaryAction",
                    in: app,
                    timeout: 5,
                    context: "the command-route primary Reconstruction group"
                )
                try createJobWithoutExecutableProvider(in: app)

                let provider = try InstalledDeterministicLocalAIProvider.start(
                    oracle: catalog.provider
                )
                let providerCleanup = registerTask10Cleanup {
                    provider.stopExactOwnedProcessIfNeeded()
                }
                defer { try? providerCleanup.perform() }
                try provider.hold(.chat)
                try configureInstalledProvider(
                    provider,
                    oracle: catalog.provider,
                    harness: harness,
                    in: app
                )

                let outcomes = try dispatchCommandLifecycle(route: route, in: app)
                let nonterminalOutcomes = Array(outcomes.prefix(3))
                if let referenceNonterminalOutcomes {
                    XCTAssertEqual(
                        nonterminalOutcomes,
                        referenceNonterminalOutcomes,
                        "\(route.rawValue) commands did not commit the control-route lifecycle."
                    )
                } else {
                    referenceNonterminalOutcomes = nonterminalOutcomes
                }
                switch route {
                case .control, .menu:
                    XCTAssertEqual(
                        outcomes,
                        ["retrieving", "paused", "retrieving", "cancelled"],
                        "\(route.rawValue) must retain destructive Cancel coverage."
                    )
                case .keyboard:
                    XCTAssertEqual(
                        outcomes,
                        ["retrieving", "paused", "retrieving"],
                        "Keyboard equivalence is limited to commands with global shortcuts."
                    )
                }
            }
        }
        XCTAssertEqual(
            referenceNonterminalOutcomes,
            ["retrieving", "paused", "retrieving"],
            "Control, menu, and keyboard routes must agree for Start, Pause, and Resume."
        )
    }

    func createJobWithoutExecutableProvider(in app: XCUIApplication) throws {
        try openCreationSheet(in: app)
        let item = try requireElement(
            identified: "reconstruction.creation.item.10000000-0000-0000-0000-000000000005",
            in: app,
            timeout: 5,
            context: "the command-route creation item"
        )
        item.click()
        try enterObjective("Compare control, menu, and keyboard command routes", in: app)
        let submit = try requireElement(
            identified: "reconstruction.creation.submit",
            in: app,
            timeout: 5,
            context: "the command-route creation submission"
        )
        try requireEnabled(submit, context: "the command-route creation submission")
        submit.click()
        let state = try requireElement(
            identified: "reconstruction.job.state",
            in: app,
            timeout: 10,
            context: "the committed command-route job"
        )
        try requireText(
            state,
            containing: "created",
            timeout: 10,
            context: "the created job before provider readiness"
        )
    }

    func dispatchCommandLifecycle(
        route: Task10CCommandRoute,
        in app: XCUIApplication
    ) throws -> [String] {
        let state = try requireElement(
            identified: "reconstruction.job.state",
            in: app,
            timeout: 5,
            context: "the command-route committed state"
        )
        let commandsWithGlobalShortcuts = [
            ("Start", "retrieving"),
            ("Pause", "paused"),
            ("Resume", "retrieving"),
        ]
        let commands: [(String, String)]
        switch route {
        case .control, .menu:
            commands = commandsWithGlobalShortcuts + [("Cancel", "cancelled")]
        case .keyboard:
            commands = commandsWithGlobalShortcuts
        }

        var outcomes: [String] = []
        for (command, expectedState) in commands {
            try dispatchReconstructionCommand(command, route: route, in: app)
            try requireText(
                state,
                containing: expectedState,
                timeout: 15,
                context: "\(route.rawValue) \(command) committed outcome"
            )
            outcomes.append(expectedState)
        }
        return outcomes
    }

    func dispatchReconstructionCommand(
        _ command: String,
        route: Task10CCommandRoute,
        in app: XCUIApplication
    ) throws {
        let identifier = "reconstruction.\(command.lowercased())"
        let control = try requireElement(
            identified: identifier,
            in: app,
            timeout: 10,
            context: "the \(command) control for \(route.rawValue) dispatch"
        )
        try requireEnabled(control, timeout: 15, context: "\(route.rawValue) \(command)")

        let menu = app.menuBars.menuBarItems["Reconstruction"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "The Reconstruction menu is missing.")
        menu.click()
        let menuItem = app.menuItems[command]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5), "The \(command) menu item is missing.")
        XCTAssertEqual(
            menuItem.isEnabled,
            control.isEnabled,
            "\(command) menu/control enabled-state parity drifted."
        )
        app.typeKey(.escape, modifierFlags: [])

        switch route {
        case .control:
            control.click()
        case .menu:
            menu.click()
            let routedItem = app.menuItems[command]
            XCTAssertTrue(routedItem.waitForExistence(timeout: 5))
            routedItem.click()
        case .keyboard:
            switch command {
            case "Start":
                app.typeKey(.return, modifierFlags: .command)
            case "Pause":
                app.typeKey("p", modifierFlags: [.command, .option])
            case "Resume":
                app.typeKey("r", modifierFlags: [.command, .option])
            case "Cancel":
                throw task10CFailure(
                    "Cancel intentionally has no global keyboard shortcut; use its control or menu item."
                )
            default:
                throw task10CFailure("Unknown Reconstruction command route: \(command)")
            }
        }
    }

    func exercisePauseFromActive(app: XCUIApplication) throws {
        let pause = try requireElement(
            identified: "reconstruction.pause",
            in: app,
            timeout: 10,
            context: "Pause from retrieving"
        )
        try requireEnabled(pause, timeout: 10, context: "Pause from retrieving")
        pause.click()
        let state = try requireElement(
            identified: "reconstruction.job.state",
            in: app,
            timeout: 5,
            context: "the committed paused state"
        )
        try requireText(state, containing: "paused", timeout: 10, context: "Pause")
    }

    func exercisePausedModelUnavailable(
        harness: InstalledAppUITestHarness,
        fixture: Task10InstalledScenarioFixtureCatalog.Fixture,
        app: XCUIApplication
    ) throws {
        XCTAssertEqual(fixture.expectedJobState, "paused")
        let state = try requireElement(
            identified: "reconstruction.job.state",
            in: app,
            timeout: 5,
            context: "the durable paused state"
        )
        try requireText(state, containing: "paused", timeout: 5, context: "paused state")
        let resume = try requireElement(
            identified: "reconstruction.resume",
            in: app,
            timeout: 5,
            context: "the exact Resume target"
        )
        XCTAssertFalse(resume.isEnabled, "Resume must wait for executable model authority.")
        XCTAssertNotNil(
            fixture.expectedResumeTarget,
            "The paused fixture must preserve its exact durable resume target."
        )
        let accessibilityApplication = try harness.accessibilityApplication()
        let resumeAccessibility = try harness.waitForAccessibilityDescendant(
            identified: "reconstruction.resume",
            of: accessibilityApplication,
            depth: 12,
            timeout: 5,
            context: "the model-unavailable Resume accessibility action"
        )
        let help = harness.accessibilityString(
            attribute: kAXHelpAttribute as CFString,
            of: resumeAccessibility
        ) ?? ""
        XCTAssertTrue(
            help.localizedCaseInsensitiveContains("not executable"),
            "Resume was disabled for an unexpected reason: \(help)"
        )
    }

    func exercisePendingPauseNotCommitted(
        barrier: Task10CPauseBarrier,
        app: XCUIApplication
    ) throws {
        let pause = try requireElement(
            identified: "reconstruction.pause",
            in: app,
            timeout: 10,
            context: "the pause command guarded by the owned barrier"
        )
        try requireEnabled(pause, timeout: 10, context: "the pause command")
        pause.click()
        try barrier.waitForArrival()

        let notice = try requireElement(
            identified: "reconstruction.terminalNotice",
            in: app,
            timeout: 5,
            context: "the pending Pause notice"
        )
        try requireText(notice, containing: "Requesting pause", timeout: 5, context: "pending Pause")
        let state = try requireElement(
            identified: "reconstruction.job.state",
            in: app,
            timeout: 5,
            context: "the still-committed retrieving state"
        )
        try requireText(
            state,
            containing: "retrieving",
            timeout: 5,
            context: "pending Pause committed-state fence"
        )

        try barrier.release()
        try requireText(state, containing: "paused", timeout: 10, context: "released Pause")
    }

    func exercisePrivacy(
        harness: InstalledAppUITestHarness,
        fixture: Task10InstalledScenarioFixtureCatalog.Fixture,
        app: XCUIApplication
    ) throws {
        let canaries = try [
            XCTUnwrap(fixture.forbiddenRawPromptCanary),
            XCTUnwrap(fixture.forbiddenRawPathCanary),
            XCTUnwrap(fixture.forbiddenRawPseudocodeCanary),
        ]
        for canary in canaries {
            XCTAssertTrue(
                try packageContainsUTF8Canary(canary, at: fixture.packageURL),
                "The privacy fixture does not contain its required source canary."
            )
        }

        let application = try harness.accessibilityApplication()
        var surfacedStrings: [String] = []
        for (identifier, context) in [
            ("reconstruction.dashboard", "the privacy-bounded dashboard"),
            ("reconstruction.terminalNotice", "the privacy-bounded notice"),
            ("reconstruction.inspector", "the privacy-bounded inspector"),
        ] {
            let surface = try harness.waitForAccessibilityDescendant(
                identified: identifier,
                of: application,
                depth: 14,
                timeout: 5,
                context: context
            )
            let boundedStrings = harness.boundedAccessibilityAttributeStrings(
                of: surface,
                depth: 12,
                limit: 512
            )
            guard !boundedStrings.wasTruncated, !boundedStrings.wasIncomplete else {
                throw task10CFailure(
                    "Installed privacy accessibility traversal was truncated or incomplete; "
                        + "refusing to treat a partial scan as absence proof."
                )
            }
            recordSuccessfulAccessibilityResolution(identifier)
            surfacedStrings.append(contentsOf: boundedStrings.strings)
        }
        for canary in canaries {
            XCTAssertFalse(
                surfacedStrings.contains(where: { $0.contains(canary) }),
                "Installed AX label/value/help leaked a governed privacy canary."
            )
        }
        let lowercaseText = surfacedStrings.joined(separator: "\n").lowercased()
        for forbidden in ["file://", "api_key", "bearer ", "password=", "secret="] {
            XCTAssertFalse(
                lowercaseText.contains(forbidden),
                "Installed accessibility leaked a forbidden credential/path marker."
            )
        }
    }

    func exerciseResumeExactTarget(
        fixture: Task10InstalledScenarioFixtureCatalog.Fixture,
        app: XCUIApplication
    ) throws {
        let expectedTarget = try XCTUnwrap(fixture.expectedResumeTarget)
        let resume = try requireElement(
            identified: "reconstruction.resume",
            in: app,
            timeout: 10,
            context: "Resume to \(expectedTarget)"
        )
        try requireEnabled(resume, timeout: 10, context: "Resume to \(expectedTarget)")
        resume.click()
        let state = try requireElement(
            identified: "reconstruction.job.state",
            in: app,
            timeout: 5,
            context: "the resumed committed state"
        )
        try requireText(state, containing: expectedTarget, timeout: 10, context: "exact Resume")
    }

    func exerciseCurrentSourceReveal(
        harness: InstalledAppUITestHarness,
        fixture: Task10InstalledScenarioFixtureCatalog.Fixture,
        app: XCUIApplication
    ) throws {
        XCTAssertEqual(fixture.expectedCheckpointFreshness, "current")
        let address = try XCTUnwrap(fixture.expectedFunctionAddress)
        let functionID = try expectedFunctionID(in: fixture, at: address)
        let startingImageName = try XCTUnwrap(fixture.expectedStartingImageName)
        let startingAddress = try XCTUnwrap(fixture.expectedStartingFunctionAddress)
        XCTAssertNotEqual(startingImageName, fixture.expectedFocusedImageName)
        XCTAssertNotEqual(startingAddress, address)
        let startingContext = try expectedFunctionContext(
            in: fixture, imageName: startingImageName, at: startingAddress
        )
        let project = try requireElement(
            identified: "workspace.tool.project",
            in: app,
            timeout: 5,
            context: "Project navigation before current source reveal"
        )
        project.click()
        let startingImage = app.buttons.matching(
            NSPredicate(
                format: "label BEGINSWITH %@",
                startingImageName + ", "
            )
        ).firstMatch
        XCTAssertTrue(
            startingImage.waitForExistence(timeout: 10),
            "Current source reveal did not start from the distinct persisted image."
        )
        // Project function rows are a primary-image compatibility projection, not
        // the focused image's functions. Establish the secondary image/address
        // through its binary row and Go To, then verify the image-qualified editor.
        startingImage.click()
        app.typeKey("l", modifierFlags: .command)
        let goToField = app.textFields["0x100000000 or symbol name"]
        XCTAssertTrue(
            goToField.waitForExistence(timeout: 5),
            "Go to Address did not expose its exact query field."
        )
        goToField.typeText(String(format: "0x%llx", startingAddress))
        goToField.typeKey(.return, modifierFlags: [])
        let renderedStartingAddress = String(format: "0x%016llx", startingAddress)
        let startingEditor = app.groups.matching(NSPredicate(
            format: "label == %@",
            "Disassembly, \(startingImageName), \(startingContext.name), "
                + "selected instruction \(renderedStartingAddress), ret"
        )).firstMatch
        XCTAssertTrue(
            startingEditor.waitForExistence(timeout: 10),
            "Go To did not select the fixture's exact starting image, function, and address."
        )
        _ = try requireElement(
            identified: "disassembly.breakpoint.\(startingContext.slot)."
                + String(format: "%016llx", startingAddress),
            in: app,
            timeout: 5,
            context: "the image-qualified starting instruction"
        )
        // Go To selects Disassembly for an instruction address. Explicitly enter
        // Hex so Reveal Source must also restore the expected editor mode.
        let hexMode = app.radioButtons["Hex"]
        XCTAssertTrue(hexMode.waitForExistence(timeout: 5))
        hexMode.click()
        try requireRadioSelection(hexMode, context: "the distinct starting Hex mode")
        // Hex exposes a byte-window offset and row, not a virtual address. The
        // exact image/function/address was proven above; the radio proves mode.
        let reconstruction = try requireElement(
            identified: "reconstruction.navigation",
            in: app,
            timeout: 5,
            context: "Reconstruction navigation after distinct source selection"
        )
        reconstruction.click()
        let destination = try requireElement(
            identified: "reconstruction.destination",
            in: app,
            timeout: 10,
            context: "Reconstruction after distinct source selection"
        )
        func visibleDashboardButton(matching predicate: NSPredicate, context: String) throws -> XCUIElement {
            // Details and its evidence samples are below the initial viewport. Re-query
            // after each real scroll, including after evidence selection changes layout.
            for step in 0..<12 {
                let matches = app.buttons.matching(predicate).allElementsBoundByIndex
                if matches.count == 1, let button = matches.first, button.isHittable {
                    return button
                }
                if matches.count > 1 { break }
                if step < 11 { destination.scroll(byDeltaX: 0, deltaY: -300) }
            }
            let snapshot = XCTAttachment(screenshot: app.screenshot())
            snapshot.name = "Reveal-\(context)-dashboard"
            snapshot.lifetime = .keepAlways
            add(snapshot)
            let accessibility = XCTAttachment(string: app.debugDescription)
            accessibility.name = "Reveal-\(context)-accessibility"
            accessibility.lifetime = .keepAlways
            add(accessibility)
            throw task10CFailure("The bounded dashboard scroll did not expose one hittable \(context).")
        }
        let evidence = try visibleDashboardButton(
            matching: NSPredicate(
                format: "label == %@ AND value == %@",
                "Select acceptedCurrent evidence", "structuredJSON"
            ),
            context: "current function evidence"
        )
        evidence.click()
        _ = try requireElement(
            identified: "reconstruction.details",
            in: app,
            timeout: 5,
            context: "current evidence details"
        )
        let reveal = try visibleDashboardButton(
            matching: NSPredicate(format: "identifier == %@", "reconstruction.revealSource"),
            context: "current Reveal Source"
        )
        try requireEnabled(reveal, context: "current Reveal Source")
        reveal.click()
        guard waitUntil(timeout: 10, predicate: {
            !app.descendants(matching: .any)["reconstruction.destination"].exists
        }) else {
            throw task10CFailure("Current source reveal did not return to the editor.")
        }
        let renderedAddress = String(format: "0x%016llx", address)
        let disassembly = app.groups.matching(
            NSPredicate(
                format: "label BEGINSWITH %@ AND label CONTAINS %@",
                "Disassembly, \(fixture.expectedFocusedImageName), ",
                "selected instruction \(renderedAddress),"
            )
        ).firstMatch
        XCTAssertTrue(
            disassembly.waitForExistence(timeout: 10),
            "Current source reveal did not select exact address \(renderedAddress)."
        )
        let mode = app.radioButtons[fixture.expectedEditorMode]
        XCTAssertTrue(mode.waitForExistence(timeout: 10), "Editor mode was not restored.")
        try requireRadioSelection(mode, context: "the source-revealed exact editor mode")
        let focusedImage = app.buttons.matching(
            NSPredicate(
                format: "label BEGINSWITH %@",
                fixture.expectedFocusedImageName + ", "
            )
        ).firstMatch
        XCTAssertTrue(
            focusedImage.waitForExistence(timeout: 10),
            "Current source reveal did not restore the exact focused image."
        )
        let revealedFunction = try requireElement(
            identified: "function:\(functionID.uuidString)",
            in: app,
            timeout: 10,
            context: "the exact source-revealed function sidebar selection"
        )
        try requireSelectedAndKeyboardFocused(
            revealedFunction,
            identified: "function:\(functionID.uuidString)",
            harness: harness,
            context: "the exact source-revealed function sidebar selection"
        )
    }

    func expectedFunctionID(
        in fixture: Task10InstalledScenarioFixtureCatalog.Fixture,
        at address: UInt64
    ) throws -> UUID {
        let manifestURL = fixture.packageURL.appendingPathComponent("manifest.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
        let manifest = try XCTUnwrap(object as? [String: Any])
        let analyses = try XCTUnwrap(manifest["imageAnalyses"] as? [[String: Any]])
        let matchingIDs = analyses.flatMap { imageAnalysis -> [UUID] in
            guard let analysis = imageAnalysis["analysis"] as? [String: Any],
                  let functions = analysis["functions"] as? [[String: Any]] else { return [] }
            return functions.compactMap { function in
                guard (function["startAddress"] as? NSNumber)?.uint64Value == address,
                      let rawID = function["id"] as? String else { return nil }
                return UUID(uuidString: rawID)
            }
        }
        guard matchingIDs.count == 1, let functionID = matchingIDs.first else {
            throw task10CFailure(
                "The committed package does not carry exactly one function at "
                    + String(format: "0x%llx", address) + "."
            )
        }
        return functionID
    }

    func expectedFunctionContext(
        in fixture: Task10InstalledScenarioFixtureCatalog.Fixture,
        imageName: String,
        at address: UInt64
    ) throws -> (name: String, slot: Int) {
        let manifestURL = fixture.packageURL.appendingPathComponent("manifest.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
        let manifest = try XCTUnwrap(object as? [String: Any])
        let binaries = try XCTUnwrap(manifest["binaries"] as? [[String: Any]])
        let matchingBinaries = binaries.filter { $0["displayName"] as? String == imageName }
        guard matchingBinaries.count == 1,
              let binaryID = matchingBinaries.first?["id"] as? String else {
            throw task10CFailure("The fixture does not uniquely identify its starting image.")
        }
        let analyses = try XCTUnwrap(manifest["imageAnalyses"] as? [[String: Any]])
        let matchingAnalyses = analyses.filter { $0["binaryID"] as? String == binaryID }
        guard matchingAnalyses.count == 1, let image = matchingAnalyses.first,
              let slot = image["imageSlot"] as? Int,
              let analysis = image["analysis"] as? [String: Any],
              let functions = analysis["functions"] as? [[String: Any]] else {
            throw task10CFailure("The fixture does not uniquely identify its starting image analysis.")
        }
        let matchingFunctions = functions.filter {
            ($0["startAddress"] as? NSNumber)?.uint64Value == address
        }
        guard matchingFunctions.count == 1,
              let name = matchingFunctions.first?["name"] as? String, !name.isEmpty else {
            throw task10CFailure("The fixture does not uniquely identify its starting function.")
        }
        return (name, slot)
    }

    func exerciseStaleSourceReveal(
        barrier: Task10CSourceRevealBarrier,
        fixture: Task10InstalledScenarioFixtureCatalog.Fixture,
        app: XCUIApplication
    ) throws {
        XCTAssertEqual(fixture.expectedCheckpointFreshness, "current")
        let evidenceID = try XCTUnwrap(
            fixture.expectedNavigableEvidenceID,
            "The TOCTOU proof must render one exactly current Reveal Source action first."
        )
        let packageTreeBefore = try packageTreeSHA256(at: fixture.packageURL)
        let details = try requireElement(
            identified: "reconstruction.details",
            in: app,
            timeout: 5,
            context: "the pre-selection current evidence details"
        )
        let before = accessibilityText(of: details)
        let evidence = try firstHittableButton(
            in: app,
            labelContaining: "evidence",
            context: "the current function evidence retained for invalidation"
        )
        evidence.click()
        guard waitUntil(timeout: 5, predicate: {
            let selected = self.accessibilityText(of: details)
            return selected != before && selected.localizedCaseInsensitiveContains("evidence")
        }) else {
            throw task10CFailure("The current function evidence was not selected deterministically.")
        }
        let selectedEvidence = accessibilityText(of: details)
        let committedState = accessibilityText(of: try requireElement(
            identified: "reconstruction.job.state",
            in: app,
            timeout: 5,
            context: "the pre-invalidation committed Reconstruction state"
        ))
        let retainedReveal = try requireElement(
            identified: "reconstruction.revealSource",
            in: app,
            timeout: 5,
            context: "the rendered current Reveal Source action"
        )
        try requireEnabled(retainedReveal, context: "the retained current Reveal Source action")
        retainedReveal.click()
        try barrier.waitForArrival(expectedEvidenceID: evidenceID)

        XCTAssertTrue(
            app.descendants(matching: .any)["reconstruction.destination"].exists,
            "The retained Reveal Source action navigated before the test released invalidation."
        )
        XCTAssertEqual(
            accessibilityText(of: details),
            selectedEvidence,
            "The post-render barrier mutated selection before invalidation."
        )

        try barrier.release()
        let notice = try requireElement(
            identified: "reconstruction.terminalNotice",
            in: app,
            timeout: 10,
            context: "the exact stale-after-render refusal notice"
        )
        try requireText(
            notice,
            containing: "Source reveal refused",
            timeout: 10,
            context: "the stale-after-render refusal title"
        )
        try requireText(
            notice,
            containing: "Workspace, corpus, image, analysis, or function authority changed. "
                + "No source navigation was performed.",
            timeout: 10,
            context: "the stale-after-render generic refusal detail"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["reconstruction.destination"].exists,
            "Stale-after-render Reveal Source escaped the Reconstruction destination."
        )
        XCTAssertEqual(
            accessibilityText(of: details),
            selectedEvidence,
            "Stale-after-render Reveal Source mutated the selected evidence."
        )
        XCTAssertEqual(
            accessibilityText(of: try requireElement(
                identified: "reconstruction.job.state",
                in: app,
                timeout: 5,
                context: "the post-refusal committed Reconstruction state"
            )),
            committedState,
            "The qualification invalidation mutated durable Reconstruction state."
        )
        XCTAssertEqual(
            try packageTreeSHA256(at: fixture.packageURL),
            packageTreeBefore,
            "The stale-after-render qualification seam changed package bytes."
        )
        try exerciseDestinationSwitch(fixture: fixture, app: app)
    }

    func exerciseSaveReopen(
        harness: InstalledAppUITestHarness,
        fixture: Task10InstalledScenarioFixtureCatalog.Fixture,
        originalApp: XCUIApplication,
        appearance: InstalledAppUITestHarness.Appearance? = nil
    ) throws -> XCUIApplication {
        XCTAssertEqual(
            fixture.expectedJobState,
            "retrieving",
            "Save/reopen must start active so a pre-existing paused fixture cannot false-green."
        )
        let expectedPackage = try Task10SavedPackageObservation.capture(
            at: fixture.packageURL.resolvingSymlinksInPath()
        )
        let jobID = try XCTUnwrap(fixture.expectedJobID).uuidString
        func history(_ observation: Task10SavedPackageObservation) throws
            -> (job: [String: Any], checkpoints: [[String: Any]]) {
            let object = try JSONSerialization.jsonObject(with: observation.checkpointManifest)
            guard let manifest = object as? [String: Any],
                  let jobs = manifest["jobs"] as? [[String: Any]],
                  let checkpoints = manifest["checkpoints"] as? [[String: Any]] else {
                throw task10CFailure("Save/reopen checkpoint history is malformed.")
            }
            let matching = jobs.filter { $0["jobID"] as? String == jobID }
            guard matching.count == 1, let job = matching.first else {
                throw task10CFailure("Save/reopen lost its exact fixture job identity.")
            }
            return (job, checkpoints)
        }
        let initial = try history(expectedPackage)
        let initialCheckpointID = try XCTUnwrap(initial.job["currentCheckpointID"] as? String)
        let initialCheckpoint = try XCTUnwrap(initial.checkpoints.first {
            $0["checkpointID"] as? String == initialCheckpointID
        })
        guard initial.job["state"] as? String == "retrieving",
              initialCheckpoint["coordinatorState"] as? String == "retrieving",
              initialCheckpoint["jobID"] as? String == jobID else {
            throw task10CFailure("Save/reopen must observe active on-disk history before Pause.")
        }
        // An active fixture has no pauseContext yet. Pause must preserve its
        // verified current state as the future resume target.
        let resumeTarget = try XCTUnwrap(initial.job["state"] as? String)
        func verifySavedPause(_ observation: Task10SavedPackageObservation) throws {
            var verified = false
            defer {
                if !verified {
                    attachSaveObservation(observation, name: "rejected-pause-observation")
                }
            }
            let saved = try history(observation)
            guard saved.job["state"] as? String == "paused",
                  let pause = saved.job["pauseContext"] as? [String: Any],
                  pause["cause"] as? String == "pausedByUser",
                  pause["resumeTarget"] as? String == resumeTarget,
                  let currentID = saved.job["currentCheckpointID"] as? String,
                  currentID != initialCheckpointID else {
                let observedPause = saved.job["pauseContext"] as? [String: Any]
                throw task10CFailure(
                    "Save did not persist the exact user pause and resume target; "
                        + "state=\(String(describing: saved.job["state"])), "
                        + "pauseContextPresent=\(observedPause != nil), "
                        + "cause=\(String(describing: observedPause?["cause"])), "
                        + "resumeTarget=\(String(describing: observedPause?["resumeTarget"])), "
                        + "currentCheckpointID=\(String(describing: saved.job["currentCheckpointID"])); "
                        + "expected state=paused, cause=pausedByUser, resumeTarget=\(resumeTarget), "
                        + "checkpoint different from active baseline \(initialCheckpointID)."
                )
            }
            let current = saved.checkpoints.filter { $0["checkpointID"] as? String == currentID }
            guard current.count == 1, var child = current.first,
                  child["coordinatorState"] as? String == "paused" else {
                throw task10CFailure("The paused job does not own one current paused checkpoint.")
            }
            // Follow the saved successor chain back to the physically observed active baseline.
            // A matching pre-existing paused fixture or an unrelated checkpoint cannot satisfy it.
            for _ in 0..<saved.checkpoints.count {
                guard child["jobID"] as? String == jobID,
                      let parentID = child["parentCheckpointID"] as? String else { break }
                let parents = saved.checkpoints.filter { $0["checkpointID"] as? String == parentID }
                guard parents.count == 1, let parent = parents.first,
                      parent["jobID"] as? String == jobID,
                      let parentSHA256 = parent["canonicalSHA256"] as? String,
                      child["parentCheckpointSHA256"] as? String == parentSHA256,
                      let childRevision = child["revision"] as? Int,
                      let parentRevision = parent["revision"] as? Int,
                      parentRevision >= 0, childRevision > 0,
                      childRevision - 1 == parentRevision else { break }
                if parentID == initialCheckpointID {
                    guard NSDictionary(dictionary: parent).isEqual(to: initialCheckpoint) else { break }
                    verified = true
                    return
                }
                child = parent
            }
            throw task10CFailure("Saved Pause lacks a valid successor chain from the active checkpoint.")
        }
        func attachSaveObservation(_ observation: Task10SavedPackageObservation, name: String) {
            for (suffix, bytes) in [("manifest", observation.workspaceManifest),
                                    ("checkpoint-manifest", observation.checkpointManifest)] {
                let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.json")
                attachment.name = "SaveReopen-\(name)-\(suffix)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        attachSaveObservation(expectedPackage, name: "active-baseline")
        // This copied scenario contains fixture-only data. Retain its final
        // on-disk observation before the caller's fixture cleanup runs, even on failure.
        defer {
            do {
                let finalObservation = try Task10SavedPackageObservation.capture(
                    at: expectedPackage.packageURL
                )
                attachSaveObservation(finalObservation, name: "final-before-fixture-cleanup")
            } catch {
                let attachment = XCTAttachment(string:
                    "Final fixture package observation failed: \(error)"
                )
                attachment.name = "SaveReopen-final-observation-error"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        try exercisePauseFromActive(app: originalApp)
        let state = try requireElement(
            identified: "reconstruction.job.state",
            in: originalApp,
            timeout: 5,
            context: "the pre-save paused state"
        )
        try requireText(state, containing: "paused", timeout: 5, context: "pre-save Pause")
        let publication = try harness.saveOpenWorkspacePackage(
            matching: expectedPackage, in: originalApp, verifyContents: verifySavedPause
        )
        try verifySavedPause(publication.after)
        attachSaveObservation(publication.before, name: "before-explicit-save")
        attachSaveObservation(publication.after, name: "after-explicit-save")
        let generation = XCTAttachment(string:
            "File > Save package publication: device/inode "
                + "\(publication.before.rootIdentity.device)/\(publication.before.rootIdentity.inode) -> "
                + "\(publication.after.rootIdentity.device)/\(publication.after.rootIdentity.inode); "
                + "document \(publication.after.documentID); workspace \(publication.after.workspaceID)"
        )
        generation.name = "SaveReopen-explicit-save-physical-publication"
        generation.lifetime = .keepAlways
        add(generation)
        let reopenedApp = try harness.terminateRelaunchAndOpenWorkspace(
            fixture.packageURL,
            appearance: appearance
        )
        _ = try openReconstructionDashboard(harness: harness, fixture: fixture, app: reopenedApp)
        _ = try requireElement(
            identified: "reconstruction.dashboard",
            in: reopenedApp,
            timeout: 10,
            context: "the reopened Reconstruction dashboard"
        )
        let reopenedState = try requireElement(
            identified: "reconstruction.job.state",
            in: reopenedApp,
            timeout: 10,
            context: "the reopened durable state"
        )
        try requireText(reopenedState, containing: "paused", timeout: 10, context: "reopened Pause")
        let resume = try requireElement(
            identified: "reconstruction.resume",
            in: reopenedApp,
            timeout: 5,
            context: "Resume after durable projection restored"
        )
        try requireEnabled(resume, timeout: 10, context: "Resume after durable projection restored")
        resume.click()
        try requireText(
            reopenedState,
            containing: resumeTarget,
            timeout: 10,
            context: "the exact resume target after save and reopen"
        )
        return reopenedApp
    }

    func exerciseStaleCheckpoint(
        fixture: Task10InstalledScenarioFixtureCatalog.Fixture,
        app: XCUIApplication
    ) throws {
        XCTAssertEqual(fixture.expectedCheckpointFreshness, "stale")
        let notice = try requireElement(
            identified: "reconstruction.terminalNotice",
            in: app,
            timeout: 5,
            context: "the stale checkpoint notice"
        )
        try requireText(notice, containing: "Checkpoint is not current", timeout: 5, context: "stale checkpoint")
        for identifier in [
            "reconstruction.start", "reconstruction.pause", "reconstruction.resume",
            "reconstruction.cancel",
        ] {
            let control = try requireElement(
                identified: identifier,
                in: app,
                timeout: 5,
                context: "a stale-checkpoint control"
            )
            XCTAssertFalse(control.isEnabled, "Stale checkpoint left \(identifier) enabled.")
        }
        let primary = try requireElement(
            identified: "reconstruction.primaryAction",
            in: app,
            timeout: 5,
            context: "the stale primary action"
        )
        XCTAssertTrue(accessibilityText(of: primary).contains("Unavailable"))
    }

    func exerciseTaskEvidenceCounts(
        harness: InstalledAppUITestHarness,
        fixture: Task10InstalledScenarioFixtureCatalog.Fixture,
        app: XCUIApplication
    ) throws {
        let tasks = try requireElement(
            identified: "reconstruction.taskSummary",
            in: app,
            timeout: 5,
            context: "the task count summary"
        )
        let taskText = accessibilityText(of: tasks)
        XCTAssertTrue(
            taskText.contains("\(fixture.expectedTaskCount) completed"),
            "Task count was not accessible: \(taskText)"
        )
        let expectedValue = "\(fixture.expectedEvidenceCurrentCount) current, "
            + "\(fixture.expectedEvidenceHistoricalCount) historical, "
            + "\(fixture.expectedEvidenceStaleCount) stale, "
            + "\(fixture.expectedEvidenceUnavailableCount) unavailable"
        _ = try requireExactAccessibilityContract(
            harness: harness,
            identifier: "reconstruction.evidenceSummary",
            expectedWindowTitle: fixture.packageURL.deletingPathExtension().lastPathComponent,
            expected: Task10CAccessibilityContract(
                label: "Evidence summary",
                value: expectedValue,
                help: "Reports bounded current, historical, stale, and unavailable evidence "
                    + "counts for the selected job."
            ),
            context: "the exact evidence summary"
        )
    }

    func exerciseTerminalControls(app: XCUIApplication) throws {
        for identifier in [
            "reconstruction.start", "reconstruction.pause", "reconstruction.resume",
            "reconstruction.cancel",
        ] {
            let control = try requireElement(
                identified: identifier,
                in: app,
                timeout: 5,
                context: "a terminal Reconstruction control"
            )
            XCTAssertFalse(control.isEnabled, "Terminal state left \(identifier) enabled.")
        }
        let primary = try requireElement(
            identified: "reconstruction.primaryAction",
            in: app,
            timeout: 5,
            context: "the terminal primary action"
        )
        XCTAssertTrue(accessibilityText(of: primary).contains("Unavailable"))
    }

    func exerciseTwoWindowSelection(
        harness: InstalledAppUITestHarness,
        catalog: Task10InstalledScenarioFixtureCatalog,
        firstFixture: Task10InstalledScenarioFixtureCatalog.Fixture,
        app: XCUIApplication
    ) throws {
        let firstEvidence = try firstHittableButton(
            in: app,
            labelContaining: "evidence",
            context: "first-window evidence"
        )
        firstEvidence.click()
        let firstWindow = try focusedAccessibilityWindow(harness: harness)
        _ = try harness.waitForAccessibilityDescendant(
            identified: "reconstruction.inspector",
            of: firstWindow,
            depth: 10,
            timeout: 5,
            context: "the first-window Reconstruction inspector"
        )
        recordSuccessfulAccessibilityResolution("reconstruction.inspector")
        let firstDetails = try harness.waitForAccessibilityDescendant(
            identified: "reconstruction.details",
            of: firstWindow,
            depth: 10,
            timeout: 5,
            context: "first-window details"
        )
        recordSuccessfulAccessibilityResolution("reconstruction.details")
        let firstSelection = try XCTUnwrap(
            harness.accessibilityString(attribute: kAXValueAttribute as CFString, of: firstDetails)
        )

        let secondFixture = try catalog.copyScenario("navigation-current")
        let secondFixtureCleanup = registerTask10Cleanup { secondFixture.remove() }
        defer { try? secondFixtureCleanup.perform() }
        app.typeKey("n", modifierFlags: .command)
        guard waitUntil(timeout: 10, predicate: { app.windows.count >= 2 }) else {
            throw task10CFailure("New Window did not create an independent document window.")
        }
        try harness.openWorkspacePackage(secondFixture.packageURL, in: app)
        _ = try openReconstructionDashboard(harness: harness, fixture: secondFixture, app: app)
        let secondTask = try firstHittableButton(
            in: app,
            labelContaining: "task",
            context: "second-window task"
        )
        secondTask.click()
        let secondWindow = try focusedAccessibilityWindow(harness: harness)
        _ = try harness.waitForAccessibilityDescendant(
            identified: "reconstruction.inspector",
            of: secondWindow,
            depth: 10,
            timeout: 5,
            context: "the second-window Reconstruction inspector"
        )
        let secondDetails = try harness.waitForAccessibilityDescendant(
            identified: "reconstruction.details",
            of: secondWindow,
            depth: 10,
            timeout: 5,
            context: "second-window details"
        )
        let secondSelection = try XCTUnwrap(
            harness.accessibilityString(attribute: kAXValueAttribute as CFString, of: secondDetails)
        )
        XCTAssertNotEqual(firstSelection, secondSelection)

        XCTAssertEqual(
            AXUIElementPerformAction(firstWindow, kAXRaiseAction as CFString),
            .success,
            "The first owned document window could not be raised."
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(
            harness.accessibilityString(attribute: kAXValueAttribute as CFString, of: firstDetails),
            firstSelection,
            "The second window mutated the first window's evidence selection."
        )
        XCTAssertEqual(
            harness.accessibilityString(attribute: kAXValueAttribute as CFString, of: secondDetails),
            secondSelection,
            "Raising the first window mutated the second window's task selection."
        )
        XCTAssertTrue(firstFixture.expectedEvidenceCount > 0)
    }

    func openCreationSheet(in app: XCUIApplication) throws {
        let create = try requireElement(
            identified: "reconstruction.create",
            in: app,
            timeout: 5,
            context: "Create"
        )
        try requireEnabled(create, context: "Create")
        create.click()
        _ = try requireElement(
            identified: "reconstruction.creation.sheet",
            in: app,
            timeout: 5,
            context: "the creation sheet"
        )
    }

    func enterObjective(_ objective: String, in app: XCUIApplication) throws {
        let field = try requireElement(
            identified: "reconstruction.creation.objective",
            in: app,
            timeout: 5,
            context: "the creation objective"
        )
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(objective)
    }

    func requireExactAccessibilityContract(
        harness: InstalledAppUITestHarness,
        identifier: String,
        expectedWindowTitle: String,
        expected: Task10CAccessibilityContract,
        context: String
    ) throws -> AXUIElement {
        let window = try harness.waitForFocusedWindow(
            titled: expectedWindowTitle,
            timeout: 10,
            context: "the exact fixture window for \(context)"
        )
        let element = try harness.waitForAccessibilityDescendant(
            identified: identifier,
            of: window,
            depth: 14,
            timeout: 10,
            context: context
        )
        let diagnostic = harness.accessibilityWindowDiagnostic(
            identified: identifier,
            expectedWindowTitle: expectedWindowTitle,
            window: window,
            selectedElement: element
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let attachment = XCTAttachment(
            data: try encoder.encode(diagnostic),
            uniformTypeIdentifier: "public.json"
        )
        attachment.name = "MacScope.Task10.RawAX.\(identifier).v1.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        let description = harness.accessibilityString(
            attribute: kAXDescriptionAttribute as CFString,
            of: element
        )
        let title = harness.accessibilityString(
            attribute: kAXTitleAttribute as CFString,
            of: element
        )
        XCTAssertEqual(
            description ?? title,
            expected.label,
            "\(context) label drifted."
        )
        XCTAssertEqual(
            harness.accessibilityString(
                attribute: kAXValueAttribute as CFString,
                of: element
            ),
            expected.value,
            "\(context) value drifted."
        )
        XCTAssertEqual(
            harness.accessibilityString(
                attribute: kAXHelpAttribute as CFString,
                of: element
            ),
            expected.help,
            "\(context) help drifted."
        )
        recordSuccessfulAccessibilityResolution(identifier)
        return element
    }

    func packageContainsUTF8Canary(_ canary: String, at packageURL: URL) throws -> Bool {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: packageURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw task10CFailure("The privacy fixture package could not be enumerated.")
        }
        let needle = Data(canary.utf8)
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            if try Data(contentsOf: fileURL).range(of: needle) != nil {
                return true
            }
        }
        return false
    }

    func packageTreeSHA256(at packageURL: URL) throws -> String {
        let paths = try FileManager.default.subpathsOfDirectory(atPath: packageURL.path).sorted()
        var hasher = SHA256()
        for path in paths {
            let fileURL = packageURL.appendingPathComponent(path)
            let values = try fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: try Data(contentsOf: fileURL))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func requireElement(
        identified identifier: String,
        in root: XCUIElement,
        timeout: TimeInterval,
        context: String
    ) throws -> XCUIElement {
        let element = root.descendants(matching: .any)[identifier]
        guard element.waitForExistence(timeout: timeout) else {
            throw task10CFailure("Installed accessibility did not expose \(context) (\(identifier)).")
        }
        recordSuccessfulAccessibilityResolution(identifier)
        return element
    }

    func recordSuccessfulAccessibilityResolution(_ identifier: String) {
        guard var observation = activeTask10AccessibilityObservation,
              observation.scenario.requiredAccessibilityIdentifiers.contains(identifier) else {
            return
        }
        observation.observedIdentifiers.insert(identifier)
        activeTask10AccessibilityObservation = observation
    }

    func attachTask10AccessibilityObservation() throws {
        guard let observation = activeTask10AccessibilityObservation else {
            throw task10CFailure("The Task 10 accessibility observation was not initialized.")
        }
        let required = observation.scenario.requiredAccessibilityIdentifiers
        guard observation.observedIdentifiers == required else {
            let missing = required.subtracting(observation.observedIdentifiers).sorted()
            let unexpected = observation.observedIdentifiers.subtracting(required).sorted()
            throw task10CFailure(
                "Task 10 accessibility observation is incomplete; missing=\(missing), "
                    + "unexpected=\(unexpected)."
            )
        }
        let value = Task10CAccessibilityObservationAttachment(
            vectorID: "xcui.\(observation.scenario.rawValue)",
            testIdentifier: observation.scenario.testIdentifier,
            observedIdentifiers: observation.observedIdentifiers.sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let attachment = XCTAttachment(
            data: try encoder.encode(value),
            uniformTypeIdentifier: "public.json"
        )
        attachment.name = "MacScope.Task10.AccessibilityObservation.v1.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func requireEnabled(
        _ element: XCUIElement,
        timeout: TimeInterval = 5,
        context: String
    ) throws {
        guard waitUntil(timeout: timeout, predicate: { element.exists && element.isEnabled }) else {
            throw task10CFailure("Installed \(context) did not become enabled.")
        }
    }

    func requireSelectedAndKeyboardFocused(
        _ element: XCUIElement,
        identified identifier: String,
        harness: InstalledAppUITestHarness,
        timeout: TimeInterval = 5,
        context: String
    ) throws {
        let accessibilityElement = try harness.waitForAccessibilityDescendant(
            identified: identifier,
            of: harness.accessibilityApplication(timeout: timeout),
            depth: 12,
            timeout: timeout,
            context: context
        )
        guard waitUntil(timeout: timeout, predicate: {
            element.exists && element.isSelected && accessibilityFocused(accessibilityElement)
        }) else {
            throw task10CFailure(
                "Installed \(context) did not expose selected AX state and keyboard focus; "
                    + "selected=\(element.isSelected), focused=\(accessibilityFocused(accessibilityElement)), "
                    + "value=\(String(describing: element.value))."
            )
        }
    }

    func requireRadioSelection(_ element: XCUIElement, context: String) throws {
        let value = element.value
        // XCUIElement.value is untyped. Native radio controls may expose AXValue
        // as NSNumber rather than String; only the exact selected value qualifies.
        let selected: Bool
        if let number = value as? NSNumber {
            selected = number == NSNumber(value: 1)
        } else {
            selected = (value as? String) == "1"
        }
        guard selected else {
            throw task10CFailure(
                "Installed \(context) was not selected; AX value="
                    + String(describing: value) + ", type="
                    + (value.map { String(reflecting: type(of: $0)) } ?? "nil") + "."
            )
        }
    }

    func accessibilityFocused(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            &value
        ) == .success else {
            return false
        }
        return (value as? NSNumber)?.boolValue == true
    }

    func requireText(
        _ element: XCUIElement,
        containing expected: String,
        timeout: TimeInterval,
        context: String
    ) throws {
        guard waitUntil(timeout: timeout, predicate: {
            self.accessibilityText(of: element)
                .localizedCaseInsensitiveContains(expected)
        }) else {
            throw task10CFailure(
                "Installed \(context) did not expose \(expected); observed "
                    + self.accessibilityText(of: element)
            )
        }
    }

    func accessibilityText(of element: XCUIElement) -> String {
        var components = [element.label, element.placeholderValue ?? ""]
        if let value = element.value as? String { components.append(value) }
        for descendant in element.descendants(matching: .any).allElementsBoundByIndex.prefix(96) {
            components.append(descendant.label)
            if let value = descendant.value as? String { components.append(value) }
        }
        return components.filter { !$0.isEmpty }.joined(separator: " | ")
    }

    func firstHittableButton(
        in app: XCUIApplication,
        labelContaining fragment: String,
        context: String
    ) throws -> XCUIElement {
        let query = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", fragment)
        )
        guard waitUntil(timeout: 5, predicate: {
            query.allElementsBoundByIndex.contains(where: \.isHittable)
        }), let button = query.allElementsBoundByIndex.first(where: \.isHittable) else {
            throw task10CFailure("Installed accessibility did not expose \(context).")
        }
        return button
    }

    func focusedAccessibilityWindow(
        harness: InstalledAppUITestHarness
    ) throws -> AXUIElement {
        let application = try harness.accessibilityApplication()
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &value
        )
        guard result == .success, let value else {
            throw task10CFailure("Accessibility did not expose the focused MacScope window.")
        }
        return value as! AXUIElement
    }
}

@MainActor
private func waitUntil(timeout: TimeInterval, predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if predicate() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    return predicate()
}

private func task10CFailure(_ message: String) -> NSError {
    NSError(
        domain: "MacScopeInstalledAppUITests.Task10C",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}
