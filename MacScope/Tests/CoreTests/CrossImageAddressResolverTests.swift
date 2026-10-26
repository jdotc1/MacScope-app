import XCTest
@testable import MacScope

final class CrossImageAddressResolverTests: XCTestCase {
    private struct EdgeProjection: Equatable {
        let fromSlot: ImageSlot
        let from: UInt64
        let toSlot: ImageSlot
        let to: UInt64
        let kind: String
    }

    private let slotB = ImageSlot(rawValue: 1)
    private let slotC = ImageSlot(rawValue: 2)

    private func section(
        _ name: String,
        address: UInt64,
        size: UInt64,
        fileOffset: UInt64 = 0,
        isExecutable: Bool,
        isZeroFill: Bool = false,
        fileSize: UInt64? = nil
    ) -> SectionSummary {
        SectionSummary(
            id: UUID(),
            name: name,
            address: address,
            size: size,
            fileOffset: fileOffset,
            isExecutable: isExecutable,
            isZeroFill: isZeroFill,
            fileSize: fileSize
        )
    }

    private func image(
        _ slot: ImageSlot,
        sections: [SectionSummary],
        imageBytes: Data = Data(),
        xrefs: [XRef] = []
    ) -> (BinaryImage, ImageAnalysis) {
        let binary = BinaryImage(
            id: UUID(),
            name: "image-\(slot.rawValue)",
            path: "/tmp/image-\(slot.rawValue)",
            kind: "executable",
            architecture: "arm64",
            slot: slot
        )
        var analysis = ImageAnalysis()
        analysis.sections = sections
        analysis.imageBytes = imageBytes
        analysis.xrefs = xrefs
        return (binary, analysis)
    }

    private func snapshot(_ images: [(BinaryImage, ImageAnalysis)]) -> WorkspaceSnapshot {
        var snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        for (binary, analysis) in images {
            snapshot.insertImage(binary: binary, analysis: analysis)
        }
        return snapshot
    }

    private func bytes(count: Int, words: [(offset: Int, value: UInt64)]) -> Data {
        var result = Data(repeating: 0, count: count)
        for word in words {
            precondition(word.offset >= 0 && word.offset + 8 <= count)
            for byteIndex in 0..<8 {
                result[word.offset + byteIndex] = UInt8(
                    truncatingIfNeeded: word.value >> (byteIndex * 8)
                )
            }
        }
        return result
    }

    private func projection(of edges: [CrossImageXRef]) -> [EdgeProjection] {
        edges.map {
            EdgeProjection(
                fromSlot: $0.fromSlot,
                from: $0.from,
                toSlot: $0.toSlot,
                to: $0.to,
                kind: $0.kind
            )
        }
    }

    func testDataWordResolvesFromSectionRelativeSiteIntoAnotherImage() throws {
        let dataSection = section(
            "__DATA,__data",
            address: 0x1000,
            size: 0x10,
            fileOffset: 3,
            isExecutable: false
        )
        let targetSection = section(
            "__TEXT,__text",
            address: 0x2000,
            size: 0x80,
            isExecutable: true
        )
        var input = snapshot([
            image(.primary, sections: [dataSection]),
            image(slotB, sections: [targetSection]),
        ])
        let layout = ImageLayoutResolver.layout(input)
        let target = ImageAddress(slot: slotB, address: 0x2028)
        input.mutateAnalysis(in: .primary) {
            // Section-relative k = 8 lives at file offset 3 + 8, but emits from VA 0x1000 + 8.
            $0.imageBytes = bytes(
                count: 19,
                words: [(offset: 11, value: layout.runtimeVA(target))]
            )
        }

        let edges = CrossImageAddressResolver.resolve(input, layout: layout)

        let edge = try XCTUnwrap(edges.first)
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edge.fromSlot, .primary)
        XCTAssertEqual(edge.from, 0x1008)
        XCTAssertEqual(edge.toSlot, slotB)
        XCTAssertEqual(edge.to, 0x2028)
        XCTAssertEqual(edge.symbol, "")
        XCTAssertEqual(edge.kind, XRefKind.data)
    }

    func testDataWordResolvingInsideSourceImageDoesNotEmitEdge() {
        let dataSection = section(
            "__DATA,__data",
            address: 0x1000,
            size: 8,
            isExecutable: false
        )
        let targetSection = section(
            "__TEXT,__text",
            address: 0x2000,
            size: 0x80,
            isExecutable: true
        )
        var input = snapshot([
            image(.primary, sections: [dataSection]),
            image(slotB, sections: [targetSection]),
        ])
        let layout = ImageLayoutResolver.layout(input)
        let ownAddress = ImageAddress(slot: .primary, address: 0x1004)
        input.mutateAnalysis(in: .primary) {
            $0.imageBytes = bytes(
                count: 8,
                words: [(offset: 0, value: layout.runtimeVA(ownAddress))]
            )
        }

        XCTAssertTrue(CrossImageAddressResolver.resolve(input, layout: layout).isEmpty)
    }

    func testDataWordInGuardBandDoesNotEmitEdge() throws {
        let dataSection = section(
            "__DATA,__data",
            address: 0x1000,
            size: 8,
            isExecutable: false
        )
        let targetSection = section(
            "__TEXT,__text",
            address: 0x2000,
            size: 0x80,
            isExecutable: true
        )
        var input = snapshot([
            image(.primary, sections: [dataSection]),
            image(slotB, sections: [targetSection]),
        ])
        let layout = ImageLayoutResolver.layout(input)
        let primaryPlacement = try XCTUnwrap(layout.placements[.primary])
        let targetPlacement = try XCTUnwrap(layout.placements[slotB])
        let gapValue = primaryPlacement.runtimeBase + primaryPlacement.runtimeSize + 8
        XCTAssertLessThan(gapValue, targetPlacement.runtimeBase)
        input.mutateAnalysis(in: .primary) {
            $0.imageBytes = bytes(count: 8, words: [(offset: 0, value: gapValue)])
        }

        XCTAssertTrue(CrossImageAddressResolver.resolve(input, layout: layout).isEmpty)
    }

    func testRuntimeRangeLowerBoundIsInclusiveAndUpperBoundIsExclusive() throws {
        let dataSection = section(
            "__DATA,__data",
            address: 0x1000,
            size: 0x10,
            isExecutable: false
        )
        let targetSection = section(
            "__TEXT,__text",
            address: 0x2000,
            size: 0x80,
            isExecutable: true
        )
        var input = snapshot([
            image(.primary, sections: [dataSection]),
            image(slotB, sections: [targetSection]),
        ])
        let layout = ImageLayoutResolver.layout(input)
        let placement = try XCTUnwrap(layout.placements[slotB])
        input.mutateAnalysis(in: .primary) {
            $0.imageBytes = bytes(
                count: 16,
                words: [
                    (offset: 0, value: placement.runtimeBase),
                    (offset: 8, value: placement.runtimeBase + placement.runtimeSize),
                ]
            )
        }

        let edges = CrossImageAddressResolver.resolve(input, layout: layout)

        let edge = try XCTUnwrap(edges.first)
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edge.from, 0x1000)
        XCTAssertEqual(edge.toSlot, slotB)
        XCTAssertEqual(edge.to, targetSection.address)
    }

    func testInstructionTargetOutsideSourceSectionsResolvesButOwnSectionTargetIsIgnored() throws {
        let primaryText = section(
            "__TEXT,__text",
            address: 0x1000,
            size: 0x100,
            isExecutable: true
        )
        let siblingText = section(
            "__TEXT,__text",
            address: 0x1000,
            size: 0x100,
            isExecutable: true
        )
        var input = snapshot([
            image(.primary, sections: [primaryText]),
            image(slotB, sections: [siblingText]),
        ])
        let layout = ImageLayoutResolver.layout(input)
        let crossTarget = ImageAddress(slot: slotB, address: 0x1030)
        input.mutateAnalysis(in: .primary) {
            $0.xrefs = [
                XRef(id: UUID(), from: 0x1020, to: layout.runtimeVA(crossTarget), kind: XRefKind.call),
            ]
        }
        input.mutateAnalysis(in: slotB) {
            // Numerically this resolves to primary, but it is inside B's own image-VA section and
            // therefore must never be reconsidered as a cross-image runtime target.
            $0.xrefs = [
                XRef(id: UUID(), from: 0x1040, to: 0x1010, kind: XRefKind.call),
            ]
        }

        let edges = CrossImageAddressResolver.resolve(input, layout: layout)

        let edge = try XCTUnwrap(edges.first)
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edge.fromSlot, .primary)
        XCTAssertEqual(edge.from, 0x1020)
        XCTAssertEqual(edge.toSlot, slotB)
        XCTAssertEqual(edge.to, 0x1030)
        XCTAssertEqual(edge.symbol, "")
        XCTAssertEqual(edge.kind, XRefKind.data)
    }

    func testThreeImageDataFanOutKeepsTargetsInTheirResolvedSlots() {
        let dataSection = section(
            "__DATA,__data",
            address: 0x1000,
            size: 0x10,
            isExecutable: false
        )
        let sectionB = section(
            "__TEXT,__text",
            address: 0x2000,
            size: 0x80,
            isExecutable: true
        )
        let sectionC = section(
            "__TEXT,__text",
            address: 0x3000,
            size: 0x80,
            isExecutable: true
        )
        var input = snapshot([
            image(.primary, sections: [dataSection]),
            image(slotB, sections: [sectionB]),
            image(slotC, sections: [sectionC]),
        ])
        let layout = ImageLayoutResolver.layout(input)
        input.mutateAnalysis(in: .primary) {
            $0.imageBytes = bytes(
                count: 16,
                words: [
                    (
                        offset: 0,
                        value: layout.runtimeVA(ImageAddress(slot: slotB, address: 0x2010))
                    ),
                    (
                        offset: 8,
                        value: layout.runtimeVA(ImageAddress(slot: slotC, address: 0x3020))
                    ),
                ]
            )
        }

        let edges = CrossImageAddressResolver.resolve(input, layout: layout)

        XCTAssertEqual(
            projection(of: edges),
            [
                EdgeProjection(
                    fromSlot: .primary,
                    from: 0x1000,
                    toSlot: slotB,
                    to: 0x2010,
                    kind: XRefKind.data
                ),
                EdgeProjection(
                    fromSlot: .primary,
                    from: 0x1008,
                    toSlot: slotC,
                    to: 0x3020,
                    kind: XRefKind.data
                ),
            ]
        )
    }

    func testDataWordAndInstructionTargetWithSameEndpointsAreDeduplicated() {
        let dataSection = section(
            "__DATA,__data",
            address: 0x1000,
            size: 8,
            isExecutable: false
        )
        let targetSection = section(
            "__TEXT,__text",
            address: 0x2000,
            size: 0x80,
            isExecutable: true
        )
        var input = snapshot([
            image(.primary, sections: [dataSection]),
            image(slotB, sections: [targetSection]),
        ])
        let layout = ImageLayoutResolver.layout(input)
        let runtimeTarget = layout.runtimeVA(ImageAddress(slot: slotB, address: 0x2020))
        input.mutateAnalysis(in: .primary) {
            $0.imageBytes = bytes(count: 8, words: [(offset: 0, value: runtimeTarget)])
            $0.xrefs = [
                XRef(id: UUID(), from: 0x1000, to: runtimeTarget, kind: XRefKind.call),
            ]
        }

        let edges = CrossImageAddressResolver.resolve(input, layout: layout)

        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges.first?.fromSlot, .primary)
        XCTAssertEqual(edges.first?.from, 0x1000)
        XCTAssertEqual(edges.first?.toSlot, slotB)
        XCTAssertEqual(edges.first?.to, 0x2020)
        XCTAssertEqual(edges.first?.kind, XRefKind.data)
    }

    func testResolveIsDeterministicBySemanticProjection() {
        let dataSection = section(
            "__DATA,__data",
            address: 0x1000,
            size: 0x10,
            isExecutable: false
        )
        let sectionB = section(
            "__TEXT,__text",
            address: 0x2000,
            size: 0x80,
            isExecutable: true
        )
        let sectionC = section(
            "__TEXT,__text",
            address: 0x3000,
            size: 0x80,
            isExecutable: true
        )
        var input = snapshot([
            image(.primary, sections: [dataSection]),
            image(slotB, sections: [sectionB]),
            image(slotC, sections: [sectionC]),
        ])
        let layout = ImageLayoutResolver.layout(input)
        let targetB = layout.runtimeVA(ImageAddress(slot: slotB, address: 0x2010))
        let targetC = layout.runtimeVA(ImageAddress(slot: slotC, address: 0x3020))
        input.mutateAnalysis(in: .primary) {
            $0.imageBytes = bytes(
                count: 16,
                words: [(offset: 0, value: targetC), (offset: 8, value: targetB)]
            )
            $0.xrefs = [
                XRef(id: UUID(), from: 0x1100, to: targetB, kind: XRefKind.call),
                XRef(id: UUID(), from: 0x1108, to: targetC, kind: XRefKind.data),
            ]
        }

        let first = CrossImageAddressResolver.resolve(input, layout: layout)
        let second = CrossImageAddressResolver.resolve(input, layout: layout)

        XCTAssertEqual(projection(of: first), projection(of: second))
        XCTAssertEqual(
            projection(of: first),
            [
                EdgeProjection(
                    fromSlot: .primary,
                    from: 0x1000,
                    toSlot: slotC,
                    to: 0x3020,
                    kind: XRefKind.data
                ),
                EdgeProjection(
                    fromSlot: .primary,
                    from: 0x1008,
                    toSlot: slotB,
                    to: 0x2010,
                    kind: XRefKind.data
                ),
                EdgeProjection(
                    fromSlot: .primary,
                    from: 0x1100,
                    toSlot: slotB,
                    to: 0x2010,
                    kind: XRefKind.data
                ),
                EdgeProjection(
                    fromSlot: .primary,
                    from: 0x1108,
                    toSlot: slotC,
                    to: 0x3020,
                    kind: XRefKind.data
                ),
            ]
        )
    }

    func testDataScanHonorsSectionEligibilityDeclaredFileSizeAndImageBounds() {
        let executable = section(
            "__TEXT,__text",
            address: 0x1000,
            size: 8,
            fileOffset: 0,
            isExecutable: true
        )
        let zeroFill = section(
            "__DATA,__bss",
            address: 0x2000,
            size: 8,
            fileOffset: 8,
            isExecutable: false,
            isZeroFill: true
        )
        let shorterThanAWord = section(
            "__DATA,__short",
            address: 0x3000,
            size: 0x100,
            fileOffset: 16,
            isExecutable: false,
            fileSize: 7
        )
        let clamped = section(
            "__DATA,__clamped",
            address: 0x4000,
            size: 0x100,
            fileOffset: 24,
            isExecutable: false,
            fileSize: 16
        )
        let outOfRange = section(
            "__DATA,__missing",
            address: 0x5000,
            size: 8,
            fileOffset: 32,
            isExecutable: false
        )
        let targetSection = section(
            "__TEXT,__text",
            address: 0x6000,
            size: 0x80,
            isExecutable: true
        )
        var input = snapshot([
            image(
                .primary,
                sections: [executable, zeroFill, shorterThanAWord, clamped, outOfRange]
            ),
            image(slotB, sections: [targetSection]),
        ])
        let layout = ImageLayoutResolver.layout(input)
        let runtimeTarget = layout.runtimeVA(ImageAddress(slot: slotB, address: 0x6010))
        input.mutateAnalysis(in: .primary) {
            $0.imageBytes = bytes(
                count: 32,
                words: [
                    (offset: 0, value: runtimeTarget),
                    (offset: 8, value: runtimeTarget),
                    (offset: 16, value: runtimeTarget),
                    (offset: 24, value: runtimeTarget),
                ]
            )
        }

        let edges = CrossImageAddressResolver.resolve(input, layout: layout)

        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges.first?.fromSlot, .primary)
        XCTAssertEqual(edges.first?.from, clamped.address)
        XCTAssertEqual(edges.first?.toSlot, slotB)
        XCTAssertEqual(edges.first?.to, 0x6010)
    }

    /// Regression: `imageBytes` can arrive as a `Data` SLICE whose `startIndex` is non-zero (same
    /// invariant the `hexByteReader` convention relies on). The data-word read must rebase the
    /// logical file offset onto `startIndex`; indexing with the raw offset reads the wrong bytes or
    /// traps. A fresh-`Data` fixture cannot exercise this, so build a sliced one explicitly.
    func testDataWordScanHonorsNonZeroStartIndexSlice() throws {
        let dataSection = section("__DATA,__data", address: 0x1000, size: 0x10,
                                  fileOffset: 3, isExecutable: false)
        let targetSection = section("__TEXT,__text", address: 0x2000, size: 0x80, isExecutable: true)
        var input = snapshot([
            image(.primary, sections: [dataSection]),
            image(slotB, sections: [targetSection]),
        ])
        let layout = ImageLayoutResolver.layout(input)
        let target = ImageAddress(slot: slotB, address: 0x2028)

        // Same 19-byte payload as the base test, but prefixed with 100 padding bytes and then sliced
        // off — so the retained `Data` has `startIndex == 100`, not 0.
        let payload = bytes(count: 19, words: [(offset: 11, value: layout.runtimeVA(target))])
        let padded = Data(repeating: 0xEE, count: 100) + payload
        let sliced = padded.suffix(19)
        XCTAssertNotEqual(sliced.startIndex, 0, "fixture must be a non-zero-startIndex slice")
        input.mutateAnalysis(in: .primary) { $0.imageBytes = sliced }

        let edges = CrossImageAddressResolver.resolve(input, layout: layout)
        let edge = try XCTUnwrap(edges.first)
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edge.from, 0x1008, "section-relative word site VA, read from the correct slice byte")
        XCTAssertEqual(edge.toSlot, slotB)
        XCTAssertEqual(edge.to, 0x2028)
    }
}
