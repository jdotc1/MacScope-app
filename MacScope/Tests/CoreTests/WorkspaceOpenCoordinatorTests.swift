import AppKit
import Foundation
import XCTest
@testable import MacScope

@MainActor
final class WorkspaceOpenCoordinatorTests: XCTestCase {
    func testApplicationBinaryOpenWithoutFocusedWorkspaceQueuesExactlyOnce() throws {
        let harness = try makeHarness()
        let router = WorkspaceApplicationOpenRouter(registry: harness.registry,
                                                     coordinator: harness.coordinator)
        let url = URL(fileURLWithPath: "/application-open-fixture")
        var opened: [WorkspaceWindowID] = []
        XCTAssertTrue(router.enqueueBinary(url) { opened.append($0) })
        let id = try XCTUnwrap(opened.first)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(harness.registry.count, 0, "scene resolution owns store creation")
        XCTAssertEqual(harness.registry.takePendingBinaryOpen(for: id), url)
        XCTAssertNil(harness.registry.takePendingBinaryOpen(for: id))
    }

    func testApplicationOpenCannotQueueWindowAfterTermination() async throws {
        let harness = try makeHarness()
        let terminated = await harness.registry.shutdown()
        XCTAssertTrue(terminated)
        let router = WorkspaceApplicationOpenRouter(registry: harness.registry,
                                                     coordinator: harness.coordinator)
        var opened: [WorkspaceWindowID] = []
        XCTAssertFalse(router.enqueueBinary(URL(fileURLWithPath: "/rejected-fixture")) {
            opened.append($0)
        })
        XCTAssertTrue(opened.isEmpty)
    }

    func testApplicationWorkspaceOpenWithoutFocusPreservesDuplicateOwnership() async throws {
        let files = try OpenTestFiles()
        defer { files.remove() }
        let url = try files.makeDirectory("Application-Open.mscope")
        let harness = try makeHarness()
        let router = WorkspaceApplicationOpenRouter(registry: harness.registry,
                                                     coordinator: harness.coordinator)
        var opened: [WorkspaceWindowID] = []
        let first = await router.openWorkspace(url, source: .fileMenu) { opened.append($0) }
        guard case .openedWindow(let owner) = first else {
            return XCTFail("Expected validated application-owned open: \(first)")
        }
        let second = await router.openWorkspace(url, source: .recentMenu) { opened.append($0) }
        XCTAssertEqual(second, .activatedExisting(owner))
        XCTAssertEqual(opened, [owner], "duplicate activation must not request another native window")
        XCTAssertEqual(harness.registry.count, 1)
        XCTAssertEqual(harness.activator.activated, [owner])
    }

    func testSupersededRestorationCannotAcquireWindowOwnershipAfterRead() async throws {
        let files = try OpenTestFiles()
        defer { files.remove() }
        let package = try files.makeDirectory("Superseded-Restoration.mscope")
        let harness = try makeHarness()
        let admission = OpenTestAdmission()
        await harness.reader.setAfterRead { admission.allowed = false }
        XCTAssertTrue(admission.allowed)
        let outcome = await harness.coordinator.open(
            WorkspaceOpenRequest(url: package, source: .stateRestoration, preferredReusableWindow: nil),
            shouldProceed: { admission.allowed }
        )
        XCTAssertEqual(outcome, .rejected("document-open-cancelled"))
        XCTAssertEqual(harness.registry.count, 0)
        XCTAssertTrue(harness.activator.activated.isEmpty)
        XCTAssertNil(harness.coordinator.owner(of: try WorkspaceDocumentLocation.canonicalized(from: package)))
    }

    func testCancelledRestorationReadCannotAdoptOrActivateAWindow() async throws {
        let files = try OpenTestFiles()
        defer { files.remove() }
        let package = try files.makeDirectory("Cancelled-Restoration.mscope")
        let harness = try makeHarness()
        // Simulate an I/O implementation that returns valid bytes after the caller is
        // cancelled. The coordinator, not cooperative I/O, owns the adoption fence.
        await harness.reader.setCancelsReadTask(true)
        let opening = Task {
            await harness.coordinator.open(WorkspaceOpenRequest(
                url: package, source: .stateRestoration, preferredReusableWindow: nil
            ))
        }
        let outcome = await opening.value
        XCTAssertEqual(outcome, .rejected("document-open-cancelled"))
        XCTAssertEqual(harness.registry.count, 0)
        XCTAssertTrue(harness.activator.activated.isEmpty)
        XCTAssertNil(harness.coordinator.owner(of: try WorkspaceDocumentLocation.canonicalized(from: package)))
    }

    func testCanonicalAndSymlinkAliasesActivateOneExactWindow() async throws {
        let files = try OpenTestFiles()
        defer { files.remove() }
        let package = try files.makeDirectory("Canonical.mscope")
        let alias = files.root.appendingPathComponent("Alias.mscope")
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: package
        )
        let harness = try makeHarness()

        let first = await harness.coordinator.open(
            WorkspaceOpenRequest(
                url: package,
                source: .fileMenu,
                preferredReusableWindow: nil
            )
        )
        guard case .openedWindow(let owner) = first else {
            return XCTFail("Expected a newly owned window, got \(first)")
        }

        let second = await harness.coordinator.open(
            WorkspaceOpenRequest(
                url: alias,
                source: .finder,
                preferredReusableWindow: nil
            )
        )

        XCTAssertEqual(second, .activatedExisting(owner))
        XCTAssertEqual(harness.activator.activated, [owner])
        XCTAssertEqual(harness.registry.count, 1)
    }

    func testHardLinkAliasesCannotAcquireDifferentOwners() throws {
        let files = try OpenTestFiles()
        defer { files.remove() }
        let firstURL = try files.makeFile("First.mscope")
        let secondURL = files.root.appendingPathComponent("Second.mscope")
        try FileManager.default.linkItem(at: firstURL, to: secondURL)
        let first = try WorkspaceDocumentLocation.canonicalized(from: firstURL)
        let second = try WorkspaceDocumentLocation.canonicalized(from: secondURL)
        let harness = try makeHarness()
        let firstSession = WorkspaceDocumentSessionID(rawValue: UUID())
        let firstWindow = WorkspaceWindowID.fresh()

        XCTAssertEqual(
            harness.coordinator.reserve(
                first,
                for: firstSession,
                windowID: firstWindow
            ),
            .reserved
        )
        XCTAssertEqual(harness.coordinator.owner(of: second), firstWindow)
        XCTAssertEqual(
            harness.coordinator.reserve(
                second,
                for: WorkspaceDocumentSessionID(rawValue: UUID()),
                windowID: .fresh()
            ),
            .alreadyOwned(firstWindow)
        )
    }

    func testSeparatelyCopiedPackagesRemainIndependent() async throws {
        let files = try OpenTestFiles()
        defer { files.remove() }
        let firstURL = try files.makeDirectory("First.mscope")
        let secondURL = try files.makeDirectory("Second.mscope")
        let harness = try makeHarness()

        let first = await harness.coordinator.open(request(firstURL))
        let second = await harness.coordinator.open(request(secondURL))

        guard case .openedWindow(let firstWindow) = first,
              case .openedWindow(let secondWindow) = second else {
            return XCTFail("Independent copies must open independently")
        }
        XCTAssertNotEqual(firstWindow, secondWindow)
        XCTAssertEqual(harness.registry.count, 2)
    }

    func testConcurrentDuplicateOpenRequestsConvergeToOneOwner() async throws {
        let files = try OpenTestFiles()
        defer { files.remove() }
        let package = try files.makeDirectory("Concurrent.mscope")
        let harness = try makeHarness()
        let firstRequest = request(package)
        let secondRequest = request(package)

        async let first = harness.coordinator.open(firstRequest)
        async let second = harness.coordinator.open(secondRequest)
        let outcomes = await [first, second]

        let opened = outcomes.compactMap { outcome -> WorkspaceWindowID? in
            guard case .openedWindow(let id) = outcome else { return nil }
            return id
        }
        let activated = outcomes.compactMap { outcome -> WorkspaceWindowID? in
            guard case .activatedExisting(let id) = outcome else { return nil }
            return id
        }
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(activated, opened)
        XCTAssertEqual(harness.registry.count, 1)
    }

    func testAliasOpenWaitsForAtomicPublicationOwnershipHandoff() async throws {
        let files = try OpenTestFiles()
        defer { files.remove() }
        let package = try files.makeDirectory("Published.mscope")
        let alias = files.root.appendingPathComponent("Published-Alias.mscope")
        let openWaited = expectation(description: "alias open reached publication barrier")
        let harness = try makeHarness(
            testHooks: .init(didWaitForPublication: {
                openWaited.fulfill()
            })
        )
        let ownerSession = WorkspaceDocumentSessionID(rawValue: UUID())
        let ownerWindow = WorkspaceWindowID.fresh()
        let original = try WorkspaceDocumentLocation.canonicalized(from: package)
        XCTAssertEqual(
            harness.coordinator.reserve(
                original,
                for: ownerSession,
                windowID: ownerWindow
            ),
            .reserved
        )

        let replacementIdentity = WorkspaceFileObjectIdentity(device: 71, inode: 72)
        let stagedLocation = WorkspaceDocumentLocation(
            canonicalURL: files.root.appendingPathComponent(".published-stage.mscope"),
            fileObjectIdentity: replacementIdentity
        )
        let staged = WorkspaceDocumentStagedPackage(
            stagingID: UUID(),
            stagingURL: stagedLocation.canonicalURL,
            stagedObservation: openTestExternalVersion(
                at: stagedLocation,
                seed: "published-stage"
            ),
            capturedMutationGeneration: .init(rawValue: 0)
        )
        let published = WorkspaceDocumentLocation(
            canonicalURL: original.canonicalURL,
            fileObjectIdentity: replacementIdentity
        )
        let proposedAlias = try WorkspaceDocumentLocation.canonicalized(from: alias)
        let observedAlias = WorkspaceDocumentLocation(
            canonicalURL: proposedAlias.canonicalURL,
            fileObjectIdentity: replacementIdentity
        )
        await harness.probe.setOverride(
            openTestExternalVersion(at: observedAlias, seed: "published"),
            for: proposedAlias.canonicalURL
        )

        let publication: WorkspaceDocumentPublicationReservation
        switch harness.coordinator.beginPhysicalPublication(
            staged,
            to: original,
            retainingPublishedOwnership: true,
            for: ownerSession,
            windowID: ownerWindow
        ) {
        case .reserved(let reservation):
            publication = reservation
        case .alreadyOwned(let existing):
            return XCTFail("Unexpected publication owner: \(existing)")
        }

        let aliasOpen = Task {
            await harness.coordinator.open(request(alias))
        }
        await fulfillment(of: [openWaited], timeout: 1.0)
        let aliasObservationCount = await harness.probe.observationCount(
            for: proposedAlias.canonicalURL
        )
        XCTAssertEqual(
            aliasObservationCount,
            0,
            "Alias validation must not enter the replacement-to-reservation interval"
        )

        XCTAssertEqual(
            harness.coordinator.completePhysicalPublication(
                publication,
                at: published
            ),
            .completed
        )
        let disposition = await aliasOpen.value

        XCTAssertEqual(disposition, .activatedExisting(ownerWindow))
        XCTAssertEqual(harness.activator.activated, [ownerWindow])
        XCTAssertEqual(harness.coordinator.owner(of: observedAlias), ownerWindow)
        XCTAssertEqual(harness.registry.count, 0)
    }

    func testPublicationCompletionRejectsMismatchedDestinationWithMatchingIdentity() throws {
        let files = try OpenTestFiles()
        defer { files.remove() }
        let destinationURL = try files.makeDirectory("Destination.mscope")
        let mismatchedURL = try files.makeDirectory("Mismatched.mscope")
        let harness = try makeHarness()
        let ownerSession = WorkspaceDocumentSessionID(rawValue: UUID())
        let ownerWindow = WorkspaceWindowID.fresh()
        let destination = try WorkspaceDocumentLocation.canonicalized(from: destinationURL)
        let mismatched = try WorkspaceDocumentLocation.canonicalized(from: mismatchedURL)
        let stagedIdentity = WorkspaceFileObjectIdentity(device: 81, inode: 82)
        let stagedLocation = WorkspaceDocumentLocation(
            canonicalURL: files.root.appendingPathComponent(".destination-stage.mscope"),
            fileObjectIdentity: stagedIdentity
        )
        let staged = WorkspaceDocumentStagedPackage(
            stagingID: UUID(),
            stagingURL: stagedLocation.canonicalURL,
            stagedObservation: openTestExternalVersion(
                at: stagedLocation,
                seed: "destination-stage"
            ),
            capturedMutationGeneration: .init(rawValue: 0)
        )

        let publication: WorkspaceDocumentPublicationReservation
        switch harness.coordinator.beginPhysicalPublication(
            staged,
            to: destination,
            retainingPublishedOwnership: true,
            for: ownerSession,
            windowID: ownerWindow
        ) {
        case .reserved(let reservation):
            publication = reservation
        case .alreadyOwned(let existing):
            return XCTFail("Unexpected publication owner: \(existing)")
        }

        XCTAssertEqual(
            harness.coordinator.completePhysicalPublication(
                publication,
                at: WorkspaceDocumentLocation(
                    canonicalURL: mismatched.canonicalURL,
                    fileObjectIdentity: stagedIdentity
                )
            ),
            .invalid
        )
        XCTAssertNil(harness.coordinator.owner(of: destination))
        XCTAssertNil(harness.coordinator.owner(of: mismatched))
    }

    func testPendingPublicationExcludesASecondWriterToTheSameDestination() throws {
        let files = try OpenTestFiles()
        defer { files.remove() }
        let destinationURL = try files.makeDirectory("Destination.mscope")
        let destination = try WorkspaceDocumentLocation.canonicalized(from: destinationURL)
        let harness = try makeHarness()
        let firstWindow = WorkspaceWindowID.fresh()
        let firstSession = WorkspaceDocumentSessionID(rawValue: UUID())

        func staged(_ seed: String, inode: UInt64) -> WorkspaceDocumentStagedPackage {
            let location = WorkspaceDocumentLocation(
                canonicalURL: files.root.appendingPathComponent(".\(seed)-stage.mscope"),
                fileObjectIdentity: WorkspaceFileObjectIdentity(device: 91, inode: inode)
            )
            return WorkspaceDocumentStagedPackage(
                stagingID: UUID(),
                stagingURL: location.canonicalURL,
                stagedObservation: openTestExternalVersion(at: location, seed: seed),
                capturedMutationGeneration: .init(rawValue: 0)
            )
        }

        let firstReservation: WorkspaceDocumentPublicationReservation
        switch harness.coordinator.beginPhysicalPublication(
            staged("first", inode: 92),
            to: destination,
            retainingPublishedOwnership: false,
            for: firstSession,
            windowID: firstWindow
        ) {
        case .reserved(let reservation):
            firstReservation = reservation
        case .alreadyOwned(let owner):
            return XCTFail("Unexpected first owner: \(owner)")
        }

        XCTAssertEqual(
            harness.coordinator.beginPhysicalPublication(
                staged("second", inode: 93),
                to: destination,
                retainingPublishedOwnership: false,
                for: WorkspaceDocumentSessionID(rawValue: UUID()),
                windowID: .fresh()
            ),
            .alreadyOwned(firstWindow)
        )

        harness.coordinator.cancelPhysicalPublication(firstReservation)
        guard case .reserved(let retry) = harness.coordinator.beginPhysicalPublication(
            staged("retry", inode: 94),
            to: destination,
            retainingPublishedOwnership: false,
            for: WorkspaceDocumentSessionID(rawValue: UUID()),
            windowID: .fresh()
        ) else {
            return XCTFail("Cancelling the pending publication must release the destination")
        }
        harness.coordinator.cancelPhysicalPublication(retry)
    }

    func testPreferredWindowIsReusedOnlyWhenVerifiedReusable() async throws {
        let files = try OpenTestFiles()
        defer { files.remove() }
        let reusablePackage = try files.makeDirectory("Reusable.mscope")
        let busyPackage = try files.makeDirectory("Busy.mscope")

        let reusableHarness = try makeHarness()
        let reusableID = WorkspaceWindowID.primary
        let reusableStore = reusableHarness.registry.store(
            for: reusableID,
            launchConfiguration: WorkspaceLaunchConfiguration()
        )
        let reusableSession = reusableHarness.registry.documentSession(
            for: reusableID,
            launchConfiguration: WorkspaceLaunchConfiguration()
        )
        XCTAssertTrue(reusableHarness.registry.isReusableDocumentWindow(reusableID))
        let reuseOutcome = await reusableHarness.coordinator.open(
            request(reusablePackage, preferred: reusableID)
        )
        XCTAssertEqual(reuseOutcome, .reusedWindow(reusableID))
        XCTAssertTrue(reusableHarness.registry.storeIfPresent(for: reusableID) === reusableStore)
        XCTAssertTrue(
            reusableHarness.registry.documentSessionIfPresent(for: reusableID)
                === reusableSession
        )
        XCTAssertEqual(
            reusableSession.snapshot.location?.canonicalURL,
            try WorkspaceDocumentLocation.canonicalized(from: reusablePackage).canonicalURL
        )

        let busyHarness = try makeHarness()
        let busyID = WorkspaceWindowID.primary
        let busyStore = busyHarness.registry.store(
            for: busyID,
            launchConfiguration: WorkspaceLaunchConfiguration()
        )
        busyStore.isImporting = true
        guard case .openedWindow(let opened) = await busyHarness.coordinator.open(
            request(busyPackage, preferred: busyID)
        ) else {
            return XCTFail("A busy preferred window must not be reused")
        }
        XCTAssertNotEqual(opened, busyID)
        XCTAssertEqual(busyHarness.registry.count, 2)
    }

    func testFailedInstallReleasesReservationAndDoesNotRecordRecent() async throws {
        let files = try OpenTestFiles()
        defer { files.remove() }
        let package = try files.makeDirectory("Invalid.mscope")
        let recents = OpenTestRecents()
        let harness = try makeHarness(recents: recents)
        await harness.reader.setReturnsMalformedPackage(true)

        let outcome = await harness.coordinator.open(request(package))
        let location = try WorkspaceDocumentLocation.canonicalized(from: package)

        guard case .rejected = outcome else {
            return XCTFail("Malformed content must be rejected")
        }
        XCTAssertNil(harness.coordinator.owner(of: location))
        XCTAssertTrue(recents.noted.isEmpty)
        XCTAssertEqual(harness.registry.count, 0)
    }

    func testSuccessfulOpenRecordsRecentOnlyAfterAdoptionAndCloseReleasesOwner() async throws {
        let files = try OpenTestFiles()
        defer { files.remove() }
        let package = try files.makeDirectory("Recent.mscope")
        let recents = OpenTestRecents()
        let harness = try makeHarness(recents: recents)
        XCTAssertTrue(recents.noted.isEmpty)

        guard case .openedWindow(let windowID) = await harness.coordinator.open(
            request(package)
        ), let session = harness.registry.documentSessionIfPresent(for: windowID) else {
            return XCTFail("Expected an adopted document session")
        }
        let location = try WorkspaceDocumentLocation.canonicalized(from: package)
        XCTAssertEqual(recents.noted, [location.canonicalURL])
        XCTAssertEqual(harness.coordinator.owner(of: location), windowID)

        harness.coordinator.windowDidClose(
            windowID,
            sessionID: session.snapshot.sessionID
        )

        XCTAssertNil(harness.coordinator.owner(of: location))
        XCTAssertNil(harness.registry.storeIfPresent(for: windowID))
        let saveAfterClose = await session.save()
        XCTAssertEqual(saveAfterClose, .failed("document-session-closed"))
    }

    func testNonemptyVersion3PackageOpensAndRestoresExactReconstructionState() async throws {
        let seed = try Task10InstalledScenarioSeedPackage.make(.activeRetrieving)
        defer { seed.remove() }
        let manifestData = try Data(
            contentsOf: MacScopeDocumentPackage.manifestURL(in: seed.packageURL)
        )
        let package = try MacScopeDocumentPackage.openPackage(from: seed.packageURL)
        XCTAssertEqual(
            package.manifest.formatVersion,
            WorkspacePackageManifest.instructionSidecarFormatVersion
        )
        XCTAssertEqual(
            package.manifest.analysisFormatVersion,
            WorkspacePackageManifest.reconstructionFormatVersion
        )
        XCTAssertNotEqual(package.reconstructionState, .empty)
        let harness = try makeHarness(
            validatedPayload: OpenTestValidatedPayload(
                manifestData: manifestData,
                attachments: package.attachmentsByBinaryID,
                reconstructionState: package.reconstructionState,
                reconstructionAttachmentSources: package.reconstructionAttachmentSources,
                instructionSidecarData: package.instructionSidecarData
            )
        )

        let outcome = await harness.coordinator.open(request(seed.packageURL))
        guard case .openedWindow(let windowID) = outcome,
              let restoredStore = harness.registry.storeIfPresent(for: windowID) else {
            return XCTFail("Expected the production-shaped version 3 package to open, got \(outcome)")
        }

        XCTAssertEqual(restoredStore.reconstructionState, package.reconstructionState)
    }

    func testValidatedOpenSchedulesRecoveryAfterBindingDocumentWriter() async throws {
        let files = try OpenTestFiles()
        defer { files.remove() }
        let url = try files.makeDirectory("Recovery-Admission.mscope")
        let store = WorkspaceStore.bootstrap()
        let previousRecoveryGeneration = store.phase2ShellRecoveryGeneration
        let harness = try makeHarness(openedStore: store)
        let outcome = await harness.coordinator.open(request(url))
        guard case .openedWindow(let windowID) = outcome else {
            return XCTFail("Expected validated open, got \(outcome)")
        }
        XCTAssertTrue(harness.registry.storeIfPresent(for: windowID) === store)
        let session = try XCTUnwrap(harness.registry.documentSessionIfPresent(for: windowID))
        XCTAssertEqual(session.snapshot.location?.canonicalURL, store.documentURL)
        XCTAssertNotEqual(store.phase2ShellRecoveryGeneration, previousRecoveryGeneration,
            "The validated open path must admit recovery after acquiring its writer")
    }

    func testSaveAsReservationCollisionNeverDisplacesExistingOwner() throws {
        let files = try OpenTestFiles()
        defer { files.remove() }
        let package = try files.makeDirectory("Owned.mscope")
        let location = try WorkspaceDocumentLocation.canonicalized(from: package)
        let harness = try makeHarness()
        let ownerSession = WorkspaceDocumentSessionID(rawValue: UUID())
        let ownerWindow = WorkspaceWindowID.fresh()
        XCTAssertEqual(
            harness.coordinator.reserve(
                location,
                for: ownerSession,
                windowID: ownerWindow
            ),
            .reserved
        )

        XCTAssertEqual(
            harness.coordinator.reserve(
                location,
                for: WorkspaceDocumentSessionID(rawValue: UUID()),
                windowID: .fresh()
            ),
            .alreadyOwned(ownerWindow)
        )
        XCTAssertEqual(harness.coordinator.owner(of: location), ownerWindow)
    }

    // MARK: LaunchServices open-document route (`open -a`, Finder double-click)

    /// Cold launch: AppKit delivers `kAEOpenDocuments` before any window mounted its presenter.
    /// The URL must wait, then open into the pristine launch window instead of leaving an
    /// Untitled Workspace beside a second document window.
    func testExternalOpenDocumentAtLaunchWaitsForPresenterAndReusesLaunchWindow() async throws {
        let files = try OpenTestFiles()
        defer { files.remove() }
        let url = try files.makeDirectory("Launch Open.mscope")
        let harness = try makeHarness()
        let router = WorkspaceApplicationOpenRouter(registry: harness.registry,
                                                     coordinator: harness.coordinator)
        router.openExternalDocuments([url])
        await router.waitForExternalOpens()
        XCTAssertNil(router.lastExternalOpenOutcome, "no window may open before a presenter exists")

        let launchStore = WorkspaceStore.bootstrap()
        harness.registry.adopt(launchStore, for: .primary)
        XCTAssertTrue(harness.registry.isReusableDocumentWindow(.primary))
        var presented: [WorkspaceWindowID] = []
        router.installWindowPresenter { presented.append($0) }
        await router.waitForExternalOpens()

        XCTAssertEqual(router.lastExternalOpenOutcome, .reusedWindow(.primary))
        XCTAssertEqual(presented, [.primary])
        XCTAssertEqual(harness.registry.count, 1)
        let location = try WorkspaceDocumentLocation.canonicalized(from: url)
        XCTAssertEqual(harness.coordinator.owner(of: location), .primary)
        XCTAssertEqual(
            harness.registry.documentSessionIfPresent(for: .primary)?.snapshot.location?.canonicalURL,
            location.canonicalURL
        )
    }

    /// While running: a second open of another package gets its own window; reopening an owned
    /// package activates its window and requests no new one.
    func testExternalOpenDocumentWhileRunningOpensWindowThenActivatesDuplicate() async throws {
        let files = try OpenTestFiles()
        defer { files.remove() }
        let first = try files.makeDirectory("First.mscope")
        let second = try files.makeDirectory("Second.mscope")
        let harness = try makeHarness()
        let router = WorkspaceApplicationOpenRouter(registry: harness.registry,
                                                     coordinator: harness.coordinator)
        var presented: [WorkspaceWindowID] = []
        router.installWindowPresenter { presented.append($0) }

        router.openExternalDocuments([first])
        await router.waitForExternalOpens()
        guard case .openedWindow(let firstOwner) = router.lastExternalOpenOutcome else {
            return XCTFail("Expected a new document window: \(String(describing: router.lastExternalOpenOutcome))")
        }
        router.openExternalDocuments([second])
        await router.waitForExternalOpens()
        guard case .openedWindow(let secondOwner) = router.lastExternalOpenOutcome else {
            return XCTFail("Expected a second document window: \(String(describing: router.lastExternalOpenOutcome))")
        }
        router.openExternalDocuments([first])
        await router.waitForExternalOpens()

        XCTAssertNotEqual(firstOwner, secondOwner)
        XCTAssertEqual(router.lastExternalOpenOutcome, .activatedExisting(firstOwner))
        XCTAssertEqual(presented, [firstOwner, secondOwner])
        XCTAssertEqual(harness.activator.activated, [firstOwner])
        XCTAssertEqual(harness.registry.count, 2)
    }

    /// The delegate is the only `kAEOpenDocuments` ingress; URLs delivered before the router is
    /// installed replay exactly once, later ones pass straight through.
    func testApplicationDelegateOpenURLsReplayToInstalledRouterExactlyOnce() {
        let delegate = MacScopeApplicationDelegate()
        let early = URL(fileURLWithPath: "/tmp/Early.mscope")
        let late = URL(fileURLWithPath: "/tmp/Late.mscope")
        delegate.application(NSApplication.shared, open: [early])
        var delivered: [[URL]] = []
        delegate.installOpenDocuments { delivered.append($0) }
        delegate.application(NSApplication.shared, open: [late])
        XCTAssertEqual(delivered, [[early], [late]])
    }

    private struct Harness {
        let registry: WorkspaceSessionRegistry
        let coordinator: WorkspaceOpenCoordinator
        let activator: OpenTestWindowActivator
        let probe: OpenTestProbe
        let reader: OpenTestReader
    }

    private func makeHarness(
        validatedPayload: OpenTestValidatedPayload? = nil,
        recents: OpenTestRecents? = nil,
        openedStore: WorkspaceStore? = nil,
        testHooks: WorkspaceOpenCoordinator.TestHooks = .init()
    ) throws -> Harness {
        let payload: OpenTestValidatedPayload
        if let validatedPayload {
            payload = validatedPayload
        } else {
            let seed = WorkspaceStore.bootstrap()
            let packagePayload = try seed.makePackagePayload()
            payload = OpenTestValidatedPayload(
                manifestData: packagePayload.manifestData,
                attachments: packagePayload.attachmentsByBinaryID,
                reconstructionState: .empty,
                reconstructionAttachmentSources: [],
                instructionSidecarData: packagePayload.instructionSidecarData
            )
        }
        let probe = OpenTestProbe(manifestData: payload.manifestData)
        let reader = OpenTestReader(
            manifestData: payload.manifestData,
            attachments: payload.attachments,
            reconstructionState: payload.reconstructionState,
            reconstructionAttachmentSources: payload.reconstructionAttachmentSources,
            instructionSidecarData: payload.instructionSidecarData,
            probe: probe
        )
        let io = WorkspaceDocumentIO(
            probe: probe,
            reader: reader,
            publisher: OpenTestUnusedPublisher(),
            monitor: OpenTestSilentMonitor()
        )
        let registry = WorkspaceSessionRegistry()
        let activator = OpenTestWindowActivator()
        let coordinator = WorkspaceOpenCoordinator(
            registry: registry,
            io: io,
            windowActivator: activator,
            storeFactory: {
                let store = openedStore ?? WorkspaceStore.bootstrap()
                if let recents { store.recents = recents }
                return store
            },
            sessionIOFactory: { io },
            testHooks: testHooks
        )
        return Harness(
            registry: registry,
            coordinator: coordinator,
            activator: activator,
            probe: probe,
            reader: reader
        )
    }

    private func request(
        _ url: URL,
        preferred: WorkspaceWindowID? = nil
    ) -> WorkspaceOpenRequest {
        WorkspaceOpenRequest(
            url: url,
            source: .fileMenu,
            preferredReusableWindow: preferred
        )
    }
}

private struct OpenTestValidatedPayload {
    let manifestData: Data
    let attachments: [UUID: Data]
    let reconstructionState: ReconstructionWorkspaceState
    let reconstructionAttachmentSources: [ReconstructionAttachmentSource]
    let instructionSidecarData: Data?
}

@MainActor
private final class OpenTestAdmission {
    var allowed = true
}

@MainActor
private final class OpenTestWindowActivator: WorkspaceWindowActivating {
    private(set) var activated: [WorkspaceWindowID] = []

    func activateWindow(_ windowID: WorkspaceWindowID) -> Bool {
        activated.append(windowID)
        return true
    }
}

@MainActor
private final class OpenTestRecents: WorkspaceRecentsRecording {
    private(set) var noted: [URL] = []
    var recentDocumentURLs: [URL] { noted }

    func noteRecentDocument(_ url: URL) { noted.append(url) }
    func clearRecentDocuments() { noted.removeAll() }
}

private actor OpenTestProbe: WorkspacePackageVersionProbing {
    let manifestData: Data
    private var overrides: [URL: WorkspacePackageExternalVersion] = [:]
    private var observationCounts: [URL: Int] = [:]

    init(manifestData: Data) {
        self.manifestData = manifestData
    }

    func setOverride(
        _ observation: WorkspacePackageExternalVersion,
        for url: URL
    ) {
        overrides[url] = observation
    }

    func observationCount(for url: URL) -> Int {
        observationCounts[url, default: 0]
    }

    func observe(_ url: URL) async throws -> WorkspacePackageExternalVersion {
        observationCounts[url, default: 0] += 1
        if let override = overrides[url] {
            return override
        }
        return try openTestObservation(at: url, manifestData: manifestData)
    }
}

private actor OpenTestReader: WorkspaceDocumentReading {
    let manifestData: Data
    let attachments: [UUID: Data]
    let reconstructionState: ReconstructionWorkspaceState
    let reconstructionAttachmentSources: [ReconstructionAttachmentSource]
    let instructionSidecarData: Data?
    let probe: OpenTestProbe
    private var returnsMalformedPackage = false
    private var cancelsReadTask = false
    private var afterRead: (@MainActor @Sendable () -> Void)?

    init(
        manifestData: Data,
        attachments: [UUID: Data],
        reconstructionState: ReconstructionWorkspaceState,
        reconstructionAttachmentSources: [ReconstructionAttachmentSource],
        instructionSidecarData: Data?,
        probe: OpenTestProbe
    ) {
        self.manifestData = manifestData
        self.attachments = attachments
        self.reconstructionState = reconstructionState
        self.reconstructionAttachmentSources = reconstructionAttachmentSources
        self.instructionSidecarData = instructionSidecarData
        self.probe = probe
    }

    func setReturnsMalformedPackage(_ value: Bool) {
        returnsMalformedPackage = value
    }

    func setCancelsReadTask(_ value: Bool) {
        cancelsReadTask = value
    }

    func setAfterRead(_ action: @escaping @MainActor @Sendable () -> Void) {
        afterRead = action
    }

    func readValidated(
        from location: WorkspaceDocumentLocation
    ) async throws -> WorkspaceDocumentValidatedPackage {
        if cancelsReadTask { withUnsafeCurrentTask { $0?.cancel() } }
        let package = WorkspaceDocumentValidatedPackage(
            manifestData: returnsMalformedPackage
                ? Data("not-a-package".utf8)
                : manifestData,
            attachmentsByBinaryID: attachments,
            reconstructionState: reconstructionState,
            reconstructionAttachmentSources: reconstructionAttachmentSources,
            instructionSidecarData: instructionSidecarData,
            observation: try await probe.observe(location.canonicalURL)
        )
        await afterRead?()
        return package
    }
}

private struct OpenTestUnusedPublisher: WorkspaceDocumentPublishing {
    func stage(
        _ payload: WorkspaceDocumentPackagePayload,
        in parentDirectory: URL
    ) async throws -> WorkspaceDocumentStagedPackage {
        throw WorkspaceDocumentSessionError.operationFailed("unexpected-open-stage")
    }

    func publish(
        _ staged: WorkspaceDocumentStagedPackage,
        to destination: WorkspaceDocumentLocation,
        expecting expected: WorkspacePackageExternalVersion
    ) async throws -> WorkspaceDocumentPublishReceipt {
        throw WorkspaceDocumentSessionError.operationFailed("unexpected-open-publish")
    }

    func discard(_ staged: WorkspaceDocumentStagedPackage) async {}
}

private struct OpenTestSilentMonitor: WorkspaceDocumentChangeMonitoring {
    func changes(
        at location: WorkspaceDocumentLocation
    ) -> WorkspaceDocumentChangeFeed {
        let probeDemand = WorkspaceDocumentProbeDemand()
        return WorkspaceDocumentChangeFeed(
            stream: AsyncStream { $0.finish() },
            probeDemand: probeDemand
        )
    }
}

private struct OpenTestFiles {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WorkspaceOpenCoordinatorTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    func makeDirectory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func makeFile(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("alias".utf8).write(to: url, options: .withoutOverwriting)
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func openTestObservation(
    at url: URL,
    manifestData: Data
) throws -> WorkspacePackageExternalVersion {
    let location = try WorkspaceDocumentLocation.canonicalized(from: url)
    let digest = MacScopeDocumentPackage.fileHash(for: manifestData)
    return WorkspacePackageExternalVersion(
        location: location,
        condition: .valid,
        observationSHA256: digest,
        manifestSHA256: digest,
        validatedContentSHA256: digest,
        boundedReason: nil
    )
}

private func openTestExternalVersion(
    at location: WorkspaceDocumentLocation,
    seed: String
) -> WorkspacePackageExternalVersion {
    let digest = MacScopeDocumentPackage.fileHash(for: Data(seed.utf8))
    return WorkspacePackageExternalVersion(
        location: location,
        condition: .valid,
        observationSHA256: digest,
        manifestSHA256: digest,
        validatedContentSHA256: digest,
        boundedReason: nil
    )
}
