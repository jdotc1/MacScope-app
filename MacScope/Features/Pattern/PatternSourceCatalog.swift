import Foundation

/// Fixed bundle resources and bounded in-memory input; never a caller-supplied path.
enum PatternSourceCatalog {
    enum Entry: String, CaseIterable, Identifiable {
        case pngIHDR = "png-ihdr", nestedRecord = "nested-record"
        case crossByteBits = "cross-byte-bits", synthetic, userText = "user-text"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .pngIHDR: "PNG IHDR"
            case .nestedRecord: "Nested record"
            case .crossByteBits: "Cross-byte bits"
            case .synthetic: "Synthetic values"
            case .userText: "User text"
            }
        }
        var resourceName: String? {
            switch self {
            case .pngIHDR: "png_ihdr"
            case .nestedRecord: "nested_record"
            case .crossByteBits: "cross_byte_bits"
            case .synthetic: "synthetic"
            case .userText: nil
            }
        }
    }

    static func source(for entry: Entry, userText: String, bundle: Bundle = .main) throws -> String {
        try source(for: entry, userText: userText) { name in
            guard let url = bundle.url(forResource: name, withExtension: "hexpat", subdirectory: "Patterns")
                    ?? bundle.url(forResource: name, withExtension: "hexpat") else { return nil }
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 32_768 else { return nil }
            return try? Data(contentsOf: url)
        }
    }

    static func source(for entry: Entry, userText: String, load: (String) -> Data?) throws -> String {
        let source: String
        if let name = entry.resourceName {
            guard let bytes = load(name), bytes.count <= 32_768,
                  let decoded = String(data: bytes, encoding: .utf8) else {
                throw PatternInterpretationError.nativeUnavailable
            }
            source = decoded
        } else {
            source = userText
        }
        guard !source.isEmpty, source.utf8.count <= 32_768 else {
            throw PatternInterpretationError.invalidRequest
        }
        return source
    }
}
