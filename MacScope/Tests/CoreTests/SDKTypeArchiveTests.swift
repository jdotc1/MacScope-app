import Foundation
import XCTest
@testable import MacScopeAnalysisCore

final class SDKTypeArchiveTests: XCTestCase {
    func testRoundTripRejectsWrongTargetDuplicateIDAndInvalidLayout() throws {
        let data = try Data(contentsOf: TestSourceRoot.url.appendingPathComponent(
            "MacScope/Tests/CoreTests/Fixtures/TypeImport/minimal-archive.json"))
        let target = "arm64-apple-macosx27.0"
        let archive = try SDKTypeArchive.decode(data, expectedTarget: target)
        let roundTrip = try SDKTypeArchive.decode(archive.encoded(), expectedTarget: target)
        XCTAssertEqual(roundTrip.document, archive.document)
        XCTAssertEqual(roundTrip.contentSHA256, archive.contentSHA256)
        XCTAssertEqual(archive.identity(for: "record:Node")?.declarationID, "record:Node")
        XCTAssertNil(archive.identity(for: "absent"))
        XCTAssertEqual(archive.document.types[1].fields[1].bitOffset, 64)
        XCTAssertEqual(archive.document.types[1].fields[1].bitWidth, 3)
        XCTAssertEqual(archive.document.types[3].layout.status, .unknown)
        XCTAssertNil(archive.document.types[3].layout.sizeBytes)
        XCTAssertEqual(archive.document.types[4].enumValues[0].value, "18446744073709551615")
        XCTAssertEqual(archive.document.types[5].underlyingTypeID, "scalar:ulong")
        XCTAssertEqual(archive.document.types[8].fields.last?.flexibleArray, true)
        XCTAssertEqual(archive.document.types[10].layout.status, .unknown)
        XCTAssertThrowsError(try SDKTypeArchive.decode(data, expectedTarget: "arm64e-apple-macosx27.0"))
        XCTAssertThrowsError(try SDKTypeArchive.decode(data, expectedTarget: target, expectedConfigurationID: "wrong"))

        func corrupted(_ edit: (inout [String: Any]) -> Void) throws -> Data {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            edit(&json)
            return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        }
        func changeNode(_ json: inout [String: Any], _ index: Int, _ edit: (inout [String: Any]) -> Void) {
            var types = json["types"] as! [[String: Any]]
            edit(&types[index]); json["types"] = types
        }
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("version", { $0["schemaMajor"] = 2 }),
            ("provenance", { $0.removeValue(forKey: "provenance") }),
            ("duplicate", { json in changeNode(&json, 2) { $0["id"] = "record:Node" } }),
            ("dangling", { json in changeNode(&json, 2) { $0["pointeeTypeID"] = "missing" } }),
            ("unknown size", { json in changeNode(&json, 3) {
                $0["layout"] = ["status": "unknown", "reason": "incomplete", "sizeBytes": 0]
            } }),
            ("alignment", { json in changeNode(&json, 1) {
                $0["layout"] = ["status": "known", "sizeBytes": 16, "alignmentBytes": 3]
            } }),
            ("overflow", { json in changeNode(&json, 1) {
                $0["layout"] = ["status": "known", "sizeBytes": UInt64.max, "alignmentBytes": 1]
            } }),
            ("union offset", { json in changeNode(&json, 1) { $0["recordKind"] = "union" } }),
            ("pointer bitfield", { json in changeNode(&json, 1) { node in
                var fields = node["fields"] as! [[String: Any]]
                fields[1]["typeID"] = "pointer:Node"; node["fields"] = fields
            } }),
            ("field extent", { json in changeNode(&json, 1) { node in
                var fields = node["fields"] as! [[String: Any]]
                fields[1]["bitOffset"] = 128; node["fields"] = fields
            } }),
            ("by-value cycle", { json in changeNode(&json, 1) { node in
                var fields = node["fields"] as! [[String: Any]]
                fields[0]["typeID"] = "record:Node"; node["fields"] = fields
            } }),
            ("unknown by-value", { json in changeNode(&json, 1) { node in
                var fields = node["fields"] as! [[String: Any]]
                fields[0]["typeID"] = "record:Opaque"; node["fields"] = fields
            } })
        ]
        for (label, edit) in mutations {
            XCTAssertThrowsError(try SDKTypeArchive.decode(corrupted(edit), expectedTarget: target), label)
        }
        let tooDeep = Data((String(repeating: "[", count: 33) + "0" + String(repeating: "]", count: 33)).utf8)
        XCTAssertThrowsError(try SDKTypeArchive.decode(tooDeep, expectedTarget: target))
    }
}
