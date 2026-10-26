import CryptoKit
import Foundation

/// Immutable, data-only v1 import substrate. No Clang, authored-layout fallback,
/// signature binding or UI activation occurs here. References are local graph
/// keys; cross-shard activation is deliberately deferred. Content identity is
/// SHA-256 of the retained JSON bytes (not a self-referential manifest field).
struct SDKTypeArchive: Sendable {
    static let maxBytes = 64 * 1024 * 1024
    static let maxNodes = 200_000
    static let maxEdges = 1_000_000

    enum ArchiveError: Error, Equatable { case invalid(String) }
    enum Kind: String, Codable, Sendable { case scalar, pointer, record, typedef, enumeration, array, opaque }
    enum RecordKind: String, Codable, Sendable { case `struct`, union }
    enum LayoutStatus: String, Codable, Sendable { case known, unknown }
    struct Layout: Codable, Equatable, Sendable {
        let status: LayoutStatus
        let sizeBytes: UInt64?
        let alignmentBytes: UInt64?
        let reason: String?
    }
    struct Origin: Codable, Equatable, Sendable {
        let header: String
        let line: UInt32
        let column: UInt32
    }
    struct Field: Codable, Equatable, Sendable {
        let id: String
        let name: String
        let typeID: String
        /// Absolute bits from the enclosing record start, never bytes.
        let bitOffset: UInt64?
        let bitWidth: UInt64?
        let flexibleArray: Bool
        let anonymous: Bool
    }
    struct EnumValue: Codable, Equatable, Sendable {
        let name: String
        /// Decimal text preserves unsigned constants above Int64.max.
        let value: String
    }
    struct Node: Codable, Equatable, Sendable {
        let id: String
        let kind: Kind
        let spelling: String
        let layout: Layout
        let origin: Origin?
        let canonicalTypeID: String?
        let underlyingTypeID: String?
        let pointeeTypeID: String?
        let elementTypeID: String?
        let arrayCount: UInt64?
        let signed: Bool?
        let recordKind: RecordKind?
        let fields: [Field]
        let enumValues: [EnumValue]
        let qualifiers: [String]
    }
    struct Provenance: Codable, Equatable, Sendable {
        let compiler: String
        let compilerVersion: String
        let libclangVersion: String
        let sdkIdentity: String
        let targetTriple: String
        let language: String
        let extractorVersion: String
        let input: String
        let inputSHA256: String
        let arguments: [String]
    }
    struct Document: Codable, Equatable, Sendable {
        let schema: String
        let schemaMajor: Int
        let schemaMinor: Int
        let configurationID: String
        let provenance: Provenance
        let diagnostics: [String]
        let types: [Node]
    }

    let contentSHA256: String
    let document: Document
    private let retainedJSON: Data

    func encoded() -> Data { retainedJSON }
    func identity(for declarationID: String) -> ImportedTypeIdentity? {
        guard document.types.contains(where: { $0.id == declarationID }) else { return nil }
        return ImportedTypeIdentity(archiveSHA256: contentSHA256, declarationID: declarationID)
    }

    static func decode(_ data: Data, expectedTarget: String,
                       expectedConfigurationID: String? = nil) throws -> SDKTypeArchive {
        guard !data.isEmpty, data.count <= maxBytes else { throw ArchiveError.invalid("byte limit") }
        try preflight(data)
        let doc = try JSONDecoder().decode(Document.self, from: data)
        guard doc.schema == "macscope.sdk-type-archive", doc.schemaMajor == 1, doc.schemaMinor == 0 else {
            throw ArchiveError.invalid("unsupported schema")
        }
        guard doc.provenance.targetTriple == expectedTarget,
              expectedConfigurationID == nil || expectedConfigurationID == doc.configurationID else {
            throw ArchiveError.invalid("target/configuration mismatch")
        }
        try validate(doc)
        return SDKTypeArchive(contentSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                              document: doc, retainedJSON: data)
    }

    private static func text(_ value: String, empty: Bool = false, limit: Int = 16_384) throws {
        guard (empty || !value.isEmpty), value.utf8.count <= limit, !value.contains("\0") else {
            throw ArchiveError.invalid("string bound")
        }
    }
    private static func digest(_ value: String) throws {
        guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ArchiveError.invalid("digest identity")
        }
    }
    private static func bits(_ bytes: UInt64) throws -> UInt64 {
        let (value, overflow) = bytes.multipliedReportingOverflow(by: 8)
        guard !overflow else { throw ArchiveError.invalid("layout overflow") }
        return value
    }
    private static func validate(_ doc: Document) throws {
        try digest(doc.configurationID)
        try digest(doc.provenance.inputSHA256)
        let p = doc.provenance
        for value in [p.compiler, p.compilerVersion, p.libclangVersion, p.sdkIdentity,
                      p.targetTriple, p.language, p.extractorVersion, p.input] { try text(value) }
        guard ["c", "objective-c"].contains(p.language), p.arguments.count <= 512,
              doc.diagnostics.count <= 1024, doc.types.count <= maxNodes else {
            throw ArchiveError.invalid("manifest bound")
        }
        for value in p.arguments + doc.diagnostics { try text(value) }
        var byID: [String: Node] = [:]
        var edgeCount = 0
        for node in doc.types {
            try text(node.id, limit: 1024)
            try text(node.spelling)
            guard byID.updateValue(node, forKey: node.id) == nil else { throw ArchiveError.invalid("duplicate ID") }
            guard node.fields.count <= 4096, node.enumValues.count <= 4096, node.qualifiers.count <= 16 else {
                throw ArchiveError.invalid("node bound")
            }
            edgeCount += node.fields.count + 4
            guard edgeCount <= maxEdges else { throw ArchiveError.invalid("edge bound") }
            for qualifier in node.qualifiers { try text(qualifier, limit: 128) }
            if let origin = node.origin {
                try text(origin.header)
                guard !origin.header.hasPrefix("/"), !origin.header.split(separator: "/").contains("..") else {
                    throw ArchiveError.invalid("origin must be input-relative")
                }
            }
            switch node.layout.status {
            case .known:
                guard let size = node.layout.sizeBytes, let align = node.layout.alignmentBytes,
                      align > 0, align & (align - 1) == 0, node.layout.reason == nil,
                      size % align == 0 else { throw ArchiveError.invalid("known layout") }
                _ = try bits(size)
            case .unknown:
                guard node.layout.sizeBytes == nil, node.layout.alignmentBytes == nil,
                      let reason = node.layout.reason else { throw ArchiveError.invalid("unknown layout") }
                try text(reason)
            }
        }
        var scalarRoots: [String: String] = [:]
        var nonintegerRoots = Set<String>()
        var scalarWork = 0
        func integerBase(_ start: String) throws -> Node? {
            var id = start, trail: [String] = []
            var visited = Set<String>()
            var root: String?
            while true {
                if let cached = scalarRoots[id] { root = cached; break }
                if nonintegerRoots.contains(id) { break }
                guard visited.insert(id).inserted, let node = byID[id] else { break }
                scalarWork += 1
                guard scalarWork <= maxEdges else { throw ArchiveError.invalid("carrier work bound") }
                trail.append(id)
                if node.kind == .scalar, node.signed != nil { root = id; break }
                guard [.typedef, .enumeration].contains(node.kind), let next = node.underlyingTypeID else { break }
                id = next
            }
            for key in trail {
                if let root { scalarRoots[key] = root } else { nonintegerRoots.insert(key) }
            }
            return root.flatMap { byID[$0] }
        }
        // By-value dependencies are processed by an iterative topological walk.
        // Pointee edges are validated, but never followed as layout dependencies.
        var users: [String: [String]] = [:]
        var remaining: [String: Int] = [:]
        for node in doc.types {
            let refs = [node.canonicalTypeID, node.underlyingTypeID, node.pointeeTypeID, node.elementTypeID].compactMap { $0 }
                + node.fields.map(\.typeID)
            for ref in refs {
                try text(ref, limit: 1024)
                guard byID[ref] != nil else { throw ArchiveError.invalid("dangling reference") }
            }
            guard (node.underlyingTypeID == nil || [.typedef, .enumeration].contains(node.kind)),
                  (node.pointeeTypeID == nil || node.kind == .pointer),
                  (node.elementTypeID == nil || node.kind == .array),
                  (node.arrayCount == nil || node.kind == .array),
                  (node.signed == nil || node.kind == .scalar) else {
                throw ArchiveError.invalid("incompatible type edge")
            }
            var required: [String] = []
            switch node.kind {
            case .record:
                guard node.recordKind != nil else { throw ArchiveError.invalid("record kind") }
                var fieldIDs = Set<String>()
                for (index, field) in node.fields.enumerated() {
                    try text(field.id, limit: 1024)
                    try text(field.name, empty: true)
                    guard fieldIDs.insert(field.id).inserted, let type = byID[field.typeID] else {
                        throw ArchiveError.invalid("field identity")
                    }
                    if field.bitWidth != nil, try integerBase(field.typeID) == nil {
                        throw ArchiveError.invalid("noninteger bitfield")
                    }
                    if field.flexibleArray {
                        guard node.recordKind == .struct, index == node.fields.count - 1,
                              type.kind == .array, type.arrayCount == nil, field.bitWidth == nil else {
                            throw ArchiveError.invalid("flexible tail")
                        }
                    } else { required.append(field.typeID) }
                    if node.layout.status == .known {
                        guard let offset = field.bitOffset, let size = node.layout.sizeBytes else {
                            throw ArchiveError.invalid("missing field offset")
                        }
                        if node.recordKind == .union, offset != 0 { throw ArchiveError.invalid("union offset") }
                        let extent: UInt64
                        if field.flexibleArray { extent = 0 }
                        else if let width = field.bitWidth {
                            guard let carrier = type.layout.sizeBytes, width <= (try bits(carrier)),
                                  width != 0 || field.name.isEmpty else { throw ArchiveError.invalid("bit width") }
                            extent = width
                        } else {
                            guard let bytes = type.layout.sizeBytes else { throw ArchiveError.invalid("unknown by-value field") }
                            extent = try bits(bytes)
                        }
                        let (end, overflow) = offset.addingReportingOverflow(extent)
                        guard !overflow, end <= (try bits(size)) else { throw ArchiveError.invalid("field extent") }
                    }
                }
            case .typedef, .enumeration:
                guard let underlying = node.underlyingTypeID else { throw ArchiveError.invalid("missing underlying type") }
                required.append(underlying)
                if node.kind == .enumeration {
                    let base = try integerBase(underlying)
                    let signed = base?.signed
                    let bytes = base?.layout.sizeBytes
                    if node.layout.status == .known {
                        guard signed != nil, let bytes, bytes > 0, bytes <= 8 else {
                            throw ArchiveError.invalid("enum base")
                        }
                    }
                    var names = Set<String>()
                    for item in node.enumValues {
                        try text(item.name)
                        guard names.insert(item.name).inserted else { throw ArchiveError.invalid("enum name") }
                        if signed == true {
                            guard let value = Int64(item.value), String(value) == item.value else {
                                throw ArchiveError.invalid("enum value")
                            }
                            if let bytes, bytes > 0, bytes < 8 {
                                let bound = Int64(1) << (bytes * 8 - 1)
                                guard value >= -bound, value < bound else { throw ArchiveError.invalid("enum range") }
                            }
                        } else if signed == false {
                            guard let value = UInt64(item.value), String(value) == item.value else {
                                throw ArchiveError.invalid("enum value")
                            }
                            if let bytes, bytes > 0, bytes < 8, value >= (UInt64(1) << (bytes * 8)) { throw ArchiveError.invalid("enum range") }
                        } else {
                            let canonicalSigned = Int64(item.value).map { String($0) == item.value } ?? false
                            let canonicalUnsigned = UInt64(item.value).map { String($0) == item.value } ?? false
                            guard canonicalSigned || canonicalUnsigned else { throw ArchiveError.invalid("enum value") }
                        }
                    }
                }
            case .pointer:
                guard node.pointeeTypeID != nil else { throw ArchiveError.invalid("missing pointee") }
            case .array:
                guard let element = node.elementTypeID else { throw ArchiveError.invalid("missing element") }
                if node.arrayCount != nil { required.append(element) }
                else if node.layout.status == .known { throw ArchiveError.invalid("unknown array extent") }
            case .opaque:
                guard node.layout.status == .unknown else { throw ArchiveError.invalid("opaque layout") }
            case .scalar: break
            }
            if node.kind != .record && (!node.fields.isEmpty || node.recordKind != nil) {
                throw ArchiveError.invalid("fields on non-record")
            }
            if node.kind != .enumeration && !node.enumValues.isEmpty { throw ArchiveError.invalid("values on non-enum") }
            if node.layout.status == .known {
                for ref in required {
                    guard byID[ref]?.layout.status == .known else { throw ArchiveError.invalid("incomplete by-value dependency") }
                    users[ref, default: []].append(node.id)
                }
                remaining[node.id] = required.count
                if [.typedef, .enumeration].contains(node.kind), let ref = node.underlyingTypeID,
                   node.layout != byID[ref]?.layout { throw ArchiveError.invalid("underlying layout mismatch") }
                if node.kind == .array, let count = node.arrayCount, let ref = node.elementTypeID,
                   let element = byID[ref], let size = element.layout.sizeBytes {
                    let (total, overflow) = size.multipliedReportingOverflow(by: count)
                    guard !overflow, total == node.layout.sizeBytes,
                          element.layout.alignmentBytes == node.layout.alignmentBytes else { throw ArchiveError.invalid("array layout") }
                }
            }
        }
        var queue = remaining.compactMap { $0.value == 0 ? $0.key : nil }
        var cursor = 0
        while cursor < queue.count {
            let id = queue[cursor]; cursor += 1
            for user in users[id] ?? [] {
                guard let count = remaining[user] else { continue }
                remaining[user] = count - 1
                if count == 1 { queue.append(user) }
            }
        }
        guard queue.count == remaining.count else { throw ArchiveError.invalid("by-value cycle") }
    }

    /// Bound nesting and raw string/token work before Foundation allocates DTOs.
    private static func preflight(_ data: Data) throws {
        var depth = 0, strings = 0, stringBytes = 0
        var inString = false, escaped = false
        for byte in data {
            if inString {
                stringBytes += 1
                guard stringBytes <= 98_304 else { throw ArchiveError.invalid("encoded string bound") }
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
            } else if byte == 34 {
                inString = true; stringBytes = 0; strings += 1
                guard strings <= 4_000_000 else { throw ArchiveError.invalid("string count") }
            } else if byte == 123 || byte == 91 {
                depth += 1
                guard depth <= 32 else { throw ArchiveError.invalid("JSON depth") }
            } else if byte == 125 || byte == 93 { depth -= 1 }
        }
    }
}
