import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import MacScope

/// The same source compiles against the frozen baseline and the candidate. This is intentional:
/// benchmark-only application of component 05 makes an honest before/after comparison possible.
/// Ordinary CoreTests skip this experiment. Errors are failures; no timing is emitted for a
/// failed operation and no error is swallowed inside a measure block.
@MainActor
final class M1MaxPerformanceQualificationTests: XCTestCase {
    func testRecordControlledCorpus() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MACSCOPE_PERF_RUN"] == "1" else {
            throw XCTSkip("Explicit performance experiment; set MACSCOPE_PERF_RUN=1")
        }
        let manifestPath = try XCTUnwrap(environment["MACSCOPE_PERF_MANIFEST"])
        let outputPath = try XCTUnwrap(environment["MACSCOPE_PERF_OUTPUT"])
        let runID = try XCTUnwrap(environment["MACSCOPE_PERF_RUN_ID"])
        let manifest = try JSONDecoder().decode(MacScopePerformanceManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
        try manifest.validate()
        guard !FileManager.default.fileExists(atPath: outputPath) else {
            throw MacScopePerformanceFailure.outputAlreadyExists
        }
        guard FileManager.default.createFile(atPath: outputPath, contents: nil) else {
            throw MacScopePerformanceFailure.cannotCreateOutput
        }
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: outputPath))
        defer { try? output.close() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for input in manifest.inputs {
            try await Task.detached(priority: .utility) {
                try MacScopePerformanceScenario.verify(input)
            }.value
            // Each input starts with a new provider; warmups absorb its on-demand worker startup.
            let provider: (any AnalysisProviding)? = input.mode == "xpc"
                ? XPCAnalysisProvider(transport: NSXPCConnectionTransport(), codec: PayloadWireCodec())
                : nil
            for iteration in 0..<(manifest.warmupIterations + manifest.measuredIterations) {
                let warmup = iteration < manifest.warmupIterations
                let sample = try await Task.detached(priority: .userInitiated) {
                    try await MacScopePerformanceScenario.run(
                        input: input, provider: provider, runID: runID,
                        iteration: iteration, warmup: warmup
                    )
                }.value
                try output.write(contentsOf: encoder.encode(sample))
                try output.write(contentsOf: Data([0x0A]))
                try output.synchronize()
            }
            try await Task.detached(priority: .utility) {
                try MacScopePerformanceScenario.verify(input)
            }.value
        }
    }
}

private enum MacScopePerformanceFailure: Error {
    case invalidManifest
    case inputChanged
    case outputAlreadyExists
    case cannotCreateOutput
    case missingAnalysisFingerprint
    case payloadRoundTripChanged
}

private struct MacScopePerformanceManifest: Decodable {
    struct Input: Codable, Sendable {
        let id: String
        let path: String
        let sha256: String
        let sizeBytes: UInt64
        let mode: String
        let requestedSliceIndex: Int?
    }
    let schemaVersion: Int
    let warmupIterations: Int
    let measuredIterations: Int
    let inputs: [Input]

    func validate() throws {
        guard schemaVersion == 1, (1...5).contains(warmupIterations),
              (20...200).contains(measuredIterations), !inputs.isEmpty,
              inputs.count <= 20, Set(inputs.map(\.id)).count == inputs.count,
              inputs.allSatisfy({ !$0.id.isEmpty && $0.path.hasPrefix("/")
                  && ["inProcess", "xpc"].contains($0.mode)
                  && $0.sha256.utf8.count == 64
                  && $0.sha256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                  && ($0.requestedSliceIndex ?? 0) >= 0 }) else {
            throw MacScopePerformanceFailure.invalidManifest
        }
    }
}

private struct MacScopePerformanceSample: Encodable, Sendable {
    let schemaVersion = 1
    let runID: String
    let inputID: String
    let inputSHA256: String
    let mode: String
    let iteration: Int
    let warmup: Bool
    let analyzeMS: Double
    let listingPrepareMS: Double
    let wireEncodeMS: Double
    let wireDecodeMS: Double
    let totalMS: Double
    let cpuMS: Double
    let cpuScope = "testProcessOnly"
    let instructionCount: Int
    let procedureCount: Int
    let listingRowCount: Int
    let wireBytes: Int
    let footprintBytes: UInt64?
    let lifetimePeakFootprintBytes: UInt64?
    let thermalState: Int
    let lowPowerMode: Bool
    let facetSHA256: String
    let mainQueueProbeCount: Int
    let mainQueueDelayP95MS: Double?
    let mainQueueDelayMaxMS: Double?
}

private enum MacScopePerformanceScenario {
    static func verify(_ input: MacScopePerformanceManifest.Input) throws {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: input.path))
        defer { try? handle.close() }
        var hasher = SHA256()
        var count: UInt64 = 0
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            hasher.update(data: bytes)
            count += UInt64(bytes.count)
        }
        guard count == input.sizeBytes, hex(hasher.finalize()) == input.sha256 else {
            throw MacScopePerformanceFailure.inputChanged
        }
    }

    static func run(
        input: MacScopePerformanceManifest.Input, provider: (any AnalysisProviding)?,
        runID: String, iteration: Int, warmup: Bool
    ) async throws -> MacScopePerformanceSample {
        let probe = MacScopeMainQueueProbe()
        probe.start()
        defer { probe.stop() }
        let cpuStart = cpuMilliseconds()
        let start = now()
        let snapshot: WorkspaceSnapshot
        if let provider {
            snapshot = try await provider.openBinary(
                url: URL(fileURLWithPath: input.path), requestedSliceIndex: input.requestedSliceIndex,
                overrides: [:], cancellation: .never
            )
        } else {
            snapshot = try AnalysisEngine().analyze(
                url: URL(fileURLWithPath: input.path), requestedSliceIndex: input.requestedSliceIndex,
                overrides: [:], cancellation: .never
            )
        }
        let analyzed = now()
        let listing = DisassemblyListingBuilder.buildResolved(snapshot: snapshot)
        let listed = now()
        let codec = PayloadWireCodec()
        let wire = codec.encodeReply(.success(snapshot))
        let encoded = now()
        let restored = try codec.decodeReply(wire)
        let decoded = now()
        let footprint = footprint()
        let cpuEnd = cpuMilliseconds()
        probe.stop()
        let delays = probe.delays()

        // Correctness checks are outside the timed interval. Full codec payload equality checks
        // every derived field for this exact snapshot; cross-run facets omit random BinaryImage ID.
        guard AnalysisPayloadCodec.payload(from: restored) == AnalysisPayloadCodec.payload(from: snapshot) else {
            throw MacScopePerformanceFailure.payloadRoundTripChanged
        }
        guard let fingerprint = snapshot.analysisInputFingerprint else {
            throw MacScopePerformanceFailure.missingAnalysisFingerprint
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let facets = fingerprint.facets.sorted { $0.kind.rawValue < $1.kind.rawValue }
        let facetDigest = hex(SHA256.hash(data: try encoder.encode(facets)))
        return MacScopePerformanceSample(
            runID: runID, inputID: input.id, inputSHA256: input.sha256, mode: input.mode,
            iteration: iteration, warmup: warmup,
            analyzeMS: ms(start, analyzed), listingPrepareMS: ms(analyzed, listed),
            wireEncodeMS: ms(listed, encoded), wireDecodeMS: ms(encoded, decoded),
            totalMS: ms(start, decoded), cpuMS: max(0, cpuEnd - cpuStart),
            instructionCount: snapshot.instructions.count, procedureCount: snapshot.functions.count,
            listingRowCount: listing.rows.count, wireBytes: wire.count,
            footprintBytes: footprint?.current, lifetimePeakFootprintBytes: footprint?.peak,
            thermalState: ProcessInfo.processInfo.thermalState.rawValue,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            facetSHA256: facetDigest, mainQueueProbeCount: delays.count,
            mainQueueDelayP95MS: percentile(delays, 0.95), mainQueueDelayMaxMS: delays.max()
        )
    }

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func ms(_ first: UInt64, _ last: UInt64) -> Double { Double(last - first) / 1_000_000 }
    static func hex<D: Sequence>(_ value: D) -> String where D.Element == UInt8 {
        value.map { String(format: "%02x", $0) }.joined()
    }
    static func percentile(_ values: [Double], _ quantile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[max(0, min(sorted.count - 1, Int(ceil(quantile * Double(sorted.count))) - 1))]
    }
    static func cpuMilliseconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000
    }
    static func footprint() -> (current: UInt64, peak: UInt64)? {
        var information = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let status = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        // The peak ledger is a signed Int64 in the SDK; a negative value is not a valid size.
        return (information.phys_footprint, UInt64(max(0, information.ledger_phys_footprint_peak)))
    }
}

/// Measures how long a posted main-queue callback waits, not rendered frame time. One outstanding
/// callback and at most 4,096 retained delays prevent the probe from worsening an observed hang.
private final class MacScopeMainQueueProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(
        label: "org.macscope.MacScope.performance-probe", qos: .utility
    ))
    private var isRunning = false
    private var pending = false
    private var values: [Double] = []

    func start() {
        lock.withLock { isRunning = true }
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
        timer.resume()
    }
    func stop() {
        lock.withLock { isRunning = false }
        timer.cancel()
    }
    func delays() -> [Double] { lock.withLock { values } }
    private func tick() {
        let shouldPost = lock.withLock { () -> Bool in
            guard isRunning, !pending, values.count < 4_096 else { return false }
            pending = true
            return true
        }
        guard shouldPost else { return }
        let start = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let duration = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            self.lock.withLock {
                self.pending = false
                if self.isRunning { self.values.append(duration) }
            }
        }
    }
}
