import Foundation
import XCTest
@testable import MacScope

/// MS-20 (audit section 6, "Failed-decoder rows becoming functions"): a row the ARM64
/// decoder could not decode (`unavailable`: fewer than four bytes of text) must never seed
/// a function, even when LC_FUNCTION_STARTS and the entry point both name its address.
/// The row stays in the listing as honest degraded output; it is just not a procedure.
final class ARM64FailedDecodeSeedTests: XCTestCase {
    private let base: UInt64 = 0x4000
    private let ignoredURL = URL(fileURLWithPath: "/arm64-failed-decode-fixture")
    private let failedMnemonics: Set<String> = ["unavailable", ".byte"]

    func testTruncatedTextUnavailableRowIsNotSeededAsFunction() throws {
        // Two bytes: no complete arm64 instruction word.
        let snapshot = try analyze(Data([0xC0, 0x03]), functionStarts: [base])

        let row = try XCTUnwrap(snapshot.instructions.first { $0.address == base })
        XCTAssertEqual(row.mnemonic, "unavailable", "fixture must exercise the decoder's failed row")
        XCTAssertFalse(snapshot.functions.contains { $0.startAddress == base },
                       "an undecoded `unavailable` row was seeded as a function")
        assertNoFunctionStartsOnFailedRows(snapshot)
    }

    func testFailedRowsNeverStartFunctionsInWholeSnapshot() throws {
        // Same truncated text without any function-start metadata: entry-point seeding alone.
        let snapshot = try analyze(Data([0xC0]), functionStarts: [])
        assertNoFunctionStartsOnFailedRows(snapshot)
    }

    func testCompleteInstructionStillSeedsFunction() throws {
        // Over-correction guard: a real decoded `ret` at the entry must remain a function.
        let snapshot = try analyze(Data([0xC0, 0x03, 0x5F, 0xD6]), functionStarts: [base])
        XCTAssertEqual(snapshot.instructions.first?.mnemonic, "ret")
        XCTAssertTrue(snapshot.functions.contains { $0.startAddress == base })
    }

    private func assertNoFunctionStartsOnFailedRows(
        _ snapshot: WorkspaceSnapshot, file: StaticString = #filePath, line: UInt = #line
    ) {
        let failed = Set(snapshot.instructions.filter { failedMnemonics.contains($0.mnemonic) }.map(\.address))
        let offending = snapshot.functions.filter { failed.contains($0.startAddress) }
        XCTAssertTrue(offending.isEmpty,
                      "functions seeded on failed-decode rows: \(offending.map { String(format: "0x%llx", $0.startAddress) })",
                      file: file, line: line)
    }

    private func analyze(_ data: Data, functionStarts: [UInt64]) throws -> WorkspaceSnapshot {
        let text = BinarySection(name: "__text", address: base, size: UInt64(data.count), fileOffset: 0,
                                 isExecutable: true, fileSize: UInt64(data.count))
        let binary = LoadedBinary(
            name: "arm64-failed-decode-fixture", path: ignoredURL.path, isBundle: false,
            cpuType: MachOConstants.cpuTypeARM64, fileTypeName: "fixture", architectureDisplayName: "arm64",
            metadata: .empty, bytes: data, sliceOffset: 0, sliceSize: UInt64(data.count),
            sections: [text], executableTextSection: text, entryPointAddress: base,
            symbols: [], imports: [], indirectSymbols: [], exports: [], stringLiterals: [],
            functionStarts: functionStarts, objcSelectors: [:]
        )
        return try AnalysisEngine(loader: FailedDecodeFixtureLoader(binary: binary)).analyze(url: ignoredURL)
    }
}

private struct FailedDecodeFixtureLoader: BinaryLoader {
    let binary: LoadedBinary
    func load(at url: URL) throws -> LoadedBinary { binary }
}
