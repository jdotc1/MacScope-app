public struct OSSignpostIntervalState: Sendable { public init() {} }
public struct OSSignposter: Sendable {
    public init(subsystem: String, category: String) {}
    public var isEnabled: Bool { false }
    public func makeSignpostID() -> UInt64 { fatalError("Disabled signposter reached") }
    public func beginInterval(_ name: StaticString, id: UInt64) -> OSSignpostIntervalState { fatalError("Disabled signposter reached") }
    public func endInterval(_ name: StaticString, _ state: OSSignpostIntervalState) { fatalError("Disabled signposter reached") }
}
