import Foundation
import XCTest
@testable import MacScope

/// New DOT-07 handwritten fixtures only. No binary loader, corpus or accepted suite is run here.
final class RehydrationDerivedProductsTests: XCTestCase {
    private struct Fixture {
        var bytes: Data
        var persisted: ImageAnalysis
        var loader: RehydrationLoaderProducts
    }

    private func uuid(_ last: Int) -> UUID {
        UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", last))!
    }

    private func section(_ id: Int, _ name: String, _ address: UInt64, _ size: UInt64,
                         _ offset: UInt64, executable: Bool = false,
                         zeroFill: Bool = false, fileSize: UInt64? = nil) -> SectionSummary {
        SectionSummary(id: uuid(id), name: name, address: address, size: size,
                       fileOffset: offset, isExecutable: executable,
                       isZeroFill: zeroFill, fileSize: fileSize)
    }

    private func row(_ address: UInt64, _ mnemonic: String, _ operands: String = "") -> InstructionRow {
        InstructionRow(address: address, bytes: "00 00 00 00", mnemonic: mnemonic,
                       operands: operands, hasBreakpoint: false, comment: nil)
    }

    private func rows(start: UInt64 = 0x4200, table: UInt64 = 0x9000) -> [InstructionRow] {
        [row(start, "cmp", "w3, #1"),
         row(start + 4, "b.hi", "0x\(String(start + 0x30, radix: 16))"),
         row(start + 8, "adrp", "x10, 0x\(String(table & ~0xfff, radix: 16))"),
         row(start + 12, "add", "x10, x10, #0x\(String(table & 0xfff, radix: 16))"),
         row(start + 16, "ldrsw", "x11, [x10, w3, lsl #2]"),
         row(start + 20, "add", "x10, x10, x11"),
         row(start + 24, "br", "x10"),
         row(start + 32, "ret"), row(start + 40, "ret"), row(start + 48, "ret")]
    }

    private func function(_ id: Int = 7, start: UInt64 = 0x4200,
                          end: UInt64 = 0x4240) -> FunctionSummary {
        FunctionSummary(id: uuid(id), name: "dot07_handwritten_dispatch", startAddress: start,
                        endAddress: end, confidence: 0.75)
    }

    private func fixture() -> Fixture {
        let sections = [section(1, "__TEXT,__dot07", 0x4200, 0x40, 0, executable: true),
                        section(2, "__DATA_CONST,__dot07", 0x9000, 8, 0x40)]
        // Handwritten signed little-endian words:
        // 0xFFFFB220 = -0x4DE0; 0x9000 - 0x4DE0 = 0x4220.
        // 0xFFFFB228 = -0x4DD8; 0x9000 - 0x4DD8 = 0x4228.
        let bytes = Data(repeating: 0, count: 0x40) + Data([0x20, 0xb2, 0xff, 0xff,
                                                         0x28, 0xb2, 0xff, 0xff])
        var persisted = ImageAnalysis()
        persisted.instructions = rows()
        persisted.instructions[0].comment = "Keep the authored comment exactly."
        persisted.instructions[0].hasBreakpoint = true
        persisted.functions = [function()]
        persisted.basicBlocks = [.init(id: uuid(8), functionID: uuid(7), startAddress: 0x4200,
                                      endAddress: 0x421c, instructionCount: 7)]
        persisted.controlFlowEdges = [.init(id: uuid(9), from: 0x4204, to: 0x4230, kind: "branch")]
        persisted.xrefs = [.init(id: uuid(10), from: 0x4208, to: 0x9000, kind: XRefKind.data)]
        persisted.imageBytes = bytes
        persisted.hexBytes = Data([0x91, 0x82, 0x73])
        let loader = RehydrationLoaderProducts(requestID: uuid(11), requestedSliceIndex: nil,
            imageByteCount: bytes.count, sliceOffset: 0, sliceSize: UInt64(bytes.count),
            sections: sections,
            mappings: FileAddressMapping.verifiedMappings(from: sections, payloadLength: bytes.count))
        return Fixture(bytes: bytes, persisted: persisted, loader: loader)
    }

    private func remap(_ fixture: inout Fixture) {
        fixture.loader.imageByteCount = fixture.bytes.count
        let size = fixture.loader.sliceSize ?? UInt64(fixture.bytes.count) - fixture.loader.sliceOffset
        fixture.loader.mappings = FileAddressMapping.verifiedMappings(
            from: fixture.loader.sections, payloadLength: Int(size))
    }

    private func rebuild(_ fixture: Fixture, overrides: [UInt64: AddressOverride] = [:],
                         cancellation: AnalysisCancellationToken = .never) throws -> ImageAnalysis {
        try RehydrationDerivedProducts.rebuild(persisted: fixture.persisted, loader: fixture.loader,
            imageBytes: fixture.bytes, overrides: overrides, cancellation: cancellation)
    }

    private func assertPreserved(_ actual: ImageAnalysis, _ original: ImageAnalysis,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.instructions, original.instructions, file: file, line: line)
        XCTAssertEqual(actual.functions, original.functions, file: file, line: line)
        XCTAssertEqual(actual.basicBlocks, original.basicBlocks, file: file, line: line)
        XCTAssertEqual(actual.controlFlowEdges, original.controlFlowEdges, file: file, line: line)
        XCTAssertEqual(actual.xrefs, original.xrefs, file: file, line: line)
        XCTAssertEqual(actual.imageBytes, original.imageBytes, file: file, line: line)
        XCTAssertEqual(actual.hexBytes, original.hexBytes, file: file, line: line)
    }

    func testSplitRehydratePreservesRowsAndResolvesPatchedTable() throws {
        let f = fixture()
        let original = try rebuild(f)
        XCTAssertEqual(original.jumpTables, [0x4218: [0x4220, 0x4228]])
        // 0xFFFFB230 = -0x4DD0, so only entry 1 becomes 0x4230.
        let patched = try rebuild(f, overrides: [0x9004: AddressOverride(
            patch: BytePatch(bytes: [0x30, 0xb2, 0xff, 0xff]))])
        XCTAssertEqual(patched.jumpTables, [0x4218: [0x4220, 0x4230]])
        assertPreserved(original, f.persisted)
        assertPreserved(patched, f.persisted)
        XCTAssertEqual(Array(f.bytes.suffix(8)), [0x20, 0xb2, 0xff, 0xff, 0x28, 0xb2, 0xff, 0xff])
    }

    func testAliasedAndZeroFillTableBytesRemainUnavailable() throws {
        var aliased = fixture()
        aliased.bytes.append(contentsOf: [0x20, 0xb2, 0xff, 0xff, 0x28, 0xb2, 0xff, 0xff])
        aliased.loader.sliceSize = UInt64(aliased.bytes.count)
        aliased.loader.sections.append(section(12, "alias", 0x9000, 8, 0x48))
        remap(&aliased)
        XCTAssertTrue(try rebuild(aliased).jumpTables.isEmpty)
        XCTAssertNil(RehydrationDerivedProducts.mappedBytes(in: aliased.bytes, sliceOffset: 0,
            at: 0x9000, count: 4, mappings: aliased.loader.mappings))

        var zeroFill = fixture()
        zeroFill.loader.sections[1].fileSize = 4
        remap(&zeroFill)
        XCTAssertTrue(try rebuild(zeroFill).jumpTables.isEmpty)
        XCTAssertNil(RehydrationDerivedProducts.mappedBytes(in: zeroFill.bytes, sliceOffset: 0,
            at: 0x9004, count: 4, mappings: zeroFill.loader.mappings))

        var split = fixture()
        split.loader.sections[1].size = 2
        split.loader.sections.append(section(13, "neighbor", 0x9002, 6, 0x42))
        remap(&split)
        XCTAssertTrue(try rebuild(split).jumpTables.isEmpty)
        XCTAssertNil(RehydrationDerivedProducts.mappedBytes(in: split.bytes, sliceOffset: 0,
            at: 0x9000, count: 4, mappings: split.loader.mappings))
    }

    func testDisjointCodeAndNonzeroSliceOffsetPreserveAuthority() throws {
        var f = fixture()
        f.loader.sections = [
            section(1, "__TEXT,__first", 0x4200, 0x40, 0, executable: true),
            section(2, "__TEXT,__second", 0x4300, 0x40, 0x40, executable: true),
            section(3, "__DATA,__not_exec", 0x4380, 0x40, 0x80, executable: true),
            section(4, "table", 0x9000, 0x28, 0xc0)]
        var slice = Data(repeating: 0, count: 0xe8)
        slice.replaceSubrange(0xc0..<0xc8, with: [0x20, 0xb2, 0xff, 0xff, 0x28, 0xb2, 0xff, 0xff])
        // Gap function table: 0x42A0 - 0x9010 = -0x4D70; second destination 0x42A8.
        slice.replaceSubrange(0xd0..<0xd8, with: [0x90, 0xb2, 0xff, 0xff, 0x98, 0xb2, 0xff, 0xff])
        // Non-executable owner's table: 0x43A0 - 0x9020 = -0x4C80; second 0x43A8.
        slice.replaceSubrange(0xe0..<0xe8, with: [0x80, 0xb3, 0xff, 0xff, 0x88, 0xb3, 0xff, 0xff])
        let backing = Data([0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xef, 0xf0, 0xf1]) + slice
        f.bytes = backing[3...]
        XCTAssertEqual(f.bytes.startIndex, 3)
        f.loader.sliceOffset = 5
        f.loader.sliceSize = UInt64(slice.count)
        f.loader.preferredSegmentLayout = try .init(records: [
            .init(name: "__TEXT", preferredVMStart: 0x4200, preferredVMSize: 0x40,
                  sliceRelativeFileOffset: 0, fileSize: 0x40, initialProtections: 5),
            .init(name: "__TEXT2", preferredVMStart: 0x4300, preferredVMSize: 0x40,
                  sliceRelativeFileOffset: 0x40, fileSize: 0x40, initialProtections: 5),
            .init(name: "__DATA", preferredVMStart: 0x4380, preferredVMSize: 0x40,
                  sliceRelativeFileOffset: 0x80, fileSize: 0x40, initialProtections: 3)
        ], selectedSliceByteCount: UInt64(slice.count))
        f.persisted.instructions += rows(start: 0x4280, table: 0x9010) + rows(start: 0x4380, table: 0x9020)
        f.persisted.instructions.sort { $0.address < $1.address }
        f.persisted.functions += [function(20, start: 0x4280, end: 0x42c0),
                                  function(21, start: 0x4380, end: 0x43c0)]
        remap(&f)
        XCTAssertEqual(RehydrationDerivedProducts.executableCodeSections(sections: f.loader.sections,
            layout: f.loader.preferredSegmentLayout, mappings: f.loader.mappings).map(\.address), [0x4200, 0x4300])
        XCTAssertNil(RehydrationDerivedProducts.mappedBytes(in: f.bytes, sliceOffset: 5,
            at: 0x4280, count: 4, mappings: f.loader.mappings))
        XCTAssertEqual(try rebuild(f).jumpTables, [0x4218: [0x4220, 0x4228]])
    }

    func testOverlappingAndOverflowingFunctionsRemainOpaque() throws {
        let variants: [[FunctionSummary]] = [
            [function(), function(22, start: 0x4220, end: 0x4250)],
            [function(start: 0x4200, end: 0x4200)],
            [function(start: UInt64.max - 15, end: 16)]
        ]
        for functions in variants {
            var f = fixture()
            f.persisted.functions = functions
            XCTAssertTrue(try rebuild(f).jumpTables.isEmpty)
        }
        var missingTarget = fixture()
        missingTarget.persisted.instructions.removeAll { $0.address == 0x4228 }
        XCTAssertTrue(try rebuild(missingTarget).jumpTables.isEmpty, "Reject the complete table, not only the missing case")
    }

    func testReconstructedDiagnosticsPreserveLoaderEvidence() throws {
        var f = fixture()
        f.persisted.instructions[f.persisted.instructions.count - 1].mnemonic = "unknown"
        f.persisted.controlFlowEdges.append(.init(id: uuid(30), from: 0x4200, to: 0x4400, kind: "branch"))
        f.persisted.xrefs.append(.init(id: uuid(31), from: 0x4204, to: 0xa000, kind: XRefKind.data))
        f.loader.loaderTruncations = [.init(address: 0x4240, message: "third-party text must not escape")]
        f.loader.loaderFindings = [.init(category: .unsupportedFixup, code: "fixtureUnsupported",
                                        address: 0x4244, message: "Unsupported fixture fixup.")]
        f.loader.parserDisagreements = [.init(address: 0x4248, engines: [.lief], facts: [.sectionSize])]
        f.loader.parserCrossCheckSkip = .init(address: 0x424c, reason: .size(byteCount: 2_097_152, limit: 1_048_576))
        let rebuilt = try rebuild(f)
        let expectedKinds: [AnalysisDiagnostic.Kind] = [.undecodedInstruction, .unresolvedBranchTarget,
            .loaderTruncation, .unsupportedLoaderStructure, .parserCrossCheckDisagreement,
            .parserCrossCheckSkipped, .xrefTargetOutsideSections]
        XCTAssertEqual(rebuilt.diagnostics.map(\.kind), expectedKinds)
        XCTAssertEqual(rebuilt.diagnostics.map(\.address), [0x4230, 0x4400, 0x4240, 0x4244, 0x4248, 0x424c, 0xa000])
        XCTAssertEqual(rebuilt.diagnostics.map { $0.sourceCoordinate?.address },
                       [0x4230, 0x4200, 0x4240, 0x4244, 0x4248, 0x424c, 0x4204])
        XCTAssertEqual(rebuilt.diagnostics.map(\.severity), [.error, .error, .warning, .warning, .warning, .warning, .warning])
        XCTAssertEqual(rebuilt.diagnostics.map(\.provenance), [.decoder, .controlFlow, .loader, .loader,
                                                              .parserCrossCheck, .parserCrossCheck, .crossReference])
        XCTAssertEqual(rebuilt.diagnostics[2].message, "The loader reported a truncated or over-read structure.")
        XCTAssertEqual(rebuilt.diagnostics[4].message, "LIEF disagrees with MacScope's loader here: section size.")
        XCTAssertTrue(rebuilt.diagnostics.allSatisfy { $0.authority == nil }) // Existing image-local engine semantics.
        let authority = try XCTUnwrap(AnalysisDiagnostic.Authority(imageID: uuid(32), documentID: uuid(33),
            sessionID: uuid(34), runID: uuid(35), analysisGeneration: 7))
        let fence = AnalysisDiagnosticsPublicationFence(authority: authority)
        let owned = AnalysisDiagnosticsCollector().collect(.init(instructions: rebuilt.instructions,
            controlFlowEdges: rebuilt.controlFlowEdges, xrefs: rebuilt.xrefs, sections: rebuilt.sections,
            loaderTruncations: f.loader.loaderTruncations, parserDisagreements: f.loader.parserDisagreements,
            parserCrossCheckSkip: f.loader.parserCrossCheckSkip, loaderFindings: f.loader.loaderFindings,
            authority: authority, publicationPermit: fence.permit(for: authority)))
        XCTAssertEqual(owned.map(\.kind), expectedKinds)
        XCTAssertTrue(owned.allSatisfy { $0.isCurrent(for: authority) })
        assertPreserved(rebuilt, f.persisted)
    }

    func testCancellationDoesNotPublishDerivedProducts() throws {
        let f = fixture()
        XCTAssertThrowsError(try rebuild(f, cancellation: AnalysisCancellationToken { true })) {
            XCTAssertTrue($0 is AnalysisCancelled)
        }
        let counter = CheckpointCounter(cancelAt: 5)
        XCTAssertThrowsError(try rebuild(f, cancellation: AnalysisCancellationToken { counter.check() })) {
            XCTAssertTrue($0 is AnalysisCancelled)
        }
        XCTAssertGreaterThanOrEqual(counter.count, 5)
        XCTAssertTrue(f.persisted.jumpTables.isEmpty)
        XCTAssertTrue(f.persisted.sections.isEmpty)
        XCTAssertEqual(f.persisted.instructions[0].comment, "Keep the authored comment exactly.")
    }

    func testContradictoryMappingAndSliceFactsAreRejected() throws {
        var f = fixture()
        f.loader.mappings[1].fileOffset += 1
        XCTAssertThrowsError(try rebuild(f)) { XCTAssertEqual($0 as? RehydrationLoaderProducts.Failure, .invalidAuthority) }
        f = fixture()
        f.loader.sliceSize = UInt64(f.bytes.count + 1)
        XCTAssertThrowsError(try rebuild(f)) { XCTAssertEqual($0 as? RehydrationLoaderProducts.Failure, .invalidAuthority) }
        f = fixture()
        f.loader.sliceOffset = UInt64.max
        XCTAssertThrowsError(try rebuild(f)) { XCTAssertEqual($0 as? RehydrationLoaderProducts.Failure, .invalidAuthority) }
    }

    func testRequestCorrelationCannotAdmitAnotherLoaderReply() throws {
        let f = fixture()
        try f.loader.validate(imageByteCount: f.bytes.count, requestedSliceIndex: nil, requestID: uuid(11))
        XCTAssertThrowsError(try f.loader.validate(imageByteCount: f.bytes.count,
            requestedSliceIndex: nil, requestID: uuid(99))) {
            XCTAssertEqual($0 as? RehydrationLoaderProducts.Failure, .mismatchedRequest)
        }
        XCTAssertThrowsError(try f.loader.validate(imageByteCount: f.bytes.count,
            requestedSliceIndex: 1, requestID: uuid(11))) {
            XCTAssertEqual($0 as? RehydrationLoaderProducts.Failure, .mismatchedRequest)
        }
    }

    func testConstantStringsMergeAndTypeCatalogRefresh() throws {
        var f = fixture()
        f.persisted.stringLiterals = [.init(id: uuid(40), value: "saved literal", address: 0x9100,
            sourceSection: "__TEXT,__cstring", byteLength: 14)]
        f.persisted.constantStrings = [0x9200: .init(text: "retained CF", kind: .cfString),
                                      0x9208: .init(text: "stale CF", kind: .cfString)]
        f.loader.constantCFStrings = [0x9208: "loaded CF", 0x9210: "new CF"]
        f.persisted.typeCatalog = .empty(in: ImageSlot(rawValue: 7))
        f.loader.objcSelectors = [0x9300: "freshSelector:"]
        let rebuilt = try rebuild(f)
        XCTAssertEqual(rebuilt.constantStrings, [0x9100: .init(text: "saved literal", kind: .cString),
            0x9200: .init(text: "retained CF", kind: .cfString),
            0x9208: .init(text: "loaded CF", kind: .cfString), 0x9210: .init(text: "new CF", kind: .cfString)])
        XCTAssertEqual(rebuilt.objcSelectors, [0x9300: "freshSelector:"])
        XCTAssertNotNil(rebuilt.typeCatalog)
        XCTAssertEqual(rebuilt.typeCatalog, ImageTypeCatalogBuilder.build(analysis: rebuilt))
        assertPreserved(rebuilt, f.persisted)
    }

    func testPreferredSegmentNeedsUniqueExecutableOwner() throws {
        var f = fixture()
        let owner = MachOPreferredSegmentLayout.Record(name: "__TEXT", preferredVMStart: 0x4200,
            preferredVMSize: 0x40, sliceRelativeFileOffset: 0, fileSize: 0x40, initialProtections: 5)
        f.loader.preferredSegmentLayout = try .init(records: [owner, owner], selectedSliceByteCount: UInt64(f.bytes.count))
        XCTAssertTrue(try rebuild(f).jumpTables.isEmpty)
        let nonExecutable = MachOPreferredSegmentLayout.Record(name: "__DATA", preferredVMStart: 0x4200,
            preferredVMSize: 0x40, sliceRelativeFileOffset: 0, fileSize: 0x40, initialProtections: 3)
        f.loader.preferredSegmentLayout = try .init(records: [nonExecutable], selectedSliceByteCount: UInt64(f.bytes.count))
        XCTAssertTrue(try rebuild(f).jumpTables.isEmpty)
    }

    func testFileBackedPrefixDoesNotAuthorizeVirtualTail() throws {
        var f = fixture()
        f.loader.sections[0].size = 0x80
        f.loader.sections[0].fileSize = 0x40
        remap(&f)
        let admitted = RehydrationDerivedProducts.executableCodeSections(sections: f.loader.sections,
            layout: nil, mappings: f.loader.mappings)
        XCTAssertEqual(admitted.map(\.size), [0x40])
        XCTAssertEqual(try rebuild(f).jumpTables, [0x4218: [0x4220, 0x4228]])
        f.persisted.functions = [function(end: 0x4280)]
        XCTAssertTrue(try rebuild(f).jumpTables.isEmpty)
        XCTAssertNil(RehydrationDerivedProducts.mappedBytes(in: f.bytes, sliceOffset: 0,
            at: 0x4240, count: 1, mappings: f.loader.mappings))
    }

    func testExecutableCandidateBoundRemainsFailClosed() throws {
        var f = fixture()
        f.loader.sections = (0..<257).map { index in
            section(100 + index, "tiny\(index)", 0x10000 + UInt64(index * 2), 1,
                    UInt64(index), executable: true)
        }
        f.bytes = Data(repeating: 0, count: 257)
        f.loader.sliceSize = 257
        remap(&f)
        XCTAssertTrue(RehydrationDerivedProducts.executableCodeSections(sections: f.loader.sections,
            layout: nil, mappings: f.loader.mappings).isEmpty)
        XCTAssertTrue(try rebuild(f).jumpTables.isEmpty)
        let boundaries = [
            section(400, "zero", 0x5000, 0, 0, executable: true),
            section(401, "overflow", UInt64.max - 3, 4, 0, executable: true),
            section(402, "valid_exclusive_end", UInt64.max - 8, 4, 4, executable: true)
        ]
        let mappings = FileAddressMapping.verifiedMappings(from: boundaries, payloadLength: 8)
        XCTAssertEqual(RehydrationDerivedProducts.executableCodeSections(sections: boundaries,
            layout: nil, mappings: mappings).map(\.name), ["valid_exclusive_end"])
    }

    private final class CheckpointCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        private let cancelAt: Int
        init(cancelAt: Int) { self.cancelAt = cancelAt }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        func check() -> Bool {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value >= cancelAt
        }
    }
}
