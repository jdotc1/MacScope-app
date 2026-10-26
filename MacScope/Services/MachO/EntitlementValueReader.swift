import CoreFoundation
import Foundation

/// Values from a declared entitlement blob. An unsupported value invalidates the entire blob.
indirect enum DeclaredEntitlementValue: Codable, Equatable, Sendable {
    case boolean(Bool)
    case string(String)
    case integer(Int64)
    case real(Double)
    case data(Data)
    case date(Date)
    case array([DeclaredEntitlementValue])
    case dictionary([String: DeclaredEntitlementValue])

    var isTrue: Bool { if case .boolean(true) = self { return true }; return false }
    var isFalse: Bool { if case .boolean(false) = self { return true }; return false }
}

struct DeclaredEntitlements: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case absent, parsed, unparsed }
    var state: State
    var format: String?
    var values: [String: DeclaredEntitlementValue]
    var reason: String?
}

/// Reads the already located Code Signature blob from the selected slice's bytes.
/// No signature verification or filesystem access occurs here.
enum EntitlementValueReader {
    static func read(signature: MachOCodeSignature?, sliceBytes: Data) -> DeclaredEntitlements {
        guard let signature, let superBlob = signature.superBlob else {
            return .init(state: .unparsed, format: nil, values: [:], reason: "Code Signature blob is unavailable")
        }
        let candidates = superBlob.blobs.filter {
            $0.type == MachOConstants.codeSignatureSlotEntitlements ||
                $0.type == MachOConstants.codeSignatureSlotDerEntitlements
        }
        guard !candidates.isEmpty else {
            return .init(state: .absent, format: nil, values: [:], reason: nil)
        }
        // Prefer XML when both formats are present: XML is a full property list, while DER
        // implementations may encounter an unsupported tag. Never merge partial forms.
        let ordered = candidates.sorted { lhs, rhs in
            (lhs.type == MachOConstants.codeSignatureSlotEntitlements ? 0 : 1) <
                (rhs.type == MachOConstants.codeSignatureSlotEntitlements ? 0 : 1)
        }
        var failures: [String] = []
        for blob in ordered {
            let format = blob.type == MachOConstants.codeSignatureSlotEntitlements ? "XML" : "DER"
            let payload: Data
            do {
                payload = try entitlementPayload(blob: blob, sliceBytes: sliceBytes)
            } catch {
                failures.append("\(format) \(error.localizedDescription)")
                continue
            }
            if let values = format == "XML" ? decodeXML(payload) : decodeDER(payload) {
                return .init(state: .parsed, format: format, values: values, reason: nil)
            }
            failures.append("\(format) values could not be decoded completely")
        }
        return .init(state: .unparsed, format: ordered.first.map {
            $0.type == MachOConstants.codeSignatureSlotEntitlements ? "XML" : "DER"
        }, values: [:], reason: failures.joined(separator: "; "))
    }

    private static func decodeXML(_ data: Data) -> [String: DeclaredEntitlementValue]? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any] else { return nil }
        var budget = 4_096
        return convert(dictionary, depth: 0, budget: &budget).flatMap {
            if case .dictionary(let result) = $0, result.count <= 256 { return result }
            return nil
        }
    }

    private static func convert(_ raw: Any, depth: Int, budget: inout Int) -> DeclaredEntitlementValue? {
        guard depth <= 16, budget > 0 else { return nil }
        budget -= 1
        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean(number.boolValue) }
            let numericType = String(cString: number.objCType)
            if numericType == "f" || numericType == "d" { return .real(number.doubleValue) }
            return .integer(number.int64Value)
        }
        if let string = raw as? String { return .string(string) }
        if let data = raw as? Data { return .data(data) }
        if let date = raw as? Date { return .date(date) }
        if let array = raw as? [Any] {
            var values: [DeclaredEntitlementValue] = []
            for item in array {
                guard let value = convert(item, depth: depth + 1, budget: &budget) else { return nil }
                values.append(value)
            }
            return .array(values)
        }
        if let dictionary = raw as? [String: Any] {
            var values: [String: DeclaredEntitlementValue] = [:]
            for (key, item) in dictionary {
                guard let value = convert(item, depth: depth + 1, budget: &budget) else { return nil }
                values[key] = value
            }
            return .dictionary(values)
        }
        return nil
    }

    /// Blob offsets include the CS_GenericBlob header. Strip it here exactly once;
    /// both XML and DER decoders consume only the bounded payload.
    static func entitlementPayload(blob: MachOCodeSignatureBlob, sliceBytes: Data) throws -> Data {
        let header = MachOConstants.codeSignatureBlobHeaderSize
        let isXML = blob.type == MachOConstants.codeSignatureSlotEntitlements
        guard blob.length >= header,
              blob.fileOffset <= UInt64(sliceBytes.count),
              UInt64(blob.length) <= UInt64(sliceBytes.count) - blob.fileOffset,
              blob.magic == (isXML ? MachOConstants.codeSignatureEmbeddedEntitlementsMagic :
                                MachOConstants.codeSignatureDerEntitlementsMagic) else {
            throw AppleEntitlementDER.Failure("blob bounds or magic invalid")
        }
        guard blob.length - header <= 262_144 else {
            throw AppleEntitlementDER.Failure("payload exceeds 262144 byte bound")
        }
        let start = Int(blob.fileOffset) + Int(header)
        return sliceBytes.subdata(in: start..<(Int(blob.fileOffset) + Int(blob.length)))
    }

    private static func decodeDER(_ data: Data) -> [String: DeclaredEntitlementValue]? {
        guard let entries = try? AppleEntitlementDER.decode(data) else { return nil }
        return declaredDictionary(entries)
    }

    private static func declaredDictionary(_ entries: [AppleEntitlementDER.Entry]) -> [String: DeclaredEntitlementValue]? {
        var result: [String: DeclaredEntitlementValue] = [:]
        for entry in entries {
            // The legacy model cannot represent distinct canonically equivalent keys.
            guard result[entry.key] == nil, let value = declaredValue(entry.value) else { return nil }
            result[entry.key] = value
        }
        return result
    }

    private static func declaredValue(_ value: AppleEntitlementDER.Value) -> DeclaredEntitlementValue? {
        switch value {
        case .boolean(let value): return .boolean(value)
        case .string(let value): return .string(value)
        case .integer(let value): return .integer(value)
        case .unsignedInteger: return nil // Preserve refusal rather than truncate to Int64.
        case .dictionary(let entries): return declaredDictionary(entries).map { .dictionary($0) }
        case .array(let items):
            var result: [DeclaredEntitlementValue] = []
            for item in items {
                guard let value = declaredValue(item) else { return nil }
                result.append(value)
            }
            return .array(result)
        }
    }
}

/// Strict parsing shared by both output models. No CS blob header is accepted here.
/// Current codesign emits APPLICATION 16 { INTEGER 1, CONTEXT 16 dictionary }.
/// Security-59754.120.12's signer used der_encode_plist: retain its SET dictionaries
/// and SEQUENCE arrays, but never the former synthetic SET-as-array encoding.
enum AppleEntitlementDER {
    struct Entry {
        let key: String
        let value: Value
    }

    indirect enum Value {
        case boolean(Bool), string(String), integer(Int64), unsignedInteger(UInt64)
        case array([Value]), dictionary([Entry])
    }

    struct Failure: LocalizedError {
        let detail: String
        init(_ detail: String) { self.detail = detail }
        var errorDescription: String? { detail }
    }

    static func decode(_ data: Data) throws -> [Entry] {
        guard data.count <= 262_144 else { throw Failure("payload exceeds 262144 byte bound") }
        var cursor = Cursor(data: Data(data))
        var nodes = 4_096
        let value: Value
        if data.first == 0x70 {
            var envelope = Cursor(data: try cursor.read(tag: 0x70))
            guard try envelope.read(tag: 0x02) == Data([1]) else { throw Failure("DER version must be 1") }
            value = try envelope.readValue(depth: 0, nodes: &nodes, dictionaryTag: 0xb0)
            guard envelope.isAtEnd else { throw Failure("DER envelope trailing bytes") }
        } else {
            // A real historical producer, not a fallback for malformed envelopes.
            guard data.first == 0x31 else { throw Failure("DER envelope tag") }
            value = try cursor.readValue(depth: 0, nodes: &nodes, dictionaryTag: 0x31)
        }
        guard cursor.isAtEnd else { throw Failure("DER trailing bytes") }
        guard case .dictionary(let entries) = value else { throw Failure("DER root dictionary") }
        return entries
    }

    private struct Cursor {
        let data: Data
        private(set) var position = 0
        var isAtEnd: Bool { position == data.count }

        mutating func read(tag: UInt8) throws -> Data {
            guard position < data.count, data[position] == tag else { throw Failure("DER tag") }
            position += 1
            guard position < data.count else { throw Failure("DER length") }
            let first = data[position]
            position += 1
            var length = Int(first)
            if first & 0x80 != 0 {
                let count = Int(first & 0x7f)
                guard count > 0, count <= 4, count <= data.count - position,
                      data[position] != 0 else { throw Failure("DER length") }
                length = 0
                for _ in 0..<count {
                    length = (length << 8) | Int(data[position])
                    position += 1
                }
                guard length >= 128 else { throw Failure("DER nonminimal length") }
            }
            guard length <= data.count - position else { throw Failure("DER truncated value") }
            let result = data.subdata(in: position..<(position + length))
            position += length
            return result
        }

        mutating func readValue(depth: Int, nodes: inout Int, dictionaryTag: UInt8) throws -> Value {
            guard depth <= 16 else { throw Failure("nesting depth") }
            guard nodes > 0 else { throw Failure("node count") }
            nodes -= 1
            guard position < data.count else { throw Failure("DER missing value") }
            switch data[position] {
            case 0x01:
                let bytes = try read(tag: 0x01)
                guard bytes.count == 1, bytes[0] == 0 || bytes[0] == 0xff else { throw Failure("DER Boolean") }
                return .boolean(bytes[0] == 0xff)
            case 0x0c:
                guard let value = String(data: try read(tag: 0x0c), encoding: .utf8) else {
                    throw Failure("DER string UTF-8")
                }
                return .string(value)
            case 0x02:
                let bytes = try read(tag: 0x02)
                guard !bytes.isEmpty, bytes.count <= 9 else { throw Failure("DER integer exceeds Int64/UInt64") }
                if bytes.count > 1 {
                    guard !(bytes[0] == 0 && bytes[1] & 0x80 == 0),
                          !(bytes[0] == 0xff && bytes[1] & 0x80 != 0) else { throw Failure("DER nonminimal integer") }
                }
                if bytes.count == 9 {
                    guard bytes[0] == 0, bytes[1] & 0x80 != 0 else { throw Failure("DER integer exceeds Int64/UInt64") }
                    return .unsignedInteger(bytes.dropFirst().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
                }
                var value: UInt64 = bytes[0] & 0x80 == 0 ? 0 : .max
                for byte in bytes { value = (value << 8) | UInt64(byte) }
                return .integer(Int64(bitPattern: value))
            case 0x30:
                var items = Cursor(data: try read(tag: 0x30))
                var values: [Value] = []
                while !items.isAtEnd {
                    values.append(try items.readValue(depth: depth + 1, nodes: &nodes, dictionaryTag: dictionaryTag))
                }
                return .array(values)
            case dictionaryTag:
                var pairs = Cursor(data: try read(tag: dictionaryTag))
                var entries: [Entry] = []
                var keys = Set<Data>()
                while !pairs.isAtEnd {
                    guard depth != 0 || entries.count < 256 else { throw Failure("top-level key count") }
                    var pair = Cursor(data: try pairs.read(tag: 0x30))
                    let keyBytes = try pair.read(tag: 0x0c)
                    guard let key = String(data: keyBytes, encoding: .utf8), !key.isEmpty else {
                        throw Failure("DER key UTF-8")
                    }
                    guard keys.insert(keyBytes).inserted else { throw Failure("DER duplicate key") }
                    let value = try pair.readValue(depth: depth + 1, nodes: &nodes, dictionaryTag: dictionaryTag)
                    guard pair.isAtEnd else { throw Failure("DER pair trailing bytes") }
                    entries.append(Entry(key: key, value: value))
                }
                return .dictionary(entries)
            default:
                throw Failure("DER value tag")
            }
        }
    }
}
