import Foundation

/// Scheduling authority only: never changes analysis semantics or pins a P/E core.
struct AnalysisResourceBudget: Codable, Equatable, Sendable {
    static let maximumSupportedParallelism = 64
    let maximumParallelism: Int

    init(maximumParallelism: Int) {
        precondition((1...Self.maximumSupportedParallelism).contains(maximumParallelism))
        self.maximumParallelism = maximumParallelism
    }

    static var interactive: Self {
        .init(maximumParallelism: AnalysisHostResourcePolicy.interactiveParallelism(
            processorCount: ProcessInfo.processInfo.activeProcessorCount,
            thermalState: ProcessInfo.processInfo.thermalState,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        ))
    }

    func clamped(to hostCeiling: Self) -> Self {
        .init(maximumParallelism: min(maximumParallelism, hostCeiling.maximumParallelism))
    }

    private enum CodingKeys: String, CodingKey { case maximumParallelism }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(Int.self, forKey: .maximumParallelism)
        guard (1...Self.maximumSupportedParallelism).contains(value) else {
            throw DecodingError.dataCorruptedError(forKey: .maximumParallelism, in: container,
                debugDescription: "Analysis parallelism must be between 1 and 64")
        }
        maximumParallelism = value
    }
}

/// Only synchronous scopes use this context. No context is allowed to span an await.
/// GCD iterations explicitly establish their own child scope; nested parallel maps run serially.
enum AnalysisParallelism {
    private static let key = "com.macscope.analysis.parallelism"

    static var current: AnalysisResourceBudget {
        guard let value = Thread.current.threadDictionary[key] as? Int else { return .interactive }
        return .init(maximumParallelism: value)
    }

    static func withBudget<T>(
        _ budget: AnalysisResourceBudget,
        _ operation: () throws -> T
    ) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[key]
        dictionary[key] = budget.maximumParallelism
        defer {
            if let previous { dictionary[key] = previous }
            else { dictionary.removeObject(forKey: key) }
        }
        return try operation()
    }
}

enum AnalysisHostResourcePolicy {
    /// 10 logical cores on the common M1 Max => eight interactive execution slots.
    /// Generic fallback remains bounded even if processorCount is malformed or enormous.
    static func interactiveParallelism(
        processorCount: Int,
        thermalState: ProcessInfo.ThermalState,
        lowPowerMode: Bool
    ) -> Int {
        let cores = min(64, max(1, processorCount))
        let normal = min(8, max(1, cores - 2))
        switch thermalState {
        case .critical: return 1
        case .serious: return min(2, normal)
        case .fair: return lowPowerMode ? max(1, normal / 2) : min(6, normal)
        case .nominal: return lowPowerMode ? max(1, normal / 2) : normal
        @unknown default: return 1
        }
    }

    /// Six aggregate CPU slots on 10 cores (2 outer x 3 inner). This leaves scheduling room
    /// for UI, native workers and inference. Defaults are provisional until Mac qualification.
    static func reconstructionParallelism(processorCount: Int) -> (outer: Int, inner: Int) {
        let cores = min(64, max(1, processorCount))
        let available = max(1, cores - 4)
        let outer = min(2, available)
        return (outer, min(3, max(1, available / outer)))
    }
}
