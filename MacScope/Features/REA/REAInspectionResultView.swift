import Foundation
import SwiftUI
import LumenUI

/// Built once from an already accepted result, outside SwiftUI body evaluation.
/// These display values are not a substitute for the accepted evidence payload.
struct REAInspectionResultPresentation: Sendable {
    enum Failure: Error { case invalidResult }
    enum Tone: Equatable, Sendable { case neutral, positive, warning }
    struct Row: Identifiable, Sendable {
        let id: String
        let title: String
        let detail: String
        let status: String
        let tone: Tone
    }
    struct Section: Identifiable, Sendable {
        let id: String
        let title: String
        let rows: [Row]
        let total: Int
    }
    let title: String
    let operationTitle: String
    let summary: String
    let explanation: String
    let sections: [Section]
    let coverage: [Row]
    let provenance: [Row]

    static func make(operation: REAInspectionOperation, title: String, resultData: Data,
                     coverage suppliedCoverage: [String] = [], provenance suppliedProvenance: [String] = []) throws -> Self {
        guard resultData.count <= REAInspectionLimits.maximumResponseBytes,
              let envelope = try JSONSerialization.jsonObject(with: resultData) as? [String: Any] else { throw Failure.invalidResult }
        var provenance = suppliedProvenance.enumerated().map { Row(id: "provided:\($0.offset)", title: "Source", detail: $0.element, status: "", tone: .neutral) }
        let result: [String: Any]
        if envelope["ok"] != nil {
            guard envelope["ok"] as? Bool == true, envelope["operation"] as? String == operation.rawValue,
                  let value = envelope["result"] as? [String: Any] else { throw Failure.invalidResult }
            result = value
            for key in ["requestID", "implementationIdentity"] {
                if let value = envelope[key] as? String {
                    provenance.append(Row(id: key, title: key == "requestID" ? "Request" : "Implementation", detail: value, status: "", tone: .neutral))
                }
            }
        } else { result = envelope }
        var coverage = suppliedCoverage.enumerated().map { Row(id: "provided:\($0.offset)", title: "Coverage", detail: $0.element, status: "", tone: .neutral) }
        var sections: [Section] = []
        let operationTitle: String
        let summary: String
        let explanation: String
        switch operation {
        case .nativeApplication:
            operationTitle = "Native application"
            guard let bundles = result["bundles"] as? [[String: Any]], let trace = result["trace"] as? [String: Any],
                  let edges = trace["edges"] as? [[String: Any]], let traceCoverage = trace["coverage"] as? [String: Any],
                  let state = traceCoverage["status"] as? String, ["complete", "partial"].contains(state) else { throw Failure.invalidResult }
            summary = state == "complete" ? "Static application analysis complete" : "Static application analysis has gaps"
            explanation = "Bundle roles and load paths come from captured metadata. Conditional, unresolved, and undetermined loads retain those states."
            sections.append(section("bundles", title: "Bundles", values: bundles) { value, id in
                Row(id: id, title: text(value["path"]), detail: "Layout: \(text(value["layout"]))", status: text(value["role"]), tone: .neutral)
            })
            sections.append(section("loads", title: "Dependency load paths", values: edges) { value, id in
                let resolution = value["resolution"] as? [String: Any] ?? [:]
                let state = text(resolution["status"])
                let ancestry = (value["via"] as? [String] ?? []).joined(separator: " → ")
                let detail = "Loader: \(text(value["loader"]))\nProcess root: \(text(value["root"]))\nResolved image: \(text(resolution["image"]))" +
                    (ancestry.isEmpty ? "" : "\nAncestry: \(ancestry)") + ((value["loader_conditional"] as? Bool == true) ? "\nLoader is conditional" : "")
                return Row(id: id, title: text(value["install_name"]), detail: detail, status: state, tone: state == "resolved" ? .positive : .warning)
            })
            let findings = trace["findings"] as? [[String: Any]] ?? []
            sections.append(section("findings", title: "Derived findings", values: findings) { value, id in
                Row(id: id, title: text(value["kind"]), detail: text(value["explanation"]), status: "Derived", tone: .neutral)
            })
            coverage.append(Row(id: "trace", title: "Load-path coverage", detail: "Unparsed images: \((traceCoverage["unparsed_images"] as? [String] ?? []).joined(separator: ", "))\nRoots without an architecture: \((traceCoverage["roots_without_architecture"] as? [String] ?? []).joined(separator: ", "))", status: state, tone: state == "complete" ? .positive : .warning))
            appendLimitations(trace["limitations"], prefix: "native", to: &coverage)
        case .uiResources:
            operationTitle = "Compiled UI resources"
            guard let analysis = result["analysis"] as? [String: Any], let documents = analysis["documents"] as? [[String: Any]],
                  let graph = analysis["graph"] as? [String: Any], let nodes = graph["nodes"] as? [[String: Any]],
                  let edges = graph["edges"] as? [[String: Any]], let records = result["coverage"] as? [[String: Any]] else { throw Failure.invalidResult }
            summary = "\(documents.count) compiled UI document\(documents.count == 1 ? "" : "s") inspected"
            explanation = "Handler links are static candidates. Runtime dispatch was not observed; duplicate Objective-C candidates remain ambiguous. Missing catalog metadata does not establish asset absence."
            sections.append(section("documents", title: "Decoded documents", values: documents) { value, id in
                Row(id: id, title: text(value["relative_path"]), detail: "Archive SHA-256: \(text(value["archive_sha256"]))\nObjects: \(text(value["object_count"])) · Connections: \(text(value["connection_count"]))", status: text(value["document_kind"]), tone: .neutral)
            })
            var names: [String: String] = [:]
            for node in nodes { if let id = node["id"] as? String { names[id] = node["name"] as? String ?? id } }
            let dispatch = edges.filter { $0["relation"] as? String == "objc_dispatch" }
            sections.append(section("handlers", title: "Static handler candidates", values: dispatch) { value, id in
                let state = text(value["resolution"])
                let from = value["from"] as? String ?? ""
                let to = value["to"] as? String ?? ""
                return Row(id: id, title: names[from] ?? from, detail: (names[to] ?? "No unique implementation") + "\n" + text(value["reason"]),
                           status: state == "resolved" ? "Candidate handler" : state == "inferred" ? "Inferred candidate" : "Ambiguous or unresolved", tone: .neutral)
            })
            let candidates = result["dispatchCandidates"] as? [[String: Any]] ?? []
            sections.append(section("objc", title: "Captured Objective-C candidates", values: candidates) { value, id in
                Row(id: id, title: "\(text(value["class_name"])) · \(text(value["selector"]))", detail: "Implementation: \(text(value["implementation_address"]))", status: text(value["method_type"]), tone: .neutral)
            })
            if let catalog = result["assetCatalogs"] as? [String: Any] {
                let assets = catalog["records"] as? [[String: Any]] ?? []
                sections.append(section("assets", title: "Captured catalog records", values: assets) { value, id in
                    Row(id: id, title: text(value["asset_name"]), detail: "Catalog: \(text(value["catalog_path"]))\nRendition: \(text(value["rendition_name"]))", status: text(value["kind"]), tone: .neutral)
                })
                if catalog["truncated"] as? Bool == true { coverage.append(Row(id: "catalog-page", title: "Catalog page", detail: "Additional catalog records exist outside this result page.", status: "Partial", tone: .warning)) }
            }
            appendCoverage(records, prefix: "ui", to: &coverage)
            appendCoverage(graph["coverage"] as? [[String: Any]] ?? [], prefix: "graph", to: &coverage)
            appendLimitations(analysis["limitations"], prefix: "ui", to: &coverage)
            if let target = analysis["target_sha256"] as? String { provenance.append(Row(id: "target", title: "Selected image SHA-256", detail: target, status: "", tone: .neutral)) }
            if let snapshot = result["snapshotID"] as? String { provenance.append(Row(id: "snapshot", title: "Snapshot", detail: snapshot, status: "", tone: .neutral)) }
        case .processComparison:
            operationTitle = "Execution comparison"
            guard let state = result["status"] as? String, let dimensions = result["dimensions"] as? [[String: Any]],
                  ["equal", "different", "unknown", "nonComparable"].contains(state) else { throw Failure.invalidResult }
            switch state {
            case "equal": summary = "Captured behavior matches"
            case "different": summary = "Captured behavior differs"
            case "nonComparable": summary = "Captures are not comparable"
            default: summary = "Comparison is incomplete"
            }
            explanation = "Only admitted captured dimensions are compared. Missing observations, incomplete execution, truncation, or uncertain cleanup remain unknown."
            sections.append(section("dimensions", title: "Compared dimensions", values: dimensions) { value, id in
                let status = text(value["status"])
                return Row(id: id, title: text(value["source"]), detail: comparisonDetail(value, status: status), status: status == "equal" ? "Matching" : status == "different" ? "Different" : "Unknown", tone: status == "equal" ? .positive : .warning)
            })
            if let reason = result["reason"] as? String { coverage.append(Row(id: "comparison-reason", title: "Comparability", detail: reason, status: state, tone: .warning)) }
            for key in ["leftCaptureID", "rightCaptureID", "scenarioSHA256"] {
                if let value = result[key] as? String { provenance.append(Row(id: key, title: key, detail: value, status: "", tone: .neutral)) }
            }
            if let hashes = result["executableSHA256"] as? [String] {
                provenance.append(Row(id: "executables", title: "Actual executable SHA-256 identities", detail: hashes.joined(separator: "\n"), status: "", tone: .neutral))
            }
        }
        return Self(title: title, operationTitle: operationTitle, summary: summary, explanation: explanation,
                    sections: sections, coverage: coverage, provenance: provenance)
    }

    private static func comparisonDetail(_ value: [String: Any], status: String) -> String {
        let comparison = value["comparison"] as? [String: Any] ?? [:]
        let divergence = comparison["first_divergence"] as? [String: Any] ?? [:]
        if divergence["status"] as? String == "found" {
            return "First divergence at observation \(text(divergence["index"]))\nLeft: \(fragment(divergence["left"]))\nRight: \(fragment(divergence["right"]))"
        }
        if let reason = divergence["reason"] as? String { return reason }
        return status == "unknown" ? "Coverage is insufficient to establish matching behavior." : "Compared under the committed scenario and normalization."
    }
    private static func fragment(_ value: Any?) -> String {
        guard let value else { return "Unknown" }
        let rendered: String
        if let string = value as? String { rendered = string }
        else if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), let string = String(data: data, encoding: .utf8) { rendered = string }
        else { return "Unknown" }
        if rendered.count > 4096 { return String(rendered.prefix(4096)) + "\n[Display shortened; the accepted payload retains the full observation.]" }
        return rendered
    }
    private static func text(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "Unknown" }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return "Unknown"
    }
    private static func section(_ id: String, title: String, values: [[String: Any]], project: ([String: Any], String) -> Row) -> Section {
        Section(id: id, title: title, rows: values.prefix(500).enumerated().map { project($0.element, id + ":" + String($0.offset)) }, total: values.count)
    }
    private static func appendCoverage(_ records: [[String: Any]], prefix: String, to rows: inout [Row]) {
        for (index, value) in records.prefix(500).enumerated() {
            let status = text(value["status"])
            rows.append(Row(id: "\(prefix):\(index)", title: text(value["facet"]),
                            detail: "\(text(value["reason"]))\nExamined: \(text(value["examined"])) · Omitted: \(text(value["omitted"]))",
                            status: status, tone: status == "complete" ? .positive : .warning))
        }
        if records.count > 500 { rows.append(Row(id: prefix + ":more", title: "Additional coverage records", detail: "Showing 500 of \(records.count) records; the accepted payload retains all records.", status: "Display limit", tone: .neutral)) }
    }
    private static func appendLimitations(_ value: Any?, prefix: String, to rows: inout [Row]) {
        let limitations = value as? [String] ?? []
        for (index, item) in limitations.prefix(500).enumerated() {
            rows.append(Row(id: prefix + ":limitation:\(index)", title: "Limitation", detail: item, status: "", tone: .neutral))
        }
        if limitations.count > 500 { rows.append(Row(id: prefix + ":limitations-more", title: "Additional limitations", detail: "Showing 500 of \(limitations.count) limitations; the accepted payload retains all records.", status: "Display limit", tone: .neutral)) }
    }
}

struct REAInspectionResultView: View {
    let presentation: REAInspectionResultPresentation
    /// U9-4e: the result's three views on a Lumen tab strip over a hairline.
    enum ResultTab: String, CaseIterable { case findings = "Findings", coverage = "Coverage", provenance = "Provenance" }
    @State private var tab: ResultTab = .findings
    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s6) {
            REAResultHeader(title: presentation.title, operation: presentation.operationTitle, summary: presentation.summary, explanation: presentation.explanation)
            LumenTabbedBox(selection: $tab, tabs: ResultTab.allCases, style: .header, title: \.rawValue) { tab in
                switch tab {
                case .findings: REAResultFindings(sections: presentation.sections)
                case .coverage: REAResultRows(rows: presentation.coverage, emptyMessage: "No coverage notes were supplied with this accepted result.")
                case .provenance: REAResultRows(rows: presentation.provenance, emptyMessage: "No additional provenance was supplied.")
                }
            }
        }
        .padding(Lumen.Space.s6)
        .textSelection(.enabled)
    }
}

private struct REAResultHeader: View {
    let title: String
    let operation: String
    let summary: String
    let explanation: String
    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            Text(title).font(.headline)
            Text(operation).font(.subheadline).foregroundStyle(.secondary)
            Text(summary).font(.body.weight(.semibold))
            Text(explanation).font(.callout).foregroundStyle(.secondary)
        }
    }
}
private struct REAResultFindings: View {
    let sections: [REAInspectionResultPresentation.Section]
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Lumen.Space.s7) {
                ForEach(sections) { section in
                    REAResultSection(section: section)
                }
            }.padding(Lumen.Space.s6)
        }
    }
}
private struct REAResultSection: View {
    let section: REAInspectionResultPresentation.Section
    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s5) {
            Text("\(section.title) (\(section.total))").font(.headline)
            if section.rows.isEmpty { Text("No records in this accepted result.").foregroundStyle(.secondary) }
            ForEach(section.rows) { row in REAResultRow(row: row) }
            if section.total > section.rows.count {
                Text("Showing \(section.rows.count) of \(section.total) records; the accepted payload retains all records.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
private struct REAResultRows: View {
    let rows: [REAInspectionResultPresentation.Row]
    let emptyMessage: String
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Lumen.Space.s5) {
                if rows.isEmpty { Text(emptyMessage).foregroundStyle(.secondary) }
                ForEach(rows) { row in REAResultRow(row: row) }
            }.padding(Lumen.Space.s6)
        }
    }
}
private struct REAResultRow: View {
    let row: REAInspectionResultPresentation.Row
    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title).font(.body.weight(.medium))
                Spacer(minLength: Lumen.Space.s5)
                Text(row.status).font(.caption).foregroundStyle(row.tone == .warning ? Color.lumen(.statusWarning) : row.tone == .positive ? Color.lumen(.statusSuccess) : Color.secondary)
            }
            Text(row.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
