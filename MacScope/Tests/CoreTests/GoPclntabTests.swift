import Foundation
import XCTest
import MacScopeParserEngines
@testable import MacScope

final class GoPclntabTests: XCTestCase {
    private func fixture() throws -> LoadedBinary {
        try MachOBinaryLoader().load(at: TestSourceRoot.url.appendingPathComponent("Scripts/parser-oracles/go-pclntab/stripped.bin"))
    }

    func testStrippedFixtureSeedsNamesAndPreservesRealSymbol() throws {
        let loaded = try fixture()
        XCTAssertFalse(loaded.symbols.contains { $0.name.contains("ownedAdd") })
        let raw = try XCTUnwrap(NativeParserEngines.document(for: loaded.bytes, call: macscope_gomacho_go_functions))
        let parsed = try JSONDecoder().decode(NativeParserEngines.GoFunctionDocument.self, from: raw)
        XCTAssertEqual(parsed.status, "parsed", parsed.reason ?? "no reason")
        let enriched = NativeParserEngines.applyingGoFunctions(parsed, to: loaded)
        let added = try XCTUnwrap(enriched.symbols.first { $0.name == "main.ownedAdd" })
        XCTAssertEqual(added.kind, "Go pclntab")
        XCTAssertNil(added.rawLinkageName)
        XCTAssertTrue(enriched.functionStarts.contains(try XCTUnwrap(added.address)))
        XCTAssertNotNil(enriched.symbols.first { $0.name == "main.ownedChoose" })
        XCTAssertNotNil(enriched.symbols.first { $0.name == "main.main" })
        // Test precedence without parsing identical bytes twice.
        XCTAssertTrue(parsed.functions?.contains { $0.name == "main.ownedAdd" && ($0.line ?? 0) > 0 && $0.sourceFile?.hasSuffix("fixture.go") == true } == true)
        var withSymbol = loaded
        let real = SymbolSummary(id: UUID(), name: "real_linker_name", address: added.address,
                                 kind: "Defined", libraryName: nil, rawLinkageName: "_real_linker_name")
        withSymbol.symbols.append(real)
        let preserved = NativeParserEngines.applyingGoFunctions(parsed, to: withSymbol)
        XCTAssertEqual(preserved.symbols.filter { $0.address == added.address }, [real])
        let snapshot = try AnalysisEngine(binaryEnrichment: {
            NativeParserEngines.applyingGoFunctions(parsed, to: $0)
        }).analyze(url: TestSourceRoot.url.appendingPathComponent("Scripts/parser-oracles/go-pclntab/stripped.bin"))
        XCTAssertEqual(snapshot.functions.first { $0.startAddress == added.address }?.name, "main.ownedAdd")

    }

    func testMalformedTableRefusesWithoutPartialSeeds() throws {
        var loaded = try fixture()
        let section = try XCTUnwrap(loaded.sections.first { $0.name.hasSuffix(",__gopclntab") || $0.name == "__gopclntab" })
        let offset = Int(loaded.sliceOffset + section.fileOffset)
        // The loader captures read-only mapped storage; make owned bytes before mutation.
        loaded.bytes = loaded.bytes.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) }
        loaded.bytes.replaceSubrange(offset..<(offset + 4), with: [0, 0, 0, 0])
        let raw = try XCTUnwrap(NativeParserEngines.document(for: loaded.bytes, call: macscope_gomacho_go_functions))
        let parsed = try JSONDecoder().decode(NativeParserEngines.GoFunctionDocument.self, from: raw)
        let after = NativeParserEngines.applyingGoFunctions(parsed, to: loaded)
        XCTAssertEqual(after.symbols, loaded.symbols)
        XCTAssertEqual(after.functionStarts, loaded.functionStarts)
        XCTAssertEqual(parsed.status, "rejected")
        XCTAssertEqual(parsed.reason, "unsupported")
        XCTAssertNil(parsed.functions)
    }

    func testLinkerDataRowsDoNotBecomeFunctionSeeds() throws {
        var loaded = try fixture()
        loaded.symbols = []
        loaded.functionStarts = []
        let start = try XCTUnwrap(loaded.executableTextSection).address
        let document = NativeParserEngines.GoFunctionDocument(status: "parsed", functions: [
            .init(name: "go:textfipsend", start: start, end: start + 1),
            .init(name: "main.known", start: start + 4, end: start + 8)
        ])
        let enriched = NativeParserEngines.applyingGoFunctions(document, to: loaded)
        XCTAssertEqual(enriched.functionStarts, [start + 4])
        XCTAssertEqual(enriched.symbols.map(\.name), ["main.known"])
        var malformed = document
        malformed.functions?[0].name = "main.unaligned"
        XCTAssertEqual(NativeParserEngines.applyingGoFunctions(malformed, to: loaded).functionStarts, [])
    }

    /// Explicit metadata witness; counts seeds/symbols, not completed analysis functions.
    func testHomebrewGHWitness() throws {
        guard ProcessInfo.processInfo.environment["MACSCOPE_GO_GH_WITNESS"] == "1" else {
            return // This host-bound witness is selected explicitly; no routine host dependency.
        }
        let loaded = try MachOBinaryLoader().load(at: URL(fileURLWithPath: "/opt/homebrew/bin/gh"))
        let raw = try XCTUnwrap(NativeParserEngines.document(for: loaded.bytes, call: macscope_gomacho_go_functions))
        let parsed = try JSONDecoder().decode(NativeParserEngines.GoFunctionDocument.self, from: raw)
        XCTAssertEqual(parsed.status, "parsed", parsed.reason ?? "no bridge reason")
        print("GO_PCLNTAB_AUTHORITY version=\(parsed.goVersion ?? "header") provenance=\(parsed.textBaseProvenance ?? "matching header")")
        print("GO_PCLNTAB_STATUS status=\(parsed.status) reason=\(parsed.reason ?? "none") rows=\(parsed.functions?.count ?? 0)")
        let enriched = NativeParserEngines.applyingGoFunctions(parsed, to: loaded)
        let goNames = enriched.symbols.filter { $0.kind == "Go pclntab" }
        XCTAssertGreaterThan(goNames.count, 1000)
        XCTAssertFalse(goNames.contains { ["go:buildid", "go:textfipsstart", "go:textfipsend"].contains($0.name) })
        print("GO_PCLNTAB_WITNESS beforeSymbols=\(loaded.symbols.count) afterSymbols=\(enriched.symbols.count) beforeSeeds=\(loaded.functionStarts.count) afterSeeds=\(enriched.functionStarts.count) addedNames=\(goNames.count)")
        for name in ["main.main", "runtime.main", "runtime.goexit"] {
            let symbol = try XCTUnwrap(enriched.symbols.first { $0.name == name }, name)
            let address = try XCTUnwrap(symbol.address)
            let before = loaded.symbols.first { $0.address == address }?.name ?? "<no symbol>"
            print("GO_PCLNTAB_NAME address=\(String(address, radix: 16)) before=\(before) after=\(name)")
        }
    }
}
