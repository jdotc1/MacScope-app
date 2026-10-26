import Foundation

/// Image-qualified source candidates built from exact DWARF line rows and tentative compiler
/// markers. This index performs no source discovery or downloads and never treats a string marker
/// as proof of function identity.
struct SourceCandidateIndex {
    struct DebugContext: Hashable, Sendable {
        let architecture: String
        let sourceRevision: SourceRevisionIdentity

        init(architecture: String, sourceRevision: SourceRevisionIdentity) {
            self.architecture = architecture
            self.sourceRevision = sourceRevision
        }

        init?(importResult: DSYMImportResult, sourceRevision: SourceRevisionIdentity) {
            guard let architecture = importResult.matchedSliceArchitecture else { return nil }
            self.init(architecture: architecture, sourceRevision: sourceRevision)
        }
    }

    let image: SourceLinkImageIdentity?
    let debugContext: DebugContext?
    let sourceLines: [SourceLineEntry]
    let compilerMarkers: [CompilerSourceMarker]
    let acceptedCheckouts: [AcceptedLocalSourceCheckout]

    init(
        binary: BinaryImage,
        sourceRevision: SourceRevisionIdentity,
        debugContext: DebugContext?,
        sourceLines: [SourceLineEntry],
        compilerMarkers: [CompilerSourceMarker] = [],
        acceptedCheckouts: [AcceptedLocalSourceCheckout] = []
    ) {
        image = SourceLinkImageIdentity(
            slot: binary.slot,
            binaryID: binary.id,
            imageUUID: binary.metadata.uuid ?? "",
            architecture: SourceLinkImageIdentity.architecture(for: binary),
            selectedSliceIndex: binary.selectedSliceIndex,
            sourceRevision: sourceRevision
        )
        self.debugContext = debugContext
        self.sourceLines = sourceLines.sorted { $0.address < $1.address }
        self.compilerMarkers = Array(compilerMarkers.prefix(Self.maximumMarkers))
        self.acceptedCheckouts = Array(acceptedCheckouts.prefix(Self.maximumCheckouts))
    }

    static let maximumMarkers = 1_024
    static let maximumCheckouts = 64

    func links(functionAddress: UInt64) -> [SourceEvidenceLink] {
        var result: [SourceEvidenceLink] = []
        if let row = sourceLine(at: functionAddress) {
            result.append(debugLink(row: row, functionAddress: functionAddress))
        } else {
            result.append(unresolved(functionAddress: functionAddress, reason: .noLineForAddress))
        }
        result.append(contentsOf: compilerMarkers
            .filter { $0.functionAddress == nil || $0.functionAddress == functionAddress }
            .map { markerLink($0, functionAddress: functionAddress) })
        return result
    }

    private func debugLink(row: SourceLineEntry, functionAddress: UInt64) -> SourceEvidenceLink {
        guard let image else {
            return unresolved(functionAddress: functionAddress, row: row, reason: .imageHasNoUUID)
        }
        guard let artifactUUID = row.debugArtifactUUID,
              let digest = row.debugArtifactMachOSHA256,
              Self.isLowercaseSHA256(digest),
              let byteCount = row.debugArtifactMachOByteCount,
              byteCount > 0,
              let unitOffset = row.lineProgramUnitOffset,
              let fileIndex = row.fileTableIndex,
              let tablePath = row.tablePath,
              row.line > 0,
              let debugContext else {
            return unresolved(functionAddress: functionAddress, row: row, reason: .debugArtifactIncomplete)
        }
        let evidence = SourceLinkEvidence.debugSymbols(
            artifactUUID: artifactUUID,
            artifactMachOSHA256: digest,
            artifactMachOByteCount: byteCount,
            lineProgramUnitOffset: unitOffset,
            fileTableIndex: fileIndex,
            architecture: debugContext.architecture,
            sourceRevision: debugContext.sourceRevision
        )
        guard artifactUUID == image.imageUUID else {
            return unresolved(functionAddress: functionAddress, row: row,
                              evidence: evidence, reason: .debugArtifactUUIDMismatch)
        }
        guard Self.sameArchitecture(debugContext.architecture, image.architecture) else {
            return unresolved(functionAddress: functionAddress, row: row,
                              evidence: evidence, reason: .architectureMismatch)
        }
        guard debugContext.sourceRevision == image.sourceRevision else {
            return unresolved(functionAddress: functionAddress, row: row,
                              evidence: evidence, reason: .sourceRevisionMismatch)
        }
        return resolved(
            image: image,
            functionAddress: functionAddress,
            recordedPath: Self.recordedPath(tablePath),
            line: row.line,
            column: row.column > 0 ? row.column : nil,
            evidence: evidence,
            qualification: .exactDebugSymbols
        )
    }

    private func markerLink(_ marker: CompilerSourceMarker, functionAddress: UInt64) -> SourceEvidenceLink {
        guard let image else {
            return unresolved(functionAddress: functionAddress, marker: marker, reason: .imageHasNoUUID)
        }
        guard marker.sourceRevision == nil || marker.sourceRevision == image.sourceRevision else {
            return unresolved(functionAddress: functionAddress, marker: marker, reason: .sourceRevisionMismatch)
        }
        return resolved(
            image: image,
            functionAddress: functionAddress,
            recordedPath: marker.recordedPath,
            line: marker.line,
            column: marker.column,
            evidence: .compilerMarker(markerID: marker.id, description: marker.description),
            qualification: .versionQualifiedCandidate
        )
    }

    private func resolved(
        image: SourceLinkImageIdentity,
        functionAddress: UInt64,
        recordedPath: String,
        line: Int?,
        column: Int?,
        evidence: SourceLinkEvidence,
        qualification: SourceLinkQualification
    ) -> SourceEvidenceLink {
        guard let checkout = acceptedCheckouts.first(where: {
            $0.revision == image.sourceRevision && Self.contains(recordedPath, in: $0.recordedSourceRoot)
        }) else {
            let pathMatchedOtherRevision = acceptedCheckouts.contains {
                Self.contains(recordedPath, in: $0.recordedSourceRoot)
                    && $0.revision != image.sourceRevision
            }
            let revisionExists = acceptedCheckouts.contains { $0.revision == image.sourceRevision }
            return SourceEvidenceLink(
                image: image, functionAddress: functionAddress,
                recordedPath: recordedPath, localPath: nil, checkoutID: nil,
                line: line, column: column,
                qualification: .unresolved, evidence: evidence,
                unresolvedReason: pathMatchedOtherRevision
                    ? .sourceRevisionMismatch
                    : (revisionExists ? .recordedPathOutsideAcceptedRoot : .noAcceptedCheckout)
            )
        }
        guard checkout.revision == image.sourceRevision else {
            return SourceEvidenceLink(
                image: image, functionAddress: functionAddress,
                recordedPath: recordedPath, localPath: nil, checkoutID: nil,
                line: line, column: column,
                qualification: .unresolved, evidence: evidence,
                unresolvedReason: .sourceRevisionMismatch
            )
        }
        let relative = Self.relativeSuffix(of: recordedPath, below: checkout.recordedSourceRoot)
        let localPath = relative.map {
            NSString(string: checkout.localRootPath).appendingPathComponent($0)
        }
        return SourceEvidenceLink(
            image: image, functionAddress: functionAddress,
            recordedPath: recordedPath, localPath: localPath, checkoutID: checkout.id,
            line: line, column: column,
            qualification: qualification, evidence: evidence, unresolvedReason: nil
        )
    }

    private func unresolved(
        functionAddress: UInt64,
        row: SourceLineEntry? = nil,
        marker: CompilerSourceMarker? = nil,
        evidence: SourceLinkEvidence? = nil,
        reason: SourceLinkUnresolvedReason
    ) -> SourceEvidenceLink {
        SourceEvidenceLink(
            image: image, functionAddress: functionAddress,
            recordedPath: row?.tablePath.map(Self.recordedPath) ?? row?.file ?? marker?.recordedPath,
            localPath: nil, checkoutID: nil,
            line: row?.line ?? marker?.line, column: row?.column ?? marker?.column,
            qualification: .unresolved,
            evidence: evidence ?? marker.map {
                .compilerMarker(markerID: $0.id, description: $0.description)
            },
            unresolvedReason: reason
        )
    }

    private func sourceLine(at address: UInt64) -> SourceLineEntry? {
        var low = 0
        var high = sourceLines.count
        while low < high {
            let middle = (low + high) / 2
            if sourceLines[middle].address <= address { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return nil }
        let row = sourceLines[low - 1]
        return row.endSequence ? nil : row
    }

    private static func sameArchitecture(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static func recordedPath(_ path: DebuggerCanonicalSourceTablePath) -> String {
        switch path {
        case .absoluteUTF8(let value), .compilationDirectoryRelativeUTF8(let value): value
        }
    }

    private static func contains(_ path: String, in root: String) -> Bool {
        relativeSuffix(of: path, below: root) != nil
    }

    private static func relativeSuffix(of path: String, below root: String) -> String? {
        let path = NSString(string: path).standardizingPath
        let root = NSString(string: root).standardizingPath
        if root == "." {
            guard !path.hasPrefix("/"), path != "..", !path.hasPrefix("../") else { return nil }
            return path
        }
        guard path == root || path.hasPrefix(root == "/" ? root : root + "/") else { return nil }
        if path == root { return "" }
        return String(path.dropFirst(root.count + (root == "/" ? 0 : 1)))
    }
}

/// Converts a qualified candidate into a bounded local file/line target. UI callers present that
/// target in their own source viewer; this type deliberately does not launch another process.
struct SourceLinkOpener {
    var fileManager: FileManager = .default

    func target(
        for link: SourceEvidenceLink,
        origin: SourceLinkOpenOrigin,
        currentImage: SourceLinkImageIdentity,
        checkout: AcceptedLocalSourceCheckout
    ) throws -> SourceFileOpenTarget {
        guard link.isOpenable, let linkImage = link.image,
              let localPath = link.localPath else {
            throw SourceLinkOpenError.unresolved
        }
        guard linkImage == currentImage, origin.slot == currentImage.slot else {
            throw SourceLinkOpenError.staleImage
        }
        guard checkout.revision == linkImage.sourceRevision else {
            throw SourceLinkOpenError.staleSourceRevision
        }
        guard link.checkoutID == checkout.id else { throw SourceLinkOpenError.staleCheckout }

        let root = URL(fileURLWithPath: checkout.localRootPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let file = URL(fileURLWithPath: localPath, isDirectory: false)
            .standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path == "/" ? root.path : root.path + "/"
        guard file.path.hasPrefix(rootPath) else { throw SourceLinkOpenError.pathEscapesCheckout }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: file.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { throw SourceLinkOpenError.fileUnavailable }
        return SourceFileOpenTarget(
            fileURL: file, line: link.line, column: link.column,
            image: linkImage, origin: origin
        )
    }
}
