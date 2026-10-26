import Darwin
import Foundation
import CryptoKit
import SwiftUI

/// One source-ordered parameter row in a function-signature override.
///
/// `index` is a read-only compatibility coordinate for existing consumers. In a
/// schema-v2 `parameterList`, array order is the only source-order truth and the
/// index is never encoded. `rowToken` is opaque identity: editors preserve it
/// through rename, retype, reorder, binding, and unbinding.
public struct ArgOverride: Codable, Equatable, Sendable {
    /// Where a schema-v2 row came from. Provenance is descriptive only: ABI
    /// binding remains a separate derived decision. `.debug` covers authoritative
    /// debug metadata such as DWARF without coupling the persistence model to one
    /// debug format.
    public enum Provenance: String, Codable, Equatable, Sendable {
        case user
        case script
        case debug
        case legacy
    }

    public var rowToken: String
    public internal(set) var index: Int
    public var name: String
    public var type: String
    public var provenance: Provenance

    /// Compatibility constructor for established call sites. New persisted/editor
    /// code should preserve an existing token or use the row-token constructor.
    public init(index: Int, name: String, type: String) {
        self.init(
            rowToken: Self.compatibilityRowToken(for: index),
            index: index,
            name: name,
            type: type,
            provenance: .user
        )
    }

    public init(
        rowToken: String = UUID().uuidString.lowercased(),
        name: String,
        type: String,
        provenance: Provenance = .user
    ) {
        self.init(rowToken: rowToken, index: 0, name: name, type: type, provenance: provenance)
    }

    fileprivate init(
        rowToken: String,
        index: Int,
        name: String,
        type: String,
        provenance: Provenance
    ) {
        self.rowToken = rowToken
        self.index = index
        self.name = name
        self.type = type
        self.provenance = provenance
    }

    private enum CodingKeys: String, CodingKey {
        case rowToken
        case index
        case name
        case type
        case provenance
    }

    /// Standalone decoding accepts either a v2 row or an old `ArgOverride` row.
    /// `FunctionSignatureOverride` itself uses stricter schema-aware wrappers so a
    /// legacy row cannot be smuggled into a schema-v2 `parameterList`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(String.self, forKey: .type)

        if container.contains(.rowToken) {
            rowToken = try container.decode(String.self, forKey: .rowToken)
            guard !rowToken.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .rowToken,
                    in: container,
                    debugDescription: "A function-signature row token must not be empty."
                )
            }
            provenance = try container.decode(Provenance.self, forKey: .provenance)
            index = try container.decodeIfPresent(Int.self, forKey: .index) ?? 0
        } else {
            index = try container.decode(Int.self, forKey: .index)
            rowToken = Self.compatibilityRowToken(for: index)
            provenance = .legacy
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rowToken, forKey: .rowToken)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(provenance, forKey: .provenance)
    }

    /// Source order belongs to the containing array, so compatibility `index` is
    /// excluded. Opaque row identity and authored declaration fields remain part
    /// of equality; otherwise two distinct rows could collapse during editing.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rowToken == rhs.rowToken
            && lhs.name == rhs.name
            && lhs.type == rhs.type
            && lhs.provenance == rhs.provenance
    }

    /// Existing index-based producers construct expected and actual rows
    /// independently. A deterministic opaque compatibility token preserves that
    /// source compatibility while keeping the token stable across rename/retype.
    private static func compatibilityRowToken(for index: Int) -> String {
        let digest = SHA256.hash(data: Data("macscope-signature-row:\(index)".utf8))
        let suffix = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return "compat-\(suffix)"
    }
}

/// An ambiguous pre-v2 row retained verbatim but excluded from analysis until the
/// user explicitly adopts its array order. `originalOrder` records the JSON array
/// coordinate separately from the ambiguous legacy `index` value.
public struct LegacyArgOverride: Codable, Equatable, Sendable {
    public var originalIndex: Int
    public var originalOrder: Int
    public var name: String
    public var type: String

    public init(originalIndex: Int, originalOrder: Int, name: String, type: String) {
        self.originalIndex = originalIndex
        self.originalOrder = originalOrder
        self.name = name
        self.type = type
    }
}

/// A persisted function declarator keyed by function start. Schema v3 separates
/// list presence from list contents: `.unspecified` preserves recovered parameters,
/// while `.authoritative([])` explicitly declares `(void)`, and independently
/// records whether recovered no-return semantics are preserved, set, or cleared.
public struct FunctionSignatureOverride: Codable, Equatable, Sendable {
    public enum ParameterListState: Equatable, Sendable {
        case unspecified
        case authoritative([ArgOverride])
    }

    public enum VariadicState: String, Codable, Equatable, Sendable {
        case unspecified
        case fixed
        case variadic
    }

    public enum NoReturnState: String, Codable, CaseIterable, Equatable, Sendable {
        case unspecified
        case returns
        case noReturn
    }

    public static let currentSchemaVersion = 3

    public var returnType: String?
    public var parameterList: ParameterListState
    public var variadicState: VariadicState
    public var quarantinedLegacyArgs: [LegacyArgOverride]
    public var noReturnState: NoReturnState

    /// Transitional read-only projection for analysis consumers that still render
    /// a Boolean qualifier. Authoring and persistence use `noReturnState`.
    public var isNoReturn: Bool { noReturnState == .noReturn }

    /// Compatibility projection used by existing rendering and editor paths. It is
    /// deliberately read-only: assigning an empty array must not accidentally turn
    /// an unspecified list into explicit void (or vice versa).
    public var args: [ArgOverride] {
        guard case let .authoritative(rows) = parameterList else { return [] }
        return rows
    }

    /// Presence-preserving constructor. Omitting `parameterList` means "use the
    /// recovered list", even when return type or no-return state is overridden.
    public init(
        returnType: String? = nil,
        parameterList: ParameterListState = .unspecified,
        variadicState: VariadicState = .unspecified,
        quarantinedLegacyArgs: [LegacyArgOverride] = [],
        noReturnState: NoReturnState = .unspecified
    ) {
        self.returnType = returnType
        self.parameterList = Self.normalized(parameterList)
        self.variadicState = variadicState
        self.quarantinedLegacyArgs = Self.canonicalizedQuarantine(quarantinedLegacyArgs)
        self.noReturnState = noReturnState
    }

    /// Source-compatible constructor for established `args:` call sites. Supplying
    /// `args` is always authoritative, including an explicit empty array.
    public init(
        returnType: String? = nil,
        args: [ArgOverride],
        noReturnState: NoReturnState = .unspecified
    ) {
        self.init(
            returnType: returnType,
            parameterList: .authoritative(args),
            variadicState: .fixed,
            noReturnState: noReturnState
        )
    }

    /// Source compatibility for callers that predate the tri-state authoring seam.
    /// The Boolean itself is required so this overload cannot compete with the
    /// enum-state initializer. A false value preserves recovered state; explicit
    /// clear is represented by `.returns` at current mutation boundaries.
    public init(
        returnType: String? = nil,
        parameterList: ParameterListState = .unspecified,
        variadicState: VariadicState = .unspecified,
        quarantinedLegacyArgs: [LegacyArgOverride] = [],
        isNoReturn: Bool
    ) {
        self.init(
            returnType: returnType,
            parameterList: parameterList,
            variadicState: variadicState,
            quarantinedLegacyArgs: quarantinedLegacyArgs,
            noReturnState: isNoReturn ? .noReturn : .unspecified
        )
    }

    /// Source compatibility for established `args:isNoReturn:` call sites.
    public init(
        returnType: String? = nil,
        args: [ArgOverride],
        isNoReturn: Bool
    ) {
        self.init(
            returnType: returnType,
            parameterList: .authoritative(args),
            variadicState: .fixed,
            noReturnState: isNoReturn ? .noReturn : .unspecified
        )
    }

    public static func authoritative(
        returnType: String? = nil,
        args: [ArgOverride],
        variadicState: VariadicState = .fixed,
        noReturnState: NoReturnState = .unspecified
    ) -> Self {
        Self(
            returnType: returnType,
            parameterList: .authoritative(args),
            variadicState: variadicState,
            noReturnState: noReturnState
        )
    }

    /// Source compatibility for established authoritative Boolean call sites.
    public static func authoritative(
        returnType: String? = nil,
        args: [ArgOverride],
        variadicState: VariadicState = .fixed,
        isNoReturn: Bool
    ) -> Self {
        Self(
            returnType: returnType,
            parameterList: .authoritative(args),
            variadicState: variadicState,
            noReturnState: isNoReturn ? .noReturn : .unspecified
        )
    }

    /// Makes the user's explicit adoption operation atomic: quarantined order is
    /// promoted to source order, every row receives a fresh durable token, and the
    /// old ambiguous payload is cleared.
    public func adoptingLegacyOrder(
        provenance: ArgOverride.Provenance = .user,
        variadicState adoptedVariadicState: VariadicState = .fixed
    ) -> Self {
        let adoptedRows = quarantinedLegacyArgs
            .map { legacy in
                ArgOverride(name: legacy.name, type: legacy.type, provenance: provenance)
            }
        return Self(
            returnType: returnType,
            parameterList: .authoritative(adoptedRows),
            variadicState: adoptedVariadicState,
            noReturnState: noReturnState
        )
    }

    /// Whether this value must survive save/reload. Quarantine is persisted even
    /// though it has no analysis effect, and explicit void must never be pruned.
    public var hasPersistedPayload: Bool {
        !(returnType?.isEmpty ?? true)
            || noReturnState != .unspecified
            || variadicState != .unspecified
            || Self.isAuthoritative(parameterList)
            || !quarantinedLegacyArgs.isEmpty
    }

    /// Whether applying this value can change analysis or rendering. Quarantine
    /// alone is inert until explicitly adopted.
    public var hasAnalysisEffect: Bool {
        !(returnType?.isEmpty ?? true)
            || noReturnState != .unspecified
            || variadicState != .unspecified
            || Self.isAuthoritative(parameterList)
    }

    /// Compatibility spelling used by pruning paths.
    public var isEmpty: Bool { !hasPersistedPayload }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case returnType
        case parameterList
        case variadicState
        case quarantinedLegacyArgs
        case noReturnState
        case isNoReturn
        case args
    }

    private struct PersistedParameterRow: Codable {
        var rowToken: String
        var name: String
        var type: String
        var provenance: ArgOverride.Provenance

        private enum CodingKeys: String, CodingKey {
            case rowToken
            case name
            case type
            case provenance
            case index
        }

        init(_ row: ArgOverride) {
            rowToken = row.rowToken
            name = row.name
            type = row.type
            provenance = row.provenance
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard !container.contains(.index) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .index,
                    in: container,
                    debugDescription: "Schema-v2 parameter rows use array order and must not encode index."
                )
            }
            rowToken = try container.decode(String.self, forKey: .rowToken)
            name = try container.decode(String.self, forKey: .name)
            type = try container.decode(String.self, forKey: .type)
            provenance = try container.decode(ArgOverride.Provenance.self, forKey: .provenance)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(rowToken, forKey: .rowToken)
            try container.encode(name, forKey: .name)
            try container.encode(type, forKey: .type)
            try container.encode(provenance, forKey: .provenance)
        }

        func modelRow(index: Int) throws -> ArgOverride {
            guard !rowToken.isEmpty else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "A function-signature row token must not be empty.")
                )
            }
            return ArgOverride(
                rowToken: rowToken,
                index: index,
                name: name,
                type: type,
                provenance: provenance
            )
        }
    }

    private struct LegacyParameterRow: Decodable {
        var index: Int
        var name: String
        var type: String
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        returnType = nil
        parameterList = .unspecified
        variadicState = .unspecified
        quarantinedLegacyArgs = []
        noReturnState = .unspecified

        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        switch version {
        case nil, 1:
            try self.initLegacy(from: container)
        case 2, Self.currentSchemaVersion:
            try self.initSchemaV2(from: container)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported function-signature schema."
            )
        }

        switch version {
        case nil, 1, 2:
            noReturnState = (try container.decodeIfPresent(Bool.self, forKey: .isNoReturn) == true)
                ? .noReturn
                : .unspecified
        case Self.currentSchemaVersion:
            noReturnState = try container.decodeIfPresent(
                NoReturnState.self,
                forKey: .noReturnState
            ) ?? .unspecified
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported function-signature schema."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        guard Self.isCanonicalQuarantine(quarantinedLegacyArgs) else {
            throw EncodingError.invalidValue(
                quarantinedLegacyArgs,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Quarantined legacy rows must have originalOrder values matching array order."
                )
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(returnType, forKey: .returnType)
        if case let .authoritative(rows) = parameterList {
            try container.encode(rows.map(PersistedParameterRow.init), forKey: .parameterList)
        }
        try container.encode(variadicState, forKey: .variadicState)
        if !quarantinedLegacyArgs.isEmpty {
            try container.encode(quarantinedLegacyArgs, forKey: .quarantinedLegacyArgs)
        }
        try container.encode(noReturnState, forKey: .noReturnState)
    }

    private mutating func initSchemaV2(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        guard !container.contains(.args) else {
            throw DecodingError.dataCorruptedError(
                forKey: .args,
                in: container,
                debugDescription: "A schema-v2 signature must use parameterList, not the legacy args key."
            )
        }
        returnType = try container.decodeIfPresent(String.self, forKey: .returnType)
        variadicState = try container.decodeIfPresent(VariadicState.self, forKey: .variadicState) ?? .unspecified
        quarantinedLegacyArgs = try container.decodeIfPresent(
            [LegacyArgOverride].self,
            forKey: .quarantinedLegacyArgs
        ) ?? []
        guard quarantinedLegacyArgs.enumerated().allSatisfy({ offset, row in
            row.originalOrder == offset
        }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .quarantinedLegacyArgs,
                in: container,
                debugDescription: "Quarantined legacy rows require unique contiguous originalOrder values matching array order."
            )
        }
        if container.contains(.parameterList) {
            let persistedRows = try container.decode([PersistedParameterRow].self, forKey: .parameterList)
            var seenTokens = Set<String>()
            let rows = try persistedRows.enumerated().map { offset, persisted in
                guard seenTokens.insert(persisted.rowToken).inserted else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .parameterList,
                        in: container,
                        debugDescription: "A schema-v2 parameter list contains duplicate row tokens."
                    )
                }
                return try persisted.modelRow(index: offset)
            }
            parameterList = .authoritative(rows)
        } else {
            parameterList = .unspecified
        }
    }

    private mutating func initLegacy(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        guard !container.contains(.parameterList),
              !container.contains(.quarantinedLegacyArgs),
              !container.contains(.variadicState)
        else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: container.codingPath,
                    debugDescription: "Schema-v2 function-signature fields require schemaVersion 2."
                )
            )
        }

        returnType = try container.decodeIfPresent(String.self, forKey: .returnType)
        variadicState = .unspecified
        quarantinedLegacyArgs = []

        guard container.contains(.args) else {
            parameterList = .unspecified
            return
        }

        let legacyRows = try container.decode([LegacyParameterRow].self, forKey: .args)
        guard !legacyRows.isEmpty else {
            // The old encoder always wrote `args: []`, even for a return-only or
            // no-return-only change. Treating it as explicit void would preserve the
            // historical parameter-erasure bug, so absence of rows remains unspecified.
            parameterList = .unspecified
            return
        }

        if Self.canMigrateLegacyRows(legacyRows) {
            let rows = legacyRows
                .enumerated()
                .map { offset, legacy in
                    ArgOverride(
                        rowToken: Self.derivedRowToken(
                            domain: "legacy-migration-v1",
                            prefix: "legacy",
                            components: [String(offset), legacy.name, legacy.type]
                        ),
                        index: offset,
                        name: legacy.name,
                        type: legacy.type,
                        provenance: .legacy
                    )
                }
            parameterList = .authoritative(rows)
        } else {
            parameterList = .unspecified
            quarantinedLegacyArgs = legacyRows.enumerated().map { order, legacy in
                LegacyArgOverride(
                    originalIndex: legacy.index,
                    originalOrder: order,
                    name: legacy.name,
                    type: legacy.type
                )
            }
        }
    }

    private static func normalized(_ state: ParameterListState) -> ParameterListState {
        guard case let .authoritative(rows) = state else { return .unspecified }
        // Reserve every explicit token before deriving replacements. This keeps a
        // repaired empty/duplicate row from taking a token that a later valid row
        // already owns, while the first occurrence of a duplicate remains stable.
        let reservedTokens = Set(rows.map(\.rowToken).filter { !$0.isEmpty })
        var seenTokens = Set<String>()
        return .authoritative(rows.enumerated().map { offset, row in
            var token = row.rowToken
            if token.isEmpty || seenTokens.contains(token) {
                var attempt = 0
                repeat {
                    token = derivedRowToken(
                        domain: "active-token-normalization-v1",
                        prefix: "normalized",
                        components: [
                            String(offset),
                            row.rowToken,
                            row.name,
                            row.type,
                            row.provenance.rawValue,
                            String(attempt),
                        ]
                    )
                    attempt += 1
                } while seenTokens.contains(token) || reservedTokens.contains(token)
            }
            _ = seenTokens.insert(token)
            return ArgOverride(
                rowToken: token,
                index: offset,
                name: row.name,
                type: row.type,
                provenance: row.provenance
            )
        })
    }

    private static func canonicalizedQuarantine(
        _ rows: [LegacyArgOverride]
    ) -> [LegacyArgOverride] {
        rows.enumerated().map { offset, row in
            LegacyArgOverride(
                originalIndex: row.originalIndex,
                originalOrder: offset,
                name: row.name,
                type: row.type
            )
        }
    }

    private static func isCanonicalQuarantine(_ rows: [LegacyArgOverride]) -> Bool {
        rows.enumerated().allSatisfy { offset, row in row.originalOrder == offset }
    }

    /// Produces a deterministic opaque token from length-prefixed evidence. The
    /// domain is part of the digest input and the output prefix, so a migrated
    /// legacy identity can never be confused with a programmatic repair identity.
    private static func derivedRowToken(
        domain: String,
        prefix: String,
        components: [String]
    ) -> String {
        var evidence = "\(domain.utf8.count):\(domain)"
        for component in components {
            evidence += "|\(component.utf8.count):\(component)"
        }
        let digest = SHA256.hash(data: Data(evidence.utf8))
        let suffix = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\(prefix)-\(suffix)"
    }

    private static func isAuthoritative(_ state: ParameterListState) -> Bool {
        if case .authoritative = state { return true }
        return false
    }

    private static func canMigrateLegacyRows(_ rows: [LegacyParameterRow]) -> Bool {
        guard rows.enumerated().allSatisfy({ offset, row in row.index == offset })
        else { return false }

        return rows.allSatisfy { isLegacyIntegerOrPointerType($0.type) }
    }

    private static func isLegacyIntegerOrPointerType(_ type: String) -> Bool {
        // Legacy migration and authoritative binding must share exactly one type
        // decision. Only a value the strict binder proves occupies the GPR scalar
        // channel can migrate automatically; everything else remains quarantined.
        DarwinARM64ParameterBinder.isSupportedLegacyGPRScalar(type)
    }
}

/// A user-authored jump-table (switch) declaration, keyed by the dispatching `br`
/// address. It exists for the case the auto-`JumpTableResolver` could not recover
/// (an ambiguous dispatch idiom, or a table the heuristic refused). The user
/// declares the table location and shape; the targets are resolved by reading the
/// table bytes, mirroring `JumpTableResolver.readTargets`, and merged over the
/// auto-recovered map so the pseudocode `switch` reconstruction picks it up.
public struct SwitchHintOverride: Codable, Equatable, Sendable {
    /// Virtual address of the first table entry.
    public var tableBase: UInt64
    /// Number of cases (table entries); case value `i` maps to entry `i`.
    public var entryCount: Int
    /// Bytes per entry (the index multiplier), e.g. 4 or 8.
    public var entryStride: Int
    /// Relativity: when true each entry is a signed offset added to `tableBase`
    /// (the classic `ldrsw`+add-back form); when false each entry is an absolute
    /// target address (the 8-byte absolute form).
    public var isRelativeToBase: Bool

    public init(tableBase: UInt64, entryCount: Int, entryStride: Int = 4, isRelativeToBase: Bool = true) {
        self.tableBase = tableBase
        self.entryCount = entryCount
        self.entryStride = entryStride
        self.isRelativeToBase = isRelativeToBase
    }

    /// Upper bound on declared cases. A real jump table is far smaller; the cap
    /// keeps a fat-fingered/pasted huge count from over-reserving on resolution
    /// (and is the single source of truth the editor validates against).
    public static let maxEntryCount = 65_536

    /// True when the hint declares no cases (so it can be pruned like any other
    /// cleared override).
    public var isEmpty: Bool { entryCount <= 0 }

    /// Resolves the declared table to its ordered case targets by reading
    /// `entryCount` little-endian entries of `entryStride` bytes at
    /// `tableBase + i*entryStride`. Returns nil when the declaration is degenerate
    /// or any entry's bytes are unavailable (so a partially-readable table never
    /// yields a truncated switch). Unlike the conservative auto-resolver this trusts
    /// the user's declaration: it does not enforce target alignment or a code range.
    public func resolveTargets(readBytes: (_ virtualAddress: UInt64, _ count: Int) -> Data?) -> [UInt64]? {
        // The entryCount cap guards reserveCapacity below: a degenerate count
        // (from a hand-edited .mscope or an older build) resolves to nil rather
        // than attempting an absurd allocation.
        guard entryCount > 0, entryCount <= Self.maxEntryCount, entryStride > 0, entryStride <= 8 else { return nil }
        var targets: [UInt64] = []
        targets.reserveCapacity(entryCount)
        for index in 0..<entryCount {
            let entryAddress = tableBase &+ UInt64(index) &* UInt64(entryStride)
            guard let data = readBytes(entryAddress, entryStride), data.count == entryStride else { return nil }
            let bytes = [UInt8](data)
            var raw: UInt64 = 0
            for byteIndex in 0..<entryStride {
                raw |= UInt64(bytes[byteIndex]) << (8 * byteIndex) // little-endian
            }
            if isRelativeToBase {
                // Sign-extend the raw value from `entryStride` bytes, then add to base.
                let bitWidth = entryStride * 8
                let signed: Int64
                if bitWidth < 64, (raw & (UInt64(1) << (bitWidth - 1))) != 0 {
                    signed = Int64(bitPattern: raw | (~UInt64(0) << bitWidth))
                } else {
                    signed = Int64(bitPattern: raw)
                }
                targets.append(UInt64(bitPattern: Int64(bitPattern: tableBase) &+ signed))
            } else {
                targets.append(raw)
            }
        }
        return targets
    }
}

/// A user-authored DATA SHAPE applied at an address — the "Make Array",
/// "Make Alignment" and "Make String" authoring types. A shaped address is data
/// (excluded from code analysis, exactly like `isData`) AND carries the directive
/// the listing renders for the span: an array directive, an `.align`/`.balign`
/// padding directive, or a string literal.
///
/// Persisted as one JSON column (`data_shape_json`) on `address_overrides`, mirroring
/// `switchHint`'s single-column shape, so a new authoring kind never needs a new
/// SQLite column.
public struct DataShapeOverride: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case array
        case alignment
        case string
    }

    public var kind: Kind

    // --- Array (`.kind == .array`) ---
    /// The element base type name (e.g. "int32_t"), resolved for its byte width via
    /// `TypeDefinition.size(ofType:)`. nil/unknown widths degrade to a 1-byte element.
    public var elementType: String?
    /// The number of elements in the array. Clamped to `[1, maxElementCount]`.
    public var elementCount: Int
    /// The per-element display radix/format for an `.array` shape. nil renders the
    /// bare type signature only (`int32_t[16]`, the legacy behavior); a set value
    /// also materializes each element's value in that format (hex/dec/char/…), reusing
    /// the shared `OperandFormat` formatter. Persisted inside the existing
    /// `data_shape_json` column — no schema change.
    public var elementDisplayFormat: OperandFormat?

    // --- Alignment (`.kind == .alignment`) ---
    /// The alignment boundary in bytes (power of two: 2/4/8/16/32…). Clamped to
    /// `[1, maxAlignment]`.
    public var alignment: Int

    // --- String (`.kind == .string`) ---
    /// When true the span is a NUL-terminated C string; when false it is a fixed
    /// `stringLength`-byte buffer. Renders as `.asciz` vs `.ascii`.
    public var isNullTerminated: Bool
    /// For a fixed-length string, the byte length. Clamped to `[0, maxStringLength]`.
    /// Ignored when `isNullTerminated` is true.
    public var stringLength: Int

    /// Upper bound on array elements. A real array is far smaller; the cap keeps a
    /// fat-fingered/pasted huge count from over-reserving when the span is computed.
    public static let maxElementCount = 1_048_576
    /// Upper bound on a fixed string length (1 MiB), same rationale.
    public static let maxStringLength = 1_048_576
    /// Upper bound on an alignment boundary (64 KiB), well past any real `.align`.
    public static let maxAlignment = 65_536

    public init(
        kind: Kind,
        elementType: String? = nil,
        elementCount: Int = 1,
        alignment: Int = 4,
        isNullTerminated: Bool = true,
        stringLength: Int = 0,
        elementDisplayFormat: OperandFormat? = nil
    ) {
        self.kind = kind
        self.elementType = elementType
        self.elementCount = elementCount
        self.alignment = alignment
        self.isNullTerminated = isNullTerminated
        self.stringLength = stringLength
        self.elementDisplayFormat = elementDisplayFormat
    }

    private enum CodingKeys: String, CodingKey {
        case kind, elementType, elementCount, alignment, isNullTerminated, stringLength, elementDisplayFormat
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // An unknown kind (a newer build's authoring type) degrades to `.array` rather
        // than throwing and failing the whole package load, matching colorTag/operandFormat.
        let rawKind = try container.decodeIfPresent(String.self, forKey: .kind)
        kind = rawKind.flatMap(Kind.init(rawValue:)) ?? .array
        elementType = try container.decodeIfPresent(String.self, forKey: .elementType)
        elementCount = try container.decodeIfPresent(Int.self, forKey: .elementCount) ?? 1
        alignment = try container.decodeIfPresent(Int.self, forKey: .alignment) ?? 4
        isNullTerminated = try container.decodeIfPresent(Bool.self, forKey: .isNullTerminated) ?? true
        stringLength = try container.decodeIfPresent(Int.self, forKey: .stringLength) ?? 0
        // An unknown format string (an older/newer build) degrades to nil — the array
        // simply renders its type signature without per-element values, never throwing.
        let rawFormat = try container.decodeIfPresent(String.self, forKey: .elementDisplayFormat)
        elementDisplayFormat = rawFormat.flatMap(OperandFormat.init(rawValue:))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .kind)
        try container.encodeIfPresent(elementType, forKey: .elementType)
        // Emit only the fields the active kind needs, so the JSON stays minimal and
        // round-trips deterministically.
        switch kind {
        case .array:
            try container.encode(elementCount, forKey: .elementCount)
            try container.encodeIfPresent(elementDisplayFormat?.rawValue, forKey: .elementDisplayFormat)
        case .alignment:
            try container.encode(alignment, forKey: .alignment)
        case .string:
            try container.encode(isNullTerminated, forKey: .isNullTerminated)
            if !isNullTerminated {
                try container.encode(stringLength, forKey: .stringLength)
            }
        }
    }

    /// True when the shape is degenerate (an array of <=0 elements, etc.) so it can be
    /// pruned like any other cleared override.
    public var isEmpty: Bool {
        switch kind {
        case .array: return elementCount <= 0
        case .alignment: return alignment <= 1
        case .string: return !isNullTerminated && stringLength <= 0
        }
    }

    /// The byte width of one array element (the resolved base type's size, or 1 for an
    /// unknown/missing type). Always >= 1 so the span computation never collapses.
    public var elementWidth: Int {
        guard kind == .array else { return 1 }
        return max(1, TypeDefinition.size(ofType: elementType ?? "") ?? 1)
    }

    /// The number of bytes this shape spans from its start address. Used to exclude the
    /// whole span from code analysis (like mark-as-data over the entire range), with the
    /// same overflow-safe clamping the other untrusted-count consumers use.
    ///
    /// - Array: `elementWidth * clamped(elementCount)`.
    /// - Alignment: padding from `address` up to the next multiple of `alignment`
    ///   (0 when already aligned). Computed by the caller via `paddingSpan(from:)`.
    /// - String (fixed): `clamped(stringLength)`.
    /// - String (NUL-terminated): not statically known here — resolved from the bytes by
    ///   the listing builder; this returns 0 as a conservative lower bound.
    public func staticByteSpan() -> Int {
        switch kind {
        case .array:
            let count = min(max(elementCount, 0), Self.maxElementCount)
            // elementWidth <= 8 and count <= 1<<20, so the product cannot overflow Int.
            return elementWidth &* count
        case .alignment:
            return 0 // depends on the address; see paddingSpan(from:)
        case .string:
            if isNullTerminated { return 0 }
            return min(max(stringLength, 0), Self.maxStringLength)
        }
    }

    /// For an alignment shape, the number of padding bytes from `address` up to the next
    /// `alignment` boundary (0 when already aligned). Overflow-safe: a degenerate or
    /// non-positive alignment yields 0.
    public func paddingSpan(from address: UInt64) -> Int {
        guard kind == .alignment else { return 0 }
        let boundary = min(max(alignment, 1), Self.maxAlignment)
        guard boundary > 1 else { return 0 }
        let remainder = Int(address % UInt64(boundary))
        return remainder == 0 ? 0 : boundary - remainder
    }
}

/// A user PATCH of the bytes at an address — replacement machine-code bytes that
/// overwrite the original encoding (a hand-entered hex sequence or a NOP patch). The
/// listing/analysis RE-DECODE from these bytes (so the patched instruction renders from
/// the new encoding); clearing the patch restores the original. Persisted as one JSON
/// column (`patch_json`) on `address_overrides`, mirroring `switchHint`/`dataShape`'s
/// single-column shape so the new authoring kind needs no new SQLite column.
public struct BytePatch: Codable, Equatable, Sendable {
    /// The replacement bytes, in order, as they sit in memory. An empty array is a no-op
    /// (pruned like any cleared override).
    public var bytes: [UInt8]

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Upper bound on a single patch's byte count. A real instruction patch is a handful
    /// of bytes; the cap keeps a pasted huge blob from over-reserving on decode/render.
    public static let maxByteCount = 4096

    /// True when the patch carries no bytes, so it prunes like any other cleared override.
    public var isEmpty: Bool { bytes.isEmpty }

    /// The space-separated lowercase hex text of the patched bytes (e.g. "1f 20 03 d5"),
    /// the same `InstructionRow.bytes` format the decoder and the listing consume.
    public var byteText: String {
        HexByteFormatter.spacedHex(bytes)
    }

    /// The canonical ARM64 NOP patch (`1f 20 03 d5`, little-endian `0xd503201f`). The
    /// most common patch operation — neutralize an instruction in place.
    public static let arm64NOP = BytePatch(bytes: [0x1f, 0x20, 0x03, 0xd5])

    /// The canonical x86-64 NOP patch (single byte `0x90`). The x86 counterpart to
    /// `arm64NOP`, selected for x86_64 targets so "Replace with NOP" neutralizes an x86
    /// instruction with a real NOP rather than mis-applying the 4-byte ARM64 encoding.
    public static let x86NOP = BytePatch(bytes: [0x90])

    /// Parses a user-entered hex string into a patch, or nil when the input is invalid.
    /// Accepts whitespace- and comma-separated bytes ("1f 20 03 d5", "1f,20,03,d5") and a
    /// bare even-length run ("1f2003d5"); rejects odd-length runs, non-hex characters, an
    /// empty string, and anything over `maxByteCount` bytes. Validating here keeps a
    /// fat-fingered input from silently becoming a garbage patch.
    public static func parse(hex input: String) -> BytePatch? {
        let separated = input.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," || $0 == "\n" })
        var bytes: [UInt8] = []
        if separated.count > 1 || (separated.count == 1 && separated[0].count <= 2) {
            // Token-separated form: each token is one byte (1–2 hex digits).
            for token in separated {
                guard token.count <= 2, let value = UInt8(token, radix: 16) else { return nil }
                bytes.append(value)
            }
        } else {
            // Bare run form: an even-length string of hex digits, two per byte.
            let run = separated.first.map(String.init) ?? input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !run.isEmpty, run.count % 2 == 0 else { return nil }
            var index = run.startIndex
            while index < run.endIndex {
                let next = run.index(index, offsetBy: 2)
                guard let value = UInt8(run[index..<next], radix: 16) else { return nil }
                bytes.append(value)
                index = next
            }
        }
        guard !bytes.isEmpty, bytes.count <= maxByteCount else { return nil }
        return BytePatch(bytes: bytes)
    }
}

/// One authored branch into a new executable cave. The bytes are authoring input, not bytes
/// attributed to the captured image. Export and native projection must independently admit the
/// signed thin Mach-O and bind the computed cave address before using this record.
struct AppendedExecutableCaveAuthoring: Codable, Equatable, Sendable {
    let ownerBinaryID: UUID
    let functionID: UUID
    let selectedSliceSHA256: String
    let branchSourceAddress: UInt64
    let codeBytes: Data

    var isWellFormed: Bool {
        selectedSliceSHA256.count == 64
            && selectedSliceSHA256.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
            && branchSourceAddress.isMultiple(of: 4)
            && !codeBytes.isEmpty
            && codeBytes.count <= 1_048_576
            && codeBytes.count.isMultiple(of: 4)
    }
}

/// DP04 C1: a user-authored name and/or type for one stack local of a procedure, stored
/// under `MacIRStackStorage.authoringKey` (the local's entry-SP byte range).
public struct StackLocalOverride: Codable, Equatable, Hashable, Sendable {
    public var name: String?
    public var typeName: String?

    public init(name: String? = nil, typeName: String? = nil) {
        self.name = name
        self.typeName = typeName
    }

    public var isEmpty: Bool { (name?.isEmpty ?? true) && (typeName?.isEmpty ?? true) }

    /// Blank fields read as unset.
    public var normalized: StackLocalOverride {
        StackLocalOverride(name: name.flatMap { $0.isEmpty ? nil : $0 },
                           typeName: typeName.flatMap { $0.isEmpty ? nil : $0 })
    }
}

struct AddressOverride: Codable, Equatable {
    var customName: String?
    var customComment: String?
    /// Free-text user tag/category for the address (e.g. "parser", "TODO").
    var tag: String?
    /// Highlight color applied to the address.
    var colorTag: ColorTag?
    /// When true, the user marked this address as DATA — the listing renders the
    /// bytes as a data directive instead of a decoded instruction. `false` is the
    /// default (code), so "Mark as Code" clears it.
    var isData: Bool
    /// User-authored signature for the function starting at this address.
    var signature: FunctionSignatureOverride?
    /// The name of a workspace type applied at this address (resolved against the
    /// type catalog; a missing name degrades to no-type).
    var appliedTypeName: String?
    /// User-authored jump-table (switch) declaration for the dispatching `br` at
    /// this address. Merged over the auto-recovered jump tables.
    var switchHint: SwitchHintOverride?
    /// User-chosen display format for this instruction's immediate operand.
    var operandFormat: OperandFormat?
    /// When true, the user forced a FUNCTION START at this address — the manual lever
    /// that corrects function discovery (e.g. splitting a tail-called function the
    /// conservative recovery left merged). Fed into `makeFunctionSummaries`'s start set.
    var markAsProcedure: Bool
    /// A user-authored DATA SHAPE at this address (Make Array / Make Alignment / Make
    /// String). A shaped address is treated as data over its whole span and rendered as
    /// the chosen assembler directive. Merged over `isData` (a shape implies data).
    var dataShape: DataShapeOverride?
    /// When true the user marked this address UNDEFINED — the inverse of Mark-as-Procedure:
    /// the span is removed from function/code analysis and rendered as a raw `.byte`
    /// undefined directive. Re-drives analysis like `isData` (the address is excluded from
    /// every code pass) but the listing renders the distinct "undefined" directive rather
    /// than a plain data word. `false` is the default; Mark-as-Code clears it.
    var isUndefined: Bool
    /// A user PATCH at this address: replacement bytes that overwrite the original encoding
    /// (a hand-entered hex sequence or a NOP patch). nil = unpatched (the original bytes).
    /// The listing/analysis RE-DECODE from these bytes, so the patched instruction renders
    /// from the new encoding. Clearing the patch restores the original. Stored as raw bytes;
    /// `BytePatch.isEmpty` (no bytes) prunes like any other cleared override.
    var patch: BytePatch?
    /// Function-entry anchored recipe for one appended executable cave. The branch instruction
    /// is generated only after the output mapping is known; it is not a patch of captured bytes.
    var appendedExecutableCave: AppendedExecutableCaveAuthoring?
    /// User-authored REGISTER RENAMES for the procedure whose START is this address: a map
    /// from a register identifier (e.g. "x19") to the display name the user wants the
    /// pseudocode to show for it (e.g. "count"). KEYED AT THE PROCEDURE START (the natural
    /// per-procedure scope) — the same address-keyed seam the signature override uses, so it
    /// never collides with a register rename in another procedure. Threaded into
    /// `PseudocodePrinter` so the renamed name replaces the raw register at every occurrence.
    /// nil/empty when the user has set no renames (output stays byte-identical).
    var registerNames: [String: String]?
    /// DP04 C1: user-authored STACK LOCAL names/types for the procedure whose START is this
    /// address, keyed by `MacIRStackStorage.authoringKey` (entry-SP byte range). Same
    /// procedure-start seam as `registerNames`. An entry whose key matches no recovered local
    /// is kept (an orphan) and never retargeted. nil/empty when unset.
    var stackLocals: [String: StackLocalOverride]?
    /// A user-authored LOCAL LABEL at this address — a name scoped to the enclosing procedure,
    /// rendered in the listing/pseudocode within that procedure (a per-procedure local
    /// label). Distinct from `customName`, which is a GLOBAL symbol rename: a local label is a
    /// procedure-private branch/data tag (e.g. "loc_retry") that does not enter the symbol
    /// table. nil/empty when unset.
    var localLabel: String?

    init(
        customName: String? = nil,
        customComment: String? = nil,
        tag: String? = nil,
        colorTag: ColorTag? = nil,
        isData: Bool = false,
        signature: FunctionSignatureOverride? = nil,
        appliedTypeName: String? = nil,
        switchHint: SwitchHintOverride? = nil,
        operandFormat: OperandFormat? = nil,
        markAsProcedure: Bool = false,
        dataShape: DataShapeOverride? = nil,
        isUndefined: Bool = false,
        patch: BytePatch? = nil,
        appendedExecutableCave: AppendedExecutableCaveAuthoring? = nil,
        registerNames: [String: String]? = nil,
        stackLocals: [String: StackLocalOverride]? = nil,
        localLabel: String? = nil
    ) {
        self.customName = customName
        self.customComment = customComment
        self.tag = tag
        self.colorTag = colorTag
        self.isData = isData
        self.signature = signature
        self.appliedTypeName = appliedTypeName
        self.switchHint = switchHint
        self.operandFormat = operandFormat
        self.markAsProcedure = markAsProcedure
        self.dataShape = dataShape
        self.isUndefined = isUndefined
        self.patch = patch
        self.appendedExecutableCave = appendedExecutableCave
        self.registerNames = registerNames
        self.stackLocals = stackLocals
        self.localLabel = localLabel
    }

    private enum CodingKeys: String, CodingKey {
        case customName, customComment, tag, colorTag, isData, signature, appliedTypeName, switchHint, operandFormat, markAsProcedure, dataShape, isUndefined, patch, appendedExecutableCave, registerNames, stackLocals, localLabel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        customName = try container.decodeIfPresent(String.self, forKey: .customName)
        customComment = try container.decodeIfPresent(String.self, forKey: .customComment)
        tag = try container.decodeIfPresent(String.self, forKey: .tag)
        // Decode the color leniently: an unknown raw value (e.g. a palette entry
        // a newer build added) degrades to nil instead of throwing and failing the
        // whole package load — matching the SQLite load path's ColorTag(rawValue:).
        let rawColor = try container.decodeIfPresent(String.self, forKey: .colorTag)
        colorTag = rawColor.flatMap(ColorTag.init(rawValue:))
        isData = try container.decodeIfPresent(Bool.self, forKey: .isData) ?? false
        // A signature is an independently versioned nested payload. An unknown
        // schema or malformed row drops only that signature; the sibling rename,
        // comment, tag, and other address-authored state remain recoverable.
        if container.contains(.signature) {
            signature = try? container.decode(FunctionSignatureOverride.self, forKey: .signature)
        } else {
            signature = nil
        }
        appliedTypeName = try container.decodeIfPresent(String.self, forKey: .appliedTypeName)
        switchHint = try container.decodeIfPresent(SwitchHintOverride.self, forKey: .switchHint)
        // Decode the operand format leniently (an unknown raw value degrades to nil),
        // matching colorTag's forward-compatible handling.
        let rawFormat = try container.decodeIfPresent(String.self, forKey: .operandFormat)
        operandFormat = rawFormat.flatMap(OperandFormat.init(rawValue:))
        markAsProcedure = try container.decodeIfPresent(Bool.self, forKey: .markAsProcedure) ?? false
        dataShape = try container.decodeIfPresent(DataShapeOverride.self, forKey: .dataShape)
        isUndefined = try container.decodeIfPresent(Bool.self, forKey: .isUndefined) ?? false
        patch = try container.decodeIfPresent(BytePatch.self, forKey: .patch)
        appendedExecutableCave = try container.decodeIfPresent(AppendedExecutableCaveAuthoring.self, forKey: .appendedExecutableCave)
        // Prune empty register-name entries on decode so a hand-edited / legacy package
        // carrying a blank mapping degrades to "no rename" rather than rendering an empty name.
        let rawRegisterNames = try container.decodeIfPresent([String: String].self, forKey: .registerNames)
        registerNames = rawRegisterNames.map { Self.prunedRegisterNames($0) }.flatMap { $0.isEmpty ? nil : $0 }
        stackLocals = try container.decodeIfPresent([String: StackLocalOverride].self, forKey: .stackLocals)
            .map(Self.prunedStackLocals).flatMap { $0.isEmpty ? nil : $0 }
        localLabel = try container.decodeIfPresent(String.self, forKey: .localLabel)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(customName, forKey: .customName)
        try container.encodeIfPresent(customComment, forKey: .customComment)
        try container.encodeIfPresent(tag, forKey: .tag)
        try container.encodeIfPresent(colorTag?.rawValue, forKey: .colorTag)
        // Only emit the flag when set, so a default (code) override stays minimal.
        if isData {
            try container.encode(true, forKey: .isData)
        }
        try container.encodeIfPresent(signature, forKey: .signature)
        try container.encodeIfPresent(appliedTypeName, forKey: .appliedTypeName)
        try container.encodeIfPresent(switchHint, forKey: .switchHint)
        try container.encodeIfPresent(operandFormat?.rawValue, forKey: .operandFormat)
        if markAsProcedure {
            try container.encode(true, forKey: .markAsProcedure)
        }
        // Only emit a non-empty shape, so a cleared shape stays minimal (mirrors isData).
        if let dataShape, !dataShape.isEmpty {
            try container.encode(dataShape, forKey: .dataShape)
        }
        // Emit only when set, so a default override stays minimal (mirrors isData).
        if isUndefined {
            try container.encode(true, forKey: .isUndefined)
        }
        if let patch, !patch.isEmpty {
            try container.encode(patch, forKey: .patch)
        }
        try container.encodeIfPresent(appendedExecutableCave, forKey: .appendedExecutableCave)
        // Emit only the non-empty register-name mapping, so a cleared rename stays minimal
        // and the persisted JSON is deterministic (mirrors the other optional fields).
        if let registerNames {
            let pruned = Self.prunedRegisterNames(registerNames)
            if !pruned.isEmpty { try container.encode(pruned, forKey: .registerNames) }
        }
        if let stackLocals {
            let pruned = Self.prunedStackLocals(stackLocals)
            if !pruned.isEmpty { try container.encode(pruned, forKey: .stackLocals) }
        }
        if let localLabel, !localLabel.isEmpty {
            try container.encode(localLabel, forKey: .localLabel)
        }
    }

    /// Drops blank keys/values from a register-name mapping. A blank name means "no rename",
    /// so it should never persist (and never render as an empty token in the pseudocode).
    static func prunedRegisterNames(_ map: [String: String]) -> [String: String] {
        map.filter { !$0.key.isEmpty && !$0.value.isEmpty }
    }

    /// True when the override carries nothing — used to prune empty entries so a
    /// cleared rename/comment/tag/color/data-mark/signature/applied-type/switch-hint
    /// does not linger as a no-op record.
    var isEmpty: Bool {
        (customName?.isEmpty ?? true)
            && (customComment?.isEmpty ?? true)
            && (tag?.isEmpty ?? true)
            && colorTag == nil
            && !isData
            && (signature?.isEmpty ?? true)
            && (appliedTypeName?.isEmpty ?? true)
            && (switchHint?.isEmpty ?? true)
            && operandFormat == nil
            && !markAsProcedure
            && (dataShape?.isEmpty ?? true)
            && !isUndefined
            && (patch?.isEmpty ?? true)
            && appendedExecutableCave == nil
            && (registerNames.map { Self.prunedRegisterNames($0).isEmpty } ?? true)
            && (stackLocals.map { Self.prunedStackLocals($0).isEmpty } ?? true)
            && (localLabel?.isEmpty ?? true)
    }
}

/// Wire representation of one address → override pair. The in-memory store uses an
/// `[ImageAddress: AddressOverride]` dictionary; this flat, sorted entry form gives
/// the persisted package deterministic, human-diffable JSON. `imageSlot` is OMITTED
/// when 0 (the primary/legacy slot) so single-image packages stay byte-identical to
/// the pre-image-aware format, and absent slots decode to 0 — legacy packages load
/// with all authoring bound to the primary image, exactly their original meaning.
struct AddressOverrideEntry: Codable, Equatable {
    var address: UInt64
    var imageSlot: ImageSlot = .primary
    var override: AddressOverride

    private enum CodingKeys: String, CodingKey {
        case address, imageSlot, override
    }

    init(address: UInt64, imageSlot: ImageSlot = .primary, override: AddressOverride) {
        self.address = address
        self.imageSlot = imageSlot
        self.override = override
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        address = try container.decode(UInt64.self, forKey: .address)
        imageSlot = try container.decodeIfPresent(ImageSlot.self, forKey: .imageSlot) ?? .primary
        override = try container.decode(AddressOverride.self, forKey: .override)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(address, forKey: .address)
        if imageSlot != .primary {
            try container.encode(imageSlot, forKey: .imageSlot)
        }
        try container.encode(override, forKey: .override)
    }
}

extension AddressOverride {
    /// Drops blank edits and keys that do not name a valid entry-SP range. A well-formed key
    /// with no matching local is kept: orphans stay visible, never silently dropped.
    static func prunedStackLocals(_ locals: [String: StackLocalOverride]) -> [String: StackLocalOverride] {
        locals.reduce(into: [:]) { result, entry in
            let value = entry.value.normalized
            guard !value.isEmpty, MacIRStackStorage.entryRange(forAuthoringKey: entry.key) != nil else { return }
            result[entry.key] = value
        }
    }
}
