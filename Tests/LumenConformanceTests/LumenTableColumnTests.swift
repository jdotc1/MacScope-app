import XCTest
import SwiftUI
@testable import LumenUI
import LumenConformance

/// Table-wide column widths: a column never cuts its text while another has slack, and columns
/// collapse in their stated order. Laid out in a real window, where preferences resolve.
@MainActor final class LumenTableColumnTests: XCTestCase {
    private struct Symbol: Identifiable { let id: Int; let offset: String; let name: String; let type: String }

    private let symbols = [
        Symbol(id: 1, offset: "0x10", name: "objc_msgSend_stret", type: "unsigned long"),
        Symbol(id: 2, offset: "0x18", name: "start", type: "unsigned long long"),
    ]

    private struct FramesKey: PreferenceKey {
        static let defaultValue: [String: CGRect] = [:]
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
    }

    /// Text that fills its column and reports the column's frame, plus its own one-line width.
    private struct Probe: View {
        let key: String
        let text: String
        @Environment(\.lumenTableMeasuring) private var measuring

        var body: some View {
            Text(text).font(.system(size: 13)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if !measuring {
                        GeometryReader { proxy in Color.clear.preference(key: FramesKey.self, value: [key: proxy.frame(in: .global)]) }
                    }
                }
                .background {
                    if !measuring {
                        Text(text).font(.system(size: 13)).fixedSize().hidden().background {
                            GeometryReader { proxy in
                                Color.clear.preference(key: FramesKey.self, value: ["natural/" + key: CGRect(origin: .zero, size: proxy.size)])
                            }
                        }
                    }
                }
        }
    }

    private var table: some View {
        LumenTable(symbols, selection: .constant(nil), columns: [
            LumenTableColumn("Offset", width: 44) { Probe(key: "Offset/\($0.id)", text: $0.offset) }
                .header { Probe(key: "Offset/header", text: "OFFSET") },
            LumenTableColumn("Name") { Probe(key: "Name/\($0.id)", text: $0.name) }
                .header { Probe(key: "Name/header", text: "NAME") }
                .minWidth(72).priority(1),
            LumenTableColumn("Type") { Probe(key: "Type/\($0.id)", text: $0.type) }
                .header { Probe(key: "Type/header", text: "TYPE") }
                .minWidth(72),
        ])
    }

    private final class Recorder { var frames: [String: CGRect] = [:] }

    private func layOut<Content: View>(_ content: Content, width: CGFloat) -> [String: CGRect] {
        let recorder = Recorder()
        let root = content.frame(width: width, height: 240)
            .onPreferenceChange(FramesKey.self) { frames in MainActor.assumeIsolated { recorder.frames = frames } }
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 240),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        addTeardownBlock { @MainActor in window.close() }
        return recorder.frames
    }

    func testTypeReachesItsMinimumBeforeNameShrinksAndColumnsAlign() throws {
        for width: CGFloat in [248, 300, 400] {
            let frames = layOut(table, width: width)
            func frame(_ key: String) throws -> CGRect { try XCTUnwrap(frames[key], "\(key) at \(Int(width))") }
            func natural(_ column: String) throws -> CGFloat {
                try symbols.map { try frame("natural/\(column)/\($0.id)").width }.max() ?? 0
            }

            // Header and every row share one frame per column.
            for column in ["Offset", "Name", "Type"] {
                let header = try frame("\(column)/header")
                for symbol in symbols {
                    let cell = try frame("\(column)/\(symbol.id)")
                    XCTAssertEqual(cell.minX, header.minX, accuracy: 0.5, "\(column) row \(symbol.id) at \(Int(width))")
                    XCTAssertEqual(cell.width, header.width, accuracy: 0.5, "\(column) row \(symbol.id) at \(Int(width))")
                }
            }
            XCTAssertEqual(try frame("Offset/header").width, 44, accuracy: 0.5)

            let name = try frame("Name/header").width, type = try frame("Type/header").width
            let nameNatural = try natural("Name"), typeNatural = try natural("Type")
            XCTAssertGreaterThanOrEqual(type, 72 - 0.5, "Type keeps its minimum at \(Int(width))")
            if name < nameNatural - 0.5 {
                XCTAssertEqual(type, 72, accuracy: 0.5, "Name shrank at \(Int(width)) while Type had slack (\(type))")
            }
            switch width {
            case 248:
                XCTAssertEqual(type, 72, accuracy: 0.5, "Type collapses first")
                XCTAssertGreaterThan(name, type, "Name keeps more width than Type")
            case 400:
                XCTAssertGreaterThanOrEqual(name, nameNatural - 0.5, "Name is cut with room to spare")
                XCTAssertGreaterThanOrEqual(type, typeNatural - 0.5, "Type is cut with room to spare")
            default: break
            }
        }
    }

    func testWidthsShrinkByPriorityThenProportionally() {
        // Room for both: each gets its want plus an equal share.
        XCTAssertEqual(LumenTableLayout.widths(natural: [100, 50], minimums: [72, 72], priorities: [1, 0], available: 200), [114, 86])
        // Short: the lower priority shrinks to its minimum first.
        XCTAssertEqual(LumenTableLayout.widths(natural: [120, 110], minimums: [72, 72], priorities: [1, 0], available: 170), [98, 72])
        // Ties shrink in proportion to the width they can give.
        XCTAssertEqual(LumenTableLayout.widths(natural: [112, 92], minimums: [72, 72], priorities: [0, 0], available: 174), [92, 82])
        // Below every minimum: all shrink in proportion.
        XCTAssertEqual(LumenTableLayout.widths(natural: [120, 110], minimums: [72, 72], priorities: [1, 0], available: 72), [36, 36])
    }
}

@MainActor
final class LumenTableMinimumCharactersTests: XCTestCase {
    struct Member: Identifiable { let id: Int; let name: String; let type: String }
    let rows = [Member(id: 0, name: "_setupWindowController", type: "SampleSetupWindowController *")]

    func table() -> some View {
        LumenTable(rows, selection: .constant(nil), columns: [
            .text("Offset", width: 44, monospaced: true) { _ in "+0x8" },
            LumenTableColumn.text("Name") { $0.name }.minWidth(72).priority(1),
            LumenTableColumn.text("Type", monospaced: true) { $0.type }.minWidth(36),   // a small minimum: it gives way first
        ])
    }

    func testACellCutBelowEightCharactersIsReported() {
        let findings = LumenConformance.truncation(sizes: [CGSize(width: 190, height: 200)]) { table() }
        XCTAssertTrue(findings.contains { $0.description.contains("fewer than 8 characters show") }, "\(findings)")
    }

    func testAColumnSqueezedToNothingIsReported() {
        let rows = self.rows
        let findings = LumenConformance.truncation(sizes: [CGSize(width: 190, height: 200)]) {
            LumenTable(rows, selection: .constant(nil), columns: [
                .text("Offset", width: 44, monospaced: true) { _ in "+0x8" },
                LumenTableColumn.text("Name") { $0.name }.minWidth(72).priority(1),
                LumenTableColumn.text("Type", monospaced: true) { $0.type },
            ])
        }
        XCTAssertTrue(findings.contains { $0.description.contains("SampleSetupWindowController") }, "\(findings)")
    }

    /// Middle truncation keeps both ends: two members sharing a stem stay apart, and the floor is
    /// four characters each side of the ellipsis.
    func testMiddleTruncatedCellsKeepBothEnds() {
        let rows = [Member(id: 0, name: "triggerAnalysisOnAppear", type: "CalculatorViewModel.Mode"),
                    Member(id: 1, name: "triggerAnalysisOnChange", type: "CalculatorViewModel.Operation")]
        func table() -> some View {
            LumenTable(rows, selection: .constant(nil), columns: [
                LumenTableColumn.text("Name", truncationMode: .middle) { $0.name }.minWidth(72).priority(1),
                LumenTableColumn.text("Type", monospaced: true, truncationMode: .middle) { $0.type }.minWidth(72),
            ])
        }
        XCTAssertEqual(LumenConformance.truncation(sizes: [CGSize(width: 300, height: 200)]) { table() }.map(\.description), [])
        let squeezed = LumenConformance.truncation(sizes: [CGSize(width: 120, height: 200)]) { table() }
        XCTAssertTrue(squeezed.contains { $0.description.contains("fewer than 8 characters show") }, "\(squeezed)")
    }

    func testCellsWithRoomAreNotReported() {
        let findings = LumenConformance.truncation(sizes: [CGSize(width: 520, height: 200)]) { table() }
        XCTAssertFalse(findings.contains { $0.description.contains("fewer than 8 characters show") }, "\(findings)")
    }
}

/// A table never grows past its container: when its columns' minimums don't fit, they yield. MacScope's
/// Types inspector clipped on both edges when its members table (minimums ~272 pt) sat in ~259 pt.
@MainActor
final class LumenTableFitsItsContainerTests: XCTestCase {
    struct Member: Identifiable { let id: Int; let offset: String; let name: String; let type: String }
    struct WidthKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
    final class Recorder { var width: CGFloat = 0 }

    func testTheMembersTableStaysInsideTheInspector() {
        let rows = [Member(id: 0, offset: "+0x8", name: "_stickyWindowController", type: "SNWindowController *"),
                    Member(id: 1, offset: "+0x10", name: "_stickyUUID", type: "NSString *")]
        for width: CGFloat in [248, 259, 300] {
            let recorder = Recorder()
            let table = LumenTable(rows, selection: .constant(nil), columns: [
                .text("Offset", width: 44, monospaced: true) { $0.offset },
                LumenTableColumn.text("Name") { $0.name }.minWidth(72).priority(1),
                LumenTableColumn.text("Type", monospaced: true) { $0.type }.minWidth(72),
                LumenTableColumn("Evidence", width: 16) { _ in Image(systemName: "checkmark.seal") },
            ])
            let root = VStack { table.background { GeometryReader { Color.clear.preference(key: WidthKey.self, value: $0.size.width) } } }
                .frame(width: width, height: 220)
                .onPreferenceChange(WidthKey.self) { v in MainActor.assumeIsolated { recorder.width = v } }
            let host = NSHostingView(rootView: root)
            host.sizingOptions = []
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 220), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            for _ in 0..<6 { host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            window.close()
            XCTAssertGreaterThan(recorder.width, 0, "no width at \(Int(width))")
            XCTAssertLessThanOrEqual(recorder.width, width + 0.5, "the table grew past its \(Int(width)) pt container")
        }
    }
}

@MainActor
final class LumenTruncationRulingTests: XCTestCase {
    /// A nine-character cell shown in full isn't reported ("Find Nex…" is wider than "Find Next").
    func testAShortCellShownInFullIsNotReported() {
        let findings = LumenConformance.truncation(sizes: [CGSize(width: 300, height: 80)]) {
            HStack { LumenTableText("Find Next").fixedSize(); Spacer() }
        }
        XCTAssertEqual(findings, [])
    }

    /// Shrinking within its minimum scale isn't truncation; cut short at that scale, it is.
    func testScaleToFitWithinItsMinimumIsNotReported() {
        let label = "0x0000000100003f00"
        let fits = LumenConformance.truncation(sizes: [CGSize(width: 300, height: 80)]) {
            Text(label).font(.title2).lineLimit(1).minimumScaleFactor(0.7).lumenNeverTruncates(label, minimumScale: 0.7).frame(width: 190)
        }
        XCTAssertEqual(fits, [], "shrunk within 0.7 should pass")
        let cut = LumenConformance.truncation(sizes: [CGSize(width: 300, height: 80)]) {
            Text(label).font(.title2).lineLimit(1).minimumScaleFactor(0.7).lumenNeverTruncates(label, minimumScale: 0.7).frame(width: 60)
        }
        XCTAssertEqual(cut.count, 1, "cut short even at 0.7 should report: \(cut)")
    }

    /// A hidden inspector stays mounted at zero width; its labels don't report.
    func testAHiddenInspectorDoesNotReport() {
        let label = "A long inspector title that cannot possibly fit"
        func window(_ panels: LumenWorkspacePanels) -> some View {
            LumenWorkspaceWindow(panels: .constant(panels)) {
                Color.clear
            } inspector: {
                Text(label).lineLimit(1).lumenNeverTruncates(label)
            } topLeading: {
                Text("Untitled")
            }
        }
        let hidden = LumenConformance.workspaceWindow(sizes: [CGSize(width: 900, height: 560)],
                                                      panels: [LumenWorkspacePanels(leading: false, bottom: false, trailing: false)]) { window($0) }
        XCTAssertFalse(hidden.contains { $0.description.contains("cannot possibly fit") }, "\(hidden)")
    }
}
