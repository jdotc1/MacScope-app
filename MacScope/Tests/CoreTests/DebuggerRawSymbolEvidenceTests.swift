import Foundation
import XCTest
@testable import MacScope

final class DebuggerRawSymbolEvidenceTests: XCTestCase {
    func testFreshMachOLoaderPreservesExactRawLinkageSpelling() throws {
        let fixture = MachOFixture.makeExecutableWithSymbols()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-ws21-raw-symbol-\(UUID().uuidString)")
        try fixture.bytes.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let symbols = try MachOBinaryLoader().load(at: url).symbols
        XCTAssertEqual(symbols.map(\.name), ["_local_helper", "_exported_entry", "_puts"])
        XCTAssertEqual(symbols.map(\.rawLinkageName), symbols.map(\.name))
    }

    func testWorkerPayloadKeepsRawNameIndependentFromDisplayNameByteExact() throws {
        let decomposed = "_$s4Cafe\u{301}6helperyyF"
        let symbol = SymbolSummary(
            id: UUID(),
            name: "Caf\u{e9}.helper()",
            address: 0x1000,
            kind: "export",
            libraryName: nil,
            rawLinkageName: decomposed
        )
        let snapshot = WorkspaceSnapshot(
            binaries: [],
            functions: [],
            symbols: [symbol],
            instructions: [],
            xrefs: [],
            hexBytes: Data()
        )
        let encoded = try JSONEncoder().encode(AnalysisPayloadCodec.payload(from: snapshot))
        let decoded = try JSONDecoder().decode(AnalysisResultPayload.self, from: encoded)
        let reopened = AnalysisPayloadCodec.snapshot(from: decoded)
        let recovered = try XCTUnwrap(reopened.symbols.first)

        XCTAssertEqual(recovered.name, "Caf\u{e9}.helper()")
        XCTAssertEqual(Array(try XCTUnwrap(recovered.rawLinkageName).utf8), Array(decomposed.utf8))
        XCTAssertNotEqual(Array(recovered.name.utf8), Array(decomposed.utf8))
    }

    func testLegacySymbolWithoutRawNameRemainsDisplayableButHasNoAuthority() throws {
        let id = UUID()
        let json = Data(
            #"{"id":"\#(id.uuidString)","name":"display","address":4096,"kind":"export","libraryName":null}"#.utf8
        )
        let decoded = try JSONDecoder().decode(SymbolSummary.self, from: json)

        XCTAssertEqual(decoded.name, "display")
        XCTAssertNil(decoded.rawLinkageName)
    }
}
