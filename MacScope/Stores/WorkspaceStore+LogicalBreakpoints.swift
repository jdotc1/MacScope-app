import Foundation

enum WorkspaceLegacyBreakpointMigrationError: Error, Equatable, LocalizedError {
    case tooManyTargets(Int)
    case unprovableOwnership(ImageSlot)
    case duplicateTarget(ImageSlot, UInt64)

    var errorDescription: String? {
        switch self {
        case .tooManyTargets(let count):
            "The legacy workspace contains \(count) breakpoints; at most 4096 can be migrated safely."
        case .unprovableOwnership(let slot):
            "A legacy breakpoint in image slot \(slot.rawValue) has no exact binary owner."
        case .duplicateTarget(let slot, let address):
            "Legacy breakpoint ownership is ambiguous at \(address.hexAddress) in image slot \(slot.rawValue)."
        }
    }
}

/// Complete authored fields for one logical breakpoint, excluding the stable ID and the
/// store-owned monotonic revision. Editing replaces this value atomically.
struct WorkspaceLogicalBreakpointDraft: Sendable {
    var enabled: Bool
    var target: DebuggerLogicalBreakpointTarget
    var condition: String?
    var hitPolicy: DebuggerBreakpointHitPolicy
    var actions: [DebuggerBreakpointAction]
    var disposition: DebuggerBreakpointDisposition

    init(
        enabled: Bool = true,
        target: DebuggerLogicalBreakpointTarget,
        condition: String? = nil,
        hitPolicy: DebuggerBreakpointHitPolicy = .always,
        actions: [DebuggerBreakpointAction] = [],
        disposition: DebuggerBreakpointDisposition = .stop
    ) {
        self.enabled = enabled
        self.target = target
        self.condition = condition
        self.hitPolicy = hitPolicy
        self.actions = actions
        self.disposition = disposition
    }

    init(_ specification: DebuggerLogicalBreakpointSpecification) {
        self.init(
            enabled: specification.enabled,
            target: specification.target,
            condition: specification.condition,
            hitPolicy: specification.hitPolicy,
            actions: specification.actions,
            disposition: specification.disposition
        )
    }

    fileprivate func specification(
        id: DebuggerLogicalBreakpointID,
        revision: DebuggerLogicalBreakpointRevision
    ) throws -> DebuggerLogicalBreakpointSpecification {
        try DebuggerLogicalBreakpointSpecification(
            id: id,
            revision: revision,
            enabled: enabled,
            target: target,
            condition: condition,
            hitPolicy: hitPolicy,
            actions: actions,
            disposition: disposition
        )
    }
}

enum WorkspaceLogicalBreakpointOperation: Sendable {
    case upsert(id: DebuggerLogicalBreakpointID, draft: WorkspaceLogicalBreakpointDraft)
    case delete(id: DebuggerLogicalBreakpointID)

    func applying(
        to catalog: DebuggerLogicalBreakpointCatalog
    ) throws -> WorkspaceLogicalBreakpointMutation? {
        let existing = catalog.specifications.first { specification in
            switch self {
            case .upsert(let id, _), .delete(let id): specification.id == id
            }
        }

        switch self {
        case .upsert(let id, let draft):
            if let existing {
                // Swift String equality folds canonically equivalent Unicode spellings. Authored
                // debugger text deliberately does not: its durable identity is exact UTF-8. Build
                // the validated candidate at the existing revision and use the specification's
                // byte-exact equality before deciding that this is a no-op.
                let candidate = try draft.specification(id: id, revision: existing.revision)
                if candidate == existing { return nil }
            }
            let revision = try DebuggerLogicalBreakpointRevision(validating: catalog.revision)
                .incremented()
            let specification = try draft.specification(id: id, revision: revision)
            var specifications = catalog.specifications.filter { $0.id != id }
            specifications.append(specification)
            let next = try DebuggerLogicalBreakpointCatalog(
                catalogID: catalog.catalogID,
                revision: revision.rawValue,
                specifications: specifications
            )
            let inverse = existing.map {
                WorkspaceLogicalBreakpointOperation.upsert(
                    id: $0.id,
                    draft: WorkspaceLogicalBreakpointDraft($0)
                )
            } ?? .delete(id: id)
            return WorkspaceLogicalBreakpointMutation(
                catalog: next,
                inverse: inverse,
                specification: specification
            )

        case .delete(let id):
            guard let existing else { return nil }
            let revision = try DebuggerLogicalBreakpointRevision(validating: catalog.revision)
                .incremented()
            let next = try DebuggerLogicalBreakpointCatalog(
                catalogID: catalog.catalogID,
                revision: revision.rawValue,
                specifications: catalog.specifications.filter { $0.id != id }
            )
            return WorkspaceLogicalBreakpointMutation(
                catalog: next,
                inverse: .upsert(id: id, draft: WorkspaceLogicalBreakpointDraft(existing)),
                specification: nil
            )
        }
    }
}

struct WorkspaceLogicalBreakpointMutation: Sendable {
    let catalog: DebuggerLogicalBreakpointCatalog
    let inverse: WorkspaceLogicalBreakpointOperation
    let specification: DebuggerLogicalBreakpointSpecification?
}

@MainActor
extension WorkspaceStore {
    var logicalBreakpointCatalogCoordinate: DebuggerLogicalBreakpointCatalogCoordinate {
        // A catalog can enter WorkspaceSnapshot only through its validating initializer/decoder.
        try! DebuggerLogicalBreakpointCatalogCoordinate(
            workspaceID: workspaceID,
            catalogID: snapshot.logicalBreakpointCatalog.catalogID,
            revision: snapshot.logicalBreakpointCatalog.revision
        )
    }

    var logicalBreakpointSpecifications: [DebuggerLogicalBreakpointSpecification] {
        logicalBreakpointCatalogAvailability == .available
            ? snapshot.logicalBreakpointCatalog.specifications : []
    }

    var logicalBreakpointCount: Int { logicalBreakpointSpecifications.count }

    var enabledLogicalBreakpointCount: Int {
        logicalBreakpointSpecifications.lazy.filter(\.enabled).count
    }

    func logicalBreakpoint(
        id: DebuggerLogicalBreakpointID
    ) -> DebuggerLogicalBreakpointSpecification? {
        logicalBreakpointSpecifications.first { $0.id == id }
    }

    @discardableResult
    func createLogicalBreakpoint(
        enabled: Bool = true,
        target: DebuggerLogicalBreakpointTarget,
        condition: String? = nil,
        hitPolicy: DebuggerBreakpointHitPolicy = .always,
        actions: [DebuggerBreakpointAction] = [],
        disposition: DebuggerBreakpointDisposition = .stop
    ) throws -> DebuggerLogicalBreakpointSpecification {
        let draft = WorkspaceLogicalBreakpointDraft(
            enabled: enabled,
            target: target,
            condition: condition,
            hitPolicy: hitPolicy,
            actions: actions,
            disposition: disposition
        )
        var id: DebuggerLogicalBreakpointID
        repeat {
            id = DebuggerLogicalBreakpointID(rawValue: UUID())
        } while logicalBreakpoint(id: id) != nil

        guard let mutation = try applyLogicalBreakpointOperation(
            .upsert(id: id, draft: draft),
            actionName: "Add Breakpoint"
        ), let specification = mutation.specification else {
            preconditionFailure("A fresh logical-breakpoint ID must produce one specification.")
        }
        return specification
    }

    @discardableResult
    func editLogicalBreakpoint(
        id: DebuggerLogicalBreakpointID,
        draft: WorkspaceLogicalBreakpointDraft
    ) throws -> Bool {
        guard logicalBreakpoint(id: id) != nil else { return false }
        return try applyLogicalBreakpointOperation(
            .upsert(id: id, draft: draft),
            actionName: "Edit Breakpoint"
        ) != nil
    }

    @discardableResult
    func setLogicalBreakpointEnabled(
        _ id: DebuggerLogicalBreakpointID,
        enabled: Bool
    ) throws -> Bool {
        guard let existing = logicalBreakpoint(id: id) else { return false }
        var draft = WorkspaceLogicalBreakpointDraft(existing)
        draft.enabled = enabled
        return try applyLogicalBreakpointOperation(
            .upsert(id: id, draft: draft),
            actionName: enabled ? "Enable Breakpoint" : "Disable Breakpoint"
        ) != nil
    }

    @discardableResult
    func deleteLogicalBreakpoint(_ id: DebuggerLogicalBreakpointID) throws -> Bool {
        try applyLogicalBreakpointOperation(
            .delete(id: id),
            actionName: "Delete Breakpoint"
        ) != nil
    }

    /// Package/in-memory repair boundary. The caller must obtain explicit confirmation before
    /// invoking this method; cancellation is a byte-identical no-op.
    @discardableResult
    func discardCorruptLogicalBreakpointCatalog(confirmed: Bool) -> Bool {
        guard confirmed, logicalBreakpointCatalogAvailability == .unavailable else { return false }
        installRepairedLogicalBreakpointCatalog(.freshPristine())
        return true
    }

    /// Database-backed repair uses the persistence layer's transactional delete/recreate seam
    /// before publishing the fresh coordinate to the live store.
    @discardableResult
    func discardCorruptLogicalBreakpointCatalog(
        confirmed: Bool,
        in database: WorkspaceDatabase
    ) throws -> Bool {
        guard confirmed, logicalBreakpointCatalogAvailability == .unavailable else { return false }
        guard let persistedWorkspaceID else {
            throw WorkspaceDatabase.DatabaseError.notFound
        }
        let repaired = try database.discardCorruptLogicalBreakpointCatalog(
            workspaceID: persistedWorkspaceID
        )
        installRepairedLogicalBreakpointCatalog(repaired)
        return true
    }

    /// The exact preferred-address specifications represented by one gutter location. This reads
    /// only the durable catalog; legacy instruction bits are never input authority.
    func logicalBreakpointSpecifications(
        at address: ImageAddress
    ) -> [DebuggerLogicalBreakpointSpecification] {
        guard let binary = snapshot.binary(in: address.slot) else { return [] }
        return logicalBreakpointSpecifications.filter { specification in
            guard case .preferredAddress(let owner, let preferredVA) = specification.target,
                  preferredVA == address.address,
                  owner.slot == address.slot,
                  owner.binaryID == binary.id else {
                return false
            }
            return owner.artifactIdentity == nil || owner.artifactIdentity == binary.artifactIdentity
        }
    }

    /// Enabled preferred-address gutter projection for the current exact image owner.
    func enabledLogicalBreakpointPreferredAddresses(in slot: ImageSlot) -> [UInt64] {
        guard logicalBreakpointCatalogAvailability == .available,
              let binary = snapshot.binary(in: slot) else { return [] }
        let addresses: [UInt64] = logicalBreakpointSpecifications.compactMap { specification -> UInt64? in
            guard specification.enabled,
                  case .preferredAddress(let owner, let preferredVA) = specification.target,
                  owner.slot == slot,
                  owner.binaryID == binary.id,
                  owner.artifactIdentity == nil || owner.artifactIdentity == binary.artifactIdentity else {
                return nil
            }
            return preferredVA
        }
        return Array(Set(addresses)).sorted()
    }

    /// Rebuilds the temporary instruction-bit compatibility view from the sole durable catalog.
    /// Legacy bits are never read: unavailable catalogs and non-preferred/disabled specifications
    /// project an empty gutter, while exact owner seals prevent same-VA cross-image bleed.
    @discardableResult
    static func reprojectLogicalBreakpointCompatibility(
        in snapshot: inout WorkspaceSnapshot,
        availability: DebuggerLogicalBreakpointCatalogAvailability
    ) -> Bool {
        var didChange = false
        let binaries = snapshot.binaries
        for binary in binaries {
            let addresses: Set<UInt64>
            if availability == .available {
                addresses = Set(snapshot.logicalBreakpointCatalog.specifications.compactMap {
                    specification -> UInt64? in
                    guard specification.enabled,
                          case .preferredAddress(let owner, let preferredVA) = specification.target,
                          owner.slot == binary.slot,
                          owner.binaryID == binary.id,
                          owner.artifactIdentity == nil
                            || owner.artifactIdentity == binary.artifactIdentity else {
                        return nil
                    }
                    return preferredVA
                })
            } else {
                addresses = []
            }
            if var analysis = snapshot.analysis(in: binary.slot) {
                let projectedInstructions = analysis.instructions.map { row in
                    var copy = row
                    copy.hasBreakpoint = addresses.contains(row.address)
                    return copy
                }
                if projectedInstructions != analysis.instructions {
                    analysis.instructions = projectedInstructions
                    snapshot.replaceAnalysis(analysis, in: binary.slot)
                    didChange = true
                }
            }
        }

        // Preserve the long-standing binary-less primary analysis fixture without granting legacy
        // bits authority. Such a fixture has no exact binary seal, so its projection is always empty.
        if snapshot.binaries.isEmpty,
           var analysis = snapshot.analysis(in: snapshot.primarySlot) {
            let projectedInstructions = analysis.instructions.map { row in
                var copy = row
                copy.hasBreakpoint = false
                return copy
            }
            if projectedInstructions != analysis.instructions {
                analysis.instructions = projectedInstructions
                snapshot.replaceAnalysis(analysis, in: snapshot.primarySlot)
                didChange = true
            }
        }
        return didChange
    }

    /// One-time compatibility import for snapshots produced before the durable logical catalog
    /// existed. A pristine catalog carries no authored intent, so enabled instruction bits may be
    /// lifted exactly once into owner-sealed preferred-address specifications. After this boundary
    /// the catalog is the sole authority and `reprojectLogicalBreakpointCompatibility` never reads
    /// instruction bits back into authoring state.
    static func importLegacyBreakpointBitsIfNeeded(
        in snapshot: inout WorkspaceSnapshot,
        availability: DebuggerLogicalBreakpointCatalogAvailability
    ) throws {
        guard availability == .available,
              snapshot.logicalBreakpointCatalog.isPristine else { return }

        let legacyBitCount = snapshot.analysisBySlot.values.reduce(into: 0) { count, analysis in
            count += analysis.instructions.lazy.filter(\.hasBreakpoint).count
        }
        guard legacyBitCount > 0 else { return }
        guard legacyBitCount <= 4_096 else {
            throw WorkspaceLegacyBreakpointMigrationError.tooManyTargets(legacyBitCount)
        }
        try snapshot.validateInvariants()

        var seenTargets = Set<ImageAddress>()
        let legacyTargets: [(BinaryImage, UInt64)] = try snapshot.binaries.flatMap { binary in
            try (snapshot.analysis(in: binary.slot)?.instructions ?? []).compactMap {
                row -> (BinaryImage, UInt64)? in
                guard row.hasBreakpoint else { return nil }
                let target = ImageAddress(slot: binary.slot, address: row.address)
                guard seenTargets.insert(target).inserted else {
                    throw WorkspaceLegacyBreakpointMigrationError.duplicateTarget(
                        binary.slot,
                        row.address
                    )
                }
                return (binary, row.address)
            }
        }
        guard legacyTargets.count == legacyBitCount else {
            let unownedSlot = snapshot.analysisBySlot
                .filter { _, analysis in analysis.instructions.contains(where: \.hasBreakpoint) }
                .map(\.key)
                .sorted { $0.rawValue < $1.rawValue }
                .first ?? snapshot.primarySlot
            throw WorkspaceLegacyBreakpointMigrationError.unprovableOwnership(unownedSlot)
        }

        let revision = try DebuggerLogicalBreakpointRevision(validating: 1)
        let specifications = try legacyTargets.enumerated().map { index, target in
            let (binary, address) = target
            let id = DebuggerLogicalBreakpointID(
                rawValue: UUID(
                    uuidString: String(
                        format: "00000000-0000-4000-8000-%012llx",
                        UInt64(index + 1)
                    )
                )!
            )
            return try DebuggerLogicalBreakpointSpecification(
                id: id,
                revision: revision,
                enabled: true,
                target: .preferredAddress(
                    owner: DebuggerWorkspaceImageOwnerSeal(
                        slot: binary.slot,
                        binaryID: binary.id,
                        artifactIdentity: binary.artifactIdentity
                    ),
                    preferredVA: address
                ),
                condition: nil,
                hitPolicy: .always,
                actions: [],
                disposition: .stop
            )
        }
        snapshot.logicalBreakpointCatalog = try DebuggerLogicalBreakpointCatalog(
            catalogID: snapshot.logicalBreakpointCatalog.catalogID,
            revision: 1,
            specifications: specifications
        )
    }

    static func logicalBreakpointCatalog(
        _ catalog: DebuggerLogicalBreakpointCatalog,
        remappingOwner binaryID: UUID,
        from oldSlot: ImageSlot,
        to newSlot: ImageSlot
    ) throws -> DebuggerLogicalBreakpointCatalog {
        let affected = catalog.specifications.filter {
            $0.target.logicalBreakpointOwner.slot == oldSlot
                && $0.target.logicalBreakpointOwner.binaryID == binaryID
        }
        guard !affected.isEmpty else { return catalog }
        let revision = try DebuggerLogicalBreakpointRevision(validating: catalog.revision)
            .incremented()
        let specifications = try catalog.specifications.map { specification in
            let owner = specification.target.logicalBreakpointOwner
            guard owner.slot == oldSlot, owner.binaryID == binaryID else { return specification }
            let remappedOwner = DebuggerWorkspaceImageOwnerSeal(
                slot: newSlot,
                binaryID: owner.binaryID,
                artifactIdentity: owner.artifactIdentity
            )
            var draft = WorkspaceLogicalBreakpointDraft(specification)
            draft.target = specification.target.replacingLogicalBreakpointOwner(with: remappedOwner)
            return try draft.specification(id: specification.id, revision: revision)
        }
        return try DebuggerLogicalBreakpointCatalog(
            catalogID: catalog.catalogID,
            revision: revision.rawValue,
            specifications: specifications
        )
    }
}

private extension DebuggerLogicalBreakpointTarget {
    var logicalBreakpointOwner: DebuggerWorkspaceImageOwnerSeal {
        switch self {
        case .preferredAddress(let owner, _),
             .imageOffset(let owner, _, _, _),
             .function(let owner, _, _),
             .symbol(let owner, _, _, _, _),
             .source(let owner, _, _, _, _):
            owner
        }
    }

    func replacingLogicalBreakpointOwner(
        with owner: DebuggerWorkspaceImageOwnerSeal
    ) -> DebuggerLogicalBreakpointTarget {
        switch self {
        case .preferredAddress(_, let preferredVA):
            .preferredAddress(owner: owner, preferredVA: preferredVA)
        case .imageOffset(_, let segmentName, let start, let offset):
            .imageOffset(
                owner: owner,
                segmentName: segmentName,
                expectedSegmentPreferredStart: start,
                offset: offset
            )
        case .function(_, let entry, let hint):
            .function(owner: owner, entryPreferredVA: entry, rawLinkageNameHint: hint)
        case .symbol(_, let name, let kind, let library, let cardinality):
            .symbol(
                owner: owner,
                exactRawLinkageName: name,
                kind: kind,
                libraryName: library,
                cardinality: cardinality
            )
        case .source(_, let file, let line, let column, let cardinality):
            .source(
                owner: owner,
                file: file,
                line: line,
                columnPolicy: column,
                cardinality: cardinality
            )
        }
    }
}
