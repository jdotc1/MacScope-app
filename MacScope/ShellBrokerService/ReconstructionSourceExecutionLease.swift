import Darwin
import Foundation
#if TESTING_SHELL_BROKER_PRINCIPAL
@testable import MacScope
#endif

/// Fixed policy for app-owned source execution. The existing broker lease remains the only owner.
enum ReconstructionSourceExecutionPolicy {
    static let acknowledgment = Array("MACSCOPE_SOURCE_EXECUTION_ACK_V1\n".utf8)
    static let maximumWallSeconds: TimeInterval = 10
    static let maximumObservationRetryNanoseconds: UInt64 = 20_000_000
    static let observationRetryMicroseconds: useconds_t = 1_000
    /// Consecutive failed group cuts (each already retried for the window above) tolerated while
    /// the group still exists, before the run fails closed as unobservable (~1 s with PTY reads).
    static let maximumConsecutiveUnobservableCuts = 25
    static let maximumDiagnosticBytes = 16_384
    static let compileMaximumResidentBytes: UInt64 = 1_073_741_824
    static let behaviorMaximumResidentBytes: UInt64 = 268_435_456
}

enum ReconstructionSourceExecutionFailure: String, Sendable {
    case cancelled, deadline, diagnosticsLimit, residentMemoryLimit
    case observationUnavailable, handshakeFailed, cleanupFailed
}

struct ReconstructionSourceExecutionResult: Sendable {
    let failure: ReconstructionSourceExecutionFailure?
    let terminalOutcome: Phase2HumanPTYTerminalOutcome?
    let diagnostics: Data
    let peakGroupResidentBytes: UInt64
    let sampledProcessIDs: [Int32]
    let elapsedSeconds: TimeInterval
    let cleanupProof: Phase2ShellBrokerCleanupProof
}

struct ReconstructionSourceExecutionGroupObservation: Sendable {
    let processIDs: [Int32]
    let residentBytes: UInt64

    /// Includes every process currently in the broker-owned group, not only its leader.
    /// A raced, truncated, inaccessible, or malformed observation cannot authorize continuation.
    static func capture(groupID: Int32) -> Self? {
        guard groupID > 0 else { return nil }
        return freshCompleteCut { captureOnce(groupID: groupID) }
    }

    /// Yield between fresh attempts so an exiting compiler child can be reaped. No part of a
    /// failed attempt is reused, and expiry never turns missing RSS into an accepted observation.
    static func freshCompleteCut(
        nowNanoseconds: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        wait: (useconds_t) -> Void = { usleep($0) },
        read: () -> Self?
    ) -> Self? {
        let deadline = nowNanoseconds()
            + ReconstructionSourceExecutionPolicy.maximumObservationRetryNanoseconds
        repeat {
            if let observation = read() { return observation }
            let now = nowNanoseconds()
            guard now < deadline else { return nil }
            let remainingMicroseconds = (deadline - now) / 1_000
            guard remainingMicroseconds > 0 else { return nil }
            wait(useconds_t(min(UInt64(ReconstructionSourceExecutionPolicy.observationRetryMicroseconds),
                remainingMicroseconds)))
        } while nowNanoseconds() < deadline
        return nil
    }

    private static func processIDs(groupID: Int32) -> [Int32]? {
        let capacity = 1_024
        var identifiers = [Int32](repeating: 0, count: capacity)
        let byteCount = identifiers.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(groupID), buffer.baseAddress, Int32(buffer.count))
        }
        guard byteCount > 0, Int(byteCount) < capacity * MemoryLayout<Int32>.size,
              Int(byteCount).isMultiple(of: MemoryLayout<Int32>.size) else { return nil }
        let ids = Array(identifiers.prefix(Int(byteCount) / MemoryLayout<Int32>.size)).sorted()
        guard ids.allSatisfy({ $0 > 0 }), Set(ids).count == ids.count else { return nil }
        return ids
    }

    private static func captureOnce(groupID: Int32) -> Self? {
        guard let ids = processIDs(groupID: groupID) else { return nil }
        var resident: UInt64 = 0
        for id in ids {
            var before = proc_taskallinfo(), after = proc_taskallinfo()
            let size = Int32(MemoryLayout<proc_taskallinfo>.size)
            guard proc_pidinfo(id, PROC_PIDTASKALLINFO, 0, &before, size) == size,
                  proc_pidinfo(id, PROC_PIDTASKALLINFO, 0, &after, size) == size,
                  before.pbsd.pbi_pid == UInt32(id), after.pbsd.pbi_pid == UInt32(id),
                  before.pbsd.pbi_pgid == UInt32(groupID), after.pbsd.pbi_pgid == UInt32(groupID),
                  before.pbsd.pbi_uid == getuid(), after.pbsd.pbi_uid == getuid(),
                  before.pbsd.pbi_start_tvsec == after.pbsd.pbi_start_tvsec,
                  before.pbsd.pbi_start_tvusec == after.pbsd.pbi_start_tvusec else { return nil }
            let bytes = max(before.ptinfo.pti_resident_size, after.ptinfo.pti_resident_size)
            let sum = resident.addingReportingOverflow(bytes)
            guard !sum.overflow else { return nil }
            resident = sum.partialValue
        }
        // A fork or exit during the per-member reads invalidates the whole cut. Re-enumerate;
        // every current member must have both exact identity and RSS observations above.
        guard processIDs(groupID: groupID) == ids else { return nil }
        return .init(processIDs: ids, residentBytes: resident)
    }
}

extension Phase2ShellBrokerProcessAdapter {
    /// Invoke off the broker command queue. Cancellation authority stays with the caller and lease.
    /// Source/toolchain/binary attestation belongs to admission before this fixed launcher plan.
    func executeSource(_ plan: Phase2HumanPTYLaunchPlan,
        cancelled: @Sendable () -> Bool = { Task.isCancelled }) throws -> ReconstructionSourceExecutionResult {
        let isCompile = plan.arguments.count == 5 && ["compile", "inspect"].contains(plan.arguments.first ?? "")
        let isBehavior = plan.arguments.count == 2 && plan.arguments.first == "behavior"
        let isScenario = plan.arguments.count == 2 && plan.arguments.first == "scenario"
        let isAssetCatalog = plan.arguments.count == 2 && plan.arguments.first == "asset-catalog"
        guard URL(fileURLWithPath: plan.executablePath).lastPathComponent == "SourceExecutionRunner",
              isCompile || isBehavior || isScenario || isAssetCatalog else { throw LaunchError.invalidLaunchPlan([]) }
        let began = DispatchTime.now().uptimeNanoseconds
        let lease = try launch(plan, sourceExecutionHandshake: true)
        var failure: ReconstructionSourceExecutionFailure?
        var diagnostics = Data()
        var peak: UInt64 = 0
        var observedIDs = Set<Int32>()
        var unobservableCuts = 0
        let residentLimit = isCompile ? ReconstructionSourceExecutionPolicy.compileMaximumResidentBytes
            : ReconstructionSourceExecutionPolicy.behaviorMaximumResidentBytes
        func elapsed() -> TimeInterval {
            Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000_000
        }
        defer { _ = lease.cleanup(timeout: 1) }
        if cancelled() { failure = .cancelled }
        else if let observation = ReconstructionSourceExecutionGroupObservation.capture(
            groupID: lease.ownedProcess.processIdentifier) {
            peak = observation.residentBytes
            observedIDs.formUnion(observation.processIDs)
            if peak > residentLimit { failure = .residentMemoryLimit }
            else {
                do {
                    guard try lease.writeInput(ReconstructionSourceExecutionPolicy.acknowledgment)
                        == ReconstructionSourceExecutionPolicy.acknowledgment.count else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                } catch { failure = .handshakeFailed }
            }
        } else { failure = .observationUnavailable }
        while failure == nil {
            if cancelled() { failure = .cancelled; break }
            if elapsed() >= ReconstructionSourceExecutionPolicy.maximumWallSeconds {
                failure = .deadline; break
            }
            let bytes = lease.readAvailablePTYOutput(maxBytes: 4_096, timeout: 0.02)
            let remaining = ReconstructionSourceExecutionPolicy.maximumDiagnosticBytes - diagnostics.count
            diagnostics.append(contentsOf: bytes.prefix(remaining))
            if bytes.count > remaining { failure = .diagnosticsLimit; break }
            if !lease.isRunning { break }
            guard let observation = ReconstructionSourceExecutionGroupObservation.capture(
                groupID: lease.ownedProcess.processIdentifier) else {
                // Natural exit may race sampling, but only an observed group exit authorizes it.
                if !lease.isRunning { break }
                // An exited but not yet reaped member (a zombie) has no task info, so the cut
                // fails while the group still exists. Under host load reaping can take longer
                // than one capture's retry window; tolerate a bounded run of such cuts.
                unobservableCuts += 1
                if unobservableCuts > ReconstructionSourceExecutionPolicy.maximumConsecutiveUnobservableCuts {
                    failure = .observationUnavailable; break
                }
                continue
            }
            unobservableCuts = 0
            peak = max(peak, observation.residentBytes)
            observedIDs.formUnion(observation.processIDs)
            if observedIDs.count > 1_024 { failure = .observationUnavailable; break }
            if observation.residentBytes > residentLimit { failure = .residentMemoryLimit; break }
        }
        // Drain the remaining bounded PTY bytes after natural exit before closing its descriptor.
        if failure == nil {
            while true {
                let bytes = lease.readAvailablePTYOutput(maxBytes: 4_096, timeout: 0)
                if bytes.isEmpty { break }
                let remaining = ReconstructionSourceExecutionPolicy.maximumDiagnosticBytes - diagnostics.count
                diagnostics.append(contentsOf: bytes.prefix(remaining))
                if bytes.count > remaining { failure = .diagnosticsLimit; break }
            }
        }
        let terminal = lease.terminalOutcomeAfterObservedExit()
        if failure == nil && (terminal == nil || terminal == .outcomeUnknown) { failure = .observationUnavailable }
        let proof = lease.cleanup(outcome: terminal ?? .canceled, timeout: 1)
        if !proof.observedProcessAbsent { failure = .cleanupFailed }
        return .init(failure: failure, terminalOutcome: terminal, diagnostics: diagnostics,
            peakGroupResidentBytes: peak, sampledProcessIDs: observedIDs.sorted(),
            elapsedSeconds: elapsed(), cleanupProof: proof)
    }
}
