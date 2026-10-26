import Foundation

/// Exact-values-v1 compares final channel snapshots. `order` enumerates the
/// normalized fields, and atMS=0 denotes normalization, never execution timing.
/// The original authenticated receipt and its digest remain on AcceptedCapture.
enum REAProcessComparisonProjection {
    struct Input: Encodable, Sendable {
        let left: Capture
        let right: Capture
        let admittedCaptureSHA256: [String]
        fileprivate init(left: Capture, right: Capture, hashes: [String]) {
            self.left = left; self.right = right; admittedCaptureSHA256 = hashes
        }
    }
    struct Capture: Encodable, Sendable {
        struct Executable: Encodable, Sendable { let sha256: String; let byteCount: UInt64 }
        struct Receipt: Encodable, Sendable {
            let receiptID: String; let captureID: String; let scenarioSHA256: String
            let executableSHA256: String; let inputTreeSHA256: String; let materializedInputTreeSHA256: String
        }
        struct Observation: Encodable, Sendable {
            enum Value: Encodable, Sendable {
                case text(String), terminal(code: Int32?, signal: String?, reason: String)
                func encode(to encoder: any Encoder) throws {
                    switch self {
                    case .text(let text): var box = encoder.singleValueContainer(); try box.encode(text)
                    case .terminal(let code, let signal, let reason):
                        var box = encoder.container(keyedBy: Keys.self)
                        try box.encode(code, forKey: .code); try box.encode(signal, forKey: .signal)
                        try box.encode(reason, forKey: .reason)
                    }
                }
                private enum Keys: String, CodingKey { case code, signal, reason }
            }
            let order: Int; let source: String; let atMS: Int; let value: Value
        }
        let captureID: String
        let scenario: REAProcessScenario
        let scenarioSHA256: String
        let executable: Executable
        let producerReceipt: Receipt
        let observations: [Observation]
        let completeSources: [String]
        let truncatedSources: [String]
        let cleanup: String
        let execution: String
    }
    static func input(left: REAScenarioCaptureProvider.AcceptedCapture,
                      right: REAScenarioCaptureProvider.AcceptedCapture) throws -> Input {
        let a = try project(left), b = try project(right)
        func digest(_ capture: Capture) throws -> String {
            REACaptureCommitment.digest(try REAInspectionWireCodec.canonicalCommitment(REACaptureCommitment.encode(capture)))
        }
        return try Input(left: a, right: b, hashes: [digest(a), digest(b)])
    }
    private static func project(_ accepted: REAScenarioCaptureProvider.AcceptedCapture) throws -> Capture {
        let request = accepted.request, response = accepted.response
        guard response.isAccepted, let terminal = response.terminal, let status = terminal.status,
              let stdout = String(data: response.stdout, encoding: .utf8),
              let stderr = String(data: response.stderr, encoding: .utf8),
              let materialized = response.materializedInputTreeSHA256 else {
            throw REAScenarioCaptureProvider.Failure.invalidReply
        }
        let identifier = response.receiptID.uuidString
        let termination: Capture.Observation.Value = terminal.kind == .exited
            ? .terminal(code: status, signal: nil, reason: "exited")
            : .terminal(code: nil, signal: String(status), reason: "signaled")
        return Capture(captureID: identifier, scenario: request.scenario, scenarioSHA256: request.scenarioSHA256,
            executable: .init(sha256: request.executableSHA256, byteCount: request.executableByteCount),
            producerReceipt: .init(receiptID: identifier, captureID: identifier, scenarioSHA256: request.scenarioSHA256,
                executableSHA256: request.executableSHA256, inputTreeSHA256: request.scenario.inputTreeSHA256,
                materializedInputTreeSHA256: materialized),
            observations: [.init(order: 0, source: "stdout", atMS: 0, value: .text(stdout)),
                           .init(order: 1, source: "stderr", atMS: 0, value: .text(stderr)),
                           .init(order: 2, source: "exit", atMS: 0, value: termination)],
            completeSources: ["stdout", "stderr", "exit"], truncatedSources: [], cleanup: "verifiedAbsent", execution: "accepted")
    }
}
