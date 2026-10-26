import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import XCTest

/// Test-side mirror of the product barrier fence; the UI runner does not link product code.
private enum InstalledQualificationBarrierRoot {
    static var runnerTemporaryDirectory: URL? {
        var account = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        let home: String? = buffer.withUnsafeMutableBufferPointer { storage in
            guard getpwuid_r(getuid(), &account, storage.baseAddress, storage.count, &result) == 0,
                  result != nil, let directory = account.pw_dir else { return nil }
            return String(cString: directory)
        }
        guard let home, home.hasPrefix("/"), home != "/" else { return nil }
        return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(
            "Library/Containers/org.macscope.app.MacScopeInstalledAppUITests.xctrunner/Data/tmp",
            isDirectory: true
        )
    }

    private static func openPhysicalDirectory(_ path: String) -> Int32? {
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        for component in path.split(separator: "/") {
            let next = String(component).withCString {
                Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            Darwin.close(descriptor)
            guard next >= 0 else { return nil }
            descriptor = next
        }
        return descriptor
    }

    static func openOwnedRunnerParent(_ path: String) -> Int32? {
        guard path == runnerTemporaryDirectory?.path,
              let descriptor = openPhysicalDirectory(path) else { return nil }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_uid == getuid(), metadata.st_mode & 0o7777 == 0o700 else {
            Darwin.close(descriptor)
            return nil
        }
        return descriptor
    }

    static func openOwnedRoot(_ path: String, prefix: String) -> Int32? {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let name = root.lastPathComponent
        let parent = root.deletingLastPathComponent().path
        guard !path.utf8.contains(0), path == parent + "/" + name,
              prefix == "MacScope-Task10-PauseBarrier-" || prefix == "MacScope-Task10-RevealBarrier-",
              name.hasPrefix(prefix), name.count == prefix.count + 36,
              UUID(uuidString: String(name.dropFirst(prefix.count))) != nil,
              parent == "/private/tmp" || parent == runnerTemporaryDirectory?.path else { return nil }
        let openedParent = parent == "/private/tmp"
            ? openPhysicalDirectory(parent) : openOwnedRunnerParent(parent)
        guard let parentDescriptor = openedParent else { return nil }
        defer { Darwin.close(parentDescriptor) }
        var before = stat()
        guard name.withCString({ Darwin.fstatat(parentDescriptor, $0, &before, AT_SYMLINK_NOFOLLOW) }) == 0,
              before.st_mode & S_IFMT == S_IFDIR,
              before.st_uid == getuid(), before.st_mode & 0o7777 == 0o700 else { return nil }
        let descriptor = name.withCString {
            Darwin.openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return nil }
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              opened.st_dev == before.st_dev, opened.st_ino == before.st_ino,
              opened.st_uid == before.st_uid,
              opened.st_mode & S_IFMT == S_IFDIR, opened.st_mode & 0o7777 == 0o700 else {
            Darwin.close(descriptor)
            return nil
        }
        return descriptor
    }
}

/// The one entry point for UI automation that drives an installed MacScope product.
///
/// Construction is intentionally guarded: callers must explicitly opt in, and the selected
/// bundle must carry qualification-eligible Release provenance. The resulting value captures
/// the exact executable path and digest so every later process, menu, lifecycle, and screenshot
/// operation remains bound to that candidate rather than to whichever app happens to share the
/// product bundle identifier.
@MainActor
final class InstalledAppUITestHarness {
    enum Appearance: String, CaseIterable {
        case automatic = "auto"
        case light
        case dark
    }

    enum WindowSize: String, CaseIterable {
        case minimum
        case wide

        var size: CGSize {
            switch self {
            case .minimum:
                return CGSize(width: 1_080, height: 680)
            case .wide:
                return CGSize(width: 1_440, height: 840)
            }
        }

        /// `.minimum` is the product's governed content minimum (`MacScopeApp` applies
        /// `.frame(minWidth: 1080, minHeight: 680)` to the workspace root). The hidden-titlebar
        /// window keeps the native titlebar safe area above that root, so the smallest outer
        /// window is taller than 680 points (installed evidence has recorded 1080x712 since
        /// WS-14). Settlement for this size therefore allows exactly one titlebar of extra outer
        /// height and requires the workspace root to fill that window rather than overflow it.
        var settlesOnWorkspaceContent: Bool {
            self == .minimum
        }
    }

    static let workspaceRootAccessibilityIdentifier = "workspace.root"

    struct CandidateIdentity: Equatable {
        let sourceCommit: String
        let executableSHA256: String
    }

    /// A bounded scan must disclose whether it stopped before proving that every
    /// user-visible AX string surface was examined. Privacy checks treat that state as refusal,
    /// never as evidence that a canary is absent.
    struct BoundedAccessibilityAttributeStrings {
        let strings: [String]
        let wasTruncated: Bool
        let wasIncomplete: Bool
    }

    struct AccessibilityAttributeObservation: Encodable {
        let attribute: String
        let status: Int32
        let returnedTypeID: UInt?
        let returnedTypeName: String?
        let stringValue: String?
        let stringWasTruncated: Bool
    }

    struct AccessibilityElementObservation: Encodable {
        let processIdentifier: Int32?
        let processIdentifierStatus: Int32
        let attributes: [AccessibilityAttributeObservation]
    }

    struct AccessibilityWindowDiagnostic: Encodable {
        let schemaVersion = 1
        let expectedWindowTitle: String
        let identifier: String
        let requestWasTruncated: Bool
        let window: AccessibilityElementObservation
        let selectedElement: AccessibilityElementObservation
        let matchingElements: [AccessibilityElementObservation]
        let observedMatchingElementCount: Int
        let visitedElementCount: Int
        let wasTruncated: Bool
        let wasIncomplete: Bool
    }

    enum AccessibilityCharacterVisibility {
        case unsupported
        case visibleRange(CFRange)
    }

    private struct ReleaseProvenance: Decodable {
        let qualificationEligible: Bool?
        let repositoryClean: Bool?
        let configuration: String?
        let gitHeadCommit: String?

        private enum CodingKeys: String, CodingKey {
            case qualificationEligible = "qualification_eligible"
            case repositoryClean = "repository_clean"
            case configuration
            case gitHeadCommit = "git_head_commit"
        }
    }

    private static let bundleIdentifier = "org.macscope.app"
    private static let optInEnvironmentKey = "MACSCOPE_WS24_RUN_INSTALLED_XCUITEST"
    private static let installedAppEnvironmentKey = "MACSCOPE_WS24_INSTALLED_APP"
    private static let optInFlagPath = "/tmp/MacScope-WS24-run-installed-xcuitest"
    private static let appearancePreferenceKey = "appAppearancePreference"
    private static let reconstructionPauseBarrierRootEnvironmentKey =
        "MACSCOPE_WS24_RECONSTRUCTION_PAUSE_BARRIER_ROOT"
    private static let reconstructionPauseCandidateSHA256EnvironmentKey =
        "MACSCOPE_WS24_RECONSTRUCTION_PAUSE_CANDIDATE_SHA256"
    private static let reconstructionRevealBarrierRootEnvironmentKey =
        "MACSCOPE_WS24_RECONSTRUCTION_REVEAL_BARRIER_ROOT"
    private static let reconstructionRevealCandidateSHA256EnvironmentKey =
        "MACSCOPE_WS24_RECONSTRUCTION_REVEAL_CANDIDATE_SHA256"
    private static let approvedLaunchEnvironmentKeys = Set([
        reconstructionPauseBarrierRootEnvironmentKey,
        reconstructionPauseCandidateSHA256EnvironmentKey,
        reconstructionRevealBarrierRootEnvironmentKey,
        reconstructionRevealCandidateSHA256EnvironmentKey,
    ])

    private(set) var preferenceSuiteName = "org.macscope.app.tests." + UUID().uuidString
    private var retiredPreferenceSuiteNames: [String] = []

    /// A fresh name, rather than a cross-process delete, also isolates sandboxed runners.
    func beginIsolatedProviderPreferenceScope() {
        retiredPreferenceSuiteNames.append(preferenceSuiteName)
        preferenceSuiteName = "org.macscope.app.tests." + UUID().uuidString
    }

    func removeIsolatedProviderPreferences() {
        for name in retiredPreferenceSuiteNames + [preferenceSuiteName] {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
    }

    deinit {
        for name in retiredPreferenceSuiteNames + [preferenceSuiteName] {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
    }

    let installedAppURL: URL
    let executableURL: URL
    let identity: CandidateIdentity

    private let provenanceURL: URL

    private init(
        installedAppURL: URL,
        executableURL: URL,
        provenanceURL: URL,
        identity: CandidateIdentity
    ) {
        self.installedAppURL = installedAppURL
        self.executableURL = executableURL
        self.provenanceURL = provenanceURL
        self.identity = identity
    }

    /// Resolves and freezes the exact installed candidate before any app-driving operation.
    /// The explicit environment/flag opt-in remains the unattended-run safety boundary.
    static func requireOptedInCandidate() throws -> InstalledAppUITestHarness {
        let environment = ProcessInfo.processInfo.environment
        let isOptedIn = environment[Self.optInEnvironmentKey] == "1"
            || FileManager.default.fileExists(atPath: Self.optInFlagPath)
        guard isOptedIn else {
            throw XCTSkip(
                "Set \(Self.optInEnvironmentKey)=1 or create \(Self.optInFlagPath) "
                    + "to run installed-app XCUITest automation."
            )
        }

        let selectedPath = environment[Self.installedAppEnvironmentKey]
            ?? "/Applications/MacScope.app"
        let installedAppURL = URL(fileURLWithPath: selectedPath, isDirectory: true)
            .standardizedFileURL
        let executableURL = installedAppURL.appendingPathComponent("Contents/MacOS/MacScope")
        let provenanceURL = installedAppURL.appendingPathComponent(
            "Contents/Resources/MacScopeBuildProvenance.json"
        )

        guard Self.isDirectory(installedAppURL) else {
            throw Self.harnessError("Installed MacScope.app bundle is missing.")
        }
        guard Self.isRegularFile(executableURL) else {
            throw Self.harnessError("Installed MacScope executable is missing.")
        }
        guard Self.isRegularFile(provenanceURL) else {
            throw Self.harnessError("Installed Release provenance is missing.")
        }

        let provenance = try Self.decodeProvenance(at: provenanceURL)
        guard provenance.qualificationEligible == true else {
            throw Self.harnessError("Installed Release provenance is not qualification eligible.")
        }
        guard provenance.repositoryClean == true else {
            throw Self.harnessError("Installed Release provenance does not record a clean repository.")
        }
        guard provenance.configuration == "Release" else {
            throw Self.harnessError("Installed app was not built with the Release configuration.")
        }
        guard let sourceCommit = provenance.gitHeadCommit, sourceCommit.count == 40 else {
            throw Self.harnessError(
                "Installed app provenance must bind the UI scenario to an exact source commit."
            )
        }

        let executableSHA256 = try Self.sha256Hex(of: executableURL)
        guard executableSHA256.count == 64 else {
            throw Self.harnessError("Installed executable SHA-256 has an invalid shape.")
        }

        return InstalledAppUITestHarness(
            installedAppURL: installedAppURL,
            executableURL: executableURL,
            provenanceURL: provenanceURL,
            identity: CandidateIdentity(
                sourceCommit: sourceCommit,
                executableSHA256: executableSHA256
            )
        )
    }

    /// Re-hashes the bundle inputs that established this harness. This prevents a long matrix
    /// from silently crossing from one installed candidate to another at the same filesystem path.
    func assertCandidateIdentityIsUnchanged() throws {
        guard Self.isRegularFile(executableURL), Self.isRegularFile(provenanceURL) else {
            throw Self.harnessError("The selected installed candidate disappeared during qualification.")
        }
        let provenance = try Self.decodeProvenance(at: provenanceURL)
        guard provenance.gitHeadCommit == identity.sourceCommit else {
            throw Self.harnessError(
                "Installed candidate provenance changed during qualification; expected "
                    + "\(identity.sourceCommit), observed \(provenance.gitHeadCommit ?? "nil")."
            )
        }
        let observedDigest = try Self.sha256Hex(of: executableURL)
        guard observedDigest == identity.executableSHA256 else {
            throw Self.harnessError(
                "Installed candidate executable changed during qualification; expected "
                    + "\(identity.executableSHA256), observed \(observedDigest)."
            )
        }
    }

    /// Launches by exact bundle URL and then proves that the resulting process executable is the
    /// candidate captured by the opt-in guard. Passing nil preserves the user's normal appearance;
    /// explicit Light/Dark runs use the product's own AppStorage preference key.
    func launch(
        appearance: Appearance? = nil,
        launchEnvironment: [String: String] = [:]
    ) throws -> XCUIApplication {
        try assertCandidateIdentityIsUnchanged()
        try assertNoForeignRunningApplication()
        let app = XCUIApplication(url: installedAppURL)
        app.launchEnvironment[Self.optInEnvironmentKey] = "1"
        app.launchEnvironment["MACSCOPE_TEST_PREFERENCES_SUITE"] = preferenceSuiteName
        app.launchEnvironment["MACSCOPE_TEST_MODE_BASELINE"] = "1"
        for (key, value) in try Self.validatedLaunchEnvironment(launchEnvironment) {
            app.launchEnvironment[key] = value
        }
        if let appearance {
            app.launchArguments += ["-\(Self.appearancePreferenceKey)", appearance.rawValue]
        }
        app.launch()

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15)
                || app.wait(for: .runningBackground, timeout: 5),
            "Installed MacScope.app did not reach a running state."
        )
        let runningApplication = try requireRunningCandidate(
            timeout: 10,
            context: "the XCUITest launch"
        )
        XCTAssertEqual(
            runningApplication.executableURL?.path,
            executableURL.path,
            "XCUITest resolved bundle identifier \(Self.bundleIdentifier) to an unexpected executable."
        )
        return app
    }

    /// XCUITest may resolve a same-ID process before using the requested URL.
    /// Refuse that collision without acquiring authority to stop another app.
    private func assertNoForeignRunningApplication() throws {
        let applications = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.bundleIdentifier)
        guard applications.count <= 64 else {
            throw Self.harnessError("Installed-app launch refused: bundle-ID census exceeds its bound.")
        }
        for runningApplication in applications {
            let pid = runningApplication.processIdentifier
            let path = runningApplication.executableURL?.path
            guard pid > 0, path == executableURL.path else {
                throw Self.harnessError(
                    "Installed-app launch refused: foreign or unknown \(Self.bundleIdentifier) "
                        + "PID \(pid) path=\(path ?? "unknown"); expected \(executableURL.path)."
                )
            }
        }
    }

    private static func validatedLaunchEnvironment(
        _ environment: [String: String]
    ) throws -> [String: String] {
        for (key, value) in environment {
            guard !key.isEmpty,
                  key.unicodeScalars.allSatisfy({ scalar in
                      scalar.isASCII
                          && (CharacterSet.uppercaseLetters.contains(scalar)
                              || CharacterSet.decimalDigits.contains(scalar)
                              || scalar == "_")
                  }),
                  key.hasPrefix("MACSCOPE_"),
                  approvedLaunchEnvironmentKeys.contains(key) else {
                throw harnessError("Installed-app launch environment key is not approved: \(key)")
            }
            guard !value.isEmpty,
                  !value.contains("\0"),
                  !value.contains("\n"),
                  !value.contains("\r") else {
                throw harnessError("Installed-app launch environment value is malformed.")
            }

            if key == reconstructionPauseBarrierRootEnvironmentKey
                || key == reconstructionRevealBarrierRootEnvironmentKey {
                let requiredPrefix = key == reconstructionPauseBarrierRootEnvironmentKey
                    ? "MacScope-Task10-PauseBarrier-"
                    : "MacScope-Task10-RevealBarrier-"
                guard let descriptor = InstalledQualificationBarrierRoot.openOwnedRoot(
                    value, prefix: requiredPrefix
                ) else {
                    throw harnessError(
                        "Installed qualification barrier root must be an owned canonical "
                            + "directory under an approved physical temporary parent."
                    )
                }
                Darwin.close(descriptor)
            }

            if key == reconstructionPauseCandidateSHA256EnvironmentKey
                || key == reconstructionRevealCandidateSHA256EnvironmentKey {
                guard value.count == 64,
                      value.unicodeScalars.allSatisfy({ scalar in
                          (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
                      }) else {
                    throw harnessError(
                        "Installed qualification barrier candidate SHA-256 is malformed."
                    )
                }
            }
        }
        return environment
    }

    static func createQualificationBarrierRoot(prefix: String) throws -> URL {
        let observed = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        guard let expected = InstalledQualificationBarrierRoot.runnerTemporaryDirectory,
              observed.path == expected.path,
              prefix == "MacScope-Task10-PauseBarrier-" || prefix == "MacScope-Task10-RevealBarrier-",
              let parent = InstalledQualificationBarrierRoot.openOwnedRunnerParent(expected.path) else {
            throw harnessError("The installed runner temporary directory did not match its owned container.")
        }
        defer { Darwin.close(parent) }
        let name = prefix + UUID().uuidString
        guard name.withCString({ Darwin.mkdirat(parent, $0, mode_t(0o700)) }) == 0 else {
            throw harnessError("The installed qualification barrier could not be created exactly once.")
        }
        let root = observed.appendingPathComponent(name, isDirectory: true)
        guard let descriptor = InstalledQualificationBarrierRoot.openOwnedRoot(root.path, prefix: prefix) else {
            _ = name.withCString { Darwin.unlinkat(parent, $0, AT_REMOVEDIR) }
            throw harnessError("The newly created qualification barrier failed ownership validation.")
        }
        Darwin.close(descriptor)
        return root
    }

    /// Returns only a process whose bundle identifier and exact executable path both match the
    /// frozen candidate. Bundle-identifier-only lookup is deliberately never exposed.
    func runningCandidate(timeout: TimeInterval) -> NSRunningApplication? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let match = NSRunningApplication
                .runningApplications(withBundleIdentifier: Self.bundleIdentifier)
                .first(where: { $0.executableURL?.path == executableURL.path }) {
                return match
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return nil
    }

    func requireRunningCandidate(
        timeout: TimeInterval,
        context: String
    ) throws -> NSRunningApplication {
        try XCTUnwrap(
            runningCandidate(timeout: timeout),
            "The exact installed candidate was not running during \(context)."
        )
    }

    /// Terminates only the process resolved by the frozen candidate's executable path. If a normal
    /// termination does not complete, the fallback is still bounded to the same captured PID and
    /// executable; no bundle-wide or process-name-wide signal is ever sent.
    func terminateExactCandidateIfRunning(timeout: TimeInterval = 5) {
        guard let runningApplication = runningCandidate(timeout: 0) else { return }
        let processIdentifier = runningApplication.processIdentifier
        let expectedExecutablePath = executableURL.path

        _ = runningApplication.terminate()
        if Self.waitForTermination(
            of: runningApplication,
            processIdentifier: processIdentifier,
            timeout: timeout
        ) {
            return
        }

        guard runningApplication.processIdentifier == processIdentifier,
              runningApplication.executableURL?.path == expectedExecutablePath else {
            XCTFail("Installed-app cleanup lost the exact candidate process identity.")
            return
        }
        _ = runningApplication.forceTerminate()
        XCTAssertTrue(
            Self.waitForTermination(
                of: runningApplication,
                processIdentifier: processIdentifier,
                timeout: timeout
            ),
            "Exact installed candidate PID \(processIdentifier) did not terminate during cleanup."
        )
    }

    /// Proves the product's real termination path completed for a lifecycle qualification.
    /// Unlike cleanup, this must never force-kill a candidate that refused or hung during normal
    /// termination, because doing so would turn a broken persistence fence into a false green.
    func terminateExactCandidateGracefully(timeout: TimeInterval = 10) throws {
        let runningApplication = try requireRunningCandidate(
            timeout: 0,
            context: "graceful lifecycle termination"
        )
        let processIdentifier = runningApplication.processIdentifier
        guard runningApplication.terminate() else {
            throw Self.harnessError(
                "Exact installed candidate PID \(processIdentifier) refused normal termination."
            )
        }
        guard Self.waitForTermination(
            of: runningApplication,
            processIdentifier: processIdentifier,
            timeout: timeout
        ) else {
            throw Self.harnessError(
                "Exact installed candidate PID \(processIdentifier) did not complete normal termination."
            )
        }
    }

    /// Drives the shipping File ▸ Open Workspace command and the standard Open panel. It does not
    /// inject an open request, add a launch argument, or mutate a workspace outside the app.
    func openWorkspacePackage(_ packageURL: URL, in app: XCUIApplication) throws {
        try assertCandidateIdentityIsUnchanged()
        let runningApplication = try requireRunningCandidate(
            timeout: 10,
            context: "File ▸ Open Workspace"
        )
        try chooseFileThroughOpenPanel(
            packageURL,
            in: app,
            runningApplication: runningApplication,
            commandTitle: "Open Workspace...",
            context: "File ▸ Open Workspace"
        )
    }

    /// Drives the shipping File ▸ Open Binary command and standard file importer. The exact
    /// installed candidate and user-selected filesystem URL remain the only authorities; this
    /// helper never injects a store request or launch argument.
    func openBinary(_ binaryURL: URL, in app: XCUIApplication) throws {
        try assertCandidateIdentityIsUnchanged()
        let runningApplication = try requireRunningCandidate(
            timeout: 10,
            context: "File ▸ Open Binary"
        )
        try chooseFileThroughOpenPanel(
            binaryURL,
            in: app,
            runningApplication: runningApplication,
            commandTitle: "Open Binary...",
            context: "File ▸ Open Binary"
        )
    }

    private func chooseFileThroughOpenPanel(
        _ fileURL: URL,
        in app: XCUIApplication,
        runningApplication: NSRunningApplication,
        commandTitle: String,
        context: String
    ) throws {
        try performFileMenuCommand(
            titled: commandTitle,
            in: runningApplication,
            context: context
        )

        // NSOpenPanel is a dialog on the current macOS SDK and can be a sheet when
        // attached to a document. Bind the native panel's identity inside this exact
        // candidate, rather than assuming one presentation role.
        let dialog = app.dialogs["open-panel"]
        let openPanel = dialog.waitForExistence(timeout: 5)
            ? dialog
            : app.sheets["open-panel"]
        XCTAssertTrue(
            openPanel.waitForExistence(timeout: 10),
            "\(context) did not present its standard Open panel."
        )
        app.typeKey("g", modifierFlags: [.command, .shift])
        let goToFolderSheet = app.sheets.firstMatch
        XCTAssertTrue(
            goToFolderSheet.waitForExistence(timeout: 10),
            "The Open panel did not present Go to Folder."
        )
        let pathField = app.textFields.matching(
            NSPredicate(format: "hasKeyboardFocus == true")
        ).firstMatch
        XCTAssertTrue(
            pathField.waitForExistence(timeout: 10),
            "The Open panel did not focus the Go to Folder path field."
        )
        pathField.click()
        pathField.typeKey("a", modifierFlags: .command)
        pathField.typeText(fileURL.path)
        pathField.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(
            goToFolderSheet.waitForNonExistence(timeout: 10),
            "Go to Folder did not finish selecting the requested workspace package."
        )

        XCTAssertTrue(
            openPanel.waitForExistence(timeout: 10),
            "The Open panel disappeared before the requested file could be selected."
        )
        let openButton = openPanel.buttons["Open"]
        XCTAssertTrue(openButton.waitForExistence(timeout: 10), "The Open panel had no Open action.")
        XCTAssertTrue(
            openButton.isEnabled,
            "Go to Folder did not select the requested file."
        )
        openButton.click()
    }

    /// Uses the production File ▸ Save command for an already-open workspace package.
    func saveOpenWorkspace() throws {
        try assertCandidateIdentityIsUnchanged()
        let runningApplication = try requireRunningCandidate(timeout: 10, context: "File ▸ Save")
        let application = AXUIElementCreateApplication(runningApplication.processIdentifier)
        let documentWindow = try Self.accessibilityElement(
            attribute: kAXFocusedWindowAttribute as CFString,
            of: application,
            context: "the focused document window before File ▸ Save"
        )
        guard try Task10DocumentEditedReader.read(
            window: documentWindow, expectedPID: runningApplication.processIdentifier
        ) else {
            throw Self.accessibilityError(
                "The focused document window was not marked edited before File ▸ Save; "
                    + "refusing to claim that Save persisted a new workspace state."
            )
        }
        try performFileMenuCommand(
            titled: "Save",
            in: runningApplication,
            context: "File ▸ Save"
        )
        let deadline = Date().addingTimeInterval(10)
        repeat {
            if try !Task10DocumentEditedReader.read(
                window: documentWindow, expectedPID: runningApplication.processIdentifier
            ) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        throw Self.accessibilityError(
            "The focused document window remained edited after File ▸ Save; "
                + "refusing to terminate before production save completion."
        )
    }

    /// Create can already be clean after normal autosave. Its separate save contract requires
    /// a new physical publication, not a dirty-dot transition or pre-existing package bytes.
    /// The caller holds further automated writes and verifies the exact canonical job history.
    func saveOpenWorkspacePackage(
        matching expectedPackage: Task10SavedPackageObservation,
        in app: XCUIApplication,
        verifyContents: (Task10SavedPackageObservation) throws -> Void
    ) throws -> (before: Task10SavedPackageObservation, after: Task10SavedPackageObservation) {
        try assertCandidateIdentityIsUnchanged()
        let running = try requireRunningCandidate(timeout: 10, context: "package-aware File ▸ Save")
        let application = AXUIElementCreateApplication(running.processIdentifier)
        let title = expectedPackage.packageURL.deletingPathExtension().lastPathComponent
        let documentWindow = try Self.waitForFocusedWindow(
            titled: title, in: application, timeout: 5, context: "the exact package document before Save"
        )

        func requireFocusedDocument() throws -> Bool {
            guard !running.isTerminated else {
                throw Self.harnessError("The exact candidate terminated during package-aware Save.")
            }
            let current = try Self.accessibilityElement(
                attribute: kAXFocusedWindowAttribute as CFString,
                of: application, context: "the exact package document during Save"
            )
            guard CFEqual(current, documentWindow), Self.accessibilityTitle(of: current) == title,
                  try hasAccessibilityDescendant(
                    identified: Self.workspaceRootAccessibilityIdentifier, of: current, depth: 10
                  ) else {
                throw Self.accessibilityError("Package-aware Save lost its exact workspace window.")
            }
            guard !app.staticTexts["Save Failed"].exists else {
                throw Self.accessibilityError("The product presented Save Failed during package-aware Save.")
            }
            return try Task10DocumentEditedReader.read(
                window: current, expectedPID: running.processIdentifier
            )
        }

        func observeExpectedPackage() throws -> Task10SavedPackageObservation {
            let observation = try Task10SavedPackageObservation.capture(at: expectedPackage.packageURL)
            _ = try observation.isNewPublication(after: expectedPackage)
            try verifyContents(observation)
            return observation
        }

        // Drain a legitimate pending autosave before establishing the explicit command baseline.
        // This is a condition wait, not an autosave override or an artificial authoring mutation.
        let readyDeadline = Date().addingTimeInterval(10)
        var ready = false
        repeat {
            if try !requireFocusedDocument() {
                _ = try observeExpectedPackage()
                if try !requireFocusedDocument() { ready = true; break }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < readyDeadline
        guard ready else {
            throw Self.accessibilityError("The package did not reach a clean canonical pre-Save cut.")
        }

        var before: Task10SavedPackageObservation?
        try performFileMenuCommand(
            titled: "Save", in: running, context: "package-aware File ▸ Save",
            beforePress: {
                guard try !requireFocusedDocument() else {
                    throw Self.accessibilityError("The package changed before the explicit Save command.")
                }
                before = try observeExpectedPackage()
            }
        )
        guard let before else { throw Self.harnessError("Save did not capture its publication baseline.") }
        let deadline = Date().addingTimeInterval(10)
        var observationFailure: String?
        repeat {
            let edited = try requireFocusedDocument()
            do {
                let after = try observeExpectedPackage()
                if try after.isNewPublication(after: before), !edited,
                   try !requireFocusedDocument() {
                    try assertCandidateIdentityIsUnchanged()
                    return (before, after)
                }
            } catch {
                // A bounded read can cross the app's atomic publication. Retry the physical cut;
                // a stale, malformed or wrong document can never pass the final oracle.
                observationFailure = error.localizedDescription
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        throw Self.accessibilityError(
            "File ▸ Save did not republish the exact clean canonical package. "
                + (observationFailure ?? "No physical package generation change was observed.")
        )
    }

    /// Provides the lifecycle sequence shared by the forthcoming save/terminate/reopen selectors.
    /// The caller remains responsible for asserting the restored product state after the reopen.
    func terminateRelaunchAndOpenWorkspace(
        _ packageURL: URL,
        appearance: Appearance? = nil
    ) throws -> XCUIApplication {
        try terminateExactCandidateGracefully()
        let app = try launch(appearance: appearance)
        try openWorkspacePackage(packageURL, in: app)
        return app
    }

    func accessibilityApplication(timeout: TimeInterval = 10) throws -> AXUIElement {
        let runningApplication = try requireRunningCandidate(
            timeout: timeout,
            context: "Accessibility traversal"
        )
        return AXUIElementCreateApplication(runningApplication.processIdentifier)
    }

    func waitForFocusedWindow(
        titled title: String,
        timeout: TimeInterval,
        context: String
    ) throws -> AXUIElement {
        try Self.waitForFocusedWindow(
            titled: title,
            in: accessibilityApplication(timeout: timeout),
            timeout: timeout,
            context: context
        )
    }

    func focusedAccessibilityWindow(timeout: TimeInterval = 5) throws -> AXUIElement {
        try Self.accessibilityElement(
            attribute: kAXFocusedWindowAttribute as CFString,
            of: accessibilityApplication(timeout: timeout),
            context: "the focused installed-app window"
        )
    }

    func waitForAccessibilityDescendant(
        identified identifier: String,
        of element: AXUIElement,
        depth: Int,
        timeout: TimeInterval,
        context: String
    ) throws -> AXUIElement {
        try Self.waitForAccessibilityDescendant(
            identified: identifier,
            of: element,
            depth: depth,
            timeout: timeout,
            context: context
        )
    }

    func hasAccessibilityDescendant(
        identified identifier: String,
        of element: AXUIElement,
        depth: Int
    ) throws -> Bool {
        var wasIncomplete = false
        let match = Self.boundedAccessibilityDescendant(
            identified: identifier,
            of: element,
            depth: max(0, depth),
            wasIncomplete: &wasIncomplete
        )
        guard !wasIncomplete else {
            throw Self.accessibilityError(
                "Accessibility could not complete the bounded search for \(identifier)."
            )
        }
        return match != nil
    }

    func accessibilityDescendants(
        role: String,
        of element: AXUIElement,
        depth: Int
    ) -> [AXUIElement] {
        Self.accessibilityDescendants(
            role: role,
            of: element,
            depth: max(0, depth)
        )
    }

    func accessibilityFrame(of element: AXUIElement) -> CGRect? {
        guard let origin = Self.accessibilityPosition(of: element),
              let size = Self.accessibilitySize(of: element) else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    func waitForAccessibilityFrame(
        of element: AXUIElement,
        timeout: TimeInterval = 5,
        context: String
    ) throws -> CGRect {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let frame = accessibilityFrame(of: element),
               frame.width > 0,
               frame.height > 0 {
                return frame
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        throw Self.accessibilityError(
            "Accessibility did not expose a nonempty frame for \(context)."
        )
    }

    func raiseAccessibilityWindow(_ window: AXUIElement) throws {
        let result = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        guard result == .success else {
            throw Self.accessibilityError(
                "Accessibility could not raise the requested window (AX error \(result.rawValue))."
            )
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    func accessibilityString(attribute: CFString, of element: AXUIElement) -> String? {
        Self.accessibilityString(attribute: attribute, of: element)
    }

    /// Diagnostic-only raw observations. The caller supplies the verified fixture window
    /// and the exact element its assertions will read; no application-wide fallback occurs.
    func accessibilityWindowDiagnostic(
        identified identifier: String,
        expectedWindowTitle: String,
        window: AXUIElement,
        selectedElement: AXUIElement
    ) -> AccessibilityWindowDiagnostic {
        let attributes = [
            kAXIdentifierAttribute, kAXRoleAttribute, kAXSubroleAttribute,
            kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute,
            kAXValueAttribute, kAXValueDescriptionAttribute,
        ]
        func observe(_ element: AXUIElement) -> AccessibilityElementObservation {
            var pid: pid_t = 0
            let result = AXUIElementGetPid(element, &pid)
            return AccessibilityElementObservation(
                processIdentifier: result == .success ? pid : nil,
                processIdentifierStatus: result.rawValue,
                attributes: attributes.map {
                    Self.accessibilityAttributeObservation(attribute: $0 as CFString, of: element)
                }
            )
        }
        let windowObservation = observe(window)
        let selectedObservation = observe(selectedElement)
        var remainingElements = 256
        var matches: [AccessibilityElementObservation] = []
        var observedMatchingElementCount = 0
        var wasTruncated = false
        var wasIncomplete = false
        func visit(_ element: AXUIElement, depth: Int) {
            guard remainingElements > 0 else { wasTruncated = true; return }
            remainingElements -= 1
            let identity = Self.accessibilityAttributeObservation(
                attribute: kAXIdentifierAttribute as CFString, of: element
            )
            if identity.status != AXError.success.rawValue,
               identity.status != AXError.attributeUnsupported.rawValue,
               identity.status != AXError.noValue.rawValue {
                wasIncomplete = true
            }
            if identity.stringWasTruncated { wasIncomplete = true }
            if identity.stringValue == identifier {
                observedMatchingElementCount += 1
                guard matches.count < 8 else { wasTruncated = true; return }
                matches.append(observe(element))
            }
            var childCount: CFIndex = 0
            let countResult = AXUIElementGetAttributeValueCount(
                element, kAXChildrenAttribute as CFString, &childCount
            )
            if countResult == .attributeUnsupported || countResult == .noValue { return }
            guard countResult == .success, childCount >= 0 else { wasIncomplete = true; return }
            guard childCount > 0 else { return }
            guard depth > 0 else { wasTruncated = true; return }
            let count = min(childCount, remainingElements)
            if count < childCount { wasTruncated = true }
            guard count > 0 else { return }
            var values: CFArray?
            let childrenResult = AXUIElementCopyAttributeValues(
                element, kAXChildrenAttribute as CFString, 0, count, &values
            )
            guard childrenResult == .success,
                  let children = values as? [AXUIElement], children.count == count else {
                wasIncomplete = true
                return
            }
            for child in children {
                guard CFGetTypeID(child) == AXUIElementGetTypeID() else {
                    wasIncomplete = true
                    continue
                }
                visit(child, depth: depth - 1)
            }
        }
        visit(window, depth: 14)
        let title = Self.boundedAccessibilityDiagnosticString(expectedWindowTitle, maximumUTF8Bytes: 512)
        let identifierText = Self.boundedAccessibilityDiagnosticString(identifier, maximumUTF8Bytes: 512)
        return AccessibilityWindowDiagnostic(
            expectedWindowTitle: title.text,
            identifier: identifierText.text,
            requestWasTruncated: title.wasTruncated || identifierText.wasTruncated,
            window: windowObservation,
            selectedElement: selectedObservation,
            matchingElements: matches,
            observedMatchingElementCount: observedMatchingElementCount,
            visitedElementCount: 256 - remainingElements,
            wasTruncated: wasTruncated,
            wasIncomplete: wasIncomplete
        )
    }

    func accessibilityCharacterVisibility(
        of element: AXUIElement
    ) throws -> AccessibilityCharacterVisibility {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXVisibleCharacterRangeAttribute as CFString,
            &value
        )
        switch result {
        case .attributeUnsupported, .noValue:
            return .unsupported
        case .success:
            guard let value,
                  CFGetTypeID(value) == AXValueGetTypeID() else {
                throw Self.accessibilityError(
                    "Accessibility returned a malformed visible-character range."
                )
            }
            let axValue = value as! AXValue
            guard AXValueGetType(axValue) == .cfRange else {
                throw Self.accessibilityError(
                    "Accessibility returned the wrong visible-character range type."
                )
            }
            var range = CFRange()
            guard AXValueGetValue(axValue, .cfRange, &range) else {
                throw Self.accessibilityError(
                    "Accessibility could not decode the visible-character range."
                )
            }
            return .visibleRange(range)
        default:
            throw Self.accessibilityError(
                "Accessibility could not read the visible-character range "
                    + "(AX error \(result.rawValue))."
            )
        }
    }

    func accessibilityTitle(of element: AXUIElement) -> String? {
        Self.accessibilityTitle(of: element)
    }

    /// Returns only the user-visible accessibility text surfaces governed by the installed
    /// privacy selectors. Traversal is bounded so a malformed or unexpectedly deep AX tree
    /// cannot turn qualification into an unbounded walk.
    func boundedAccessibilityAttributeStrings(
        of element: AXUIElement,
        depth: Int = 12,
        limit: Int = 512,
        elementLimit: Int = 512
    ) -> BoundedAccessibilityAttributeStrings {
        var strings: [String] = []
        var wasTruncated = false
        var wasIncomplete = false
        var remainingElements = max(1, elementLimit)
        Self.collectAccessibilityAttributeStrings(
            of: element,
            depth: max(0, depth),
            limit: max(1, limit),
            into: &strings,
            wasTruncated: &wasTruncated,
            wasIncomplete: &wasIncomplete,
            remainingElements: &remainingElements
        )
        return BoundedAccessibilityAttributeStrings(
            strings: strings,
            wasTruncated: wasTruncated,
            wasIncomplete: wasIncomplete
        )
    }

    func accessibilityPress(_ element: AXUIElement, context: String) throws {
        try Self.accessibilityPress(element, context: context)
    }

    /// Invokes a command from the exact installed candidate's application menu through the
    /// accessibility action boundary. XCUI's synthesized click can report transient macOS menu
    /// items as non-hittable even after resolving them, so qualification uses the same bounded
    /// AX path that already governs production File-menu commands.
    func performApplicationMenuCommand(titled title: String) throws {
        try assertCandidateIdentityIsUnchanged()
        let runningApplication = try requireRunningCandidate(
            timeout: 10,
            context: "MacScope ▸ \(title)"
        )
        let application = AXUIElementCreateApplication(runningApplication.processIdentifier)
        let menuBar = try Self.accessibilityElement(
            attribute: kAXMenuBarAttribute as CFString,
            of: application,
            context: "MacScope menu bar"
        )
        let applicationMenu = try Self.accessibilityElement(
            titled: "MacScope",
            among: Self.accessibilityChildren(of: menuBar),
            context: "MacScope application menu"
        )
        try Self.accessibilityPress(applicationMenu, context: "MacScope application menu")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let command = try Self.accessibilityDescendant(
            titled: title,
            of: applicationMenu,
            depth: 3,
            context: "MacScope ▸ \(title)"
        )
        try Self.accessibilityPress(command, context: "MacScope ▸ \(title)")
    }

    /// Applies one of the governed qualification sizes to the exact candidate's focused window.
    func setFocusedWindowSize(
        _ windowSize: WindowSize,
        timeout: TimeInterval = 5
    ) throws {
        guard windowSize.settlesOnWorkspaceContent else {
            try setFocusedWindowSize(windowSize.size, timeout: timeout)
            return
        }
        try setFocusedWindowContentSize(windowSize.size, timeout: timeout)
    }

    /// Requests `requestedContentSize` as the outer size and requires the window to settle at
    /// exactly that width and at that height plus the standard native titlebar height AppKit
    /// reports for a titled window. The workspace root's accessibility frame spans the window
    /// (its background reaches under the hidden titlebar), so it must share the window's leading,
    /// trailing and bottom edges and may not start above it: a root wider than the window is an
    /// overflowing layout, not a settled one.
    private func setFocusedWindowContentSize(
        _ requestedContentSize: CGSize,
        timeout: TimeInterval
    ) throws {
        let window = try requestFocusedWindowSize(requestedContentSize, timeout: timeout)
        let root = try Self.waitForAccessibilityDescendant(
            identified: Self.workspaceRootAccessibilityIdentifier,
            of: window,
            depth: 14,
            timeout: timeout,
            context: "the workspace root"
        )
        let titlebarHeight = NSWindow.frameRect(
            forContentRect: CGRect(origin: .zero, size: requestedContentSize),
            styleMask: .titled
        ).height - requestedContentSize.height

        let deadline = Date().addingTimeInterval(timeout)
        var lastObservedWindowFrame: CGRect?
        var lastObservedRootFrame: CGRect?
        repeat {
            lastObservedWindowFrame = accessibilityFrame(of: window)
            lastObservedRootFrame = accessibilityFrame(of: root)
            if let observedWindow = lastObservedWindowFrame,
               let observedRoot = lastObservedRootFrame,
               abs(observedWindow.width - requestedContentSize.width) < 1,
               abs(observedWindow.height - requestedContentSize.height - titlebarHeight) < 1,
               abs(observedRoot.minX - observedWindow.minX) < 1,
               abs(observedRoot.maxX - observedWindow.maxX) < 1,
               abs(observedRoot.maxY - observedWindow.maxY) < 1,
               observedRoot.minY > observedWindow.minY - 1 {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        throw Self.accessibilityError(
            "The focused window did not settle at "
                + "\(Int(requestedContentSize.width))x\(Int(requestedContentSize.height)) content below a "
                + "\(Int(titlebarHeight))-point titlebar with the workspace root filling it; "
                + "last observed AX window frame: "
                + "\(lastObservedWindowFrame.map(NSStringFromRect) ?? "unavailable"), "
                + "workspace root frame: \(lastObservedRootFrame.map(NSStringFromRect) ?? "unavailable")."
        )
    }

    func setFocusedWindowSize(
        _ requestedSize: CGSize,
        timeout: TimeInterval = 5
    ) throws {
        let window = try requestFocusedWindowSize(requestedSize, timeout: timeout)

        let deadline = Date().addingTimeInterval(timeout)
        var lastObservedSize: CGSize?
        repeat {
            lastObservedSize = Self.accessibilitySize(of: window)
            if let observed = lastObservedSize,
               abs(observed.width - requestedSize.width) < 1,
               abs(observed.height - requestedSize.height) < 1 {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        throw Self.accessibilityError(
            "The focused window did not settle at \(Int(requestedSize.width))x\(Int(requestedSize.height)); "
                + "last observed AX size: \(lastObservedSize.map(NSStringFromSize) ?? "unavailable")."
        )
    }

    private func requestFocusedWindowSize(
        _ requestedSize: CGSize,
        timeout: TimeInterval
    ) throws -> AXUIElement {
        let application = try accessibilityApplication(timeout: timeout)
        let window = try Self.accessibilityElement(
            attribute: kAXFocusedWindowAttribute as CFString,
            of: application,
            context: "the focused installed-app window"
        )
        var requestedSizeValue = requestedSize
        guard requestedSize.width > 0,
              requestedSize.height > 0,
              requestedSize.width.isFinite,
              requestedSize.height.isFinite,
              let sizeValue = AXValueCreate(.cgSize, &requestedSizeValue) else {
            throw Self.accessibilityError("Accessibility could not encode the requested window size.")
        }
        let result = AXUIElementSetAttributeValue(
            window,
            kAXSizeAttribute as CFString,
            sizeValue
        )
        guard result == .success else {
            throw Self.accessibilityError(
                "Accessibility could not set the focused window size (AX error \(result.rawValue))."
            )
        }
        return window
    }

    /// Produces a full-window attachment whose name binds the scenario to the frozen source and
    /// installed executable identities. Explicit appearance runs are accepted only when the
    /// captured pixels independently demonstrate the requested effective Light/Dark appearance.
    func windowScreenshotAttachment(
        from app: XCUIApplication,
        scenario: String,
        appearance: Appearance,
        size: WindowSize
    ) throws -> XCTAttachment {
        _ = try requireRunningCandidate(timeout: 10, context: "installed-window screenshot")
        let window = app.windows.element(boundBy: 0)
        guard window.waitForExistence(timeout: 10) else {
            throw Self.harnessError("The exact installed candidate had no window to capture.")
        }
        let screenshot = window.screenshot()
        try Self.assertEffectiveAppearance(appearance, in: screenshot)
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(scenario)-\(appearance.rawValue)-\(size.rawValue)-"
            + "\(identity.sourceCommit)-\(identity.executableSHA256)"
        attachment.lifetime = .keepAlways
        return attachment
    }

    private static func assertEffectiveAppearance(
        _ appearance: Appearance,
        in screenshot: XCUIScreenshot
    ) throws {
        guard appearance != .automatic else { return }
        guard let bitmap = NSBitmapImageRep(data: screenshot.pngRepresentation),
              bitmap.pixelsWide > 0,
              bitmap.pixelsHigh > 0 else {
            throw harnessError("The installed-window screenshot could not be decoded.")
        }

        let horizontalStride = max(1, bitmap.pixelsWide / 48)
        let verticalStride = max(1, bitmap.pixelsHigh / 36)
        var luminances: [CGFloat] = []
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: verticalStride) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: horizontalStride) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }
                luminances.append(
                    0.2126 * color.redComponent
                        + 0.7152 * color.greenComponent
                        + 0.0722 * color.blueComponent
                )
            }
        }
        guard luminances.count >= 256 else {
            throw harnessError("The installed-window screenshot had too few appearance samples.")
        }
        luminances.sort()
        let medianLuminance = luminances[luminances.count / 2]
        switch appearance {
        case .automatic:
            return
        case .light:
            guard medianLuminance >= 0.55 else {
                throw harnessError(
                    "The requested Light appearance was not effective; median luminance was "
                        + String(format: "%.3f", medianLuminance)
                )
            }
        case .dark:
            guard medianLuminance <= 0.45 else {
                throw harnessError(
                    "The requested Dark appearance was not effective; median luminance was "
                        + String(format: "%.3f", medianLuminance)
                )
            }
        }
    }

    private func performFileMenuCommand(
        titled title: String,
        in runningApplication: NSRunningApplication,
        context: String,
        beforePress: () throws -> Void = {}
    ) throws {
        guard runningApplication.executableURL?.path == executableURL.path else {
            throw Self.harnessError("\(context) was not bound to the exact installed candidate.")
        }
        let application = AXUIElementCreateApplication(runningApplication.processIdentifier)
        let menuBar = try Self.accessibilityElement(
            attribute: kAXMenuBarAttribute as CFString,
            of: application,
            context: "MacScope menu bar"
        )
        let fileMenu = try Self.accessibilityElement(
            titled: "File",
            among: Self.accessibilityChildren(of: menuBar),
            context: "MacScope File menu"
        )
        try Self.accessibilityPress(fileMenu, context: "File menu")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let command = try Self.accessibilityDescendant(
            titled: title,
            of: fileMenu,
            depth: 3,
            context: context
        )
        try beforePress()
        try Self.accessibilityPress(command, context: context)
    }

    private static func waitForTermination(
        of runningApplication: NSRunningApplication,
        processIdentifier: pid_t,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if runningApplication.isTerminated
                || NSRunningApplication(processIdentifier: processIdentifier) == nil {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return runningApplication.isTerminated
    }

    private static func accessibilityElement(
        attribute: CFString,
        of element: AXUIElement,
        context: String
    ) throws -> AXUIElement {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else {
            throw accessibilityError(
                "Accessibility could not resolve \(context) (AX error \(result.rawValue))."
            )
        }
        return value as! AXUIElement
    }

    private static func boundedAccessibilityChildren(
        of element: AXUIElement,
        wasIncomplete: inout Bool
    ) -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        )
        switch result {
        case .success:
            guard let children = value as? [AXUIElement] else {
                wasIncomplete = true
                return []
            }
            return children
        case .attributeUnsupported, .noValue:
            return []
        default:
            wasIncomplete = true
            return []
        }
    }

    private static func accessibilityChildren(of element: AXUIElement) -> [AXUIElement] {
        var wasIncomplete = false
        return boundedAccessibilityChildren(of: element, wasIncomplete: &wasIncomplete)
    }

    private static func accessibilityIdentifier(of element: AXUIElement) -> String? {
        accessibilityString(attribute: kAXIdentifierAttribute as CFString, of: element)
    }

    private static func accessibilityString(
        attribute: CFString,
        of element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func accessibilityAttributeObservation(
        attribute: CFString,
        of element: AXUIElement
    ) -> AccessibilityAttributeObservation {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        let typeID = value.map { CFGetTypeID($0) }
        let typeName = typeID.flatMap { CFCopyTypeIDDescription($0) as String? }
        let string = value.flatMap { CFGetTypeID($0) == CFStringGetTypeID() ? $0 as? String : nil }
        let bounded = string.map { boundedAccessibilityDiagnosticString($0, maximumUTF8Bytes: 512) }
        return AccessibilityAttributeObservation(
            attribute: attribute as String,
            status: result.rawValue,
            returnedTypeID: typeID,
            returnedTypeName: typeName.map {
                boundedAccessibilityDiagnosticString($0, maximumUTF8Bytes: 64).text
            },
            stringValue: bounded?.text,
            stringWasTruncated: bounded?.wasTruncated ?? false
        )
    }

    private static func boundedAccessibilityDiagnosticString(
        _ text: String,
        maximumUTF8Bytes: Int
    ) -> (text: String, wasTruncated: Bool) {
        var bounded = ""
        var byteCount = 0
        for scalar in text.unicodeScalars {
            let scalarBytes = String(scalar).utf8.count
            guard byteCount + scalarBytes <= maximumUTF8Bytes else { return (bounded, true) }
            bounded.unicodeScalars.append(scalar)
            byteCount += scalarBytes
        }
        return (bounded, false)
    }

    private static func boundedAccessibilityString(
        attribute: CFString,
        of element: AXUIElement,
        wasIncomplete: inout Bool
    ) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        switch result {
        case .success:
            return value as? String
        case .attributeUnsupported, .noValue:
            return nil
        default:
            wasIncomplete = true
            return nil
        }
    }

    private static func accessibilityBoolean(
        attribute: CFString,
        of element: AXUIElement
    ) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return (value as? NSNumber)?.boolValue
    }

    private static func accessibilityIdentifierSummary(
        of element: AXUIElement,
        depth: Int,
        limit: Int
    ) -> String {
        guard depth >= 0, limit > 0 else { return "[]" }
        var identifiers: [String] = []
        var remaining = limit
        func appendDescendants(of current: AXUIElement, remainingDepth: Int) {
            guard remainingDepth >= 0, remaining > 0 else { return }
            for child in accessibilityChildren(of: current) where remaining > 0 {
                if let identifier = accessibilityIdentifier(of: child) {
                    identifiers.append(identifier)
                    remaining -= 1
                }
                appendDescendants(of: child, remainingDepth: remainingDepth - 1)
            }
        }
        appendDescendants(of: element, remainingDepth: depth)
        return identifiers.isEmpty ? "[]" : "[\(identifiers.joined(separator: ", "))]"
    }

    private static func waitForFocusedWindow(
        titled title: String,
        in application: AXUIElement,
        timeout: TimeInterval,
        context: String
    ) throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        var observedTitle: String?
        repeat {
            if let window = try? accessibilityElement(
                attribute: kAXFocusedWindowAttribute as CFString,
                of: application,
                context: context
            ) {
                observedTitle = accessibilityTitle(of: window)
                if observedTitle == title {
                    return window
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        throw accessibilityError(
            "Accessibility did not expose \(context); focused window title was "
                + "\(observedTitle ?? "nil")."
        )
    }

    private static func waitForAccessibilityDescendant(
        identified identifier: String,
        of element: AXUIElement,
        depth: Int,
        timeout: TimeInterval,
        context: String
    ) throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let matchingElement = try? accessibilityDescendant(
                identified: identifier,
                of: element,
                depth: depth,
                context: context
            ) {
                return matchingElement
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        throw accessibilityError(
            "Accessibility did not expose \(context); visible identifiers: "
                + accessibilityIdentifierSummary(of: element, depth: 6, limit: 64)
        )
    }

    private static func accessibilityElement(
        titled title: String,
        among elements: [AXUIElement],
        context: String
    ) throws -> AXUIElement {
        guard let matchingElement = elements.first(where: { accessibilityTitle(of: $0) == title }) else {
            throw accessibilityError("Accessibility could not find \(context).")
        }
        return matchingElement
    }

    private static func accessibilityDescendant(
        titled title: String,
        of element: AXUIElement,
        depth: Int,
        context: String
    ) throws -> AXUIElement {
        guard depth >= 0 else {
            throw accessibilityError("Accessibility could not find \(context).")
        }
        for child in accessibilityChildren(of: element) {
            if accessibilityTitle(of: child) == title {
                return child
            }
            if let matchingDescendant = try? accessibilityDescendant(
                titled: title,
                of: child,
                depth: depth - 1,
                context: context
            ) {
                return matchingDescendant
            }
        }
        throw accessibilityError("Accessibility could not find \(context).")
    }

    private static func accessibilityDescendant(
        identified identifier: String,
        of element: AXUIElement,
        depth: Int,
        context: String
    ) throws -> AXUIElement {
        guard depth >= 0 else {
            throw accessibilityError("Accessibility could not find \(context).")
        }
        for child in accessibilityChildren(of: element) {
            if accessibilityIdentifier(of: child) == identifier {
                return child
            }
            if let matchingDescendant = try? accessibilityDescendant(
                identified: identifier,
                of: child,
                depth: depth - 1,
                context: context
            ) {
                return matchingDescendant
            }
        }
        throw accessibilityError("Accessibility could not find \(context).")
    }

    private static func boundedAccessibilityDescendant(
        identified identifier: String,
        of element: AXUIElement,
        depth: Int,
        wasIncomplete: inout Bool
    ) -> AXUIElement? {
        guard depth >= 0, !wasIncomplete else { return nil }
        let children = boundedAccessibilityChildren(
            of: element,
            wasIncomplete: &wasIncomplete
        )
        guard !wasIncomplete else { return nil }
        for child in children {
            if boundedAccessibilityString(
                attribute: kAXIdentifierAttribute as CFString,
                of: child,
                wasIncomplete: &wasIncomplete
            ) == identifier {
                return child
            }
            guard !wasIncomplete else { return nil }
            if depth > 0,
               let match = boundedAccessibilityDescendant(
                   identified: identifier,
                   of: child,
                   depth: depth - 1,
                   wasIncomplete: &wasIncomplete
               ) {
                return match
            }
            guard !wasIncomplete else { return nil }
        }
        return nil
    }

    private static func accessibilityDescendants(
        role: String,
        of element: AXUIElement,
        depth: Int
    ) -> [AXUIElement] {
        guard depth >= 0 else { return [] }
        var matches: [AXUIElement] = []
        for child in accessibilityChildren(of: element) {
            if accessibilityString(attribute: kAXRoleAttribute as CFString, of: child) == role {
                matches.append(child)
            }
            if depth > 0 {
                matches.append(contentsOf: accessibilityDescendants(
                    role: role,
                    of: child,
                    depth: depth - 1
                ))
            }
        }
        return matches
    }

    private static func accessibilityTitle(of element: AXUIElement) -> String? {
        accessibilityString(attribute: kAXTitleAttribute as CFString, of: element)
    }

    private static func collectAccessibilityAttributeStrings(
        of element: AXUIElement,
        depth: Int,
        limit: Int,
        into strings: inout [String],
        wasTruncated: inout Bool,
        wasIncomplete: inout Bool,
        remainingElements: inout Int
    ) {
        guard remainingElements > 0 else {
            wasTruncated = true
            return
        }
        remainingElements -= 1
        guard strings.count < limit else {
            wasTruncated = true
            return
        }
        for attribute in [
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXValueAttribute,
            kAXHelpAttribute,
        ] {
            let value = boundedAccessibilityString(
                attribute: attribute as CFString,
                of: element,
                wasIncomplete: &wasIncomplete
            )
            guard !wasIncomplete else { return }
            guard let value, !value.isEmpty else { continue }
            guard strings.count < limit else {
                wasTruncated = true
                return
            }
            strings.append(value)
            if strings.count == limit {
                wasTruncated = true
                return
            }
        }
        guard !wasIncomplete else { return }
        let children = boundedAccessibilityChildren(
            of: element,
            wasIncomplete: &wasIncomplete
        )
        guard !wasIncomplete else { return }
        guard depth > 0 else {
            if !children.isEmpty {
                wasTruncated = true
            }
            return
        }
        for child in children {
            collectAccessibilityAttributeStrings(
                of: child,
                depth: depth - 1,
                limit: limit,
                into: &strings,
                wasTruncated: &wasTruncated,
                wasIncomplete: &wasIncomplete,
                remainingElements: &remainingElements
            )
            guard !wasTruncated, !wasIncomplete else { return }
        }
    }

    private static func accessibilitySize(of element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &value
        ) == .success,
        let value else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else {
            return nil
        }
        return size
    }

    private static func accessibilityPosition(of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &value
        ) == .success,
        let value else {
            return nil
        }
        var position = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &position) else {
            return nil
        }
        return position
    }

    private static func accessibilityPress(_ element: AXUIElement, context: String) throws {
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success else {
            throw accessibilityError(
                "Accessibility could not invoke \(context) (AX error \(result.rawValue))."
            )
        }
    }

    private static func decodeProvenance(at url: URL) throws -> ReleaseProvenance {
        try JSONDecoder().decode(ReleaseProvenance.self, from: Data(contentsOf: url))
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func accessibilityError(_ description: String) -> NSError {
        harnessError(description, code: 4)
    }

    private static func harnessError(_ description: String, code: Int = 1) -> NSError {
        NSError(
            domain: "MacScopeInstalledAppUITestHarness",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}
