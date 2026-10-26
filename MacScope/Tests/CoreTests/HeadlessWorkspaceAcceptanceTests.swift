import Foundation
import XCTest
@testable import MacScope

final class HeadlessWorkspaceAcceptanceTests: XCTestCase {
    @MainActor
    func testRejectsAmbiguousAndUnsafeRequestsBeforeAnyOperation() throws {
        let invalid = [
            #"{"action":"terminal","workspace":"relative.mscope","output":"/tmp/new"}"#,
            #"{"action":"terminal","workspace":"/tmp/a.mscope","output":"/tmp/a.mscope/new"}"#,
            #"{"action":"terminal","workspace":"/tmp/a.mscope","output":"/tmp/new","prompt":"unexpected"}"#,
            #"{"action":"rea","workspace":"/tmp/a.mscope","output":"/tmp/new"}"#,
            #"{"action":"inspect","workspace":"/tmp/a.mscope","output":"/tmp/new","unknown":true}"#,
            #"{"action":"inspect","action":"terminal","workspace":"/tmp/a.mscope","output":"/tmp/new"}"#
        ]
        for json in invalid {
            XCTAssertThrowsError(try HeadlessWorkspaceAcceptance.Request.decode(Data(json.utf8)), json)
        }
    }

    @MainActor
    func testAdmissionKeepsExplicitReadAndMutationModes() throws {
        for action in ["inspect", "terminal", "reopen"] {
            let data = try ScriptValue.object([
                "action": .string(action), "workspace": .string("/tmp/test.mscope"),
                "output": .string("/tmp/new-result")
            ]).jsonData()
            let request = try HeadlessWorkspaceAcceptance.Request.decode(data)
            XCTAssertEqual(request.action, action)
            XCTAssertNil(request.prompt)
            XCTAssertEqual(request.workspace.pathExtension, "mscope")
        }
    }
}
