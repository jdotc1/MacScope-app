import Foundation
import XCTest
@testable import MacScope

final class REAInspectionWireCodecTests: XCTestCase {
    func testRejectsDuplicateKeysMalformedUnicodeAndUnsafeNumbers() throws {
        let id = UUID()
        func request(_ input: String) -> Data {
            Data("{\"schemaVersion\":1,\"requestID\":\"\(id)\",\"operation\":\"nativeApplication\",\"input\":\(input)}".utf8)
        }
        for input in ["{\"a\":1,\"a\":2}", "{\"a\":\"\\uD800\"}", "{\"address\":9007199254740992}"] {
            XCTAssertThrowsError(try REAInspectionWireCodec.validateRequest(request(input), requestID: id))
        }
        XCTAssertNoThrow(try REAInspectionWireCodec.validateRequest(request("{\"address\":\"0xffffffffffffffff\"}"), requestID: id))
        XCTAssertThrowsError(try REAInspectionWireCodec.validateRequest(request("{}"), requestID: UUID()))
    }

    func testCanonicalCommitmentUsesJavaScriptKeyOrderAndPreservesUnicode() throws {
        // Supplementary U+1F600 sorts before BMP U+E000 in JavaScript's UTF-16 ordering.
        let input = Data("{\"\u{e000}\":null,\"😀\":\"é\",\"a\":[1e0,-0,\"\\n\"]}".utf8)
        let actual = try REAInspectionWireCodec.canonicalCommitment(input)
        XCTAssertEqual(String(decoding: actual, as: UTF8.self), "{\"a\":[1,0,\"\\n\"],\"😀\":\"é\",\"\u{e000}\":null}")
        XCTAssertThrowsError(try REAInspectionWireCodec.canonicalCommitment(Data("{\"x\":1.25}".utf8)))
    }

    func testErrorDiagnosticLimitCountsUTF8BytesAndRejectsSplitSurrogates() throws {
        let id = UUID(), identity = "test"
        func response(_ message: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "requestID": id.uuidString,
                "operation": "uiResources", "implementationIdentity": identity, "ok": false,
                "error": ["code": "invalidInput", "message": message]])
        }
        for message in [String(repeating: "a", count: 1_024), String(repeating: "é", count: 512),
                        String(repeating: "😀", count: 256), String(repeating: "a", count: 1_020) + "😀"] {
            XCTAssertEqual(message.utf8.count, 1_024)
            XCTAssertNoThrow(try REAInspectionWireCodec.validateResponse(response(message), requestID: id,
                operation: .uiResources, implementationIdentity: identity))
            XCTAssertThrowsError(try REAInspectionWireCodec.validateResponse(response(message + "a"), requestID: id,
                operation: .uiResources, implementationIdentity: identity))
        }
        let invalid = Data("{\"schemaVersion\":1,\"requestID\":\"\(id)\",\"operation\":\"uiResources\",\"implementationIdentity\":\"test\",\"ok\":false,\"error\":{\"code\":\"invalidInput\",\"message\":\"\\ud83d\"}}".utf8)
        XCTAssertThrowsError(try REAInspectionWireCodec.validateResponse(invalid, requestID: id,
            operation: .uiResources, implementationIdentity: identity))
    }

    func testResponseRejectsWrongIdentityAndMixedSuccessFailure() throws {
        let id = UUID(), identity = String(repeating: "a", count: 64)
        let valid = REAInspectionWireCodec.failure(requestID: id, operation: .uiResources,
            implementationIdentity: identity, code: "cancelled", message: "Cancelled")
        XCTAssertNoThrow(try REAInspectionWireCodec.validateResponse(valid, requestID: id,
            operation: .uiResources, implementationIdentity: identity))
        XCTAssertThrowsError(try REAInspectionWireCodec.validateResponse(valid, requestID: id,
            operation: .nativeApplication, implementationIdentity: identity))
        var mixed = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        mixed["result"] = [:]
        XCTAssertThrowsError(try REAInspectionWireCodec.validateResponse(
            JSONSerialization.data(withJSONObject: mixed), requestID: id,
            operation: .uiResources, implementationIdentity: identity))
    }
}
