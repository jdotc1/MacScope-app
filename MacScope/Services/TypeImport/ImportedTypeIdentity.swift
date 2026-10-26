import Foundation

/// A display name is never an imported declaration's identity. The archive
/// digest binds the exact retained bytes; the local key identifies a graph node.
struct ImportedTypeIdentity: Codable, Hashable, Sendable {
    let archiveSHA256: String
    let declarationID: String
}
