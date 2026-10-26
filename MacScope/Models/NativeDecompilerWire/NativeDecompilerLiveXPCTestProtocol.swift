#if MACSCOPE_NATIVE_DECOMPILER_LIVE_XPC_TESTING
import Foundation

/// Deterministic barriers available only to the signed live-XPC qualification build.
@objc enum NativeDecompilerLiveXPCTestHoldMode: Int {
    case normal = 0
    case manual = 1
    case cooperativeCancellation = 2
    case unresponsive = 3
}

/// Scheduler/reply barriers exposed only by the signed live-XPC qualification build.
@objc enum NativeDecompilerLiveXPCTestEvent: Int {
    case submittedQueued = 0
    case replyAttempted = 1
}

/// Capability receipt for the sole live-test session in one service process.
///
/// The receipt intentionally carries no caller path, signing material, package identity, request
/// content, or result data. Mutual XPC peer-signing authenticates the connection; all live-control
/// methods additionally require this exact process-instance tuple.
@objc(MSNativeDecompilerLiveXPCTestReceipt)
@objcMembers
final class NativeDecompilerLiveXPCTestReceipt: NSObject, NSSecureCoding, @unchecked Sendable {
    static var supportsSecureCoding: Bool { true }

    let sessionID: NSUUID
    let processInstanceID: NSUUID
    let processID: Int32

    init(sessionID: NSUUID, processInstanceID: NSUUID, processID: Int32) {
        self.sessionID = sessionID
        self.processInstanceID = processInstanceID
        self.processID = processID
        super.init()
    }

    required convenience init?(coder: NSCoder) {
        guard let sessionID = coder.decodeObject(
            of: NSUUID.self,
            forKey: "sessionID"
        ),
            let processInstanceID = coder.decodeObject(
                of: NSUUID.self,
                forKey: "processInstanceID"
            )
        else {
            return nil
        }
        let decodedProcessID = coder.decodeInt64(forKey: "processID")
        guard decodedProcessID > 0, decodedProcessID <= Int64(Int32.max) else {
            return nil
        }
        self.init(
            sessionID: sessionID,
            processInstanceID: processInstanceID,
            processID: Int32(decodedProcessID)
        )
    }

    func encode(with coder: NSCoder) {
        coder.encode(sessionID, forKey: "sessionID")
        coder.encode(processInstanceID, forKey: "processInstanceID")
        coder.encode(Int64(processID), forKey: "processID")
    }
}

/// Compile-time-only qualification surface. The production protocol is inherited, never widened.
@objc protocol NativeDecompilerLiveXPCTestProtocol: NativeDecompilerXPCProtocol {
    func openLiveTestSession(
        sessionID: NSUUID,
        withReply reply: @escaping (NativeDecompilerLiveXPCTestReceipt?) -> Void
    )

    func configureLiveTestRequest(
        receipt: NativeDecompilerLiveXPCTestReceipt,
        requestID: NSUUID,
        holdMode: Int,
        withReply reply: @escaping (Bool) -> Void
    )

    func waitUntilLiveTestRequestEntered(
        receipt: NativeDecompilerLiveXPCTestReceipt,
        requestID: NSUUID,
        withReply reply: @escaping (NativeDecompilerLiveXPCTestReceipt?) -> Void
    )

    func waitUntilLiveTestRequestEvent(
        receipt: NativeDecompilerLiveXPCTestReceipt,
        requestID: NSUUID,
        event: Int,
        withReply reply: @escaping (NativeDecompilerLiveXPCTestReceipt?) -> Void
    )

    func releaseLiveTestRequest(
        receipt: NativeDecompilerLiveXPCTestReceipt,
        requestID: NSUUID,
        withReply reply: @escaping (Bool) -> Void
    )

    func pingLiveTestSession(
        receipt: NativeDecompilerLiveXPCTestReceipt,
        withReply reply: @escaping (NativeDecompilerLiveXPCTestReceipt?) -> Void
    )

    func selfSIGKILLLiveTestService(receipt: NativeDecompilerLiveXPCTestReceipt)
}
#endif
