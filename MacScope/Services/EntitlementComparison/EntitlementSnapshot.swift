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

/// An embedded declaration capture. No signing identifier or Security API origin is invented.
struct EntitlementSnapshot: Sendable {
    let source: EntitlementComparisonSource
    let requestedArchitecture: String
    let declarations: ExactDeclaredEntitlements
}

struct EntitlementComparisonSource: Equatable, Sendable {
    let slot: ImageSlot
    let path: String
    let imageUUID: UUID?
    let sliceDigest: String?
    let architecture: String?
    let generation: Phase2ReadImageIdentity
}

struct EntitlementComparisonSelection: Equatable {
    var previous: ImageSlot? { didSet { if previous != oldValue { revision = UUID() } } }
    var current: ImageSlot? { didSet { if current != oldValue { revision = UUID() } } }
    var architecture = "" { didSet { if architecture != oldValue { revision = UUID() } } }
    var revision = UUID()
}

struct EntitlementComparisonContext: Equatable {
    let selection: EntitlementComparisonSelection
    let workspace: Phase2ReadWorkspaceIdentity
    let sourceRevision: UUID
    let previous: EntitlementComparisonSource?
    let current: EntitlementComparisonSource?
    let loading: Bool
    let openRequest: UUID?
}

struct EntitlementComparisonCapture {
    let context: EntitlementComparisonContext
    let previous: EntitlementSnapshot?
    let current: EntitlementSnapshot?

    var rows: [EntitlementChange]? {
        guard !context.loading,
              context.selection.previous != context.selection.current,
              !context.selection.architecture.isEmpty,
              let old = previous?.declarations, let new = current?.declarations,
              old.state != .unavailable, new.state != .unavailable else { return nil }
        return EntitlementComparison(previous: old.values ?? EntitlementDictionary(),
                                     current: new.values ?? EntitlementDictionary()).rows
    }
}

/// Session-only projection. Every publication checks both source generations and the selection.
struct EntitlementComparisonSession {
    private(set) var capture: EntitlementComparisonCapture?
    var browser = ComparisonBrowser()

    mutating func invalidate() {
        capture = nil
        browser.replaceRows([])
    }

    @discardableResult
    mutating func publish(_ candidate: EntitlementComparisonCapture,
                          current: EntitlementComparisonContext) -> Bool {
        guard candidate.context == current, !current.loading else {
            invalidate()
            return false
        }
        capture = candidate
        browser.replaceRows(candidate.rows ?? [])
        return true
    }

    func isCurrent(_ context: EntitlementComparisonContext) -> Bool {
        capture?.context == context && !context.loading
    }
}
