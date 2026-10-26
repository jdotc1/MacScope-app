import Foundation
@testable import MacScope

// MARK: - Analysis performance benchmark seam
//
// A minimal, OFF-by-default harness that times the four coarse phases of the analysis
// pipeline — load, decode, full analysis, and decompilation — on an in-scope binary,
// and records peak resident memory when it is cheaply available (mach `task_info`).
//
// This is a SEAM, not a suite: one entry point that returns a small struct of timings.
// The intent is that a CoreTests `measure {}` block or an env-gated test drives it on a
// small system binary; the normal test run stays fast because nothing here runs unless
// a test explicitly calls it.
//
// Architecture scope: ARM64 and x86_64 ONLY (whatever `AnalysisEngine` selects for the
// loaded binary). No PowerPC / Hexagon / i386 cases exist here.

/// One benchmark run's coarse phase timings (seconds) plus a few size signals and the
/// optional peak-memory reading. All timings are wall-clock from a monotonic clock.
struct AnalysisBenchmarkResult: Equatable {
    /// Seconds to read the file bytes off disk into memory.
    var loadSeconds: Double
    /// Seconds for the full `AnalysisEngine.analyze` (load + decode + every analysis pass).
    /// This is the headline end-to-end number; the finer phases below are derived
    /// sub-measurements of the same work re-run in isolation where that is possible.
    var analyzeSeconds: Double
    /// Seconds to decompile (lift + structure + print) the first procedure, the most
    /// expensive single decompile step, as a representative decompilation cost.
    var decompileFirstProcedureSeconds: Double

    /// Number of decoded instructions (a proxy for decode work done).
    var instructionCount: Int
    /// Number of recovered procedures.
    var procedureCount: Int

    /// Peak resident memory in bytes at the end of the run, or `nil` when the host did
    /// not report it. Best-effort and cheap (a single `task_info` call); not a precise
    /// allocation total.
    var peakResidentBytes: UInt64?
}

/// The benchmark harness. Pure aside from disk reads and the analysis pipeline it
/// drives; constructing it does nothing, so it has zero cost until `run` is called.
struct AnalysisBenchmark {
    /// Environment variable that gates the slow, full-binary benchmark in CoreTests.
    /// The benchmark test should `XCTSkip` unless this is set, so a normal `xcodebuild
    /// test` run never pays the cost.
    static let enableEnvironmentKey = "MACSCOPE_RUN_BENCHMARK"

    /// `true` when the gating env var is set to a truthy value (`1`/`true`/`yes`).
    static var isEnabledByEnvironment: Bool {
        guard let raw = ProcessInfo.processInfo.environment[enableEnvironmentKey] else { return false }
        switch raw.lowercased() {
        case "1", "true", "yes", "on": return true
        default: return false
        }
    }

    init() {}

    /// Runs the benchmark against the binary at `url`, returning coarse phase timings.
    /// Throws whatever the loader/engine throws (e.g. an unreadable file).
    ///
    /// Runs on the main actor because `AnalysisEngine.analyze` is `@MainActor`.
    @MainActor
    func run(url: URL) throws -> AnalysisBenchmarkResult {
        // 1) Isolated load timing: just read the bytes.
        let loadStart = Self.now()
        _ = try Data(contentsOf: url)
        let loadSeconds = Self.now() - loadStart

        // 2) Full analysis end-to-end (this internally re-reads + decodes + analyzes).
        let analyzeStart = Self.now()
        let snapshot = try AnalysisEngine().analyze(url: url)
        let analyzeSeconds = Self.now() - analyzeStart

        // 3) Decompile the first procedure as a representative decompilation cost.
        var decompileSeconds = 0.0
        if let firstFunction = snapshot.functions.sorted(by: { $0.startAddress < $1.startAddress }).first,
           let target = snapshot.pseudocodeTarget(selectedAddress: firstFunction.startAddress) {
            let resolvedJumpTables = snapshot.resolvedJumpTables(in: snapshot.primarySlot)
            let decompileStart = Self.now()
            _ = PseudocodePrinter().print(
                functionName: target.function.name,
                startAddress: target.function.startAddress,
                jumpTables: resolvedJumpTables,
                objcSelectors: snapshot.objcSelectors,
                instructions: target.instructions
            )
            decompileSeconds = Self.now() - decompileStart
        }

        return AnalysisBenchmarkResult(
            loadSeconds: loadSeconds,
            analyzeSeconds: analyzeSeconds,
            decompileFirstProcedureSeconds: decompileSeconds,
            instructionCount: snapshot.instructions.count,
            procedureCount: snapshot.functions.count,
            peakResidentBytes: Self.peakResidentBytes()
        )
    }

    /// A monotonic wall-clock reading in seconds. Uses `DispatchTime` (mach absolute
    /// time) so it is unaffected by wall-clock/NTP adjustments.
    private static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    /// Best-effort current resident memory in bytes via mach `task_info`, or `nil` when
    /// the call fails. Cheap: one syscall, no sampling loop.
    private static func peakResidentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kerr = withUnsafeMutablePointer(to: &info) { infoPointer -> kern_return_t in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return nil }
        // `resident_size_max` is the high-water mark for this task's resident set.
        return UInt64(info.resident_size_max)
    }
}
