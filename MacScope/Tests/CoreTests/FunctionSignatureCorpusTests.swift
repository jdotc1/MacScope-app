import XCTest
@testable import MacScope

final class FunctionSignatureCorpusTests: XCTestCase {
    func testPhaseBStandardCorpusContainsValidatedCompilerRTSignatures() {
        let database = FunctionSignatureCorpus.database
        let matcher = FunctionSignatureMatcher(database: database)

        XCTAssertEqual(database.schemaVersion, FunctionSignatureDatabase.currentSchemaVersion)
        XCTAssertEqual(database.signatures.count, 244)
        XCTAssertEqual(matcher.validatedSignatureCount, 244)
        XCTAssertTrue(matcher.validationIssues.isEmpty)
    }
}
