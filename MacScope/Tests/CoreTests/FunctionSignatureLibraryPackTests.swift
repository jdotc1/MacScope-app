import XCTest
@testable import MacScope

final class FunctionSignatureLibraryPackTests: XCTestCase {
    private func record(_ name: String) -> FunctionSignature {
        let bytes: [UInt8] = [0, 0, 0x80, 0xd2, 0x21, 0, 0x80, 0xd2, 0x42, 0, 0x80, 0xd2, 0xc0, 3, 0x5f, 0xd6]
        return FunctionSignature(architecture: .arm64, name: name, libraryName: "DOT01-fixture", totalLength: 16,
            prefix: FunctionSignatureMaskedPattern(bytes: bytes, comparisonMask: Array(repeating: 255, count: 16)),
            checksum: FunctionSignatureChecksumSpan(offset: 16, byteCount: 0, crc32: 0),
            collisionTail: FunctionSignatureCollisionTail(byteRuns: [], importedReferences: []))
    }

    func testEqualPredicatesWithDifferentNamesRemainAmbiguous() {
        let a = record("first"), b = record("second")
        let matcher = FunctionSignatureMatcher(database: FunctionSignatureDatabase(schemaVersion: 1, signatures: [a, b]))
        XCTAssertEqual(matcher.validatedSignatureCount, 2)
        XCTAssertEqual(matcher.match(FunctionSignatureCandidate(architecture: .arm64, bytes: a.prefix.bytes, importedReferences: [:])),
            .ambiguous([FunctionSignatureIdentity(name: "first", libraryName: "DOT01-fixture"), FunctionSignatureIdentity(name: "second", libraryName: "DOT01-fixture")]))
    }

    func testRepeatedIdenticalIdentityKeepsOneUsablePredicate() {
        let a = record("first")
        let matcher = FunctionSignatureMatcher(database: FunctionSignatureDatabase(schemaVersion: 1, signatures: [a, a]))
        XCTAssertEqual(matcher.validatedSignatureCount, 1)
        XCTAssertEqual(matcher.validationIssues.map(\.reason), [.duplicatePredicate])
        XCTAssertEqual(matcher.match(FunctionSignatureCandidate(architecture: .arm64, bytes: a.prefix.bytes, importedReferences: [:])),
            .unique(FunctionSignatureIdentity(name: "first", libraryName: "DOT01-fixture")))
    }
}
