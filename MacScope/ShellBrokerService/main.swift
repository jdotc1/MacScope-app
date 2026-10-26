import Dispatch
import Foundation

final class Phase2ShellBrokerListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let durableRegistry: Phase2DurableShellBrokerRegistry
    private let makePrincipal: (Phase2DurableShellBrokerRegistry) -> Phase2ShellBrokerPrincipal

    init(
        durableRegistry: Phase2DurableShellBrokerRegistry = Phase2DurableShellBrokerRegistry(),
        makePrincipal: @escaping (Phase2DurableShellBrokerRegistry) -> Phase2ShellBrokerPrincipal = {
            Phase2ShellBrokerPrincipal(durableRegistry: $0)
        }
    ) {
        self.durableRegistry = durableRegistry
        self.makePrincipal = makePrincipal
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        _ = listener
        newConnection.setCodeSigningRequirement(Phase2ShellBrokerPeerRequirement.app)
        newConnection.exportedInterface = NSXPCInterface(with: Phase2ShellBrokerXPCProtocol.self)
        let principal = makePrincipal(durableRegistry)
        newConnection.exportedObject = principal
        newConnection.interruptionHandler = { [weak principal] in
            principal?.invalidate()
        }
        newConnection.invalidationHandler = { [weak principal] in
            principal?.invalidate()
        }
        newConnection.resume()
        return true
    }
}

let delegate = Phase2ShellBrokerListenerDelegate()
let listener: NSXPCListener
if CommandLine.arguments.contains("--launch-agent") {
    listener = NSXPCListener(
        machServiceName: Phase2ShellBrokerProtocolIdentity.persistentMachServiceName
    )
} else {
    listener = NSXPCListener.service()
}
listener.delegate = delegate
listener.resume()
dispatchMain()
