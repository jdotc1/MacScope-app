import XCTest
@testable import MacScope

/// WS-7 Phase A: the synthetic runtime layout (slide policy + `runtimeVA`/`resolve`) and the frozen
/// address-resolver stub. Primary is always slide 0; secondary images are stacked into disjoint,
/// page-aligned runtime ranges; adding a higher-slot image never shifts earlier ones.
final class ImageLayoutTests: XCTestCase {
    private let slotB = ImageSlot(rawValue: 1)
    private let slotC = ImageSlot(rawValue: 2)

    private func image(_ slot: ImageSlot, minVA: UInt64, size: UInt64) -> (BinaryImage, ImageAnalysis) {
        var a = ImageAnalysis()
        a.sections = [SectionSummary(id: UUID(), name: "__text", address: minVA, size: size,
                                     fileOffset: 0, isExecutable: true)]
        let b = BinaryImage(id: UUID(), name: "img\(slot.rawValue)", path: "/tmp/x", kind: "executable",
                            architecture: "arm64", slot: slot)
        return (b, a)
    }

    private func snapshot(_ images: [(BinaryImage, ImageAnalysis)]) -> WorkspaceSnapshot {
        var s = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        for (b, a) in images { s.insertImage(binary: b, analysis: a) }
        return s
    }

    func testPrimaryIsSlideZeroAndRuntimeVAIsIdentity() {
        let s = snapshot([image(.primary, minVA: 0x1_0000_0000, size: 0x8000)])
        let layout = ImageLayoutResolver.layout(s)
        XCTAssertEqual(layout.slide(.primary), 0)
        XCTAssertEqual(layout.runtimeVA(ImageAddress(slot: .primary, address: 0x1_0000_1000)), 0x1_0000_1000)
    }

    func testSecondImageGetsDisjointPageAlignedRange() {
        let s = snapshot([image(.primary, minVA: 0x1_0000_0000, size: 0x8000),
                          image(slotB,   minVA: 0x1_0000_0000, size: 0x9000)])   // colliding image VAs
        let layout = ImageLayoutResolver.layout(s)
        XCTAssertEqual(layout.slide(.primary), 0)
        XCTAssertGreaterThan(layout.slide(slotB), 0, "B must be slid off the primary's range")
        let pa = layout.placements[.primary]!, pb = layout.placements[slotB]!
        XCTAssertGreaterThanOrEqual(pb.runtimeBase, pa.runtimeBase + pa.runtimeSize,
                                    "B's runtime range must start at/after the primary's end")
        XCTAssertEqual(pb.runtimeBase % 0x4000, 0, "page-aligned base")
    }

    func testResolveRoundTripsAndRejectsGaps() {
        let s = snapshot([image(.primary, minVA: 0x1_0000_0000, size: 0x8000),
                          image(slotB,   minVA: 0x1_0000_0000, size: 0x9000)])
        let layout = ImageLayoutResolver.layout(s)
        let a = ImageAddress(slot: slotB, address: 0x1_0000_5000)
        XCTAssertEqual(layout.resolve(runtimeVA: layout.runtimeVA(a)), a)
        let primaryRT = layout.runtimeVA(ImageAddress(slot: .primary, address: 0x1_0000_2000))
        XCTAssertEqual(layout.resolve(runtimeVA: primaryRT)?.slot, .primary)
        let gap = layout.placements[.primary]!.runtimeBase + layout.placements[.primary]!.runtimeSize + 0x10
        XCTAssertNil(layout.resolve(runtimeVA: gap), "a value in the guard-band gap resolves to nil")
    }

    func testAppendOnlyStabilityDoesNotShiftEarlierImages() {
        let two = snapshot([image(.primary, minVA: 0x1_0000_0000, size: 0x8000),
                            image(slotB,   minVA: 0x2_0000_0000, size: 0x9000)])
        let three = snapshot([image(.primary, minVA: 0x1_0000_0000, size: 0x8000),
                              image(slotB,   minVA: 0x2_0000_0000, size: 0x9000),
                              image(slotC,   minVA: 0x3_0000_0000, size: 0x4000)])
        XCTAssertEqual(ImageLayoutResolver.layout(two).slide(slotB),
                       ImageLayoutResolver.layout(three).slide(slotB), "adding C must not move B")
    }

    func testImageWithoutSectionsIsSkipped() {
        var s = snapshot([image(.primary, minVA: 0x1_0000_0000, size: 0x8000)])
        let (bBare, _) = image(slotB, minVA: 0, size: 0)
        s.insertImage(binary: bBare, analysis: ImageAnalysis())   // no sections
        let layout = ImageLayoutResolver.layout(s)
        XCTAssertNil(layout.placements[slotB], "a section-less image gets no runtime range")
        XCTAssertEqual(layout.slide(slotB), 0)
    }

    func testAddressResolverStubReturnsEmpty() {
        let s = snapshot([image(.primary, minVA: 0x1_0000_0000, size: 0x8000)])
        XCTAssertTrue(CrossImageAddressResolver.resolve(s, layout: ImageLayoutResolver.layout(s)).isEmpty)
    }

    // MARK: - MS-07: actual-primary reservation, checked secondary cursor, overflow rejection

    private let page = ImageLayoutResolver.page

    private func bare(_ slot: ImageSlot) -> (BinaryImage, ImageAnalysis) {
        (image(slot, minVA: 0, size: 0).0, ImageAnalysis())     // no sections
    }

    /// Every placement is non-wrapping and pairwise disjoint, and every image's first and last
    /// section byte round-trips image-VA -> runtime-VA -> the SAME (slot, image-VA).
    private func assertDisjointAndRoundTrips(_ layout: ImageLayout, _ s: WorkspaceSnapshot,
                                             file: StaticString = #filePath, line: UInt = #line) {
        let placed = layout.placements.sorted { $0.value.runtimeBase < $1.value.runtimeBase }
        for (slot, p) in placed {
            let (_, overflow) = p.runtimeBase.addingReportingOverflow(p.runtimeSize)
            XCTAssertFalse(overflow, "slot \(slot.rawValue) range wraps", file: file, line: line)
        }
        for (a, b) in zip(placed, placed.dropFirst()) {
            XCTAssertLessThanOrEqual(a.value.runtimeBase + a.value.runtimeSize, b.value.runtimeBase,
                                     "slots \(a.key.rawValue)/\(b.key.rawValue) overlap", file: file, line: line)
        }
        for slot in layout.placements.keys {
            for section in s.analysis(in: slot)?.sections ?? [] where section.size > 0 {
                for va in [section.address, section.address + section.size - 1] {
                    let address = ImageAddress(slot: slot, address: va)
                    XCTAssertEqual(layout.resolve(runtimeVA: layout.runtimeVA(address)), address,
                                   "round trip slot \(slot.rawValue) va \(va)", file: file, line: line)
                }
            }
        }
    }

    func testSingleImageLayoutIsUnchanged() {
        let s = snapshot([image(.primary, minVA: 0x1_0000_0000, size: 0x8100)])
        let layout = ImageLayoutResolver.layout(s)
        XCTAssertEqual(layout.placements,
                       [.primary: ImageLayout.Placement(slide: 0, runtimeBase: 0x1_0000_0000, runtimeSize: 0xC000)])
        XCTAssertTrue(layout.rejections.isEmpty)
    }

    func testSectionlessPrimaryReservesFirstPageSoSecondariesAreDisjoint() throws {
        let s = snapshot([bare(.primary),
                          image(slotB, minVA: 0x1_0000_0000, size: 0x8000),
                          image(slotC, minVA: 0x1_0000_0000, size: 0x8000)])
        let layout = ImageLayoutResolver.layout(s)
        XCTAssertNil(layout.placements[.primary], "a section-less primary publishes no range")
        XCTAssertEqual(layout.slide(.primary), 0)
        let pb = try XCTUnwrap(layout.placements[slotB]), pc = try XCTUnwrap(layout.placements[slotC])
        XCTAssertEqual(pb.runtimeBase, page, "first secondary starts past the reserved [0, page)")
        XCTAssertNotEqual(pb.runtimeBase, pc.runtimeBase, "secondaries must not share the fallback base")
        XCTAssertGreaterThanOrEqual(pc.runtimeBase, pb.runtimeBase + pb.runtimeSize + page)
        XCTAssertEqual(pc.runtimeBase % page, 0)
        XCTAssertNil(layout.resolve(runtimeVA: 0x10), "the primary reservation is not attributed to a secondary")
        XCTAssertTrue(layout.rejections.isEmpty)
        assertDisjointAndRoundTrips(layout, s)
    }

    func testSeveralSecondariesNeverShareTheFallbackBase() {
        let slots = (1...4).map { ImageSlot(rawValue: $0) }
        let s = snapshot([bare(.primary)] + slots.map { image($0, minVA: 0x1_0000_0000, size: 0x4000) })
        let layout = ImageLayoutResolver.layout(s)
        let bases = slots.compactMap { layout.placements[$0]?.runtimeBase }
        XCTAssertEqual(bases.count, 4)
        XCTAssertEqual(Set(bases).count, 4, "every secondary gets its own base")
        XCTAssertEqual(bases, bases.sorted(), "placed in ascending slot order")
        assertDisjointAndRoundTrips(layout, s)
    }

    func testRemappedPrimaryKeepsItsUnchangedBaseAndSecondariesStackAboveIt() throws {
        var s = snapshot([image(.primary, minVA: 0x1_0000_0000, size: 0x8000),
                          image(slotB,   minVA: 0x1_0000_0000, size: 0x9000),
                          image(slotC,   minVA: 0x0_0000_4000, size: 0x4000)])
        let remapped = ImageSlot(rawValue: 7)
        s.remapImageSlot(from: .primary, to: remapped)
        XCTAssertEqual(s.primarySlot, remapped, "the first image stays primary at a higher slot")

        let layout = ImageLayoutResolver.layout(s)
        XCTAssertEqual(layout.placements[remapped],
                       ImageLayout.Placement(slide: 0, runtimeBase: 0x1_0000_0000, runtimeSize: 0x8000))
        let pb = try XCTUnwrap(layout.placements[slotB]), pc = try XCTUnwrap(layout.placements[slotC])
        XCTAssertGreaterThanOrEqual(pb.runtimeBase, 0x1_0000_8000 + page, "B stacks above the primary")
        XCTAssertGreaterThanOrEqual(pc.runtimeBase, pb.runtimeBase + pb.runtimeSize + page, "C advances past B")
        XCTAssertEqual(layout.resolve(runtimeVA: 0x1_0000_2000), ImageAddress(slot: remapped, address: 0x1_0000_2000))
        XCTAssertTrue(layout.rejections.isEmpty)
        assertDisjointAndRoundTrips(layout, s)
    }

    func testSecondaryThatCannotFitBelowUInt64MaxIsRejectedNotWrapped() {
        let top: UInt64 = 0xFFFF_FFFF_FFF0_0000
        let s = snapshot([image(.primary, minVA: top, size: 0x8000),
                          image(slotB,   minVA: 0x1_0000_0000, size: 0x10_0000),  // too large to fit
                          image(slotC,   minVA: 0x1_0000_0000, size: 0x4000)])    // still fits
        let layout = ImageLayoutResolver.layout(s)
        XCTAssertEqual(layout.rejections[slotB], .addressSpaceExhausted)
        XCTAssertNil(layout.placements[slotB])
        XCTAssertEqual(layout.slide(slotB), 0)
        XCTAssertEqual(layout.placements[slotC]?.runtimeBase, 0xFFFF_FFFF_FFF0_C000)
        assertDisjointAndRoundTrips(layout, s)
    }

    func testSectionEndOverflowIsRejected() {
        let s = snapshot([image(.primary, minVA: 0x1_0000_0000, size: 0x8000),
                          image(slotB,   minVA: UInt64.max - 0x10, size: 0x100)])
        let layout = ImageLayoutResolver.layout(s)
        XCTAssertEqual(layout.rejections[slotB], .sectionExtentOverflow)
        XCTAssertNil(layout.placements[slotB])
        XCTAssertNotNil(layout.placements[.primary])
        assertDisjointAndRoundTrips(layout, s)
    }

    func testPrimaryExtentOverflowRejectsAllSecondariesConservatively() {
        let s = snapshot([image(.primary, minVA: UInt64.max - 0x10, size: 0x100),
                          image(slotB,   minVA: 0x1_0000_0000, size: 0x4000)])
        let layout = ImageLayoutResolver.layout(s)
        XCTAssertTrue(layout.placements.isEmpty)
        XCTAssertEqual(layout.rejections, [.primary: .sectionExtentOverflow, slotB: .primaryExtentUnavailable])
        XCTAssertEqual(layout.slide(.primary), 0, "the primary keeps identity VAs")
        XCTAssertNil(layout.resolve(runtimeVA: 0x1_0000_0000))
    }

    func testPrimaryAtTopOfAddressSpaceClampsWithoutWrappingAndExhaustsCursor() throws {
        let s = snapshot([image(.primary, minVA: 0xFFFF_FFFF_FFFF_C000, size: 0x3000),
                          image(slotB,   minVA: 0x1_0000_0000, size: 0x4000)])
        let layout = ImageLayoutResolver.layout(s)
        let pp = try XCTUnwrap(layout.placements[.primary])
        XCTAssertEqual(pp.runtimeBase, 0xFFFF_FFFF_FFFF_C000)
        XCTAssertEqual(pp.runtimeSize, UInt64.max - 0xFFFF_FFFF_FFFF_C000, "clamped, never wrapped")
        XCTAssertEqual(layout.rejections[slotB], .addressSpaceExhausted)
        XCTAssertEqual(layout.resolve(runtimeVA: 0xFFFF_FFFF_FFFF_EFFF),
                       ImageAddress(slot: .primary, address: 0xFFFF_FFFF_FFFF_EFFF))
        XCTAssertNil(layout.resolve(runtimeVA: 0x10), "no wrapped range reaches the bottom of the space")
        assertDisjointAndRoundTrips(layout, s)
    }
}
