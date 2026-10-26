import XCTest
@testable import MacScope

final class MacIRNEONMatrixPackedOutputTests: XCTestCase {
    func testExactCompositionCertificateUnitsAndTerminal() {
        let kinds: [MacIRNEONMatrixPackedOutput.Family] = [.loadQ, .matrix, .rounded, .narrow, .storeQ, .terminal]
        let entries = kinds.enumerated().map { n, kind in
            MacIRNEONMatrixPackedOutput.Entry(family: kind, rowOrdinal: n,
                identity: .init(sourceAddress: 0x3100 + UInt64(n * 4), effectOrdinal: 0),
                qTransferOrdinal: kind == .loadQ ? 0 : (kind == .storeQ ? 1 : nil))
        }
        let certificate = MacIRNEONMatrixPackedOutput(entries: entries)
        XCTAssertEqual(certificate?.rowCount, 6)
        XCTAssertEqual(certificate?.effectCount, 6)
        XCTAssertEqual(certificate?.qTransferCount, 2)
        XCTAssertEqual(certificate?.memoryByteCount, 32)
        XCTAssertNil(MacIRNEONMatrixPackedOutput(entries: Array(entries.dropLast())))
        XCTAssertNil(MacIRNEONMatrixPackedOutput(entries: []))
        let pureKinds: [MacIRNEONMatrixPackedOutput.Family] = [.matrix, .rounded, .narrow, .terminal]
        let pure = pureKinds.enumerated().map { n, kind in
            MacIRNEONMatrixPackedOutput.Entry(family: kind, rowOrdinal: n,
                identity: .init(sourceAddress: 0x4100 + UInt64(n * 4), effectOrdinal: 0))
        }
        XCTAssertNil(MacIRNEONMatrixPackedOutput(entries: pure))
    }
}
