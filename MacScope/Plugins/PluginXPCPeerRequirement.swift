import Foundation

/// Frozen mutual code-signing requirements for the plugin XPC service boundary.
///
/// These expressions deliberately match the app's existing AI-worker, Shell-broker, and
/// native-decompiler admission policy: exact bundle identifier, exact approved Apple Development
/// leaf certificate, and the Apple development intermediate. The listener-side requirement is a
/// precondition for embedding the service; the host-side requirement is installed now so the
/// live adapter is already gated when reachability lands.
enum PluginXPCPeerRequirement {
    private static let certificate =
        "anchor apple generic and certificate leaf[subject.CN] = "
        + "\"Apple Development: MacScope Developer (CERT000000)\" and "
        + "certificate leaf[subject.OU] = \"TEAM000000\" and "
        + "certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */"

    static let app = "identifier \"org.macscope.app\" and \(certificate)"
    static let service =
        "identifier \"org.macscope.app.PluginXPCService\" and \(certificate)"
}

/// Deterministic listener-side admission order for the plugin service. The app requirement is
/// installed before either the exported interface or principal becomes reachable and before the
/// connection is resumed, mirroring `NativeDecompilerXPCListenerAdmission`.
enum PluginXPCListenerAdmission {
    static func accept(
        installRequirement: (String) -> Void,
        exportInterface: () -> Void,
        exportObject: () -> Void,
        resume: () -> Void
    ) {
        installRequirement(PluginXPCPeerRequirement.app)
        exportInterface()
        exportObject()
        resume()
    }
}
