import Foundation

// MARK: - Bundled XPC service runtime entry point
//
// This file is the RUNTIME TAIL of the plugin XPC service. It is deliberately NOT
// part of the app target or the CoreTests target — it provides the `.xpc` bundle's
// `main` and an `NSXPCListenerDelegate`, both of which only make sense inside a
// running service process. It must be named `main.swift` because it contains
// top-level executable statements (the listener bring-up at the bottom).
// The unit-testable core (`PluginXPCServicePrincipal`,
// `PluginXPCServiceCommandHandling`, `PluginXPCMessageTranslator`) lives under
// `Plugins/` and is fully covered by tests without any of this.
//
// To ship the live service, add the `PluginXPCService` target stanza from
// `project.yml` to the app's embed/sign phases (see integrationRisks in the task
// report). This source compiles only inside that bundle target.

/// The `NSXPCListenerDelegate` that accepts inbound connections and exports a
/// freshly-configured `PluginXPCServicePrincipal` per connection. The principal is
/// the pure handler; this delegate is the thin runtime that binds it to a live
/// `NSXPCConnection`.
final class PluginXPCServiceListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let makeHandler: () -> PluginXPCServiceCommandHandling

    init(makeHandler: @escaping () -> PluginXPCServiceCommandHandling = { EchoPluginXPCServiceHandler() }) {
        self.makeHandler = makeHandler
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        // Mutual peer authentication: only the signed MacScope app may drive this
        // service. The requirement is installed before the exported interface or
        // principal becomes reachable and before the connection is resumed.
        PluginXPCListenerAdmission.accept(
            installRequirement: { requirement in
                newConnection.setCodeSigningRequirement(requirement)
            },
            exportInterface: {
                newConnection.exportedInterface = NSXPCInterface(with: PluginXPCServiceProtocol.self)
            },
            exportObject: {
                newConnection.exportedObject = PluginXPCServicePrincipal(handler: makeHandler())
            },
            resume: {
                newConnection.resume()
            }
        )
        return true
    }
}

// Service entry point: install the delegate and run the listener. `NSXPCListener
// .service()` blocks for the lifetime of the service process.
let delegate = PluginXPCServiceListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
