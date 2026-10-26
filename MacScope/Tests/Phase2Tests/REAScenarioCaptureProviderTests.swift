import Foundation
import Darwin
import XCTest
@testable import MacScope

private final class REACaptureTransportFixture: REAScenarioCaptureTransport, @unchecked Sendable {
    enum Mode: Equatable, Sendable { case accepted, wrongIdentity, held }
    let mode: Mode
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var stopped = false
    private var cancellations = 0
    init(_ mode: Mode) { self.mode = mode }
    var cancelCount: Int { lock.withLock { cancellations } }
    func request(_ request: REAScenarioCaptureRequest) async throws -> Data {
        if mode == .held {
            return try await withCheckedThrowingContinuation { continuation in
                let retired = lock.withLock {
                    if stopped { return true }; self.continuation = continuation; return false
                }
                if retired { continuation.resume(throwing: CancellationError()) }
            }
        }
        let terminal = MacScope.Phase2SourceExecutionTerminal(kind: .exited, status: 7)
        let response = REAScenarioCaptureResponse(requestID: mode == .wrongIdentity ? UUID() : request.requestID,
            sessionID: request.sessionID, receiptID: UUID(), scenarioSHA256: request.scenarioSHA256,
            executableSHA256: request.executableSHA256, materializedInputTreeSHA256: request.scenario.inputTreeSHA256,
            status: .completed, failure: nil, stdout: Data("out\n".utf8), stderr: Data("err\n".utf8), terminal: terminal,
            cleanup: .init(sessionID: request.sessionID, requestID: request.requestID, processIdentifier: 123,
                           observedProcessAbsent: true, outcome: terminal), elapsedSeconds: 0.1,
            completeSources: ["stdout", "stderr", "exit"])
        return try REACaptureCommitment.encode(response)
    }
    func cancel(_ request: REAScenarioCaptureRequest) { lock.withLock { cancellations += 1 } }
    func retire() {
        let current = lock.withLock {
            stopped = true; let current = continuation; continuation = nil; return current
        }
        current?.resume(throwing: CancellationError())
    }
}

@MainActor final class REAScenarioCaptureProviderTests: XCTestCase {
    private func fixture() throws -> (URL, REAScenarioCaptureRequest) {
        let root = TestWorkRoot.authorityURL("rea-capture-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let executable = root.appendingPathComponent("fixture")
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data("fixture-not-executed".utf8), attributes: [.posixPermissions: 0o500]))
        let scenario = REAProcessScenario(arguments: ["a"], environment: [:],
            inputTreeSHA256: try REACaptureCommitment.sha256([REAScenarioCapture.InputFile]()),
            workingDirectory: ".", interactions: [], dimensions: ["stdout", "stderr", "exit"], normalization: .init(kind: "exact-values-v1"))
        let request = try REAScenarioCaptureProvider.stage(executable: executable, runner: executable,
            scenario: scenario, files: [:], parent: root.appendingPathComponent("stages", isDirectory: true))
        return (root, request)
    }
    private func remove(_ root: URL) {
        let fm = FileManager.default
        for path in ((try? fm.subpathsOfDirectory(atPath: root.path)) ?? []).sorted(by: { $0.count < $1.count }) {
            _ = chmod(root.appendingPathComponent(path).path, 0o700)
        }
        try? fm.removeItem(at: root)
    }
    func testAcceptedReceiptCleansStageAndBuildsBoundNormalizedComparison() async throws {
        let (root, request) = try fixture(); defer { remove(root) }
        let fixture = REACaptureTransportFixture(.accepted)
        let capture = try await REAScenarioCaptureProvider(makeTransport: { fixture }).capture(request)
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.stageRootPath))
        XCTAssertEqual(capture.producerReceiptSHA256, try REACaptureCommitment.digest(REACaptureCommitment.encode(capture.response)))
        let input = try REAProcessComparisonProjection.input(left: capture, right: capture)
        XCTAssertEqual(input.left.observations.map(\.source), ["stdout", "stderr", "exit"])
        XCTAssertEqual(input.left.observations.map(\.atMS), [0, 0, 0])
        let canonical = try REAInspectionWireCodec.canonicalCommitment(REACaptureCommitment.encode(input.left))
        XCTAssertEqual(input.admittedCaptureSHA256, [REACaptureCommitment.digest(canonical), REACaptureCommitment.digest(canonical)])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: REACaptureCommitment.encode(input.left)) as? [String: Any])
        let observations = try XCTUnwrap(object["observations"] as? [[String: Any]])
        let exit = try XCTUnwrap(observations.last?["value"] as? [String: Any])
        XCTAssertEqual(exit["code"] as? Int, 7)
        XCTAssertTrue(exit["signal"] is NSNull)
    }
    func testWrongRequestReceiptCannotAdmitOrRemoveStage() async throws {
        let (root, request) = try fixture(); defer { remove(root) }
        let fixture = REACaptureTransportFixture(.wrongIdentity)
        do { _ = try await REAScenarioCaptureProvider(makeTransport: { fixture }).capture(request); XCTFail("must reject") }
        catch { XCTAssertEqual(error as? REAScenarioCaptureProvider.Failure, .invalidReply) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: request.stageRootPath))
    }
    func testTimeoutCancelsClientAndRetainsUnprovenStage() async throws {
        let (root, request) = try fixture(); defer { remove(root) }
        let fixture = REACaptureTransportFixture(.held)
        do { _ = try await REAScenarioCaptureProvider(timeout: 0.01, makeTransport: { fixture }).capture(request); XCTFail("must time out") }
        catch { XCTAssertEqual(error as? REAScenarioCaptureProvider.Failure, .timeout) }
        XCTAssertEqual(fixture.cancelCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: request.stageRootPath))
    }
    func testStageInputsAreImmutableAndCommitted() throws {
        let (root, request) = try fixture(); defer { remove(root) }
        XCTAssertEqual(try REAScenarioCapture.verify(request), request.scenario.inputTreeSHA256)
        for name in ["executable", "arguments.bin", "environment.bin", "working-directory.bin", "input"] {
            var info = stat()
            XCTAssertEqual(lstat(URL(fileURLWithPath: request.stageRootPath).appendingPathComponent(name).path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o222, 0)
        }
    }
}
