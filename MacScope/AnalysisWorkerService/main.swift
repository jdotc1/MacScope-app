import Foundation
import Darwin

// Explicit child mode exits before any service/controller/engine construction.
// With no child-mode argument, the existing listener path below is unchanged.
if let code = PosixOwnedChildMode.runIfRequested(arguments: CommandLine.arguments,
    environment: ProcessInfo.processInfo.environment, allowedChannels: ["pattern", "analysis", "dyld", "rea"]) {
    Darwin._exit(code)
}

// MARK: - Bundled analysis-worker XPC service runtime entry point
//
// This is the runtime-only tail of the analysis worker. The unit-testable principal and service
// handler live under Services/XPC; this file compiles only in AnalysisWorkerXPCService and must be
// named main.swift because the listener bring-up below uses top-level statements.

private func makeREAService() -> REAWorkerService {
    guard let url = Bundle.main.url(forResource: "MacScopeREAKernel", withExtension: "js") else {
        return .unavailable()
    }
    return REAWorkerService(host: REAJavaScriptHost(resourceURL: url,
        expectedSHA256: REAEmbeddedIdentity.resourceSHA256,
        implementationIdentity: REAEmbeddedIdentity.implementationIdentity))
}

// One nonce and control object per executable incarnation, shared by every principal.
private let workerProcessControl = AnalysisWorkerProcessControl()

/// Accepts inbound XPC connections and exports a fresh production principal per connection.
final class AnalysisWorkerServiceListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let makePrincipal: () -> AnalysisWorkerXPCPrincipal

    init(
        makePrincipal: @escaping () -> AnalysisWorkerXPCPrincipal = {
            AnalysisWorkerXPCPrincipal(
                service: AnalysisWorkerService(
                    engine: AnalysisEngine(
                        parserCrossCheck: NativeParserEngines(),
                        parserCrossCheckCache: NativeParserEngines.processVerdicts,
                        binaryEnrichment: NativeParserEngines.enrichGoFunctions
                    ),
                    codec: PayloadWireCodec()
                ),
                dyldCacheService: DyldCacheAnalysisWorkerService(
                    provider: MachOKitDyldCacheAnalysisProvider(),
                    codec: DyldCacheAnalysisWireCodec()
                ),
                reaService: makeREAService(),
                // Native linkage is ready, but activation requires a host deadline
                // and confirmed same-process return/termination supervision.
                patternService: .unavailable(),
                processControl: workerProcessControl
            )
        }
    ) {
        self.makePrincipal = makePrincipal
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        // Mutual peer authentication: only the signed MacScope app may drive this
        // worker. The requirement is installed before the exported interface or
        // principal becomes reachable and before the connection is resumed.
        AnalysisWorkerXPCListenerAdmission.accept(
            installRequirement: { requirement in
                newConnection.setCodeSigningRequirement(requirement)
            },
            exportInterface: {
                let interface = NSXPCInterface(with: AnalysisWorkerXPCProtocol.self)
                newConnection.exportedInterface = interface
            },
            exportObject: {
                newConnection.exportedObject = makePrincipal()
            },
            resume: {
                newConnection.resume()
            }
        )
        return true
    }
}

// `NSXPCListener.service()` binds this executable to its containing `.xpc` bundle. `resume()`
// then runs the service process for the listener's lifetime.
let delegate = AnalysisWorkerServiceListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
