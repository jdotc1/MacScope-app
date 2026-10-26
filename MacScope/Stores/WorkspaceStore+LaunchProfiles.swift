import Foundation

/// Complete authored launch-profile fields. Stable identity and monotonic revision remain owned by
/// the workspace catalog, so editing always replaces this value atomically.
struct WorkspaceLaunchProfileDraft: Sendable {
    var name: String
    var target: DebuggerLaunchProfileTarget
    var arguments: [String]
    var environment: [DebuggerLaunchProfileEnvironmentEntry]
    var workingDirectory: String?
    var standardIOPolicy: DebuggerLaunchProfileStandardIOPolicy

    init(
        name: String,
        target: DebuggerLaunchProfileTarget,
        arguments: [String] = [],
        environment: [DebuggerLaunchProfileEnvironmentEntry] = [],
        workingDirectory: String? = nil,
        standardIOPolicy: DebuggerLaunchProfileStandardIOPolicy = .inheritNoCapture
    ) {
        self.name = name
        self.target = target
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.standardIOPolicy = standardIOPolicy
    }

    init(_ profile: DebuggerLaunchProfile) {
        self.init(
            name: profile.name,
            target: profile.target,
            arguments: profile.arguments,
            environment: profile.environment,
            workingDirectory: profile.workingDirectory,
            standardIOPolicy: profile.standardIOPolicy
        )
    }

    func profile(
        id: DebuggerLaunchProfileID,
        revision: UInt64
    ) throws -> DebuggerLaunchProfile {
        try DebuggerLaunchProfile(
            id: id,
            revision: revision,
            name: name,
            target: target,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            standardIOPolicy: standardIOPolicy
        )
    }
}

private enum WorkspaceLaunchProfileSelectionIntent: Sendable {
    case preserve
    case set(DebuggerLaunchProfileID?)
}

private enum WorkspaceLaunchProfileOperation: Sendable {
    case upsert(
        id: DebuggerLaunchProfileID,
        draft: WorkspaceLaunchProfileDraft,
        insertionIndex: Int?,
        selection: WorkspaceLaunchProfileSelectionIntent
    )
    case delete(
        id: DebuggerLaunchProfileID,
        selectionAfterDeletion: WorkspaceLaunchProfileSelectionIntent
    )
    case select(DebuggerLaunchProfileID?)

    /// Workspace-image targets are authorized against the live snapshot on every upsert, including
    /// undo/redo inverse replay. A stale owner can therefore never be reintroduced after its exact
    /// binary or artifact seal has been replaced.
    func validateTargetAuthority(in snapshot: WorkspaceSnapshot) throws {
        guard case .upsert(_, let draft, _, _) = self else { return }
        guard case .workspaceImage(let owner) = draft.target else { return }
        guard let binary = snapshot.binary(in: owner.slot),
              binary.id == owner.binaryID,
              let persistedArtifact = binary.artifactIdentity,
              let ownerArtifact = owner.artifactIdentity,
              ownerArtifact == persistedArtifact else {
            throw DebuggerLaunchProfileValidationError.invalidWorkspaceOwner
        }
    }

    func applying(to catalog: DebuggerLaunchProfileCatalog) throws -> WorkspaceLaunchProfileMutation? {
        switch self {
        case .upsert(let id, let draft, let requestedIndex, let selectionIntent):
            let existingIndex = catalog.profiles.firstIndex { $0.id == id }
            let existing = existingIndex.map { catalog.profiles[$0] }
            let selectedProfileID = selectionIntent.resolved(from: catalog.selectedProfileID)
            let insertionIndex = min(
                max(0, requestedIndex ?? existingIndex ?? catalog.profiles.count),
                catalog.profiles.count - (existing == nil ? 0 : 1)
            )

            if let existing {
                let candidate = try draft.profile(id: id, revision: existing.revision)
                if try DebuggerLaunchProfileCanonicalCodec.encodeProfile(candidate)
                    == DebuggerLaunchProfileCanonicalCodec.encodeProfile(existing),
                   insertionIndex == existingIndex,
                   selectedProfileID == catalog.selectedProfileID {
                    return nil
                }
            }

            let nextRevision = try nextRevision(after: catalog.revision)
            let profile = try draft.profile(id: id, revision: nextRevision)
            var profiles = catalog.profiles.filter { $0.id != id }
            profiles.insert(profile, at: insertionIndex)
            let next = try DebuggerLaunchProfileCatalog(
                catalogID: catalog.catalogID,
                revision: nextRevision,
                profiles: profiles,
                selectedProfileID: selectedProfileID
            )
            let inverse: WorkspaceLaunchProfileOperation
            if let existing, let existingIndex {
                inverse = .upsert(
                    id: id,
                    draft: WorkspaceLaunchProfileDraft(existing),
                    insertionIndex: existingIndex,
                    selection: .set(catalog.selectedProfileID)
                )
            } else {
                inverse = .delete(
                    id: id,
                    selectionAfterDeletion: .set(catalog.selectedProfileID)
                )
            }
            return WorkspaceLaunchProfileMutation(
                catalog: next,
                inverse: inverse,
                profile: profile
            )

        case .delete(let id, let selectionAfterDeletion):
            guard let existingIndex = catalog.profiles.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            let nextRevision = try nextRevision(after: catalog.revision)
            let existing = catalog.profiles[existingIndex]
            let selectedProfileID: DebuggerLaunchProfileID?
            switch selectionAfterDeletion {
            case .preserve:
                selectedProfileID = catalog.selectedProfileID == id
                    ? nil : catalog.selectedProfileID
            case .set(let restoredSelection):
                selectedProfileID = restoredSelection
            }
            let next = try DebuggerLaunchProfileCatalog(
                catalogID: catalog.catalogID,
                revision: nextRevision,
                profiles: catalog.profiles.filter { $0.id != id },
                selectedProfileID: selectedProfileID
            )
            return WorkspaceLaunchProfileMutation(
                catalog: next,
                inverse: .upsert(
                    id: id,
                    draft: WorkspaceLaunchProfileDraft(existing),
                    insertionIndex: existingIndex,
                    selection: .set(catalog.selectedProfileID)
                ),
                profile: nil
            )

        case .select(let selectedProfileID):
            guard selectedProfileID != catalog.selectedProfileID else { return nil }
            let nextRevision = try nextRevision(after: catalog.revision)
            let next = try DebuggerLaunchProfileCatalog(
                catalogID: catalog.catalogID,
                revision: nextRevision,
                profiles: catalog.profiles,
                selectedProfileID: selectedProfileID
            )
            return WorkspaceLaunchProfileMutation(
                catalog: next,
                inverse: .select(catalog.selectedProfileID),
                profile: selectedProfileID.flatMap { next.profile(id: $0) }
            )
        }
    }

    private func nextRevision(after revision: UInt64) throws -> UInt64 {
        guard revision < UInt64(Int64.max) else {
            throw DebuggerLaunchProfileValidationError.invalidRevision
        }
        return revision + 1
    }
}

private extension WorkspaceLaunchProfileSelectionIntent {
    func resolved(from current: DebuggerLaunchProfileID?) -> DebuggerLaunchProfileID? {
        switch self {
        case .preserve: current
        case .set(let value): value
        }
    }
}

private struct WorkspaceLaunchProfileMutation: Sendable {
    let catalog: DebuggerLaunchProfileCatalog
    let inverse: WorkspaceLaunchProfileOperation
    let profile: DebuggerLaunchProfile?
}

@MainActor
extension WorkspaceStore {
    var launchProfiles: [DebuggerLaunchProfile] {
        launchProfileCatalogAvailability == .available
            ? snapshot.launchProfileCatalog.profiles : []
    }

    var selectedLaunchProfile: DebuggerLaunchProfile? {
        guard launchProfileCatalogAvailability == .available,
              let id = snapshot.launchProfileCatalog.selectedProfileID else { return nil }
        return snapshot.launchProfileCatalog.profile(id: id)
    }

    func launchProfile(id: DebuggerLaunchProfileID) -> DebuggerLaunchProfile? {
        launchProfiles.first { $0.id == id }
    }

    @discardableResult
    func createLaunchProfile(
        draft: WorkspaceLaunchProfileDraft,
        id requestedID: DebuggerLaunchProfileID? = nil
    ) throws -> DebuggerLaunchProfile {
        try ensureLaunchProfilesAvailable()
        var id = requestedID ?? DebuggerLaunchProfileID(rawValue: UUID())
        if requestedID == nil {
            while launchProfile(id: id) != nil {
                id = DebuggerLaunchProfileID(rawValue: UUID())
            }
        }
        guard launchProfile(id: id) == nil else {
            throw DebuggerLaunchProfileValidationError.duplicateProfileID
        }
        guard let mutation = try applyLaunchProfileOperation(
            .upsert(id: id, draft: draft, insertionIndex: nil, selection: .set(id)),
            actionName: "Add Launch Profile"
        ), let profile = mutation.profile else {
            preconditionFailure("A fresh launch-profile ID must produce one profile.")
        }
        return profile
    }

    @discardableResult
    func editLaunchProfile(
        id: DebuggerLaunchProfileID,
        draft: WorkspaceLaunchProfileDraft
    ) throws -> Bool {
        try ensureLaunchProfilesAvailable()
        guard launchProfile(id: id) != nil else { return false }
        return try applyLaunchProfileOperation(
            .upsert(id: id, draft: draft, insertionIndex: nil, selection: .preserve),
            actionName: "Edit Launch Profile"
        ) != nil
    }

    @discardableResult
    func renameLaunchProfile(id: DebuggerLaunchProfileID, name: String) throws -> Bool {
        try ensureLaunchProfilesAvailable()
        guard let existing = launchProfile(id: id) else { return false }
        var draft = WorkspaceLaunchProfileDraft(existing)
        draft.name = name
        return try applyLaunchProfileOperation(
            .upsert(id: id, draft: draft, insertionIndex: nil, selection: .preserve),
            actionName: "Rename Launch Profile"
        ) != nil
    }

    @discardableResult
    func duplicateLaunchProfile(
        _ sourceID: DebuggerLaunchProfileID,
        name: String,
        id requestedID: DebuggerLaunchProfileID? = nil
    ) throws -> DebuggerLaunchProfile {
        try ensureLaunchProfilesAvailable()
        guard let sourceIndex = launchProfiles.firstIndex(where: { $0.id == sourceID }) else {
            throw DebuggerLaunchProfileValidationError.duplicateProfileID
        }
        var id = requestedID ?? DebuggerLaunchProfileID(rawValue: UUID())
        if requestedID == nil {
            while launchProfile(id: id) != nil {
                id = DebuggerLaunchProfileID(rawValue: UUID())
            }
        }
        guard launchProfile(id: id) == nil else {
            throw DebuggerLaunchProfileValidationError.duplicateProfileID
        }
        var draft = WorkspaceLaunchProfileDraft(launchProfiles[sourceIndex])
        draft.name = name
        guard let mutation = try applyLaunchProfileOperation(
            .upsert(
                id: id,
                draft: draft,
                insertionIndex: sourceIndex + 1,
                selection: .set(id)
            ),
            actionName: "Duplicate Launch Profile"
        ), let profile = mutation.profile else {
            preconditionFailure("A fresh duplicate launch-profile ID must produce one profile.")
        }
        return profile
    }

    @discardableResult
    func deleteLaunchProfile(_ id: DebuggerLaunchProfileID) throws -> Bool {
        try ensureLaunchProfilesAvailable()
        return try applyLaunchProfileOperation(
            .delete(id: id, selectionAfterDeletion: .preserve),
            actionName: "Delete Launch Profile"
        ) != nil
    }

    @discardableResult
    func selectLaunchProfile(_ id: DebuggerLaunchProfileID?) throws -> Bool {
        try ensureLaunchProfilesAvailable()
        if let id, launchProfile(id: id) == nil { return false }
        return try applyLaunchProfileOperation(
            .select(id),
            actionName: "Select Launch Profile"
        ) != nil
    }

    /// Package/in-memory repair boundary. Cancellation is an exact no-op; confirmation installs a
    /// new pristine authority without mutating any other workspace catalog.
    @discardableResult
    func discardCorruptLaunchProfileCatalog(confirmed: Bool) -> Bool {
        guard confirmed, launchProfileCatalogAvailability == .unavailable else { return false }
        installRepairedLaunchProfileCatalog(.freshPristine())
        return true
    }

    /// Database-backed repair publishes only after the transactional persistence repair succeeds.
    @discardableResult
    func discardCorruptLaunchProfileCatalog(
        confirmed: Bool,
        in database: WorkspaceDatabase
    ) throws -> Bool {
        guard confirmed, launchProfileCatalogAvailability == .unavailable else { return false }
        guard let persistedWorkspaceID else {
            throw WorkspaceDatabase.DatabaseError.notFound
        }
        let repaired = try database.discardCorruptLaunchProfileCatalog(
            workspaceID: persistedWorkspaceID
        )
        installRepairedLaunchProfileCatalog(repaired)
        return true
    }

    private func applyLaunchProfileOperation(
        _ operation: WorkspaceLaunchProfileOperation,
        actionName: String
    ) throws -> WorkspaceLaunchProfileMutation? {
        guard launchProfileCatalogAvailability == .available else {
            throw WorkspaceDatabase.DatabaseError.launchProfileCatalogUnavailable
        }
        try operation.validateTargetAuthority(in: snapshot)
        guard let mutation = try operation.applying(to: snapshot.launchProfileCatalog) else {
            return nil
        }

        let manager = undoManager
        let needsExplicitGroup = !manager.groupsByEvent && !manager.isUndoing && !manager.isRedoing
        if needsExplicitGroup { manager.beginUndoGrouping() }
        defer {
            manager.setActionName(actionName)
            if needsExplicitGroup { manager.endUndoGrouping() }
        }

        let priorToken = markDocumentMutated(preservingUndoComparability: true)
        manager.registerUndo(withTarget: self) { store in
            do {
                if try store.applyLaunchProfileOperation(
                    mutation.inverse,
                    actionName: actionName
                ) != nil {
                    store.restoreDocumentDirtyToken(priorToken)
                }
            } catch {
                store.lastIssue = error.localizedDescription
            }
        }
        var next = snapshot
        next.launchProfileCatalog = mutation.catalog
        snapshot = next
        return mutation
    }

    private func ensureLaunchProfilesAvailable() throws {
        guard launchProfileCatalogAvailability == .available else {
            throw WorkspaceDatabase.DatabaseError.launchProfileCatalogUnavailable
        }
    }

}
