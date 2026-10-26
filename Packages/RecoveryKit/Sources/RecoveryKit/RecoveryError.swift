import Foundation

public enum RecoveryError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalid(String)
    case unsupported(String)
    case budget(String)
    case stale(String)

    public var description: String {
        switch self {
        case .invalid(let text): return "invalid: \(text)"
        case .unsupported(let text): return "unsupported: \(text)"
        case .budget(let text): return "budget: \(text)"
        case .stale(let text): return "stale: \(text)"
        }
    }
}

public struct RecoveryLimits: Sendable {
    public var bytes: Int
    public var records: Int
    public var depth: Int
    public init(bytes: Int = 32 * 1024 * 1024, records: Int = 100_000, depth: Int = 128) {
        self.bytes = bytes
        self.records = records
        self.depth = depth
    }
    public func validate() throws {
        guard bytes > 0, records > 0, depth > 0 else { throw RecoveryError.invalid("nonpositive resource limit") }
    }
}
