#if canImport(SwiftUI)
import SwiftUI

/// Optional read-only surface. No target launch, permissions, automation, or
/// accessibility-service integration. MacScope owns window and worker policy.
public struct RecoveryInspectorView: View {
    private let envelope: AnalysisEnvelope
    @State private var selection: String = "facts"
    public init(envelope: AnalysisEnvelope) { self.envelope = envelope }
    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Text("Facts (\(envelope.facts.count))").tag("facts")
                Text("Functions (\(envelope.functions.count))").tag("functions")
                Text("Unresolved (\(envelope.frontier.count))").tag("frontier")
            }
            .navigationTitle("Recovery evidence")
        } detail: {
            VStack(alignment: .leading, spacing: 12) {
                Text(envelope.imageKey).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text("Analysis complete; whole-application recovery not established.").font(.callout)
                ScrollView {
                    Text(renderedSelection).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding()
        }
    }
    private var renderedSelection: String {
        let values = selection == "frontier" ? envelope.frontier : (selection == "functions" ? envelope.functions : envelope.facts)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(values) else { return "Unable to render structured evidence." }
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
