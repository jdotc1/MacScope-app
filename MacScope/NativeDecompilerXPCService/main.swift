import Foundation
import Darwin

// Explicit child mode never prepares a native backend or enters the XPC listener.
if let code = PosixOwnedChildMode.runIfRequested(arguments: CommandLine.arguments,
    environment: ProcessInfo.processInfo.environment, allowedChannels: ["decompiler"]) {
    Darwin._exit(code)
}

guard let composition = NativeDecompilerServiceComposition.production() else {
    exit(EXIT_FAILURE)
}
composition.runService()
