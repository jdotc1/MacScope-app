import Foundation
import XCTest
@testable import MacScope

/// RX-03: the analysis worker's independent parser engines (vendored LIEF, pe-parse and
/// go-macho, linked from cached static archives) exercised through the same code the worker
/// runs: `NativeParserEngines` directly, and `AnalysisEngine(parserCrossCheck:)` end to end.
/// Fixtures are the in-tree corkami PE specimens and the deterministic RX-03 specimens.
final class ParserCrossCheckTests: XCTestCase {
    private static let repositoryRoot = TestSourceRoot.fileURL(#filePath)
        .deletingLastPathComponent()   // CoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // MacScope
        .deletingLastPathComponent()   // repository

    private func fixture(_ relative: String) throws -> URL {
        let url = Self.repositoryRoot.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture is not present in this source tree: \(relative)")
        }
        return url
    }

    private func specimen(_ name: String) throws -> URL {
        try fixture("Scripts/parser-oracles/specimens/\(name)")
    }

    private func corkami(_ name: String) throws -> URL {
        try fixture("ThirdParty/CorkamiPocs/PE/bin/\(name)")
    }

    private func observation(_ reports: [ParserEngineReport], _ engine: ParserEngineID) -> ParserEngineReport.Observation? {
        reports.first(where: { $0.engine == engine })?.observation
    }

    private func parserRows(_ snapshot: WorkspaceSnapshot) -> [AnalysisDiagnostic] {
        snapshot.diagnostics.filter { $0.kind == .parserCrossCheckDisagreement }
    }

    // MARK: - Native engines (worker code path)

    func testLinkedEnginesReportTheirPinnedIdentity() {
        let identity = NativeParserEngines.identity
        XCTAssertTrue(identity.contains("\"lief\":{\"git_revision\":\"d05b3499b6934137e917c009a4df0a9dc8cb11c5\",\"version\":\"1.0.0\"}"), identity)
        XCTAssertTrue(identity.contains("\"version\":\"2.1.1\""), identity)
        XCTAssertTrue(identity.contains("\"version\":\"1.1.283\""), identity)
    }

    func testCorkamiPESpecimensParseInBothPEEngines() throws {
        for name in ["normal.exe", "normal64.exe", "nosectionW7.exe"] {
            let bytes = try Data(contentsOf: corkami(name))
            XCTAssertEqual(ParserCrossCheckFormat.classify(sliceBytes: bytes), .pe, name)
            let reports = NativeParserEngines().reports(forSliceBytes: bytes, format: .pe)
            XCTAssertEqual(reports.map(\.engine), [.lief, .peParse], name)
            for report in reports {
                guard case let .parsed(facts) = report.observation else {
                    return XCTFail("\(report.engine) rejected \(name)")
                }
                XCTAssertEqual(facts.sections.count, name == "nosectionW7.exe" ? 0 : 1, "\(report.engine) \(name)")
            }
        }
    }

    func testCorkamiTinyIsABoundaryTheEnginesDisagreeOn() throws {
        let bytes = try Data(contentsOf: corkami("tiny.exe"))
        let reports = NativeParserEngines().reports(forSliceBytes: bytes, format: .pe)
        guard case .parsed = observation(reports, .lief) else { return XCTFail("LIEF should parse tiny.exe") }
        XCTAssertEqual(observation(reports, .peParse), .rejected)
    }

    func testMachOEnginesAgreeOnSynthesizedSpecimens() throws {
        for name in ["macho-thin-arm64-exec.bin", "macho-arm64e-dylib.bin"] {
            let bytes = try Data(contentsOf: specimen(name))
            XCTAssertEqual(ParserCrossCheckFormat.classify(sliceBytes: bytes), .machO)
            let reports = NativeParserEngines().reports(forSliceBytes: bytes, format: .machO)
            XCTAssertEqual(reports.map(\.engine), [.lief, .goMacho])
            guard case let .parsed(lief) = observation(reports, .lief),
                  case let .parsed(goMacho) = observation(reports, .goMacho) else {
                return XCTFail("both Mach-O engines must parse \(name)")
            }
            XCTAssertEqual(lief, goMacho, name)
            XCTAssertEqual(lief.sections.map(\.name), ["__TEXT,__text"], name)
        }
    }

    func testMalformedInputIsRejectedNotCrashed() throws {
        let bytes = try Data(contentsOf: specimen("macho-sizeofcmds-overflow.bin"))
        let reports = NativeParserEngines().reports(forSliceBytes: bytes, format: .machO)
        XCTAssertEqual(observation(reports, .goMacho), .rejected)
        let garbage = Data(repeating: 0xFF, count: 64)
        for format in [ParserCrossCheckFormat.machO, .pe] {
            for report in NativeParserEngines().reports(forSliceBytes: garbage, format: format) {
                XCTAssertEqual(report.observation, .rejected, "\(report.engine) \(format)")
            }
        }
    }

    // MARK: - AnalysisEngine end to end (the worker's analyze path)

    private func analyze(_ url: URL, slice: Int? = nil) throws -> WorkspaceSnapshot {
        try AnalysisEngine(parserCrossCheck: NativeParserEngines()).analyze(url: url, requestedSliceIndex: slice)
    }

    func testAgreeingImagesProduceNoCrossCheckRows() throws {
        XCTAssertEqual(parserRows(try analyze(specimen("macho-thin-arm64-exec.bin"))), [])
        XCTAssertEqual(parserRows(try analyze(specimen("pe-pe32plus-imports.bin"))), [])
    }

    /// corkami normal64.exe declares its import directory with Size 0 (only the RVA is set).
    /// The Windows loader ignores that Size and binds kernel32!ExitProcess and msvcrt!printf;
    /// MacScope's loader does the same, while LIEF and pe-parse treat a zero-sized directory as
    /// absent (both goldens record import_count 0). The image is therefore NOT an agreeing
    /// specimen: the row is a genuine engine boundary and must stay visible.
    func testZeroSizedImportDirectoryIsAnEngineBoundary() throws {
        let snapshot = try analyze(corkami("normal64.exe"))
        XCTAssertEqual(snapshot.imports.map(\.name).sorted(), ["ExitProcess", "printf"])
        let rows = parserRows(snapshot)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.message, "LIEF, pe-parse disagree with MacScope's loader here: import count.")
    }

    func testEachFatSliceIsCheckedWithItsOwnBytes() throws {
        for slice in [0, 1] {
            XCTAssertEqual(parserRows(try analyze(specimen("macho-fat-x86_64-arm64.bin"), slice: slice)), [], "slice \(slice)")
        }
    }

    func testLongPESectionNameDisagreementIsSurfaced() throws {
        let snapshot = try analyze(specimen("pe-long-section-name.bin"))
        let rows = parserRows(snapshot)
        let longSection = try XCTUnwrap(snapshot.sections.first(where: { $0.address == 0x1_4000_3000 }))
        // MacScope resolves the COFF string-table name; LIEF and pe-parse keep the raw "/4".
        XCTAssertEqual(longSection.name, ".oracle_long_section_name")
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.address, 0x1_4000_3000)
        XCTAssertEqual(row.severity, .warning)
        XCTAssertEqual(row.provenance, .parserCrossCheck)
        XCTAssertEqual(row.message, "LIEF, pe-parse disagree with MacScope's loader here: section absent, extra section.")
    }

    func testAppSideEngineHasNoCrossCheck() throws {
        let snapshot = try AnalysisEngine().analyze(url: specimen("pe-long-section-name.bin"))
        XCTAssertEqual(parserRows(snapshot), [])
    }

    // MARK: - Comparator (pure)

    private struct FixedEngines: ParserCrossChecking {
        var reports: [ParserEngineReport]
        func reports(forSliceBytes _: Data, format _: ParserCrossCheckFormat) -> [ParserEngineReport] { reports }
    }

    func testRejectionSizeAndExtraSectionAreAggregatedPerAddress() throws {
        let loaded = try MachOBinaryLoader().load(at: specimen("macho-thin-arm64-exec.bin"))
        let text = try XCTUnwrap(loaded.sections.first)
        var facts = ParserEngineFacts(cpuType: loaded.cpuType, sections: [
            .init(name: text.name, address: text.address, size: text.size + 4),
            .init(name: "__DATA,__extra", address: 0x1_0000_8000, size: 8),
        ], uuid: loaded.artifactIdentity?.uuid, entryPointAddress: nil, importCount: nil)
        let rows = ParserCrossCheckComparator.disagreements(loaded: loaded, format: .machO, reports: [
            ParserEngineReport(engine: .lief, observation: .parsed(facts)),
            ParserEngineReport(engine: .goMacho, observation: .rejected),
        ])
        XCTAssertEqual(rows.map(\.address), [text.address, 0x1_0000_8000])
        XCTAssertEqual(rows[0].engines, [.lief, .goMacho])
        XCTAssertEqual(rows[0].facts, [.sectionSize, .engineRejected])
        XCTAssertEqual(rows[1].facts, [.sectionUnexpected])

        facts.uuid = UUID()
        facts.sections = [.init(name: text.name, address: text.address, size: text.size)]
        let uuidRows = ParserCrossCheckComparator.disagreements(loaded: loaded, format: .machO, reports: [
            ParserEngineReport(engine: .lief, observation: .parsed(facts)),
        ])
        XCTAssertEqual(uuidRows.map(\.facts), [[.uuid]])
    }

    // MARK: - Cost controls (decision D4)

    /// Records every engine invocation so tests can prove when the engines did NOT run.
    private final class CountingEngines: ParserCrossChecking, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        let reports: [ParserEngineReport]

        init(reports: [ParserEngineReport]) { self.reports = reports }

        var calls: Int { lock.withLock { _calls } }

        func reports(forSliceBytes _: Data, format _: ParserCrossCheckFormat) -> [ParserEngineReport] {
            lock.withLock { _calls += 1 }
            return reports
        }
    }

    private func skipRows(_ snapshot: WorkspaceSnapshot) -> [AnalysisDiagnostic] {
        snapshot.diagnostics.filter { $0.kind == .parserCrossCheckSkipped }
    }

    func testVerdictIsCachedPerSliceDigestAcrossReanalysisAndEngines() throws {
        let engines = CountingEngines(reports: [ParserEngineReport(engine: .peParse, observation: .rejected)])
        let cache = ParserCrossCheckVerdictCache()
        let first = AnalysisEngine(parserCrossCheck: engines, parserCrossCheckCache: cache)
        let pe = try specimen("pe-pe32plus-imports.bin")
        let machO = try specimen("macho-thin-arm64-exec.bin")

        let initial = parserRows(try first.analyze(url: pe))
        XCTAssertEqual(initial.count, 1)
        XCTAssertEqual(parserRows(try first.analyze(url: pe)), initial, "reanalysis reuses the verdict")
        XCTAssertEqual(engines.calls, 1)

        // A second engine (another worker connection) sharing the process cache does not re-run.
        let second = AnalysisEngine(parserCrossCheck: engines, parserCrossCheckCache: cache)
        XCTAssertEqual(parserRows(try second.analyze(url: pe)), initial)
        XCTAssertEqual(engines.calls, 1)

        // Different bytes are a different digest; the Mach-O key comes from the verified identity.
        let loaded = try MachOBinaryLoader().load(at: machO)
        XCTAssertEqual(
            AnalysisEngine.parserCrossCheckDigest(of: try Data(contentsOf: machO), loaded: loaded),
            try XCTUnwrap(loaded.artifactIdentity?.selectedSliceSHA256)
        )
        _ = try first.analyze(url: machO)
        _ = try second.analyze(url: machO)
        XCTAssertEqual(engines.calls, 2)
        XCTAssertEqual(cache.count, 2)
    }

    func testVerdictCacheIsBounded() {
        let cache = ParserCrossCheckVerdictCache()
        for index in 0 ... ParserCrossCheckVerdictCache.maximumEntries {
            let key = ParserCrossCheckVerdictCache.Key(sha256: String(index), byteCount: index, format: .pe)
            _ = cache.reports(for: key) { [] }
        }
        XCTAssertEqual(cache.count, ParserCrossCheckVerdictCache.maximumEntries)
    }

    func testOversizedSliceIsSkippedWithOneSizeDiagnostic() throws {
        XCTAssertEqual(AnalysisEngine.maximumParserCrossCheckBytes, 64 * 1_024 * 1_024)
        let engines = CountingEngines(reports: [ParserEngineReport(engine: .lief, observation: .rejected)])
        let engine = AnalysisEngine(parserCrossCheck: engines, parserCrossCheckByteLimit: 64)
        let snapshot = try engine.analyze(url: specimen("macho-thin-arm64-exec.bin"))

        XCTAssertEqual(engines.calls, 0, "an oversized slice is never handed to the engines")
        XCTAssertEqual(parserRows(snapshot), [])
        let rows = skipRows(snapshot)
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.severity, .warning)
        XCTAssertEqual(row.provenance, .parserCrossCheck)
        XCTAssertEqual(row.address, snapshot.sections.map(\.address).min())
        XCTAssertTrue(row.message.hasPrefix("Parser cross-check skipped: size."), row.message)
        XCTAssertFalse(snapshot.instructions.isEmpty, "the analysis itself still completes")
    }

    func testSliceAtTheCapIsStillChecked() throws {
        let url = try specimen("macho-thin-arm64-exec.bin")
        let byteCount = try Data(contentsOf: url).count
        let engines = CountingEngines(reports: [])
        let snapshot = try AnalysisEngine(parserCrossCheck: engines, parserCrossCheckByteLimit: byteCount).analyze(url: url)
        XCTAssertEqual(engines.calls, 1)
        XCTAssertEqual(skipRows(snapshot), [])
    }

    func testDyldSharedCacheImagesAreNeverCrossChecked() throws {
        let engines = CountingEngines(reports: [ParserEngineReport(engine: .lief, observation: .rejected)])
        let engine = AnalysisEngine(parserCrossCheck: engines)

        // Projected out of a cache by the loader.
        let fixture = DyldCacheFixture.makeSingleImageCache()
        let projected = try DyldSharedCacheBinaryLoader()
            .loadFromBytes(fixture.bytes, name: "cache", path: "/tmp/cache")
        XCTAssertTrue(projected.isDyldSharedCacheProjection)
        XCTAssertEqual(try engine.parserCrossCheckOutcome(for: projected, cancellation: .never), .notChecked)

        // A standalone file whose header carries MH_DYLIB_IN_CACHE (an extracted cache image).
        var extracted = try MachOBinaryLoader().load(at: specimen("macho-thin-arm64-exec.bin"))
        XCTAssertFalse(extracted.isDyldSharedCacheProjection)
        // The loader's bytes are a read-only `.mappedIfSafe` mapping; writing through it in place
        // is a SIGBUS (KERN_PROTECTION_FAILURE). Mutate an owned copy.
        extracted.bytes = Data([UInt8](extracted.bytes))
        let flagsByte = Int(extracted.sliceOffset) + 27
        extracted.bytes[flagsByte] |= 0x80
        XCTAssertEqual(try engine.parserCrossCheckOutcome(for: extracted, cancellation: .never), .notChecked)
        XCTAssertEqual(engines.calls, 0)

        // Control: the same image without the cache flag is checked.
        extracted.bytes[flagsByte] &= 0x7F
        XCTAssertEqual(try engine.parserCrossCheckOutcome(for: extracted, cancellation: .never).disagreements.count, 1)
        XCTAssertEqual(engines.calls, 1)
    }

    func testInjectedEnginesFlowIntoDiagnostics() throws {
        let engine = AnalysisEngine(parserCrossCheck: FixedEngines(reports: [
            ParserEngineReport(engine: .peParse, observation: .rejected),
        ]))
        let rows = parserRows(try engine.analyze(url: specimen("pe-pe32plus-imports.bin")))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.message, "pe-parse disagrees with MacScope's loader here: rejected the image.")
    }
}
