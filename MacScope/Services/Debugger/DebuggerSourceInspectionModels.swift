import Foundation

// MARK: - WS-23 source/debug-artifact inspection models

struct DebuggerSourceDebugArtifactIdentity: Hashable, Sendable {
    let uuid: UUID
    let selectedMachOSHA256: String
    let selectedMachOByteCount: UInt64

    init?(
        uuid: UUID,
        selectedMachOSHA256: String,
        selectedMachOByteCount: UInt64
    ) {
        guard Self.isLowercaseSHA256(selectedMachOSHA256),
              selectedMachOByteCount > 0 else {
            return nil
        }
        self.uuid = uuid
        self.selectedMachOSHA256 = selectedMachOSHA256
        self.selectedMachOByteCount = selectedMachOByteCount
    }

    init?(sourceLine: SourceLineEntry) {
        guard let uuid = sourceLine.debugArtifactUUID,
              let sha256 = sourceLine.debugArtifactMachOSHA256,
              let byteCount = sourceLine.debugArtifactMachOByteCount else {
            return nil
        }
        self.init(
            uuid: uuid,
            selectedMachOSHA256: sha256,
            selectedMachOByteCount: byteCount
        )
    }

    func matches(binaryArtifactIdentity identity: MachOSliceArtifactIdentity) -> Bool {
        guard let binaryUUID = identity.uuid else { return false }
        return binaryUUID == uuid
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

struct DebuggerSourceFileInspectionIdentity: Hashable, Sendable {
    let file: DebuggerCanonicalSourceFileIdentity
    let line: UInt32
    let column: UInt32
    let preferredVA: UInt64

    init?(
        sourceLine: SourceLineEntry
    ) {
        guard !sourceLine.endSequence,
              let line = UInt32(exactly: sourceLine.line),
              let column = UInt32(exactly: sourceLine.column),
              let uuid = sourceLine.debugArtifactUUID,
              let sha256 = sourceLine.debugArtifactMachOSHA256,
              let byteCount = sourceLine.debugArtifactMachOByteCount,
              let unitOffset = sourceLine.lineProgramUnitOffset,
              let fileTableIndex = sourceLine.fileTableIndex,
              let tablePath = sourceLine.tablePath,
              let file = try? DebuggerCanonicalSourceFileIdentity(
                  debugArtifactUUID: uuid,
                  debugArtifactMachOSHA256: sha256,
                  debugArtifactMachOByteCount: byteCount,
                  lineProgramUnitOffset: unitOffset,
                  fileTableIndex: fileTableIndex,
                  tablePath: tablePath
              ) else {
            return nil
        }
        self.file = file
        self.line = line
        self.column = column
        preferredVA = sourceLine.address
    }
}

struct DebuggerSourceInspectionContext: Hashable, Sendable {
    let coordinate: DebuggerInspectionCoordinate
    let mappingKey: DebuggerRuntimeMappingProjectionKey
    let moduleInstanceID: DebuggerRuntimeModuleInstanceID
    let workspaceCoordinate: DebuggerWorkspaceArtifactCoordinate
    let runtimeAddress: UInt64
    let imageAddress: ImageAddress
    let source: DebuggerSourceFileInspectionIdentity
    let debugArtifact: DebuggerSourceDebugArtifactIdentity

    init?(
        coordinate: DebuggerInspectionCoordinate,
        resolvedAddress: DebuggerResolvedStaticAddress,
        source: DebuggerSourceFileInspectionIdentity
    ) {
        guard resolvedAddress.imageAddress.slot == resolvedAddress.workspaceCoordinate.slot,
              resolvedAddress.imageAddress.address == source.preferredVA,
              let debugArtifact = DebuggerSourceDebugArtifactIdentity(
                  uuid: source.file.debugArtifactUUID,
                  selectedMachOSHA256: source.file.debugArtifactMachOSHA256,
                  selectedMachOByteCount: source.file.debugArtifactMachOByteCount
              ),
              debugArtifact.matches(binaryArtifactIdentity: resolvedAddress.workspaceCoordinate.artifactIdentity) else {
            return nil
        }
        self.coordinate = coordinate
        mappingKey = resolvedAddress.projectionKey
        moduleInstanceID = resolvedAddress.moduleInstanceID
        workspaceCoordinate = resolvedAddress.workspaceCoordinate
        runtimeAddress = resolvedAddress.runtimeAddress
        imageAddress = resolvedAddress.imageAddress
        self.source = source
        self.debugArtifact = debugArtifact
    }
}

enum DebuggerSourceInspectionResolution: Hashable, Sendable {
    case resolved(DebuggerSourceInspectionContext)
    case unavailable(DebuggerSourceInspectionUnavailableReason)
    case ambiguous([DebuggerSourceFileInspectionIdentity])
    case stale(DebuggerInspectionStaleReason)
}

enum DebuggerSourceInspectionUnavailableReason: String, Hashable, Sendable {
    case noSourceEvidence
    case noDebugArtifactSeal
    case debugArtifactMismatch
    case focusDebuggedImageMismatch
    case unmappedRuntimeAddress
}

enum DebuggerSourceInspectionFreshness: Hashable, Sendable {
    case fresh(DebuggerSourceInspectionContext)
    case stale(DebuggerInspectionStaleReason)
    case unavailable(DebuggerSourceInspectionUnavailableReason)
    case failed(String)
}

enum DebuggerSourceInspectionResolver {
    static func resolve(
        coordinate: DebuggerInspectionCoordinate,
        resolvedAddress: DebuggerResolvedStaticAddress?,
        sourceLines: [SourceLineEntry],
        focusedImageSlot: ImageSlot? = nil
    ) -> DebuggerSourceInspectionResolution {
        guard let resolvedAddress else {
            return .unavailable(.unmappedRuntimeAddress)
        }
        if let focusedImageSlot,
           focusedImageSlot != resolvedAddress.imageAddress.slot {
            return .unavailable(.focusDebuggedImageMismatch)
        }

        let candidates = sourceLines
            .filter { $0.address == resolvedAddress.imageAddress.address }
            .compactMap(DebuggerSourceFileInspectionIdentity.init(sourceLine:))

        let uniqueCandidates = Array(Set(candidates)).sorted(by: sourcePrecedes)
        switch uniqueCandidates.count {
        case 0:
            let hadSourceRow = sourceLines.contains {
                !$0.endSequence && $0.address == resolvedAddress.imageAddress.address
            }
            return .unavailable(hadSourceRow ? .noDebugArtifactSeal : .noSourceEvidence)
        case 1:
            guard let context = DebuggerSourceInspectionContext(
                coordinate: coordinate,
                resolvedAddress: resolvedAddress,
                source: uniqueCandidates[0]
            ) else {
                return .unavailable(.debugArtifactMismatch)
            }
            return .resolved(context)
        default:
            return .ambiguous(uniqueCandidates)
        }
    }

    private static func sourcePrecedes(
        _ lhs: DebuggerSourceFileInspectionIdentity,
        _ rhs: DebuggerSourceFileInspectionIdentity
    ) -> Bool {
        if lhs.preferredVA != rhs.preferredVA { return lhs.preferredVA < rhs.preferredVA }
        if lhs.line != rhs.line { return lhs.line < rhs.line }
        if lhs.column != rhs.column { return lhs.column < rhs.column }
        return lhs.file.fileTableIndex < rhs.file.fileTableIndex
    }
}

enum DebuggerSourceInspectionFreshnessPolicy {
    static func evaluate(
        cached context: DebuggerSourceInspectionContext,
        currentStop: DebuggerStopCoordinate?,
        currentAuthority: DebuggerSessionTargetAuthority?,
        currentThread: DebuggerThreadIdentity?,
        currentFrame: DebuggerFrameIdentity?,
        processState: DebuggerProcessState,
        currentMappingKey: DebuggerRuntimeMappingProjectionKey?,
        currentWorkspaceCoordinate: DebuggerWorkspaceArtifactCoordinate?,
        focusedImageSlot: ImageSlot?,
        debugArtifactEvidenceChanged: Bool = false
    ) -> DebuggerSourceInspectionFreshness {
        switch DebuggerInspectionFreshnessPolicy.evaluate(
            cached: context.coordinate,
            currentStop: currentStop,
            currentAuthority: currentAuthority,
            currentThread: currentThread,
            currentFrame: currentFrame,
            processState: processState,
            debugArtifactEvidenceChanged: debugArtifactEvidenceChanged
        ) {
        case .fresh:
            break
        case .stale(let reason):
            return .stale(reason)
        case .unavailable:
            return .unavailable(.noSourceEvidence)
        case .failed(let reason):
            return .failed(reason)
        }

        guard let currentMappingKey,
              currentMappingKey == context.mappingKey else {
            return .stale(.runtimeModuleEvidenceChanged)
        }
        guard let currentWorkspaceCoordinate,
              currentWorkspaceCoordinate == context.workspaceCoordinate else {
            return .stale(.debugArtifactEvidenceChanged)
        }
        if let focusedImageSlot,
           focusedImageSlot != context.imageAddress.slot {
            return .unavailable(.focusDebuggedImageMismatch)
        }
        return .fresh(context)
    }
}
