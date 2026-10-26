import Foundation

struct NativeDecompilerAuthoredProjection: Equatable, Sendable {
    let authoredInputs: NativeDecompilerWireAuthoredInputs
    let canonicalIdentitySHA256: String
    let canonicalByteCount: Int
}

enum NativeDecompilerSemanticInputState: Equatable, Sendable {
    case valid(NativeDecompilerAuthoredProjection)
    case invalid(NativeAuthoredProjectionDiagnostic)

    var identity: NativeDecompilerSemanticInputIdentity {
        switch self {
        case let .valid(projection):
            .valid(sha256: projection.canonicalIdentitySHA256)
        case let .invalid(diagnostic):
            .invalid(diagnostic.identity)
        }
    }
}

enum NativeDecompilerSemanticInputIdentity: Hashable, Sendable {
    case valid(sha256: String)
    case invalid(NativeAuthoredProjectionDiagnostic.Identity)
}

private extension NativeAuthoredProjectionDiagnostic {
    var identity: Identity {
        switch self {
        case let .unsupported(id), let .invalid(id), let .bounds(id):
            id
        }
    }
}
