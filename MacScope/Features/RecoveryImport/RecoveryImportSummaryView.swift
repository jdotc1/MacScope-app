import SwiftUI

/// Read-only presentation of the host's admitted import. It grants no execution authority.
struct RecoveryImportSummaryView: View {
    let presentation: RecoveryReportAdmission.Presentation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Imported recovery evidence").fontWeight(.semibold)
            Text("Admitted facts: \(presentation.factCount)")
            Text(presentation.sourceValidation == "not_run"
                 ? "Generated-source validation: not run"
                 : "Producer-reported source validation: \(presentation.sourceValidation)")
            Text("Whole-application recovery is not established.")
            Text("Unresolved items: \(presentation.unresolved.count)").fontWeight(.semibold)
            ScrollView {
                Text(presentation.unresolved.joined(separator: "\n\n"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .font(.custom("Arial", size: 10))
        .padding()
    }
}
