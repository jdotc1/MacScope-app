import Foundation

public struct WorkToken: Hashable, Codable, Sendable {
    public let image: String
    public let task: String
    public let generation: UInt64
}
public struct WorkState: Codable, Sendable {
    public let token: WorkToken
    public var status: String
    public var artifact: String?
    public var reason: String?
}

/// Generation-scoped admission prevents stale sidecar work from changing a new
/// image's findings. This actor coordinates results; it does not run target code.
public actor RecoveryCoordinator {
    private var tasks: [String: WorkState] = [:]
    private var nextGeneration: UInt64 = 0
    public init() {}
    private func key(_ image: String, _ task: String) -> String { image + ":" + task }

    public func begin(image: String, task: String) throws -> WorkToken {
        try ImageKey.validate(image)
        guard !task.isEmpty, task.utf8.count <= 256 else { throw RecoveryError.invalid("task identity") }
        let (generation, overflow) = nextGeneration.addingReportingOverflow(1)
        guard !overflow else { throw RecoveryError.budget("work generation overflow") }
        nextGeneration = generation
        let token = WorkToken(image: image, task: task, generation: generation)
        tasks[key(image, task)] = WorkState(token: token, status: "running", artifact: nil, reason: nil)
        return token
    }
    @discardableResult public func complete(_ token: WorkToken, artifact: String) -> Bool {
        let id = key(token.image, token.task)
        guard var state = tasks[id], state.token == token, state.status == "running", !artifact.isEmpty else { return false }
        state.status = "complete"; state.artifact = artifact; tasks[id] = state
        return true
    }
    @discardableResult public func block(_ token: WorkToken, reason: String) -> Bool {
        let id = key(token.image, token.task)
        guard var state = tasks[id], state.token == token, state.status == "running", !reason.isEmpty else { return false }
        state.status = "blocked"; state.reason = reason; tasks[id] = state
        return true
    }
    public func invalidate(image: String, reason: String) {
        for key in tasks.keys.sorted() where tasks[key]?.token.image == image {
            tasks[key]?.status = "invalidated"; tasks[key]?.reason = reason
        }
    }
    public func snapshot() -> [WorkState] { tasks.values.sorted { $0.token.generation < $1.token.generation } }
}
