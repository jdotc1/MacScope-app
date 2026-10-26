import XCTest
@testable import MacScope

final class CrossImageReferenceResolverTests: XCTestCase {
    private struct EdgeProjection: Equatable {
        let fromSlot: ImageSlot
        let from: UInt64
        let toSlot: ImageSlot
        let to: UInt64
        let symbol: String
        let kind: String
    }

    private func binary(in slot: ImageSlot) -> BinaryImage {
        BinaryImage(
            id: UUID(),
            name: "image-\(slot.rawValue)",
            path: "/tmp/image-\(slot.rawValue)",
            kind: "executable",
            architecture: "arm64",
            slot: slot
        )
    }

    private func indirectSymbol(
        _ name: String?,
        address: UInt64,
        section: String,
        tableIndex: UInt32 = 0
    ) -> IndirectSymbolSummary {
        IndirectSymbolSummary(
            id: UUID(),
            kind: "stub",
            sourceSection: section,
            address: address,
            entrySize: 8,
            tableIndex: tableIndex,
            rawSymbolIndex: 0,
            symbolIndex: nil,
            symbolName: name,
            libraryOrdinal: nil,
            libraryName: nil,
            isLocal: false,
            isAbsolute: false
        )
    }

    private func exportedSymbol(_ name: String, address: UInt64?) -> ExportSummary {
        ExportSummary(id: UUID(), name: name, address: address, source: "exports")
    }

    private func snapshot(
        _ images: [(
            slot: ImageSlot,
            indirectSymbols: [IndirectSymbolSummary],
            exports: [ExportSummary]
        )]
    ) -> WorkspaceSnapshot {
        var snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        for image in images {
            var analysis = ImageAnalysis()
            analysis.indirectSymbols = image.indirectSymbols
            analysis.exports = image.exports
            snapshot.insertImage(binary: binary(in: image.slot), analysis: analysis)
        }
        return snapshot
    }

    private func projection(of edge: CrossImageXRef) -> EdgeProjection {
        EdgeProjection(
            fromSlot: edge.fromSlot,
            from: edge.from,
            toSlot: edge.toSlot,
            to: edge.to,
            symbol: edge.symbol,
            kind: edge.kind
        )
    }

    func testSingleCrossImageCallEdge() throws {
        let slotB = ImageSlot(rawValue: 1)
        let input = snapshot([
            (
                slot: .primary,
                indirectSymbols: [
                    indirectSymbol("_foo", address: 0x2340, section: "__TEXT,__stubs"),
                ],
                exports: []
            ),
            (
                slot: slotB,
                indirectSymbols: [],
                exports: [exportedSymbol("_foo", address: 0x5000)]
            ),
        ])

        let result = CrossImageReferenceResolver.resolve(input)

        let edge = try XCTUnwrap(result.edges.first)
        XCTAssertEqual(result.edges.count, 1)
        XCTAssertEqual(edge.fromSlot, .primary)
        XCTAssertEqual(edge.from, 0x2340)
        XCTAssertEqual(edge.toSlot, slotB)
        XCTAssertEqual(edge.to, 0x5000)
        XCTAssertEqual(edge.symbol, "_foo")
        XCTAssertEqual(edge.kind, XRefKind.call)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testGotSiteIsDataKind() throws {
        let input = snapshot([
            (
                slot: .primary,
                indirectSymbols: [
                    indirectSymbol("_foo", address: 0x3000, section: "__DATA_CONST,__GoT"),
                ],
                exports: []
            ),
            (
                slot: ImageSlot(rawValue: 1),
                indirectSymbols: [],
                exports: [exportedSymbol("_foo", address: 0x5000)]
            ),
        ])

        let result = CrossImageReferenceResolver.resolve(input)

        let edge = try XCTUnwrap(result.edges.first)
        XCTAssertEqual(result.edges.count, 1)
        XCTAssertEqual(edge.kind, XRefKind.data)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testNoExporterYieldsNoEdge() {
        let input = snapshot([
            (
                slot: .primary,
                indirectSymbols: [
                    indirectSymbol("_missing", address: 0x2340, section: "__TEXT,__stubs"),
                ],
                exports: []
            ),
            (
                slot: ImageSlot(rawValue: 1),
                indirectSymbols: [],
                exports: [exportedSymbol("_other", address: 0x5000)]
            ),
        ])

        let result = CrossImageReferenceResolver.resolve(input)

        XCTAssertTrue(result.edges.isEmpty)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testSelfReferenceExcluded() {
        let input = snapshot([
            (
                slot: .primary,
                indirectSymbols: [
                    indirectSymbol("_bar", address: 0x2340, section: "__TEXT,__stubs"),
                ],
                exports: [exportedSymbol("_bar", address: 0x1111)]
            ),
        ])

        let result = CrossImageReferenceResolver.resolve(input)

        XCTAssertTrue(result.edges.isEmpty)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testDuplicateExportResolvesToLowestSlotWithDiagnostic() throws {
        let slotB = ImageSlot(rawValue: 1)
        let slotC = ImageSlot(rawValue: 2)
        // Deliberately insert out of slot order: the resolver, not fixture order, owns precedence.
        let input = snapshot([
            (
                slot: slotC,
                indirectSymbols: [
                    indirectSymbol("_foo", address: 0x7000, section: "__TEXT,__stubs"),
                ],
                exports: []
            ),
            (
                slot: slotB,
                indirectSymbols: [],
                exports: [exportedSymbol("_foo", address: 0x6000)]
            ),
            (
                slot: .primary,
                indirectSymbols: [],
                exports: [exportedSymbol("_foo", address: 0x5000)]
            ),
        ])

        let result = CrossImageReferenceResolver.resolve(input)

        let edge = try XCTUnwrap(result.edges.first)
        XCTAssertEqual(result.edges.count, 1)
        XCTAssertEqual(edge.fromSlot, slotC)
        XCTAssertEqual(edge.from, 0x7000)
        XCTAssertEqual(edge.toSlot, .primary)
        XCTAssertEqual(edge.to, 0x5000)
        XCTAssertEqual(edge.symbol, "_foo")
        XCTAssertEqual(
            result.diagnostics,
            [#"Cross-image symbol "_foo" is exported by multiple images; resolved to the lowest slot."#]
        )
    }

    func testThreeImageFanOutNoCrossBleed() throws {
        let slotB = ImageSlot(rawValue: 1)
        let slotC = ImageSlot(rawValue: 2)
        let input = snapshot([
            (
                slot: .primary,
                indirectSymbols: [
                    indirectSymbol("_foo", address: 0x2340, section: "__TEXT,__stubs", tableIndex: 0),
                    indirectSymbol("_bar", address: 0x2360, section: "__DATA,__got", tableIndex: 1),
                ],
                exports: []
            ),
            (
                slot: slotB,
                indirectSymbols: [],
                exports: [exportedSymbol("_foo", address: 0x5000)]
            ),
            (
                slot: slotC,
                indirectSymbols: [],
                exports: [exportedSymbol("_bar", address: 0x6000)]
            ),
        ])

        let result = CrossImageReferenceResolver.resolve(input)

        XCTAssertEqual(result.edges.count, 2)
        let edgesBySymbol = Dictionary(uniqueKeysWithValues: result.edges.map { ($0.symbol, $0) })
        let foo = try XCTUnwrap(edgesBySymbol["_foo"])
        XCTAssertEqual(foo.fromSlot, .primary)
        XCTAssertEqual(foo.from, 0x2340)
        XCTAssertEqual(foo.toSlot, slotB)
        XCTAssertEqual(foo.to, 0x5000)
        XCTAssertEqual(foo.kind, XRefKind.call)
        let bar = try XCTUnwrap(edgesBySymbol["_bar"])
        XCTAssertEqual(bar.fromSlot, .primary)
        XCTAssertEqual(bar.from, 0x2360)
        XCTAssertEqual(bar.toSlot, slotC)
        XCTAssertEqual(bar.to, 0x6000)
        XCTAssertEqual(bar.kind, XRefKind.data)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testDeterministicAcrossTwoCalls() {
        let slotB = ImageSlot(rawValue: 1)
        let slotC = ImageSlot(rawValue: 2)
        // Both the image array and slot-0 table entries are intentionally unsorted.
        let input = snapshot([
            (
                slot: slotC,
                indirectSymbols: [
                    indirectSymbol("_foo", address: 0x7340, section: "__TEXT,__stubs", tableIndex: 0),
                ],
                exports: []
            ),
            (
                slot: slotB,
                indirectSymbols: [],
                exports: [
                    exportedSymbol("_foo", address: 0x5000),
                    exportedSymbol("_bar", address: 0x6000),
                ]
            ),
            (
                slot: .primary,
                indirectSymbols: [
                    indirectSymbol("_foo", address: 0x2340, section: "__TEXT,__stubs", tableIndex: 8),
                    indirectSymbol("_bar", address: 0x2360, section: "__TEXT,__stubs", tableIndex: 2),
                ],
                exports: []
            ),
        ])

        let first = CrossImageReferenceResolver.resolve(input).edges.map(projection)
        let second = CrossImageReferenceResolver.resolve(input).edges.map(projection)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.fromSlot), [.primary, .primary, slotC])
        XCTAssertEqual(first.map(\.from), [0x2360, 0x2340, 0x7340])
    }

    func testExportWithoutAddressIsIgnored() {
        let input = snapshot([
            (
                slot: .primary,
                indirectSymbols: [
                    indirectSymbol("_foo", address: 0x2340, section: "__TEXT,__stubs"),
                ],
                exports: []
            ),
            (
                slot: ImageSlot(rawValue: 1),
                indirectSymbols: [],
                exports: [exportedSymbol("_foo", address: nil)]
            ),
        ])

        let result = CrossImageReferenceResolver.resolve(input)

        XCTAssertTrue(result.edges.isEmpty)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testIndirectSymbolWithoutNameIsIgnored() {
        let input = snapshot([
            (
                slot: .primary,
                indirectSymbols: [
                    indirectSymbol(nil, address: 0x2340, section: "__TEXT,__stubs"),
                ],
                exports: []
            ),
            (
                slot: ImageSlot(rawValue: 1),
                indirectSymbols: [],
                exports: [exportedSymbol("_foo", address: 0x5000)]
            ),
        ])

        let result = CrossImageReferenceResolver.resolve(input)

        XCTAssertTrue(result.edges.isEmpty)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testDuplicateExportWithoutJoinedEdgeYieldsNoDiagnostic() {
        let input = snapshot([
            (
                slot: .primary,
                indirectSymbols: [],
                exports: [exportedSymbol("_foo", address: 0x5000)]
            ),
            (
                slot: ImageSlot(rawValue: 1),
                indirectSymbols: [],
                exports: [exportedSymbol("_foo", address: 0x6000)]
            ),
        ])

        let result = CrossImageReferenceResolver.resolve(input)

        XCTAssertTrue(result.edges.isEmpty)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }
}
