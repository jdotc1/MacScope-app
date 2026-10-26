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

/// Empty-result presentation only. Counts describe the complete captured comparison.
public struct BrowserRecoveryGuidance: Sendable {
    public enum Action: Equatable, Sendable {
        case clearSearch, showAllChanges, showAllKeys
    }
    public let title: String
    public let message: String
    public let action: Action?
    public let actionLabel: String?

    init(filter: BrowserFilter, hasQuery: Bool, categoryCount: Int, keyCount: Int, changeCount: Int) {
        if keyCount == 0 {
            title = "No entitlement keys in this scope"
            message = "Both snapshots contain no entitlement keys for the requested architecture. This is a completed comparison."
            action = nil; actionLabel = nil
        } else if categoryCount > 0 && hasQuery {
            title = "No keys match the search in \(filter.label)"
            message = "Keys in this category before search: \(categoryCount). Clear the search to see them; category and sorting stay the same."
            action = .clearSearch; actionLabel = "Clear Search"
        } else {
            title = changeCount == 0 && filter == .allChanges
                ? "No entitlement-value changes in this scope"
                : "No keys in \(filter.label)"
            let target = changeCount > 0 ? "All Changes" : "All Keys"
            message = hasQuery
                ? "The category has no keys before search, and a search is also active. Clear the search and show \(target) to see available results. Sorting stays the same."
                : changeCount == 0
                    ? "The snapshots have matching entitlement values. Show All Keys to inspect unchanged keys (\(keyCount)). Sorting stays the same."
                    : "Changes in the complete comparison: \(changeCount). Show All Changes to see them. Sorting stays the same."
            action = changeCount > 0 ? .showAllChanges : .showAllKeys
            actionLabel = (hasQuery ? "Clear Search and Show " : "Show ") + target
        }
    }
}
