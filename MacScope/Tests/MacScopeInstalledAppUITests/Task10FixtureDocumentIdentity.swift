import Foundation

/// Changes only the document scope of an already digest-verified fixture copy. The production
/// reader still validates all package content; job/corpus/checkpoint/attachment bytes are untouched.
enum Task10FixtureDocumentIdentity {
    enum InvalidManifest: Error { case unsupported, ambiguous }

    static func isolatedManifest(from data: Data) throws -> Data {
        guard let original = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              original["formatIdentifier"] as? String == "org.macscope.workspace-package",
              original["formatVersion"] as? Int == 3,
              let document = original["documentID"] as? String,
              let workspace = original["workspaceUUID"] as? String,
              UUID(uuidString: document) == UUID(uuidString: "10000000-0000-0000-0000-000000000001"),
              UUID(uuidString: workspace) == UUID(uuidString: "10000000-0000-0000-0000-000000000002"),
              let assistant = original["assistantSessionRecords"] as? [Any], assistant.isEmpty,
              let runtime = original["runtimeAuthorityRecords"] as? [Any], runtime.isEmpty,
              let text = String(data: data, encoding: .utf8) else {
            throw InvalidManifest.unsupported
        }
        // JSONSerialization accepts duplicate object keys. Reject them, including escaped aliases,
        // before identifying any replacement range. Syntax validity was established above.
        try rejectDuplicateKeys(in: data)
        let replacements = ["documentID": UUID().uuidString, "workspaceUUID": UUID().uuidString]
        let result = NSMutableString(string: text)
        var ranges: [(NSRange, String)] = []
        for (key, value) in replacements {
            let pattern = "\"\(key)\"\\s*:\\s*\"([0-9A-Fa-f-]{36})\""
            let expression = try NSRegularExpression(pattern: pattern)
            let matches = expression.matches(in: text, range: NSRange(location: 0, length: result.length))
            guard matches.count == 1, let match = matches.first else {
                throw InvalidManifest.ambiguous
            }
            ranges.append((match.range(at: 1), value))
        }
        for (range, value) in ranges.sorted(by: { $0.0.location > $1.0.location }) {
            result.replaceCharacters(in: range, with: value)
        }
        let output = Data((result as String).utf8)
        var expected = original
        for (key, value) in replacements { expected[key] = value }
        guard let actual = try JSONSerialization.jsonObject(with: output) as? [String: Any],
              NSDictionary(dictionary: actual).isEqual(to: expected) else {
            throw InvalidManifest.ambiguous
        }
        return output
    }

    private static func rejectDuplicateKeys(in data: Data) throws {
        let bytes = Array(data)
        var frames: [Set<String>?] = []
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case 123: frames.append([]) // object
            case 91: frames.append(nil) // array
            case 125, 93: _ = frames.popLast()
            case 34:
                let start = index
                index += 1
                while index < bytes.count {
                    if bytes[index] == 92 { index += 2; continue }
                    if bytes[index] == 34 { break }
                    index += 1
                }
                guard index < bytes.count else { throw InvalidManifest.ambiguous }
                var next = index + 1
                while next < bytes.count, [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
                if next < bytes.count, bytes[next] == 58 {
                    guard let key = try JSONSerialization.jsonObject(
                        with: Data(bytes[start...index]), options: .fragmentsAllowed
                    ) as? String, var keys = frames.last ?? nil,
                    keys.insert(key).inserted else { throw InvalidManifest.ambiguous }
                    frames[frames.count - 1] = keys
                }
            default: break
            }
            index += 1
        }
    }
}
