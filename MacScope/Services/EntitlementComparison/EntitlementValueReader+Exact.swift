import Foundation

/// Exact embedded declarations; unavailable values must never become an empty dictionary.
struct ExactDeclaredEntitlements: Equatable, Sendable {
    enum State: String, Equatable, Sendable { case notPresent, dictionaryPresent, unavailable }
    var state: State
    var values: EntitlementDictionary?
    var reason: String?
    var format: String?
}

extension EntitlementValueReader {
    /// Reads only the selected slice's embedded blob; does not verify signing or effective access.
    static func readExact(signature: MachOCodeSignature?, sliceBytes: Data) -> ExactDeclaredEntitlements {
        guard let superBlob = signature?.superBlob else {
            return .init(state: .unavailable, values: nil,
                         reason: "Code Signature blob is unavailable", format: nil)
        }
        let candidates = superBlob.blobs.filter {
            $0.type == MachOConstants.codeSignatureSlotEntitlements ||
                $0.type == MachOConstants.codeSignatureSlotDerEntitlements
        }.sorted {
            ($0.type == MachOConstants.codeSignatureSlotEntitlements ? 0 : 1) <
                ($1.type == MachOConstants.codeSignatureSlotEntitlements ? 0 : 1)
        }
        guard !candidates.isEmpty else {
            return .init(state: .notPresent, values: nil, reason: nil, format: nil)
        }
        var failures: [String] = []
        for blob in candidates {
            let isXML = blob.type == MachOConstants.codeSignatureSlotEntitlements
            let format = isXML ? "XML" : "DER"
            do {
                let payload = try entitlementPayload(blob: blob, sliceBytes: sliceBytes)
                let dictionary: EntitlementDictionary
                if isXML {
                    let object = try PropertyListSerialization.propertyList(from: payload, format: nil)
                    guard let root = object as? NSDictionary else { throw EntitlementDataError.invalidRoot }
                    guard root.count <= 256 else { throw EntitlementDataError.limitExceeded("top-level key count") }
                    dictionary = try FoundationEntitlementDecoder(limits: .init(
                        maxDepth: 16, maxNodes: 4_096, maxBytes: 262_144)).decode(root)
                } else {
                    dictionary = try exactDERDictionary(AppleEntitlementDER.decode(payload))
                }
                return .init(state: .dictionaryPresent, values: dictionary, reason: nil, format: format)
            } catch {
                failures.append("\(format): \(error.localizedDescription)")
            }
        }
        return .init(state: .unavailable, values: nil, reason: failures.joined(separator: "; "),
                     format: candidates.first.map {
                         $0.type == MachOConstants.codeSignatureSlotEntitlements ? "XML" : "DER"
                     })
    }

    private static func exactDERDictionary(_ entries: [AppleEntitlementDER.Entry]) throws -> EntitlementDictionary {
        try EntitlementDictionary(entries: entries.map { .init(key: $0.key, value: try exactDERValue($0.value)) })
    }

    private static func exactDERValue(_ value: AppleEntitlementDER.Value) throws -> EntitlementValue {
        switch value {
        case .boolean(let value): return .boolean(value)
        case .string(let value): return .string(value)
        case .integer(let value): return .integer(value)
        case .unsignedInteger(let value): return .unsignedInteger(value)
        case .array(let values): return .array(try values.map(exactDERValue))
        case .dictionary(let entries): return .dictionary(try exactDERDictionary(entries))
        }
    }
}
