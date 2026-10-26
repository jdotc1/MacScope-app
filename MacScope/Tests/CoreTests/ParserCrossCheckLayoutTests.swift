import Foundation
import XCTest
@testable import MacScope

/// Focused, synthetic neutral-model and adapter tests. These do not require a corpus,
/// an installed app, or executing a specimen. The existing ParserCrossCheckTests retain
/// the linked-engine and real selected-fat-slice integration checks.
final class ParserCrossCheckLayoutTests: XCTestCase {
    private let base: UInt64 = 0x1_0000_0000
    private let sliceByteCount = 0x5000
    private let fixtureUUID = UUID(uuidString: "11223344-5566-7788-99AA-BBCCDDEEFF00")!

    private func rawSlice() throws -> NativeParserEngines.RawMachOSlice {
        let document = try JSONDecoder().decode(
            NativeParserEngines.RawMachODocument.self,
            from: Data(Self.document.utf8)
        )
        XCTAssertEqual(document.status, "parsed")
        return try XCTUnwrap(document.slices?.first)
    }

    private func engineFacts() throws -> ParserEngineFacts {
        try XCTUnwrap(NativeParserEngines.facts(machO: rawSlice()))
    }

    private func loaded(sliceOffset: UInt64 = 0) throws -> LoadedBinary {
        let sections: [BinarySection] = [
            .init(name: "__TEXT,__text", address: base + 0x400, size: 0x40,
                  fileOffset: 0x400, isExecutable: true),
            .init(name: "__TEXT,__empty", address: base + 0x500, size: 0,
                  fileOffset: 0x500, isExecutable: false),
            .init(name: "__DATA,__bss", address: base + 0x4000, size: 0x80,
                  fileOffset: 0, isExecutable: false, isZeroFill: true),
        ]
        let selectedBytes = Data(repeating: 0, count: sliceByteCount)
        let identity = try MachOSliceArtifactIdentity(
            uuid: fixtureUUID,
            rawCPUType: MachOConstants.cpuTypeARM64,
            rawCPUSubtype: 0,
            selectedSliceSHA256: AnalysisFingerprintBuilder.sha256Hex(selectedBytes),
            selectedSliceByteCount: UInt64(sliceByteCount)
        )
        let layout = try MachOPreferredSegmentLayout(records: [
            .init(name: "__PAGEZERO", preferredVMStart: 0, preferredVMSize: base,
                  sliceRelativeFileOffset: 0, fileSize: 0, initialProtections: 0),
            .init(name: "__TEXT", preferredVMStart: base, preferredVMSize: 0x4000,
                  sliceRelativeFileOffset: 0, fileSize: 0x4000, initialProtections: 5),
            .init(name: "__DATA", preferredVMStart: base + 0x4000, preferredVMSize: 0x1000,
                  sliceRelativeFileOffset: 0x4000, fileSize: 0, initialProtections: 3),
            // Go's unmapped __DWARF shape is valid: file bytes with zero VM size.
            .init(name: "__DWARF", preferredVMStart: 0, preferredVMSize: 0,
                  sliceRelativeFileOffset: 0x4000, fileSize: 0x1000, initialProtections: 0),
        ], selectedSliceByteCount: UInt64(sliceByteCount))
        return LoadedBinary(
            name: "layout-fixture", path: "/synthetic/layout-fixture", isBundle: false,
            cpuType: MachOConstants.cpuTypeARM64, cpuSubtype: 0,
            fileTypeName: "Synthetic Mach-O layout", architectureDisplayName: "arm64",
            metadata: .empty,
            artifactIdentity: identity, preferredSegmentLayout: layout,
            artifactIntegrityState: .verified,
            bytes: Data(repeating: 0, count: Int(sliceOffset) + sliceByteCount),
            sliceOffset: sliceOffset, sliceSize: UInt64(sliceByteCount),
            sections: sections, executableTextSection: sections[0],
            entryPointAddress: base + 0x400,
            symbols: [], imports: [], indirectSymbols: [], exports: [],
            stringLiterals: [], functionStarts: [], objcSelectors: [:]
        )
    }

    private func disagreements(
        _ facts: ParserEngineFacts,
        loaded image: LoadedBinary,
        format: ParserCrossCheckFormat = .machO
    ) -> [ParserCrossCheckDisagreement] {
        ParserCrossCheckComparator.disagreements(
            loaded: image, format: format,
            reports: [.init(engine: .lief, observation: .parsed(facts))]
        )
    }

    func testRawAdapterRetains64BitRangesZeroOffsetsAndSubtypeBits() throws {
        var slice = try rawSlice()
        slice.cpusubtype = 0x8000_0002
        let facts = try XCTUnwrap(NativeParserEngines.facts(machO: slice))
        XCTAssertEqual(facts.cpuSubtype, Int32(bitPattern: 0x8000_0002))
        let segments = try XCTUnwrap(facts.segments)
        XCTAssertEqual(segments.count, 4)
        XCTAssertEqual(segments[0].size, base)
        XCTAssertEqual(segments[1].address, base)
        XCTAssertEqual(segments[1].fileOffset, 0)
        XCTAssertEqual(segments[1].fileSize, 0x4000)
        XCTAssertEqual(segments[3].size, 0)
        XCTAssertEqual(segments[3].fileSize, 0x1000)
        XCTAssertEqual(facts.sections.map(\.fileOffset), [0x400, 0x500, 0])
    }

    func testMissingNewFieldsRemainUnknownAndWrongTypedValuesFailDecode() throws {
        let legacy = #"{"cputype":16777228,"segments":[{"name":"__TEXT","sections":[{"name":"__text","segment":"__TEXT","addr":4294968320,"size":64}]}],"uuid":null}"#
        let raw = try JSONDecoder().decode(
            NativeParserEngines.RawMachOSlice.self, from: Data(legacy.utf8)
        )
        let facts = try XCTUnwrap(NativeParserEngines.facts(machO: raw))
        XCTAssertNil(facts.cpuSubtype)
        XCTAssertNil(facts.sections[0].fileOffset)
        XCTAssertNil(facts.segments?.first?.address)
        XCTAssertNil(facts.segments?.first?.fileOffset)
        let wrongType = legacy.replacingOccurrences(
            of: #""name":"__TEXT","sections""#,
            with: #""name":"__TEXT","vmaddr":"4294967296","sections""#
        )
        XCTAssertThrowsError(try JSONDecoder().decode(
            NativeParserEngines.RawMachOSlice.self, from: Data(wrongType.utf8)
        ))
    }

    func testNonzeroContainerOffsetAndExcessSegmentCountAreRejected() throws {
        var slice = try rawSlice()
        slice.fat_offset = 0x1000
        XCTAssertNil(NativeParserEngines.facts(machO: slice))
        slice.fat_offset = 0
        slice.segments = Array(
            repeating: try XCTUnwrap(slice.segments.first),
            count: NativeParserEngines.maximumSegments + 1
        )
        XCTAssertNil(NativeParserEngines.facts(machO: slice))
    }

    func testAgreementIncludesPageZeroAndUnmappedFileBackedSegment() throws {
        XCTAssertEqual(try disagreements(engineFacts(), loaded: loaded()), [])
    }

    func testSectionOffsetUsesSliceCoordinatesAndIgnoresZeroFillAndEmptySections() throws {
        let image = try loaded(sliceOffset: 0x1000)
        var facts = try engineFacts()
        XCTAssertEqual(disagreements(facts, loaded: image), [], "Do not add the outer fat offset")
        facts.sections[0].fileOffset = 0x404
        facts.sections[1].fileOffset = 0xDEAD
        facts.sections[2].fileOffset = 0xBEEF
        let rows = disagreements(facts, loaded: image)
        XCTAssertEqual(rows.map(\.address), [base + 0x400])
        XCTAssertEqual(rows.map(\.facts), [[.sectionFileOffset]])
        facts.sections[0].fileOffset = nil
        XCTAssertEqual(disagreements(facts, loaded: image), [], "Unavailable is not zero")
    }

    func testSegmentRangeDisagreementsUseLoaderCoordinatesAndDoNotChangeAuthority() throws {
        let image = try loaded()
        let originalSections = image.sections
        let originalLayout = image.preferredSegmentLayout
        let originalBytes = image.bytes
        var facts = try engineFacts()
        var segments = try XCTUnwrap(facts.segments)
        segments[1].address = base + 0x100
        segments[1].size = 0x3000
        segments[1].fileOffset = 0x100
        segments[1].fileSize = 0x3000
        facts.segments = segments
        let rows = disagreements(facts, loaded: image)
        XCTAssertEqual(rows.map(\.address), [base])
        XCTAssertEqual(rows.map(\.facts), [[
            .segmentAddress, .segmentSize, .segmentFileOffset, .segmentFileSize,
        ]])
        XCTAssertEqual(image.sections, originalSections)
        XCTAssertEqual(image.preferredSegmentLayout, originalLayout)
        XCTAssertEqual(image.bytes, originalBytes)
    }

    func testUnknownSegmentsDifferFromKnownEmptyAndPartialFieldsStayUnknown() throws {
        let image = try loaded()
        var facts = try engineFacts()
        facts.segments = nil
        XCTAssertEqual(disagreements(facts, loaded: image), [])
        facts.segments = []
        let emptyRows = disagreements(facts, loaded: image)
        XCTAssertFalse(emptyRows.isEmpty)
        XCTAssertTrue(emptyRows.allSatisfy { $0.facts == [.segmentMissing] })
        facts = try engineFacts()
        facts.segments = try XCTUnwrap(facts.segments).map {
            .init(name: $0.name, address: nil, size: nil, fileOffset: nil, fileSize: nil)
        }
        XCTAssertEqual(disagreements(facts, loaded: image), [])
    }

    func testExtraEngineSegmentUsesExistingLoaderAnchor() throws {
        let image = try loaded()
        var facts = try engineFacts()
        var segments = try XCTUnwrap(facts.segments)
        segments.append(.init(
            name: "__ENGINE_ONLY", address: 0x9999_9999,
            size: 0x1000, fileOffset: 0x6000, fileSize: 0x1000
        ))
        facts.segments = segments
        let rows = disagreements(facts, loaded: image)
        XCTAssertEqual(rows.map(\.address), [base + 0x400])
        XCTAssertEqual(rows.map(\.facts), [[.segmentUnexpected]])
    }

    func testKnownWrongArchitectureSubtypeOrUUIDStopsLayoutComparison() throws {
        let image = try loaded()
        for identityMismatch in 0..<3 {
            var facts = try engineFacts()
            facts.sections = []
            facts.segments = []
            switch identityMismatch {
            case 0: facts.cpuType = MachOConstants.cpuTypeX86_64
            case 1: facts.cpuSubtype = 2
            default: facts.uuid = UUID(uuidString: "FFEEDDCC-BBAA-9988-7766-554433221100")
            }
            let rows = disagreements(facts, loaded: image)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?.facts, identityMismatch == 2 ? [.uuid] : [.architecture])
        }
    }

    func testUnavailableNativeLayoutDoesNotBecomeAnEmptyLayout() throws {
        var image = try loaded()
        var facts = try engineFacts()
        facts.segments = []
        image.artifactIntegrityState = .unavailable
        XCTAssertEqual(disagreements(facts, loaded: image), [])
        image.preferredSegmentLayout = nil
        XCTAssertEqual(disagreements(facts, loaded: image), [])
        facts.sections[0].fileOffset = 0x404
        XCTAssertEqual(disagreements(facts, loaded: image).map(\.facts), [[.sectionFileOffset]])
    }

    func testMachORangeFieldsDoNotAffectPEComparison() throws {
        let image = try loaded()
        var facts = try engineFacts()
        facts.cpuSubtype = 2
        facts.segments = []
        facts.sections[0].fileOffset = 0x404
        XCTAssertEqual(disagreements(facts, loaded: image, format: .pe), [])
    }

    func testNewFactReachesExistingDiagnosticCodecAndProblemsRow() throws {
        let image = try loaded()
        var facts = try engineFacts()
        facts.sections[0].fileOffset = 0x404
        let authority = try XCTUnwrap(AnalysisDiagnostic.Authority(
            imageID: UUID(), documentID: UUID(), sessionID: UUID(), runID: UUID(),
            analysisGeneration: 1
        ))
        let diagnostics = AnalysisDiagnosticsCollector().collect(.init(
            instructions: [], controlFlowEdges: [], xrefs: [], sections: [],
            parserDisagreements: disagreements(facts, loaded: image),
            authority: authority
        ))
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics.first?.kind, .parserCrossCheckDisagreement)
        XCTAssertEqual(diagnostics.first?.provenance, .parserCrossCheck)
        let wire = try JSONEncoder().encode(diagnostics)
        let decoded = try JSONDecoder().decode([AnalysisDiagnostic].self, from: wire)
        XCTAssertEqual(decoded, diagnostics)
        let model = ProblemsViewModel(diagnostics: decoded)
        XCTAssertEqual(model.warningCount, 1)
        XCTAssertEqual(model.rows.first?.address, base + 0x400)
        XCTAssertEqual(
            model.rows.first?.message,
            "LIEF disagrees with MacScope's loader here: section file offset."
        )
    }

    private static let document = """
    {
      "status": "parsed",
      "slices": [{
        "cputype": 16777228,
        "cpusubtype": 0,
        "fat_offset": 0,
        "uuid": "112233445566778899aabbccddeeff00",
        "segments": [
          {"name":"__PAGEZERO","vmaddr":0,"vmsize":4294967296,"fileoff":0,"filesize":0,"sections":[]},
          {"name":"__TEXT","vmaddr":4294967296,"vmsize":16384,"fileoff":0,"filesize":16384,"sections":[
            {"name":"__text","segment":"__TEXT","addr":4294968320,"size":64,"offset":1024},
            {"name":"__empty","segment":"__TEXT","addr":4294968576,"size":0,"offset":1280}
          ]},
          {"name":"__DATA","vmaddr":4294983680,"vmsize":4096,"fileoff":16384,"filesize":0,"sections":[
            {"name":"__bss","segment":"__DATA","addr":4294983680,"size":128,"offset":0}
          ]},
          {"name":"__DWARF","vmaddr":0,"vmsize":0,"fileoff":16384,"filesize":4096,"sections":[]}
        ]
      }]
    }
    """
}
