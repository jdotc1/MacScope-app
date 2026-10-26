#if TESTING_REA_WORKER_HOST
@testable import MacScope
#endif
import CryptoKit
import Foundation
import JavaScriptCore

/// Only the exact verified resource is evaluated. All JSContext/JSValue ownership lives on
/// one process-wide serial queue; pending promises retain their context until actual settlement.
final class REAJavaScriptHost: @unchecked Sendable {
    let implementationIdentity: String
    private let resourceURL: URL
    private let resourceSHA256: String
    private static let queue = DispatchQueue(label: "org.macscope.app.REA.javascript")
    private final class Sessions: @unchecked Sendable {
        static let shared = Sessions()
        // Access exclusively on REAJavaScriptHost.queue.
        var values: [UUID: Session] = [:]
    }
    private final class Session: @unchecked Sendable {
        let context: JSContext
        var promise: JSValue?
        var settled = false
        init(_ context: JSContext) { self.context = context }
    }
    init(resourceURL: URL, expectedSHA256: String, implementationIdentity: String) {
        self.resourceURL = resourceURL; resourceSHA256 = expectedSHA256
        self.implementationIdentity = implementationIdentity
    }
    func execute(requestData: Data, requestID: UUID, control: REAWorkerExecutionControl,
                 completion: @escaping @Sendable (Result<Data, REAWorkerFailure>) -> Void) {
        Self.queue.async { [self] in
            do {
                try control.check()
                _ = try REAInspectionWireCodec.validateRequest(requestData, requestID: requestID)
                guard resourceURL.isFileURL,
                      resourceURL.standardizedFileURL.path == resourceURL.path,
                      resourceURL.resolvingSymlinksInPath().path == resourceURL.path else {
                    throw REAWorkerFailure("resourceRejected")
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: resourceURL.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let length = attributes[.size] as? NSNumber,
                      length.intValue > 0, length.intValue <= 16 * 1_024 * 1_024 else {
                    throw REAWorkerFailure("resourceRejected")
                }
                let bytes = try Data(contentsOf: resourceURL)
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                guard bytes.count <= 16 * 1_024 * 1_024, digest == resourceSHA256, let script = String(data: bytes, encoding: .utf8),
                      let request = String(data: requestData, encoding: .utf8),
                      let context = JSContext() else { throw REAWorkerFailure("resourceRejected") }
                let id = UUID(), session = Session(context)
                Self.Sessions.shared.values[id] = session
                // Native blocks are deliberately limited to cooperative budget checks and
                // terminal string delivery; no filesystem, process, network or generic bridge.
                let checkpoint: @convention(block) () -> Void = { [weak context] in
                    do { try control.check() }
                    catch { context?.exception = JSValue(newErrorFromMessage: "REA execution stopped", in: context) }
                }
                let sha256: @convention(block) (JSValue) -> String? = { [weak context] value in
                    guard value.isString, let text = value.toString(),
                          text.utf8.count <= 16 * 1_024 * 1_024 else {
                        context?.exception = JSValue(newErrorFromMessage: "Invalid SHA input", in: context)
                        return nil
                    }
                    // Reject unpaired UTF-16 before Swift's repairing string conversion can
                    // change commitment bytes. JS strings report exact code units via charCodeAt.
                    let count = value.forProperty("length")?.toInt32() ?? -1
                    guard count >= 0, count <= 16 * 1_024 * 1_024 else { return nil }
                    var index: Int32 = 0
                    while index < count {
                        let unit = value.invokeMethod("charCodeAt", withArguments: [index])?.toInt32() ?? -1
                        if (0xD800...0xDBFF).contains(unit) {
                            guard index + 1 < count,
                                  let low = value.invokeMethod("charCodeAt", withArguments: [index + 1])?.toInt32(),
                                  (0xDC00...0xDFFF).contains(low) else {
                                context?.exception = JSValue(newErrorFromMessage: "Invalid Unicode", in: context); return nil
                            }
                            index += 1
                        } else if (0xDC00...0xDFFF).contains(unit) {
                            context?.exception = JSValue(newErrorFromMessage: "Invalid Unicode", in: context); return nil
                        }
                        index += 1
                    }
                    do { try control.check() } catch {
                        context?.exception = JSValue(newErrorFromMessage: "REA execution stopped", in: context); return nil
                    }
                    return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
                }
                let sha256Base64: @convention(block) (JSValue) -> String? = { [weak context] value in
                    guard value.isString, let text = value.toString(),
                          text.utf8.count <= 16 * 1_024 * 1_024,
                          let bytes = Data(base64Encoded: text), bytes.base64EncodedString() == text else {
                        context?.exception = JSValue(newErrorFromMessage: "Invalid base64", in: context); return nil
                    }
                    do { try control.check() } catch {
                        context?.exception = JSValue(newErrorFromMessage: "REA execution stopped", in: context); return nil
                    }
                    return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                }
                context.setObject(sha256Base64, forKeyedSubscript: "__macscopeSHA256Base64" as NSString)
                context.setObject(sha256, forKeyedSubscript: "__macscopeSHA256" as NSString)
                context.setObject(checkpoint, forKeyedSubscript: "__macscopeCheckpoint" as NSString)
                func finish(_ result: Result<Data, REAWorkerFailure>) {
                    guard !session.settled else { return }; session.settled = true
                    Self.queue.async {
                        session.promise = nil
                        session.context.exceptionHandler = nil
                        session.context.setObject(nil, forKeyedSubscript: "__macscopeResolve" as NSString)
                        session.context.setObject(nil, forKeyedSubscript: "__macscopeReject" as NSString)
                        Self.Sessions.shared.values.removeValue(forKey: id)
                        completion(result)
                    }
                }
                let resolve: @convention(block) (JSValue) -> Void = { value in
                    do {
                        try control.check()
                        guard value.isString, let text = value.toString(),
                              text.utf8.count <= 8 * 1_024 * 1_024 else { throw REAWorkerFailure("outputLimitExceeded") }
                        let data = Data(text.utf8)

                        finish(.success(data))
                    } catch { finish(.failure((error as? REAWorkerFailure) ?? .init("invalidResponse"))) }
                }
                let reject: @convention(block) (JSValue) -> Void = { _ in
                    do { try control.check(); finish(.failure(.init("executionFailed"))) }
                    catch { finish(.failure((error as? REAWorkerFailure) ?? .init("executionFailed"))) }
                }
                context.setObject(resolve, forKeyedSubscript: "__macscopeResolve" as NSString)
                context.setObject(reject, forKeyedSubscript: "__macscopeReject" as NSString)
                context.exceptionHandler = { _, _ in finish(.failure(.init("executionFailed"))) }
                context.evaluateScript(script, withSourceURL: resourceURL)
                guard !session.settled else { return }
                guard let api = context.objectForKeyedSubscript("MacScopeREA"), !api.isUndefined,
                      let analyze = api.objectForKeyedSubscript("analyze"), analyze.isObject,
                      let promise = analyze.call(withArguments: [request]), promise.isObject else {
                    finish(.failure(.init("invalidResponse"))); return
                }
                session.promise = promise
                // Native Promise handlers run through JavaScriptCore's microtask queue. Keep
                // both promise and context alive; unresolved work never masquerades as stopped.
                promise.invokeMethod("then", withArguments: [resolve, reject])
            } catch { completion(.failure((error as? REAWorkerFailure) ?? .init("resourceRejected"))) }
        }
    }
}

extension REAWorkerService {
    convenience init(host: REAJavaScriptHost, duration: TimeInterval = 30) {
        self.init(executor: { data, requestID, control, completion in
            host.execute(requestData: data, requestID: requestID, control: control, completion: completion)
        }, implementationIdentity: host.implementationIdentity, duration: duration)
    }
}
