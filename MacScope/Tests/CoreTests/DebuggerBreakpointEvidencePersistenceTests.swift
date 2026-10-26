import Foundation
import XCTest
@testable import MacScope

final class DebuggerBreakpointEvidencePersistenceTests: XCTestCase {
    func testSQLiteReopenPreservesRawSymbolAndDistinctSameBasenameSourceAuthority() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let artifactUUID = UUID()
        let digest = String(repeating: "a", count: 64)
        let decomposedRawName = "_$s4Cafe\u{301}6helperyyF"
        var analysis = ImageAnalysis()
        analysis.symbols = [
            SymbolSummary(
                id: UUID(),
                name: "Friendly helper",
                address: 0x1000,
                kind: "export",
                libraryName: nil,
                rawLinkageName: decomposedRawName
            )
        ]
        analysis.sourceLines = [
            Self.sourceLine(
                address: 0x1000,
                artifactUUID: artifactUUID,
                digest: digest,
                unitOffset: 0x20,
                path: .absoluteUTF8("/first/shared.c")
            ),
            Self.sourceLine(
                address: 0x2000,
                artifactUUID: artifactUUID,
                digest: digest,
                unitOffset: 0x80,
                path: .absoluteUTF8("/second/shared.c")
            ),
        ]
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(
                id: UUID(),
                name: "Evidence",
                path: "/tmp/evidence",
                kind: "Mach-O executable",
                architecture: "arm64",
                slot: .primary
            )],
            analysisBySlot: [.primary: analysis]
        )

        let workspace = try database.saveSnapshot(workspaceName: "Evidence", snapshot: snapshot)
        let reopened = try XCTUnwrap(
            try database.loadSnapshot(workspaceID: try XCTUnwrap(workspace.id))
        )
        let reopenedAnalysis = try XCTUnwrap(reopened.analysis(in: .primary))
        let rawName = try XCTUnwrap(reopenedAnalysis.symbols.first?.rawLinkageName)

        XCTAssertEqual(Array(rawName.utf8), Array(decomposedRawName.utf8))
        XCTAssertEqual(reopenedAnalysis.sourceLines, analysis.sourceLines)
        XCTAssertNotEqual(
            reopenedAnalysis.sourceLines[0].tablePath,
            reopenedAnalysis.sourceLines[1].tablePath
        )
        XCTAssertEqual(reopenedAnalysis.sourceLines.map(\.lineProgramUnitOffset), [0x20, 0x80])
    }

    func testPackageRoundTripPreservesExactEvidenceAndLegacyRowsStayIneligible() throws {
        let artifactUUID = UUID()
        let digest = String(repeating: "b", count: 64)
        let exact = Self.sourceLine(
            address: 0x3000,
            artifactUUID: artifactUUID,
            digest: digest,
            unitOffset: 0x123,
            path: .compilationDirectoryRelativeUTF8("Sources/../Generated/item.c")
        )
        let legacy = SourceLineEntry(
            address: 0x3004,
            file: "item.c",
            line: 8,
            column: 0,
            endSequence: false
        )
        var image = ImageAnalysis()
        image.symbols = [SymbolSummary(
            id: UUID(),
            name: "display",
            address: 0x3000,
            kind: "local",
            libraryName: nil,
            rawLinkageName: "_exact_linkage"
        )]
        image.sourceLines = [exact, legacy]

        let encoded = try JSONEncoder().encode(WorkspacePackageAnalysis(imageAnalysis: image))
        let decoded = try JSONDecoder().decode(WorkspacePackageAnalysis.self, from: encoded)

        XCTAssertEqual(decoded.symbols.first?.rawLinkageName, "_exact_linkage")
        XCTAssertEqual(decoded.sourceLines, [exact, legacy])
        XCTAssertEqual(
            decoded.sourceLines.first?.tablePath,
            .compilationDirectoryRelativeUTF8("Sources/../Generated/item.c")
        )
        XCTAssertNil(decoded.sourceLines.last?.debugArtifactUUID)
        XCTAssertNil(decoded.sourceLines.last?.lineProgramUnitOffset)
        XCTAssertNil(decoded.sourceLines.last?.tablePath)
    }

    private static func sourceLine(
        address: UInt64,
        artifactUUID: UUID,
        digest: String,
        unitOffset: UInt64,
        path: DebuggerCanonicalSourceTablePath
    ) -> SourceLineEntry {
        SourceLineEntry(
            address: address,
            file: {
                switch path {
                case .absoluteUTF8(let value), .compilationDirectoryRelativeUTF8(let value): value
                }
            }(),
            line: 7,
            column: 2,
            endSequence: false,
            debugArtifactUUID: artifactUUID,
            debugArtifactMachOSHA256: digest,
            debugArtifactMachOByteCount: 4_096,
            lineProgramUnitOffset: unitOffset,
            fileTableIndex: 1,
            tablePath: path
        )
    }
}
