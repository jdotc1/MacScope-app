import Foundation
import CryptoKit

/// Committed input, independent of the two programs selected for comparison.
struct REAProcessScenario: Codable, Equatable, Sendable {
    struct Interaction: Codable, Equatable, Sendable { let atMS: UInt64; let kind: String; let value: String }
    struct Normalization: Codable, Equatable, Sendable { let kind: String }
    let arguments: [String]
    let environment: [String: String]
    let inputTreeSHA256: String
    let workingDirectory: String
    let interactions: [Interaction]
    let dimensions: [String]
    let normalization: Normalization
    var isSupported: Bool {
        arguments.count <= 128 && arguments.allSatisfy { !$0.contains("\0") && $0.utf8.count <= 4096 }
        && environment.count <= 128 && environment.allSatisfy { !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("LD_") && !$0.key.contains("\0") && !$0.value.contains("\0") && $0.value.utf8.count <= 4096 }
        && REACaptureCommitment.isDigest(inputTreeSHA256) && Self.safeRelative(workingDirectory)
        && interactions.isEmpty && !dimensions.isEmpty && Set(dimensions).count == dimensions.count
        && dimensions.allSatisfy { ["stdout", "stderr", "exit"].contains($0) } && normalization.kind == "exact-values-v1"
    }
    static func safeRelative(_ path: String) -> Bool {
        path == "." || (!path.isEmpty && !path.hasPrefix("/") && !path.contains("\0")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." })
    }
}
struct REAScenarioCaptureRequest: Codable, Equatable, Sendable {
    let requestID: UUID
    let sessionID: UUID
    let stageRootPath: String
    let scenario: REAProcessScenario
    let scenarioSHA256: String
    let executableSHA256: String
    let executableByteCount: UInt64
    let runnerSHA256: String
    var isValid: Bool {
        scenario.isSupported && MacScopeWorkRoot.contains(stageRootPath)
        && stageRootPath.utf8.count <= 3000 && executableByteCount > 0 && executableByteCount <= 16_777_216
        && [scenarioSHA256, executableSHA256, runnerSHA256].allSatisfy(REACaptureCommitment.isDigest)
        && (try? REACaptureCommitment.sha256(scenario)) == scenarioSHA256
    }
}
struct REAScenarioCaptureResponse: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case completed, rejected }
    let requestID: UUID
    let sessionID: UUID
    let receiptID: UUID
    let scenarioSHA256: String
    let executableSHA256: String
    let materializedInputTreeSHA256: String?
    let status: Status
    let failure: String?
    let stdout: Data
    let stderr: Data
    let terminal: Phase2SourceExecutionTerminal?
    let cleanup: Phase2SourceExecutionCleanup?
    let elapsedSeconds: Double
    /// These are final channel snapshots, never a fabricated interleaved stream journal.
    let completeSources: [String]
    var isAccepted: Bool {
        status == .completed && failure == nil && cleanup?.observedProcessAbsent == true
        && cleanup?.requestID == requestID && cleanup?.sessionID == sessionID
        && terminal?.isValid == true && (terminal?.kind == .exited || terminal?.kind == .signaled)
        && cleanup?.outcome == terminal && (cleanup?.processIdentifier ?? 0) > 1
        && elapsedSeconds.isFinite && elapsedSeconds >= 0 && elapsedSeconds <= 12
        && stdout.count < 8192 && stderr.count < 8192
        && materializedInputTreeSHA256.map(REACaptureCommitment.isDigest) == true
        && REACaptureCommitment.isDigest(scenarioSHA256) && REACaptureCommitment.isDigest(executableSHA256)
        && completeSources.count == 3 && Set(completeSources) == Set(["stdout", "stderr", "exit"])
    }
    static func rejected(_ request: REAScenarioCaptureRequest, failure: String) -> Self {
        .init(requestID: request.requestID, sessionID: request.sessionID, receiptID: UUID(),
            scenarioSHA256: request.scenarioSHA256, executableSHA256: request.executableSHA256,
            materializedInputTreeSHA256: nil, status: .rejected, failure: failure,
            stdout: Data(), stderr: Data(), terminal: nil, cleanup: nil, elapsedSeconds: 0, completeSources: [])
    }
}
enum REACaptureCommitment {
    static func isDigest(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func sha256<T: Encodable>(_ value: T) throws -> String { digest(try REAInspectionWireCodec.canonicalCommitment(encode(value))) }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
