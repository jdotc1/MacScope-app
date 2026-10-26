import CryptoKit
import Foundation
import XCTest
@testable import MacScope

final class REAJavaScriptHostTests: XCTestCase {
    private func resource(_ script: String) throws -> URL {
        let root = TestWorkRoot.authorityURL("rea-worker-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("verified.js")
        try Data(script.utf8).write(to: file)
        return file
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func request(_ id: UUID) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "requestID": id.uuidString,
            "operation": "nativeApplication", "input": [:]], options: [.sortedKeys])
    }
    // The hosted CoreTests process includes every app test and may retain >2GiB
    // of live state. These host-algorithm tests are not the isolated XPC worker
    // memory-policy gate; inject only their execution-control ceiling.
    private func hostedService(_ host: REAJavaScriptHost) -> REAWorkerService {
        REAWorkerService(executor: { data, id, control, completion in
            host.execute(requestData: data, requestID: id, control: control, completion: completion)
        }, implementationIdentity: host.implementationIdentity, executionControlFactory: {
            REAWorkerExecutionControl(deadline: $0, maximumResidentBytes: Int64.max)
        })
    }

    func testDefaultIsolatedWorkerRetainsTwoGiBMemoryCeiling() throws {
        let done = expectation(description: "default worker control captured")
        let service = REAWorkerService(executor: { _, _, control, completion in
            XCTAssertEqual(control.maximumResidentBytes, 2_147_483_648)
            completion(.failure(.init("testCompletion")))
            done.fulfill()
        }, implementationIdentity: "test")
        let id = UUID()
        service.handle(requestData: try request(id), requestID: id) { _ in }
        wait(for: [done], timeout: 3)
    }

    func testActualPromiseCompletesAndSHAUsesUTF8() throws {
        let script = """
        var MacScopeREA = { analyze: async function(text) {
          __macscopeCheckpoint();
          const request = JSON.parse(text);
          await Promise.resolve();
          return JSON.stringify({schemaVersion:1, requestID:request.requestID,
            operation:request.operation, implementationIdentity:"test", ok:true,
            result:{digest:__macscopeSHA256("é")}});
        }};
        """
        let file = try resource(script), host = REAJavaScriptHost(resourceURL: file,
            expectedSHA256: hash(Data(script.utf8)), implementationIdentity: "test")
        let service = hostedService(host), id = UUID()
        let done = expectation(description: "actual JS Promise settles")
        let expected = hash(Data("é".utf8))
        service.handle(requestData: try request(id), requestID: id) { data in
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(object?["ok"] as? Bool, true)
            XCTAssertEqual((object?["result"] as? [String: Any])?["digest"] as? String, expected)
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
    }
    func testVerifiedProductKernelCompletesNativeApplicationPromise() throws {
        var root = TestSourceRoot.fileURL(#filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let resource = root.appendingPathComponent("ThirdParty/REA/generated/MacScopeREAKernel.js")
        let host = REAJavaScriptHost(resourceURL: resource,
            expectedSHA256: REAEmbeddedIdentity.resourceSHA256,
            implementationIdentity: REAEmbeddedIdentity.implementationIdentity)
        let slice: [String: Any] = ["architecture": "arm64", "slice_offset": 0, "slice_size": 32,
            "cpu_type": 16_777_228, "cpu_subtype": 0, "fat_cpu_type": NSNull(),
            "fat_cpu_subtype": NSNull(), "fat_alignment_exponent": NSNull(),
            "file_type": "execute", "file_type_code": 2, "platform": 1, "platforms": [1],
            "install_name": NSNull(), "dependencies": [], "rpaths": [], "dyld_environment": [],
            "code_signature_present": false]
        let input: [String: Any] = ["inventoryComplete": true,
            "subject": ["name": "Example.app", "format": "directory"],
            "entries": [["path": "Contents", "kind": "directory"],
                ["path": "Contents/MacOS", "kind": "directory"],
                ["path": "Contents/MacOS/main", "kind": "file"]],
            "images": [["path": "Contents/MacOS/main", "facts": ["status": "parsed", "slices": [slice]]]],
            "roots": ["Contents/MacOS/main"]]
        let id = UUID(), data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1,
            "requestID": id.uuidString, "operation": "nativeApplication", "input": input],
            options: [.sortedKeys, .withoutEscapingSlashes])
        let completed = expectation(description: "verified product Promise completes")
        let service = hostedService(host)
        service.handle(requestData: data, requestID: id) { data in
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(object?["ok"] as? Bool, true)
            let result = object?["result"] as? [String: Any]
            XCTAssertEqual(result?["applicationRoots"] as? [String], ["."])
            XCTAssertEqual((result?["trace"] as? [String: Any])?["roots"] is [Any], true)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5)
    }

    func testVerifiedProductKernelPreservesLongInvalidInputDiagnostic() throws {
        var root = TestSourceRoot.fileURL(#filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let host = REAJavaScriptHost(resourceURL: root.appendingPathComponent("ThirdParty/REA/generated/MacScopeREAKernel.js"),
            expectedSHA256: REAEmbeddedIdentity.resourceSHA256,
            implementationIdentity: REAEmbeddedIdentity.implementationIdentity)
        let id = UUID()
        let input = Dictionary(uniqueKeysWithValues: (0..<50).map { ("invalid😀field\($0)", "value") })
        let encoded = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1,
            "requestID": id.uuidString, "operation": "nativeApplication", "input": input])
        let request = try REAInspectionWireCodec.canonicalCommitment(encoded)
        let completed = expectation(description: "kernel diagnostic survives worker validation")
        hostedService(host).handle(requestData: request, requestID: id) { data in
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let error = object?["error"] as? [String: Any]
            XCTAssertEqual(object?["ok"] as? Bool, false)
            XCTAssertEqual(error?["code"] as? String, "invalidInput")
            let message = error?["message"] as? String ?? ""
            XCTAssertGreaterThan(message.utf8.count, 1_000)
            XCTAssertLessThanOrEqual(message.utf8.count, 1_024)
            XCTAssertNotEqual(message, "REA inspection did not complete.")
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5)
    }

    func testTamperedResourceIsNotEvaluated() throws {
        let original = "var MacScopeREA = {};", file = try resource(original)
        let host = REAJavaScriptHost(resourceURL: file, expectedSHA256: hash(Data(original.utf8)), implementationIdentity: "test")
        try Data("throw new Error('tampered');".utf8).write(to: file)
        let id = UUID(), done = expectation(description: "resource rejected")
        host.execute(requestData: try request(id), requestID: id,
            control: .init(deadline: Date().addingTimeInterval(2), maximumResidentBytes: Int64.max)) { result in
                XCTAssertEqual(result, .failure(.init("resourceRejected")))
                done.fulfill()
            }
        wait(for: [done], timeout: 3)
    }
}
