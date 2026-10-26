import OSLog

/// Fixed operation names only: no paths, symbols, bytes, pseudocode or user strings enter logs.
/// Diagnostic intervals never participate in acceptance, cache identity or persisted state.
enum MacScopePerformance {
    private static let signposter = OSSignposter(
        subsystem: "org.macscope.MacScope", category: "Performance"
    )

    static func begin(_ name: StaticString) -> OSSignpostIntervalState? {
        guard signposter.isEnabled else { return nil }
        return signposter.beginInterval(name, id: signposter.makeSignpostID())
    }

    static func end(_ name: StaticString, _ interval: OSSignpostIntervalState?) {
        guard let interval else { return }
        signposter.endInterval(name, interval)
    }

    static func measure<Value>(
        _ name: StaticString, _ operation: () throws -> Value
    ) rethrows -> Value {
        let interval = begin(name)
        defer { end(name, interval) }
        return try operation()
    }
}
