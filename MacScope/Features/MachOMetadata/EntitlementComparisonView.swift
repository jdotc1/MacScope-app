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

import SwiftUI
import LumenUI

struct EntitlementComparisonView: View {
    @ObservedObject var store: WorkspaceStore
    @State private var selection = EntitlementComparisonSelection()
    @State private var session = EntitlementComparisonSession()

    private var context: EntitlementComparisonContext { store.entitlementComparisonContext(selection) }
    private var architectures: [String] { store.entitlementComparisonArchitectures }

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            Text("Compare Entitlements").font(.headline)
            Text("Embedded declarations for the explicitly selected image slots and architecture.")
                .foregroundStyle(.secondary)
            imagePicker("Previous", selection: $selection.previous)
            imagePicker("Current", selection: $selection.current)
            Picker("Architecture", selection: $selection.architecture) {
                Text("Select architecture").tag("")
                ForEach(architectures, id: \.self) { Text($0).tag($0) }
            }
            HStack {
                Button("Compare") { compare() }
                    .disabled(selection.previous == nil || selection.current == nil ||
                              selection.previous == selection.current || selection.architecture.isEmpty || context.loading)
                Button("Swap") {
                    let previous = selection.previous
                    selection.previous = selection.current
                    selection.current = previous
                    session.invalidate()
                }
                Button("Reload Declarations") {
                    session.invalidate()
                    selection.revision = UUID()
                    compare()
                }
                .disabled(selection.previous == nil || selection.current == nil || context.loading)
                Button("Clear") {
                    session.invalidate()
                    selection.revision = UUID()
                    selection.previous = nil
                    selection.current = nil
                }
            }
            if session.isCurrent(context), let capture = session.capture {
                Text(summary("Previous", capture.previous))
                Text(summary("Current", capture.current))
                if capture.rows != nil { comparisonRows }
            } else {
                Text(context.loading ? "Image source is changing. Compare again when it finishes." :
                     architectures.isEmpty ? "Comparison unavailable: the loaded slots have no supported retained architecture." :
                     "Select two loaded image slots and their common architecture, then Compare.")
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: context) { _, current in
            if !session.isCurrent(current) { session.invalidate() }
        }
        .onReceive(store.$isImporting) { if $0 { session.invalidate() } }
        .onReceive(store.$isReanalyzing) { if $0 { session.invalidate() } }
    }

    private func imagePicker(_ title: String, selection: Binding<ImageSlot?>) -> some View {
        Picker(title, selection: selection) {
            Text("Select image slot").tag(nil as ImageSlot?)
            ForEach(store.snapshot.binaries) { binary in
                Text("\(binary.name) · slot \(binary.slot.rawValue) · \(binary.architecture)")
                    .tag(Optional(binary.slot))
            }
        }
    }

    private func compare() {
        let candidate = store.captureEntitlementComparison(selection)
        session.publish(candidate, current: store.entitlementComparisonContext(selection))
    }

    private func summary(_ side: String, _ snapshot: EntitlementSnapshot?) -> String {
        guard let snapshot else { return "\(side): no image slot selected." }
        let declarations = snapshot.declarations
        let origin = declarations.format.map { "embedded \($0)" } ?? "embedded declaration inventory"
        switch declarations.state {
        case .notPresent: return "\(side): no entitlements blob present."
        case .dictionaryPresent:
            return "\(side): \(declarations.values?.entries.count ?? 0) keys, \(origin)."
        case .unavailable: return "\(side): unavailable — \(declarations.reason ?? "extraction unavailable")."
        }
    }

    private var comparisonRows: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            TextField("Filter entitlement keys", text: $session.browser.query)
                .textFieldStyle(.roundedBorder)
            Picker("Show", selection: $session.browser.filter) {
                ForEach(BrowserFilter.allCases, id: \.self) { filter in
                    Text("\(filter.label) (\(session.browser.count(filter)))").tag(filter)
                }
            }
            Text("Added \(session.browser.count(.added)) · Removed \(session.browser.count(.removed)) · Changed \(session.browser.count(.changed)) · Unchanged \(session.browser.count(.unchanged))")
                .font(.caption)
            Table(session.browser.visibleRows, selection: $session.browser.selection,
                  sortOrder: $session.browser.sortOrder) {
                TableColumn("Key", sortUsing: BrowserSort(column: .key)) { row in
                    Text(EntitlementValue.string(row.key).preview(maxCharacters: 512))
                }
                TableColumn("Change", sortUsing: BrowserSort(column: .change)) { row in
                    Text(row.kind.label)
                }
                TableColumn("Previous") { row in Text(row.previous?.preview() ?? "<absent>") }
                TableColumn("Current") { row in Text(row.current?.preview() ?? "<absent>") }
            }
            // Reviewed geometry: Lumen has no entitlement-table height equivalent.
            .frame(height: 250)
            if let guidance = session.browser.recoveryGuidance {
                Text(guidance.message).foregroundStyle(.secondary)
            }
        }
    }
}
