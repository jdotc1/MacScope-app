import Darwin
import Foundation
import CryptoKit
import SwiftUI

/// A user-authored override for the entity at a given address — a custom name
/// (rename), comment, free-text tag, and/or highlight color, with room to grow
/// (types, operand formats, switch hints, mark-as-code/data). Unlike the derived
/// `jumpTables`/`objcSelectors` seams, overrides ARE persisted with the workspace
/// so that authoring survives save and reload.
/// Function-signature parameter rows are source ordered. Their durable row token
/// survives reorder and editing; physical ABI locations are derived when the
/// signature is applied and are intentionally not persisted here.
/// The kind of a user-defined type in the workspace type catalog.
public enum TypeKind: String, Codable, CaseIterable, Equatable, Sendable, Identifiable {
    case `struct`
    case union
    case `enum`
    case typedef

    public var id: String { rawValue }
    public var displayName: String { rawValue }
}

/// Layout modifiers that affect a struct/union as a whole. These are intentionally
/// small and ABI-focused: the parser records only modifiers the layout engine can
/// reproduce exactly.
public struct AggregateLayoutRules: Codable, Equatable, Sendable {
    public var isPacked: Bool
    public var packAlignment: Int?
    public var minimumAlignment: Int?

    public static let `default` = AggregateLayoutRules()

    public init(isPacked: Bool = false, packAlignment: Int? = nil, minimumAlignment: Int? = nil) {
        self.isPacked = isPacked
        self.packAlignment = Self.validAlignment(packAlignment)
        self.minimumAlignment = Self.validAlignment(minimumAlignment)
    }

    private enum CodingKeys: String, CodingKey {
        case isPacked
        case packAlignment
        case minimumAlignment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isPacked: try container.decodeIfPresent(Bool.self, forKey: .isPacked) ?? false,
            packAlignment: try container.decodeIfPresent(Int.self, forKey: .packAlignment),
            minimumAlignment: try container.decodeIfPresent(Int.self, forKey: .minimumAlignment)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if isPacked {
            try container.encode(isPacked, forKey: .isPacked)
        }
        try container.encodeIfPresent(packAlignment, forKey: .packAlignment)
        try container.encodeIfPresent(minimumAlignment, forKey: .minimumAlignment)
    }

    private static func validAlignment(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }
}

/// Source-level callable metadata; the field's existing carrier remains its layout authority.
public struct FunctionPointerSignatureV1: Codable, Equatable, Sendable {
    public struct Parameter: Codable, Equatable, Sendable {
        public var name: String?
        public var type: String
        /// Preserves a callback parameter's own prototype instead of erasing it to a pointer.
        public var functionPointerSignatureV1: FunctionPointerSignatureV1?

        public init(name: String? = nil, type: String, functionPointerSignatureV1: FunctionPointerSignatureV1? = nil) {
            self.name = name
            self.type = type
            self.functionPointerSignatureV1 = functionPointerSignatureV1
        }
    }

    public var returnType: String
    public var parameters: [Parameter]
    public var isVariadic: Bool
    /// C `()` supplies no parameter information; `(void)` is an explicit empty list.
    public var hasUnspecifiedParameters: Bool

    public init(returnType: String, parameters: [Parameter], isVariadic: Bool = false,
                hasUnspecifiedParameters: Bool = false) {
        self.returnType = returnType
        self.parameters = parameters
        self.isVariadic = isVariadic
        self.hasUnspecifiedParameters = hasUnspecifiedParameters
    }
}

/// One field of a user-defined struct/union (or a named member of an enum/typedef).
public struct FieldDef: Codable, Equatable, Sendable {
    public enum DeclaratorSemanticsV1: String, Codable, CaseIterable, Equatable, Sendable {
        case ordinary
        case functionPointerCarrier
        case pointerToArrayCarrier
        case arrayOfFunctionPointerCarrier
    }

    /// Distinguishes imported unknown layout from a field authored for C ABI layout.
    public enum LayoutSource: String, Codable, Equatable, Sendable {
        case dwarf
    }

    public var name: String
    public var type: String
    public var declaratorSemanticsV1: DeclaratorSemanticsV1?
    public var functionPointerSignatureV1: FunctionPointerSignatureV1?
    /// Absolute bit offset in a computed member layout. Authored/persisted fields may omit it.
    public var bitOffset: Int? = nil
    /// Member-level packed attribute, independently of its containing record.
    public var isPacked: Bool? = nil
    /// An unsupported declaration must poison layout rather than disappear.
    public var layoutIsUnknown: Bool? = nil
    /// Atomic qualification affects ABI shape even where its byte layout matches the scalar.
    public var isAtomic: Bool? = nil
    public var bitWidth: Int? = nil
    /// C11 `_Alignas`: either a numeric byte alignment or the name of a type whose
    /// alignment should be used. The layout engine resolves type-based alignment
    /// against the same catalog as by-value aggregate fields.
    public var minimumAlignment: Int? = nil
    public var minimumAlignmentType: String? = nil
    /// Inline `struct { ... }` / `union { ... }` member metadata. When present,
    /// layout uses `inlineFields` instead of resolving `type` through the catalog.
    public var inlineAggregateKind: TypeKind? = nil
    public var inlineFields: [FieldDef] = []
    public var inlineAggregateLayoutRules: AggregateLayoutRules = .default
    /// True only for C11 anonymous aggregate members (`struct { ... };` /
    /// `union { ... };`): their inner fields are exposed in the enclosing layout.
    public var promotesInlineFields: Bool = false
    /// RX-02a: the member offset a dSYM recorded (`DW_AT_data_member_location`), kept on import
    /// instead of being recomputed. nil when absent or unrepresentable. Read by the Type Atlas; the C
    /// layout engine (`memberLayout`) does not consult it.
    public var byteOffset: Int? = nil
    public var layoutSource: LayoutSource? = nil

    public init(
        name: String,
        type: String,
        declaratorSemanticsV1: DeclaratorSemanticsV1? = nil,
        functionPointerSignatureV1: FunctionPointerSignatureV1? = nil,
        bitWidth: Int? = nil,
        bitOffset: Int? = nil,
        isPacked: Bool? = nil,
        layoutIsUnknown: Bool? = nil,
        isAtomic: Bool? = nil,
        minimumAlignment: Int? = nil,
        minimumAlignmentType: String? = nil,
        inlineAggregateKind: TypeKind? = nil,
        inlineFields: [FieldDef] = [],
        inlineAggregateLayoutRules: AggregateLayoutRules = .default,
        promotesInlineFields: Bool = false,
        byteOffset: Int? = nil,
        layoutSource: LayoutSource? = nil
    ) {
        self.name = name
        self.type = type
        self.declaratorSemanticsV1 = declaratorSemanticsV1
        self.functionPointerSignatureV1 = functionPointerSignatureV1
        self.bitWidth = bitWidth
        self.bitOffset = bitOffset
        self.isPacked = isPacked
        self.layoutIsUnknown = layoutIsUnknown
        self.isAtomic = isAtomic
        self.minimumAlignment = AggregateLayoutRules(isPacked: false, minimumAlignment: minimumAlignment).minimumAlignment
        self.minimumAlignmentType = minimumAlignmentType
        self.inlineAggregateKind = inlineAggregateKind
        self.inlineFields = inlineFields
        self.inlineAggregateLayoutRules = inlineAggregateLayoutRules
        self.promotesInlineFields = promotesInlineFields
        self.byteOffset = byteOffset
        self.layoutSource = layoutSource
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case type
        case declaratorSemanticsV1
        case functionPointerSignatureV1
        case bitWidth
        case bitOffset
        case layoutIsUnknown
        case isAtomic
        case isPacked
        case minimumAlignment
        case minimumAlignmentType
        case inlineAggregateKind
        case inlineFields
        case inlineAggregateLayoutRules
        case promotesInlineFields
        case byteOffset
        case layoutSource
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(String.self, forKey: .type)
        declaratorSemanticsV1 = try container.decodeIfPresent(
            DeclaratorSemanticsV1.self,
            forKey: .declaratorSemanticsV1
        )
        functionPointerSignatureV1 = try container.decodeIfPresent(FunctionPointerSignatureV1.self, forKey: .functionPointerSignatureV1)
        bitWidth = try container.decodeIfPresent(Int.self, forKey: .bitWidth)
        bitOffset = try container.decodeIfPresent(Int.self, forKey: .bitOffset)
        layoutIsUnknown = try container.decodeIfPresent(Bool.self, forKey: .layoutIsUnknown)
        isAtomic = try container.decodeIfPresent(Bool.self, forKey: .isAtomic)
        isPacked = try container.decodeIfPresent(Bool.self, forKey: .isPacked)
        let decodedMinimumAlignment = try container.decodeIfPresent(Int.self, forKey: .minimumAlignment)
        minimumAlignment = AggregateLayoutRules(minimumAlignment: decodedMinimumAlignment).minimumAlignment
        minimumAlignmentType = try container.decodeIfPresent(String.self, forKey: .minimumAlignmentType)
        inlineAggregateKind = try container.decodeIfPresent(TypeKind.self, forKey: .inlineAggregateKind)
        inlineFields = try container.decodeIfPresent([FieldDef].self, forKey: .inlineFields) ?? []
        inlineAggregateLayoutRules = try container.decodeIfPresent(AggregateLayoutRules.self, forKey: .inlineAggregateLayoutRules) ?? .default
        promotesInlineFields = try container.decodeIfPresent(Bool.self, forKey: .promotesInlineFields) ?? false
        byteOffset = try container.decodeIfPresent(Int.self, forKey: .byteOffset)
        layoutSource = try container.decodeIfPresent(LayoutSource.self, forKey: .layoutSource)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(declaratorSemanticsV1, forKey: .declaratorSemanticsV1)
        try container.encodeIfPresent(functionPointerSignatureV1, forKey: .functionPointerSignatureV1)
        try container.encodeIfPresent(bitWidth, forKey: .bitWidth)
        try container.encodeIfPresent(bitOffset, forKey: .bitOffset)
        try container.encodeIfPresent(layoutIsUnknown, forKey: .layoutIsUnknown)
        try container.encodeIfPresent(isAtomic, forKey: .isAtomic)
        try container.encodeIfPresent(isPacked, forKey: .isPacked)
        try container.encodeIfPresent(minimumAlignment, forKey: .minimumAlignment)
        try container.encodeIfPresent(minimumAlignmentType, forKey: .minimumAlignmentType)
        try container.encodeIfPresent(inlineAggregateKind, forKey: .inlineAggregateKind)
        if !inlineFields.isEmpty {
            try container.encode(inlineFields, forKey: .inlineFields)
        }
        if inlineAggregateLayoutRules != .default {
            try container.encode(inlineAggregateLayoutRules, forKey: .inlineAggregateLayoutRules)
        }
        if promotesInlineFields {
            try container.encode(promotesInlineFields, forKey: .promotesInlineFields)
        }
        try container.encodeIfPresent(byteOffset, forKey: .byteOffset)
        try container.encodeIfPresent(layoutSource, forKey: .layoutSource)
    }
}

/// A user-defined type in the workspace-global type catalog. Referenced by `name`
/// from `AddressOverride.appliedTypeName` (by name, not id) so the .mscope manifest
/// round-trips by value and a missing/renamed type degrades to no-type.
/// DP04 D2: where an accepted inferred layout came from. The type itself is an authored
/// assertion; this records the static evidence it was accepted from, so the two never merge
/// (the evidence stays inference, never compiler truth). Absent for hand-written types.
public struct TypeInferenceProvenance: Codable, Equatable, Hashable, Sendable {
    /// `usage-candidate-v1`: a DP04 D1 usage-layout candidate.
    public var source: String
    public var candidateID: String
    /// The candidate root (e.g. `param:x0`) in the function it was recovered from.
    public var root: String
    public var functionStart: UInt64
    public var observationCount: Int
    public var fieldCount: Int
    public var conflictCount: Int
    /// The extent the evidence proves; the type's tail beyond it is unknown.
    public var extentLowerBound: Int64
    /// Reasons the candidate was incomplete when accepted (budget, recursion, unresolvedCall).
    public var incompleteness: [String]

    public init(source: String, candidateID: String, root: String, functionStart: UInt64, observationCount: Int,
                fieldCount: Int, conflictCount: Int, extentLowerBound: Int64, incompleteness: [String]) {
        self.source = source
        self.candidateID = candidateID
        self.root = root
        self.functionStart = functionStart
        self.observationCount = observationCount
        self.fieldCount = fieldCount
        self.conflictCount = conflictCount
        self.extentLowerBound = extentLowerBound
        self.incompleteness = incompleteness
    }
}

public struct TypeDefinition: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: TypeKind
    public var name: String
    public var fields: [FieldDef]
    public var layoutRules: AggregateLayoutRules
    /// GCC vector_size on a typedef; nil retains legacy scalar/alias semantics.
    public var vectorByteSize: Int? = nil
    /// True for incomplete values or unsupported enum layout attributes; never size a partial declaration.
    public var enumValuesIncomplete: Bool? = nil
    /// DP04 D2: present only for a type accepted from inferred evidence.
    public var inferenceProvenance: TypeInferenceProvenance? = nil

    public init(
        id: UUID = UUID(),
        kind: TypeKind,
        name: String,
        fields: [FieldDef] = [],
        layoutRules: AggregateLayoutRules = .default,
        vectorByteSize: Int? = nil,
        enumValuesIncomplete: Bool? = nil,
        inferenceProvenance: TypeInferenceProvenance? = nil
    ) {
        self.inferenceProvenance = inferenceProvenance
        self.id = id
        self.kind = kind
        self.name = name
        self.fields = fields
        self.layoutRules = layoutRules
        self.vectorByteSize = vectorByteSize
        self.enumValuesIncomplete = enumValuesIncomplete
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case name
        case fields
        case layoutRules
        case vectorByteSize
        case enumValuesIncomplete
        case inferenceProvenance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(TypeKind.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        fields = try container.decode([FieldDef].self, forKey: .fields)
        layoutRules = try container.decodeIfPresent(AggregateLayoutRules.self, forKey: .layoutRules) ?? .default
        vectorByteSize = try container.decodeIfPresent(Int.self, forKey: .vectorByteSize)
        enumValuesIncomplete = try container.decodeIfPresent(Bool.self, forKey: .enumValuesIncomplete)
        inferenceProvenance = try container.decodeIfPresent(TypeInferenceProvenance.self, forKey: .inferenceProvenance)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encode(fields, forKey: .fields)
        try container.encodeIfPresent(vectorByteSize, forKey: .vectorByteSize)
        try container.encodeIfPresent(enumValuesIncomplete, forKey: .enumValuesIncomplete)
        try container.encodeIfPresent(inferenceProvenance, forKey: .inferenceProvenance)
        if layoutRules != .default {
            try container.encode(layoutRules, forKey: .layoutRules)
        }
    }

    /// The byte offset of each field, following the C ABI: each field is aligned up to its
    /// natural alignment. struct = aligned cumulative; union = every field at 0; enum/typedef
    /// = no member layout. Nested aggregate and array field types resolve through `catalog`
    /// (name → definition); a field whose size can't be determined stops advancing the offset
    /// so neither it nor subsequent fields receive an invented offset in this legacy byte view.
    /// Bitfields additionally carry their exact absolute `field.bitOffset` and declared width.
    public func memberLayout(in catalog: [String: TypeDefinition] = [:]) -> [(field: FieldDef, offset: Int)] {
        switch kind {
        case .struct:
            return TypeDefinition.aggregateLayout(self, in: catalog, visiting: [], strict: false)?.members ?? []
        case .union:
            return TypeDefinition.aggregateLayout(self, in: catalog, visiting: [], strict: false)?.members ?? []
        case .enum, .typedef:
            return []
        }
    }

    /// Byte size of a C type name (nil = unknown). Convenience over the catalog-aware form with
    /// no catalog: resolves primitives, pointers (8 bytes), and arrays of those.
    public static func size(ofType type: String) -> Int? {
        size(ofType: type, in: [:])
    }

    /// Byte size of a C type name, resolving nested aggregates and arrays through `catalog`.
    /// Pointers are 8 bytes (arm64); `T[N]` is `N * size(T)`; a struct/union is its ABI size
    /// (aligned cumulative / aligned max member) padded up to its own alignment. nil for an
    /// unresolved type. Guarded against a by-value cycle in a hostile catalog.
    public static func size(ofType type: String, in catalog: [String: TypeDefinition]) -> Int? {
        size(ofType: type, in: catalog, visiting: [])
    }

    /// Natural alignment of a C type name (nil = unknown). Primitive alignment equals its size;
    /// a pointer is 8; an array's is its element's; an aggregate's is its max member alignment.
    public static func alignment(ofType type: String, in catalog: [String: TypeDefinition]) -> Int? {
        alignment(ofType: type, in: catalog, visiting: [])
    }

    // MARK: - C layout (private, cycle-guarded by the aggregate names on the stack)

    private static func size(ofType type: String, in catalog: [String: TypeDefinition], visiting: Set<String>) -> Int? {
        let normalized = type.trimmingCharacters(in: .whitespaces)
        if normalized.hasSuffix("*") { return 8 }
        if let (element, count) = arrayComponents(normalized) {
            guard let elementSize = size(ofType: element, in: catalog, visiting: visiting) else { return nil }
            let (product, overflow) = elementSize.multipliedReportingOverflow(by: count)
            return overflow ? nil : product
        }
        if let primitive = primitiveSize(normalized) { return primitive }
        guard let def = aggregate(normalized, in: catalog) else { return nil }
        switch def.kind {
        case .struct, .union:
            return aggregateSize(def, in: catalog, visiting: visiting)
        case .enum:
            return enumSize(def)
        case .typedef:
            if def.vectorByteSize != nil { return vectorSize(def, in: catalog, visiting: visiting) }
            guard !visiting.contains(def.name), let target = typedefTarget(def),
                  def.fields[0].isAtomic != true || hasKnownAtomicLayout(target, in: catalog, visiting: visiting.union([def.name])) else { return nil }
            return size(ofType: target, in: catalog, visiting: visiting.union([def.name]))
        }
    }

    private static func alignment(ofType type: String, in catalog: [String: TypeDefinition], visiting: Set<String>) -> Int? {
        let normalized = type.trimmingCharacters(in: .whitespaces)
        if normalized.hasSuffix("*") { return 8 }
        if let (element, _) = arrayComponents(normalized) {
            return alignment(ofType: element, in: catalog, visiting: visiting)
        }
        if let primitive = primitiveSize(normalized) { return primitive }
        guard let def = aggregate(normalized, in: catalog), !visiting.contains(def.name) else { return nil }
        switch def.kind {
        case .struct, .union:
            return aggregateLayout(def, in: catalog, visiting: visiting, strict: true)?.alignment
        case .enum:
            return enumSize(def)
        case .typedef:
            if def.vectorByteSize != nil { return vectorSize(def, in: catalog, visiting: visiting) }
            guard let target = typedefTarget(def),
                  def.fields[0].isAtomic != true || hasKnownAtomicLayout(target, in: catalog, visiting: visiting.union([def.name])) else { return nil }
            return alignment(ofType: target, in: catalog, visiting: visiting.union([def.name]))
        }
    }

    private static func aggregateSize(_ def: TypeDefinition, in catalog: [String: TypeDefinition], visiting: Set<String>) -> Int? {
        aggregateLayout(def, in: catalog, visiting: visiting, strict: true)?.size
    }

    private struct AggregateLayout {
        var members: [(field: FieldDef, offset: Int)]
        // Preserve source aggregate grouping for ABI classification. The UI's
        // promoted-member view remains unchanged; both share computed offsets.
        var directMembers: [(field: FieldDef, offset: Int)] = []
        var size: Int
        var alignment: Int
    }

    private struct FieldLayoutMetrics {
        var size: Int
        var alignment: Int
        var promotedMembers: [(field: FieldDef, offset: Int)]?
    }

    private static func aggregateLayout(
        _ def: TypeDefinition,
        in catalog: [String: TypeDefinition],
        visiting: Set<String>,
        strict: Bool
    ) -> AggregateLayout? {
        guard !visiting.contains(def.name) else { return nil }  // by-value cycle → unsized (no crash)
        let inner = visiting.union([def.name])
        switch def.kind {
        case .struct:
            return structLayout(def, in: catalog, visiting: inner, strict: strict)
        case .union:
            return unionLayout(def, in: catalog, visiting: inner, strict: strict)
        case .enum, .typedef:
            return nil
        }
    }

    private static func structLayout(
        _ def: TypeDefinition,
        in catalog: [String: TypeDefinition],
        visiting: Set<String>,
        strict: Bool
    ) -> AggregateLayout? {
        var bitCursor = 0
        var maxAlign = 1
        var members: [(field: FieldDef, offset: Int)] = []
        var directMembers: [(field: FieldDef, offset: Int)] = []
        let fields = def.fields
        func unknownLayout() -> AggregateLayout? {
            strict ? nil : AggregateLayout(members: members, size: 0, alignment: maxAlign)
        }

        for index in fields.indices {
            let field = fields[index]
            guard field.layoutIsUnknown != true else { return unknownLayout() }
            if let width = field.bitWidth {
                guard let naturalAlign = alignment(ofType: field.type, in: catalog, visiting: visiting),
                      let size = size(ofType: field.type, in: catalog, visiting: visiting),
                      let capacity = bitFieldValueCapacityBits(field.type, in: catalog, visiting: visiting),
                      width >= 0,
                      width <= capacity
                else {
                    if strict { return nil }
                    return AggregateLayout(members: members, size: 0, alignment: maxAlign)
                }
                guard let align = effectiveMemberAlignment(
                    naturalAlign,
                    field: field,
                    rules: def.layoutRules,
                    in: catalog,
                    visiting: visiting,
                    strict: strict
                ) else {
                    if strict { return nil }
                    return AggregateLayout(members: members, size: 0, alignment: maxAlign)
                }

                guard naturalAlign <= Int.max / 8, size <= Int.max / 8, align <= Int.max / 8 else { return unknownLayout() }
                var explicitAlignment = field.minimumAlignment ?? 0
                if let type = field.minimumAlignmentType {
                    guard let typeAlignment = alignment(ofType: type, in: catalog, visiting: visiting) else { return unknownLayout() }
                    explicitAlignment = max(explicitAlignment, typeAlignment)
                }
                guard explicitAlignment <= Int.max / 8 else { return unknownLayout() }
                if width == 0 {
                    // Clang RecordLayoutBuilder.cpp 1544–1803: zero-width fields
                    // retain the natural boundary even inside a packed record.
                    guard let resetByte = aligned(ceilBitsToBytes(bitCursor), to: max(naturalAlign, explicitAlignment)),
                          resetByte <= Int.max / 8 else { return unknownLayout() }
                    bitCursor = resetByte * 8
                    var placed = field
                    placed.bitOffset = bitCursor
                    members.append((placed, resetByte))
                    directMembers.append((placed, resetByte))
                    continue
                }
                let bitAlignment: Int
                if let pack = def.layoutRules.packAlignment {
                    bitAlignment = min(max(naturalAlign, explicitAlignment), pack)
                } else {
                    bitAlignment = align
                }
                if !field.name.isEmpty { maxAlign = max(maxAlign, bitAlignment) }
                let packed = def.layoutRules.isPacked || field.isPacked == true || def.layoutRules.packAlignment != nil
                // Ordinary bitfields can share a naturally aligned storage unit;
                // packed fields instead begin at the next free bit and may cross it.
                if !packed && bitCursor % (naturalAlign * 8) + width > size * 8 {
                    guard let next = aligned(bitCursor, to: naturalAlign * 8) else { return unknownLayout() }
                    bitCursor = next
                }
                if explicitAlignment > 0, def.layoutRules.packAlignment.map({ explicitAlignment <= $0 }) ?? true {
                    guard let next = aligned(bitCursor, to: explicitAlignment * 8) else { return unknownLayout() }
                    bitCursor = next
                }
                guard bitCursor <= Int.max - width else { return unknownLayout() }
                var placed = field
                placed.bitOffset = bitCursor
                members.append((placed, bitCursor / 8))
                directMembers.append((placed, bitCursor / 8))
                bitCursor += width
                continue
            }

            guard let metrics = fieldLayoutMetrics(
                field,
                in: catalog,
                visiting: visiting,
                strict: strict,
                allowsFlexibleArray: index == fields.index(before: fields.endIndex)
            ) else {
                if strict { return nil }
                return AggregateLayout(members: members, size: 0, alignment: maxAlign)
            }
            guard let align = effectiveMemberAlignment(
                metrics.alignment,
                field: field,
                rules: def.layoutRules,
                in: catalog,
                visiting: visiting,
                strict: strict
            ) else {
                if strict { return nil }
                return AggregateLayout(members: members, size: 0, alignment: maxAlign)
            }

            maxAlign = max(maxAlign, align)
            guard let byteOffset = aligned(ceilBitsToBytes(bitCursor), to: align), metrics.size >= 0 else { return unknownLayout() }
            let (endByte, overflow) = byteOffset.addingReportingOverflow(metrics.size)
            guard !overflow, endByte <= Int.max / 8 else { return unknownLayout() }
            directMembers.append((field, byteOffset))
            if let promotedMembers = metrics.promotedMembers {
                for member in promotedMembers {
                    var placed = member.field
                    if let bit = placed.bitOffset { placed.bitOffset = byteOffset * 8 + bit }
                    members.append((placed, byteOffset + member.offset))
                }
            } else {
                members.append((field, byteOffset))
            }
            bitCursor = endByte * 8
        }

        let finalAlign = effectiveAggregateAlignment(maxAlign, rules: def.layoutRules)
        guard let size = aligned(ceilBitsToBytes(bitCursor), to: finalAlign) else { return unknownLayout() }
        return AggregateLayout(members: members, directMembers: directMembers, size: size, alignment: finalAlign)
    }

    private static func unionLayout(
        _ def: TypeDefinition,
        in catalog: [String: TypeDefinition],
        visiting: Set<String>,
        strict: Bool
    ) -> AggregateLayout? {
        var maxSize = 0
        var maxAlign = 1
        var members: [(field: FieldDef, offset: Int)] = []
        var directMembers: [(field: FieldDef, offset: Int)] = []

        for field in def.fields {
            guard field.layoutIsUnknown != true else {
                return strict ? nil : AggregateLayout(members: members, size: 0, alignment: maxAlign)
            }
            if let width = field.bitWidth {
                guard let naturalAlign = alignment(ofType: field.type, in: catalog, visiting: visiting),
                      size(ofType: field.type, in: catalog, visiting: visiting) != nil,
                      let capacity = bitFieldValueCapacityBits(field.type, in: catalog, visiting: visiting),
                      width >= 0,
                      width <= capacity
                else {
                    if strict { return nil }
                    return AggregateLayout(members: members, size: 0, alignment: maxAlign)
                }
                guard let align = effectiveMemberAlignment(
                    naturalAlign,
                    field: field,
                    rules: def.layoutRules,
                    in: catalog,
                    visiting: visiting,
                    strict: strict
                ) else {
                    if strict { return nil }
                    return AggregateLayout(members: members, size: 0, alignment: maxAlign)
                }

                if field.name.isEmpty {
                    if width > 0 {
                        maxSize = max(maxSize, ceilBitsToBytes(width))
                    }
                } else {
                    maxSize = max(maxSize, ceilBitsToBytes(width))
                    var bitAlignment = align
                    if let pack = def.layoutRules.packAlignment {
                        var explicit = field.minimumAlignment ?? 0
                        if let type = field.minimumAlignmentType {
                            guard let value = alignment(ofType: type, in: catalog, visiting: visiting) else { return nil }
                            explicit = max(explicit, value)
                        }
                        bitAlignment = min(max(naturalAlign, explicit), pack)
                    }
                    maxAlign = max(maxAlign, bitAlignment)
                }
                var placed = field
                placed.bitOffset = 0
                members.append((placed, 0))
                directMembers.append((placed, 0))
                continue
            }

            guard let metrics = fieldLayoutMetrics(field, in: catalog, visiting: visiting, strict: strict, allowsFlexibleArray: false) else {
                if strict { return nil }
                return AggregateLayout(members: members, size: 0, alignment: maxAlign)
            }
            guard let align = effectiveMemberAlignment(
                metrics.alignment,
                field: field,
                rules: def.layoutRules,
                in: catalog,
                visiting: visiting,
                strict: strict
            ) else {
                if strict { return nil }
                return AggregateLayout(members: members, size: 0, alignment: maxAlign)
            }
            directMembers.append((field, 0))
            if let promotedMembers = metrics.promotedMembers {
                members.append(contentsOf: promotedMembers)
            } else {
                members.append((field, 0))
            }
            maxSize = max(maxSize, metrics.size)
            maxAlign = max(maxAlign, align)
        }

        let finalAlign = effectiveAggregateAlignment(maxAlign, rules: def.layoutRules)
        guard let size = aligned(maxSize, to: finalAlign) else { return nil }
        return AggregateLayout(members: members, directMembers: directMembers, size: size, alignment: finalAlign)
    }

    private static func fieldLayoutMetrics(
        _ field: FieldDef,
        in catalog: [String: TypeDefinition],
        visiting: Set<String>,
        strict: Bool,
        allowsFlexibleArray: Bool
    ) -> FieldLayoutMetrics? {
        guard field.isAtomic != true || hasKnownAtomicLayout(field.type, in: catalog, visiting: visiting) else { return nil }
        if let inlineKind = field.inlineAggregateKind {
            guard let inlineLayout = inlineAggregateLayout(
                kind: inlineKind,
                fields: field.inlineFields,
                layoutRules: field.inlineAggregateLayoutRules,
                in: catalog,
                visiting: visiting,
                strict: true
            ) else {
                return nil
            }
            return FieldLayoutMetrics(
                size: inlineLayout.size,
                alignment: inlineLayout.alignment,
                promotedMembers: field.promotesInlineFields ? inlineLayout.members : nil
            )
        }

        if allowsFlexibleArray, let element = flexibleArrayElementType(field.type) {
            guard let align = alignment(ofType: element, in: catalog, visiting: visiting) else {
                return nil
            }
            return FieldLayoutMetrics(size: 0, alignment: align, promotedMembers: nil)
        }

        guard let align = alignment(ofType: field.type, in: catalog, visiting: visiting),
              let size = size(ofType: field.type, in: catalog, visiting: visiting)
        else {
            return nil
        }
        return FieldLayoutMetrics(size: size, alignment: align, promotedMembers: nil)
    }

    private static func inlineAggregateLayout(
        kind: TypeKind,
        fields: [FieldDef],
        layoutRules: AggregateLayoutRules,
        in catalog: [String: TypeDefinition],
        visiting: Set<String>,
        strict: Bool
    ) -> AggregateLayout? {
        let inline = TypeDefinition(kind: kind, name: "<inline aggregate>", fields: fields, layoutRules: layoutRules)
        switch kind {
        case .struct:
            return structLayout(inline, in: catalog, visiting: visiting, strict: strict)
        case .union:
            return unionLayout(inline, in: catalog, visiting: visiting, strict: strict)
        case .enum, .typedef:
            return nil
        }
    }

    private static func effectiveMemberAlignment(
        _ naturalAlignment: Int,
        field: FieldDef,
        rules: AggregateLayoutRules,
        in catalog: [String: TypeDefinition],
        visiting: Set<String>,
        strict: Bool
    ) -> Int? {
        var alignment = (rules.isPacked || field.isPacked == true) ? 1 : naturalAlignment
        if let minimumAlignment = field.minimumAlignment {
            alignment = max(alignment, minimumAlignment)
        }
        if let minimumAlignmentType = field.minimumAlignmentType {
            guard let resolved = self.alignment(ofType: minimumAlignmentType, in: catalog, visiting: visiting) else {
                return nil
            }
            alignment = max(alignment, resolved)
        }
        if let packAlignment = rules.packAlignment {
            alignment = min(alignment, packAlignment)
        }
        return alignment
    }

    private static func effectiveAggregateAlignment(_ maxMemberAlignment: Int, rules: AggregateLayoutRules) -> Int {
        var alignment = maxMemberAlignment
        if let minimumAlignment = rules.minimumAlignment {
            alignment = max(alignment, minimumAlignment)
        }
        return max(alignment, 1)
    }

    private static func primitiveSize(_ type: String) -> Int? {
        let words = type.split(whereSeparator: { $0.isWhitespace }).filter {
            !["const", "volatile", "restrict", "_Atomic"].contains(String($0))
        }
        switch words.joined(separator: " ") {
        case "int8_t", "uint8_t", "char", "signed char", "unsigned char", "bool", "_Bool": return 1
        case "int16_t", "uint16_t", "short", "short int", "signed short", "signed short int", "unsigned short", "unsigned short int": return 2
        case "int32_t", "uint32_t", "int", "signed", "signed int", "unsigned", "unsigned int", "float", "wchar_t": return 4
        case "int64_t", "uint64_t", "long", "long int", "signed long", "signed long int", "unsigned long", "unsigned long int",
             "long long", "long long int", "signed long long", "signed long long int", "unsigned long long", "unsigned long long int",
             "double", "long double", "size_t", "ssize_t", "intptr_t", "uintptr_t", "ptrdiff_t": return 8
        case "__int128", "signed __int128", "unsigned __int128": return 16
        default: return nil
        }
    }

    private static func hasKnownAtomicLayout(_ type: String, in catalog: [String: TypeDefinition], visiting: Set<String>) -> Bool {
        if primitiveSize(type) != nil || type.hasSuffix("*") { return true }
        guard let alias = aggregate(type, in: catalog), alias.kind == .typedef,
              alias.vectorByteSize == nil, !visiting.contains(alias.name), let target = typedefTarget(alias) else { return false }
        return hasKnownAtomicLayout(target, in: catalog, visiting: visiting.union([alias.name]))
    }

    private static func vectorSize(_ def: TypeDefinition, in catalog: [String: TypeDefinition], visiting: Set<String>) -> Int? {
        guard !visiting.contains(def.name), def.fields.first?.isAtomic != true,
              let bytes = def.vectorByteSize, [8, 16].contains(bytes),
              var element = typedefTarget(def) else { return nil }
        var seen = visiting.union([def.name])
        while primitiveSize(element) == nil {
            guard let alias = aggregate(element, in: catalog), alias.kind == .typedef,
                  alias.vectorByteSize == nil, !seen.contains(alias.name), let target = typedefTarget(alias) else { return nil }
            seen.insert(alias.name)
            element = target
        }
        guard !["bool", "_Bool"].contains(element), let size = primitiveSize(element), bytes.isMultiple(of: size) else { return nil }
        return bytes
    }

    /// Darwin's unpacked enum uses the smallest int-or-larger integer that holds its range.
    /// Enumerator values remain decimal strings, including unsigned values above Int64.max.
    private static func enumSize(_ def: TypeDefinition) -> Int? {
        guard def.enumValuesIncomplete != true else { return nil }
        var minimum: Int64 = 0
        var maximum: UInt64 = 0
        for field in def.fields {
            if field.type.hasPrefix("-") {
                guard let value = Int64(field.type) else { return nil }
                minimum = min(minimum, value)
            } else {
                guard let value = UInt64(field.type) else { return nil }
                maximum = max(maximum, value)
            }
        }
        if minimum < 0 {
            if minimum >= Int64(Int32.min), maximum <= UInt64(Int32.max) { return 4 }
            return maximum <= UInt64(Int64.max) ? 8 : nil
        }
        return maximum <= UInt64(UInt32.max) ? 4 : 8
    }

    /// Parses an `Element[N]` array type into (element, count); nil if not an array or N <= 0.
    /// Multi-dimensional `T[a][b]` peels the outermost dimension and recurses through `element`.
    private static func arrayComponents(_ type: String) -> (element: String, count: Int)? {
        guard type.hasSuffix("]"), let open = type.lastIndex(of: "[") else { return nil }
        let inner = type[type.index(after: open)..<type.index(before: type.endIndex)]
        guard let count = Int(inner.trimmingCharacters(in: .whitespaces)), count > 0 else { return nil }
        let element = String(type[..<open]).trimmingCharacters(in: .whitespaces)
        return element.isEmpty ? nil : (element, count)
    }

    private static func flexibleArrayElementType(_ type: String) -> String? {
        let normalized = type.trimmingCharacters(in: .whitespaces)
        guard normalized.hasSuffix("[]") else { return nil }
        let element = String(normalized.dropLast(2)).trimmingCharacters(in: .whitespaces)
        return element.isEmpty ? nil : element
    }

    static func bitFieldValueCapacityBits(_ type: String, in catalog: [String: TypeDefinition], visiting: Set<String> = []) -> Int? {
        let name = type.split(whereSeparator: { $0.isWhitespace }).filter { !["const", "volatile", "_Atomic", "restrict"].contains(String($0)) }.joined(separator: " ")
        if name == "_Bool" || name == "bool" { return 1 }
        if ["float", "double", "long double"].contains(name) { return nil }
        if let size = primitiveSize(name) { return size * 8 }
        guard let definition = aggregate(name, in: catalog), !visiting.contains(definition.name) else { return nil }
        if definition.kind == .enum { return enumSize(definition).map { $0 * 8 } }
        guard definition.kind == .typedef, definition.vectorByteSize == nil, let target = typedefTarget(definition) else { return nil }
        return bitFieldValueCapacityBits(target, in: catalog, visiting: visiting.union([definition.name]))
    }

    /// Resolves a struct/union type name (with an optional `struct `/`union `/`enum ` keyword)
    /// to its catalog definition.
    private static func aggregate(_ type: String, in catalog: [String: TypeDefinition]) -> TypeDefinition? {
        var name = type
        for keyword in ["struct ", "union ", "enum "] where name.hasPrefix(keyword) {
            name = String(name.dropFirst(keyword.count)).trimmingCharacters(in: .whitespaces)
        }
        return catalog[name]
    }

    private static func typedefTarget(_ def: TypeDefinition) -> String? {
        guard def.kind == .typedef, def.fields.count == 1, def.fields[0].layoutIsUnknown != true else { return nil }
        let target = def.fields[0].type.trimmingCharacters(in: .whitespaces)
        return target.isEmpty ? nil : target
    }

    /// Rounds `offset` up to the next multiple of `alignment` (a power of two in practice).
    private static func aligned(_ offset: Int, to alignment: Int) -> Int? {
        guard offset >= 0, alignment > 0 else { return nil }
        let remainder = offset % alignment
        let (result, overflow) = offset.addingReportingOverflow(remainder == 0 ? 0 : alignment - remainder)
        return overflow ? nil : result
    }

    private static func ceilBitsToBytes(_ bits: Int) -> Int {
        guard bits > 0 else { return 0 }
        return bits / 8 + (bits % 8 == 0 ? 0 : 1)
    }
}

/// Binder adapter over the same checked record layout used by Type Atlas.
/// It discovers homogeneous shape; it never computes record offsets independently.
public struct TypeAtlasDarwinARM64LayoutResolver: DarwinARM64TypeLayoutResolving {
    public let catalog: [String: TypeDefinition]
    public init(catalog: [String: TypeDefinition] = [:]) { self.catalog = catalog }
    public func resolveLayout(ofType type: String) -> DarwinARM64TypeLayout? {
        TypeDefinition.abiLayout(type, in: catalog, visiting: [])
    }

    /// D05: prove this is a direct, ordinary, non-HFA struct whose leaves are
    /// known integer, `float` or `double` scalars. On Darwin ARM64 such a
    /// composite of at most 16 bytes travels byte-for-byte in dense GPRs, so
    /// mixed integer/FP structs share the integer fragment model. The rich
    /// binder remains the authority for size, alignment and register placement;
    /// this gate only excludes pointer-bearing or otherwise uncertain aggregates.
    func isDirectGPRStruct(_ type: String) -> Bool {
        let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.hasPrefix("struct ")
            ? String(trimmed.dropFirst("struct ".count)).trimmingCharacters(in: .whitespaces)
            : trimmed
        guard let definition = catalog[name], definition.kind == .struct,
              definition.layoutRules == .default, !definition.fields.isEmpty,
              let layout = resolveLayout(ofType: type), layout.kind == .aggregate,
              layout.homogeneous == nil, (1...16).contains(layout.size) else { return false }
        return definition.fields.allSatisfy { field in
            !field.name.isEmpty && field.layoutIsUnknown != true &&
            field.isPacked != true && field.isAtomic != true &&
            field.bitWidth == nil && field.bitOffset == nil &&
            field.minimumAlignment == nil && field.minimumAlignmentType == nil &&
            field.inlineAggregateKind == nil && field.inlineFields.isEmpty &&
            !field.promotesInlineFields && field.byteOffset == nil &&
            field.layoutSource == nil &&
            DarwinARM64ParameterBinder.normalizedDataPointer(field.type) == nil &&
            (DarwinARM64ParameterBinder.isSupportedLegacyGPRScalar(field.type)
                || ["float", "double"].contains(field.type.trimmingCharacters(in: .whitespaces)))
        }
    }
}

extension TypeDefinition {
    fileprivate static func abiLayout(_ type: String, in catalog: [String: TypeDefinition], visiting: Set<String>) -> DarwinARM64TypeLayout? {
        if DarwinARM64ParameterBinder.normalizedDataPointer(type) != nil {
            guard let size = size(ofType: "void *", in: catalog) else { return nil }
            return DarwinARM64TypeLayout(kind: .integer, size: size, alignment: size)
        }
        guard !type.split(whereSeparator: { $0.isWhitespace }).contains("restrict") else { return nil }
        let isAtomic = type.split(whereSeparator: { $0.isWhitespace }).contains("_Atomic")
        let name = type.split(whereSeparator: { $0.isWhitespace }).filter { !["const", "volatile", "_Atomic"].contains(String($0)) }.joined(separator: " ")
        if ["float", "double", "long double"].contains(name), let bytes = size(ofType: name, in: catalog) {
            return DarwinARM64TypeLayout(kind: .floating, size: bytes, alignment: bytes)
        }
        if primitiveSize(name) != nil, bitFieldValueCapacityBits(name, in: catalog) != nil,
           let bytes = size(ofType: name, in: catalog) {
            return DarwinARM64TypeLayout(kind: .integer, size: bytes, alignment: bytes)
        }
        guard !isAtomic, name != "void",
              DarwinARM64ParameterBinder.normalizedDataPointer(name + " *") != nil,
              let definition = aggregate(name, in: catalog), !visiting.contains(definition.name) else { return nil }
        for kind in [TypeKind.struct, .union, .enum] where name.hasPrefix(kind.rawValue + " ") {
            guard definition.kind == kind else { return nil }
        }
        let inner = visiting.union([definition.name])
        switch definition.kind {
        case .typedef:
            if definition.vectorByteSize != nil {
                guard let bytes = vectorSize(definition, in: catalog, visiting: visiting) else { return nil }
                return DarwinARM64TypeLayout(kind: .shortVector, size: bytes, alignment: bytes)
            }
            guard let target = typedefTarget(definition) else { return nil }
            let resolved = abiLayout(target, in: catalog, visiting: inner)
            if definition.fields.first?.isAtomic == true {
                guard let resolved, resolved.kind == .floating || resolved.kind == .integer else { return nil }
                return resolved
            }
            return resolved
        case .enum:
            guard let bytes = enumSize(definition) else { return nil }
            return DarwinARM64TypeLayout(kind: .integer, size: bytes, alignment: bytes)
        case .struct, .union:
            guard let layout = aggregateLayout(definition, in: catalog, visiting: visiting, strict: true), layout.size > 0 else { return nil }
            let shape = homogeneousShape(kind: definition.kind, layout: layout, in: catalog, visiting: inner)
            switch shape {
            case .unsupported: return nil
            case .ordinary:
                return DarwinARM64TypeLayout(kind: .aggregate, size: layout.size, alignment: layout.alignment)
            case let .homogeneous(base, offsets):
                return DarwinARM64TypeLayout(kind: .aggregate, size: layout.size, alignment: layout.alignment,
                                             homogeneous: .init(base: base, memberOffsets: offsets))
            }
        }
    }

    private enum HomogeneousShape {
        case ordinary
        case unsupported
        case homogeneous(DarwinARM64TypeLayout.HomogeneousBase, [Int])
    }

    private static func homogeneousShape(kind: TypeKind, layout: AggregateLayout, in catalog: [String: TypeDefinition], visiting: Set<String>) -> HomogeneousShape {
        guard !layout.directMembers.isEmpty else { return .unsupported }
        var base: DarwinARM64TypeLayout.HomogeneousBase?
        var offsets: [Int] = []
        var ordinary = false
        for member in layout.directMembers {
            let field = member.field
            // Flexible arrays and bitfield/HFA combinations are outside the
            // call oracle. Unknown shape must not silently become a GPR guess.
            guard field.bitWidth == nil, field.layoutIsUnknown != true, field.isAtomic != true, !field.type.hasSuffix("[]") else { return .unsupported }
            let shape: HomogeneousShape
            if let inlineKind = field.inlineAggregateKind {
                guard let inline = inlineAggregateLayout(kind: inlineKind, fields: field.inlineFields,
                                                        layoutRules: field.inlineAggregateLayoutRules,
                                                        in: catalog, visiting: visiting, strict: true) else { return .unsupported }
                shape = homogeneousShape(kind: inlineKind, layout: inline, in: catalog, visiting: visiting)
            } else {
                shape = homogeneousShape(ofType: field.type, in: catalog, visiting: visiting)
            }
            switch shape {
            case .unsupported: return .unsupported
            case .ordinary: ordinary = true
            case let .homogeneous(memberBase, memberOffsets):
                if let base, base != memberBase { ordinary = true }
                base = base ?? memberBase
                if kind == .union {
                    if memberOffsets.count > offsets.count { offsets = memberOffsets }
                } else {
                    offsets.append(contentsOf: memberOffsets.map { member.offset + $0 })
                }
            }
        }
        guard !ordinary, let base else { return .ordinary }
        guard (1...4).contains(offsets.count) else { return .ordinary }
        let bytes = base.byteSize
        // Disqualifying padding/over-alignment is deliberately conservative:
        // these homogeneous-looking extension cases have no call-oracle evidence.
        guard layout.size == bytes * offsets.count, layout.alignment <= bytes,
              offsets == (0..<offsets.count).map({ $0 * bytes }) else { return .unsupported }
        return .homogeneous(base, offsets)
    }

    private static func homogeneousShape(ofType type: String, in catalog: [String: TypeDefinition], visiting: Set<String>) -> HomogeneousShape {
        guard !type.split(whereSeparator: { $0.isWhitespace }).contains("_Atomic") else { return .unsupported }
        if let definition = aggregate(type, in: catalog), definition.kind == .typedef, definition.vectorByteSize == nil {
            guard !visiting.contains(definition.name), definition.fields.first?.isAtomic != true,
                  let target = typedefTarget(definition) else { return .unsupported }
            return homogeneousShape(ofType: target, in: catalog, visiting: visiting.union([definition.name]))
        }
        if let (element, count) = arrayComponents(type) {
            switch homogeneousShape(ofType: element, in: catalog, visiting: visiting) {
            case .ordinary: return .ordinary
            case .unsupported: return .unsupported
            case let .homogeneous(base, offsets):
                guard count <= 4, offsets.count <= 4 / count else { return .ordinary }
                guard let stride = size(ofType: element, in: catalog, visiting: visiting) else { return .unsupported }
                return .homogeneous(base, (0..<count).flatMap { index in offsets.map { index * stride + $0 } })
            }
        }
        guard let layout = abiLayout(type, in: catalog, visiting: visiting) else { return .unsupported }
        switch layout.kind {
        case .integer: return .ordinary
        case .floating: return .homogeneous(.floating(byteSize: layout.size), [0])
        case .shortVector:
            // AAPCS64 homogeneous short-vector equivalence is total vector width,
            // not element type (also corroborated by the supplementary Clang probes).
            return .homogeneous(.shortVector(byteSize: layout.size), [0])
        case .aggregate:
            guard let homogeneous = layout.homogeneous else { return .ordinary }
            return .homogeneous(homogeneous.base, homogeneous.memberOffsets)
        }
    }


}

/// Pure, GUI-free decode of an applied struct/union type over the loaded bytes:
/// one row per field with its byte offset and the little-endian primitive value at
/// `baseOffset + fieldOffset`. Mirrors `DataInspectorReading`'s overflow guards —
/// a field past the loaded tail (or of unknown type) reads "—".
struct StructMemberReading: Equatable {
    struct Row: Equatable {
        var name: String
        var type: String
        var offset: Int
        var value: String
    }

    let rows: [Row]

    init(type: TypeDefinition, bytes: Data, baseOffset: Int?, catalog: [String: TypeDefinition] = [:]) {
        rows = type.memberLayout(in: catalog).map { field, fieldOffset in
            Row(
                name: field.name,
                type: field.type,
                offset: fieldOffset,
                value: Self.decode(bytes: bytes, baseOffset: baseOffset, fieldOffset: fieldOffset, type: field.type, catalog: catalog)
            )
        }
    }

    private static func decode(bytes: Data, baseOffset: Int?, fieldOffset: Int, type: String, catalog: [String: TypeDefinition]) -> String {
        // Keep scalar reading inside the core model; importing C declarations belongs to the app.
        // Match the qualifiers accepted by primitiveSize, then interpret its known spellings.
        let normalized = type.split(whereSeparator: { $0.isWhitespace }).filter {
            !["const", "volatile", "restrict", "_Atomic"].contains(String($0))
        }.joined(separator: " ")
        guard let baseOffset,
              let size = TypeDefinition.size(ofType: normalized, in: catalog),
              size <= 8 else { return "—" }
        let (relative, relativeOverflow) = baseOffset.addingReportingOverflow(fieldOffset)
        let (start, startOverflow) = bytes.startIndex.addingReportingOverflow(relative)
        let (end, endOverflow) = start.addingReportingOverflow(size)
        guard !relativeOverflow, !startOverflow, !endOverflow, relative >= 0, end <= bytes.endIndex else { return "—" }

        var raw: UInt64 = 0
        for index in 0..<size {
            raw |= UInt64(bytes[start + index]) << (8 * index) // little-endian
        }

        if normalized.hasSuffix("*") || normalized == "intptr_t" || normalized == "uintptr_t" {
            return "0x" + String(format: "%016llx", raw)
        }
        switch normalized {
        case "float": return String(Float(bitPattern: UInt32(truncatingIfNeeded: raw)))
        case "double", "long double": return String(Double(bitPattern: raw))
        case "char":
            let byte = UInt8(truncatingIfNeeded: raw)
            // Escape the two printable bytes that would otherwise produce a malformed
            // quoted literal: ' (0x27) -> '\'' and \ (0x5C) -> '\\'.
            if byte == 0x27 { return "'\\''" }
            if byte == 0x5C { return "'\\\\'" }
            return (byte >= 0x20 && byte < 0x7F) ? "'\(Character(UnicodeScalar(byte)))'" : String(Int8(bitPattern: byte))
        case "bool", "_Bool": return raw == 0 ? "false" : "true"
        case "uint8_t", "uint16_t", "uint32_t", "uint64_t", "size_t",
             "unsigned char", "unsigned short", "unsigned short int", "unsigned", "unsigned int",
             "unsigned long", "unsigned long int", "unsigned long long", "unsigned long long int": return String(raw)
        case "int8_t", "signed char": return String(Int8(bitPattern: UInt8(truncatingIfNeeded: raw)))
        case "int16_t", "short", "short int", "signed short", "signed short int": return String(Int16(bitPattern: UInt16(truncatingIfNeeded: raw)))
        case "int32_t", "int", "signed", "signed int": return String(Int32(bitPattern: UInt32(truncatingIfNeeded: raw)))
        default: return String(Int64(bitPattern: raw)) // int64_t, long, ssize_t
        }
    }
}
