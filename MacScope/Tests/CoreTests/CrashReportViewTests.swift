import LumenTokens
import LumenUI
import SwiftUI
import XCTest
@testable import MacScope

@MainActor
final class CrashReportViewTests: XCTestCase {
    func testRenderReadOnlyCrashReportForReview() throws {
        let uuid = "11111111-2222-3333-4444-555555555555"
        let report = CrashReport(
            processName: "Synthetic Example", exceptionSummary: "EXC_BAD_ACCESS · SIGSEGV",
            threads: [
                CrashReportThread(id: 0, name: "com.apple.main-thread", triggered: true,
                    frames: [
                        CrashReportFrame(id: 0, imageIndex: 0, imageOffset: 0x100, reportedSymbol: nil),
                        CrashReportFrame(id: 1, imageIndex: 0, imageOffset: 0x200, reportedSymbol: nil),
                        CrashReportFrame(id: 2, imageIndex: 1, imageOffset: 0x40, reportedSymbol: "start")
                    ]),
                CrashReportThread(id: 1, name: "Worker", triggered: false, frames: [])
            ], images: [
                CrashReportImage(name: "Synthetic Example", uuid: uuid, base: 0x102000000, size: 0x4000),
                CrashReportImage(name: "dyld", uuid: nil, base: 0x190000000, size: 0x10000)
            ])
        let context = CrashReportImageContext(uuid: uuid, preferredBase: 0x100000000,
            mappedRanges: [0x100000000..<0x100004000], symbols: [
                CrashReportSymbol(name: "processDocument", address: 0x100000100, endAddress: 0x100000180),
                CrashReportSymbol(name: "main", address: 0x100000200, endAddress: 0x100000300)
            ])
        let subject = DSSnapshot.Subject(name: "crash-report", size: CGSize(width: 940, height: 500),
            view: AnyView(CrashReportView(report: report, context: context, imageName: "Synthetic Example", onNavigate: { _ in true }, rendersOffscreen: true)
                .lumenRendersOffscreen(true)))
        let png = try XCTUnwrap(DSSnapshot.png(of: subject, in: .init(themeID: DSBuiltInThemes.scope.id, colorScheme: .dark)))
        let url = TestWorkRoot.scratchURL("crash-report-preview.png")
        try png.write(to: url)
        print("UI review shot: \(url.path)")
    }
}
