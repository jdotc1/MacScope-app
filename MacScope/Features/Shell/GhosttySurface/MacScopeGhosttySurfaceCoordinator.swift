import AppKit
import Foundation

/// Exact, ephemeral identity for one native terminal presentation.
///
/// This value is deliberately independent of persisted workspace state and Ghostty implementation
/// types. A newly created surface must receive a newly incremented generation even when the broker
/// session and request identifiers are unchanged.
struct MacScopeGhosttySurfaceGeneration: Hashable, Sendable {
    let sessionID: UUID
    let requestID: UUID
    let generation: UInt64

    init(sessionID: UUID, requestID: UUID, generation: UInt64) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.generation = generation
    }
}

enum MacScopeGhosttySurfaceTeardownStep: String, CaseIterable, Sendable {
    case retireGeneration
    case stopFeed
    case invalidateCallbacks
    case detachDisplayAndWakeup
    case destroySurface
    case releaseBridgeBox
}

enum MacScopeGhosttyFixtureKind: String, CaseIterable, Sendable {
    case ansi
    case unicode
    case grapheme
    case alternateScreen
    case selection
    case inputMethod
    case mouse
    case resize
    case teardown
}

/// A deterministic, broker-free byte fixture used to qualify the host/bridge boundary.
struct MacScopeGhosttySurfaceFixture: Equatable, Sendable {
    let kind: MacScopeGhosttyFixtureKind
    let chunks: [Data]

    var byteCount: Int {
        chunks.reduce(0) { total, chunk in
            let next = total.addingReportingOverflow(chunk.count)
            return next.overflow ? Int.max : next.partialValue
        }
    }

    static func canonical(_ kind: MacScopeGhosttyFixtureKind) -> Self {
        let strings: [String]
        switch kind {
        case .ansi:
            strings = ["\u{001B}[31mred", "\u{001B}[0m\r\n"]
        case .unicode:
            strings = ["Latin ", "日本語 ", "العربية\r\n"]
        case .grapheme:
            strings = ["e\u{0301}", " 👨‍👩‍👧‍👦 ", "🇺🇸\r\n"]
        case .alternateScreen:
            strings = ["\u{001B}[?1049h", "alternate", "\u{001B}[?1049l"]
        case .selection:
            strings = ["selectable terminal text\r\n"]
        case .inputMethod:
            strings = ["候", "補\r\n"]
        case .mouse:
            strings = ["\u{001B}[?1006h", "\u{001B}[?1006l"]
        case .resize:
            strings = ["\u{001B}[8;24;80t"]
        case .teardown:
            strings = ["final frame before teardown\r\n"]
        }
        return Self(kind: kind, chunks: strings.map { Data($0.utf8) })
    }
}

enum MacScopeGhosttyFixtureRejection: Equatable, Sendable {
    case staleOrRetiredGeneration
    case backendUnavailable
    case fixtureBudgetExceeded
    case backendRejectedChunk(index: Int, admission: MacScopeGhosttySurfaceFeedAdmission)
}

enum MacScopeGhosttyFixtureAdmission: Equatable, Sendable {
    case accepted(byteCount: Int, chunkCount: Int, ranOnMainThread: Bool)
    case rejected(MacScopeGhosttyFixtureRejection)
}

/// Lossless MacScope-owned projection of the external-I/O ABI result vocabulary.
///
/// Only `accepted` consumes bytes. In particular, callers must retain and retry a chunk after
/// `backpressured`; collapsing this value to `Bool` would permit silent terminal-output loss.
enum MacScopeGhosttySurfaceFeedAdmission: Equatable, Hashable, Sendable {
    case accepted
    case backpressured
    case closed
    case invalid
    case internalError
}

/// Host-authoritative process state reported to the renderer after all final output is admitted.
/// Ghostty never creates, owns, signals, resizes, or waits for the represented process.
enum MacScopeGhosttySurfaceProcessState: Equatable, Sendable {
    case running
    case exited(status: Int32)
    case signaled(signal: UInt32)
    case closed
}

/// MacScope-owned adapter boundary for the eventual GhosttyKit/C-ABI implementation.
///
/// UI operations are main-actor isolated. Fixture feeding is intentionally nonisolated and the
/// conformer must be thread-safe; the coordinator invokes it only from its private serial queue.
/// The C bridge may conform through a retained box without exposing Ghostty objects to SwiftUI.
protocol MacScopeGhosttySurfaceBackend: AnyObject, Sendable {
    @MainActor
    func attach(to hostView: MacScopeGhosttySurfaceHostView) throws

    @MainActor
    func handle(hostEvent: MacScopeGhosttySurfaceHostEvent) -> Bool

    @MainActor
    func selectedText() -> String?

    @MainActor
    func textInputRect() -> NSRect?

    func feed(_ bytes: Data, generation: MacScopeGhosttySurfaceGeneration)
        -> MacScopeGhosttySurfaceFeedAdmission

    func setProcessState(
        _ state: MacScopeGhosttySurfaceProcessState,
        generation: MacScopeGhosttySurfaceGeneration
    ) -> MacScopeGhosttySurfaceFeedAdmission

    @MainActor
    func retire(generation: MacScopeGhosttySurfaceGeneration)

    @MainActor
    func stopFeed()

    @MainActor
    func invalidateCallbacks()

    @MainActor
    func detachDisplayAndWakeup()

    @MainActor
    func destroySurface()

    @MainActor
    func releaseBridgeBox()
}

extension MacScopeGhosttySurfaceBackend {
    @MainActor
    func selectedText() -> String? { nil }

    @MainActor
    func textInputRect() -> NSRect? { nil }

    func setProcessState(
        _ state: MacScopeGhosttySurfaceProcessState,
        generation: MacScopeGhosttySurfaceGeneration
    ) -> MacScopeGhosttySurfaceFeedAdmission { .invalid }
}

private final class MacScopeGhosttyGenerationFence: @unchecked Sendable {
    private let condition = NSCondition()
    private let generation: MacScopeGhosttySurfaceGeneration
    private var retired = false
    private var inFlightOperationCount = 0
    private var operationsDrainedHandler: (@Sendable () -> Void)?

    init(generation: MacScopeGhosttySurfaceGeneration) {
        self.generation = generation
    }

    func permits(_ candidate: MacScopeGhosttySurfaceGeneration) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return !retired && candidate == generation
    }

    func withPermit<Result>(
        _ candidate: MacScopeGhosttySurfaceGeneration,
        perform operation: () -> Result
    ) -> Result? {
        condition.lock()
        guard !retired, candidate == generation else {
            condition.unlock()
            return nil
        }
        inFlightOperationCount += 1
        condition.unlock()

        defer {
            let handler: (@Sendable () -> Void)?
            condition.lock()
            inFlightOperationCount -= 1
            if inFlightOperationCount == 0 {
                handler = operationsDrainedHandler
                operationsDrainedHandler = nil
            } else {
                handler = nil
            }
            condition.unlock()
            handler?()
        }
        return operation()
    }

    @discardableResult
    func retire() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !retired else { return false }
        retired = true
        return true
    }

    /// Registers one completion after retirement if destruction must be deferred.
    ///
    /// Retirement prevents new permits, so observing zero here makes synchronous finalization
    /// safe. A nonzero result never blocks the caller (normally the MainActor).
    func deferUntilOperationsDrain(
        _ handler: @escaping @Sendable () -> Void
    ) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard retired, inFlightOperationCount > 0 else { return false }
        guard operationsDrainedHandler == nil else {
            assertionFailure("Ghostty generation fence registered more than one drain handler")
            return true
        }
        operationsDrainedHandler = handler
        return true
    }

    var isRetired: Bool {
        condition.lock()
        defer { condition.unlock() }
        return retired
    }
}

private enum MacScopeGhosttySurfaceAttachmentError: Error {
    case invalidLifecycle
    case hostUnavailable
}

/// Generation-fenced owner of one AppKit host and one external-surface backend.
///
/// The coordinator never owns a process, PTY, XPC connection, or workspace state. It translates
/// AppKit events into the narrow backend protocol and enforces the binding destruction sequence.
@MainActor
final class MacScopeGhosttySurfaceCoordinator: MacScopeGhosttySurfaceHostEventSink {
    private static let maximumFixtureChunkCount = 256
    private static let maximumFixtureChunkByteCount = 1 << 20
    private static let maximumFixtureByteCount = 4 << 20
    private static let maximumFeedByteCount = 4 << 20

    enum Phase: Equatable, Sendable {
        case initialized
        case attached
        case retiring
        case destroyed
    }

    let generation: MacScopeGhosttySurfaceGeneration

    private(set) var phase: Phase = .initialized
    private(set) var teardownSteps: [MacScopeGhosttySurfaceTeardownStep] = []

    private let fence: MacScopeGhosttyGenerationFence
    private let fixtureQueue: DispatchQueue
    private var backend: (any MacScopeGhosttySurfaceBackend)?
    private weak var hostView: MacScopeGhosttySurfaceHostView?
    private var teardownHostView: MacScopeGhosttySurfaceHostView?
    private var ownsBackendLifecycle = false
    private var shutdownCompletion: (@MainActor () -> Void)?

    init(
        generation: MacScopeGhosttySurfaceGeneration,
        backend: any MacScopeGhosttySurfaceBackend,
        fixtureQueue: DispatchQueue? = nil
    ) {
        self.generation = generation
        self.backend = backend
        fence = MacScopeGhosttyGenerationFence(generation: generation)
        self.fixtureQueue = fixtureQueue ?? DispatchQueue(
            label: "org.macscope.MacScope.GhosttySurface.fixture.\(generation.generation)",
            qos: .userInitiated
        )
    }

    deinit {
        // NSViewRepresentable.dismantleNSView is responsible for deterministic teardown. Avoid
        // performing AppKit or backend calls from deinit, whose executor is not guaranteed.
        assert(fence.isRetired, "Ghostty surface coordinator released without ordered teardown")
    }

    func attach(to hostView: MacScopeGhosttySurfaceHostView) throws {
        guard phase == .initialized, fence.permits(generation), let backend else {
            throw MacScopeGhosttySurfaceAttachmentError.invalidLifecycle
        }
        guard hostView.window != nil else {
            throw MacScopeGhosttySurfaceAttachmentError.hostUnavailable
        }
        guard hostView.installEventSink(self) else {
            throw MacScopeGhosttySurfaceAttachmentError.hostUnavailable
        }
        self.hostView = hostView

        do {
            try backend.attach(to: hostView)
            // A successful attach transfers this backend's teardown obligation to the
            // coordinator. A throwing attach does not: the factory may have returned a backend
            // already owned by another host, and this coordinator must never destroy it.
            ownsBackendLifecycle = true
        } catch {
            hostView.removeEventSink(self)
            self.hostView = nil
            throw error
        }

        guard hostView.window != nil,
              hostView.eventSink === self,
              fence.permits(generation)
        else {
            hostView.removeEventSink(self)
            self.hostView = nil
            throw MacScopeGhosttySurfaceAttachmentError.hostUnavailable
        }
        phase = .attached
        hostView.publishCurrentEnvironment()
    }

    func requestRender() {
        guard phase == .attached, fence.permits(generation) else { return }
        hostView?.requestRender()
    }

    /// Submits bytes that a higher layer has already admitted for this exact surface generation.
    /// Ordering, duplicate, and transcript-gap authority remains outside the renderer boundary.
    func feed(
        _ bytes: Data,
        for candidate: MacScopeGhosttySurfaceGeneration? = nil
    ) -> MacScopeGhosttySurfaceFeedAdmission {
        let candidate = candidate ?? generation
        guard phase == .attached,
              hostView?.window != nil,
              let backend
        else { return .closed }
        return fence.withPermit(candidate) {
            guard bytes.count <= Self.maximumFeedByteCount else { return .invalid }
            return backend.feed(Data(bytes), generation: candidate)
        } ?? .closed
    }

    /// Copies the fixture before crossing the queue and performs all backend admission off-main.
    func admitFixture(
        _ fixture: MacScopeGhosttySurfaceFixture,
        for candidate: MacScopeGhosttySurfaceGeneration? = nil,
        completion: @escaping @Sendable (MacScopeGhosttyFixtureAdmission) -> Void
    ) {
        let candidate = candidate ?? generation
        let fence = fence
        guard phase == .attached, hostView?.window != nil else {
            completion(.rejected(.staleOrRetiredGeneration))
            return
        }
        guard let backend else {
            completion(.rejected(.backendUnavailable))
            return
        }
        guard fixture.chunks.count <= Self.maximumFixtureChunkCount else {
            completion(.rejected(.fixtureBudgetExceeded))
            return
        }
        var byteCount = 0
        for chunk in fixture.chunks {
            guard chunk.count <= Self.maximumFixtureChunkByteCount else {
                completion(.rejected(.fixtureBudgetExceeded))
                return
            }
            let next = byteCount.addingReportingOverflow(chunk.count)
            guard !next.overflow, next.partialValue <= Self.maximumFixtureByteCount else {
                completion(.rejected(.fixtureBudgetExceeded))
                return
            }
            byteCount = next.partialValue
        }
        let chunks = fixture.chunks.map { Data($0) }
        let admittedByteCount = byteCount

        fixtureQueue.async {
            let result = fence.withPermit(candidate) {
                guard fence.permits(candidate) else {
                    return MacScopeGhosttyFixtureAdmission.rejected(
                        .staleOrRetiredGeneration
                    )
                }
                for (index, chunk) in chunks.enumerated() {
                    guard fence.permits(candidate) else {
                        return .rejected(.staleOrRetiredGeneration)
                    }
                    let admission = backend.feed(chunk, generation: candidate)
                    guard admission == .accepted else {
                        return .rejected(.backendRejectedChunk(
                            index: index,
                            admission: admission
                        ))
                    }
                    guard fence.permits(candidate) else {
                        return .rejected(.staleOrRetiredGeneration)
                    }
                }
                return .accepted(
                    byteCount: admittedByteCount,
                    chunkCount: chunks.count,
                    ranOnMainThread: Thread.isMainThread
                )
            } ?? .rejected(.staleOrRetiredGeneration)
            completion(result)
        }
    }

    /// Reports broker-owned lifecycle without granting the renderer process authority.
    func setProcessState(
        _ state: MacScopeGhosttySurfaceProcessState,
        for candidate: MacScopeGhosttySurfaceGeneration? = nil
    ) -> MacScopeGhosttySurfaceFeedAdmission {
        let candidate = candidate ?? generation
        guard phase == .attached,
              hostView?.window != nil,
              let backend
        else { return .closed }
        return fence.withPermit(candidate) {
            backend.setProcessState(state, generation: candidate)
        } ?? .closed
    }

    /// Idempotently performs the binding destruction order.
    func shutdown(completion: (@MainActor () -> Void)? = nil) {
        if phase == .destroyed {
            completion?()
            return
        }
        if let completion, shutdownCompletion == nil {
            shutdownCompletion = completion
        }
        guard fence.retire() else { return }
        phase = .retiring

        // Ghostty stores an unretained AppKit host pointer. Keep the host alive until a deferred
        // native operation drains and the surface is actually destroyed.
        teardownHostView = hostView
        hostView?.removeEventSink(self)
        hostView = nil

        guard let backend else {
            teardownHostView = nil
            phase = .destroyed
            finishShutdownCompletion()
            return
        }

        guard ownsBackendLifecycle else {
            self.backend = nil
            teardownHostView = nil
            phase = .destroyed
            finishShutdownCompletion()
            return
        }

        teardownSteps.append(.retireGeneration)
        backend.retire(generation: generation)

        teardownSteps.append(.stopFeed)
        backend.stopFeed()

        teardownSteps.append(.invalidateCallbacks)
        backend.invalidateCallbacks()

        teardownSteps.append(.detachDisplayAndWakeup)
        backend.detachDisplayAndWakeup()

        // Retire and invalidate external callbacks synchronously, but never block AppKit while an
        // admitted native operation drains. The closure deliberately retains this coordinator and
        // its backend so native storage cannot be freed under an in-flight operation.
        if fence.deferUntilOperationsDrain({ [coordinator = self] in
            Task { @MainActor in
                coordinator.finishShutdownAfterOperationsDrain()
            }
        }) {
            return
        }
        finishShutdownAfterOperationsDrain()
    }

    private func finishShutdownAfterOperationsDrain() {
        guard phase == .retiring, let backend else {
            if phase == .retiring {
                teardownHostView = nil
                phase = .destroyed
                finishShutdownCompletion()
            }
            return
        }

        teardownSteps.append(.destroySurface)
        backend.destroySurface()

        teardownSteps.append(.releaseBridgeBox)
        backend.releaseBridgeBox()

        self.backend = nil
        teardownHostView = nil
        phase = .destroyed
        finishShutdownCompletion()
    }

    private func finishShutdownCompletion() {
        let completion = shutdownCompletion
        shutdownCompletion = nil
        completion?()
    }

    func ghosttyHostView(
        _ hostView: MacScopeGhosttySurfaceHostView,
        handle event: MacScopeGhosttySurfaceHostEvent
    ) -> Bool {
        guard self.hostView === hostView,
              hostView.window != nil,
              hostView.eventSink === self,
              phase == .attached,
              fence.permits(generation),
              let backend
        else { return false }
        return backend.handle(hostEvent: event)
    }

    func selectedText(in hostView: MacScopeGhosttySurfaceHostView) -> String? {
        guard self.hostView === hostView,
              hostView.window != nil,
              hostView.eventSink === self,
              phase == .attached,
              fence.permits(generation)
        else { return nil }
        return backend?.selectedText()
    }

    func textInputRect(in hostView: MacScopeGhosttySurfaceHostView) -> NSRect? {
        guard self.hostView === hostView,
              hostView.window != nil,
              hostView.eventSink === self,
              phase == .attached,
              fence.permits(generation)
        else { return nil }
        return backend?.textInputRect()
    }

    func isAttached(to candidate: MacScopeGhosttySurfaceHostView) -> Bool {
        phase == .attached
            && hostView === candidate
            && candidate.window != nil
            && candidate.eventSink === self
            && fence.permits(generation)
    }

}
