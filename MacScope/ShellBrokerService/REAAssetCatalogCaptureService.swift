import Darwin
import Foundation
import Security
#if TESTING_SHELL_BROKER_PRINCIPAL
@testable import MacScope
#endif

/// Authenticated broker entry point; sourceAdmissionGate and the existing process lease own execution.
final class REAAssetCatalogCaptureService: @unchecked Sendable {
#if TESTING_SHELL_BROKER_PRINCIPAL
    private typealias CaptureTerminal = MacScope.Phase2SourceExecutionTerminal
    private typealias CaptureCleanup = MacScope.Phase2SourceExecutionCleanup
#else
    private typealias CaptureTerminal = Phase2SourceExecutionTerminal
    private typealias CaptureCleanup = Phase2SourceExecutionCleanup
#endif
    private let lock = NSLock()
    private let queue = DispatchQueue(label:"org.macscope.app.asset-catalog")
    private var invalidated = false
    private var active: REAAssetCatalogCaptureRequest?
    private var cancelled = Set<UUID>()
    private var seen = Set<UUID>()
    func invalidate() { lock.withLock { invalidated = true; if let active { cancelled.insert(active.requestID) } } }
    func cancel(_ data: Data, reply: @escaping (Data) -> Void) {
        guard let request = decode(data) else { reply(Data()); return }
        let accepted = lock.withLock { () -> Bool in
            guard cancelled.count < 65536, seen.count < 65536, active == nil || active == request else { return false }
            cancelled.insert(request.requestID); return true
        }
        reply((try? REAAssetCatalogAuthority.encode(REAAssetCatalogCaptureResponse.rejected(request,accepted ? "cancelled" : "identityMismatch"))) ?? Data())
    }
    func execute(_ data: Data, reply: @escaping (Data) -> Void) {
        guard let request = decode(data) else { reply(Data()); return }
        let accepted = lock.withLock { () -> Bool in
            guard !invalidated, active == nil, seen.count < 65536, !seen.contains(request.requestID) else { return false }
            active = request; seen.insert(request.requestID); return true
        }
        guard accepted else { reply((try? REAAssetCatalogAuthority.encode(REAAssetCatalogCaptureResponse.rejected(request,"admissionRejected"))) ?? Data()); return }
        queue.async { [self] in
            let response = run(request)
            lock.withLock { active = nil }
            reply((try? REAAssetCatalogAuthority.encode(response)) ?? Data())
        }
    }
    private func decode(_ data: Data) -> REAAssetCatalogCaptureRequest? {
        guard data.count <= 65536, let request = try? JSONDecoder().decode(REAAssetCatalogCaptureRequest.self,from:data), request.isValid,
              (try? REAAssetCatalogAuthority.encode(request)) == data else { return nil }; return request
    }
    private func run(_ request: REAAssetCatalogCaptureRequest) -> REAAssetCatalogCaptureResponse {
        guard Phase2ShellBrokerPrincipal.sourceAdmissionGate.begin() else { return .rejected(request,"busy") }
        defer { Phase2ShellBrokerPrincipal.sourceAdmissionGate.end() }
        do {
            guard !lock.withLock({ invalidated || cancelled.contains(request.requestID) }) else { return .rejected(request,"cancelled") }
            try REAAssetCatalogAuthority.verify(request)
            try Self.attest(URL(fileURLWithPath:"/usr/bin/assetutil"), requirement:"anchor apple and identifier \"com.apple.assetutil\"")
            let runner = try Self.runner(request)
            let plan = Phase2HumanPTYLaunchPlan(sessionID:request.sessionID,requestID:request.requestID,executablePath:runner.path,
                arguments:["asset-catalog",request.stageRootPath],environment:[:],workingDirectoryPath:request.stageRootPath,
                initialSize:.defaultInteractive,transcriptLimits:.init(maximumEvents:64,maximumEventBytes:4096,maximumCumulativeBytes:16384))
            let result = try Phase2ShellBrokerProcessAdapter().executeSource(plan,cancelled:{ [self] in lock.withLock { invalidated || cancelled.contains(request.requestID) } })
            var failure = result.failure?.rawValue
            do { try REAAssetCatalogAuthority.verify(request); _ = try Self.runner(request) } catch { failure = failure ?? "identityChanged" }
            var metadata = Data()
            do {
                let path = request.stageRootPath + "/output/stdout"
                let fd = open(path,O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw REAAssetCatalogAuthority.Failure.invalidInput }
                let status = fchmod(fd,0o400); close(fd)
                guard status == 0 else { throw REAAssetCatalogAuthority.Failure.invalidInput }
                metadata = try REAAssetCatalogAuthority.bytes(path,maximum:8_388_608,owner:getuid())
                _ = try REAAssetCatalogAuthority.metadataJSON(metadata)
            } catch { failure = failure ?? "metadataUnavailableOrLimit" }
            let proof = result.cleanupProof
            let terminal = result.terminalOutcome.map(Self.terminal)
            return .init(request:request,receiptID:UUID(),metadata:metadata,metadataSHA256:REAAssetCatalogAuthority.digest(metadata),failure:failure,
                terminal:terminal,cleanup:.init(sessionID:proof.sessionID,requestID:proof.requestID,processIdentifier:proof.processIdentifier,
                    observedProcessAbsent:proof.observedProcessAbsent,outcome:Self.terminal(proof.outcome)),elapsedSeconds:result.elapsedSeconds)
        } catch { return .rejected(request,String(describing:error)) }
    }
    private static func attest(_ url: URL, requirement text: String) throws {
        var code: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL,SecCSFlags(),&code) == errSecSuccess,let code,
              SecRequirementCreateWithString(text as CFString,SecCSFlags(),&requirement) == errSecSuccess,let requirement,
              SecStaticCodeCheckValidity(code,SecCSFlags(rawValue:kSecCSStrictValidate | kSecCSCheckAllArchitectures),requirement) == errSecSuccess else { throw REAAssetCatalogAuthority.Failure.invalidInput }
    }
    private static func runner(_ request: REAAssetCatalogCaptureRequest) throws -> URL {
        guard var app = Bundle.main.executableURL else { throw REAAssetCatalogAuthority.Failure.invalidInput }
        for _ in 0..<8 { app.deleteLastPathComponent(); if app.pathExtension == "app" { break } }
        guard app.pathExtension == "app" else { throw REAAssetCatalogAuthority.Failure.invalidInput }
        let runner = app.appendingPathComponent("Contents/MacOS/SourceExecutionRunner")
        guard REAAssetCatalogAuthority.digest(try REAAssetCatalogAuthority.bytes(runner.path,maximum:268_435_456,owner:getuid(),readOnly:false)) == request.runnerSHA256 else { throw REAAssetCatalogAuthority.Failure.changedIdentity }
        try attest(runner,requirement:Phase2ShellBrokerPeerRequirement.sourceRunner); return runner
    }
    private static func terminal(_ outcome: Phase2HumanPTYTerminalOutcome) -> CaptureTerminal {
        switch outcome {
        case .exited(let status): return .init(kind:.exited,status:status)
        case .signaled(let signal):
            let status: Int32 = switch signal { case .interrupt: SIGINT; case .terminate: SIGTERM; case .suspend: SIGTSTP; case .continueSignal: SIGCONT }
            return .init(kind:.signaled,status:status)
        case .canceled: return .init(kind:.canceled,status:nil)
        case .interrupted: return .init(kind:.interrupted,status:nil)
        case .brokerCrashed: return .init(kind:.brokerCrashed,status:nil)
        case .outcomeUnknown: return .init(kind:.outcomeUnknown,status:nil)
        }
    }
}
