import Foundation
import XCTest
@testable import MacScope

/// Additional executed-QEMU evidence, deliberately separate from the 9,368-vector ratchet.
/// Every vector carries FPSR observations, so successful numeric checks remain UNSUPPORTED.
final class MacIRScalarFPExtraOracleTests: XCTestCase {
    func testSupplementalQEMUScalarResultsMatchWithoutClaimingFPSRSupport() throws {
        struct Fixture: Decodable { let schema: String; let vectors: [A64OracleVector] }
        let url = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
            .appendingPathComponent("GoldenFixtures/cp7-scalar-fp/vectors.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.schema, "cp7-scalar-fp-supplement-1")
        XCTAssertEqual(fixture.vectors.count, 10804)
        var errors: [String] = []
        for vector in fixture.vectors {
            let result = A64OracleRunner.run(vector)
            if !result.decoded.hasPrefix(vector.form.split(separator: " ").first! + " ") || result.status != .unsupported || result.reason != "FPSR output is not modeled; numeric data checks matched" {
                errors.append("\(vector.id) \(result.status.rawValue): \(result.reason)")
            }
        }
        XCTAssertTrue(errors.isEmpty, "\(errors.count) numeric/admission errors; first diagnostics: \(errors.prefix(20))")
        print("CP7 supplemental scalar FP: \(fixture.vectors.count - errors.count)/\(fixture.vectors.count) numeric matches; FPSR remains unsupported")
    }
}
