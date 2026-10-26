import Foundation

/// Static evidence only. `definite` describes the recorded link, not the absence of other IPC.
struct AttackSurfaceReport: Codable, Sendable {
    enum Privilege: String, Codable, Sendable { case root, user, appScoped = "app-scoped", unknown }
    enum Confidence: String, Codable, Sendable { case definite, needsReview = "needs-review" }
    enum ListenerKind: String, Codable, Sendable { case nsxpc, libxpc, unknown }

    struct Source: Codable, Sendable {
        var path: String
        var section: String?
        var fields: [String: String]
    }
    struct Method: Codable, Sendable {
        var selector: String
        var typeEncoding: String?
        var parameterTypes: [String]
        var takesReplyBlock: Bool
    }
    struct Interface: Codable, Sendable {
        var protocolName: String
        var methods: [Method]
        var allowListSelectors: [String]
        var confidence: Confidence
        var reason: String?
    }
    struct Listener: Codable, Sendable {
        var kind: ListenerKind
        var setupAPI: String
        var serviceName: String?
        var setupAddress: UInt64?
        var delegateClass: String?
        var acceptanceAddress: UInt64?
        var peerHandlerAddress: UInt64?
        var interfaces: [Interface]
        var messageKeys: [String]
        var confidence: Confidence
        var reason: String?
    }
    struct Service: Codable, Sendable {
        var machServiceName: String
        var declaringSource: Source
        var binaryPath: String?
        var listener: Listener?
        var privilege: Privilege
        var declaredClientRequirements: [String]
        var confidence: Confidence
        var reason: String?
    }
    struct Unmatched: Codable, Sendable {
        var name: String?
        var binaryPath: String?
        var reason: String
        var listener: Listener?
    }
    var sources: [Source]
    var services: [Service]
    var unmatched: [Unmatched]
}
