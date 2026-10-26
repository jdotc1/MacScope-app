import XCTest
@testable import MacScope

final class FieldDeclaratorSemanticsCodableTests: XCTestCase {
    func testEveryProvenanceCaseRoundTrips() throws {
        for semantics in FieldDef.DeclaratorSemanticsV1.allCases {
            let field = FieldDef(
                name: "member",
                type: "uint64_t",
                declaratorSemanticsV1: semantics
            )
            let data = try JSONEncoder().encode(field)
            XCTAssertEqual(try JSONDecoder().decode(FieldDef.self, from: data), field)
        }
    }

    func testAbsentLegacyProvenanceDecodesAsNil() throws {
        let data = Data(#"{"name":"member","type":"uint64_t"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(FieldDef.self, from: data).declaratorSemanticsV1)
    }
}
