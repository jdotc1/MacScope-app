import Foundation

/// DP04 D1: a usage-derived layout candidate for the object behind one root pointer.
/// It is a constraint set, not a C declaration: gaps are unknown bytes, the extent is a
/// lower bound, overlapping views are conflicts, and nothing here mutates a type or local.
public struct StructLayoutCandidate: Hashable, Sendable {
    public enum Role: String, Hashable, Sendable, Comparable {
        case read, write
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum Carrier: String, Hashable, Sendable { case gpr, simd, unknown }

    /// One machine access at a byte offset from the root.
    public struct Observation: Hashable, Sendable {
        public let offset: Int64
        public let byteWidth: Int
        public let role: Role
        public let extensionKind: MacIRMemoryAccess.ExtensionKind
        public let carrier: Carrier
        public let sourceAddress: UInt64
        /// The direct-call chain this observation was transferred through (outermost first).
        public let viaCalls: [String]
    }

    /// The distinct accesses at one (offset, width).
    public struct Field: Hashable, Sendable {
        public let offset: Int64
        public let byteWidth: Int
        public let roles: [Role]
        public let evidence: [Observation]
        public var range: Range<Int64> { offset ..< offset + Int64(byteWidth) }
    }

    /// Fields whose byte ranges overlap with different extents: a possible union or a
    /// mis-merged root, never silently resolved.
    public struct Conflict: Hashable, Sendable {
        public let range: Range<Int64>
        public let fields: [Field]
    }

    public enum Incompleteness: String, Hashable, Sendable {
        /// A call-edge transfer stopped at the depth or function budget.
        case budget
        /// A recursive call edge was not followed again.
        case recursion
        /// The root reached an indirect or unresolved call.
        case unresolvedCall
    }

    public let functionStart: UInt64
    public let root: MacIRStructUsageAnalysis.Root
    public let fields: [Field]
    public let conflicts: [Conflict]
    /// Byte ranges between fields that no access touched; unknown, not proven padding.
    public let unknownGaps: [Range<Int64>]
    /// The end of the last observed access; the allocation may be larger.
    public let extentLowerBound: Int64
    /// A negative offset was observed: the root is likely an interior pointer and needs an
    /// explicit rebase before it can describe an object (no negative members).
    public let needsRebase: Bool
    /// Accesses through a register-indexed or otherwise non-constant address off the root.
    public let unresolvedAccessAddresses: [UInt64]
    public let incompleteness: Set<Incompleteness>

    /// Deterministic identity of all primitive evidence used by preview and acceptance.
    /// Layout, conflicts, gaps, extent and rebase state are derived from the observations;
    /// uncertainty is also bound so a preview cannot silently gain or lose limitations.
    public var candidateID: String {
        let text = Self.identityComponents([
            "struct-candidate-v2", String(functionStart, radix: 16), root.identity,
            Self.identityComponents(fields.flatMap { $0.evidence.map(Self.observationIdentity) }),
            Self.identityComponents(unresolvedAccessAddresses.map { String($0, radix: 16) }),
            Self.identityComponents(incompleteness.map(\.rawValue).sorted()),
        ])
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return "struct-candidate-v2:" + String(hash, radix: 16)
    }

    /// Length framing keeps arbitrary symbol names and call-chain boundaries distinct.
    private static func identityComponents(_ components: [String]) -> String {
        components.map { "\($0.utf8.count):\($0)" }.joined()
    }

    private static func observationIdentity(_ observation: Observation) -> String {
        let extensionKind: String
        switch observation.extensionKind {
        case .none: extensionKind = "none"
        case .zero: extensionKind = "zero"
        case .sign: extensionKind = "sign"
        }
        return identityComponents([
            String(observation.offset), String(observation.byteWidth), observation.role.rawValue,
            extensionKind, observation.carrier.rawValue, String(observation.sourceAddress, radix: 16),
            identityComponents(observation.viaCalls),
        ])
    }

    init(functionStart: UInt64, root: MacIRStructUsageAnalysis.Root, observations: [Observation],
         unresolvedAccessAddresses: [UInt64], incompleteness: Set<Incompleteness>) {
        self.functionStart = functionStart
        self.root = root
        let unique = Array(Set(observations)).sorted {
            let lhs = ($0.offset, $0.byteWidth, $0.role, $0.sourceAddress)
            let rhs = ($1.offset, $1.byteWidth, $1.role, $1.sourceAddress)
            if lhs != rhs { return lhs < rhs }
            return Self.observationIdentity($0) < Self.observationIdentity($1)
        }
        let grouped = Dictionary(grouping: unique) { FieldKey(offset: $0.offset, byteWidth: $0.byteWidth) }
        let fields = grouped.keys.sorted { ($0.offset, $0.byteWidth) < ($1.offset, $1.byteWidth) }.map { key in
            let evidence = grouped[key] ?? []
            return Field(offset: key.offset, byteWidth: key.byteWidth,
                         roles: Array(Set(evidence.map(\.role))).sorted(), evidence: evidence)
        }
        self.fields = fields
        // Overlap groups: union of intersecting field ranges with more than one extent.
        var conflicts: [Conflict] = []
        var group: [Field] = []
        var groupRange: Range<Int64>?
        func flush() {
            if group.count > 1, let groupRange { conflicts.append(Conflict(range: groupRange, fields: group)) }
            group = []; groupRange = nil
        }
        for field in fields {
            if let range = groupRange, range.overlaps(field.range) {
                group.append(field)
                groupRange = range.lowerBound ..< max(range.upperBound, field.range.upperBound)
            } else {
                flush()
                group = [field]; groupRange = field.range
            }
        }
        flush()
        self.conflicts = conflicts
        var gaps: [Range<Int64>] = []
        var cursor: Int64 = 0
        for field in fields where field.offset >= 0 {
            if field.offset > cursor { gaps.append(cursor ..< field.offset) }
            cursor = max(cursor, field.range.upperBound)
        }
        unknownGaps = gaps
        extentLowerBound = fields.map(\.range.upperBound).max() ?? 0
        needsRebase = fields.contains { $0.offset < 0 }
        self.unresolvedAccessAddresses = Array(Set(unresolvedAccessAddresses)).sorted()
        self.incompleteness = incompleteness
    }

    private struct FieldKey: Hashable { let offset: Int64; let byteWidth: Int }
}
