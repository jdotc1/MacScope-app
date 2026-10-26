import Foundation

// RX-01: transfer human-authored function names and function-entry comments between two matched
// versions of an image. This file is the pure, review-only pair planner (ported from the roadmap
// reference `ComparisonAdmission.swift`, pair planner only). It never reads the store and grants no
// mutation authority; the store commit re-validates everything before writing.

/// Human-authored function-entry text on one side of a transfer. Never analysis symbol names.
/// `nil` and the empty string both mean "no text".
struct TransferableAnnotation: Hashable, Sendable {
    let name: String?
    let comment: String?

    static let empty = TransferableAnnotation(name: nil, comment: nil)

    var isEmpty: Bool { (name ?? "").isEmpty && (comment ?? "").isEmpty }
}

enum AnnotationTransferField: String, Hashable, Sendable, CaseIterable {
    case name, comment
}

/// One old-function-start → new-function-start pair, image-local addresses on each side.
struct AnnotationTransferPair: Hashable, Sendable {
    let sourceAddress: UInt64
    let destinationAddress: UInt64
}

/// A field value the commit will write. A nil field is left untouched (never cleared).
struct AnnotationTransferChange: Hashable, Sendable {
    let sourceAddress: UInt64
    let destinationAddress: UInt64
    let newName: String?
    let newComment: String?
}

/// A destination field the transfer refuses to touch.
struct AnnotationTransferConflict: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        /// The destination already carries different authored text.
        case authored
        /// The destination has no authored name, but its analysis symbol is a different real name (D3).
        case destinationSymbol
    }

    let destinationAddress: UInt64
    let field: AnnotationTransferField
    let kind: Kind
    let existing: String
    let incoming: String
}

enum AnnotationTransferError: Error, Hashable, Sendable {
    /// More pairs than the planner admits (or a non-positive limit). Carries the pair count.
    case pairLimitExceeded(Int)
    /// A source or destination address appears in more than one pair. Carries that address.
    case notOneToOne(sourceOrDestination: UInt64)
    /// A field over its byte limit, containing NUL, or over the aggregate preview budget.
    /// Carries the source address for incoming text and the destination address for existing text.
    case textLimitExceeded(address: UInt64)
}

/// A review-only plan. `expectedDestination` and `expectedSource` snapshot exactly the entries the
/// plan examined, so a commit can refuse when one of them changed while edits anywhere else do not
/// stale the preview.
struct AnnotationTransferPreview: Hashable, Sendable {
    /// Ordered by source address.
    let changes: [AnnotationTransferChange]
    /// Ordered by source address, then field (name before comment).
    let conflicts: [AnnotationTransferConflict]
    /// Only the destination entries this preview examined; an absent entry was recorded as `.empty`.
    let expectedDestination: [UInt64: TransferableAnnotation]
    /// Only the source entries this preview read, including pairs whose source had no text (D6).
    let expectedSource: [UInt64: TransferableAnnotation]

    var nameCount: Int { changes.lazy.filter { $0.newName != nil }.count }
    var commentCount: Int { changes.lazy.filter { $0.newComment != nil }.count }

    /// Examined destination addresses whose current value differs from the snapshot, ascending.
    /// Empty means the destination side is still applicable. `current` may omit empty entries.
    func staleDestinations(_ current: [UInt64: TransferableAnnotation]) -> [UInt64] {
        Self.stale(expectedDestination, current)
    }

    /// Reference-planner spelling of `staleDestinations(current).isEmpty`.
    func isStillApplicable(to current: [UInt64: TransferableAnnotation]) -> Bool {
        staleDestinations(current).isEmpty
    }

    /// Examined source addresses whose current value differs from the snapshot, ascending.
    func staleSources(_ current: [UInt64: TransferableAnnotation]) -> [UInt64] {
        Self.stale(expectedSource, current)
    }

    private static func stale(_ expected: [UInt64: TransferableAnnotation],
                              _ current: [UInt64: TransferableAnnotation]) -> [UInt64] {
        expected.compactMap { address, value in
            AnnotationTransferPlanner.canonical(current[address] ?? .empty) == AnnotationTransferPlanner.canonical(value)
                ? nil : address
        }.sorted()
    }
}

enum AnnotationTransferPlanner {
    static let maximumNameBytes = 4_096
    static let maximumCommentBytes = 65_536
    static let maximumPreviewTextBytes = 8 * 1_024 * 1_024
    static let defaultMaximumPairs = 100_000

    /// True when `text` fits `limit` UTF-8 bytes and has no embedded NUL.
    static func isAdmissible(_ text: String?, limit: Int) -> Bool {
        guard let text else { return true }
        return text.utf8.count <= limit && !text.utf8.contains(0)
    }

    /// Builds a review-only preview. Pairs must be one-to-one on both sides.
    ///
    /// Per pair and per field, independently: an empty incoming value or one equal to the destination
    /// is skipped; a non-empty different destination value is an `.authored` conflict; otherwise it is
    /// a change. For the name only, `destinationSymbolConflicts[destination]` (the D3 projection: a real
    /// destination symbol that differs from the source's symbol) turns a would-be change into a
    /// `.destinationSymbol` conflict, unless that symbol already equals the incoming name (a no-op).
    static func preview(pairs: [AnnotationTransferPair],
                        source: [UInt64: TransferableAnnotation],
                        destination: [UInt64: TransferableAnnotation],
                        destinationSymbolConflicts: [UInt64: String] = [:],
                        maximumPairs: Int = defaultMaximumPairs) throws -> AnnotationTransferPreview {
        guard maximumPairs > 0, pairs.count <= maximumPairs else {
            throw AnnotationTransferError.pairLimitExceeded(pairs.count)
        }
        var usedSource = Set<UInt64>(), usedDestination = Set<UInt64>()
        for pair in pairs {
            guard usedSource.insert(pair.sourceAddress).inserted else {
                throw AnnotationTransferError.notOneToOne(sourceOrDestination: pair.sourceAddress)
            }
            guard usedDestination.insert(pair.destinationAddress).inserted else {
                throw AnnotationTransferError.notOneToOne(sourceOrDestination: pair.destinationAddress)
            }
        }

        var examinedDestination: [UInt64: TransferableAnnotation] = [:]
        var examinedSource: [UInt64: TransferableAnnotation] = [:]
        var changes: [AnnotationTransferChange] = []
        var conflicts: [AnnotationTransferConflict] = []
        var totalTextBytes = 0
        func admit(_ text: String?, limit: Int, address: UInt64) throws {
            guard let text else { return }
            let bytes = text.utf8.count
            guard isAdmissible(text, limit: limit), bytes <= maximumPreviewTextBytes - totalTextBytes else {
                throw AnnotationTransferError.textLimitExceeded(address: address)
            }
            totalTextBytes += bytes
        }

        for pair in pairs.sorted(by: { $0.sourceAddress < $1.sourceAddress }) {
            let incoming = canonical(source[pair.sourceAddress] ?? .empty)
            examinedSource[pair.sourceAddress] = incoming
            guard !incoming.isEmpty else { continue }
            let existing = canonical(destination[pair.destinationAddress] ?? .empty)
            examinedDestination[pair.destinationAddress] = existing
            // Conflicts echo existing text too, so both sides of the preview are bounded.
            try admit(existing.name, limit: maximumNameBytes, address: pair.destinationAddress)
            try admit(existing.comment, limit: maximumCommentBytes, address: pair.destinationAddress)
            try admit(incoming.name, limit: maximumNameBytes, address: pair.sourceAddress)
            try admit(incoming.comment, limit: maximumCommentBytes, address: pair.sourceAddress)

            var newName: String?
            var newComment: String?
            if let name = incoming.name, name != existing.name {
                if let old = existing.name {
                    conflicts.append(.init(destinationAddress: pair.destinationAddress, field: .name,
                                           kind: .authored, existing: old, incoming: name))
                } else if let symbol = destinationSymbolConflicts[pair.destinationAddress], !symbol.isEmpty {
                    if symbol != name {
                        try admit(symbol, limit: maximumPreviewTextBytes, address: pair.destinationAddress)
                        conflicts.append(.init(destinationAddress: pair.destinationAddress, field: .name,
                                               kind: .destinationSymbol, existing: symbol, incoming: name))
                    }
                } else {
                    newName = name
                }
            }
            if let comment = incoming.comment, comment != existing.comment {
                if let old = existing.comment {
                    conflicts.append(.init(destinationAddress: pair.destinationAddress, field: .comment,
                                           kind: .authored, existing: old, incoming: comment))
                } else {
                    newComment = comment
                }
            }
            if newName != nil || newComment != nil {
                changes.append(.init(sourceAddress: pair.sourceAddress, destinationAddress: pair.destinationAddress,
                                     newName: newName, newComment: newComment))
            }
        }
        return AnnotationTransferPreview(changes: changes, conflicts: conflicts,
                                         expectedDestination: examinedDestination,
                                         expectedSource: examinedSource)
    }

    /// Empty strings become nil so "" and absent compare equal everywhere in the planner.
    static func canonical(_ annotation: TransferableAnnotation) -> TransferableAnnotation {
        let name = annotation.name.flatMap { $0.isEmpty ? nil : $0 }
        let comment = annotation.comment.flatMap { $0.isEmpty ? nil : $0 }
        return TransferableAnnotation(name: name, comment: comment)
    }
}
