import Foundation

// RX-01: projects a Compare Images match result plus both images' authored overrides into the
// review rows the user selects from, and into the planner's inputs. Pure and value-typed: it reads
// a `WorkspaceSnapshot` and never touches the store.

/// One matched pair whose OLD function start carries authored text, i.e. one reviewable row.
struct AnnotationTransferCandidate: Identifiable, Hashable, Sendable {
    enum SkipReason: String, Hashable, Sendable {
        /// Incoming or existing text is over the planner's byte limits or contains NUL.
        case textLimit
        /// The new address is not a function start in the new analysis (defensive).
        case notFunctionStart
    }

    /// `"match:<oldID>><newID>"`, the same spelling as `VersionCompareRow.id`.
    let id: String
    let oldID: String
    let newID: String
    let oldAddress: UInt64
    let newAddress: UInt64
    let basis: FunctionVersionMatchBasis
    let confidence: FunctionVersionMatchConfidence
    let differences: [FunctionVersionDifference]
    let symbolNameChanged: Bool
    /// Authored text at the old function start (normalized; never analysis symbols).
    let incoming: TransferableAnnotation
    /// Authored text already at the new function start (normalized).
    let existing: TransferableAnnotation
    /// D3: the new function's real analysis symbol when it differs from the old function's symbol.
    /// It blocks the incoming name (a `.destinationSymbol` conflict) unless it equals that name.
    /// Nil when the destination has an authored name, the symbol is generated, or it is unchanged.
    let destinationSymbol: String?
    let skip: SkipReason?

    /// Default selection: only `high` and `userConfirmed` pairs that are not skipped (D7: a changed
    /// `high` pair stays preselected; the row shows its `differences`).
    var isPreselected: Bool { skip == nil && confidence >= .high }
    var isChanged: Bool { !differences.isEmpty }
}

enum AnnotationTransferCandidates {
    /// One pass over `result.matches` with dictionary lookups: O(functions + matches). Never calls
    /// `FunctionVersionMatchResult.match(forOldID:)` per row (a linear scan). Unresolved groups,
    /// added and removed functions never become candidates. Rows keep the matcher's order.
    static func build(result: FunctionVersionMatchResult,
                      oldSlot: ImageSlot, newSlot: ImageSlot,
                      snapshot: WorkspaceSnapshot) -> [AnnotationTransferCandidate] {
        guard oldSlot != newSlot else { return [] }
        let oldFunctions = functionsByID(snapshot.analysis(in: oldSlot))
        let newFunctions = functionsByID(snapshot.analysis(in: newSlot))
        let newStarts = Set((snapshot.analysis(in: newSlot)?.functions ?? []).map(\.startAddress))

        var candidates: [AnnotationTransferCandidate] = []
        for match in result.matches {
            let incoming = annotation(snapshot.addressOverrides[ImageAddress(slot: oldSlot, address: match.oldAddress)])
            guard !incoming.isEmpty else { continue }
            let existing = annotation(snapshot.addressOverrides[ImageAddress(slot: newSlot, address: match.newAddress)])

            var destinationSymbol: String?
            if existing.name == nil, let newName = newFunctions[match.newID]?.name,
               !FunctionVersionFingerprinting.isGeneratedName(newName) {
                let oldName = oldFunctions[match.oldID]?.name
                let oldReal = oldName.flatMap { FunctionVersionFingerprinting.isGeneratedName($0) ? nil : $0 }
                if oldReal != newName { destinationSymbol = newName }
            }

            let skip: AnnotationTransferCandidate.SkipReason?
            if !newStarts.contains(match.newAddress) {
                skip = .notFunctionStart
            } else if !isAdmissible(incoming) || !isAdmissible(existing) {
                skip = .textLimit
            } else {
                skip = nil
            }

            candidates.append(AnnotationTransferCandidate(
                id: "match:\(match.oldID)>\(match.newID)",
                oldID: match.oldID, newID: match.newID,
                oldAddress: match.oldAddress, newAddress: match.newAddress,
                basis: match.basis, confidence: match.confidence,
                differences: match.differences, symbolNameChanged: match.symbolNameChanged,
                incoming: incoming, existing: existing,
                destinationSymbol: destinationSymbol, skip: skip))
        }
        return candidates
    }

    /// The ids `build` preselects (D7). Convenience for the initial review selection.
    static func defaultSelection(_ candidates: [AnnotationTransferCandidate]) -> Set<String> {
        Set(candidates.lazy.filter(\.isPreselected).map(\.id))
    }

    /// Authored function-entry text for `addresses` in `slot`, normalized. Entries with no text are
    /// omitted (the planner and the staleness checks read an absent entry as `.empty`). Used both to
    /// feed the planner and, at commit time, to compare against the preview's snapshots.
    static func annotations(in slot: ImageSlot, at addresses: some Sequence<UInt64>,
                            snapshot: WorkspaceSnapshot) -> [UInt64: TransferableAnnotation] {
        var result: [UInt64: TransferableAnnotation] = [:]
        for address in addresses {
            let value = annotation(snapshot.addressOverrides[ImageAddress(slot: slot, address: address)])
            if !value.isEmpty { result[address] = value }
        }
        return result
    }

    /// D3 projection for the planner: destination address → blocking real symbol.
    static func destinationSymbolConflicts(for candidates: [AnnotationTransferCandidate]) -> [UInt64: String] {
        var result: [UInt64: String] = [:]
        for candidate in candidates {
            if let symbol = candidate.destinationSymbol { result[candidate.newAddress] = symbol }
        }
        return result
    }

    /// Planner pairs for the selected, non-skipped candidates, in candidate order.
    static func pairs(_ candidates: [AnnotationTransferCandidate], selected: Set<String>) -> [AnnotationTransferPair] {
        candidates.compactMap { candidate in
            guard candidate.skip == nil, selected.contains(candidate.id) else { return nil }
            return AnnotationTransferPair(sourceAddress: candidate.oldAddress, destinationAddress: candidate.newAddress)
        }
    }

    /// The whole review → plan step: selected pairs, current source and destination text read from
    /// `snapshot`, and the D3 projection, run through `AnnotationTransferPlanner.preview`.
    static func preview(_ candidates: [AnnotationTransferCandidate], selected: Set<String>,
                        oldSlot: ImageSlot, newSlot: ImageSlot,
                        snapshot: WorkspaceSnapshot) throws -> AnnotationTransferPreview {
        let selectedPairs = pairs(candidates, selected: selected)
        let chosen = Set(selectedPairs.map(\.destinationAddress))
        return try AnnotationTransferPlanner.preview(
            pairs: selectedPairs,
            source: annotations(in: oldSlot, at: selectedPairs.map(\.sourceAddress), snapshot: snapshot),
            destination: annotations(in: newSlot, at: selectedPairs.map(\.destinationAddress), snapshot: snapshot),
            destinationSymbolConflicts: destinationSymbolConflicts(for: candidates).filter { chosen.contains($0.key) })
    }

    // MARK: - Helpers

    /// Same normalization as the store's override editor: trimmed, empty → nil.
    static func normalized(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func annotation(_ override: AddressOverride?) -> TransferableAnnotation {
        TransferableAnnotation(name: normalized(override?.customName), comment: normalized(override?.customComment))
    }

    private static func isAdmissible(_ annotation: TransferableAnnotation) -> Bool {
        AnnotationTransferPlanner.isAdmissible(annotation.name, limit: AnnotationTransferPlanner.maximumNameBytes)
            && AnnotationTransferPlanner.isAdmissible(annotation.comment, limit: AnnotationTransferPlanner.maximumCommentBytes)
    }

    private static func functionsByID(_ analysis: ImageAnalysis?) -> [String: FunctionSummary] {
        var result: [String: FunctionSummary] = [:]
        for function in analysis?.functions ?? [] { result[function.id.uuidString] = function }
        return result
    }
}
