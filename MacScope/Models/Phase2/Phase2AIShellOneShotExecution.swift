import Foundation

enum Phase2AIShellExecutionResultRetention {
    static let maximumResults = 100
}

enum Phase2AIShellOneShotExecutionDisposition: String, Codable, Equatable, Sendable {
    case completed
    case nonZeroExit
    case timedOut
    case launchFailed
    case validationRejected
    case authorizationRejected
}

struct Phase2AIShellOneShotExecutionResult: Codable, Equatable, Sendable, Identifiable {
    static let schemaVersion = 1

    let id: UUID
    let schemaVersion: Int
    let proposalID: UUID
    let executablePath: String
    let arguments: [String]
    let workingDirectoryPath: String?
    let timeoutMilliseconds: Int
    let maximumOutputBytes: Int
    let disposition: Phase2AIShellOneShotExecutionDisposition
    let terminationStatus: Int32?
    let standardOutput: String
    let standardError: String
    let outputWasTruncated: Bool
    let startedAt: Date
    let completedAt: Date
    let failureMessage: String?

    init(
        id: UUID = UUID(),
        schemaVersion: Int = Self.schemaVersion,
        proposalID: UUID,
        executablePath: String,
        arguments: [String],
        workingDirectoryPath: String?,
        timeoutMilliseconds: Int,
        maximumOutputBytes: Int,
        disposition: Phase2AIShellOneShotExecutionDisposition,
        terminationStatus: Int32?,
        standardOutput: String,
        standardError: String,
        outputWasTruncated: Bool,
        startedAt: Date,
        completedAt: Date,
        failureMessage: String?
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.proposalID = proposalID
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectoryPath = workingDirectoryPath
        self.timeoutMilliseconds = timeoutMilliseconds
        self.maximumOutputBytes = maximumOutputBytes
        self.disposition = disposition
        self.terminationStatus = terminationStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.outputWasTruncated = outputWasTruncated
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.failureMessage = failureMessage
    }

    static func rejected(
        proposal: Phase2AIShellCommandProposal?,
        requestedProposalID: UUID? = nil,
        disposition: Phase2AIShellOneShotExecutionDisposition,
        message: String,
        now: Date = Date()
    ) -> Self {
        Self(
            proposalID: proposal?.proposalID
                ?? requestedProposalID
                ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            executablePath: proposal?.executablePath ?? "",
            arguments: proposal?.arguments ?? [],
            workingDirectoryPath: proposal?.workingDirectoryPath,
            timeoutMilliseconds: proposal?.timeoutMilliseconds ?? 0,
            maximumOutputBytes: proposal?.maximumOutputBytes ?? 0,
            disposition: disposition,
            terminationStatus: nil,
            standardOutput: "",
            standardError: "",
            outputWasTruncated: false,
            startedAt: now,
            completedAt: now,
            failureMessage: message
        )
    }

    func providerVisibleEvidenceText(maximumStreamBytes: Int = 2_048) -> String {
        var lines = [
            "Execution ID: \(id.uuidString)",
            "Proposal ID: \(proposalID.uuidString)",
            "Command: \(Self.quotedCommand(executablePath: executablePath, arguments: arguments))",
            "Working directory: \(workingDirectoryPath.map(Self.quoted) ?? "(default)")",
            "Disposition: \(disposition.rawValue)",
        ]
        if let terminationStatus {
            lines.append("Termination status: \(terminationStatus)")
        }
        if outputWasTruncated {
            lines.append("Output truncated by MacScope: yes")
        }
        if let failureMessage, !failureMessage.isEmpty {
            lines.append("Failure: \(Self.truncatedUTF8(failureMessage, maximumBytes: maximumStreamBytes))")
        }
        if !standardOutput.isEmpty {
            lines.append("Standard output:")
            lines.append(Self.truncatedUTF8(standardOutput, maximumBytes: maximumStreamBytes))
        }
        if !standardError.isEmpty {
            lines.append("Standard error:")
            lines.append(Self.truncatedUTF8(standardError, maximumBytes: maximumStreamBytes))
        }
        return lines.joined(separator: "\n")
    }

    static func truncatedUTF8(_ text: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        guard text.utf8.count > maximumBytes else { return text }

        let marker = "\n[truncated by MacScope]"
        let markerByteCount = marker.utf8.count
        if markerByteCount >= maximumBytes {
            return utf8Prefix(marker, maximumBytes: maximumBytes)
        }

        let contentByteBudget = maximumBytes - markerByteCount
        return utf8Prefix(text, maximumBytes: contentByteBudget) + marker
    }

    private static func utf8Prefix(_ text: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        var byteCount = 0
        var output = ""
        for character in text {
            let characterBytes = character.utf8.count
            guard byteCount + characterBytes <= maximumBytes else { break }
            output.append(character)
            byteCount += characterBytes
        }
        return output
    }

    private static func quotedCommand(executablePath: String, arguments: [String]) -> String {
        ([executablePath] + arguments).map(quoted).joined(separator: " ")
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

protocol Phase2AIShellOneShotExecuting: Sendable {
    func run(_ proposal: Phase2AIShellCommandProposal) async -> Phase2AIShellOneShotExecutionResult
}

struct Phase2AIShellOneShotExecutor: Phase2AIShellOneShotExecuting {
    func run(_ proposal: Phase2AIShellCommandProposal) async -> Phase2AIShellOneShotExecutionResult {
        let validation = Phase2AIShellProposalValidator.validate(proposal)
        guard validation.isAccepted else {
            return .rejected(
                proposal: proposal,
                disposition: .validationRejected,
                message: validation.issues.map(\.displaySummary).joined(separator: "\n")
            )
        }

        let startedAt = Date()
        let outputLimit = max(1, proposal.maximumOutputBytes)
        let outputBudget = BoundedProcessOutputBudget(maximumBytes: outputLimit)
        let stdoutBuffer = BoundedProcessOutputBuffer(budget: outputBudget)
        let stderrBuffer = BoundedProcessOutputBuffer(budget: outputBudget)

        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: proposal.executablePath)
            process.arguments = proposal.arguments
            process.environment = proposal.environment.isEmpty ? nil : proposal.environment
            if let workingDirectoryPath = proposal.workingDirectoryPath {
                process.currentDirectoryURL = URL(fileURLWithPath: workingDirectoryPath, isDirectory: true)
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let completionGate = Phase2AIShellOneShotCompletionGate(
                proposal: proposal,
                process: process,
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe,
                stdoutBuffer: stdoutBuffer,
                stderrBuffer: stderrBuffer,
                outputBudget: outputBudget,
                startedAt: startedAt,
                continuation: continuation
            )

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                stdoutBuffer.append(handle.availableData)
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                stderrBuffer.append(handle.availableData)
            }
            process.terminationHandler = { terminatedProcess in
                let status = terminatedProcess.terminationStatus
                completionGate.finish(
                    disposition: status == 0 ? .completed : .nonZeroExit,
                    terminationStatus: status,
                    failureMessage: nil
                )
            }

            do {
                try process.run()
            } catch {
                completionGate.finish(
                    disposition: .launchFailed,
                    terminationStatus: nil,
                    failureMessage: error.localizedDescription
                )
                return
            }

            let deadline = DispatchTime.now() + .milliseconds(proposal.timeoutMilliseconds)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) {
                completionGate.timeoutIfRunning()
            }
        }
    }
}

private final class Phase2AIShellOneShotCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var process: Process?
    private let proposal: Phase2AIShellCommandProposal
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let stdoutBuffer: BoundedProcessOutputBuffer
    private let stderrBuffer: BoundedProcessOutputBuffer
    private let outputBudget: BoundedProcessOutputBudget
    private let startedAt: Date
    private let continuation: CheckedContinuation<Phase2AIShellOneShotExecutionResult, Never>

    init(
        proposal: Phase2AIShellCommandProposal,
        process: Process,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        stdoutBuffer: BoundedProcessOutputBuffer,
        stderrBuffer: BoundedProcessOutputBuffer,
        outputBudget: BoundedProcessOutputBudget,
        startedAt: Date,
        continuation: CheckedContinuation<Phase2AIShellOneShotExecutionResult, Never>
    ) {
        self.proposal = proposal
        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.stdoutBuffer = stdoutBuffer
        self.stderrBuffer = stderrBuffer
        self.outputBudget = outputBudget
        self.startedAt = startedAt
        self.continuation = continuation
    }

    func timeoutIfRunning() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        let runningProcess = process
        guard runningProcess?.isRunning == true else {
            lock.unlock()
            return
        }
        finished = true
        process = nil
        lock.unlock()

        complete(
            process: runningProcess,
            disposition: .timedOut,
            terminationStatus: nil,
            failureMessage: "Process exceeded \(proposal.timeoutMilliseconds) ms timeout.",
            terminateProcess: true
        )
    }

    func finish(
        disposition: Phase2AIShellOneShotExecutionDisposition,
        terminationStatus: Int32?,
        failureMessage: String?
    ) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let finishedProcess = process
        process = nil
        lock.unlock()

        complete(
            process: finishedProcess,
            disposition: disposition,
            terminationStatus: terminationStatus,
            failureMessage: failureMessage,
            terminateProcess: false
        )
    }

    private func complete(
        process finishedProcess: Process?,
        disposition: Phase2AIShellOneShotExecutionDisposition,
        terminationStatus: Int32?,
        failureMessage: String?,
        terminateProcess: Bool
    ) {
        finishedProcess?.terminationHandler = nil
        if terminateProcess, finishedProcess?.isRunning == true {
            finishedProcess?.terminate()
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutBuffer.append(stdoutPipe.fileHandleForReading.availableData)
        stderrBuffer.append(stderrPipe.fileHandleForReading.availableData)

        continuation.resume(returning: Phase2AIShellOneShotExecutionResult(
            proposalID: proposal.proposalID,
            executablePath: proposal.executablePath,
            arguments: proposal.arguments,
            workingDirectoryPath: proposal.workingDirectoryPath,
            timeoutMilliseconds: proposal.timeoutMilliseconds,
            maximumOutputBytes: proposal.maximumOutputBytes,
            disposition: disposition,
            terminationStatus: terminationStatus,
            standardOutput: stdoutBuffer.stringValue,
            standardError: stderrBuffer.stringValue,
            outputWasTruncated: outputBudget.truncated,
            startedAt: startedAt,
            completedAt: Date(),
            failureMessage: failureMessage
        ))
    }
}

private final class BoundedProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let budget: BoundedProcessOutputBudget
    private var data = Data()

    init(budget: BoundedProcessOutputBudget) {
        self.budget = budget
    }

    func append(_ nextData: Data) {
        guard !nextData.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let acceptedBytes = budget.reserve(requestedBytes: nextData.count)
        guard acceptedBytes > 0 else { return }
        data.append(nextData.prefix(acceptedBytes))
    }

    var stringValue: String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(data: snapshot, encoding: .utf8)
            ?? String(decoding: snapshot, as: UTF8.self)
    }
}

private final class BoundedProcessOutputBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var acceptedBytes = 0
    private var didTruncate = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func reserve(requestedBytes: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let available = max(0, maximumBytes - acceptedBytes)
        let accepted = min(requestedBytes, available)
        acceptedBytes += accepted
        if accepted < requestedBytes {
            didTruncate = true
        }
        return accepted
    }

    var truncated: Bool {
        lock.lock()
        let snapshot = didTruncate
        lock.unlock()
        return snapshot
    }
}
