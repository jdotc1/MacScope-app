import Foundation

/// A reviewable source association, separate from the function matcher's binary pairs and exact DWARF links.
struct SourceFunctionCorrelation: Hashable, Codable, Sendable, Identifiable {
    let referenceLink: SourceEvidenceLink
    let targetImage: SourceLinkImageIdentity
    let targetAddress: UInt64
    let normalizedBodyHash: String
    let semanticBodyHash: String
    let size: UInt64
    let instructionCount: Int

    var id: String {
        "\(referenceLink.id):\(targetImage.slot.rawValue):\(targetImage.binaryID):\(targetImage.imageUUID):\(targetImage.architecture):\(targetImage.selectedSliceIndex.map(String.init) ?? "thin"):\(targetImage.sourceRevision.value):\(targetAddress):\(normalizedBodyHash):\(semanticBodyHash)"
    }

    func link(checkout: AcceptedLocalSourceCheckout) -> SourceEvidenceLink? {
        guard let reference = referenceLink.image,
              case .some(.debugSymbols(let uuid, let digest, _, _, _, _, _)) = referenceLink.evidence,
              let path = referenceLink.recordedPath else { return nil }
        return SourceEvidenceLink(
            image: targetImage, functionAddress: targetAddress, recordedPath: path,
            localPath: referenceLink.localPath, checkoutID: checkout.id,
            line: referenceLink.line, column: referenceLink.column,
            qualification: .versionQualifiedCandidate,
            evidence: .functionCorrelation(referenceImage: reference,
                referenceAddress: referenceLink.functionAddress, debugArtifactUUID: uuid,
                debugArtifactSHA256: digest, normalizedBodyHash: normalizedBodyHash,
                semanticBodyHash: semanticBodyHash), unresolvedReason: nil
        )
    }
}

/// Intentionally narrow first path: a source-qualified compiled reference supplies the anchor;
/// The function matcher supplies unique binary matches. Names, imports, and CFG resemblance alone cannot qualify.
enum SourceFunctionCorrelationMatcher {
    static let maximumFunctions = 512
    static let maximumInstructions = 100_000

    static func candidates(
        reference: BinaryImage, referenceAnalysis: ImageAnalysis,
        referenceBinding: SourceLinkWorkspaceState.Binding,
        target: BinaryImage, targetAnalysis: ImageAnalysis,
        targetRevision: SourceRevisionIdentity
    ) throws -> [SourceFunctionCorrelation] {
        guard withinBounds(referenceAnalysis), withinBounds(targetAnalysis) else {
            throw SourceFunctionCorrelationError.inputLimit
        }
        guard let referenceArtifact = reference.artifactIdentity, let targetArtifact = target.artifactIdentity,
              referenceArtifact.uuid == reference.metadata.uuid.flatMap(UUID.init(uuidString:)),
              targetArtifact.uuid == target.metadata.uuid.flatMap(UUID.init(uuidString:)),
              referenceArtifact.rawCPUType == targetArtifact.rawCPUType,
              referenceArtifact.rawCPUSubtype == targetArtifact.rawCPUSubtype,
              SourceLinkImageIdentity.architecture(for: reference) == SourceLinkImageIdentity.architecture(for: target),
              referenceBinding.image.sourceRevision == targetRevision,
              referenceBinding.checkout.revision == targetRevision,
              let targetImage = SourceLinkImageIdentity(
                slot: target.slot, binaryID: target.id, imageUUID: target.metadata.uuid ?? "",
                architecture: SourceLinkImageIdentity.architecture(for: target), selectedSliceIndex: target.selectedSliceIndex,
                sourceRevision: targetRevision
              ) else { return [] }
        let index = SourceCandidateIndex(
            binary: reference, sourceRevision: targetRevision,
            debugContext: referenceBinding.debugArchitecture.map {
                .init(architecture: $0, sourceRevision: targetRevision)
            }, sourceLines: referenceAnalysis.sourceLines,
            acceptedCheckouts: [referenceBinding.checkout]
        )
        guard index.image == referenceBinding.image else { return [] }
        // Exclude symbols from the function matcher's first phase: a shared name such as main must not resolve
        // otherwise ambiguous bodies or suppress a stronger contradictory body comparison.
        func anonymous(_ value: FunctionVersionFingerprint) -> FunctionVersionFingerprint {
            FunctionVersionFingerprint(
                id: value.id, address: value.address, symbolName: nil, size: value.size,
                basicBlockCount: value.basicBlockCount, edgeCount: value.edgeCount,
                cfgShapeHash: value.cfgShapeHash, normalizedBodyHash: value.normalizedBodyHash,
                semanticBodyHash: value.semanticBodyHash, instructionCount: value.instructionCount,
                calleeIDs: value.calleeIDs, importedCalleeNames: value.importedCalleeNames,
                stringReferences: value.stringReferences
            )
        }
        let old = FunctionVersionFingerprintAdapter.fingerprints(from: referenceAnalysis).map(anonymous)
        let new = FunctionVersionFingerprintAdapter.fingerprints(from: targetAnalysis).map(anonymous)
        let pairs = try FunctionVersionMatcher(old: old, new: new).match()
        // The function matcher may resolve other pairs through context and then retry body
        // uniqueness. This bounded first path requires uniqueness across both complete input sets instead.
        let oldBodyCounts = Dictionary(grouping: old.compactMap(\.normalizedBodyHash), by: { $0 }).mapValues(\.count)
        let newBodyCounts = Dictionary(grouping: new.compactMap(\.normalizedBodyHash), by: { $0 }).mapValues(\.count)
        let referenceRows = referenceAnalysis.instructions.sorted { $0.address < $1.address }
        let targetRows = targetAnalysis.instructions.sorted { $0.address < $1.address }
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
        return pairs.matches.compactMap { pair in
            guard pair.basis == .normalizedBody, pair.differences.isEmpty,
                  let lhs = oldByID[pair.oldID], let rhs = newByID[pair.newID],
                  let body = lhs.normalizedBodyHash, body == rhs.normalizedBodyHash,
                  oldBodyCounts[body] == 1, newBodyCounts[body] == 1,
                  lhs.calleeIDs != nil, rhs.calleeIDs != nil,
                  lhs.importedCalleeNames != nil, rhs.importedCalleeNames != nil,
                  lhs.stringReferences != nil, rhs.stringReferences != nil,
                  let semantic = lhs.semanticBodyHash, semantic == rhs.semanticBodyHash,
                  lhs.size > 0, lhs.size == rhs.size,
                  let count = lhs.instructionCount, count > 0, count == rhs.instructionCount,
                  completeBody(lhs, rows: referenceRows), completeBody(rhs, rows: targetRows),
                  let link = index.links(functionAddress: lhs.address).first(where: {
                      $0.qualification == .exactDebugSymbols && $0.isOpenable
                  }) else { return nil }
            return SourceFunctionCorrelation(
                referenceLink: link, targetImage: targetImage, targetAddress: rhs.address,
                normalizedBodyHash: body, semanticBodyHash: semantic,
                size: lhs.size, instructionCount: count
            )
        }
    }

    /// Both sides must cover the entire declared function, not just an identical decoded prefix.
    private static func completeBody(_ function: FunctionVersionFingerprint, rows: [InstructionRow]) -> Bool {
        let (end, overflow) = function.address.addingReportingOverflow(function.size)
        guard !overflow else { return false }
        var low = 0
        var high = rows.count
        while low < high {
            let middle = low + (high - low) / 2
            if rows[middle].address < function.address { low = middle + 1 } else { high = middle }
        }
        var cursor = function.address
        while low < rows.count, rows[low].address < end {
            let row = rows[low]
            let bytes = row.bytes.split(separator: " ")
            guard row.address == cursor, !bytes.isEmpty,
                  bytes.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else { return false }
            let (next, wrapped) = cursor.addingReportingOverflow(UInt64(bytes.count))
            guard !wrapped, next <= end else { return false }
            cursor = next
            low += 1
        }
        return cursor == end
    }

    private static func withinBounds(_ analysis: ImageAnalysis) -> Bool {
        analysis.functions.count <= maximumFunctions
            && analysis.instructions.count <= maximumInstructions
            && analysis.xrefs.count <= maximumInstructions
            && analysis.basicBlocks.count <= maximumInstructions
            && analysis.controlFlowEdges.count <= maximumInstructions
            && analysis.sourceLines.count <= maximumInstructions
            && analysis.symbols.count <= maximumInstructions
            && analysis.indirectSymbols.count <= maximumInstructions
            && analysis.stringLiterals.count <= 10_000
    }

}

enum SourceFunctionCorrelationError: LocalizedError {
    case inputLimit

    var errorDescription: String? {
        "The correlation pilot supports at most 512 functions, 100,000 instructions and related facts, and 10,000 strings per image."
    }
}
