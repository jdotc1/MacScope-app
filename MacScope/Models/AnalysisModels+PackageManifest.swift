import Darwin
import Foundation
import CryptoKit
import SwiftUI

extension CodingUserInfoKey {
    static let workspacePackageDuplicateKeyFindings = CodingUserInfoKey(
        rawValue: "org.macscope.workspacePackageDuplicateKeyFindings"
    )!
}

struct WorkspacePackageDuplicateKeyFindings {
    var anyObjectMember = false
    var logicalBreakpointCatalog = false
    var launchProfileCatalog = false
    var savedWatchCatalog = false
    var sourceLinkState = false
    var analysisAncestor = false

    var logicalBreakpointCatalogUnavailable: Bool {
        logicalBreakpointCatalog || analysisAncestor
    }

    var launchProfileCatalogUnavailable: Bool {
        launchProfileCatalog || analysisAncestor
    }
}

/// JSONDecoder keyed containers discard duplicate object members before Codable sees them. This
/// raw-byte preflight walks the manifest first and detects byte-exact decoded key repeats at
/// every object level, while accepting whitespace, key order, and ordinary JSON string escaping.
/// Catalog-member duplicates invalidate only their owning authority. A duplicate `analysis`
/// ancestor invalidates both catalogs because Foundation may discard either complete authoring
/// value before either catalog decoder is entered.
///
/// Lane AG (round 4): the scan is linear and allocation-light — it reads the buffer in place
/// (no array copy), compares keys as byte ranges (a per-object `Set` only past 24 keys), skips
/// string content a word at a time, and validates UTF-8 once with the stdlib. It is also a
/// strict RFC 8259 grammar check (number grammar, literals, escapes, surrogate pairs, raw
/// control bytes), which replaces the full `JSONSerialization` parse the manifest decoder used
/// to run only to read `formatVersion` and the root key set: JSONDecoder alone tolerates
/// malformed values under keys it ignores, so the strictness is kept here. The same pass
/// records the root object's key facts (`WorkspacePackageManifestRootSummary`).
struct WorkspacePackageDuplicateKeyPreflight {
    private enum AuthorityContext: Equatable { case root, neutral, logicalBreakpointCatalog }

    /// One key of an open object: a byte range of the buffer, or an index into `ownedKeys` for
    /// a key whose JSON spelling contained escapes (compared by its decoded UTF-8 bytes).
    private struct KeyRef { var start: Int; var count: Int; var owned: Int }

    private static let maximumDepth = 128
    private static let malformed = DebuggerLogicalBreakpointValidationError.noncanonicalPayload
    private static let linearKeyLimit = 24
    private static let logicalBreakpointCatalogKey = Array("logicalBreakpointCatalog".utf8)
    private static let launchProfileCatalogKey = Array("launchProfileCatalog".utf8)
    private static let savedWatchCatalogKey = Array("savedWatchCatalog".utf8)
    private static let sourceLinkStateKey = Array("sourceLinkState".utf8)
    private static let analysisKey = Array("analysis".utf8)
    private static let formatVersionKey = Array("formatVersion".utf8)

    private let base: UnsafePointer<UInt8>
    private let end: Int
    private var index = 0
    private var findings = WorkspacePackageDuplicateKeyFindings()
    private var root: WorkspacePackageManifestRootSummary?
    private var keyStack: [KeyRef] = []
    private var ownedKeys: [[UInt8]] = []

    static func findings(in data: Data) throws -> WorkspacePackageDuplicateKeyFindings {
        try scan(data).findings
    }

    static func scan(_ data: Data) throws -> WorkspacePackageJSONPreflightResult {
        // Validate UTF-8 for the whole buffer once (stdlib, vectorized); structural bytes are
        // ASCII, so every string's content is then valid UTF-8 as well.
        do { _ = try UTF8Span(validating: data.span) } catch { throw Self.malformed }
        return try data.withUnsafeBytes { raw -> WorkspacePackageJSONPreflightResult in
            guard let pointer = raw.bindMemory(to: UInt8.self).baseAddress, raw.count > 0 else {
                throw Self.malformed
            }
            var scanner = Self(base: pointer, end: raw.count)
            scanner.keyStack.reserveCapacity(256)
            try scanner.parseValue(depth: 0, context: .root)
            scanner.skipWhitespace()
            guard scanner.index == scanner.end else { throw Self.malformed }
            return WorkspacePackageJSONPreflightResult(findings: scanner.findings, root: scanner.root)
        }
    }

    private init(base: UnsafePointer<UInt8>, end: Int) {
        self.base = base
        self.end = end
    }

    private mutating func parseValue(depth: Int, context: AuthorityContext) throws {
        guard depth <= Self.maximumDepth else {
            throw DebuggerLogicalBreakpointValidationError.payloadTooLarge
        }
        skipWhitespace()
        guard index < end else { throw Self.malformed }
        switch base[index] {
        case 0x7B: try parseObject(depth: depth + 1, context: context)
        case 0x5B: try parseArray(depth: depth + 1, context: context)
        case 0x22:
            index += 1
            _ = try skipStringContent()
        default: try skipPrimitive()
        }
    }

    private mutating func parseObject(depth: Int, context: AuthorityContext) throws {
        index += 1
        skipWhitespace()
        if consume(0x7D) {
            if context == .root, depth == 1 { root = WorkspacePackageManifestRootSummary() }
            return
        }
        let isRoot = context == .root && depth == 1
        if isRoot { root = WorkspacePackageManifestRootSummary() }
        let firstKey = keyStack.count
        let firstOwned = ownedKeys.count
        var largeObjectKeys: Set<Data>?
        defer {
            keyStack.removeSubrange(firstKey...)
            if ownedKeys.count > firstOwned { ownedKeys.removeSubrange(firstOwned...) }
        }
        while true {
            skipWhitespace()
            guard consume(0x22) else { throw Self.malformed }
            let key = try parseKey()
            let duplicate: Bool
            if largeObjectKeys != nil {
                duplicate = !largeObjectKeys!.insert(keyData(key)).inserted
            } else {
                duplicate = containsKey(key, from: firstKey)
                keyStack.append(key)
                if keyStack.count - firstKey > Self.linearKeyLimit {
                    largeObjectKeys = Set(keyStack[firstKey...].map { keyData($0) })
                }
            }
            if duplicate {
                findings.anyObjectMember = true
                if context == .logicalBreakpointCatalog || keyEquals(key, Self.logicalBreakpointCatalogKey) {
                    findings.logicalBreakpointCatalog = true
                } else if keyEquals(key, Self.launchProfileCatalogKey) {
                    findings.launchProfileCatalog = true
                } else if keyEquals(key, Self.savedWatchCatalogKey) {
                    findings.savedWatchCatalog = true
                } else if keyEquals(key, Self.sourceLinkStateKey) {
                    findings.sourceLinkState = true
                } else if context == .root, keyEquals(key, Self.analysisKey) {
                    findings.analysisAncestor = true
                }
            }
            skipWhitespace()
            guard consume(0x3A) else { throw Self.malformed }
            let childContext: AuthorityContext =
                context == .logicalBreakpointCatalog || keyEquals(key, Self.logicalBreakpointCatalogKey)
                ? .logicalBreakpointCatalog : .neutral
            if isRoot {
                try recordRootMember(key, depth: depth, childContext: childContext)
            } else {
                try parseValue(depth: depth, context: childContext)
            }
            skipWhitespace()
            if consume(0x7D) { return }
            guard consume(0x2C) else { throw Self.malformed }
        }
    }

    private mutating func recordRootMember(
        _ key: KeyRef,
        depth: Int,
        childContext: AuthorityContext
    ) throws {
        guard let name = String(data: keyData(key), encoding: .utf8) else {
            throw Self.malformed
        }
        root?.keys.insert(name)
        skipWhitespace()
        let valueStart = index
        try parseValue(depth: depth, context: childContext)
        let token = UnsafeBufferPointer(start: base + valueStart, count: index - valueStart)
        if token.elementsEqual("null".utf8) { root?.nullValuedKeys.insert(name) }
        if keyEquals(key, Self.formatVersionKey) { root?.formatVersionTokens.append(Data(token)) }
    }

    private mutating func parseArray(depth: Int, context: AuthorityContext) throws {
        index += 1
        skipWhitespace()
        if consume(0x5D) { return }
        while true {
            try parseValue(depth: depth, context: context)
            skipWhitespace()
            if consume(0x5D) { return }
            guard consume(0x2C) else { throw Self.malformed }
        }
    }

    // MARK: keys

    private mutating func parseKey() throws -> KeyRef {
        let start = index
        let hadEscape = try skipStringContent()
        guard hadEscape else { return KeyRef(start: start, count: index - 1 - start, owned: -1) }
        let encoded = Data(UnsafeBufferPointer(start: base + start - 1, count: index - start + 1))
        guard let decoded = try? JSONDecoder().decode(String.self, from: encoded) else {
            throw Self.malformed
        }
        ownedKeys.append(Array(decoded.utf8))
        return KeyRef(start: 0, count: 0, owned: ownedKeys.count - 1)
    }

    private func keyBytes(_ key: KeyRef) -> UnsafeBufferPointer<UInt8>? {
        key.owned < 0 ? UnsafeBufferPointer(start: base + key.start, count: key.count) : nil
    }

    private func keyData(_ key: KeyRef) -> Data {
        if let bytes = keyBytes(key) { return Data(bytes) }
        return Data(ownedKeys[key.owned])
    }

    private func keysEqual(_ lhs: KeyRef, _ rhs: KeyRef) -> Bool {
        if lhs.owned < 0, rhs.owned < 0 {
            return lhs.count == rhs.count && memcmp(base + lhs.start, base + rhs.start, lhs.count) == 0
        }
        return keyData(lhs) == keyData(rhs)
    }

    private func keyEquals(_ key: KeyRef, _ literal: [UInt8]) -> Bool {
        if key.owned >= 0 { return ownedKeys[key.owned] == literal }
        guard key.count == literal.count else { return false }
        return literal.withUnsafeBufferPointer { memcmp(base + key.start, $0.baseAddress!, key.count) == 0 }
    }

    private func containsKey(_ key: KeyRef, from first: Int) -> Bool {
        var position = first
        while position < keyStack.count {
            if keysEqual(keyStack[position], key) { return true }
            position += 1
        }
        return false
    }

    // MARK: strings

    /// Scans string content after the opening quote through the closing quote. Rejects raw
    /// control bytes and malformed escapes (including unpaired UTF-16 surrogates) the same way
    /// a strict JSON parser does. Returns whether any escape occurred.
    private mutating func skipStringContent() throws -> Bool {
        var hadEscape = false
        while true {
            // Word-at-a-time skip over bytes that are not '"', '\\' or < 0x20.
            while index + 8 <= end {
                let word = UnsafeRawPointer(base + index).loadUnaligned(as: UInt64.self)
                let quote = word ^ 0x2222_2222_2222_2222
                let slash = word ^ 0x5C5C_5C5C_5C5C_5C5C
                let lows: UInt64 = 0x0101_0101_0101_0101
                let highs: UInt64 = 0x8080_8080_8080_8080
                let special = ((quote &- lows) & ~quote)
                    | ((slash &- lows) & ~slash)
                    | ((word &- 0x2020_2020_2020_2020) & ~word)
                if special & highs != 0 { break }
                index += 8
            }
            guard index < end else { throw Self.malformed }
            let byte = base[index]
            index += 1
            if byte == 0x22 { return hadEscape }
            if byte < 0x20 { throw Self.malformed }
            if byte == 0x5C {
                hadEscape = true
                try skipEscape()
            }
        }
    }

    private mutating func skipEscape() throws {
        guard index < end else { throw Self.malformed }
        let byte = base[index]
        index += 1
        switch byte {
        case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74: return
        case 0x75:
            let unit = try hexQuad()
            if unit >= 0xDC00 && unit <= 0xDFFF { throw Self.malformed }
            if unit >= 0xD800 && unit <= 0xDBFF {
                guard index + 1 < end, base[index] == 0x5C, base[index + 1] == 0x75 else {
                    throw Self.malformed
                }
                index += 2
                let low = try hexQuad()
                guard low >= 0xDC00 && low <= 0xDFFF else { throw Self.malformed }
            }
        default: throw Self.malformed
        }
    }

    private mutating func hexQuad() throws -> UInt32 {
        guard index + 4 <= end else { throw Self.malformed }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = base[index]
            index += 1
            let digit: UInt8
            switch byte {
            case 0x30...0x39: digit = byte - 0x30
            case 0x41...0x46: digit = byte - 0x41 + 10
            case 0x61...0x66: digit = byte - 0x61 + 10
            default: throw Self.malformed
            }
            value = value << 4 | UInt32(digit)
        }
        return value
    }

    // MARK: primitives

    private mutating func skipPrimitive() throws {
        switch base[index] {
        case 0x74: try literal("true")
        case 0x66: try literal("false")
        case 0x6E: try literal("null")
        default: try skipNumber()
        }
    }

    private mutating func literal(_ text: StaticString) throws {
        let count = text.utf8CodeUnitCount
        guard index + count <= end, memcmp(base + index, text.utf8Start, count) == 0 else {
            throw Self.malformed
        }
        index += count
    }

    /// RFC 8259 number grammar: -? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?
    private mutating func skipNumber() throws {
        if index < end, base[index] == 0x2D { index += 1 }
        guard index < end else { throw Self.malformed }
        if base[index] == 0x30 {
            index += 1
        } else {
            guard digitsFollow() else { throw Self.malformed }
        }
        if index < end, base[index] == 0x2E {
            index += 1
            guard digitsFollow() else { throw Self.malformed }
        }
        if index < end, base[index] == 0x65 || base[index] == 0x45 {
            index += 1
            if index < end, base[index] == 0x2B || base[index] == 0x2D { index += 1 }
            guard digitsFollow() else { throw Self.malformed }
        }
    }

    private mutating func digitsFollow() -> Bool {
        let start = index
        while index < end, base[index] >= 0x30, base[index] <= 0x39 { index += 1 }
        return index > start
    }

    private mutating func skipWhitespace() {
        // Pretty-printed manifests indent deeply: skip runs of eight spaces a word at a time.
        while index + 8 <= end,
              UnsafeRawPointer(base + index).loadUnaligned(as: UInt64.self) == 0x2020_2020_2020_2020 {
            index += 8
        }
        while index < end {
            switch base[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < end, base[index] == byte else { return false }
        index += 1
        return true
    }
}

/// Root-object facts gathered by the same pass.
struct WorkspacePackageManifestRootSummary {
    var keys: Set<String> = []
    var nullValuedKeys: Set<String> = []
    var formatVersionTokens: [Data] = []
}

struct WorkspacePackageJSONPreflightResult {
    var findings: WorkspacePackageDuplicateKeyFindings
    var root: WorkspacePackageManifestRootSummary?
}

/// Decode-once memo for manifest bytes within one save, open or observation (lane AG).
///
/// A Save used to decode the same manifest bytes about two dozen times (payload capture,
/// staging, staged read-back, two `validateStage` passes each with a package open and a
/// two-decode probe, the post-publish probe), and a reopen five more times. Manifest validation
/// is a pure function of the bytes, so within one operation the scope returns the earlier
/// result for byte-identical input (`Data ==`, a length check plus `memcmp`). Any byte change
/// misses and validates afresh; failures are never cached; file-system checks (tree snapshots,
/// attachment reads, identities) are untouched. A scope lives only as long as the operation
/// that installs it, and holds at most two entries.
final class WorkspaceManifestDecodeScope: @unchecked Sendable {
    private struct Entry {
        let data: Data
        let manifest: WorkspacePackageManifest
        var canonicalEncoding: Data?
    }

    @TaskLocal static var current: WorkspaceManifestDecodeScope?

    private static let capacity = 2
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var instructionEntry: (
        data: Data, descriptor: WorkspaceInstructionSidecarDescriptor,
        groups: [WorkspaceInstructionSidecarCodec.Group]
    )?

    func instructionGroups(for data: Data, descriptor: WorkspaceInstructionSidecarDescriptor)
        -> [WorkspaceInstructionSidecarCodec.Group]? {
        lock.withLock {
            guard let entry = instructionEntry, entry.descriptor == descriptor, entry.data == data else { return nil }
            return entry.groups
        }
    }

    func recordInstructionGroups(_ groups: [WorkspaceInstructionSidecarCodec.Group], data: Data,
                                 descriptor: WorkspaceInstructionSidecarDescriptor) {
        lock.withLock { instructionEntry = (data, descriptor, groups) }
    }

    /// Runs `body` inside the current scope, or inside a fresh one when none is installed.
    static func ensuring<T>(_ body: (WorkspaceManifestDecodeScope) throws -> T) rethrows -> T {
        if let current { return try body(current) }
        let scope = WorkspaceManifestDecodeScope()
        return try $current.withValue(scope) { try body(scope) }
    }

    func manifest(for data: Data) -> WorkspacePackageManifest? {
        lock.withLock { entries.first { $0.data == data }?.manifest }
    }

    func canonicalEncoding(for data: Data) -> Data? {
        lock.withLock { entries.first { $0.data == data }?.canonicalEncoding }
    }

    func record(
        _ manifest: WorkspacePackageManifest,
        for data: Data,
        canonicalEncoding: Data? = nil
    ) {
        lock.withLock {
            if let index = entries.firstIndex(where: { $0.data == data }) {
                if let canonicalEncoding { entries[index].canonicalEncoding = canonicalEncoding }
                return
            }
            entries.append(Entry(data: data, manifest: manifest, canonicalEncoding: canonicalEncoding))
            if entries.count > Self.capacity { entries.removeFirst() }
        }
    }

    func recordCanonicalEncoding(_ encoding: Data, for data: Data) {
        lock.withLock {
            guard let index = entries.firstIndex(where: { $0.data == data }) else { return }
            entries[index].canonicalEncoding = encoding
        }
    }
}


/// Package manifests deliberately permit ordinary JSON whitespace/key ordering, while the logical
/// breakpoint subtree remains a closed durable schema. Swift's synthesized Codable decoding
/// ignores unknown keys, so validate every keyed level before model decoding; otherwise runtime
/// addresses/backend IDs could be smuggled into a package and silently discarded on re-save.
private enum WorkspacePackageLogicalBreakpointJSONValue: Decodable, Equatable {
    case null
    case bool(Bool)
    case unsigned(UInt64)
    case signed(Int64)
    case string(String)
    case array([Self])
    case object([String: Self])

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() { self = .null }
        else if let value = try? single.decode(Bool.self) { self = .bool(value) }
        else if let value = try? single.decode(UInt64.self) { self = .unsigned(value) }
        else if let value = try? single.decode(Int64.self) { self = .signed(value) }
        else if let value = try? single.decode(String.self) { self = .string(value) }
        else if let value = try? single.decode([Self].self) { self = .array(value) }
        else if let value = try? single.decode([String: Self].self) { self = .object(value) }
        else { throw DebuggerLogicalBreakpointValidationError.noncanonicalPayload }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case (.bool(let lhs), .bool(let rhs)): lhs == rhs
        case (.unsigned(let lhs), .unsigned(let rhs)): lhs == rhs
        case (.signed(let lhs), .signed(let rhs)): lhs == rhs
        case (.string(let lhs), .string(let rhs)): exactUTF8Equal(lhs, rhs)
        case (.array(let lhs), .array(let rhs)):
            lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.0 == $0.1 }
        case (.object(let lhs), .object(let rhs)):
            exactObjectEqual(lhs, rhs)
        default: false
        }
    }

    private static func exactObjectEqual(
        _ lhs: [String: Self],
        _ rhs: [String: Self]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        let left = lhs.sorted { exactUTF8Precedes($0.key, $1.key) }
        let right = rhs.sorted { exactUTF8Precedes($0.key, $1.key) }
        return zip(left, right).allSatisfy { l, r in
            exactUTF8Equal(l.key, r.key) && l.value == r.value
        }
    }

    private static func exactUTF8Equal(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    private static func exactUTF8Precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}

private enum WorkspacePackageLogicalBreakpointStrictValidator {
    private struct Key: CodingKey, Hashable {
        let stringValue: String
        let intValue: Int?

        init(_ value: String) {
            stringValue = value
            intValue = nil
        }

        init?(stringValue: String) { self.init(stringValue) }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    static func validateCatalog(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        try requireOnly(c, ["schemaVersion", "catalogID", "revision", "specifications"])
        try requireCanonicalUUID(c.decode(String.self, forKey: Key("catalogID")))
        var specifications = try c.nestedUnkeyedContainer(forKey: Key("specifications"))
        guard (specifications.count ?? 4_097) <= 4_096 else {
            throw DebuggerLogicalBreakpointValidationError.tooManySpecifications
        }
        var priorID: String?
        while !specifications.isAtEnd {
            let id = try validateSpecification(from: specifications.superDecoder())
            guard priorID.map({ $0 < id }) ?? true else {
                throw DebuggerLogicalBreakpointValidationError.noncanonicalPayload
            }
            priorID = id
        }
    }

    private static func validateSpecification(from decoder: Decoder) throws -> String {
        let c = try decoder.container(keyedBy: Key.self)
        try requireOnly(c, [
            "schemaVersion", "id", "revision", "enabled", "target", "condition",
            "hitPolicy", "actions", "disposition",
        ])
        let id = try c.nestedContainer(keyedBy: Key.self, forKey: Key("id"))
        try requireOnly(id, ["rawValue"])
        let idText = try id.decode(String.self, forKey: Key("rawValue"))
        try requireCanonicalUUID(idText)
        try validateTarget(from: c.superDecoder(forKey: Key("target")))
        try validateHitPolicy(from: c.superDecoder(forKey: Key("hitPolicy")))
        var actions = try c.nestedUnkeyedContainer(forKey: Key("actions"))
        guard (actions.count ?? 17) <= 16 else {
            throw DebuggerLogicalBreakpointValidationError.tooManyActions
        }
        while !actions.isAtEnd {
            try validateAction(from: actions.superDecoder())
        }
        return idText
    }

    private static func validateTarget(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let type = try c.decode(String.self, forKey: Key("type"))
        let allowed: Set<String>
        switch type {
        case "preferredAddress":
            allowed = ["type", "owner", "preferredVA"]
        case "imageOffset":
            allowed = [
                "type", "owner", "segmentName", "expectedSegmentPreferredStart", "offset",
            ]
        case "function":
            allowed = ["type", "owner", "entryPreferredVA", "rawLinkageNameHint"]
        case "symbol":
            allowed = [
                "type", "owner", "exactRawLinkageName", "kind", "libraryName", "cardinality",
            ]
        case "source":
            allowed = ["type", "owner", "file", "line", "columnPolicy", "cardinality"]
        default:
            throw DebuggerLogicalBreakpointValidationError.noncanonicalPayload
        }
        try requireOnly(c, allowed)
        try validateOwner(from: c.superDecoder(forKey: Key("owner")))
        if type == "source" {
            try validateSourceFile(from: c.superDecoder(forKey: Key("file")))
            try validateColumnPolicy(from: c.superDecoder(forKey: Key("columnPolicy")))
        }
    }

    private static func validateOwner(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        try requireOnly(c, ["slot", "binaryID", "artifactIdentity"])
        try requireCanonicalUUID(c.decode(String.self, forKey: Key("binaryID")))
        // `ImageSlot`'s RawRepresentable Codable witness serializes its Int raw value as a JSON
        // number, unlike the UUID-backed logical ID wrapper whose synthesized shape is an object.
        // Requiring `{ "rawValue": ... }` here rejects every valid package before semantic decode.
        _ = try c.decode(Int.self, forKey: Key("slot"))
        if c.contains(Key("artifactIdentity")),
           (try? c.decodeNil(forKey: Key("artifactIdentity"))) == false {
            let artifact = try c.nestedContainer(
                keyedBy: Key.self,
                forKey: Key("artifactIdentity")
            )
            try requireOnly(artifact, [
                "uuid", "rawCPUType", "rawCPUSubtype", "architectureVariant",
                "selectedSliceSHA256", "selectedSliceByteCount",
            ])
            if artifact.contains(Key("uuid")),
               (try? artifact.decodeNil(forKey: Key("uuid"))) == false {
                try requireCanonicalUUID(artifact.decode(String.self, forKey: Key("uuid")))
            }
        }
    }

    private static func validateSourceFile(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        try requireOnly(c, [
            "debugArtifactUUID", "debugArtifactMachOSHA256", "debugArtifactMachOByteCount",
            "lineProgramUnitOffset", "fileTableIndex", "tablePath",
        ])
        try requireCanonicalUUID(c.decode(String.self, forKey: Key("debugArtifactUUID")))
        let path = try c.nestedContainer(keyedBy: Key.self, forKey: Key("tablePath"))
        try requireOnly(path, ["type", "value"])
    }

    private static func validateColumnPolicy(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(String.self, forKey: Key("type")) {
        case "any": try requireOnly(c, ["type"])
        case "exact": try requireOnly(c, ["type", "value"])
        default: throw DebuggerLogicalBreakpointValidationError.noncanonicalPayload
        }
    }

    private static func validateHitPolicy(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(String.self, forKey: Key("type")) {
        case "always": try requireOnly(c, ["type"])
        case "ignoreFirst": try requireOnly(c, ["type", "value"])
        default: throw DebuggerLogicalBreakpointValidationError.noncanonicalPayload
        }
    }

    private static func validateAction(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(String.self, forKey: Key("type")) {
        case "log":
            try requireOnly(c, ["type", "log"])
            let log = try c.nestedContainer(keyedBy: Key.self, forKey: Key("log"))
            try requireOnly(log, ["fragments"])
            var fragments = try log.nestedUnkeyedContainer(forKey: Key("fragments"))
            guard (fragments.count ?? 65) <= 64 else {
                throw DebuggerLogicalBreakpointValidationError.payloadTooLarge
            }
            while !fragments.isAtEnd {
                let fragment = try fragments.nestedContainer(keyedBy: Key.self)
                try requireOnly(fragment, ["type", "value"])
            }
        case "evaluateTargetExpression":
            try requireOnly(c, ["type", "expression"])
            let expression = try c.nestedContainer(keyedBy: Key.self, forKey: Key("expression"))
            try requireOnly(expression, ["label", "expression"])
        default:
            throw DebuggerLogicalBreakpointValidationError.noncanonicalPayload
        }
    }

    private static func requireOnly(
        _ container: KeyedDecodingContainer<Key>,
        _ allowed: Set<String>
    ) throws {
        guard Set(container.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
            throw DebuggerLogicalBreakpointValidationError.noncanonicalPayload
        }
    }

    private static func requireCanonicalUUID(_ value: String) throws {
        guard UUID(uuidString: value)?.uuidString == value else {
            throw DebuggerLogicalBreakpointValidationError.noncanonicalPayload
        }
    }
}

/// A pristine launch catalog is intentionally absent from package JSON. This package-only
/// coordinate makes that compatibility default stable across manifest construction and decode;
/// live workspace/database catalog identities remain independently authored and are not changed.
private enum WorkspacePackageLaunchProfileCompatibility {
    static let pristineCatalog = DebuggerLaunchProfileCatalog.freshPristine(
        catalogID: UUID(uuidString: "57533232-4C50-4000-8000-000000000001")!
    )

    static func normalized(
        _ catalog: DebuggerLaunchProfileCatalog
    ) -> DebuggerLaunchProfileCatalog {
        catalog.isPristine ? pristineCatalog : catalog
    }
}

struct WorkspacePackageAnalysis: Codable, Equatable {
    var functions: [FunctionSummary]
    var symbols: [SymbolSummary]
    var imports: [ImportSummary]
    var indirectSymbols: [IndirectSymbolSummary]
    var exports: [ExportSummary]
    var stringLiterals: [StringLiteralSummary]
    /// Only CF objects need extra persistence; ordinary C strings rebuild from stringLiterals.
    var constantCFStrings: [ImageConstantStringProvider.PersistedCFString]
    var basicBlocks: [BasicBlockSummary]
    var instructions: [InstructionRow]
    var xrefs: [XRef]
    var controlFlowEdges: [ControlFlowEdge]
    /// WS-5: dSYM-imported source lines (not byte-derivable). Decoded with `decodeIfPresent` so
    /// older packages load as empty; a no-dSYM workspace needs no format bump.
    var sourceLines: [SourceLineEntry] = []
    /// Deterministic analysis input/facet provenance. Decoded with `decodeIfPresent` so older
    /// packages and databases load with nil provenance; fresh saves retain Phase 2 freshness
    /// evidence without changing package format version.
    var analysisInputFingerprint: AnalysisInputFingerprint?
    /// User-authored overrides, address-sorted for deterministic JSON. Decoded
    /// with `decodeIfPresent` so older (pre-override) packages load as empty.
    var addressOverrides: [AddressOverrideEntry]
    var importedPrototypes: [ImportedPrototypeEntry]
    /// Workspace-global type catalog. Plain top-level array (not entry-projected);
    /// decoded with `decodeIfPresent` so older packages load as empty.
    var typeDefinitions: [TypeDefinition]
    /// User-authored xref edits (added/suppressed). Decoded with `decodeIfPresent` so
    /// older packages load as empty.
    var manualXRefs: [ManualXRef]
    /// User navigation bookmarks. Decoded with `decodeIfPresent` so older packages load
    /// as empty.
    var bookmarks: [Bookmark]
    /// User segment/section display overrides (rename + rebase). Decoded with
    /// `decodeIfPresent` so older packages load as empty.
    var segmentOverrides: [SegmentOverride]
    /// Workspace-global durable logical-breakpoint authority. A pristine catalog is omitted from
    /// package JSON so legacy packages with no breakpoint authoring remain byte-compatible.
    var logicalBreakpointCatalog: DebuggerLogicalBreakpointCatalog
    var logicalBreakpointCatalogAvailability: DebuggerLogicalBreakpointCatalogAvailability
    /// Exact canonical WS-22 launch-profile catalog bytes are stored as one base64 package blob.
    /// Availability is an in-memory corruption latch and is never serialized as authored truth.
    var launchProfileCatalog: DebuggerLaunchProfileCatalog
    var launchProfileCatalogAvailability: DebuggerLaunchProfileCatalogAvailability
    var savedWatchCatalog: WorkspaceSavedWatchCatalog
    var sourceLinkState: Data

    /// The two ownership layers are explicit in package v2. Validation uses these predicates to
    /// reject payload that `openPackage` would otherwise ignore while rebuilding the snapshot.
    var hasDerivedPayload: Bool {
        !functions.isEmpty
            || !symbols.isEmpty
            || !imports.isEmpty
            || !indirectSymbols.isEmpty
            || !exports.isEmpty
            || !stringLiterals.isEmpty
            || !constantCFStrings.isEmpty
            || !basicBlocks.isEmpty
            || !instructions.isEmpty
            || !xrefs.isEmpty
            || !controlFlowEdges.isEmpty
            || !sourceLines.isEmpty
            || analysisInputFingerprint != nil
    }

    var hasAuthoringPayload: Bool {
        !addressOverrides.isEmpty
            || !importedPrototypes.isEmpty
            || !typeDefinitions.isEmpty
            || !manualXRefs.isEmpty
            || !bookmarks.isEmpty
            || !segmentOverrides.isEmpty
            || !logicalBreakpointCatalog.isPristine
            || logicalBreakpointCatalogAvailability == .unavailable
            || !launchProfileCatalog.isPristine
            || launchProfileCatalogAvailability == .unavailable
            || !savedWatchCatalog.definitions.isEmpty
            || !sourceLinkState.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case functions
        case symbols
        case imports
        case indirectSymbols
        case exports
        case stringLiterals
        case constantCFStrings
        case basicBlocks
        case instructions
        case xrefs
        case controlFlowEdges
        case sourceLines
        case analysisInputFingerprint
        case addressOverrides
        case importedPrototypes
        case typeDefinitions
        case manualXRefs
        case bookmarks
        case segmentOverrides
        case logicalBreakpointCatalog
        case launchProfileCatalog
        case savedWatchCatalog
        case sourceLinkState
    }

    init(
        functions: [FunctionSummary] = [],
        symbols: [SymbolSummary] = [],
        imports: [ImportSummary] = [],
        indirectSymbols: [IndirectSymbolSummary] = [],
        exports: [ExportSummary] = [],
        stringLiterals: [StringLiteralSummary] = [],
        constantCFStrings: [ImageConstantStringProvider.PersistedCFString] = [],
        basicBlocks: [BasicBlockSummary] = [],
        instructions: [InstructionRow] = [],
        xrefs: [XRef] = [],
        controlFlowEdges: [ControlFlowEdge] = [],
        sourceLines: [SourceLineEntry] = [],
        analysisInputFingerprint: AnalysisInputFingerprint? = nil,
        addressOverrides: [AddressOverrideEntry] = [],
        importedPrototypes: [ImportedPrototypeEntry] = [],
        typeDefinitions: [TypeDefinition] = [],
        manualXRefs: [ManualXRef] = [],
        bookmarks: [Bookmark] = [],
        segmentOverrides: [SegmentOverride] = [],
        logicalBreakpointCatalog: DebuggerLogicalBreakpointCatalog = .freshPristine(),
        logicalBreakpointCatalogAvailability: DebuggerLogicalBreakpointCatalogAvailability = .available,
        launchProfileCatalog: DebuggerLaunchProfileCatalog = .freshPristine(),
        launchProfileCatalogAvailability: DebuggerLaunchProfileCatalogAvailability = .available,
        savedWatchCatalog: WorkspaceSavedWatchCatalog = .empty,
        sourceLinkState: Data = Data()
    ) {
        self.functions = functions
        self.symbols = symbols
        self.imports = imports
        self.indirectSymbols = indirectSymbols
        self.exports = exports
        self.stringLiterals = stringLiterals
        self.constantCFStrings = constantCFStrings
        self.basicBlocks = basicBlocks
        self.instructions = instructions
        self.xrefs = xrefs
        self.controlFlowEdges = controlFlowEdges
        self.sourceLines = sourceLines
        self.analysisInputFingerprint = analysisInputFingerprint
        self.addressOverrides = addressOverrides
        self.importedPrototypes = importedPrototypes
        self.typeDefinitions = typeDefinitions
        self.manualXRefs = manualXRefs
        self.bookmarks = bookmarks
        self.segmentOverrides = segmentOverrides
        self.logicalBreakpointCatalog = logicalBreakpointCatalog
        self.logicalBreakpointCatalogAvailability = logicalBreakpointCatalogAvailability
        self.launchProfileCatalog = WorkspacePackageLaunchProfileCompatibility.normalized(
            launchProfileCatalog
        )
        self.launchProfileCatalogAvailability = launchProfileCatalogAvailability
        self.savedWatchCatalog = savedWatchCatalog
        self.sourceLinkState = sourceLinkState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let persistence: (
            catalog: DebuggerLogicalBreakpointCatalog,
            availability: DebuggerLogicalBreakpointCatalogAvailability
        )
        let duplicateKeyFindings = decoder.userInfo[.workspacePackageDuplicateKeyFindings]
            as? WorkspacePackageDuplicateKeyFindings
            ?? WorkspacePackageDuplicateKeyFindings()
        guard !duplicateKeyFindings.savedWatchCatalog else {
            throw WorkspaceSavedWatchValidationError.invalid
        }
        guard !duplicateKeyFindings.sourceLinkState,
              !(duplicateKeyFindings.analysisAncestor && container.contains(.sourceLinkState)) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sourceLinkState, in: container, debugDescription: "Duplicate source evidence owner."
            )
        }
        if duplicateKeyFindings.logicalBreakpointCatalogUnavailable {
            persistence = (.freshPristine(), .unavailable)
        } else if container.contains(.logicalBreakpointCatalog) {
            persistence = {
                do {
                    let packageJSON = try container.decode(
                        WorkspacePackageLogicalBreakpointJSONValue.self,
                        forKey: .logicalBreakpointCatalog
                    )
                    try WorkspacePackageLogicalBreakpointStrictValidator.validateCatalog(
                        from: container.superDecoder(forKey: .logicalBreakpointCatalog)
                    )
                    let decodedCatalog = try container.decode(
                        DebuggerLogicalBreakpointCatalog.self,
                        forKey: .logicalBreakpointCatalog
                    )
                    let canonicalJSON = try JSONDecoder().decode(
                        WorkspacePackageLogicalBreakpointJSONValue.self,
                        from: DebuggerLogicalBreakpointCanonicalCodec.encodeCatalog(decodedCatalog)
                    )
                    guard packageJSON == canonicalJSON else {
                        throw DebuggerLogicalBreakpointValidationError.noncanonicalPayload
                    }
                    return (decodedCatalog, .available)
                } catch {
                    return (.freshPristine(), .unavailable)
                }
            }()
        } else {
            persistence = (.freshPristine(), .available)
        }
        let launchPersistence: (
            catalog: DebuggerLaunchProfileCatalog,
            availability: DebuggerLaunchProfileCatalogAvailability
        )
        if duplicateKeyFindings.launchProfileCatalogUnavailable {
            launchPersistence = (
                WorkspacePackageLaunchProfileCompatibility.pristineCatalog,
                .unavailable
            )
        } else if container.contains(.launchProfileCatalog) {
            launchPersistence = {
                do {
                    let base64 = try container.decode(
                        String.self,
                        forKey: .launchProfileCatalog
                    )
                    let maximumBase64Bytes =
                        ((DebuggerLaunchProfileCanonicalCodec.maximumCatalogBytes + 2) / 3) * 4
                    guard base64.utf8.count <= maximumBase64Bytes,
                          let canonicalBytes = Data(base64Encoded: base64),
                          canonicalBytes.base64EncodedString() == base64 else {
                        throw DebuggerLaunchProfileValidationError.noncanonicalPayload
                    }
                    return (
                        try DebuggerLaunchProfileCanonicalCodec.decodeCatalog(canonicalBytes),
                        .available
                    )
                } catch {
                    return (
                        WorkspacePackageLaunchProfileCompatibility.pristineCatalog,
                        .unavailable
                    )
                }
            }()
        } else {
            launchPersistence = (
                WorkspacePackageLaunchProfileCompatibility.pristineCatalog,
                .available
            )
        }
        self.init(
            functions: try container.decodeIfPresent([FunctionSummary].self, forKey: .functions) ?? [],
            symbols: try container.decodeIfPresent([SymbolSummary].self, forKey: .symbols) ?? [],
            imports: try container.decodeIfPresent([ImportSummary].self, forKey: .imports) ?? [],
            indirectSymbols: try container.decodeIfPresent([IndirectSymbolSummary].self, forKey: .indirectSymbols) ?? [],
            exports: try container.decodeIfPresent([ExportSummary].self, forKey: .exports) ?? [],
            stringLiterals: try container.decodeIfPresent([StringLiteralSummary].self, forKey: .stringLiterals) ?? [],
            constantCFStrings: try ImageConstantStringProvider.validated(
                container.decodeIfPresent([ImageConstantStringProvider.PersistedCFString].self,
                                          forKey: .constantCFStrings) ?? []),
            basicBlocks: try container.decodeIfPresent([BasicBlockSummary].self, forKey: .basicBlocks) ?? [],
            instructions: try container.decodeIfPresent([InstructionRow].self, forKey: .instructions) ?? [],
            xrefs: try container.decodeIfPresent([XRef].self, forKey: .xrefs) ?? [],
            controlFlowEdges: try container.decodeIfPresent([ControlFlowEdge].self, forKey: .controlFlowEdges) ?? [],
            sourceLines: try container.decodeIfPresent([SourceLineEntry].self, forKey: .sourceLines) ?? [],
            analysisInputFingerprint: try container.decodeIfPresent(
                AnalysisInputFingerprint.self,
                forKey: .analysisInputFingerprint
            ),
            addressOverrides: try container.decodeIfPresent([AddressOverrideEntry].self, forKey: .addressOverrides) ?? [],
            importedPrototypes: try container.decodeIfPresent([ImportedPrototypeEntry].self, forKey: .importedPrototypes) ?? [],
            typeDefinitions: try container.decodeIfPresent([TypeDefinition].self, forKey: .typeDefinitions) ?? [],
            manualXRefs: try container.decodeIfPresent([ManualXRef].self, forKey: .manualXRefs) ?? [],
            bookmarks: try container.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? [],
            segmentOverrides: try container.decodeIfPresent([SegmentOverride].self, forKey: .segmentOverrides) ?? [],
            logicalBreakpointCatalog: persistence.catalog,
            logicalBreakpointCatalogAvailability: persistence.availability,
            launchProfileCatalog: launchPersistence.catalog,
            launchProfileCatalogAvailability: launchPersistence.availability,
            savedWatchCatalog: try Self.decodeSavedWatches(from: container),
            sourceLinkState: try Self.decodeSourceLinks(from: container)
        )
    }

    private static func decodeSourceLinks(from container: KeyedDecodingContainer<CodingKeys>) throws -> Data {
        guard let text = try container.decodeIfPresent(String.self, forKey: .sourceLinkState) else {
            return Data()
        }
        guard text.utf8.count <= 1_398_104, let bytes = Data(base64Encoded: text),
              bytes.count <= 1_048_576 else {
            throw DecodingError.dataCorruptedError(
                forKey: .sourceLinkState, in: container, debugDescription: "Source evidence exceeds its storage bound."
            )
        }
        return bytes
    }

    /// Focused raw-JSON entry point used by package persistence tests and callers that decode an
    /// analysis object independently from a full manifest. Production manifest loading installs
    /// the identical preflight flag on its decoder before any model decoding occurs.
    static func decodeStrictPackageJSON(from data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.userInfo[.workspacePackageDuplicateKeyFindings] = try
            WorkspacePackageDuplicateKeyPreflight.findings(in: data)
        return try decoder.decode(Self.self, from: data)
    }

    private static func decodeSavedWatches(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> WorkspaceSavedWatchCatalog {
        guard container.contains(.savedWatchCatalog) else { return .empty }
        let base64 = try container.decode(String.self, forKey: .savedWatchCatalog)
        guard base64.utf8.count <= 43_692, let bytes = Data(base64Encoded: base64),
              bytes.base64EncodedString() == base64 else {
            throw WorkspaceSavedWatchValidationError.invalid
        }
        return try .decodeCanonicalBytes(bytes)
    }

    /// Custom encode preserves the historical field set while omitting empty `sourceLines` and
    /// pristine authored catalogs. A legacy workspace with none of those facts therefore keeps
    /// its established package shape without a format-version bump.
    func encode(to encoder: Encoder) throws {
        guard logicalBreakpointCatalogAvailability == .available else {
            throw DebuggerLogicalBreakpointCatalogPersistenceError.unavailable
        }
        guard launchProfileCatalogAvailability == .available else {
            throw DebuggerLaunchProfileCatalogPersistenceError.unavailable
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !sourceLinkState.isEmpty {
            guard sourceLinkState.count <= 1_048_576 else {
                throw EncodingError.invalidValue(sourceLinkState.count, .init(
                    codingPath: encoder.codingPath, debugDescription: "Source evidence exceeds its storage bound."
                ))
            }
            try c.encode(sourceLinkState.base64EncodedString(), forKey: .sourceLinkState)
        }
        if !savedWatchCatalog.definitions.isEmpty {
            try c.encode(savedWatchCatalog.canonicalBytes().base64EncodedString(),
                         forKey: .savedWatchCatalog)
        }
        try c.encode(functions, forKey: .functions)
        try c.encode(symbols, forKey: .symbols)
        try c.encode(imports, forKey: .imports)
        try c.encode(indirectSymbols, forKey: .indirectSymbols)
        try c.encode(exports, forKey: .exports)
        try c.encode(stringLiterals, forKey: .stringLiterals)
        if !constantCFStrings.isEmpty {
            try c.encode(ImageConstantStringProvider.validated(constantCFStrings), forKey: .constantCFStrings)
        }
        try c.encode(basicBlocks, forKey: .basicBlocks)
        try c.encode(instructions, forKey: .instructions)
        try c.encode(xrefs, forKey: .xrefs)
        try c.encode(controlFlowEdges, forKey: .controlFlowEdges)
        if !sourceLines.isEmpty { try c.encode(sourceLines, forKey: .sourceLines) }
        if let analysisInputFingerprint {
            try c.encode(analysisInputFingerprint, forKey: .analysisInputFingerprint)
        }
        try c.encode(addressOverrides, forKey: .addressOverrides)
        if !importedPrototypes.isEmpty { try c.encode(importedPrototypes, forKey: .importedPrototypes) }
        try c.encode(typeDefinitions, forKey: .typeDefinitions)
        try c.encode(manualXRefs, forKey: .manualXRefs)
        try c.encode(bookmarks, forKey: .bookmarks)
        try c.encode(segmentOverrides, forKey: .segmentOverrides)
        if !logicalBreakpointCatalog.isPristine {
            try c.encode(logicalBreakpointCatalog, forKey: .logicalBreakpointCatalog)
        }
        if !launchProfileCatalog.isPristine {
            let canonical = try DebuggerLaunchProfileCanonicalCodec.encodeCatalog(
                launchProfileCatalog
            )
            try c.encode(canonical.base64EncodedString(), forKey: .launchProfileCatalog)
        }
    }

    init(snapshot: WorkspaceSnapshot) {
        self.init(
            functions: snapshot.functions,
            symbols: snapshot.symbols,
            imports: snapshot.imports,
            indirectSymbols: snapshot.indirectSymbols,
            exports: snapshot.exports,
            stringLiterals: snapshot.stringLiterals,
            constantCFStrings: ImageConstantStringProvider.persistedCFStrings(in: snapshot.constantStrings),
            basicBlocks: snapshot.basicBlocks,
            instructions: snapshot.instructions,
            xrefs: snapshot.xrefs,
            controlFlowEdges: snapshot.controlFlowEdges,
            sourceLines: snapshot.sourceLines,
            analysisInputFingerprint: snapshot.analysisInputFingerprint,
            addressOverrides: Self.entries(from: snapshot.addressOverrides),
            importedPrototypes: ImportedPrototypeEntry.entries(from: snapshot.importedPrototypes),
            typeDefinitions: snapshot.typeDefinitions,
            manualXRefs: snapshot.manualXRefs.sorted { lhs, rhs in
                (lhs.imageSlot.rawValue, lhs.from, lhs.to, lhs.kind)
                    < (rhs.imageSlot.rawValue, rhs.from, rhs.to, rhs.kind)
            },
            bookmarks: snapshot.bookmarks.sorted {
                ($0.imageSlot.rawValue, $0.address, $0.name)
                    < ($1.imageSlot.rawValue, $1.address, $1.name)
            },
            segmentOverrides: snapshot.segmentOverrides
                .filter { !$0.isEmpty }
                .sorted {
                    ($0.imageSlot.rawValue, $0.originalName)
                        < ($1.imageSlot.rawValue, $1.originalName)
                },
            logicalBreakpointCatalog: snapshot.logicalBreakpointCatalog,
            launchProfileCatalog: snapshot.launchProfileCatalog,
            savedWatchCatalog: snapshot.savedWatchCatalog,
            sourceLinkState: snapshot.sourceLinkState
        )
    }

    /// The v2 per-image payload. Workspace-global authoring is deliberately empty here and is
    /// encoded once in the manifest's top-level `analysis` value.
    init(imageAnalysis: ImageAnalysis) {
        self.init(
            functions: imageAnalysis.functions,
            symbols: imageAnalysis.symbols,
            imports: imageAnalysis.imports,
            indirectSymbols: imageAnalysis.indirectSymbols,
            exports: imageAnalysis.exports,
            stringLiterals: imageAnalysis.stringLiterals,
            constantCFStrings: ImageConstantStringProvider.persistedCFStrings(in: imageAnalysis.constantStrings),
            basicBlocks: imageAnalysis.basicBlocks,
            instructions: imageAnalysis.instructions,
            xrefs: imageAnalysis.xrefs,
            controlFlowEdges: imageAnalysis.controlFlowEdges,
            sourceLines: imageAnalysis.sourceLines,
            analysisInputFingerprint: imageAnalysis.analysisInputFingerprint
        )
    }

    /// The v2 workspace-global payload. Image-derived arrays are deliberately empty because each
    /// image has exactly one `WorkspacePackageImageAnalysis` record.
    init(authoringFrom snapshot: WorkspaceSnapshot) {
        self.init(
            addressOverrides: Self.entries(from: snapshot.addressOverrides),
            importedPrototypes: ImportedPrototypeEntry.entries(from: snapshot.importedPrototypes),
            typeDefinitions: snapshot.typeDefinitions,
            manualXRefs: snapshot.manualXRefs.sorted { lhs, rhs in
                (lhs.imageSlot.rawValue, lhs.from, lhs.to, lhs.kind)
                    < (rhs.imageSlot.rawValue, rhs.from, rhs.to, rhs.kind)
            },
            bookmarks: snapshot.bookmarks.sorted {
                ($0.imageSlot.rawValue, $0.address, $0.name)
                    < ($1.imageSlot.rawValue, $1.address, $1.name)
            },
            segmentOverrides: snapshot.segmentOverrides
                .filter { !$0.isEmpty }
                .sorted {
                    ($0.imageSlot.rawValue, $0.originalName)
                        < ($1.imageSlot.rawValue, $1.originalName)
                },
            logicalBreakpointCatalog: snapshot.logicalBreakpointCatalog,
            launchProfileCatalog: snapshot.launchProfileCatalog,
            savedWatchCatalog: snapshot.savedWatchCatalog,
            sourceLinkState: snapshot.sourceLinkState
        )
    }

    func imageAnalysis(hexBytes: Data, imageBytes: Data = Data()) -> ImageAnalysis {
        ImageAnalysis(
            functions: functions,
            symbols: symbols,
            imports: imports,
            indirectSymbols: indirectSymbols,
            exports: exports,
            stringLiterals: stringLiterals,
            basicBlocks: basicBlocks,
            instructions: instructions,
            xrefs: xrefs,
            controlFlowEdges: controlFlowEdges,
            hexBytes: hexBytes,
            constantStrings: ImageConstantStringProvider.build(
                stringLiterals: stringLiterals,
                cfStrings: constantCFStrings.reduce(into: [:]) { $0[$1.address] = $1.text }
            ),
            sourceLines: sourceLines,
            imageBytes: imageBytes,
            analysisInputFingerprint: analysisInputFingerprint
        )
    }

    func snapshot(binaries: [BinaryImage], hexBytes: Data) -> WorkspaceSnapshot {
        let legacySlot = binaries.first?.slot ?? .primary
        return WorkspaceSnapshot(
            binaries: binaries,
            analysisBySlot: [legacySlot: imageAnalysis(hexBytes: hexBytes)],
            addressOverrides: Self.overrideMap(from: addressOverrides),
            importedPrototypes: ImportedPrototypeEntry.map(from: importedPrototypes),
            typeDefinitions: typeDefinitions,
            manualXRefs: manualXRefs,
            bookmarks: bookmarks,
            segmentOverrides: segmentOverrides,
            logicalBreakpointCatalog: logicalBreakpointCatalog,
            launchProfileCatalog: launchProfileCatalog,
            savedWatchCatalog: savedWatchCatalog,
            sourceLinkState: sourceLinkState
        )
    }

    /// Projects the qualified-address override map into (slot, address)-sorted,
    /// non-empty entries for persistence. Sorting by slot FIRST keeps single-image
    /// packages (everything in slot 0) byte-identical to the legacy address-sorted form.
    static func entries(from overrides: [ImageAddress: AddressOverride]) -> [AddressOverrideEntry] {
        overrides
            .filter { !$0.value.isEmpty }
            .sorted { ($0.key.slot.rawValue, $0.key.address) < ($1.key.slot.rawValue, $1.key.address) }
            .map { AddressOverrideEntry(address: $0.key.address, imageSlot: $0.key.slot, override: $0.value) }
    }

    /// Rebuilds the qualified-address override map from persisted entries, dropping
    /// any empty ones defensively. Entries without a persisted slot decode to
    /// `.primary` — the legacy single-image meaning.
    static func overrideMap(from entries: [AddressOverrideEntry]) -> [ImageAddress: AddressOverride] {
        var map: [ImageAddress: AddressOverride] = [:]
        for entry in entries where !entry.override.isEmpty {
            map[ImageAddress(slot: entry.imageSlot, address: entry.address)] = entry.override
        }
        return map
    }
}

/// One v2 package analysis joined explicitly to both binary UUID and durable image slot. An array
/// (rather than a JSON dictionary keyed by `ImageSlot`) preserves deterministic slot ordering and
/// lets validation detect duplicate keys instead of silently overwriting them during decode.
struct WorkspacePackageImageAnalysis: Codable, Equatable {
    var binaryID: UUID
    var imageSlot: ImageSlot
    var analysis: WorkspacePackageAnalysis
}

enum WorkspaceInputCopyingDecision: String, Codable, CaseIterable, Equatable {
    case copyInputsIntoPackage = "copy_inputs_into_package"
    case referenceOriginalInputs = "reference_original_inputs"

    var copiesInputsIntoPackage: Bool {
        self == .copyInputsIntoPackage
    }
}

enum WorkspaceBookmarkResolutionDecision: String, Codable, CaseIterable, Equatable {
    case resolveStoredBookmarks = "resolve_stored_bookmarks"
    case usePackageAttachmentsOnly = "use_package_attachments_only"
    case promptForMissingInputs = "prompt_for_missing_inputs"
}

enum WorkspaceRecentDocumentState: String, Codable, CaseIterable, Equatable {
    case available
    case missing
    case unreadable
    case conflicted
}

struct WorkspacePackageContents {
    var manifest: WorkspacePackageManifest
    var snapshot: WorkspaceSnapshot
    var attachmentsByBinaryID: [UUID: Data]
    var instructionSidecarData: Data? = nil
    var session: WorkspacePackageSession?
    var reconstructionState: ReconstructionWorkspaceState = .empty
    var reconstructionAttachmentSources: [ReconstructionAttachmentSource] = []
    var logicalBreakpointCatalogAvailability: DebuggerLogicalBreakpointCatalogAvailability = .available
    var launchProfileCatalogAvailability: DebuggerLaunchProfileCatalogAvailability = .available
    /// HS-1: what load-time validation removed from the persisted analysis (empty when consistent).
    var analysisRepairs: [WorkspaceAnalysisRepair] = []
}

struct WorkspacePackageManifest: Codable, Equatable {
    /// Legacy logical projection version. Explicit legacy manifest codecs retain versions 1–3;
    /// complete package writes wrap that analysis layout in the v4 instruction-sidecar format.
    /// Archive identity remains independent of reconstruction authority.
    static let currentFormatVersion = 1
    static let multiImageFormatVersion = 2
    static let reconstructionFormatVersion = 3
    static let instructionSidecarFormatVersion = 4
    static let supportedFormatVersions: Set<Int> = [
        currentFormatVersion,
        multiImageFormatVersion,
        reconstructionFormatVersion,
        instructionSidecarFormatVersion,
    ]

    var instructionSidecar: WorkspaceInstructionSidecarDescriptor?
    /// The layout inside the v4 envelope retains legacy single-image/multi-image/reconstruction semantics.
    var analysisFormatVersion: Int { instructionSidecar?.analysisFormatVersion ?? formatVersion }

    var formatIdentifier: String
    var formatVersion: Int
    var documentID: UUID
    var workspaceUUID: UUID
    var workspaceName: String
    var createdAt: Date
    var modifiedAt: Date
    var inputCopyingDecision: WorkspaceInputCopyingDecision
    var bookmarkResolutionDecision: WorkspaceBookmarkResolutionDecision
    var binaries: [WorkspacePackageBinary]
    var analysis: WorkspacePackageAnalysis?
    var imageAnalyses: [WorkspacePackageImageAnalysis]?
    var session: WorkspacePackageSession?
    var assistantSessionRecords: [WorkspacePackageAssistantSessionRecord]
    var runtimeAuthorityRecords: [WorkspacePackageRuntimeAuthorityRecord]
    var reconstruction: ReconstructionPackageDescriptor?
    var requiredReaderFeatures: [String]
    static let reconstructionReplayReaderFeature = "reconstruction.replay.v1"
    static let analystFindingsReaderFeature = "analyst.findings.v1"
    static let analystFindingHistoryReaderFeature = "analyst.findings.history.v2"
    /// Findings that cite contract facts or carry a retract, stale or readmit operation. Every package
    /// written with findings declares it, so a build that predates it refuses the package up front.
    static let analystFindingCitationsReaderFeature = "analyst.findings.v2"
    static let appendedExecutableCaveReaderFeature = "mach-o.appended-cave.v1"
    /// Navigator-engine contract state (`navigatorState`) is present and must be read, not dropped.
    static let navigatorStateReaderFeature = "navigator.state.v1"
    var analystFindings: AnalystFindingEnvelope?
    var reaEvidence: Data?
    /// HS-2: the analyzer that wrote this workspace. Absent in workspaces written before stamping.
    var analyzer: WorkspaceAnalyzerStamp?
    /// Navigator-engine contract state per image slot, keyed by `String(ImageSlot.rawValue)`.
    /// Absent in workspaces written before the navigator store was persisted.
    var navigatorState: [String: NavigatorEngineStateEnvelope]?
    /// Set by decoding when a `navigatorState` key is present but does not decode. Never encoded:
    /// the store opens empty and logs once instead of refusing the whole workspace.
    var navigatorStateUndecodable = false

    private enum CodingKeys: String, CodingKey {
        case instructionSidecar
        case formatIdentifier
        case formatVersion
        case documentID
        case workspaceUUID
        case workspaceName
        case createdAt
        case modifiedAt
        case inputCopyingDecision
        case bookmarkResolutionDecision
        case binaries
        case analysis
        case imageAnalyses
        case session
        case assistantSessionRecords
        case runtimeAuthorityRecords
        case reconstruction
        case requiredReaderFeatures
        case analystFindings
        case reaEvidence
        case analyzer
        case navigatorState
    }

    init(
        formatIdentifier: String = MacScopeDocumentPackage.formatIdentifier,
        formatVersion: Int = WorkspacePackageManifest.currentFormatVersion,
        documentID: UUID,
        workspaceUUID: UUID,
        workspaceName: String,
        createdAt: Date,
        modifiedAt: Date,
        inputCopyingDecision: WorkspaceInputCopyingDecision = .copyInputsIntoPackage,
        bookmarkResolutionDecision: WorkspaceBookmarkResolutionDecision = .resolveStoredBookmarks,
        binaries: [WorkspacePackageBinary],
        analysis: WorkspacePackageAnalysis? = nil,
        imageAnalyses: [WorkspacePackageImageAnalysis]? = nil,
        session: WorkspacePackageSession?,
        assistantSessionRecords: [WorkspacePackageAssistantSessionRecord] = [],
        runtimeAuthorityRecords: [WorkspacePackageRuntimeAuthorityRecord] = [],
        reconstruction: ReconstructionPackageDescriptor? = nil,
        requiredReaderFeatures: [String] = [],
        analystFindings: AnalystFindingEnvelope? = nil,
        reaEvidence: Data? = nil,
        analyzer: WorkspaceAnalyzerStamp? = nil,
        instructionSidecar: WorkspaceInstructionSidecarDescriptor? = nil,
        navigatorState: [String: NavigatorEngineStateEnvelope]? = nil
    ) {
        self.formatIdentifier = formatIdentifier
        self.formatVersion = formatVersion
        self.documentID = documentID
        self.workspaceUUID = workspaceUUID
        self.workspaceName = workspaceName
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.inputCopyingDecision = inputCopyingDecision
        self.bookmarkResolutionDecision = bookmarkResolutionDecision
        self.binaries = binaries
        self.analysis = analysis
        self.imageAnalyses = imageAnalyses
        self.session = session
        self.assistantSessionRecords = assistantSessionRecords
        self.runtimeAuthorityRecords = runtimeAuthorityRecords
        self.reconstruction = reconstruction
        self.requiredReaderFeatures = requiredReaderFeatures
        self.analystFindings = analystFindings
        self.reaEvidence = reaEvidence
        self.analyzer = analyzer
        self.instructionSidecar = instructionSidecar
        self.navigatorState = navigatorState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var decodedAnalysis = try container.decodeIfPresent(
            WorkspacePackageAnalysis.self,
            forKey: .analysis
        )
        // A duplicate ancestor can cause Foundation to select `null`, in which case
        // WorkspacePackageAnalysis.init(from:) never runs. Preserve the raw preflight latch at the
        // manifest boundary as well so an ambiguous authored catalog can never disappear into the
        // ordinary missing-analysis compatibility default.
        let duplicateKeyFindings = decoder.userInfo[.workspacePackageDuplicateKeyFindings]
            as? WorkspacePackageDuplicateKeyFindings
            ?? WorkspacePackageDuplicateKeyFindings()
        if duplicateKeyFindings.analysisAncestor {
            if decodedAnalysis == nil {
                decodedAnalysis = WorkspacePackageAnalysis(
                    logicalBreakpointCatalogAvailability: .unavailable,
                    launchProfileCatalogAvailability: .unavailable
                )
            } else {
                decodedAnalysis?.logicalBreakpointCatalog = .freshPristine()
                decodedAnalysis?.logicalBreakpointCatalogAvailability = .unavailable
                decodedAnalysis?.launchProfileCatalog =
                    WorkspacePackageLaunchProfileCompatibility.pristineCatalog
                decodedAnalysis?.launchProfileCatalogAvailability = .unavailable
            }
        }
        self.init(
            formatIdentifier: try container.decode(String.self, forKey: .formatIdentifier),
            formatVersion: try container.decode(Int.self, forKey: .formatVersion),
            documentID: try container.decode(UUID.self, forKey: .documentID),
            workspaceUUID: try container.decode(UUID.self, forKey: .workspaceUUID),
            workspaceName: try container.decode(String.self, forKey: .workspaceName),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            modifiedAt: try container.decode(Date.self, forKey: .modifiedAt),
            inputCopyingDecision: try container.decodeIfPresent(
                WorkspaceInputCopyingDecision.self,
                forKey: .inputCopyingDecision
            ) ?? .copyInputsIntoPackage,
            bookmarkResolutionDecision: try container.decodeIfPresent(
                WorkspaceBookmarkResolutionDecision.self,
                forKey: .bookmarkResolutionDecision
            ) ?? .resolveStoredBookmarks,
            binaries: try container.decode([WorkspacePackageBinary].self, forKey: .binaries),
            analysis: decodedAnalysis,
            imageAnalyses: try container.decodeIfPresent(
                [WorkspacePackageImageAnalysis].self,
                forKey: .imageAnalyses
            ),
            session: try container.decodeIfPresent(WorkspacePackageSession.self, forKey: .session),
            assistantSessionRecords: try container.decodeIfPresent(
                [WorkspacePackageAssistantSessionRecord].self,
                forKey: .assistantSessionRecords
            ) ?? [],
            runtimeAuthorityRecords: try container.decodeIfPresent(
                [WorkspacePackageRuntimeAuthorityRecord].self,
                forKey: .runtimeAuthorityRecords
            ) ?? [],
            reconstruction: try container.decodeIfPresent(
                ReconstructionPackageDescriptor.self,
                forKey: .reconstruction
            ),
            requiredReaderFeatures: try container.decodeIfPresent([String].self, forKey: .requiredReaderFeatures) ?? [],
            analystFindings: try container.decodeIfPresent(AnalystFindingEnvelope.self, forKey: .analystFindings),
            reaEvidence: try container.decodeIfPresent(Data.self, forKey: .reaEvidence),
            analyzer: try container.decodeIfPresent(WorkspaceAnalyzerStamp.self, forKey: .analyzer),
            instructionSidecar: try container.decodeIfPresent(WorkspaceInstructionSidecarDescriptor.self, forKey: .instructionSidecar)
        )
        // Lenient: navigator state is derived evidence, so a value that does not decode opens the
        // workspace with an empty store (flagged here, logged once by the store) instead of failing.
        if container.contains(.navigatorState) {
            do {
                navigatorState = try container.decodeIfPresent(
                    [String: NavigatorEngineStateEnvelope].self,
                    forKey: .navigatorState
                )
            } catch {
                navigatorState = nil
                navigatorStateUndecodable = true
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatIdentifier, forKey: .formatIdentifier)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(documentID, forKey: .documentID)
        try container.encode(workspaceUUID, forKey: .workspaceUUID)
        try container.encode(workspaceName, forKey: .workspaceName)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encode(inputCopyingDecision, forKey: .inputCopyingDecision)
        try container.encode(bookmarkResolutionDecision, forKey: .bookmarkResolutionDecision)
        try container.encode(binaries, forKey: .binaries)
        try container.encodeIfPresent(analysis, forKey: .analysis)
        try container.encodeIfPresent(imageAnalyses, forKey: .imageAnalyses)
        try container.encodeIfPresent(session, forKey: .session)
        // v3 treats authority collections as closed state even when empty. Older package
        // versions retain their established omission-compatible encoding.
        if analysisFormatVersion == Self.reconstructionFormatVersion || !assistantSessionRecords.isEmpty {
            try container.encode(
                assistantSessionRecords.map {
                    $0.normalizedForCurrentEncoding(
                        workspaceUUID: workspaceUUID,
                        documentID: documentID
                    )
                },
                forKey: .assistantSessionRecords
            )
        }
        if analysisFormatVersion == Self.reconstructionFormatVersion || !runtimeAuthorityRecords.isEmpty {
            try container.encode(runtimeAuthorityRecords, forKey: .runtimeAuthorityRecords)
        }
        try container.encodeIfPresent(reconstruction, forKey: .reconstruction)
        if !requiredReaderFeatures.isEmpty { try container.encode(requiredReaderFeatures, forKey: .requiredReaderFeatures) }
        try container.encodeIfPresent(analystFindings, forKey: .analystFindings)
        try container.encodeIfPresent(reaEvidence, forKey: .reaEvidence)
        try container.encodeIfPresent(analyzer, forKey: .analyzer)
        try container.encodeIfPresent(instructionSidecar, forKey: .instructionSidecar)
        try container.encodeIfPresent(navigatorState, forKey: .navigatorState)
    }
}

/// Versioned, slot-qualified imported contracts are independent of authored overrides.
struct ImportedPrototypeEntry: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    var imageSlot: ImageSlot
    var address: UInt64
    var signature: FunctionSignatureOverride

    static func entries(from map: [ImageAddress: FunctionSignatureOverride]) -> [Self] {
        map.sorted { ($0.key.slot.rawValue, $0.key.address) < ($1.key.slot.rawValue, $1.key.address) }
            .map { Self(imageSlot: $0.key.slot, address: $0.key.address, signature: $0.value) }
    }

    static func map(from entries: [Self]) -> [ImageAddress: FunctionSignatureOverride] {
        var result: [ImageAddress: FunctionSignatureOverride] = [:]
        var refused: Set<ImageAddress> = []
        for entry in entries {
            let key = ImageAddress(slot: entry.imageSlot, address: entry.address)
            guard entry.schemaVersion == 1, !refused.contains(key), result[key] == nil,
                  entry.signature.hasAnalysisEffect else {
                result.removeValue(forKey: key)
                refused.insert(key)
                continue
            }
            result[key] = entry.signature
        }
        return result
    }
}
