import Foundation

/// DP04 D2: turns an accepted `StructLayoutCandidate` into a catalog `TypeDefinition` that
/// reproduces every observed offset exactly. The struct is packed and every byte the
/// candidate did not observe is an explicit `uint8_t _unknown_0x…[n]` member, so the C
/// layout cannot move a field; the computed member layout is checked against the
/// candidate before anything is returned. Overlaps need an explicit choice, an interior
/// pointer needs a rebase first, and anything that cannot be expressed is refused.
public enum StructCandidateTypeAdapter {
    public enum Refusal: Error, Equatable, Sendable {
        case invalidName
        case nameInUse
        /// The root is an interior pointer (negative offsets); rebase it first.
        case needsRebase
        /// An overlap group has no chosen field, or the choice names no field of it.
        case unresolvedConflict(Range<Int64>)
        case noFields
        /// The computed C layout did not reproduce the candidate's offsets.
        case layoutMismatch
    }

    /// One chosen field per overlap group, by (offset, width).
    public struct Choice: Hashable, Sendable {
        public let offset: Int64
        public let byteWidth: Int
        public init(offset: Int64, byteWidth: Int) {
            self.offset = offset
            self.byteWidth = byteWidth
        }
    }

    public static func typeDefinition(
        for candidate: StructLayoutCandidate,
        name: String,
        choices: [Choice],
        existing: [TypeDefinition]
    ) throws -> TypeDefinition {
        guard PseudocodePrinter.isCIdentifier(name) else { throw Refusal.invalidName }
        guard !existing.contains(where: { $0.name == name }) else { throw Refusal.nameInUse }
        guard !candidate.needsRebase else { throw Refusal.needsRebase }
        let chosen = Set(choices)
        var dropped = Set<StructLayoutCandidate.Field>()
        for conflict in candidate.conflicts {
            let picks = conflict.fields.filter { chosen.contains(Choice(offset: $0.offset, byteWidth: $0.byteWidth)) }
            guard picks.count == 1, let pick = picks.first else { throw Refusal.unresolvedConflict(conflict.range) }
            for field in conflict.fields where field != pick { dropped.insert(field) }
        }
        let kept = candidate.fields.filter { !dropped.contains($0) }.sorted { $0.offset < $1.offset }
        guard !kept.isEmpty else { throw Refusal.noFields }
        var members: [FieldDef] = []
        var expected: [(name: String, offset: Int)] = []
        var cursor: Int64 = 0
        for field in kept {
            guard field.offset >= cursor else { throw Refusal.layoutMismatch }
            if field.offset > cursor {
                members.append(FieldDef(name: hexName("_unknown", cursor), type: "uint8_t[\(field.offset - cursor)]"))
            }
            let memberName = hexName("field", field.offset)
            members.append(FieldDef(name: memberName, type: scalarType(field)))
            expected.append((memberName, Int(field.offset)))
            cursor = field.range.upperBound
        }
        let definition = TypeDefinition(
            kind: .struct, name: name, fields: members, layoutRules: AggregateLayoutRules(isPacked: true),
            inferenceProvenance: TypeInferenceProvenance(
                source: "usage-candidate-v1", candidateID: candidate.candidateID, root: candidate.root.identity,
                functionStart: candidate.functionStart,
                observationCount: candidate.fields.reduce(0) { $0 + $1.evidence.count },
                fieldCount: candidate.fields.count, conflictCount: candidate.conflicts.count,
                extentLowerBound: candidate.extentLowerBound,
                incompleteness: candidate.incompleteness.map(\.rawValue).sorted()))
        let catalog = Dictionary(existing.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let layout = definition.memberLayout(in: catalog)
        let offsets = Dictionary(layout.map { ($0.field.name, $0.offset) }, uniquingKeysWith: { first, _ in first })
        guard layout.count == members.count,
              expected.allSatisfy({ offsets[$0.name] == $0.offset }) else { throw Refusal.layoutMismatch }
        return definition
    }

    private static func hexName(_ prefix: String, _ offset: Int64) -> String {
        "\(prefix)_0x" + String(offset, radix: 16)
    }

    /// Width (and a sign extension, when observed) picks the scalar; 16 bytes is a byte array.
    /// Width alone does not prove a pointer or a source type.
    private static func scalarType(_ field: StructLayoutCandidate.Field) -> String {
        let signed = field.evidence.contains { $0.extensionKind == .sign }
        switch field.byteWidth {
        case 1: return signed ? "int8_t" : "uint8_t"
        case 2: return signed ? "int16_t" : "uint16_t"
        case 4: return signed ? "int32_t" : "uint32_t"
        case 8: return signed ? "int64_t" : "uint64_t"
        default: return "uint8_t[\(field.byteWidth)]"
        }
    }
}
