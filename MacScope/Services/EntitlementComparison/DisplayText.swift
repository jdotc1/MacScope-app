/*
Ported from EntitlementDiff.

MIT License

Copyright (c) 2026 EntitlementDiff contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

import Foundation

public enum DisplayText {
    /// Escape terminal controls and directional-formatting characters. Ordinary
    /// non-ASCII text is preserved; this is not a Unicode confusable detector.
    public static func escaped(_ string: String) -> String {
        var output = ""
        for scalar in string.unicodeScalars {
            let value = scalar.value
            if value < 0x20 || (0x7F...0x9F).contains(value) || value == 0x061C
                || value == 0x200E || value == 0x200F || (0x2028...0x202E).contains(value)
                || (0x2066...0x2069).contains(value) {
                output += String(format: "\\u{%04X}", value)
            } else if scalar == "\\" {
                output += "\\\\"
            } else {
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }

    public static func quoted(_ string: String) -> String {
        "\"" + escaped(string).replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

extension EntitlementValue {
    public var rendered: String {
        switch self {
        case .boolean(let value): value ? "true" : "false"
        case .integer(let value): "integer(\(value))"
        case .unsignedInteger(let value): "integer(\(value))"
        case .real(let value): "real(\(value))"
        case .string(let value): DisplayText.quoted(value)
        case .data(let value): "data(base64: \(value.base64EncodedString()))"
        case .date(let value): "date(referenceSeconds: \(value.timeIntervalSinceReferenceDate))"
        case .array(let values): "[" + values.map(\.rendered).joined(separator: ", ") + "]"
        case .dictionary(let dictionary):
            "{" + dictionary.entries.map { DisplayText.quoted($0.key) + ": " + $0.value.rendered }.joined(separator: ", ") + "}"
        }
    }

    /// The budget counts Unicode scalars, not grapheme clusters (a single cluster
    /// may contain arbitrarily many combining marks). At most one ellipsis is
    /// appended beyond that budget. Traversal/base64 work stops at the budget.
    public func preview(maxCharacters: Int = 160) -> String {
        guard maxCharacters > 0 else { return "…" }
        var writer = PreviewWriter(remaining: maxCharacters)
        writer.write(self)
        return writer.output + (writer.truncated ? "…" : "")
    }
}

private struct PreviewWriter {
    var remaining: Int
    private(set) var output = ""
    private(set) var truncated = false

    mutating func append(_ string: String) {
        guard !truncated else { return }
        for scalar in string.unicodeScalars {
            guard remaining > 0 else { truncated = true; return }
            output.unicodeScalars.append(scalar)
            remaining -= 1
        }
    }

    mutating func quote(_ string: String) {
        append("\"")
        for scalar in string.unicodeScalars {
            if truncated { return }
            // Escape a single scalar instead of building an entire escaped string.
            append(scalar == "\"" ? "\\\"" : DisplayText.escaped(String(scalar)))
        }
        append("\"")
    }

    mutating func write(_ value: EntitlementValue) {
        guard !truncated else { return }
        switch value {
        case .string(let string):
            quote(string)
        case .array(let values):
            append("[")
            for (index, item) in values.enumerated() {
                if truncated { break }
                if index > 0 { append(", ") }
                write(item)
            }
            append("]")
        case .dictionary(let dictionary):
            append("{")
            for (index, entry) in dictionary.entries.enumerated() {
                if truncated { break }
                if index > 0 { append(", ") }
                quote(entry.key)
                append(": ")
                write(entry.value)
            }
            append("}")
        case .data(let data):
            append("data(base64: ")
            guard !truncated else { return }
            // Whole triples preserve the original base64 prefix without encoding
            // the rest of a potentially multi-megabyte data value. This arithmetic
            // remains below Int.max even for a caller-supplied Int.max budget.
            let bytes = min(data.count, (remaining / 4 + 1) * 3)
            append(data.prefix(bytes).base64EncodedString())
            if bytes < data.count { truncated = true }
            append(")")
        default:
            // Scalar numeric/Boolean/date representations have bounded size.
            append(value.rendered)
        }
    }
}
