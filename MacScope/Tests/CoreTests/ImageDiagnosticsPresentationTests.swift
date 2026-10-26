import Foundation
import XCTest
@testable import MacScope

/// HS-13 diagnostics UI (U6b): the metadata walks' graded failures reach the app as per-image
/// diagnostics, and the inspector and Problems sheet present every image's loader findings.
final class ImageDiagnosticsPresentationTests: XCTestCase {
    private func metadata(_ grade: MetadataParseDiagnostic.Grade, _ address: UInt64) -> MetadataParseDiagnostic {
        MetadataParseDiagnostic(grade: grade, address: address, message: "_$s4Name read from the file")
    }

    func testGradedMetadataFailuresBecomeBoundedFindingsWithAppOwnedText() {
        let findings = MachOLoaderFinding.metadataParseFindings(
            swift: [metadata(.abandonedList, 0x10), metadata(.abandonedList, 0x10), metadata(.walkCapped, 0x20)],
            objectiveC: [metadata(.skippedItem, 0x30), metadata(.labelledUnknownKind, 0x40)]
        )
        XCTAssertEqual(findings.map(\.kind), [.metadataAbandonedList, .metadataWalkCapped, .metadataSkippedItem, .metadataUnknownKind],
                       "One finding per kind and address")
        XCTAssertTrue(findings.allSatisfy { $0.kind.isMetadataParse && !$0.kind.isChainedFixups })
        XCTAssertFalse(findings.contains { $0.message.contains("_$s4Name") }, "Parser text can quote file bytes; findings never do")
        XCTAssertEqual(findings[0].message, "Swift metadata: the parser abandoned a list after an unreadable descriptor at 0x10.")
        XCTAssertTrue(findings[2].message.hasPrefix("Objective-C metadata:"))

    }

    func testEachSourceGetsHalfTheCapAndSaysHowManyAreNotListed() {
        let half = MachOLoaderFinding.maximumPerImage / 2
        let noisySwift = (0..<200).map { metadata(.skippedItem, UInt64($0) * 8) }
        let findings = MachOLoaderFinding.metadataParseFindings(
            swift: noisySwift, objectiveC: [metadata(.abandonedList, 0x9000)], objectiveCDropped: 3)
        XCTAssertEqual(findings.count, half + 1, "A noisy Swift walk can't crowd out Objective-C")
        XCTAssertTrue(findings[half - 1].message.hasSuffix(" \(200 - half) more Swift metadata issues are not listed."))
        XCTAssertTrue(findings[half].message.hasSuffix(" 3 more Objective-C metadata issues are not listed."),
                      "The parser log's own drop count is reported")
        XCTAssertFalse(MachOLoaderFinding.metadataParseFindings(swift: [metadata(.walkCapped, 0x10)], objectiveC: [])[0]
            .message.contains("not listed"))
    }

    /// The whole path the lead asked to pin: parser diagnostic → loader finding → collector →
    /// worker payload → app-side snapshot.
    func testAMetadataFailureArrivesAppSideAsAnImageDiagnostic() throws {
        let finding = try XCTUnwrap(MachOLoaderFinding.metadataParseFindings(
            swift: [metadata(.abandonedList, 0x1_0000_4000)], objectiveC: []).first)
        let loaderFinding = MachOBinaryLoader.loaderFinding(finding)
        XCTAssertEqual(loaderFinding.category, .metadataParseIssue)
        let diagnostics = AnalysisDiagnosticsCollector().collect(.init(
            instructions: [], controlFlowEdges: [], xrefs: [], sections: [], loaderFindings: [loaderFinding]))
        let diagnostic = try XCTUnwrap(diagnostics.first)
        XCTAssertEqual(diagnostic.kind, .metadataParseIssue)
        XCTAssertEqual(diagnostic.provenance, .loader)
        XCTAssertEqual(diagnostic.address, 0x1_0000_4000)

        let snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [.primary: ImageAnalysis(diagnostics: diagnostics)])
        let wire = try JSONEncoder().encode(AnalysisPayloadCodec.payload(from: snapshot))
        let received = AnalysisPayloadCodec.snapshot(from: try JSONDecoder().decode(AnalysisResultPayload.self, from: wire))
        XCTAssertEqual(received.analysis(in: .primary)?.diagnostics, diagnostics)
    }

    func testADiagnosticOfAnUnknownKindIsDroppedNotTheWholePayload() throws {
        let finding = try XCTUnwrap(MachOLoaderFinding.metadataParseFindings(
            swift: [metadata(.walkCapped, 0x1_0000_4000)], objectiveC: []).first)
        let diagnostics = AnalysisDiagnosticsCollector().collect(.init(
            instructions: [], controlFlowEdges: [], xrefs: [], sections: [],
            loaderFindings: [MachOBinaryLoader.loaderFinding(finding)]))
        let snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [.primary: ImageAnalysis(diagnostics: diagnostics)])
        let wire = try JSONEncoder().encode(AnalysisPayloadCodec.payload(from: snapshot))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        var entries = try XCTUnwrap(json["diagnostics"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        var future = entries[0]
        future["kind"] = "aKindFromALaterBuild"
        entries.append(future)
        json["diagnostics"] = entries
        let decoded = try JSONDecoder().decode(AnalysisResultPayload.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(AnalysisPayloadCodec.snapshot(from: decoded).analysis(in: .primary)?.diagnostics, diagnostics)
    }

    private func loaderDiagnostics() throws -> [AnalysisDiagnostic] {
        let findings = MachOLoaderFinding.metadataParseFindings(
            swift: (0..<7).map { metadata(.skippedItem, 0x1_0000_4000 + UInt64($0) * 8) }, objectiveC: [])
            + [MachOLoaderFinding(kind: .unwindFunctionStartNotInFunctionStarts, address: 0x1_0000_8000, value: nil,
                                  message: "LC_FUNCTION_STARTS omits a start.")]
        return AnalysisDiagnosticsCollector().collect(.init(
            instructions: [], controlFlowEdges: [], xrefs: [], sections: [],
            loaderFindings: findings.map(MachOBinaryLoader.loaderFinding)))
    }

    func testTheInspectorGroupsLoaderFindingsByKindAndShowsTheFirstFew() throws {
        let groups = ImageDiagnosticsInspectorSection.groups(for: try loaderDiagnostics())
        XCTAssertEqual(groups.map(\.kind), [.functionStartsDisagreement, .metadataParseIssue], "In Kind order")
        XCTAssertEqual(groups[1].total, 7)
        XCTAssertEqual(groups[1].shown.count, ImageDiagnosticsInspectorSection.rowsPerKind)
        XCTAssertEqual(groups[1].hidden, 2)
        XCTAssertEqual(groups[1].shown.map(\.address), groups[1].shown.map(\.address).sorted())
        XCTAssertEqual(ImageDiagnosticsInspectorSection.groups(for: []), [])
    }

    func testProblemsAreGroupedByImage() throws {
        let diagnostics = try loaderDiagnostics()
        let primary = BinaryImage(id: UUID(), name: "App", path: "", kind: "fixture", architecture: "arm64")
        var snapshot = WorkspaceSnapshot(binaries: [primary], analysisBySlot: [.primary: ImageAnalysis(diagnostics: diagnostics)])
        var model = ProblemsViewModel(snapshot: snapshot)
        XCTAssertEqual(model.sections.map(\.title), ["App"])
        XCTAssertFalse(model.showsImageHeaders, "One image: no headers")
        XCTAssertEqual(model.rows.count, diagnostics.count)

        let other = ImageSlot(rawValue: ImageSlot.primary.rawValue + 1)
        snapshot.analysisBySlot[other] = ImageAnalysis(diagnostics: Array(diagnostics.prefix(1)))
        snapshot.analysisBySlot[ImageSlot(rawValue: ImageSlot.primary.rawValue + 2)] = ImageAnalysis()
        model = ProblemsViewModel(snapshot: snapshot)
        XCTAssertEqual(model.sections.map(\.slot), [.primary, other], "Images without problems are left out")
        XCTAssertTrue(model.showsImageHeaders)
        XCTAssertEqual(model.summary, ProblemsViewModel(diagnostics: diagnostics + diagnostics.prefix(1)).summary)
    }
}
