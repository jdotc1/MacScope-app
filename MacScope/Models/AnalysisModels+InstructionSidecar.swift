import Foundation

extension MacScopeDocumentPackage {
    /// The bytes, rather than a path or a second loader, travel with the admitted document.
    struct InstructionStorage {
        let manifest: WorkspacePackageManifest
        let data: Data
    }

    static func preparedInstructionStorage(
        _ original: WorkspacePackageManifest,
        instructionSidecarData: Data? = nil
    ) throws -> InstructionStorage {
        try Task.checkCancellation()
        if original.formatVersion == WorkspacePackageManifest.instructionSidecarFormatVersion {
            _ = try validatedInstructionGroups(original, data: instructionSidecarData)
            guard let instructionSidecarData else { throw instructionStorageError("missing bytes") }
            let hasInlineFlow = original.analysis?.controlFlowEdges.isEmpty == false
                || (original.imageAnalyses ?? []).contains { !$0.analysis.controlFlowEdges.isEmpty }
            let hasInlineBlocks = original.analysis?.basicBlocks.isEmpty == false
                || (original.imageAnalyses ?? []).contains { !$0.analysis.basicBlocks.isEmpty }
            let needsFlowMigration = original.instructionSidecar?.groups.contains(where: { $0.controlFlowEdgeCount != nil }) == false
                && hasInlineFlow
            let needsBlockMigration = original.instructionSidecar?.groups.contains(where: { $0.basicBlockCount != nil }) == false
                && hasInlineBlocks
            if needsFlowMigration || needsBlockMigration {
                var hydrated = try manifestByRestoringInstructions(original, instructionSidecarData: instructionSidecarData)
                hydrated.formatVersion = original.analysisFormatVersion
                hydrated.instructionSidecar = nil
                return try preparedInstructionStorage(hydrated)
            }
            return InstructionStorage(manifest: original, data: instructionSidecarData)
        }
        guard original.instructionSidecar == nil, instructionSidecarData == nil,
              (1...3).contains(original.formatVersion) else {
            throw instructionStorageError("legacy package has a sidecar")
        }
        var manifest = original
        let groups: [WorkspaceInstructionSidecarCodec.Group]
        let includesBlocks = original.analysis?.basicBlocks.isEmpty == false
            || (original.imageAnalyses ?? []).contains { !$0.analysis.basicBlocks.isEmpty }
        let includesFlow = includesBlocks || original.analysis?.controlFlowEdges.isEmpty == false
            || (original.imageAnalyses ?? []).contains { !$0.analysis.controlFlowEdges.isEmpty }
        if original.formatVersion == WorkspacePackageManifest.currentFormatVersion {
            groups = [.init(binaryID: nil, imageSlot: nil,
                            instructions: original.analysis?.instructions ?? [],
                            controlFlowEdges: includesFlow ? (original.analysis?.controlFlowEdges ?? []) : nil,
                            basicBlocks: includesBlocks ? (original.analysis?.basicBlocks ?? []) : nil)]
            manifest.analysis?.instructions = []
            if includesFlow { manifest.analysis?.controlFlowEdges = [] }
            if includesBlocks { manifest.analysis?.basicBlocks = [] }
        } else {
            groups = (original.imageAnalyses ?? []).map {
                .init(binaryID: $0.binaryID, imageSlot: $0.imageSlot, instructions: $0.analysis.instructions,
                      controlFlowEdges: includesFlow ? $0.analysis.controlFlowEdges : nil,
                      basicBlocks: includesBlocks ? $0.analysis.basicBlocks : nil)
            }
            if var images = manifest.imageAnalyses {
                for index in images.indices {
                    images[index].analysis.instructions = []
                    if includesFlow { images[index].analysis.controlFlowEdges = [] }
                    if includesBlocks { images[index].analysis.basicBlocks = [] }
                }
                manifest.imageAnalyses = images
            }
        }
        let data = try WorkspaceInstructionSidecarCodec.encode(groups)
        manifest.instructionSidecar = WorkspaceInstructionSidecarDescriptor(
            path: WorkspaceInstructionSidecarCodec.fileName,
            byteCount: UInt64(data.count), sha256: fileHash(for: data),
            analysisFormatVersion: original.formatVersion,
            groups: groups.map {
                .init(binaryID: $0.binaryID, imageSlot: $0.imageSlot, rowCount: UInt64($0.instructions.count),
                      controlFlowEdgeCount: $0.controlFlowEdges.map { UInt64($0.count) },
                      basicBlockCount: $0.basicBlocks.map { UInt64($0.count) })
            }
        )
        manifest.formatVersion = WorkspacePackageManifest.instructionSidecarFormatVersion
        // The encoder checked all row structure; preserve that work for this one save operation.
        if let descriptor = manifest.instructionSidecar {
            WorkspaceManifestDecodeScope.current?.recordInstructionGroups(groups, data: data, descriptor: descriptor)
        }
        return InstructionStorage(manifest: manifest, data: data)
    }

    static func validateInstructionSidecarDescriptor(_ manifest: WorkspacePackageManifest) throws {
        guard manifest.formatVersion == WorkspacePackageManifest.instructionSidecarFormatVersion else {
            guard manifest.instructionSidecar == nil else {
                throw instructionStorageError("sidecar requires package version 4")
            }
            return
        }
        guard let descriptor = manifest.instructionSidecar,
              descriptor.path == WorkspaceInstructionSidecarCodec.fileName,
              descriptor.byteCount >= 12,
              descriptor.byteCount <= WorkspaceInstructionSidecarCodec.maximumBytes,
              (1...3).contains(descriptor.analysisFormatVersion),
              descriptor.sha256.utf8.count == 64,
              descriptor.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              manifest.analysis?.instructions.isEmpty != false,
              (manifest.imageAnalyses ?? []).allSatisfy({ $0.analysis.instructions.isEmpty }) else {
            throw instructionStorageError("invalid descriptor or mixed inline instructions")
        }
        let includesFlow = descriptor.groups.contains { $0.controlFlowEdgeCount != nil }
        if includesFlow {
            guard descriptor.groups.allSatisfy({ $0.controlFlowEdgeCount != nil }),
                  manifest.analysis?.controlFlowEdges.isEmpty != false,
                  (manifest.imageAnalyses ?? []).allSatisfy({ $0.analysis.controlFlowEdges.isEmpty }) else {
                throw instructionStorageError("mixed inline control-flow authority")
            }
        }
        let includesBlocks = descriptor.groups.contains { $0.basicBlockCount != nil }
        if includesBlocks {
            guard includesFlow, descriptor.groups.allSatisfy({ $0.basicBlockCount != nil }),
                  manifest.analysis?.basicBlocks.isEmpty != false,
                  (manifest.imageAnalyses ?? []).allSatisfy({ $0.analysis.basicBlocks.isEmpty }) else {
                throw instructionStorageError("mixed inline basic-block authority")
            }
        }
        var totalBlockRows: UInt64 = 0
        var totalFlowRows: UInt64 = 0
        let expected: [(UUID?, ImageSlot?)] = descriptor.analysisFormatVersion == 1
            ? [(nil, nil)]
            : (manifest.imageAnalyses ?? []).map { ($0.binaryID, $0.imageSlot) }
        guard expected.count == descriptor.groups.count else {
            throw instructionStorageError("group count does not match the manifest")
        }
        var totalRows: UInt64 = 0
        for (index, pair) in zip(expected, descriptor.groups).enumerated() {
            if index & 0x3ff == 0 { try Task.checkCancellation() }
            let (identity, group) = pair
            // Every row needs at least address, flag and four string lengths (25 bytes).
            guard identity.0 == group.binaryID, identity.1 == group.imageSlot,
                  group.rowCount <= descriptor.byteCount / 25,
                  totalRows <= descriptor.byteCount / 25 - group.rowCount else {
                throw instructionStorageError("group identity or row count mismatch")
            }
            totalRows += group.rowCount
            if let count = group.controlFlowEdgeCount {
                let limit = min(descriptor.byteCount, WorkspaceInstructionSidecarCodec.maximumControlFlowBytes) / 36
                guard count <= limit, totalFlowRows <= limit - count else {
                    throw instructionStorageError("control-flow row count exceeds its independent cap")
                }
                totalFlowRows += count
            }
            if let count = group.basicBlockCount {
                let limit = min(descriptor.byteCount, WorkspaceInstructionSidecarCodec.maximumBasicBlockBytes)
                    / WorkspaceInstructionSidecarCodec.basicBlockRowBytes
                guard count <= limit, totalBlockRows <= limit - count else {
                    throw instructionStorageError("basic-block row count exceeds its independent cap")
                }
                totalBlockRows += count
            }
        }
    }

    static func validatedInstructionGroups(
        _ manifest: WorkspacePackageManifest,
        data: Data?
    ) throws -> [WorkspaceInstructionSidecarCodec.Group] {
        try validateInstructionSidecarDescriptor(manifest)
        guard let descriptor = manifest.instructionSidecar else {
            guard data == nil else { throw instructionStorageError("undeclared bytes") }
            return []
        }
        guard let data, UInt64(data.count) == descriptor.byteCount else {
            throw instructionStorageError("missing bytes or size mismatch")
        }
        let scope = WorkspaceManifestDecodeScope.current
        if let cached = scope?.instructionGroups(for: data, descriptor: descriptor) { return cached }
        guard fileHash(for: data) == descriptor.sha256 else {
            throw instructionStorageError("SHA-256 mismatch")
        }
        let groups = try WorkspaceInstructionSidecarCodec.decode(data, groups: descriptor.groups)
        scope?.recordInstructionGroups(groups, data: data, descriptor: descriptor)
        return groups
    }

    static func manifestByRestoringInstructions(
        _ manifest: WorkspacePackageManifest,
        instructionSidecarData: Data?
    ) throws -> WorkspacePackageManifest {
        let groups = try validatedInstructionGroups(manifest, data: instructionSidecarData)
        guard manifest.instructionSidecar != nil else { return manifest }
        var hydrated = manifest
        if manifest.analysisFormatVersion == WorkspacePackageManifest.currentFormatVersion {
            if !groups[0].instructions.isEmpty || groups[0].controlFlowEdges != nil || groups[0].basicBlocks != nil {
                hydrated.analysis = hydrated.analysis ?? WorkspacePackageAnalysis()
                hydrated.analysis?.instructions = groups[0].instructions
                if let edges = groups[0].controlFlowEdges { hydrated.analysis?.controlFlowEdges = edges }
                if let blocks = groups[0].basicBlocks { hydrated.analysis?.basicBlocks = blocks }
            }
        } else if var images = hydrated.imageAnalyses {
            for index in images.indices {
                images[index].analysis.instructions = groups[index].instructions
                if let edges = groups[index].controlFlowEdges { images[index].analysis.controlFlowEdges = edges }
                if let blocks = groups[index].basicBlocks { images[index].analysis.basicBlocks = blocks }
            }
            hydrated.imageAnalyses = images
        }
        return hydrated
    }

    static func readInstructionSidecar(
        for manifest: WorkspacePackageManifest,
        in packageURL: URL
    ) throws -> Data? {
        try validateInstructionSidecarDescriptor(manifest)
        guard let descriptor = manifest.instructionSidecar else { return nil }
        return try readRegularFile(
            at: packageURL.appendingPathComponent(descriptor.path), relativeTo: packageURL,
            maximumByteCount: Int(descriptor.byteCount)
        )
    }

    static func instructionStorageError(_ reason: String) -> ReconstructionPackageValidationError {
        .stateGraphInvalid("instruction sidecar: \(reason)")
    }
}
