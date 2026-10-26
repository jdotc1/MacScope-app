import Foundation

/// A complete, bounded record of a published Compare Images result. Encoding performs no file
/// I/O; the caller owns the save panel and atomic write. The record contains function identities
/// and matcher findings, never binary bytes, disassembly, or conclusions about exploitability.
enum VersionCompareExportService {
    static let suggestedFileExtension = "json"
    static let maximumBytes = 12 * 1_024 * 1_024
    private static let maximumFunctionsPerImage = 20_000
    private static let maximumFieldBytes = 1_024

    enum ExportError: LocalizedError, Equatable {
        case staleComparison
        case missingIdentity
        case inconsistentResult
        case sizeLimit

        var errorDescription: String? {
            switch self {
            case .staleComparison:
                "The compared images have changed. Re-run Compare Images before exporting."
            case .missingIdentity:
                "Both images need a recorded analysis fingerprint before exporting."
            case .inconsistentResult:
                "The comparison result no longer matches its analyzed functions. Re-run Compare Images."
            case .sizeLimit:
                "This comparison exceeds the report's size limit. Narrow the source images and compare again."
            }
        }
    }

    /// `snapshot` must be the live workspace snapshot at the instant the user chooses Export.
    /// Both slot owners and analysis fingerprints are checked again before serializing.
    static func encode(
        computation: VersionCompareComputation,
        pair: VersionComparePair,
        snapshot: WorkspaceSnapshot
    ) throws -> Data {
        guard pair.old.slot != pair.new.slot else { throw ExportError.staleComparison }
        let oldImage = try image(pair.old, in: snapshot)
        let newImage = try image(pair.new, in: snapshot)
        let result = computation.result
        let oldRefs = computation.oldFunctions
        let newRefs = computation.newFunctions

        guard computation.matcher.oldFunctions.count <= maximumFunctionsPerImage,
              computation.matcher.newFunctions.count <= maximumFunctionsPerImage else {
            throw ExportError.sizeLimit
        }
        guard let oldAnalysis = snapshot.analysis(in: pair.old.slot),
              let newAnalysis = snapshot.analysis(in: pair.new.slot) else {
            throw ExportError.staleComparison
        }
        guard oldAnalysis.functions.count <= maximumFunctionsPerImage,
              newAnalysis.functions.count <= maximumFunctionsPerImage else {
            throw ExportError.sizeLimit
        }
        // The pair's fingerprint identifies the analyzed input; compare the exact facts supplied
        // to this computation as well, so a result from another pair cannot be relabeled here.
        let currentOld = FunctionVersionFingerprintAdapter.fingerprints(from: oldAnalysis)
            .sorted(by: FunctionVersionMatcher.canonicalOrder)
        let currentNew = FunctionVersionFingerprintAdapter.fingerprints(from: newAnalysis)
            .sorted(by: FunctionVersionMatcher.canonicalOrder)
        guard currentOld == computation.matcher.oldFunctions,
              currentNew == computation.matcher.newFunctions else {
            throw ExportError.staleComparison
        }
        guard oldRefs.count == computation.matcher.oldFunctions.count,
              newRefs.count == computation.matcher.newFunctions.count else {
            throw ExportError.inconsistentResult
        }
        var oldCount = result.matches.count
        var newCount = result.matches.count
        guard oldCount <= oldRefs.count,
              newCount <= newRefs.count,
              result.removedIDs.count <= oldRefs.count - oldCount,
              result.addedIDs.count <= newRefs.count - newCount else {
            throw ExportError.inconsistentResult
        }
        oldCount += result.removedIDs.count
        newCount += result.addedIDs.count
        for group in result.unresolved {
            guard group.oldIDs.count <= oldRefs.count - oldCount,
                  group.newIDs.count <= newRefs.count - newCount else {
                throw ExportError.inconsistentResult
            }
            oldCount += group.oldIDs.count
            newCount += group.newIDs.count
        }
        guard oldCount == oldRefs.count, newCount == newRefs.count else {
            throw ExportError.inconsistentResult
        }
        for fingerprint in computation.matcher.oldFunctions {
            guard let ref = oldRefs[fingerprint.id], ref.address == fingerprint.address else {
                throw ExportError.inconsistentResult
            }
        }
        for fingerprint in computation.matcher.newFunctions {
            guard let ref = newRefs[fingerprint.id], ref.address == fingerprint.address else {
                throw ExportError.inconsistentResult
            }
        }

        var usedOld: Set<String> = []
        var usedNew: Set<String> = []
        var matches: [MatchRecord] = []
        matches.reserveCapacity(result.matches.count)
        for match in result.matches {
            let old = try function(match.oldID, in: oldRefs)
            let new = try function(match.newID, in: newRefs)
            guard old.address == match.oldAddress,
                  new.address == match.newAddress,
                  usedOld.insert(match.oldID).inserted,
                  usedNew.insert(match.newID).inserted else {
                throw ExportError.inconsistentResult
            }
            if let callerID = match.propagatedFromOldCallerID { try bounded(callerID) }
            if let callerID = match.propagatedFromNewCallerID { try bounded(callerID) }
            matches.append(MatchRecord(
                old: old, new: new, status: match.isChanged ? "changed" : "unchanged",
                basis: match.basis.rawValue, confidence: confidenceName(match.confidence),
                differences: match.differences.sorted().map(\.rawValue),
                symbolNameChanged: match.symbolNameChanged,
                propagatedFromOldCallerID: match.propagatedFromOldCallerID,
                propagatedFromNewCallerID: match.propagatedFromNewCallerID
            ))
        }
        matches.sort { ordered($0.old, $1.old) }

        var removed: [FunctionRecord] = []
        for id in result.removedIDs {
            let ref = try function(id, in: oldRefs)
            guard usedOld.insert(id).inserted else { throw ExportError.inconsistentResult }
            removed.append(ref)
        }
        removed.sort(by: ordered)

        var added: [FunctionRecord] = []
        for id in result.addedIDs {
            let ref = try function(id, in: newRefs)
            guard usedNew.insert(id).inserted else { throw ExportError.inconsistentResult }
            added.append(ref)
        }
        added.sort(by: ordered)

        var unresolved: [UnresolvedRecord] = []
        unresolved.reserveCapacity(result.unresolved.count)
        for group in result.unresolved {
            guard !group.oldIDs.isEmpty, !group.newIDs.isEmpty else {
                throw ExportError.inconsistentResult
            }
            var old: [FunctionRecord] = []
            var new: [FunctionRecord] = []
            for id in group.oldIDs {
                let ref = try function(id, in: oldRefs)
                guard usedOld.insert(id).inserted else { throw ExportError.inconsistentResult }
                old.append(ref)
            }
            for id in group.newIDs {
                let ref = try function(id, in: newRefs)
                guard usedNew.insert(id).inserted else { throw ExportError.inconsistentResult }
                new.append(ref)
            }
            old.sort(by: ordered)
            new.sort(by: ordered)
            unresolved.append(UnresolvedRecord(
                old: old, new: new, bases: group.bases.sorted().map(\.rawValue)))
        }
        unresolved.sort { lhs, rhs in
            if let a = lhs.old.first, let b = rhs.old.first { return ordered(a, b) }
            return ordered(lhs.new[0], rhs.new[0])
        }

        guard usedOld.count == oldRefs.count, usedNew.count == newRefs.count else {
            throw ExportError.inconsistentResult
        }

        var pins: [PinRecord] = []
        pins.reserveCapacity(result.manualPins.count)
        var pinnedOld: Set<String> = []
        var pinnedNew: Set<String> = []
        let acceptedManualPins = Set(result.matches.compactMap { match in
            match.basis == .manual
                ? FunctionVersionManualPin(oldID: match.oldID, newID: match.newID)
                : nil
        })
        for pin in result.manualPins {
            let old = try function(pin.oldID, in: oldRefs)
            let new = try function(pin.newID, in: newRefs)
            guard pinnedOld.insert(pin.oldID).inserted,
                  pinnedNew.insert(pin.newID).inserted,
                  acceptedManualPins.contains(pin) else {
                throw ExportError.inconsistentResult
            }
            pins.append(PinRecord(old: old, new: new))
        }
        guard acceptedManualPins.count == pins.count else { throw ExportError.inconsistentResult }
        pins.sort { ordered($0.old, $1.old) }

        let document = Document(
            schemaVersion: 1, oldImage: oldImage, newImage: newImage,
            summary: Summary(
                changed: matches.filter { $0.status == "changed" }.count,
                unchanged: matches.filter { $0.status == "unchanged" }.count,
                added: added.count, removed: removed.count,
                unresolvedGroups: unresolved.count, manualPins: pins.count),
            matches: matches, added: added, removed: removed,
            unresolved: unresolved, manualPins: pins
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(document)
        guard data.count <= maximumBytes else { throw ExportError.sizeLimit }
        return data
    }

    private static func image(_ image: VersionCompareImage, in snapshot: WorkspaceSnapshot) throws -> ImageRecord {
        guard let binary = snapshot.binary(in: image.slot),
              let analysis = snapshot.analysis(in: image.slot) else {
            throw ExportError.staleComparison
        }
        guard let fingerprint = image.analysisFingerprint,
              fingerprint.count == 64,
              fingerprint.utf8.allSatisfy({ $0.isASCIIHexDigit }),
              let currentFingerprint = analysis.analysisInputFingerprint?.overallSHA256 else {
            throw ExportError.missingIdentity
        }
        guard binary.id == image.binaryID, binary.name == image.name,
              currentFingerprint == fingerprint else { throw ExportError.staleComparison }
        try bounded(image.name)
        return ImageRecord(slot: image.slot.rawValue, binaryID: image.binaryID.uuidString,
                           name: image.name, analysisFingerprintSHA256: fingerprint)
    }

    private static func function(_ id: String, in refs: [String: VersionCompareFunctionRef]) throws -> FunctionRecord {
        guard let ref = refs[id], ref.id == id, let address = ref.address else {
            throw ExportError.inconsistentResult
        }
        try bounded(ref.id)
        try bounded(ref.name)
        return FunctionRecord(id: ref.id, address: address, name: ref.name)
    }

    private static func bounded(_ value: String) throws {
        guard value.utf8.count <= maximumFieldBytes else { throw ExportError.sizeLimit }
    }

    private static func ordered(_ lhs: FunctionRecord, _ rhs: FunctionRecord) -> Bool {
        lhs.address == rhs.address ? lhs.id < rhs.id : lhs.address < rhs.address
    }

    private static func confidenceName(_ confidence: FunctionVersionMatchConfidence) -> String {
        switch confidence {
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        case .userConfirmed: "userConfirmed"
        }
    }

    private struct Document: Encodable {
        let schemaVersion: Int
        let oldImage: ImageRecord
        let newImage: ImageRecord
        let summary: Summary
        let matches: [MatchRecord]
        let added: [FunctionRecord]
        let removed: [FunctionRecord]
        let unresolved: [UnresolvedRecord]
        let manualPins: [PinRecord]
    }

    private struct ImageRecord: Encodable {
        let slot: Int
        let binaryID: String
        let name: String
        let analysisFingerprintSHA256: String
    }

    private struct FunctionRecord: Encodable {
        let id: String
        let address: UInt64
        let name: String

        private enum CodingKeys: String, CodingKey { case id, address, name }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(address.hexAddress, forKey: .address)
            try container.encode(name, forKey: .name)
        }
    }

    private struct MatchRecord: Encodable {
        let old: FunctionRecord
        let new: FunctionRecord
        let status: String
        let basis: String
        let confidence: String
        let differences: [String]
        let symbolNameChanged: Bool
        let propagatedFromOldCallerID: String?
        let propagatedFromNewCallerID: String?
    }

    private struct UnresolvedRecord: Encodable {
        let old: [FunctionRecord]
        let new: [FunctionRecord]
        let bases: [String]
    }

    private struct PinRecord: Encodable {
        let old: FunctionRecord
        let new: FunctionRecord
    }

    private struct Summary: Encodable {
        let changed: Int
        let unchanged: Int
        let added: Int
        let removed: Int
        let unresolvedGroups: Int
        let manualPins: Int
    }
}

private extension UInt8 {
    var isASCIIHexDigit: Bool {
        (48...57).contains(self) || (65...70).contains(self) || (97...102).contains(self)
    }
}
