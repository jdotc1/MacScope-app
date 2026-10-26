import Foundation
#if TESTING_NATIVE_DECOMPILER_SERVICE_COMPOSITION
@testable import MacScope
#endif

/// Accepts XPC connections and exports one principal per connection while sharing the injected
/// process-wide host/scheduler/runtime boundary.
///
/// The final target composition creates this delegate only after resolving and verifying the
/// bundle-local native package and constructing the accepted bridge/scheduler adapters. Keeping
/// top-level listener startup out of this file prevents an unavailable placeholder from becoming
/// the production service composition.
final class NativeDecompilerServiceListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let host: NativeDecompilerServiceHost

    init(host: NativeDecompilerServiceHost) {
        self.host = host
        super.init()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        _ = listener
        #if MACSCOPE_NATIVE_DECOMPILER_LIVE_XPC_TESTING
        let interface = NSXPCInterface(with: NativeDecompilerLiveXPCTestProtocol.self)
        #else
        let interface = NSXPCInterface(with: NativeDecompilerXPCProtocol.self)
        #endif
        let principal = NativeDecompilerXPCPrincipal(host: host)
        newConnection.invalidationHandler = { [weak principal] in
            principal?.invalidateConnection()
        }
        NativeDecompilerXPCListenerAdmission.accept(
            installRequirement: { requirement in
                newConnection.setCodeSigningRequirement(requirement)
            },
            exportInterface: {
                newConnection.exportedInterface = interface
            },
            exportObject: {
                newConnection.exportedObject = principal
            },
            resume: {
                newConnection.resume()
            }
        )
        return true
    }
}
