import Foundation

/// Frozen mutual code-signing requirements for the production native-decompiler XPC boundary.
///
/// These expressions deliberately match the app's existing AI-worker and Shell-broker admission
/// policy: exact bundle identifier, exact approved Apple Development leaf certificate, and the
/// Apple development intermediate. Transport admission remains separate from the frozen wire
/// protocol and carries no path or signing data over XPC.
enum NativeDecompilerXPCPeerRequirement {
    private static let certificate =
        "anchor apple generic and certificate leaf[subject.CN] = "
        + "\"Apple Development: MacScope Developer (CERT000000)\" and "
        + "certificate leaf[subject.OU] = \"TEAM000000\" and "
        + "certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */"

    static let app = "identifier \"org.macscope.app\" and \(certificate)"
    static let service =
        "identifier \"org.macscope.app.NativeDecompiler\" and \(certificate)"
}

/// Idempotent client-side admission gate. The requirement application completes while the gate is
/// locked, so a concurrent resume cannot overtake it. Calling resume before installation fails
/// closed, and repeated installation or resume requests are no-ops.
final class NativeDecompilerXPCClientAdmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var requirementInstalled = false
    private var resumed = false

    func installRequirement(_ apply: (String) -> Void) {
        lock.withLock {
            guard !requirementInstalled, !resumed else { return }
            apply(NativeDecompilerXPCPeerRequirement.service)
            requirementInstalled = true
        }
    }

    func resume(_ apply: () -> Void) {
        lock.withLock {
            guard requirementInstalled, !resumed else { return }
            resumed = true
            apply()
        }
    }
}

/// Deterministic listener-side admission order. The app requirement is installed before either the
/// exported interface or principal becomes reachable and before the connection is resumed.
enum NativeDecompilerXPCListenerAdmission {
    static func accept(
        installRequirement: (String) -> Void,
        exportInterface: () -> Void,
        exportObject: () -> Void,
        resume: () -> Void
    ) {
        installRequirement(NativeDecompilerXPCPeerRequirement.app)
        exportInterface()
        exportObject()
        resume()
    }
}
