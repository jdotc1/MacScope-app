import Foundation

/// Process-wide authority for package ownership and duplicate-safe open routing.
///
/// Both a canonical URL and the filesystem object identity participate in ownership. The URL
/// index catches spelling and symlink aliases; the physical index catches hard links. A package
/// is fully observed and validated before either index can influence window activation.
@MainActor
final class WorkspaceOpenCoordinator: WorkspaceDocumentLocationReserving {
    struct TestHooks {
        let didWaitForPublication: @MainActor () -> Void

        init(didWaitForPublication: @escaping @MainActor () -> Void = {}) {
            self.didWaitForPublication = didWaitForPublication
        }
    }

    private struct ReservationOwner: Equatable {
        let sessionID: WorkspaceDocumentSessionID
        let windowID: WorkspaceWindowID
    }

    private struct Reservation {
        let owner: ReservationOwner
        let physicalIdentity: WorkspaceFileObjectIdentity?
    }

    private struct PendingPublication {
        let owner: ReservationOwner
        let destinationURL: URL
        let stagedPhysicalIdentity: WorkspaceFileObjectIdentity?
        let retainingPublishedOwnership: Bool
        let claimedStagedPhysicalIdentity: Bool
    }

    private let registry: WorkspaceSessionRegistry
    private let io: WorkspaceDocumentIO
    private let windowActivator: any WorkspaceWindowActivating
    private let storeFactory: @MainActor () -> WorkspaceStore
    private let sessionIOFactory: @MainActor () -> WorkspaceDocumentIO
    private let testHooks: TestHooks

    private var reservationsByURL: [URL: Reservation] = [:]
    private var urlsBySession: [WorkspaceDocumentSessionID: Set<URL>] = [:]
    private var ownersByPhysicalIdentity:
        [WorkspaceFileObjectIdentity: ReservationOwner] = [:]
    private var pendingPublications:
        [WorkspaceDocumentPublicationReservation: PendingPublication] = [:]
    private var publicationWaiters: [CheckedContinuation<Void, Never>] = []
    private var publicationEpoch: UInt64 = 0

    init(
        registry: WorkspaceSessionRegistry,
        io: WorkspaceDocumentIO,
        windowActivator: any WorkspaceWindowActivating,
        storeFactory: @escaping @MainActor () -> WorkspaceStore = {
            WorkspaceStore.bootstrap()
        },
        sessionIOFactory: @escaping @MainActor () -> WorkspaceDocumentIO = {
            WorkspaceDocumentIO()
        },
        testHooks: TestHooks = .init()
    ) {
        self.registry = registry
        self.io = io
        self.windowActivator = windowActivator
        self.storeFactory = storeFactory
        self.sessionIOFactory = sessionIOFactory
        self.testHooks = testHooks
        registry.installDocumentSessionFactory { [weak self] windowID, store in
            guard let self else { return nil }
            return WorkspaceDocumentSession(
                sessionID: WorkspaceDocumentSessionID(rawValue: UUID()),
                windowID: windowID,
                source: store,
                io: self.sessionIOFactory(),
                reservations: self
            )
        }
    }

    func owner(of location: WorkspaceDocumentLocation) -> WorkspaceWindowID? {
        if let owner = reservationsByURL[location.canonicalURL]?.owner {
            return owner.windowID
        }
        guard let identity = location.fileObjectIdentity else { return nil }
        return ownersByPhysicalIdentity[identity]?.windowID
    }

    func reserve(
        _ location: WorkspaceDocumentLocation,
        for sessionID: WorkspaceDocumentSessionID,
        windowID: WorkspaceWindowID
    ) -> WorkspaceDocumentLocationReservationResult {
        let proposedOwner = ReservationOwner(
            sessionID: sessionID,
            windowID: windowID
        )
        if let existing = reservationsByURL[location.canonicalURL]?.owner,
           existing != proposedOwner {
            return .alreadyOwned(existing.windowID)
        }
        if let identity = location.fileObjectIdentity,
           let existing = ownersByPhysicalIdentity[identity],
           existing != proposedOwner {
            return .alreadyOwned(existing.windowID)
        }

        let priorPhysicalIdentity = reservationsByURL[location.canonicalURL]?.physicalIdentity
        reservationsByURL[location.canonicalURL] = Reservation(
            owner: proposedOwner,
            physicalIdentity: location.fileObjectIdentity
        )
        urlsBySession[sessionID, default: []].insert(location.canonicalURL)
        if let identity = location.fileObjectIdentity {
            ownersByPhysicalIdentity[identity] = proposedOwner
        }
        if priorPhysicalIdentity != location.fileObjectIdentity,
           let priorPhysicalIdentity {
            removePhysicalOwnerIfUnreferenced(
                priorPhysicalIdentity,
                sessionID: sessionID
            )
        }
        return .reserved
    }

    func release(
        _ location: WorkspaceDocumentLocation,
        for sessionID: WorkspaceDocumentSessionID
    ) {
        guard let reservation = reservationsByURL[location.canonicalURL],
              reservation.owner.sessionID == sessionID else {
            return
        }
        reservationsByURL.removeValue(forKey: location.canonicalURL)
        urlsBySession[sessionID]?.remove(location.canonicalURL)
        if urlsBySession[sessionID]?.isEmpty == true {
            urlsBySession.removeValue(forKey: sessionID)
        }

        guard let identity = reservation.physicalIdentity,
              ownersByPhysicalIdentity[identity]?.sessionID == sessionID else {
            return
        }
        removePhysicalOwnerIfUnreferenced(identity, sessionID: sessionID)
    }

    func releaseAll(for sessionID: WorkspaceDocumentSessionID) {
        let urls = urlsBySession[sessionID] ?? []
        for url in urls {
            guard let reservation = reservationsByURL[url] else { continue }
            release(
                WorkspaceDocumentLocation(
                    canonicalURL: url,
                    fileObjectIdentity: reservation.physicalIdentity
                ),
                for: sessionID
            )
        }
    }

    func beginPhysicalPublication(
        _ staged: WorkspaceDocumentStagedPackage,
        to destination: WorkspaceDocumentLocation,
        retainingPublishedOwnership: Bool,
        for sessionID: WorkspaceDocumentSessionID,
        windowID: WorkspaceWindowID
    ) -> WorkspaceDocumentPublicationReservationResult {
        let proposedOwner = ReservationOwner(
            sessionID: sessionID,
            windowID: windowID
        )
        if let existing = reservationsByURL[destination.canonicalURL]?.owner,
           existing != proposedOwner {
            return .alreadyOwned(existing.windowID)
        }
        if let existing = pendingPublications.values.first(where: {
            $0.destinationURL == destination.canonicalURL
        }) {
            return .alreadyOwned(existing.owner.windowID)
        }
        let stagedIdentity = staged.stagedObservation.location.fileObjectIdentity
        if let stagedIdentity,
           let existing = ownersByPhysicalIdentity[stagedIdentity],
           existing != proposedOwner {
            return .alreadyOwned(existing.windowID)
        }

        let publication = WorkspaceDocumentPublicationReservation()
        let claimedIdentity = stagedIdentity.map {
            ownersByPhysicalIdentity[$0] == nil
        } ?? false
        if let stagedIdentity, claimedIdentity {
            ownersByPhysicalIdentity[stagedIdentity] = proposedOwner
        }
        pendingPublications[publication] = PendingPublication(
            owner: proposedOwner,
            destinationURL: destination.canonicalURL,
            stagedPhysicalIdentity: stagedIdentity,
            retainingPublishedOwnership: retainingPublishedOwnership,
            claimedStagedPhysicalIdentity: claimedIdentity
        )
        publicationEpoch &+= 1
        return .reserved(publication)
    }

    func completePhysicalPublication(
        _ publication: WorkspaceDocumentPublicationReservation,
        at publishedLocation: WorkspaceDocumentLocation
    ) -> WorkspaceDocumentPublicationCompletionResult {
        guard let pending = pendingPublications[publication],
              pending.destinationURL == publishedLocation.canonicalURL,
              (pending.stagedPhysicalIdentity == nil
                || pending.stagedPhysicalIdentity == publishedLocation.fileObjectIdentity) else {
            endPhysicalPublication(publication)
            return .invalid
        }

        let result: WorkspaceDocumentPublicationCompletionResult
        if pending.retainingPublishedOwnership {
            switch reserve(
                publishedLocation,
                for: pending.owner.sessionID,
                windowID: pending.owner.windowID
            ) {
            case .reserved:
                result = .completed
            case .alreadyOwned(let owner):
                result = .alreadyOwned(owner)
            }
        } else {
            result = .completed
        }
        endPhysicalPublication(publication)
        return result
    }

    func cancelPhysicalPublication(
        _ publication: WorkspaceDocumentPublicationReservation
    ) {
        endPhysicalPublication(publication)
    }

    func open(
        _ request: WorkspaceOpenRequest,
        shouldProceed: @MainActor () -> Bool = { true }
    ) async -> WorkspaceOpenDisposition {
        do {
            while true {
                let admittedEpoch = try await publicationAdmissionEpochWhenQuiescent()
                let proposed = try WorkspaceDocumentLocation.canonicalized(from: request.url)
                let observed = try await io.observe(proposed.canonicalURL)
                guard observed.condition == .valid,
                      observed.location.canonicalURL == proposed.canonicalURL,
                      proposed.fileObjectIdentity == nil
                        || observed.location.fileObjectIdentity
                            == proposed.fileObjectIdentity else {
                    return .rejected(rejection(for: observed.condition))
                }

                let package = try await io.readValidated(from: observed.location)
                guard package.observation == observed else {
                    return .rejected("document-open-observation-changed")
                }
            // Validate the complete package before acquiring ownership or mutating a reusable
            // window. The store repeats this validation at installation as a defense-in-depth
            // boundary, but this preflight keeps malformed content side-effect free.
                _ = try MacScopeDocumentPackage.validatedContents(
                    manifestData: package.manifestData,
                    attachmentsByBinaryID: package.attachmentsByBinaryID,
                    reconstructionState: package.reconstructionState,
                    instructionSidecarData: package.instructionSidecarData
                )

                let currentEpoch = try await publicationAdmissionEpochWhenQuiescent()
                // A cancelled restoration may still receive valid bytes from uncooperative
                // I/O. Do not acquire ownership, activate, or recreate its closed window.
                try Task.checkCancellation()
                guard shouldProceed() else { return .rejected("document-open-cancelled") }
                guard admittedEpoch == currentEpoch else { continue }

                if let existingOwner = owner(of: observed.location) {
                    _ = windowActivator.activateWindow(existingOwner)
                    return .activatedExisting(existingOwner)
                }

                let reusableID = request.preferredReusableWindow.flatMap { candidate in
                    registry.isReusableDocumentWindow(candidate) ? candidate : nil
                }
                let windowID = reusableID ?? .fresh()
                let store: WorkspaceStore
                let session: WorkspaceDocumentSession
                if let reusableID,
                   let reusableStore = registry.storeIfPresent(for: reusableID),
                   let reusableSession = registry.documentSessionIfPresent(for: reusableID) {
                    store = reusableStore
                    session = reusableSession
                } else {
                    store = storeFactory()
                    session = WorkspaceDocumentSession(
                        sessionID: WorkspaceDocumentSessionID(rawValue: UUID()),
                        windowID: windowID,
                        source: store,
                        io: sessionIOFactory(),
                        reservations: self
                    )
                }

                do {
                    let reservation = reserve(
                        observed.location,
                        for: session.snapshot.sessionID,
                        windowID: windowID
                    )
                    guard reservation == .reserved else {
                        if reusableID == nil {
                            session.close()
                        }
                        return .rejected("document-location-owned-by-another-window")
                    }
                    try store.installValidatedPackage(package, from: observed.location)
                    try session.bindOpenedPackage(package, at: observed.location)
                    session.noteMutation(store.mutationGeneration)
                    if reusableID == nil {
                        registry.adopt(store, documentSession: session, for: windowID)
                    }
                    // Recovery may publish a cleared ledger, so bind its document writer first.
                    store.schedulePhase2DurableShellRecoveryIfNeeded()
                } catch {
                    release(observed.location, for: session.snapshot.sessionID)
                    if reusableID == nil {
                        session.close()
                    }
                    throw error
                }

                return reusableID == nil
                    ? .openedWindow(windowID)
                    : .reusedWindow(windowID)
            }
        } catch {
            return .rejected(rejection(for: error))
        }
    }

    private func publicationAdmissionEpochWhenQuiescent() async throws -> UInt64 {
        while !pendingPublications.isEmpty {
            testHooks.didWaitForPublication()
            await withCheckedContinuation { continuation in
                publicationWaiters.append(continuation)
            }
            try Task.checkCancellation()
        }
        return publicationEpoch
    }

    private func endPhysicalPublication(
        _ publication: WorkspaceDocumentPublicationReservation
    ) {
        guard let pending = pendingPublications.removeValue(forKey: publication) else {
            return
        }
        if pending.claimedStagedPhysicalIdentity,
           let stagedIdentity = pending.stagedPhysicalIdentity {
            removePhysicalOwnerIfUnreferenced(
                stagedIdentity,
                sessionID: pending.owner.sessionID
            )
        }
        guard pendingPublications.isEmpty else { return }
        let waiters = publicationWaiters
        publicationWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume() }
    }

    /// Ignores stale close callbacks from a window identity whose registry entry has already
    /// been replaced by a newer session.
    func windowDidClose(
        _ windowID: WorkspaceWindowID,
        sessionID: WorkspaceDocumentSessionID
    ) {
        guard registry.documentSessionIfPresent(for: windowID)?.snapshot.sessionID
                == sessionID else {
            return
        }
        registry.evict(windowID)
    }

    private func rejection(
        for condition: WorkspacePackageObservationCondition
    ) -> String {
        switch condition {
        case .absent:
            return "document-open-package-absent"
        case .valid:
            return "document-open-observation-mismatch"
        case .invalid:
            return "document-open-package-invalid"
        case .unverifiable:
            return "document-open-package-unverifiable"
        }
    }

    private func rejection(for error: Error) -> String {
        guard let error = error as? WorkspaceDocumentSessionError else {
            return error is CancellationError
                ? "document-open-cancelled"
                : "document-open-failed"
        }
        switch error {
        case .closed:
            return "document-session-closed"
        case .noActiveLocation:
            return "document-location-unavailable"
        case .writeAlreadyActive:
            return "document-write-already-active"
        case .unresolvedConflict:
            return "document-conflict-unresolved"
        case .invalidResolution(let reason), .operationFailed(let reason):
            return safeReason(reason)
        }
    }

    private func safeReason(_ reason: String) -> String {
        let isSafe = !reason.isEmpty
            && reason.utf8.count <= 128
            && reason.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0)
                    || $0 == "-" || $0 == "_" || $0 == "."
            }
        return isSafe ? reason : "document-open-failed"
    }

    private func removePhysicalOwnerIfUnreferenced(
        _ identity: WorkspaceFileObjectIdentity,
        sessionID: WorkspaceDocumentSessionID
    ) {
        guard ownersByPhysicalIdentity[identity]?.sessionID == sessionID else { return }
        let retainsAlias = reservationsByURL.values.contains {
            $0.owner.sessionID == sessionID && $0.physicalIdentity == identity
        }
        if !retainsAlias {
            ownersByPhysicalIdentity.removeValue(forKey: identity)
        }
    }
}
