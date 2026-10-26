import Foundation

/// A bounded, source-backed view of one accepted function pair. The matcher establishes the
/// function correspondence; instruction positions and basic-block IDs do not cross image versions.
struct VersionCompareInstructionDetail {
    struct Side {
        let image: VersionCompareImage
        let function: VersionCompareFunctionRef
        let endAddress: UInt64
        let instructions: [InstructionRow]
        let totalInstructionCount: Int
        let context: VersionCompareChangeContext

        var omittedInstructionCount: Int { totalInstructionCount - instructions.count }
    }

    enum Projection {
        case ready(VersionCompareInstructionDetail)
        case unavailable(String)
    }

    static let maximumRowsPerSide = 300

    let old: Side
    let new: Side
    let basis: FunctionVersionMatchBasis
    let confidence: FunctionVersionMatchConfidence
    let differences: [FunctionVersionDifference]

    /// Revalidates a rendered row against the published match and the live workspace before
    /// reading any disassembly. A missing analysis fingerprint cannot fence a later re-analysis.
    static func project(
        row: VersionCompareRow,
        pair: VersionComparePair,
        computation: VersionCompareComputation,
        snapshot: WorkspaceSnapshot
    ) -> Projection {
        guard row.status == .changed || row.status == .unchanged,
              let oldRef = row.old, let newRef = row.new,
              let oldAddress = oldRef.address, let newAddress = newRef.address,
              let match = computation.result.match(forOldID: oldRef.id),
              match.newID == newRef.id,
              match.oldAddress == oldAddress, match.newAddress == newAddress,
              computation.report.rows.contains(row),
              pair.old.slot != pair.new.slot else {
            return .unavailable("This function pair is no longer an accepted comparison result.")
        }

        guard let oldAnalysis = currentAnalysis(for: pair.old, in: snapshot),
              let newAnalysis = currentAnalysis(for: pair.new, in: snapshot) else {
            return .unavailable("An image or its analysis changed. Re-run Compare Images to inspect this pair.")
        }

        let currentOld = FunctionVersionFingerprintAdapter.fingerprints(from: oldAnalysis)
            .sorted(by: FunctionVersionMatcher.canonicalOrder)
        let currentNew = FunctionVersionFingerprintAdapter.fingerprints(from: newAnalysis)
            .sorted(by: FunctionVersionMatcher.canonicalOrder)
        guard currentOld == computation.matcher.oldFunctions,
              currentNew == computation.matcher.newFunctions else {
            return .unavailable("The compared function inputs changed. Re-run Compare Images to inspect this pair.")
        }

        guard let oldSide = side(image: pair.old, function: oldRef, analysis: oldAnalysis, snapshot: snapshot),
              let newSide = side(image: pair.new, function: newRef, analysis: newAnalysis, snapshot: snapshot) else {
            return .unavailable("The selected function no longer has a unique, valid instruction range. Re-run the analysis.")
        }

        return .ready(VersionCompareInstructionDetail(
            old: oldSide, new: newSide, basis: match.basis,
            confidence: match.confidence, differences: match.differences
        ))
    }

    private static func currentAnalysis(
        for image: VersionCompareImage,
        in snapshot: WorkspaceSnapshot
    ) -> ImageAnalysis? {
        guard snapshot.binary(in: image.slot)?.id == image.binaryID,
              let expectedFingerprint = image.analysisFingerprint,
              let analysis = snapshot.analysis(in: image.slot),
              analysis.analysisInputFingerprint?.overallSHA256 == expectedFingerprint else {
            return nil
        }
        return analysis
    }

    private static func side(
        image: VersionCompareImage,
        function: VersionCompareFunctionRef,
        analysis: ImageAnalysis,
        snapshot: WorkspaceSnapshot
    ) -> Side? {
        guard let address = function.address else { return nil }
        let candidates = analysis.functions.filter { $0.id.uuidString == function.id }
        guard candidates.count == 1, let source = candidates.first,
              source.startAddress == address,
              source.endAddress > source.startAddress,
              !analysis.functions.contains(where: { other in
                  other.id != source.id && other.startAddress < source.endAddress
                      && source.startAddress < other.endAddress
              }) else {
            return nil
        }

        let rows = analysis.instructions
            .filter { $0.address >= source.startAddress && $0.address < source.endAddress }
            .sorted { $0.address < $1.address }
        guard !rows.indices.dropFirst().contains(where: { rows[$0 - 1].address == rows[$0].address }) else {
            return nil
        }
        return Side(image: image, function: function, endAddress: source.endAddress,
                    instructions: Array(rows.prefix(maximumRowsPerSide)),
                    totalInstructionCount: rows.count,
                    context: VersionCompareChangeContext.project(
                        function: source, functions: analysis.functions,
                        xrefs: snapshot.effectiveXRefs(in: image.slot),
                        catalog: snapshot.typeCatalog(in: image.slot)))
    }
}

/// Image-local links around one function. These are observed relationships, not additional
/// old/new matches. A bounded list keeps large call graphs usable in the detail sheet.
struct VersionCompareChangeContext {
    struct Link: Identifiable, Equatable {
        let id: String
        let label: String
        let address: UInt64
        let kind: String
    }

    static let maximumLinksPerGroup = 24

    let callers: [Link]
    let incomingReferences: [Link]
    let outgoingReferences: [Link]
    let typeUsers: [Link]
    let callerCount: Int
    let incomingCount: Int
    let outgoingCount: Int
    let typeUserCount: Int

    var allLinks: [Link] { callers + incomingReferences + outgoingReferences + typeUsers }

    static func project(
        function: FunctionSummary,
        functions: [FunctionSummary],
        xrefs: [XRef],
        catalog: ImageTypeCatalog
    ) -> VersionCompareChangeContext {
        let range = function.startAddress..<function.endAddress
        func name(at address: UInt64) -> String {
            guard let owner = functions.first(where: {
                $0.startAddress <= address && address < $0.endAddress
            }) else { return address.hexAddress }
            let offset = address - owner.startAddress
            return offset == 0 ? owner.name : "\(owner.name)+0x\(String(offset, radix: 16))"
        }
        func sorted(_ rows: [Link]) -> [Link] {
            rows.sorted {
                if $0.address != $1.address { return $0.address < $1.address }
                if $0.kind != $1.kind { return $0.kind < $1.kind }
                return $0.id < $1.id
            }
        }
        let inbound = xrefs.filter { range.contains($0.to) && !range.contains($0.from) }
        let callers = sorted(inbound.filter { $0.kind == XRefKind.call }.map {
            Link(id: "call:\($0.id)", label: name(at: $0.from),
                 address: $0.from, kind: "call")
        })
        let incoming = sorted(inbound.filter { $0.kind != XRefKind.call }.map {
            Link(id: "in:\($0.id)", label: name(at: $0.from),
                 address: $0.from, kind: $0.kind)
        })
        let outgoing = sorted(xrefs.filter {
            range.contains($0.from) && !range.contains($0.to)
        }.map {
            Link(id: "out:\($0.id)", label: "\(name(at: $0.from)) → \(name(at: $0.to))",
                 address: $0.to, kind: $0.kind)
        })
        let users = sorted(catalog.entries.flatMap { entry in
            entry.users.filter { range.contains($0) }.map { address in
                Link(id: "type:\(entry.id):\(address)", label: entry.name,
                     address: address, kind: entry.kind.rawValue)
            }
        })
        return VersionCompareChangeContext(
            callers: Array(callers.prefix(maximumLinksPerGroup)),
            incomingReferences: Array(incoming.prefix(maximumLinksPerGroup)),
            outgoingReferences: Array(outgoing.prefix(maximumLinksPerGroup)),
            typeUsers: Array(users.prefix(maximumLinksPerGroup)),
            callerCount: callers.count, incomingCount: incoming.count,
            outgoingCount: outgoing.count, typeUserCount: users.count)
    }
}
