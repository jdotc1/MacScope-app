import XCTest
@testable import MacScope

final class REAScenarioCaptureTests: XCTestCase {
    private func scenario() -> REAProcessScenario {
        .init(arguments: ["hello"], environment: ["LANG": "C"], inputTreeSHA256: String(repeating: "a", count: 64),
            workingDirectory: ".", interactions: [], dimensions: ["stdout", "stderr", "exit"], normalization: .init(kind: "exact-values-v1"))
    }
    func testScenarioCommitmentChangesWithArguments() throws {
        let first = scenario()
        let changed = REAProcessScenario(arguments: ["different"], environment: first.environment,
            inputTreeSHA256: first.inputTreeSHA256, workingDirectory: first.workingDirectory,
            interactions: [], dimensions: first.dimensions, normalization: first.normalization)
        XCTAssertTrue(first.isSupported)
        XCTAssertNotEqual(try REACaptureCommitment.sha256(first), try REACaptureCommitment.sha256(changed))
        XCTAssertFalse(REAProcessScenario.safeRelative("../escape"))
        XCTAssertFalse(REAProcessScenario.safeRelative("nested/../escape"))
    }
    func testNulVectorsPreserveEmptyArgumentsAndDeterministicEnvironment() {
        XCTAssertEqual(REAScenarioCapture.nulBytes(["", "a"]), Data([0, 97, 0]))
        XCTAssertEqual(REAScenarioCapture.environmentBytes(["Z": "last", "A": "first"]), Data("A=first\0Z=last\0".utf8))
    }
    func testImmutableInputTreeRejectsTamperAndSymbolicLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path); try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("input.txt")
        try Data("original".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        let before = try REAScenarioCapture.inputTree(root)
        XCTAssertEqual(before.count, 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertThrowsError(try REAScenarioCapture.inputTree(root))
        try Data("changed".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
        XCTAssertNotEqual(try REACaptureCommitment.sha256(before), try REACaptureCommitment.sha256(REAScenarioCapture.inputTree(root)))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        XCTAssertThrowsError(try REAScenarioCapture.inputTree(root))
    }
    func testRejectedCaptureCannotEstablishCompleteEvidence() throws {
        let input = scenario()
        let request = REAScenarioCaptureRequest(requestID: UUID(), sessionID: UUID(),
            stageRootPath: TestWorkRoot.authorityPath("test-stage"), scenario: input,
            scenarioSHA256: try REACaptureCommitment.sha256(input), executableSHA256: String(repeating: "b", count: 64),
            executableByteCount: 1, runnerSHA256: String(repeating: "c", count: 64))
        XCTAssertTrue(request.isValid)
        let response = REAScenarioCaptureResponse.rejected(request, failure: "cleanupFailed")
        XCTAssertFalse(response.isAccepted)
        XCTAssertTrue(response.completeSources.isEmpty)
        XCTAssertEqual(response.requestID, request.requestID)
    }
}
