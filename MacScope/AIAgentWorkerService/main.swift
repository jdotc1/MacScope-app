import Foundation

// Runtime-only entry point for the embedded AI-worker XPC service. Unit-testable protocol,
// codec, principal, and deterministic handler code live in their separately listed target files.
final class Phase2AIWorkerListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let makePrincipal: () -> Phase2AIWorkerPrincipal

    init(makePrincipal: @escaping () -> Phase2AIWorkerPrincipal = { Phase2AIWorkerPrincipal() }) {
        self.makePrincipal = makePrincipal
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        let workerInterface = NSXPCInterface(with: Phase2AIWorkerXPCProtocol.self)
        let sinkInterface = NSXPCInterface(with: Phase2AIWorkerEventSinkXPCProtocol.self)
        workerInterface.setInterface(
            sinkInterface,
            for: #selector(Phase2AIWorkerXPCProtocol.run(requestData:requestID:eventSink:)),
            argumentIndex: 2,
            ofReply: false
        )

        newConnection.setCodeSigningRequirement(Phase2AIWorkerPeerRequirement.app)
        let principal = makePrincipal()
        newConnection.exportedInterface = workerInterface
        newConnection.exportedObject = principal
        newConnection.interruptionHandler = { [weak principal] in
            principal?.cancelAllForConnectionInvalidation()
        }
        newConnection.invalidationHandler = { [weak principal] in
            principal?.cancelAllForConnectionInvalidation()
        }
        newConnection.resume()
        return true
    }
}

let delegate = Phase2AIWorkerListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
