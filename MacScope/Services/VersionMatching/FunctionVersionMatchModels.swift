import Foundation

/// Which evidence accepted a cross-version pair. Raw values are stable for serialization.
enum FunctionVersionMatchBasis: String, Hashable, Codable, Sendable, CaseIterable {
    /// User-pinned pair; outranks every automatic phase.
    case manual
    /// Identical, non-generated symbol name, unique on both sides.
    case symbolName
    /// Identical masked instruction-stream digest, unique on both sides.
    case normalizedBody
    /// Identical CFG shape digest plus identical named-callee set, unique on both sides.
    case controlFlowAndCallees
    /// The unique structurally compatible unmatched callee pair under an already matched caller pair.
    case callGraphPropagation
}

/// Explicit confidence attached to every accepted pair. Ordered weakest to strongest.
enum FunctionVersionMatchConfidence: Int, Hashable, Codable, Sendable, Comparable {
    case low = 1
    case medium = 2
    case high = 3
    case userConfirmed = 4

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A fingerprint that differs between the two sides of an accepted pair. Unknown facts on either
/// side never produce a difference.
enum FunctionVersionDifference: String, Hashable, Codable, Sendable, CaseIterable, Comparable {
    case body
    case controlFlow
    case callees
    case size
    case stringReferences

    static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// Why a set of functions could not be paired one-to-one.
enum FunctionVersionAmbiguityBasis: String, Hashable, Codable, Sendable, CaseIterable, Comparable {
    case duplicateSymbolName
    case duplicateNormalizedBody
    case duplicateControlFlowAndCallees
    case conflictingCallGraphCandidates

    static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

struct FunctionVersionMatch: Hashable, Codable, Sendable {
    let oldID: String
    let newID: String
    let oldAddress: UInt64
    let newAddress: UInt64
    let basis: FunctionVersionMatchBasis
    let confidence: FunctionVersionMatchConfidence
    /// For `.callGraphPropagation`, the matched caller pair that supplied the context.
    let propagatedFromOldCallerID: String?
    let propagatedFromNewCallerID: String?
    /// Sorted; empty means every known fingerprint is identical.
    let differences: [FunctionVersionDifference]
    /// The symbol name differs (including stripped vs. named). Informational only: a rename or
    /// strip is not a code change and does not make the pair `isChanged`.
    let symbolNameChanged: Bool

    var isChanged: Bool { !differences.isEmpty }
}

/// Functions that share a candidate key but cannot be paired one-to-one. Members are neither
/// matched, added nor removed; each unresolved function appears in exactly one group.
struct FunctionVersionUnresolvedGroup: Hashable, Codable, Sendable {
    /// Ordered by address, then id.
    let oldIDs: [String]
    let newIDs: [String]
    let bases: [FunctionVersionAmbiguityBasis]
}

struct FunctionVersionManualPin: Hashable, Codable, Sendable {
    let oldID: String
    let newID: String
}

struct FunctionVersionMatchResult: Hashable, Codable, Sendable {
    /// Ordered by old address, then old id.
    let matches: [FunctionVersionMatch]
    /// New-version functions with no counterpart and no ambiguity, ordered by address.
    let addedIDs: [String]
    /// Old-version functions with no counterpart and no ambiguity, ordered by address.
    let removedIDs: [String]
    /// Ordered by the first member's address.
    let unresolved: [FunctionVersionUnresolvedGroup]
    /// The pins this result was computed with, in canonical order.
    let manualPins: [FunctionVersionManualPin]

    var unchangedMatches: [FunctionVersionMatch] { matches.filter { !$0.isChanged } }
    var changedMatches: [FunctionVersionMatch] { matches.filter(\.isChanged) }

    func match(forOldID id: String) -> FunctionVersionMatch? { matches.first { $0.oldID == id } }
    func match(forNewID id: String) -> FunctionVersionMatch? { matches.first { $0.newID == id } }
}

enum FunctionVersionMatcherError: Error, Hashable, Sendable {
    case duplicateOldID(String)
    case duplicateNewID(String)
    case unknownOldID(String)
    case unknownNewID(String)
    /// The function is already paired in the result being refined (automatically or by a pin).
    case oldAlreadyMatched(String)
    case newAlreadyMatched(String)
    /// Two pins name the same function.
    case conflictingPins(FunctionVersionManualPin, FunctionVersionManualPin)
}
