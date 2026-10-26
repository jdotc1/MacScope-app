/*
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

public enum ChangeKind: String, CaseIterable, Sendable, Encodable {
    case added, removed, changed, unchanged
    public var label: String { rawValue.capitalized }
}

public struct EntitlementChange: Sendable, Encodable, Identifiable {
    public let key: String
    public let kind: ChangeKind
    public let previous: EntitlementValue?
    public let current: EntitlementValue?
    /// SwiftUI's String IDs must not merge canonically equivalent Unicode keys.
    public var id: String { Data(key.utf8).base64EncodedString() }
}

public struct EntitlementComparison: Sendable {
    public let rows: [EntitlementChange]
    public var changes: [EntitlementChange] { rows.filter { $0.kind != .unchanged } }

    public init(previous: EntitlementDictionary, current: EntitlementDictionary) {
        // Merge sorted byte-identity keys without converting back to Dictionary<String, ...>.
        var rows: [EntitlementChange] = []
        let old = previous.entries, new = current.entries
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i == old.count {
                rows.append(.init(key: new[j].key, kind: .added, previous: nil, current: new[j].value))
                j += 1
            } else if j == new.count {
                rows.append(.init(key: old[i].key, kind: .removed, previous: old[i].value, current: nil))
                i += 1
            } else if old[i].key.utf8.elementsEqual(new[j].key.utf8) {
                rows.append(.init(key: old[i].key, kind: old[i].value == new[j].value ? .unchanged : .changed,
                                  previous: old[i].value, current: new[j].value))
                i += 1; j += 1
            } else if old[i].key.utf8.lexicographicallyPrecedes(new[j].key.utf8) {
                rows.append(.init(key: old[i].key, kind: .removed, previous: old[i].value, current: nil))
                i += 1
            } else {
                rows.append(.init(key: new[j].key, kind: .added, previous: nil, current: new[j].value))
                j += 1
            }
        }
        self.rows = rows
    }
}
