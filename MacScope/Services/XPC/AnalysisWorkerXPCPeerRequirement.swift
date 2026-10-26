import Foundation

/// Frozen mutual code-signing requirements for the bundled analysis-worker XPC boundary.
///
/// These expressions deliberately match the app's existing AI-worker, Shell-broker, and
/// native-decompiler admission policy: exact bundle identifier, exact approved Apple Development
/// leaf certificate, and the Apple development intermediate. The analysis worker is the one
/// boundary explicitly designed around a compromised peer — it parses hostile binaries and its
/// replies become app state — so it must not remain the only worker boundary without mutual
/// peer authentication.
enum AnalysisWorkerXPCPeerRequirement {
    private static let certificate =
        "anchor apple generic and certificate leaf[subject.CN] = "
        + "\"Apple Development: MacScope Developer (CERT000000)\" and "
        + "certificate leaf[subject.OU] = \"TEAM000000\" and "
        + "certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */"

    static let app = "identifier \"org.macscope.app\" and \(certificate)"
    static let worker =
        "identifier \"org.macscope.app.AnalysisWorker\" and \(certificate)"
}

/// Deterministic listener-side admission order for the analysis-worker service. The app
/// requirement is installed before either the exported interface or principal becomes reachable
/// and before the connection is resumed, mirroring `NativeDecompilerXPCListenerAdmission`.
enum AnalysisWorkerXPCListenerAdmission {
    static func accept(
        installRequirement: (String) -> Void,
        exportInterface: () -> Void,
        exportObject: () -> Void,
        resume: () -> Void
    ) {
        installRequirement(AnalysisWorkerXPCPeerRequirement.app)
        exportInterface()
        exportObject()
        resume()
    }
}
