import CryptoKit
import Darwin
import Foundation

/// App orchestration over the existing signed broker. This type never launches or owns a process,
/// publishes evidence, or derives oracle outputs from a formula.
struct ReconstructionSourceExecutionWorkflow: Sendable {
    struct ToolAuthority: Equatable, Sendable {
        let compilerPath: String
        let sdkRootPath: String
        let toolchainRootPath: String
        let runnerSHA256: String
        let compilerSHA256: String
        let sdkSettingsSHA256: String

        /// Capture current selected tools; the broker independently verifies their paths, signatures
        /// and bytes before and after execution. No executable or Xcode-selection subprocess runs.
        static func capture(appBundleURL: URL = Bundle.main.bundleURL) throws -> Self {
            let selected = try FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")
            let developer = URL(fileURLWithPath: selected).resolvingSymlinksInPath().standardizedFileURL
            guard developer.path.hasPrefix("/Applications/"), developer.path.hasSuffix(".app/Contents/Developer"),
                  appBundleURL.isFileURL, appBundleURL.pathExtension == "app",
                  appBundleURL.standardizedFileURL.path == appBundleURL.path,
                  appBundleURL.resolvingSymlinksInPath().path == appBundleURL.path else { throw Failure.invalidTools }
            let toolchain = developer.appendingPathComponent("Toolchains/XcodeDefault.xctoolchain").resolvingSymlinksInPath()
            let compiler = toolchain.appendingPathComponent("usr/bin/clang").resolvingSymlinksInPath()
            let sdk = developer.appendingPathComponent("Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk").resolvingSymlinksInPath()
            let runner = appBundleURL.appendingPathComponent("Contents/MacOS/SourceExecutionRunner")
            return try .init(compilerPath: compiler.path, sdkRootPath: sdk.path, toolchainRootPath: toolchain.path,
                runnerSHA256: hashFile(runner, maximum: 268_435_456),
                compilerSHA256: hashFile(compiler, maximum: 268_435_456),
                sdkSettingsSHA256: hashFile(sdk.appendingPathComponent("SDKSettings.json"), maximum: 1_048_576))
        }
        /// A hash is accepted only from a read window in which the file's identity, size, mtime and
        /// ctime held still. A metadata-only change during the read (seen on the shared Xcode clang
        /// under parallel test hosts) re-reads; three unstable windows in a row fail closed.
        private static func hashFile(_ url: URL, maximum: Int64) throws -> String {
            for _ in 0..<3 {
                if let digest = try hashFileOnce(url, maximum: maximum) { return digest }
            }
            throw Failure.invalidTools
        }
        /// nil: the read window was unstable and may be retried.
        private static func hashFileOnce(_ url: URL, maximum: Int64) throws -> String? {
            guard url.resolvingSymlinksInPath().path == url.path else { throw Failure.invalidTools }
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Failure.invalidTools }; defer { close(fd) }
            var before = stat(), after = stat(), path = stat()
            guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
                  before.st_nlink == 1, (before.st_mode & 0o022) == 0,
                  before.st_size > 0, before.st_size <= maximum else { throw Failure.invalidTools }
            var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 65536), total: Int64 = 0
            while true {
                let n = Darwin.read(fd, &buffer, buffer.count)
                if n < 0 && errno == EINTR { continue }
                guard n >= 0 else { throw Failure.invalidTools }; if n == 0 { break }
                total += Int64(n); guard total <= maximum else { throw Failure.invalidTools }
                hash.update(data: Data(buffer.prefix(n)))
            }
            guard fstat(fd, &after) == 0, lstat(url.path, &path) == 0,
                  before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                  after.st_dev == path.st_dev, after.st_ino == path.st_ino,
                  before.st_size == total, after.st_size == total else { throw Failure.invalidTools }
            guard before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { return nil }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }
    struct ValidatedOracle: Sendable {
        let oracle: ReconstructionSourceOracle
        init(record: ReconstructionEvidenceRecord, context: ReconstructionSourceOracleEvidence.Context) throws {
            oracle = try ReconstructionSourceOracleEvidence.validate(record: record, context: context)
        }
    }
    enum Purpose: Sendable {
        case original(function: ReconstructionFunctionCoordinate)
        case revision(revision: ReconstructionSourceRevision, authority: ReconstructionSourceRevisionAuthority,
                      oracle: ValidatedOracle)
        var function: ReconstructionFunctionCoordinate {
            switch self {
            case .original(let function): function
            case .revision(let revision, _, _): revision.function
            }
        }
    }
    enum Failure: Error, Equatable, Sendable {
        case cancelled, invalidTools, invalidAuthority, changedInputs
        case transport(Phase2SourceExecutionOperation, String)
        case phaseRejected(Phase2SourceExecutionOperation)
        case invalidInspection, astRejected(String), invalidExecutable, invalidBehaviorOutput, behaviorMismatch
    }
    struct Phase: Equatable, Sendable {
        let request: Phase2SourceExecutionRequest
        let response: Phase2SourceExecutionResponse?
        let transportError: String?
    }
    struct Observation: Equatable, Sendable { let input: UInt32; let output: UInt32 }
    enum ExecutableOrigin: Equatable, Sendable { case compiled, retained }
    struct Mismatch: Equatable, Sendable {
        let index: Int
        let input: UInt32
        let expected: UInt32
        let actual: UInt32
    }
    struct Outcome: Equatable, Sendable {
        let sourceAuthority: ReconstructionSourceExecutionStage.SourceAuthority
        let function: ReconstructionFunctionCoordinate
        let sourceSHA256: String
        let harnessSHA256: String
        let toolAuthority: ToolAuthority
        let oracleSuiteSHA256: String?
        let phases: [Phase]
        let inspection: ReconstructionSourceExecutionStage.FileIdentity?
        let astAdmission: ReconstructionSourceASTAdmission.Result?
        let executable: ReconstructionSourceExecutionStage.FileIdentity?
        let observations: [Observation]
        let mismatches: [Mismatch]
        let failure: Failure?
        /// `.retained`: the original executable was recovered from the job's durably admitted bytes
        /// (exact SHA-256), not compiled in this stage; its phases are then [inspect, behavior].
        var executableOrigin: ExecutableOrigin = .compiled
        var observedOriginal: Bool {
            if case .trustedOriginal = sourceAuthority { return failure == nil && observations.count == 37 }
            return false
        }
        var matchesOracle: Bool {
            if case .admittedRevision = sourceAuthority {
                return failure == nil && oracleSuiteSHA256 != nil && observations.count == 37 && mismatches.isEmpty
            }
            return false
        }
    }

    let transport: any ShellBrokerXPCTransport
    let toolAuthority: ToolAuthority

    fileprivate struct ExecutionOutcome: Sendable {
        let sourceAuthority: ReconstructionSourceExecutionStage.SourceAuthority
        let sourceSHA256: String
        let harnessSHA256: String
        let toolAuthority: ToolAuthority
        let oracleSuiteSHA256: String?
        let phases: [Phase]
        let inspection: ReconstructionSourceExecutionStage.FileIdentity?
        let astAdmission: ReconstructionSourceASTAdmission.Result?
        let executable: ReconstructionSourceExecutionStage.FileIdentity?
        let observations: [Observation]
        let mismatches: [Mismatch]
        let failure: Failure?
        var executableOrigin: ExecutableOrigin = .compiled
        func bound(to function: ReconstructionFunctionCoordinate, rejecting: Failure? = nil) -> Outcome {
            .init(sourceAuthority: sourceAuthority, function: function, sourceSHA256: sourceSHA256,
                harnessSHA256: harnessSHA256, toolAuthority: toolAuthority, oracleSuiteSHA256: oracleSuiteSHA256,
                phases: phases, inspection: inspection, astAdmission: astAdmission, executable: executable,
                observations: observations, mismatches: mismatches, failure: rejecting ?? failure,
                executableOrigin: executableOrigin)
        }
        func retained(executable: ReconstructionSourceExecutionStage.FileIdentity?, failure: Failure?) -> Self {
            .init(sourceAuthority: sourceAuthority, sourceSHA256: sourceSHA256, harnessSHA256: harnessSHA256,
                toolAuthority: toolAuthority, oracleSuiteSHA256: oracleSuiteSHA256, phases: phases,
                inspection: inspection, astAdmission: astAdmission, executable: executable,
                observations: observations, mismatches: mismatches, failure: failure, executableOrigin: .retained)
        }
    }
    struct PreparedOriginal: Sendable {
        let stage: ReconstructionSourceExecutionStage
        fileprivate let execution: ExecutionOutcome
        var phases: [Phase] { execution.phases }
        var toolAuthority: ToolAuthority { execution.toolAuthority }
        var inspection: ReconstructionSourceExecutionStage.FileIdentity? { execution.inspection }
        var astAdmission: ReconstructionSourceASTAdmission.Result? { execution.astAdmission }
        var executable: ReconstructionSourceExecutionStage.FileIdentity? { execution.executable }
        var failure: Failure? { execution.failure }
        var executableOrigin: ExecutableOrigin { execution.executableOrigin }
        /// The phases a usable prepared original must carry for its origin.
        var hasPreparationPhases: Bool {
            phases.map(\.request.operation) == (executableOrigin == .retained ? [.inspect] : [.inspect, .compile])
        }
    }

    func run(stage: ReconstructionSourceExecutionStage, purpose: Purpose) async -> Outcome {
        await execute(stage: stage, purpose: purpose, operations: [.inspect, .compile, .behavior]).bound(to: purpose.function)
    }
    /// No function coordinate exists yet. The owner imports this exact captured executable through
    /// its existing binary/analysis owner, then supplies that qualified coordinate to observeOriginal.
    func prepareOriginal(stage: ReconstructionSourceExecutionStage) async -> PreparedOriginal {
        let execution = await execute(stage: stage, purpose: nil, operations: [.inspect, .compile])
        return .init(stage: stage, execution: execution)
    }
    /// Resume recovery: never recompiles. The fixed original source is inspected (AST admission
    /// only, no artifact), then the job's durably admitted executable bytes are installed as the
    /// stage's candidate. `retainedExecutable` must already be verified against the admitted
    /// SHA-256 by the caller; the stage re-verifies the installed identity against the same hash.
    func prepareRetainedOriginal(stage: ReconstructionSourceExecutionStage, retainedExecutable: Data,
                                 expectedSHA256: String) async -> PreparedOriginal {
        let inspected = await execute(stage: stage, purpose: nil, operations: [.inspect])
        if let failure = inspected.failure {
            return .init(stage: stage, execution: inspected.retained(executable: nil, failure: failure))
        }
        if Task.isCancelled { return .init(stage: stage, execution: inspected.retained(executable: nil, failure: .cancelled)) }
        do {
            let identity = try stage.installRetainedExecutable(retainedExecutable, expectedSHA256: expectedSHA256)
            return .init(stage: stage, execution: inspected.retained(executable: identity, failure: nil))
        } catch {
            return .init(stage: stage, execution: inspected.retained(executable: nil, failure: .invalidExecutable))
        }
    }
    func observeOriginal(prepared: PreparedOriginal, function: ReconstructionFunctionCoordinate) async -> Outcome {
        // A prepared artifact cannot cross toolchain, workflow or stage authority.
        guard prepared.execution.toolAuthority == toolAuthority,
              prepared.hasPreparationPhases || prepared.failure != nil else {
            return prepared.execution.bound(to: function, rejecting: .invalidAuthority)
        }
        return await execute(stage: prepared.stage, purpose: .original(function: function),
            operations: [.behavior], previous: prepared.execution).bound(to: function)
    }

    private func execute(stage: ReconstructionSourceExecutionStage, purpose: Purpose?,
                         operations: [Phase2SourceExecutionOperation], previous: ExecutionOutcome? = nil) async -> ExecutionOutcome {
        var phases = previous?.phases ?? [], inspection = previous?.inspection
        var ast = previous?.astAdmission, executable = previous?.executable
        var observations: [Observation] = [], mismatches: [Mismatch] = []
        let oracle: ReconstructionSourceOracle?
        if case .revision(_, _, let value) = purpose { oracle = value.oracle } else { oracle = nil }
        func result(_ failure: Failure?) -> ExecutionOutcome {
            .init(sourceAuthority: stage.sourceAuthority,
                sourceSHA256: stage.source.sha256, harnessSHA256: stage.harness.sha256,
                toolAuthority: toolAuthority, oracleSuiteSHA256: oracle?.suiteSHA256,
                phases: phases, inspection: inspection, astAdmission: ast, executable: executable,
                observations: observations, mismatches: mismatches, failure: failure,
                executableOrigin: previous?.executableOrigin ?? .compiled)
        }
        if let previous, let failure = previous.failure { return result(failure) }
        if Task.isCancelled { return result(.cancelled) }
        let harness: ReconstructionSourceBehaviorHarness
        do {
            harness = try .forProfile(stage.profileID)
            guard harness.inputs.count == 37, stage.harness.sha256 ==
                    ReconstructionSourceRevisionAdmission.sourceSHA256(harness.sourceUTF8),
                  stage.harness.byteCount == harness.sourceUTF8.count else { return result(.invalidAuthority) }
            if let purpose, purpose.function.image.architecture != .arm64 { return result(.invalidAuthority) }
            switch (stage.sourceAuthority, purpose) {
            case (.trustedOriginal(let hash), .original), (.trustedOriginal(let hash), nil):
                guard hash == stage.source.sha256 else { return result(.invalidAuthority) }
            case (.admittedRevision(let hash), .revision(let revision, let authority, let validated)):
                _ = try ReconstructionSourceRevisionAdmission.decodeAndValidate(
                    payload: ReconstructionSourceRevisionAdmission.encode(revision), authority: authority)
                let oracle = validated.oracle
                guard hash == revision.revisionSHA256, stage.source.sha256 == revision.sourceSHA256,
                      stage.source.byteCount == revision.sourceUTF8.count, revision.function == oracle.function,
                      revision.projectID == oracle.projectID, revision.jobID == oracle.jobID,
                      revision.profileID == stage.profileID, revision.profileID == authority.profileID,
                      revision.profileID == oracle.profileID, revision.oracleSuiteSHA256 == oracle.suiteSHA256,
                      oracle.inputs == harness.inputs, oracle.execution.harnessSHA256 == stage.harness.sha256,
                      oracle.execution.compilerSHA256 == toolAuthority.compilerSHA256,
                      oracle.execution.sdkIdentitySHA256 == toolAuthority.sdkSettingsSHA256 else {
                    return result(.invalidAuthority)
                }
            default: return result(.invalidAuthority)
            }
            try stage.verifyInputs()
        } catch is CancellationError { return result(.cancelled) }
        catch { return result(.invalidAuthority) }

        let sessionID = previous?.phases.first?.request.sessionID ?? UUID()
        let wireAuthority: Phase2SourceExecutionAuthorityKind = switch stage.sourceAuthority {
        case .trustedOriginal: .original
        case .admittedRevision: .admittedRevision
        }
        for operation in operations {
            if Task.isCancelled { return result(.cancelled) }
            do {
                try stage.verifyInputs()
                if operation != .inspect {
                    guard let inspection, try stage.captureInspection() == inspection else { return result(.invalidInspection) }
                }
                if operation == .behavior {
                    guard let executable else { return result(.invalidExecutable) }
                    try stage.verifyExecutable(executable)
                    if case .original(let function) = purpose {
                        guard function.artifact.contentIdentity.algorithm == .sha256,
                              function.artifact.contentIdentity.digest == executable.sha256,
                              function.artifact.contentIdentity.byteCount == UInt64(executable.byteCount) else {
                            return result(.invalidAuthority)
                        }
                    }
                }
            } catch is CancellationError { return result(.cancelled) }
            catch { return result(.changedInputs) }
            let request = Phase2SourceExecutionRequest(requestID: UUID(), sessionID: sessionID, operation: operation,
                sourceAuthority: wireAuthority,
                stageRootPath: stage.root.path, revisionSHA256: stage.revisionSHA256,
                sourceSHA256: stage.source.sha256, harnessSHA256: stage.harness.sha256,
                compilerPath: toolAuthority.compilerPath, sdkRootPath: toolAuthority.sdkRootPath,
                toolchainRootPath: toolAuthority.toolchainRootPath, runnerSHA256: toolAuthority.runnerSHA256,
                compilerSHA256: toolAuthority.compilerSHA256, sdkSettingsSHA256: toolAuthority.sdkSettingsSHA256)
            guard request.isValid, request.sourceProfile?.rawValue == stage.profileID else { return result(.invalidTools) }
            let response: Phase2SourceExecutionResponse
            do { response = try await transport.executeSource(request) }
            catch {
                let description = String(String(describing: error).prefix(1024))
                phases.append(.init(request: request, response: nil, transportError: description))
                return result(error is CancellationError ? .cancelled : .transport(operation, description))
            }
            // Retain actual diagnostics and cleanup before interpreting cancellation or validation.
            phases.append(.init(request: request, response: response, transportError: nil))
            if Task.isCancelled || response.failure == .cancelled { return result(.cancelled) }
            guard response.isValid, response.requestID == request.requestID,
                  response.sessionID == request.sessionID, response.operation == operation,
                  response.status == .completed, response.failure == nil,
                  response.terminal == .init(kind: .exited, status: 0),
                  let cleanup = response.cleanup, cleanup.requestID == request.requestID,
                  cleanup.sessionID == sessionID, cleanup.observedProcessAbsent,
                  cleanup.outcome == .init(kind: .exited, status: 0),
                  response.sampledProcessIDs.contains(cleanup.processIdentifier) else {
                return result(.phaseRejected(operation))
            }
            do {
                try stage.verifyInputs()
                switch operation {
                case .inspect:
                    let captured = try stage.captureInspectionBytes()
                    inspection = captured.identity
                    do {
                        ast = try ReconstructionSourceASTAdmission.validate(json: captured.bytes,
                            expectedSourceSHA256: stage.source.sha256, profileID: stage.profileID)
                    } catch { return result(.astRejected(String(String(describing: error).prefix(1024)))) }
                case .compile:
                    // Revalidate the admitted AST bytes before accepting the linked artifact.
                    guard let inspection, try stage.captureInspection() == inspection else { return result(.invalidInspection) }
                    executable = try stage.captureExecutable()
                case .behavior:
                    guard let executable else { return result(.invalidExecutable) }
                    try stage.verifyExecutable(executable)
                    let outputs: [UInt32]
                    do { outputs = try harness.decodeObservedOutputs(response.diagnostics) }
                    catch { return result(.invalidBehaviorOutput) }
                    observations = zip(harness.inputs, outputs).map { .init(input: $0.0, output: $0.1) }
                    if let oracle {
                        mismatches = outputs.enumerated().compactMap { index, output in
                            guard output != oracle.outputs[index] else { return nil }
                            return .init(index: index, input: harness.inputs[index], expected: oracle.outputs[index], actual: output)
                        }
                    }
                }
            } catch is CancellationError { return result(.cancelled) }
            catch { return result(operation == .inspect ? .invalidInspection : .changedInputs) }
        }
        return result(mismatches.isEmpty ? nil : .behaviorMismatch)
    }
}
