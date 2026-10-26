import Foundation

// MARK: - WS-23 VM region and memory inspection models

struct DebuggerMemoryRange: Hashable, Sendable {
    let start: UInt64
    let byteCount: UInt64

    init?(start: UInt64, byteCount: UInt64) {
        guard byteCount > 0,
              !start.addingReportingOverflow(byteCount - 1).overflow else {
            return nil
        }
        self.start = start
        self.byteCount = byteCount
    }

    var lastInclusive: UInt64 {
        start + byteCount - 1
    }

    func contains(_ address: UInt64) -> Bool {
        address >= start && address - start < byteCount
    }

    func contains(_ other: DebuggerMemoryRange) -> Bool {
        other.start >= start && other.lastInclusive <= lastInclusive
    }
}

struct DebuggerVMRegionPermissions: OptionSet, Hashable, Sendable {
    let rawValue: UInt8

    static let read = DebuggerVMRegionPermissions(rawValue: 1 << 0)
    static let write = DebuggerVMRegionPermissions(rawValue: 1 << 1)
    static let execute = DebuggerVMRegionPermissions(rawValue: 1 << 2)
}

struct DebuggerVMRegionInspection: Hashable, Identifiable, Sendable {
    static let maximumPathUTF8Bytes = 4_096

    let id: DebuggerMemoryRange
    let coordinate: DebuggerInspectionCoordinate
    let range: DebuggerMemoryRange
    let permissions: DebuggerVMRegionPermissions
    let mappedPath: String?
    let moduleInstanceID: DebuggerRuntimeModuleInstanceID?
    let workspaceCoordinate: DebuggerWorkspaceArtifactCoordinate?

    init?(
        coordinate: DebuggerInspectionCoordinate,
        range: DebuggerMemoryRange,
        permissions: DebuggerVMRegionPermissions,
        mappedPath: String? = nil,
        moduleInstanceID: DebuggerRuntimeModuleInstanceID? = nil,
        workspaceCoordinate: DebuggerWorkspaceArtifactCoordinate? = nil
    ) {
        guard !permissions.isEmpty,
              mappedPath.map(Self.isValidPath) ?? true,
              (moduleInstanceID == nil) == (workspaceCoordinate == nil) else {
            return nil
        }
        self.id = range
        self.coordinate = coordinate
        self.range = range
        self.permissions = permissions
        self.mappedPath = mappedPath
        self.moduleInstanceID = moduleInstanceID
        self.workspaceCoordinate = workspaceCoordinate
    }

    var isReadable: Bool { permissions.contains(.read) }
    var isWritable: Bool { permissions.contains(.write) }
    var isExecutable: Bool { permissions.contains(.execute) }

    func contains(_ range: DebuggerMemoryRange) -> Bool {
        self.range.contains(range)
    }

    private static func isValidPath(_ path: String) -> Bool {
        path.hasPrefix("/")
            && path.utf8.count <= maximumPathUTF8Bytes
            && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

enum DebuggerMemoryPreviewDiagnostic: String, Hashable, Sendable {
    case unreadableRegion
    case nonWritableRegion
    case unmappedHole
    case fault
    case truncated
    case stale
}

struct DebuggerMemoryPreview: Hashable, Sendable {
    static let maximumPreviewByteCount = 4_096

    let coordinate: DebuggerInspectionCoordinate
    let requestedRange: DebuggerMemoryRange
    let actualRange: DebuggerMemoryRange
    let bytes: [UInt8]
    let region: DebuggerVMRegionInspection
    let diagnostics: Set<DebuggerMemoryPreviewDiagnostic>

    init?(
        coordinate: DebuggerInspectionCoordinate,
        requestedRange: DebuggerMemoryRange,
        actualRange: DebuggerMemoryRange,
        bytes: [UInt8],
        region: DebuggerVMRegionInspection,
        diagnostics: Set<DebuggerMemoryPreviewDiagnostic> = []
    ) {
        guard region.coordinate == coordinate,
              region.contains(requestedRange),
              requestedRange.contains(actualRange),
              actualRange.byteCount == UInt64(bytes.count),
              !bytes.isEmpty,
              bytes.count <= Self.maximumPreviewByteCount else {
            return nil
        }
        self.coordinate = coordinate
        self.requestedRange = requestedRange
        self.actualRange = actualRange
        self.bytes = bytes
        self.region = region
        self.diagnostics = diagnostics
    }

    var previewText: String {
        bytes.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    func freshness(
        currentStop: DebuggerStopCoordinate?,
        currentAuthority: DebuggerSessionTargetAuthority?,
        currentThread: DebuggerThreadIdentity?,
        currentFrame: DebuggerFrameIdentity?,
        processState: DebuggerProcessState,
        runtimeModuleEvidenceChanged: Bool = false
    ) -> DebuggerInspectionFreshness {
        DebuggerInspectionFreshnessPolicy.evaluate(
            cached: coordinate,
            currentStop: currentStop,
            currentAuthority: currentAuthority,
            currentThread: currentThread,
            currentFrame: currentFrame,
            processState: processState,
            runtimeModuleEvidenceChanged: runtimeModuleEvidenceChanged
        )
    }
}

enum DebuggerMemoryWritePreviewAuthorization: Hashable, Sendable {
    case authorized(DebuggerMemoryPreview)
    case rejected(DebuggerMemoryWritePreviewRejection)
}

enum DebuggerMemoryWritePreviewRejection: String, Hashable, Sendable {
    case stalePreview
    case outsidePreview
    case outsideRegion
    case nonWritableRegion
    case emptyWrite
    case oversizedWrite
}

enum DebuggerMemoryInspectionPolicy {
    static func preview(
        coordinate: DebuggerInspectionCoordinate,
        requestedRange: DebuggerMemoryRange,
        bytes: [UInt8],
        in region: DebuggerVMRegionInspection,
        faulted: Bool = false
    ) -> DebuggerMemoryPreview? {
        guard region.contains(requestedRange) else { return nil }
        var diagnostics = Set<DebuggerMemoryPreviewDiagnostic>()
        if !region.isReadable { diagnostics.insert(.unreadableRegion) }
        if !region.isWritable { diagnostics.insert(.nonWritableRegion) }
        if faulted { diagnostics.insert(.fault) }
        if UInt64(bytes.count) < requestedRange.byteCount { diagnostics.insert(.truncated) }
        guard let actualRange = DebuggerMemoryRange(
            start: requestedRange.start,
            byteCount: UInt64(bytes.count)
        ) else { return nil }
        return DebuggerMemoryPreview(
            coordinate: coordinate,
            requestedRange: requestedRange,
            actualRange: actualRange,
            bytes: bytes,
            region: region,
            diagnostics: diagnostics
        )
    }

    static func authorizeWrite(
        from preview: DebuggerMemoryPreview,
        writeStart: UInt64,
        byteCount: Int,
        currentStop: DebuggerStopCoordinate?,
        currentAuthority: DebuggerSessionTargetAuthority?,
        currentThread: DebuggerThreadIdentity?,
        currentFrame: DebuggerFrameIdentity?,
        processState: DebuggerProcessState
    ) -> DebuggerMemoryWritePreviewAuthorization {
        guard byteCount > 0 else { return .rejected(.emptyWrite) }
        guard byteCount <= DebuggerMemoryWriteRequest.maximumByteCount,
              let writeRange = DebuggerMemoryRange(start: writeStart, byteCount: UInt64(byteCount)) else {
            return .rejected(.oversizedWrite)
        }
        guard case .fresh = preview.freshness(
            currentStop: currentStop,
            currentAuthority: currentAuthority,
            currentThread: currentThread,
            currentFrame: currentFrame,
            processState: processState
        ) else {
            return .rejected(.stalePreview)
        }
        guard preview.region.isWritable else {
            return .rejected(.nonWritableRegion)
        }
        guard preview.region.contains(writeRange) else {
            return .rejected(.outsideRegion)
        }
        guard preview.actualRange.contains(writeRange) else {
            return .rejected(.outsidePreview)
        }
        return .authorized(preview)
    }
}
