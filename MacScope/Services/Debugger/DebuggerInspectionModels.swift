import CryptoKit
import Foundation

// MARK: - WS-23 exact stopped-inspection identity

/// Stable digest of the accepted debugger target authority used to bind inspection data to the
/// exact launched/attached process identity that the reducer already accepted.
///
/// The digest deliberately records the target origin as well as the immutable process digest so a
/// launched target and an attached target with the same executable facts do not alias UI freshness
/// decisions.
struct DebuggerInspectionTargetDigest: Hashable, Sendable {
    let lowercaseHex: String

    init(authority: DebuggerSessionTargetAuthority) {
        var material = Data()
        switch authority.origin {
        case .launched:
            material.appendLengthFramed("launched")
        case .attached:
            material.appendLengthFramed("attached")
        }
        material.appendLengthFramed(String(authority.processID))
        material.appendLengthFramed(authority.identityDigest.lowercaseHex)
        lowercaseHex = material.sha256LowercaseHex
    }
}

/// Stable thread identity for one stopped inspection packet.
///
/// `index` is LLDB's 1-based thread index. `tid` is preferred when LLDB reports it, while
/// `uniqueNameDigest` lets a backend carry a bounded digest of queue/name evidence without placing
/// user-controlled thread names in identity logs.
struct DebuggerThreadIdentity: Hashable, Sendable {
    let index: Int
    let tid: UInt64?
    let uniqueNameDigest: String?

    init?(
        index: Int,
        tid: UInt64? = nil,
        uniqueNameDigest: String? = nil
    ) {
        guard index > 0,
              tid.map({ $0 > 0 }) ?? true,
              uniqueNameDigest.map(Self.isValidLowercaseSHA256) ?? true else {
            return nil
        }
        self.index = index
        self.tid = tid
        self.uniqueNameDigest = uniqueNameDigest
    }

    init?(summary: DebuggerThreadSummary) {
        let digest = summary.queueName.flatMap { Self.digestIfNonEmpty($0) }
        self.init(index: summary.index, tid: summary.tid, uniqueNameDigest: digest)
    }

    private static func digestIfNonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Data(trimmed.utf8).sha256LowercaseHex
    }

    private static func isValidLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

/// Stable frame identity for one stopped inspection packet.
///
/// `frameIndex` is LLDB's 0-based frame index. Function names remain optional display evidence and
/// are digested only when used by callers; the primary identity is thread + frame + PC.
struct DebuggerFrameIdentity: Hashable, Sendable {
    let thread: DebuggerThreadIdentity
    let frameIndex: Int
    let programCounter: UInt64
    let canonicalFunctionName: String?

    init?(
        thread: DebuggerThreadIdentity,
        frameIndex: Int,
        programCounter: UInt64,
        canonicalFunctionName: String? = nil
    ) {
        guard frameIndex >= 0,
              canonicalFunctionName.map(Self.isValidDisplayString) ?? true else {
            return nil
        }
        self.thread = thread
        self.frameIndex = frameIndex
        self.programCounter = programCounter
        self.canonicalFunctionName = canonicalFunctionName
    }

    init?(
        thread: DebuggerThreadIdentity,
        summary: DebuggerFrameSummary
    ) {
        self.init(
            thread: thread,
            frameIndex: summary.index,
            programCounter: summary.address,
            canonicalFunctionName: summary.functionName.isEmpty ? nil : summary.functionName
        )
    }

    private static func isValidDisplayString(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 4_096
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

/// Complete owner coordinate for any WS-23 stopped inspection result.
///
/// A variable tree, watch result, source mapping, VM-region projection, register group, or memory
/// preview may be displayed as fresh only while this exact coordinate still matches the visible
/// session state.
struct DebuggerInspectionCoordinate: Hashable, Sendable {
    let stop: DebuggerStopCoordinate
    let targetDigest: DebuggerInspectionTargetDigest
    let thread: DebuggerThreadIdentity
    let frame: DebuggerFrameIdentity

    init?(
        stop: DebuggerStopCoordinate,
        targetAuthority: DebuggerSessionTargetAuthority,
        thread: DebuggerThreadIdentity,
        frame: DebuggerFrameIdentity
    ) {
        guard frame.thread == thread else { return nil }
        self.stop = stop
        self.targetDigest = DebuggerInspectionTargetDigest(authority: targetAuthority)
        self.thread = thread
        self.frame = frame
    }

    func matches(
        stop currentStop: DebuggerStopCoordinate?,
        targetAuthority currentAuthority: DebuggerSessionTargetAuthority?,
        selectedThread currentThread: DebuggerThreadIdentity?,
        selectedFrame currentFrame: DebuggerFrameIdentity?
    ) -> Bool {
        guard let currentStop,
              let currentAuthority,
              let currentThread,
              let currentFrame else {
            return false
        }
        return stop == currentStop
            && targetDigest == DebuggerInspectionTargetDigest(authority: currentAuthority)
            && thread == currentThread
            && frame == currentFrame
            && currentFrame.thread == currentThread
    }
}

/// Pure freshness/status value for WS-23 inspection packets.
enum DebuggerInspectionFreshness: Equatable, Sendable {
    case fresh(DebuggerInspectionCoordinate)
    case stale(reason: DebuggerInspectionStaleReason)
    case unavailable(reason: DebuggerInspectionUnavailableReason)
    case failed(reason: String)

    var isFresh: Bool {
        if case .fresh = self { return true }
        return false
    }
}

enum DebuggerInspectionStaleReason: String, Equatable, Sendable {
    case missingCurrentStop
    case missingTargetAuthority
    case targetAuthorityChanged
    case stopChanged
    case threadChanged
    case frameChanged
    case frameThreadMismatch
    case processRunning
    case processDetached
    case processExited
    case processCrashed
    case runtimeModuleEvidenceChanged
    case debugArtifactEvidenceChanged
}

enum DebuggerInspectionUnavailableReason: String, Equatable, Sendable {
    case noLiveSession
    case noSelectedThread
    case noSelectedFrame
    case noSourceEvidence
    case ambiguousSourceEvidence
    case unreadableMemory
    case unsupportedCapability
}

/// Headless freshness policy shared by source, variable, watch, memory, and register presentation.
enum DebuggerInspectionFreshnessPolicy {
    static func evaluate(
        cached coordinate: DebuggerInspectionCoordinate,
        currentStop: DebuggerStopCoordinate?,
        currentAuthority: DebuggerSessionTargetAuthority?,
        currentThread: DebuggerThreadIdentity?,
        currentFrame: DebuggerFrameIdentity?,
        processState: DebuggerProcessState,
        runtimeModuleEvidenceChanged: Bool = false,
        debugArtifactEvidenceChanged: Bool = false
    ) -> DebuggerInspectionFreshness {
        switch processState {
        case .running, .launching, .batchStopped:
            return .stale(reason: .processRunning)
        case .detaching:
            return .stale(reason: .processDetached)
        case .exited:
            return .stale(reason: .processExited)
        case .unavailable(let reason):
            return .failed(reason: reason)
        case .notAttached:
            return .unavailable(reason: .noLiveSession)
        case .paused:
            break
        }

        guard let currentStop else {
            return .stale(reason: .missingCurrentStop)
        }
        guard let currentAuthority else {
            return .stale(reason: .missingTargetAuthority)
        }
        guard let currentThread else {
            return .unavailable(reason: .noSelectedThread)
        }
        guard let currentFrame else {
            return .unavailable(reason: .noSelectedFrame)
        }
        guard currentFrame.thread == currentThread else {
            return .stale(reason: .frameThreadMismatch)
        }

        if coordinate.stop != currentStop {
            return .stale(reason: .stopChanged)
        }
        if coordinate.targetDigest != DebuggerInspectionTargetDigest(authority: currentAuthority) {
            return .stale(reason: .targetAuthorityChanged)
        }
        if coordinate.thread != currentThread {
            return .stale(reason: .threadChanged)
        }
        if coordinate.frame != currentFrame {
            return .stale(reason: .frameChanged)
        }
        if runtimeModuleEvidenceChanged {
            return .stale(reason: .runtimeModuleEvidenceChanged)
        }
        if debugArtifactEvidenceChanged {
            return .stale(reason: .debugArtifactEvidenceChanged)
        }
        return .fresh(coordinate)
    }
}

private extension Data {
    mutating func appendLengthFramed(_ value: String) {
        let bytes = Data(value.utf8)
        var length = UInt64(bytes.count).bigEndian
        Swift.withUnsafeBytes(of: &length) { append(contentsOf: $0) }
        append(bytes)
    }

    var sha256LowercaseHex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
