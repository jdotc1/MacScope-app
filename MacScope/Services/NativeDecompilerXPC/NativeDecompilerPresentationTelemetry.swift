import Foundation
import OSLog

enum NativeDecompilerTelemetryIntervalKind: String, CaseIterable, Sendable {
    case projection, admission, queueWait, cacheLookup, cacheInsert, cacheEviction
    case xpcNativeExecution, decodeSemanticValidation, tokenProjection, comparisonProjection
    case endToEndAttempt, ownerCancellation, ownerRetirement, shutdown
}

enum NativeDecompilerTelemetryOutcome: String, CaseIterable, Sendable {
    case success, failure, timeout, cancelled, superseded, cacheHit, rejected, unavailable

    /// `cacheHit` remains an accepted compatibility input for the existing registry call site, but
    /// it is never emitted as an outcome. The recorder normalizes it to `.success` plus
    /// `.lookupHit`, keeping terminal outcome separate from execution source.
    static let allCases: [Self] = [
        .success, .failure, .timeout, .cancelled, .superseded, .rejected, .unavailable,
    ]
}

enum NativeDecompilerTelemetryCacheDisposition: String, CaseIterable, Sendable {
    case notApplicable, lookupHit, lookupMiss, inserted, bypassed, evicted, invalidated
}

/// Whether a separate product fallback was involved. This is deliberately independent of the
/// native interval's terminal outcome: a failed native attempt may still have a successful
/// product fallback, and telemetry must not collapse those two facts into product truth.
enum NativeDecompilerTelemetryFallbackDisposition: String, CaseIterable, Sendable {
    case notApplicable, notUsed, used, unavailable
}

enum NativeDecompilerTelemetryOwnerKind: String, CaseIterable, Sendable {
    case windowSession, reconstructionJob, appRuntime
}

enum NativeDecompilerTelemetrySizeBucket: String, CaseIterable, Sendable {
    case none, tiny, small, medium, large, oversized
}

enum NativeDecompilerTelemetryCountBucket: String, CaseIterable, Sendable {
    case zero, one, twoToFour, fiveToSixteen, seventeenToSixtyFour, moreThanSixtyFour
}

/// Exact, process-local correlation authority for fields a caller actually owns. UUIDs and a
/// generation are fixed-size; this surface intentionally accepts no strings, paths, binary bytes,
/// pseudocode, prompts, symbols, diagnostics, exception payloads, or dependency values.
///
/// The tuple is diagnostic correlation only. It is not Codable, is never persisted, and must not
/// be consulted to accept, reject, cache, present, or otherwise establish product truth.
struct NativeDecompilerTelemetryCorrelationIdentity: Equatable, Hashable, Sendable {
    let sessionID: UUID
    let generation: UInt64
    let requestID: UUID?
    let workspaceID: UUID?
    let imageID: UUID?

    init(
        sessionID: UUID,
        generation: UInt64,
        requestID: UUID? = nil,
        workspaceID: UUID? = nil,
        imageID: UUID? = nil
    ) {
        self.sessionID = sessionID
        self.generation = generation
        self.requestID = requestID
        self.workspaceID = workspaceID
        self.imageID = imageID
    }

    fileprivate var isValid: Bool { generation > 0 }
}

/// The only payload whose fields may be logged publicly. Every string value is sourced from a
/// closed enum vocabulary and every magnitude is fixed-width or bucketed.
struct NativeDecompilerPublicIntervalPayload: Equatable, Sendable {
    let intervalKind: NativeDecompilerTelemetryIntervalKind
    let outcome: NativeDecompilerTelemetryOutcome
    let durationNanoseconds: UInt64
    let cacheDisposition: NativeDecompilerTelemetryCacheDisposition
    let fallbackDisposition: NativeDecompilerTelemetryFallbackDisposition
    let ownerKind: NativeDecompilerTelemetryOwnerKind
    let sizeBucket: NativeDecompilerTelemetrySizeBucket
    let countBucket: NativeDecompilerTelemetryCountBucket
}

/// A bounded, transient diagnostic record. `correlationIdentity` is always private in unified
/// logging and remains excluded from `NativeDecompilerPublicIntervalPayload`.
struct NativeDecompilerTelemetryRecord: Equatable, Sendable {
    let interval: NativeDecompilerPublicIntervalPayload?
    let correlationIdentity: NativeDecompilerTelemetryCorrelationIdentity?
}

struct NativeDecompilerTelemetrySnapshot: Equatable, Sendable {
    let activeIntervalCount: Int
    let trackedOwnerCount: Int
    let droppedIntervalCount: UInt64
    let records: [NativeDecompilerTelemetryRecord]
}

enum NativeDecompilerTelemetryLifecycleError: Error, Equatable, Sendable {
    case unbalancedIntervals(count: Int)
}

struct NativeDecompilerTelemetryIntervalToken: Hashable, Sendable {
    fileprivate let value: UUID
    let wasAdmitted: Bool
}

final class NativeDecompilerTelemetryRecorder: @unchecked Sendable {
    private struct ActiveInterval {
        let kind: NativeDecompilerTelemetryIntervalKind
        let cacheDisposition: NativeDecompilerTelemetryCacheDisposition
        let ownerKind: NativeDecompilerTelemetryOwnerKind
        let sizeBucket: NativeDecompilerTelemetrySizeBucket
        let countBucket: NativeDecompilerTelemetryCountBucket
        let correlationIdentity: NativeDecompilerTelemetryCorrelationIdentity?
        let startNanoseconds: UInt64
    }

    private struct OwnerFence {
        var latestGeneration: UInt64
        var closedThroughGeneration: UInt64
        var isRetired: Bool
    }

    private static let logger = Logger(
        subsystem: "org.macscope.MacScope",
        category: "NativeDecompiler"
    )
    private static let absoluteMaximumHistoryCount = 1_024
    private static let absoluteMaximumActiveIntervalCount = 1_024
    private static let absoluteMaximumTrackedOwnerCount = 1_024
    private static let absoluteMaximumLogEventCount = 1_024

    private let lock = NSLock()
    private let maximumHistoryCount: Int
    private let maximumActiveIntervalCount: Int
    private let maximumTrackedOwnerCount: Int
    private let maximumLogEventCount: Int
    private var active: [NativeDecompilerTelemetryIntervalToken: ActiveInterval] = [:]
    private var ownerFences: [UUID: OwnerFence] = [:]
    private var completed: [NativeDecompilerTelemetryRecord] = []
    private var droppedIntervals: UInt64 = 0
    private var emittedLogEvents = 0

    init(
        maximumHistoryCount: Int = 256,
        maximumActiveIntervalCount: Int = 256,
        maximumTrackedOwnerCount: Int = 256,
        maximumLogEventCount: Int = 256
    ) {
        self.maximumHistoryCount = Self.clampedCount(
            maximumHistoryCount,
            upperBound: Self.absoluteMaximumHistoryCount
        )
        self.maximumActiveIntervalCount = Self.clampedCount(
            maximumActiveIntervalCount,
            upperBound: Self.absoluteMaximumActiveIntervalCount
        )
        self.maximumTrackedOwnerCount = Self.clampedCount(
            maximumTrackedOwnerCount,
            upperBound: Self.absoluteMaximumTrackedOwnerCount
        )
        self.maximumLogEventCount = Self.clampedCount(
            maximumLogEventCount,
            upperBound: Self.absoluteMaximumLogEventCount
        )
    }

    var activeIntervalCount: Int {
        lock.withLock { active.count }
    }

    var records: [NativeDecompilerTelemetryRecord] {
        lock.withLock { completed }
    }

    func snapshot() -> NativeDecompilerTelemetrySnapshot {
        lock.withLock {
            NativeDecompilerTelemetrySnapshot(
                activeIntervalCount: active.count,
                trackedOwnerCount: ownerFences.count,
                droppedIntervalCount: droppedIntervals,
                records: completed
            )
        }
    }

    func assertBalanced() throws {
        let count = lock.withLock { active.count }
        guard count == 0 else {
            throw NativeDecompilerTelemetryLifecycleError.unbalancedIntervals(count: count)
        }
    }

    func begin(
        kind: NativeDecompilerTelemetryIntervalKind,
        cacheDisposition: NativeDecompilerTelemetryCacheDisposition,
        ownerKind: NativeDecompilerTelemetryOwnerKind,
        sizeBucket: NativeDecompilerTelemetrySizeBucket,
        countBucket: NativeDecompilerTelemetryCountBucket,
        correlationIdentity: NativeDecompilerTelemetryCorrelationIdentity? = nil,
        nowNanoseconds: UInt64
    ) -> NativeDecompilerTelemetryIntervalToken {
        let tokenID = UUID()
        let result: (admitted: Bool, logRecords: [NativeDecompilerTelemetryRecord]) =
            lock.withLock {
                var logRecords: [NativeDecompilerTelemetryRecord] = []

                if let correlationIdentity {
                    guard correlationIdentity.isValid else {
                        incrementDroppedIntervalsLocked()
                        return (false, [])
                    }
                    let sessionID = correlationIdentity.sessionID
                    if var fence = ownerFences[sessionID] {
                        guard !fence.isRetired,
                              correlationIdentity.generation > fence.closedThroughGeneration,
                              correlationIdentity.generation >= fence.latestGeneration
                        else {
                            incrementDroppedIntervalsLocked()
                            return (false, [])
                        }
                        if correlationIdentity.generation > fence.latestGeneration {
                            fence.latestGeneration = correlationIdentity.generation
                            ownerFences[sessionID] = fence
                            logRecords = terminalizeLocked(
                                where: { interval in
                                    interval.correlationIdentity?.sessionID == sessionID
                                        && (interval.correlationIdentity?.generation ?? .max)
                                            < correlationIdentity.generation
                                },
                                outcome: .superseded,
                                fallbackDisposition: .notApplicable,
                                nowNanoseconds: nowNanoseconds
                            )
                        }
                    } else {
                        guard ownerFences.count < maximumTrackedOwnerCount else {
                            incrementDroppedIntervalsLocked()
                            return (false, [])
                        }
                        ownerFences[sessionID] = OwnerFence(
                            latestGeneration: correlationIdentity.generation,
                            closedThroughGeneration: 0,
                            isRetired: false
                        )
                    }
                }

                guard active.count < maximumActiveIntervalCount else {
                    incrementDroppedIntervalsLocked()
                    return (false, logRecords)
                }
                let token = NativeDecompilerTelemetryIntervalToken(
                    value: tokenID,
                    wasAdmitted: true
                )
                active[token] = ActiveInterval(
                    kind: kind,
                    cacheDisposition: cacheDisposition,
                    ownerKind: ownerKind,
                    sizeBucket: sizeBucket,
                    countBucket: countBucket,
                    correlationIdentity: correlationIdentity,
                    startNanoseconds: nowNanoseconds
                )
                return (true, logRecords)
            }
        emit(result.logRecords)
        return NativeDecompilerTelemetryIntervalToken(
            value: tokenID,
            wasAdmitted: result.admitted
        )
    }

    @discardableResult
    func end(
        token: NativeDecompilerTelemetryIntervalToken,
        outcome: NativeDecompilerTelemetryOutcome,
        fallbackDisposition: NativeDecompilerTelemetryFallbackDisposition = .notApplicable,
        nowNanoseconds: UInt64
    ) -> Bool {
        guard token.wasAdmitted else { return false }
        let result: (ended: Bool, logRecord: NativeDecompilerTelemetryRecord?) = lock.withLock {
            guard let interval = active[token] else { return (false, nil) }
            if let identity = interval.correlationIdentity,
               let fence = ownerFences[identity.sessionID],
               (fence.isRetired
                   || identity.generation <= fence.closedThroughGeneration
                   || identity.generation < fence.latestGeneration)
            {
                active.removeValue(forKey: token)
                incrementDroppedIntervalsLocked()
                return (false, nil)
            }
            active.removeValue(forKey: token)
            let fields = Self.normalizedCompletion(
                outcome: outcome,
                cacheDisposition: interval.cacheDisposition,
                fallbackDisposition: fallbackDisposition
            )
            let record = makeRecord(
                interval: interval,
                outcome: fields.outcome,
                cacheDisposition: fields.cacheDisposition,
                fallbackDisposition: fields.fallbackDisposition,
                nowNanoseconds: nowNanoseconds
            )
            return (true, appendCompletedLocked(record))
        }
        if let record = result.logRecord {
            emit(record)
        }
        return result.ended
    }

    /// Cancels one session through an exact generation. A cancellation older than the newest
    /// admitted generation is stale and cannot terminalize its successor.
    @discardableResult
    func cancel(
        sessionID: UUID,
        throughGeneration: UInt64,
        nowNanoseconds: UInt64
    ) -> Bool {
        guard throughGeneration > 0 else { return false }
        let result: (applied: Bool, logRecords: [NativeDecompilerTelemetryRecord]) =
            lock.withLock {
                if var fence = ownerFences[sessionID] {
                    guard !fence.isRetired,
                          throughGeneration >= fence.latestGeneration
                    else { return (false, []) }
                    fence.latestGeneration = throughGeneration
                    fence.closedThroughGeneration = max(
                        fence.closedThroughGeneration,
                        throughGeneration
                    )
                    ownerFences[sessionID] = fence
                } else {
                    guard ownerFences.count < maximumTrackedOwnerCount else {
                        return (false, [])
                    }
                    ownerFences[sessionID] = OwnerFence(
                        latestGeneration: throughGeneration,
                        closedThroughGeneration: throughGeneration,
                        isRetired: false
                    )
                }
                let logRecords = terminalizeLocked(
                    where: { interval in
                        guard let identity = interval.correlationIdentity else { return false }
                        return identity.sessionID == sessionID
                            && identity.generation <= throughGeneration
                    },
                    outcome: .cancelled,
                    fallbackDisposition: .notApplicable,
                    nowNanoseconds: nowNanoseconds
                )
                return (true, logRecords)
            }
        emit(result.logRecords)
        return result.applied
    }

    /// Permanently retires a session. The exact retirement generation must not trail a live
    /// successor, and every late completion token is removed before the transition returns.
    @discardableResult
    func retire(
        sessionID: UUID,
        generation: UInt64,
        nowNanoseconds: UInt64
    ) -> Bool {
        guard generation > 0 else { return false }
        let result: (applied: Bool, logRecords: [NativeDecompilerTelemetryRecord]) =
            lock.withLock {
                if var fence = ownerFences[sessionID] {
                    guard !fence.isRetired,
                          generation >= fence.latestGeneration
                    else { return (false, []) }
                    fence.latestGeneration = generation
                    fence.closedThroughGeneration = max(
                        fence.closedThroughGeneration,
                        generation
                    )
                    fence.isRetired = true
                    ownerFences[sessionID] = fence
                } else {
                    guard ownerFences.count < maximumTrackedOwnerCount else {
                        return (false, [])
                    }
                    ownerFences[sessionID] = OwnerFence(
                        latestGeneration: generation,
                        closedThroughGeneration: generation,
                        isRetired: true
                    )
                }
                let logRecords = terminalizeLocked(
                    where: { $0.correlationIdentity?.sessionID == sessionID },
                    outcome: .superseded,
                    fallbackDisposition: .notApplicable,
                    nowNanoseconds: nowNanoseconds
                )
                return (true, logRecords)
            }
        emit(result.logRecords)
        return result.applied
    }

    private static func clampedCount(_ value: Int, upperBound: Int) -> Int {
        min(max(value, 0), upperBound)
    }

    private static func normalizedCompletion(
        outcome: NativeDecompilerTelemetryOutcome,
        cacheDisposition: NativeDecompilerTelemetryCacheDisposition,
        fallbackDisposition: NativeDecompilerTelemetryFallbackDisposition
    ) -> (
        outcome: NativeDecompilerTelemetryOutcome,
        cacheDisposition: NativeDecompilerTelemetryCacheDisposition,
        fallbackDisposition: NativeDecompilerTelemetryFallbackDisposition
    ) {
        guard outcome == .cacheHit else {
            return (outcome, cacheDisposition, fallbackDisposition)
        }
        return (
            .success,
            .lookupHit,
            fallbackDisposition == .notApplicable ? .notUsed : fallbackDisposition
        )
    }

    private func terminalizeLocked(
        where predicate: (ActiveInterval) -> Bool,
        outcome: NativeDecompilerTelemetryOutcome,
        fallbackDisposition: NativeDecompilerTelemetryFallbackDisposition,
        nowNanoseconds: UInt64
    ) -> [NativeDecompilerTelemetryRecord] {
        let tokens = active.compactMap { token, interval in
            predicate(interval) ? token : nil
        }
        var logRecords: [NativeDecompilerTelemetryRecord] = []
        logRecords.reserveCapacity(tokens.count)
        for token in tokens {
            guard let interval = active.removeValue(forKey: token) else { continue }
            let record = makeRecord(
                interval: interval,
                outcome: outcome,
                cacheDisposition: interval.cacheDisposition,
                fallbackDisposition: fallbackDisposition,
                nowNanoseconds: nowNanoseconds
            )
            if let logRecord = appendCompletedLocked(record) {
                logRecords.append(logRecord)
            }
        }
        return logRecords
    }

    private func makeRecord(
        interval: ActiveInterval,
        outcome: NativeDecompilerTelemetryOutcome,
        cacheDisposition: NativeDecompilerTelemetryCacheDisposition,
        fallbackDisposition: NativeDecompilerTelemetryFallbackDisposition,
        nowNanoseconds: UInt64
    ) -> NativeDecompilerTelemetryRecord {
        let duration = nowNanoseconds >= interval.startNanoseconds
            ? nowNanoseconds - interval.startNanoseconds
            : 0
        return NativeDecompilerTelemetryRecord(
            interval: .init(
                intervalKind: interval.kind,
                outcome: outcome,
                durationNanoseconds: duration,
                cacheDisposition: cacheDisposition,
                fallbackDisposition: fallbackDisposition,
                ownerKind: interval.ownerKind,
                sizeBucket: interval.sizeBucket,
                countBucket: interval.countBucket
            ),
            correlationIdentity: interval.correlationIdentity
        )
    }

    /// Appends to the bounded process-local ring and separately consumes the finite unified-log
    /// budget. Returning nil means the record remains available in the ring but is not logged.
    private func appendCompletedLocked(
        _ record: NativeDecompilerTelemetryRecord
    ) -> NativeDecompilerTelemetryRecord? {
        if maximumHistoryCount > 0 {
            completed.append(record)
            if completed.count > maximumHistoryCount {
                completed.removeFirst(completed.count - maximumHistoryCount)
            }
        }
        guard emittedLogEvents < maximumLogEventCount else { return nil }
        emittedLogEvents += 1
        return record
    }

    private func incrementDroppedIntervalsLocked() {
        if droppedIntervals < .max {
            droppedIntervals += 1
        }
    }

    private func emit(_ records: [NativeDecompilerTelemetryRecord]) {
        for record in records {
            emit(record)
        }
    }

    /// Only closed vocabulary and fixed-width/bucketed metrics are public. Exact correlation IDs
    /// are explicitly private and bounded (UUID text or a UInt64 generation); no caller-provided
    /// strings can enter this interpolation surface.
    private func emit(_ record: NativeDecompilerTelemetryRecord) {
        guard let interval = record.interval else { return }
        let requestID = record.correlationIdentity?.requestID?.uuidString ?? "none"
        let sessionID = record.correlationIdentity?.sessionID.uuidString ?? "none"
        let workspaceID = record.correlationIdentity?.workspaceID?.uuidString ?? "none"
        let imageID = record.correlationIdentity?.imageID?.uuidString ?? "none"
        let generation = record.correlationIdentity.map { String($0.generation) } ?? "none"
        Self.logger.info(
            "Native decompiler interval kind=\(interval.intervalKind.rawValue, privacy: .public) outcome=\(interval.outcome.rawValue, privacy: .public) duration_ns=\(interval.durationNanoseconds, privacy: .public) cache=\(interval.cacheDisposition.rawValue, privacy: .public) fallback=\(interval.fallbackDisposition.rawValue, privacy: .public) owner=\(interval.ownerKind.rawValue, privacy: .public) size=\(interval.sizeBucket.rawValue, privacy: .public) count=\(interval.countBucket.rawValue, privacy: .public) request_id=\(requestID, privacy: .private) session_id=\(sessionID, privacy: .private) workspace_id=\(workspaceID, privacy: .private) image_id=\(imageID, privacy: .private) generation=\(generation, privacy: .private)"
        )
    }
}
