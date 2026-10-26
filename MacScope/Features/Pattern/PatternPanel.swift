import Foundation
import SwiftUI

@MainActor
final class PatternPaneInputState: ObservableObject {
    @Published var entry: PatternSourceCatalog.Entry = .pngIHDR
    @Published var userText = ""
    @Published var isExpanded = false
    @Published var recordStart = ""
    @Published var byteCount = ""
    var source: String { (try? PatternSourceCatalog.source(for: entry, userText: userText)) ?? "" }
    var sourceIdentity: String { entry.rawValue }
    var record: Range<Int> {
        guard let start = Int(recordStart), let count = Int(byteCount), start >= 0, count > 0,
              start <= Int.max - count else { return 0..<0 }
        return start..<(start + count)
    }
}

/// Presentation only: the owner is the sole admission and navigation authority.
struct PatternPanel: View {
    static let capturedBytesLabel = "Captured rendered bytes"
    @ObservedObject var owner: PatternInterpretationOwner
    @ObservedObject var input: PatternPaneInputState
    let frame: PatternPaneFrame
    @State private var expandedIDs: Set<UInt64> = []

    static func detail(for field: PatternField) -> String {
        var parts = [field.backing.rawValue, "\(field.declaredSize) bytes"]
        if let bits = field.bits {
            parts.append("bits \(bits.offsetWithinFirstByte) + \(bits.count), \(bits.numbering.rawValue)")
        }
        if field.childCount > 0 || field.childrenTruncated {
            parts.append("\(field.childCount) emitted children" + (field.childrenTruncated ? " — truncated" : ""))
        }
        parts.append(contentsOf: field.ranges.map { "selection +\($0.selectionOffset), \($0.length) bytes" })
        return parts.joined(separator: " · ")
    }

    static func visible(_ field: PatternField, nodes: [PatternField], expanded: Set<UInt64>) -> Bool {
        var parent = field.parentID
        var remaining = nodes.count
        while let id = parent {
            guard remaining > 0, expanded.contains(id), let node = nodes.first(where: { $0.id == id }) else { return false }
            remaining -= 1
            parent = node.parentID
        }
        return true
    }

    private func binding<T>(_ keyPath: ReferenceWritableKeyPath<PatternPaneInputState, T>) -> Binding<T> {
        Binding(get: { input[keyPath: keyPath] }, set: { value in
            owner.invalidate()
            input[keyPath: keyPath] = value
        })
    }

    var body: some View {
        let source = input.source
        let record = input.record
        let nodes = owner.nodesIfCurrent(frame: frame, record: record, source: source, sourceIdentity: input.sourceIdentity)
        let diagnostics = owner.diagnosticsIfCurrent(frame: frame, record: record, source: source,
            sourceIdentity: input.sourceIdentity)
        DisclosureGroup("Pattern", isExpanded: binding(\.isExpanded)) {
            VStack(alignment: .leading, spacing: 8) {
                Text(Self.capturedBytesLabel).font(.caption)
                Picker("Source", selection: binding(\.entry)) {
                    ForEach(PatternSourceCatalog.Entry.allCases) { entry in Text(entry.title).tag(entry) }
                }
                if input.entry == .userText {
                    TextEditor(text: binding(\.userText)).frame(height: 80)
                    Text("Maximum 32,768 UTF-8 bytes").font(.caption)
                } else {
                    DisclosureGroup("Inspect source") {
                        ScrollView {
                            Text(verbatim: source).font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 160)
                    }
                }
                HStack {
                    TextField("Record start", text: binding(\.recordStart))
                    TextField("Byte count", text: binding(\.byteCount))
                    Button("Interpret selected record") {
                        guard let capture = try? PatternAppCapture(frame: frame, record: record,
                            source: source, sourceIdentity: input.sourceIdentity) else { return }
                        expandedIDs.removeAll()
                        owner.start(capture: capture)
                    }
                    .disabled(!owner.available || record.isEmpty || record.upperBound > frame.bytes.count || source.isEmpty)
                    if owner.phase == .running { Button("Cancel") { owner.cancel() } }
                }
                Text(sourceStatus ?? Self.copy(for: owner.phase)).font(.caption)
                ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                    Text(verbatim: "\(diagnostic.severity.rawValue): \(diagnostic.message)").font(.caption)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(nodes.filter { Self.visible($0, nodes: nodes, expanded: expandedIDs) }) { field in
                            let generation = owner.generation
                            let canReveal = owner.canReveal(fieldID: field.id, generation: generation)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    if field.childCount > 0 {
                                        Button(expandedIDs.contains(field.id) ? "−" : "+") {
                                            if !expandedIDs.insert(field.id).inserted { expandedIDs.remove(field.id) }
                                        }
                                    }
                                    Text(field.name); Text(field.typeName); Text(field.value)
                                    Button("Reveal") { _ = owner.reveal(fieldID: field.id, generation: generation) }
                                        .disabled(!canReveal)
                                }
                                Text(Self.detail(for: field)).font(.caption)
                                if !canReveal { Text("No unique backed range").font(.caption) }
                            }.padding(.leading, CGFloat(field.depth) * 12)
                        }
                    }
                }.frame(maxHeight: 220)
            }.padding(8)
        }
        .onChange(of: owner.generation) { _, _ in expandedIDs.removeAll() }
    }

    private var sourceStatus: String? {
        do { _ = try PatternSourceCatalog.source(for: input.entry, userText: input.userText); return nil }
        catch PatternInterpretationError.nativeUnavailable { return "Pattern interpretation is unavailable." }
        catch { return "This selection or pattern could not be interpreted safely." }
    }

    static func copy(for phase: PatternPhase) -> String {
        switch phase {
        case .empty: "Select a record in the current hex window, choose a pattern, then Interpret."
        case .running: "Interpreting captured rendered bytes…"
        case .completed: "Interpretation complete — captured rendered bytes."
        case .partial: "Partial interpretation — some fields are unavailable."
        case .timeout: "Interpretation timed out. Worker recovery is pending."
        case .unavailable: "Pattern interpretation is unavailable."
        case .refused: "This selection or pattern could not be interpreted safely."
        case .cancelled: "Interpretation cancelled."
        case .stale: "Selection changed. Interpret again to refresh fields."
        }
    }
}
