import AppKit
import LumenTokens
import LumenUI
import Foundation

/// Compile-disabled-safe construction boundary for the private linked renderer.
///
/// No Ghostty type appears in this public-to-MacScope signature. Ordinary builds therefore keep
/// compiling and deterministically return `nil` when the reviewed framework and feature condition
/// are absent.
enum MacScopeGhosttyLinkedSurfaceFactory {
    @MainActor
    static func make(
        generation: MacScopeGhosttySurfaceGeneration,
        workHandler: @escaping MacScopeGhosttyExternalIOBridge.Handler
    ) -> (any MacScopeGhosttySurfaceBackend)? {
        #if canImport(GhosttyKit) && MACSCOPE_FULL_GHOSTTY_SURFACE
        guard MacScopeGhosttyRuntime.productionShared.prepare() == .ready else { return nil }
        return MacScopeGhosttyLinkedSurfaceBackend(
            generation: generation,
            workHandler: workHandler
        )
        #else
        _ = generation
        _ = workHandler
        return nil
        #endif
    }

    static var isCompiled: Bool {
        #if canImport(GhosttyKit) && MACSCOPE_FULL_GHOSTTY_SURFACE
        true
        #else
        false
        #endif
    }
}

/// Fixed-cardinality storage for callback work. Repeated native notifications replace the pending
/// value for their category instead of growing an unbounded queue.
private struct MacScopeGhosttyLinkedRuntimeIntentAccumulator {
    private enum Key: Hashable {
        case render
        case wakeup
        case selection
        case pointer
        case title
        case workingDirectory
        case bell
        case close
        case hyperlink
        case rendererHealth
    }

    private var order: [Key] = []
    private var values: [Key: MacScopeGhosttyActionRouter.Intent] = [:]

    var isEmpty: Bool { order.isEmpty }
    var count: Int { order.count }

    mutating func insert(_ intent: MacScopeGhosttyActionRouter.Intent) {
        let key: Key = switch intent {
        case .scheduleRender: .render
        case .wakeup: .wakeup
        case .selectionChanged: .selection
        case .pointerChanged: .pointer
        case .updateTitleMetadata: .title
        case .updateWorkingDirectoryMetadata: .workingDirectory
        case .bell: .bell
        case .requestClose: .close
        case .activateHyperlink: .hyperlink
        case .rendererHealth: .rendererHealth
        }

        if key == .rendererHealth,
           case .rendererHealth(.unhealthy)? = values[key] {
            return
        }
        if values[key] == nil {
            order.append(key)
        }
        values[key] = intent
    }

    mutating func takeAll() -> [MacScopeGhosttyActionRouter.Intent] {
        let intents = order.compactMap { values[$0] }
        removeAll()
        return intents
    }

    mutating func removeAll() {
        order.removeAll(keepingCapacity: true)
        values.removeAll(keepingCapacity: true)
    }
}

typealias MacScopeGhosttyLinkedMainActorWork = @MainActor @Sendable () -> Void
typealias MacScopeGhosttyLinkedMainActorEnqueue = @Sendable (
    @escaping MacScopeGhosttyLinkedMainActorWork
) -> Void

/// Process-global pinning and scheduling boundary for Ghostty runtime callbacks.
///
/// `runtime_config.userdata` carries a never-reused integer token, not an object address. A native
/// callback resolves that token under the registry lock and copies a strong box reference before
/// invoking it. Retirement removes the token before native destruction, so a callback that starts
/// later misses safely while a callback that was already pinned observes the box's retired state.
///
/// The registry also owns one process-global MainActor turn. Each active generation can occupy the
/// pending token set at most once, and replacement reuses an already-enqueued turn instead of
/// leaving one canceled Task per retired generation in the actor queue.
final class MacScopeGhosttyLinkedRuntimeCallbackRegistry: @unchecked Sendable {
    struct Registration: Sendable {
        fileprivate let token: UInt
        let generation: MacScopeGhosttySurfaceGeneration
        let callbackBox: MacScopeGhosttyLinkedRuntimeCallbackBox

        var userdata: UnsafeMutableRawPointer {
            // Tokens start at one and are never recycled for the process lifetime. Ghostty treats
            // userdata as opaque and MacScope converts it back only to the integer registry key.
            UnsafeMutableRawPointer(bitPattern: token)!
        }
    }

    struct Snapshot: Equatable, Sendable {
        let pinnedGenerationCount: Int
        let pendingGenerationCount: Int
        let hasScheduledOrRunningMainActorTurn: Bool
    }

    static let productionShared = MacScopeGhosttyLinkedRuntimeCallbackRegistry()

    private let lock = NSLock()
    private let enqueueOnMainActor: MacScopeGhosttyLinkedMainActorEnqueue
    private var nextToken: UInt = 1
    private var pinnedBoxes: [UInt: MacScopeGhosttyLinkedRuntimeCallbackBox] = [:]
    private var pendingTokens: [UInt] = []
    private var pendingTokenSet: Set<UInt> = []
    private var mainActorTurnScheduledOrRunning = false

    init(
        enqueueOnMainActor: @escaping MacScopeGhosttyLinkedMainActorEnqueue = { work in
            Task { @MainActor in work() }
        }
    ) {
        self.enqueueOnMainActor = enqueueOnMainActor
    }

    func pin(
        generation: MacScopeGhosttySurfaceGeneration,
        router: MacScopeGhosttyActionRouter = MacScopeGhosttyActionRouter()
    ) -> Registration {
        lock.withLock {
            // Exhausting every nonzero pointer-sized token would require more registrations than
            // the process can create. Failing here is preferable to recycling a stale token into
            // a replacement generation.
            precondition(nextToken < UInt.max, "Ghostty callback token space exhausted")
            let token = nextToken
            nextToken += 1
            let box = MacScopeGhosttyLinkedRuntimeCallbackBox(
                generation: generation,
                router: router,
                requestDrain: { [weak self] in self?.requestDrain(for: token) }
            )
            pinnedBoxes[token] = box
            return Registration(token: token, generation: generation, callbackBox: box)
        }
    }

    @MainActor
    @discardableResult
    func install(
        _ registration: Registration,
        surfaceToken: UnsafeMutableRawPointer,
        handler: @escaping MacScopeGhosttyLinkedRuntimeCallbackBox.Handler
    ) -> Bool {
        guard let box = pinnedBox(for: registration) else { return false }
        return box.install(surfaceToken: surfaceToken, handler: handler)
    }

    @MainActor
    @discardableResult
    func retireAndUnpin(_ registration: Registration) -> Bool {
        let didRetire = registration.callbackBox.retire(generation: registration.generation)
        lock.withLock {
            guard pinnedBoxes[registration.token] === registration.callbackBox else { return }
            pinnedBoxes.removeValue(forKey: registration.token)
            removePendingTokenLocked(registration.token)
        }
        return didRetire
    }

    @discardableResult
    func submitWakeup(userdata: UnsafeMutableRawPointer?) -> Bool {
        guard let box = pinnedBox(for: userdata) else { return false }
        return box.submitWakeup()
    }

    @discardableResult
    func submit(
        _ action: MacScopeGhosttyAction,
        surfaceToken: UnsafeMutableRawPointer?,
        userdata: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let box = pinnedBox(for: userdata) else { return false }
        return box.submit(action, surfaceToken: surfaceToken)
    }

    func pinnedBox(
        for userdata: UnsafeMutableRawPointer?
    ) -> MacScopeGhosttyLinkedRuntimeCallbackBox? {
        guard let userdata else { return nil }
        let token = UInt(bitPattern: userdata)
        guard token != 0 else { return nil }
        return lock.withLock { pinnedBoxes[token] }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                pinnedGenerationCount: pinnedBoxes.count,
                pendingGenerationCount: pendingTokens.count,
                hasScheduledOrRunningMainActorTurn: mainActorTurnScheduledOrRunning
            )
        }
    }

    private func pinnedBox(
        for registration: Registration
    ) -> MacScopeGhosttyLinkedRuntimeCallbackBox? {
        lock.withLock {
            guard pinnedBoxes[registration.token] === registration.callbackBox else { return nil }
            return registration.callbackBox
        }
    }

    private func requestDrain(for token: UInt) {
        let shouldEnqueueTurn = lock.withLock { () -> Bool in
            guard pinnedBoxes[token] != nil else { return false }
            if pendingTokenSet.insert(token).inserted {
                pendingTokens.append(token)
            }
            guard !mainActorTurnScheduledOrRunning else { return false }
            mainActorTurnScheduledOrRunning = true
            return true
        }
        if shouldEnqueueTurn {
            enqueueMainActorTurn()
        }
    }

    private func enqueueMainActorTurn() {
        enqueueOnMainActor { [weak self] in
            self?.drainMainActorTurn()
        }
    }

    @MainActor
    private func drainMainActorTurn() {
        let tokens = lock.withLock { () -> [UInt] in
            let tokens = pendingTokens
            pendingTokens.removeAll(keepingCapacity: true)
            pendingTokenSet.removeAll(keepingCapacity: true)
            // Keep the global turn marked running through every handler and its finalization.
            return tokens
        }

        for token in tokens {
            guard let box = lock.withLock({ pinnedBoxes[token] }) else { continue }
            if box.drainOnceOnMainActor() {
                lock.withLock {
                    guard pinnedBoxes[token] === box else { return }
                    if pendingTokenSet.insert(token).inserted {
                        pendingTokens.append(token)
                    }
                }
            }
        }

        let needsSuccessor = lock.withLock { () -> Bool in
            guard !pendingTokens.isEmpty else {
                mainActorTurnScheduledOrRunning = false
                return false
            }
            return true
        }
        if needsSuccessor {
            enqueueMainActorTurn()
        }
    }

    private func removePendingTokenLocked(_ token: UInt) {
        guard pendingTokenSet.remove(token) != nil else { return }
        pendingTokens.removeAll { $0 == token }
    }
}

/// Generation-scoped callback state retained both by its registry pin and by the backend owner.
/// Pending intents have fixed cardinality and wakeup occupies one accumulator key. The drain state
/// remains `.draining` through synchronous handler execution so a reentrant burst produces exactly
/// one successor turn rather than a lost wakeup or duplicate queued job.
final class MacScopeGhosttyLinkedRuntimeCallbackBox: @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (
        MacScopeGhosttySurfaceGeneration,
        [MacScopeGhosttyActionRouter.Intent]
    ) -> Void

    struct Snapshot: Equatable, Sendable {
        enum DrainState: Equatable, Sendable {
            case idle
            case scheduled
            case draining
            case retired
        }

        let generation: MacScopeGhosttySurfaceGeneration
        let drainState: DrainState
        let pendingIntentCount: Int
        let hasHandler: Bool
    }

    private enum DrainState {
        case idle
        case scheduled(ticket: UInt64)
        case draining(ticket: UInt64)
        case retired
    }

    private let lock = NSLock()
    let generation: MacScopeGhosttySurfaceGeneration
    private let router: MacScopeGhosttyActionRouter
    private let requestDrain: @Sendable () -> Void
    private var drainState: DrainState = .idle
    private var nextDrainTicket: UInt64 = 1
    private var expectedSurfaceToken: UnsafeMutableRawPointer?
    private var pendingSurfaceToken: UnsafeMutableRawPointer?
    private var pending = MacScopeGhosttyLinkedRuntimeIntentAccumulator()
    private var handler: Handler?

    init(
        generation: MacScopeGhosttySurfaceGeneration,
        router: MacScopeGhosttyActionRouter = MacScopeGhosttyActionRouter(),
        requestDrain: @escaping @Sendable () -> Void
    ) {
        self.generation = generation
        self.router = router
        self.requestDrain = requestDrain
    }

    @MainActor
    @discardableResult
    func install(
        surfaceToken: UnsafeMutableRawPointer,
        handler: @escaping Handler
    ) -> Bool {
        let outcome = lock.withLock { () -> (installed: Bool, requestDrain: Bool) in
            guard !isRetiredLocked, self.handler == nil else { return (false, false) }
            if let pendingSurfaceToken, pendingSurfaceToken != surfaceToken {
                pending.removeAll()
            }
            expectedSurfaceToken = surfaceToken
            pendingSurfaceToken = nil
            self.handler = handler
            // Always perform one catch-up tick. This also covers wakeups Ghostty issued while the
            // app or surface was still being constructed and no handler could yet be installed.
            pending.insert(.wakeup)
            return (true, scheduleIfIdleLocked())
        }
        if outcome.requestDrain { requestDrain() }
        return outcome.installed
    }

    @discardableResult
    func submitWakeup() -> Bool {
        let outcome = lock.withLock { () -> (accepted: Bool, requestDrain: Bool) in
            guard !isRetiredLocked else { return (false, false) }
            pending.insert(.wakeup)
            return (true, scheduleIfIdleLocked())
        }
        if outcome.requestDrain { requestDrain() }
        return outcome.accepted
    }

    @discardableResult
    func submit(
        _ action: MacScopeGhosttyAction,
        surfaceToken: UnsafeMutableRawPointer?
    ) -> Bool {
        guard case let .perform(intent) = router.route(action) else { return false }
        guard let surfaceToken else { return false }

        let outcome = lock.withLock { () -> (accepted: Bool, requestDrain: Bool) in
            guard !isRetiredLocked else { return (false, false) }
            if let expectedSurfaceToken {
                guard expectedSurfaceToken == surfaceToken else { return (false, false) }
            } else if let pendingSurfaceToken {
                guard pendingSurfaceToken == surfaceToken else { return (false, false) }
            } else {
                pendingSurfaceToken = surfaceToken
            }
            pending.insert(intent)
            return (true, scheduleIfIdleLocked())
        }
        if outcome.requestDrain { requestDrain() }
        return outcome.accepted
    }

    @MainActor
    @discardableResult
    func retire(generation candidate: MacScopeGhosttySurfaceGeneration) -> Bool {
        lock.withLock {
            guard candidate == generation, !isRetiredLocked else { return false }
            drainState = .retired
            expectedSurfaceToken = nil
            pendingSurfaceToken = nil
            pending.removeAll()
            handler = nil
            return true
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            let publicState: Snapshot.DrainState = switch drainState {
            case .idle: .idle
            case .scheduled: .scheduled
            case .draining: .draining
            case .retired: .retired
            }
            return Snapshot(
                generation: generation,
                drainState: publicState,
                pendingIntentCount: pending.count,
                hasHandler: handler != nil
            )
        }
    }

    @MainActor
    @discardableResult
    func drainOnceOnMainActor() -> Bool {
        let delivery: (
            ticket: UInt64,
            handler: Handler,
            intents: [MacScopeGhosttyActionRouter.Intent]
        )? = lock.withLock {
            guard case let .scheduled(ticket) = drainState, let handler else {
                if !isRetiredLocked { drainState = .idle }
                pending.removeAll()
                return nil
            }
            let intents = pending.takeAll()
            guard !intents.isEmpty else {
                drainState = .idle
                return nil
            }
            drainState = .draining(ticket: ticket)
            return (ticket, handler, intents)
        }
        guard let delivery else { return false }

        delivery.handler(generation, delivery.intents)

        return lock.withLock {
            guard case let .draining(activeTicket) = drainState,
                  activeTicket == delivery.ticket else {
                return false
            }
            guard !pending.isEmpty else {
                drainState = .idle
                return false
            }
            drainState = .scheduled(ticket: takeDrainTicketLocked())
            return true
        }
    }

    private var isRetiredLocked: Bool {
        if case .retired = drainState { return true }
        return false
    }

    private func scheduleIfIdleLocked() -> Bool {
        guard handler != nil, !pending.isEmpty else { return false }
        guard case .idle = drainState else { return false }
        drainState = .scheduled(ticket: takeDrainTicketLocked())
        return true
    }

    private func takeDrainTicketLocked() -> UInt64 {
        precondition(nextDrainTicket < UInt64.max, "Ghostty callback drain ticket space exhausted")
        let ticket = nextDrainTicket
        nextDrainTicket += 1
        return ticket
    }
}

#if canImport(GhosttyKit) && MACSCOPE_FULL_GHOSTTY_SURFACE
import GhosttyKit

private enum MacScopeGhosttyLinkedSurfaceError: Error {
    case alreadyAttached
    case retired
    case applicationCreationFailed
    case externalSurfaceCreationFailed
    case externalSurfaceVerificationFailed
}

private func macScopeGhosttyNativeResult(
    _ admission: MacScopeGhosttyExternalIOBridge.Admission
) -> ghostty_external_io_result_e {
    switch admission {
    case .accepted: GHOSTTY_EXTERNAL_IO_ACCEPTED
    case .backpressured: GHOSTTY_EXTERNAL_IO_BACKPRESSURED
    case .closed: GHOSTTY_EXTERNAL_IO_CLOSED
    case .invalid: GHOSTTY_EXTERNAL_IO_INVALID
    }
}

private func macScopeGhosttyFeedAdmission(
    _ result: ghostty_external_io_result_e
) -> MacScopeGhosttySurfaceFeedAdmission {
    switch result {
    case GHOSTTY_EXTERNAL_IO_ACCEPTED: .accepted
    case GHOSTTY_EXTERNAL_IO_BACKPRESSURED: .backpressured
    case GHOSTTY_EXTERNAL_IO_CLOSED: .closed
    case GHOSTTY_EXTERNAL_IO_INVALID: .invalid
    case GHOSTTY_EXTERNAL_IO_INTERNAL_ERROR: .internalError
    default: .internalError
    }
}

private func macScopeGhosttyWriteCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<UInt8>?,
    _ count: Int
) -> ghostty_external_io_result_e {
    guard let userdata else { return GHOSTTY_EXTERNAL_IO_INVALID }
    let box = Unmanaged<MacScopeGhosttyExternalIOBridge.CallbackBox>
        .fromOpaque(userdata).takeUnretainedValue()
    return macScopeGhosttyNativeResult(
        box.copyWrite(bytes.map(UnsafeRawPointer.init), count: count)
    )
}

private func macScopeGhosttyResizeCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ columns: UInt16,
    _ rows: UInt16,
    _ pixelWidth: UInt32,
    _ pixelHeight: UInt32
) {
    guard let userdata else { return }
    let box = Unmanaged<MacScopeGhosttyExternalIOBridge.CallbackBox>
        .fromOpaque(userdata).takeUnretainedValue()
    _ = box.proposeResize(.init(
        columns: Int(columns),
        rows: Int(rows),
        pixelWidth: Int(pixelWidth),
        pixelHeight: Int(pixelHeight)
    ))
}

private func macScopeGhosttyCloseCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ reason: ghostty_external_close_reason_e
) {
    guard let userdata else { return }
    let box = Unmanaged<MacScopeGhosttyExternalIOBridge.CallbackBox>
        .fromOpaque(userdata).takeUnretainedValue()
    let mapped: MacScopeGhosttyExternalIOBridge.CloseReason
    switch reason {
    case GHOSTTY_EXTERNAL_CLOSE_HOST_EXITED: mapped = .hostExited
    case GHOSTTY_EXTERNAL_CLOSE_HOST_SIGNALED: mapped = .hostSignaled
    case GHOSTTY_EXTERNAL_CLOSE_HOST_CLOSED: mapped = .hostClosed
    case GHOSTTY_EXTERNAL_CLOSE_SURFACE_REQUEST: mapped = .surfaceRequest
    default: return
    }
    _ = box.requestClose(mapped)
}

private func macScopeGhosttyHealthCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ event: ghostty_external_health_event_e,
    _ detail: UInt64
) {
    guard let userdata else { return }
    let box = Unmanaged<MacScopeGhosttyExternalIOBridge.CallbackBox>
        .fromOpaque(userdata).takeUnretainedValue()
    let mapped: MacScopeGhosttyExternalIOBridge.HealthEvent
    switch event {
    case GHOSTTY_EXTERNAL_HEALTH_FEED_READY: mapped = .feedReady
    case GHOSTTY_EXTERNAL_HEALTH_OUTPUT_BACKPRESSURED: mapped = .outputBackpressured
    case GHOSTTY_EXTERNAL_HEALTH_OUTPUT_OVERFLOW: mapped = .outputOverflow
    case GHOSTTY_EXTERNAL_HEALTH_OUTPUT_SUPPRESSED: mapped = .outputSuppressed
    default: return
    }
    _ = box.reportHealth(mapped, detail: detail)
}

private func macScopeGhosttyWakeupCallback(_ userdata: UnsafeMutableRawPointer?) {
    _ = MacScopeGhosttyLinkedRuntimeCallbackRegistry.productionShared.submitWakeup(
        userdata: userdata
    )
}

private struct MacScopeGhosttyTranslatedNativeAction {
    let action: MacScopeGhosttyAction
    let surfaceToken: UnsafeMutableRawPointer?
}

private func macScopeGhosttyTranslateAction(
    target: ghostty_target_s,
    action native: ghostty_action_s
) -> MacScopeGhosttyTranslatedNativeAction {
    let surfaceToken: UnsafeMutableRawPointer? = target.tag == GHOSTTY_TARGET_SURFACE
        ? target.target.surface
        : nil

    func application(
        _ action: MacScopeGhosttyApplicationAction
    ) -> MacScopeGhosttyTranslatedNativeAction {
        MacScopeGhosttyTranslatedNativeAction(
            action: .application(action),
            surfaceToken: nil
        )
    }

    func surface(_ action: MacScopeGhosttyAction) -> MacScopeGhosttyTranslatedNativeAction {
        guard let surfaceToken else { return application(.unsupportedNativeAction) }
        return MacScopeGhosttyTranslatedNativeAction(
            action: action,
            surfaceToken: surfaceToken
        )
    }

    switch native.tag {
    case GHOSTTY_ACTION_RENDER:
        return surface(.render)
    case GHOSTTY_ACTION_SET_TITLE:
        let value = macScopeGhosttyBoundedCString(
            native.action.set_title.title,
            maximumUTF8ByteCount: 4_096
        )
        return surface(.titleChanged(value))
    case GHOSTTY_ACTION_SET_TAB_TITLE:
        let value = macScopeGhosttyBoundedCString(
            native.action.set_tab_title.title,
            maximumUTF8ByteCount: 4_096
        )
        return surface(.titleChanged(value))
    case GHOSTTY_ACTION_PWD:
        let value = macScopeGhosttyBoundedCString(
            native.action.pwd.pwd,
            maximumUTF8ByteCount: 65_536
        )
        return surface(.workingDirectoryChanged(value))
    case GHOSTTY_ACTION_MOUSE_SHAPE:
        let style: MacScopeGhosttyPointerStyle = switch native.action.mouse_shape {
        case GHOSTTY_MOUSE_SHAPE_POINTER: .pointingHand
        case GHOSTTY_MOUSE_SHAPE_TEXT, GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: .text
        default: .arrow
        }
        return surface(.pointerChanged(style))
    case GHOSTTY_ACTION_MOUSE_VISIBILITY:
        let style: MacScopeGhosttyPointerStyle = native.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN
            ? .hidden
            : .arrow
        return surface(.pointerChanged(style))
    case GHOSTTY_ACTION_MOUSE_OVER_LINK:
        return surface(.pointerChanged(.pointingHand))
    case GHOSTTY_ACTION_RENDERER_HEALTH:
        let health: MacScopeGhosttyRendererHealth = native.action.renderer_health == GHOSTTY_RENDERER_HEALTH_HEALTHY
            ? .healthy
            : .unhealthy
        return surface(.rendererHealth(health))
    case GHOSTTY_ACTION_RING_BELL:
        return surface(.bell)
    case GHOSTTY_ACTION_SELECTION_CHANGED:
        return surface(.selectionChanged)
    case GHOSTTY_ACTION_CLOSE_WINDOW:
        return surfaceToken == nil ? application(.closeWindow) : surface(.closeSurface)
    case GHOSTTY_ACTION_OPEN_URL:
        // The callback carries no trustworthy human-activation provenance. Route the action with
        // terminal-program provenance so the MacScope policy rejects it instead of launching an
        // external application from terminal-controlled content.
        return surface(.activateHyperlink("", activation: .terminalProgram))
    case GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD:
        return surface(.osc52ClipboardControl)

    case GHOSTTY_ACTION_QUIT:
        return application(.quitApplication)
    case GHOSTTY_ACTION_NEW_WINDOW:
        return application(.newWindow)
    case GHOSTTY_ACTION_NEW_TAB:
        return application(.newTab)
    case GHOSTTY_ACTION_CLOSE_TAB:
        return application(.closeTab)
    case GHOSTTY_ACTION_NEW_SPLIT:
        switch native.action.new_split {
        case GHOSTTY_SPLIT_DIRECTION_LEFT, GHOSTTY_SPLIT_DIRECTION_RIGHT:
            return application(.splitVertical)
        case GHOSTTY_SPLIT_DIRECTION_UP, GHOSTTY_SPLIT_DIRECTION_DOWN:
            return application(.splitHorizontal)
        default:
            return application(.unsupportedNativeAction)
        }
    case GHOSTTY_ACTION_CLOSE_ALL_WINDOWS:
        return application(.closeWindow)
    case GHOSTTY_ACTION_CHECK_FOR_UPDATES:
        return application(.checkForUpdates)
    case GHOSTTY_ACTION_OPEN_CONFIG:
        return application(.openConfiguration)
    case GHOSTTY_ACTION_RELOAD_CONFIG, GHOSTTY_ACTION_CONFIG_CHANGE:
        return application(.reloadConfiguration)
    case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
        return application(.showNotification)

    case GHOSTTY_ACTION_TOGGLE_MAXIMIZE,
         GHOSTTY_ACTION_TOGGLE_FULLSCREEN,
         GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW,
         GHOSTTY_ACTION_TOGGLE_WINDOW_DECORATIONS,
         GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL,
         GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE,
         GHOSTTY_ACTION_TOGGLE_VISIBILITY,
         GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY,
         GHOSTTY_ACTION_MOVE_TAB,
         GHOSTTY_ACTION_GOTO_TAB,
         GHOSTTY_ACTION_GOTO_SPLIT,
         GHOSTTY_ACTION_GOTO_WINDOW,
         GHOSTTY_ACTION_RESIZE_SPLIT,
         GHOSTTY_ACTION_EQUALIZE_SPLITS,
         GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM,
         GHOSTTY_ACTION_PRESENT_TERMINAL,
         GHOSTTY_ACTION_SIZE_LIMIT,
         GHOSTTY_ACTION_RESET_WINDOW_SIZE,
         GHOSTTY_ACTION_INITIAL_SIZE,
         GHOSTTY_ACTION_CELL_SIZE,
         GHOSTTY_ACTION_SCROLLBAR,
         GHOSTTY_ACTION_INSPECTOR,
         GHOSTTY_ACTION_SHOW_GTK_INSPECTOR,
         GHOSTTY_ACTION_RENDER_INSPECTOR,
         GHOSTTY_ACTION_EXPORT_TERMINAL_IO,
         GHOSTTY_ACTION_PROMPT_TITLE,
         GHOSTTY_ACTION_QUIT_TIMER,
         GHOSTTY_ACTION_FLOAT_WINDOW,
         GHOSTTY_ACTION_SECURE_INPUT,
         GHOSTTY_ACTION_KEY_SEQUENCE,
         GHOSTTY_ACTION_KEY_TABLE,
         GHOSTTY_ACTION_COLOR_CHANGE,
         GHOSTTY_ACTION_UNDO,
         GHOSTTY_ACTION_REDO,
         GHOSTTY_ACTION_SHOW_CHILD_EXITED,
         GHOSTTY_ACTION_PROGRESS_REPORT,
         GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD,
         GHOSTTY_ACTION_COMMAND_FINISHED,
         GHOSTTY_ACTION_START_SEARCH,
         GHOSTTY_ACTION_END_SEARCH,
         GHOSTTY_ACTION_SEARCH_TOTAL,
         GHOSTTY_ACTION_SEARCH_SELECTED,
         GHOSTTY_ACTION_READONLY,
         GHOSTTY_ACTION_MOVE_TAB_TO_NEW_WINDOW:
        return application(.unsupportedNativeAction)
    default:
        return application(.unsupportedNativeAction)
    }
}

private func macScopeGhosttyActionCallback(
    _ app: ghostty_app_t?,
    _ target: ghostty_target_s,
    _ action: ghostty_action_s
) -> Bool {
    guard let app, let userdata = ghostty_app_userdata(app) else { return false }
    let translated = macScopeGhosttyTranslateAction(target: target, action: action)
    return MacScopeGhosttyLinkedRuntimeCallbackRegistry.productionShared.submit(
        translated.action,
        surfaceToken: translated.surfaceToken,
        userdata: userdata
    )
}

private func macScopeGhosttyRuntimeCloseCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ processAlive: Bool
) {
    _ = userdata
    _ = processAlive
    // External surfaces use the versioned close callback. The app-level callback is intentionally
    // inert so Ghostty cannot acquire application or child-process authority.
}

private final class MacScopeGhosttyLinkedHandleState: @unchecked Sendable {
    private let lock = NSLock()
    private let generation: MacScopeGhosttySurfaceGeneration
    private var retired = false
    private var surface: ghostty_surface_t?

    init(generation: MacScopeGhosttySurfaceGeneration) {
        self.generation = generation
    }

    @discardableResult
    func install(_ surface: ghostty_surface_t) -> Bool {
        lock.withLock {
            guard !retired, self.surface == nil else { return false }
            self.surface = surface
            return true
        }
    }

    var isPristine: Bool {
        lock.withLock { !retired && surface == nil }
    }

    func activeSurface(for candidate: MacScopeGhosttySurfaceGeneration) -> ghostty_surface_t? {
        lock.withLock {
            guard !retired, candidate == generation else { return nil }
            return surface
        }
    }

    @discardableResult
    func retire(_ candidate: MacScopeGhosttySurfaceGeneration) -> Bool {
        lock.withLock {
            guard !retired, candidate == generation else { return false }
            retired = true
            return true
        }
    }

    func takeSurfaceForDestruction() -> ghostty_surface_t? {
        lock.withLock {
            let value = surface
            surface = nil
            return value
        }
    }
}

/// Narrow AppKit/C adapter. It owns renderer objects only; ShellBroker remains the sole process
/// and PTY authority and supplies both feed bytes and process-state evidence through typed calls.
@MainActor
private final class MacScopeGhosttyLinkedSurfaceBackend: MacScopeGhosttySurfaceBackend,
    @unchecked Sendable
{
    private let generation: MacScopeGhosttySurfaceGeneration
    private let handles: MacScopeGhosttyLinkedHandleState
    private let runtimeRegistry = MacScopeGhosttyLinkedRuntimeCallbackRegistry.productionShared
    private var bridge: MacScopeGhosttyExternalIOBridge?
    private var runtimeRegistration: MacScopeGhosttyLinkedRuntimeCallbackRegistry.Registration?
    private var app: ghostty_app_t?
    private weak var hostView: MacScopeGhosttySurfaceHostView?
    private var titleMetadata = ""
    private var workingDirectoryMetadata = ""
    private var cursorIsHidden = false
    /// Theme tracking: the terminal follows MacScope's editor theme, Light/Dark and Increase
    /// Contrast by pushing a color-only configuration (`ghostty_app_update_config`).
    private var themeObserver: NSObjectProtocol?
    private var appearanceObservation: NSKeyValueObservation?
    private var appliedThemePalette: TerminalThemePalette?

    init(
        generation: MacScopeGhosttySurfaceGeneration,
        workHandler: @escaping MacScopeGhosttyExternalIOBridge.Handler
    ) {
        self.generation = generation
        let handles = MacScopeGhosttyLinkedHandleState(generation: generation)
        self.handles = handles
        bridge = MacScopeGhosttyExternalIOBridge(
            generation: generation,
            writeCapacityRecovered: { candidate in
                guard let surface = handles.activeSurface(for: candidate) else { return }
                // The external-I/O ABI retains rejected output until the host announces newly
                // available callback capacity with a zero-byte feed. Bridge retirement fences
                // this hook before native destruction; the exact-generation handle rejects stale
                // or replacement work.
                _ = ghostty_surface_external_feed(surface, nil, 0)
            },
            handler: workHandler
        )
    }

    func attach(to hostView: MacScopeGhosttySurfaceHostView) throws {
        guard app == nil else { throw MacScopeGhosttyLinkedSurfaceError.alreadyAttached }
        guard let bridge, handles.isPristine else {
            throw MacScopeGhosttyLinkedSurfaceError.retired
        }

        let registration = runtimeRegistry.pin(generation: generation)
        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = registration.userdata
        runtimeConfig.wakeup_cb = macScopeGhosttyWakeupCallback
        runtimeConfig.action_cb = macScopeGhosttyActionCallback
        runtimeConfig.close_surface_cb = macScopeGhosttyRuntimeCloseCallback

        let initialPalette = TerminalThemePalette(appearance: LumenAppearance(hostView.effectiveAppearance))
        let configuration = Self.themedConfiguration(initialPalette)
        guard let newApp = ghostty_app_new(&runtimeConfig, configuration) else {
            ghostty_config_free(configuration)
            runtimeRegistry.retireAndUnpin(registration)
            throw MacScopeGhosttyLinkedSurfaceError.applicationCreationFailed
        }
        ghostty_config_free(configuration)

        var externalConfig = ghostty_external_io_config_s(
            struct_size: MemoryLayout<ghostty_external_io_config_s>.size,
            abi_version: UInt32(GHOSTTY_EXTERNAL_IO_ABI_VERSION),
            userdata: Unmanaged.passUnretained(bridge.callbackBox).toOpaque(),
            write_cb: macScopeGhosttyWriteCallback,
            resize_cb: macScopeGhosttyResizeCallback,
            close_cb: macScopeGhosttyCloseCallback,
            health_cb: macScopeGhosttyHealthCallback
        )
        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform.macos.nsview = Unmanaged.passUnretained(hostView).toOpaque()

        guard let surface = ghostty_surface_new_external(
            newApp,
            &surfaceConfig,
            &externalConfig
        ) else {
            runtimeRegistry.retireAndUnpin(registration)
            ghostty_app_free(newApp)
            throw MacScopeGhosttyLinkedSurfaceError.externalSurfaceCreationFailed
        }
        guard ghostty_surface_is_external_io(surface) else {
            runtimeRegistry.retireAndUnpin(registration)
            ghostty_surface_free(surface)
            ghostty_app_free(newApp)
            throw MacScopeGhosttyLinkedSurfaceError.externalSurfaceVerificationFailed
        }

        guard runtimeRegistry.install(
            registration,
            surfaceToken: surface,
            handler: { [weak self] callbackGeneration, intents in
                guard let self, self.generation == callbackGeneration else { return }
                self.perform(intents)
            }
        ) else {
            runtimeRegistry.retireAndUnpin(registration)
            ghostty_surface_free(surface)
            ghostty_app_free(newApp)
            throw MacScopeGhosttyLinkedSurfaceError.externalSurfaceVerificationFailed
        }

        guard handles.install(surface) else {
            runtimeRegistry.retireAndUnpin(registration)
            ghostty_surface_free(surface)
            ghostty_app_free(newApp)
            throw MacScopeGhosttyLinkedSurfaceError.retired
        }

        app = newApp
        runtimeRegistration = registration
        self.hostView = hostView
        appliedThemePalette = initialPalette
        startThemeTracking(hostView: hostView)
        ghostty_app_set_focus(newApp, NSApp.isActive)
    }

    /// A color-only Ghostty configuration: foreground, background, cursor and ANSI 0–15. It
    /// carries no process, I/O or resource settings, so the GST-01 authority boundaries are
    /// unchanged. Ghostty loads configuration only from files, so the lines are written to a
    /// per-process temporary file; if that fails, Ghostty's defaults apply.
    private static func themedConfiguration(_ palette: TerminalThemePalette) -> ghostty_config_t? {
        let configuration = ghostty_config_new()
        let url = FileManager.default.temporaryDirectory
            .appending(path: "MacScopeGhosttyTheme-\(ProcessInfo.processInfo.processIdentifier).conf")
        if (try? palette.ghosttyConfiguration.write(to: url, atomically: true, encoding: .utf8)) != nil {
            url.path(percentEncoded: false).withCString { ghostty_config_load_file(configuration, $0) }
        }
        ghostty_config_finalize(configuration)
        return configuration
    }

    private func startThemeTracking(hostView: MacScopeGhosttySurfaceHostView) {
        themeObserver = NotificationCenter.default.addObserver(
            forName: DSThemeStore.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyCurrentTheme() }
        }
        appearanceObservation = hostView.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.applyCurrentTheme() }
        }
    }

    private func stopThemeTracking() {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
        themeObserver = nil
        appearanceObservation?.invalidate()
        appearanceObservation = nil
    }

    private func applyCurrentTheme() {
        guard let app, let hostView else { return }
        let palette = TerminalThemePalette(appearance: LumenAppearance(hostView.effectiveAppearance))
        guard palette != appliedThemePalette else { return }
        let configuration = Self.themedConfiguration(palette)
        ghostty_app_update_config(app, configuration)
        ghostty_config_free(configuration)
        appliedThemePalette = palette
    }

    func handle(hostEvent: MacScopeGhosttySurfaceHostEvent) -> Bool {
        guard let app, let surface = handles.activeSurface(for: generation) else { return false }
        switch hostEvent {
        case .draw:
            ghostty_surface_draw(surface)
            return true
        case .wakeup:
            ghostty_app_tick(app)
            return true
        case let .focus(focused):
            ghostty_surface_set_focus(surface, focused)
            ghostty_app_set_focus(app, focused)
            ghostty_app_tick(app)
            return true
        case let .key(input):
            return macScopeGhosttySendKey(surface, input: input, action: input.isRepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
        case let .modifierFlagsChanged(input):
            guard let action = macScopeGhosttyModifierAction(input) else { return false }
            return macScopeGhosttySendKey(surface, input: input, action: action)
        case let .text(value, _):
            return macScopeGhosttyWithCString(value) { pointer, length in
                ghostty_surface_text(surface, pointer, length)
                return true
            }
        case let .preedit(value, _, _):
            return macScopeGhosttyWithCString(value) { pointer, length in
                ghostty_surface_preedit(surface, pointer, length)
                return true
            }
        case .unmarkText:
            ghostty_surface_preedit(surface, nil, 0)
            return true
        case .command:
            // Selector-to-keybinding translation is intentionally not guessed at this boundary.
            return false
        case let .pointer(input):
            macScopeGhosttySendPointer(surface, input: input, height: hostView?.bounds.height ?? 0)
            switch input.phase {
            case .entered, .exited, .moved, .dragged:
                return true
            case .pressed, .released:
                return macScopeGhosttySendButton(surface, input: input)
            }
        case let .scroll(input):
            let multiplier = input.hasPreciseDeltas ? 2.0 : 1.0
            let scrollMods = macScopeGhosttyScrollMods(input)
            ghostty_surface_mouse_scroll(
                surface,
                Double(input.deltaX) * multiplier,
                Double(input.deltaY) * multiplier,
                scrollMods
            )
            return true
        case .selection(.copy):
            return ghostty_surface_has_selection(surface)
        case .selection:
            // The reviewed header has no select-all/clear-selection surface operation.
            return false
        case let .paste(value):
            return macScopeGhosttyWithCString(value) { pointer, length in
                ghostty_surface_text(surface, pointer, length)
                return true
            }
        case let .resize(size, backingScale):
            guard let width = macScopeGhosttyPixelDimension(
                size.width,
                backingScale: backingScale
            ), let height = macScopeGhosttyPixelDimension(
                size.height,
                backingScale: backingScale
            ) else { return false }
            let scale = min(max(1, backingScale), 16)
            ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
            ghostty_surface_set_size(surface, width, height)
            return true
        case let .display(_, displayID):
            if let displayID { ghostty_surface_set_display_id(surface, displayID) }
            return true
        case let .occlusion(isVisible):
            ghostty_surface_set_occlusion(surface, !isVisible)
            return true
        }
    }

    func selectedText() -> String? {
        guard let surface = handles.activeSurface(for: generation) else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard text.text_len > 0,
              text.text_len <= 4 << 20,
              let pointer = text.text
        else { return nil }
        let bytes = Data(bytes: pointer, count: Int(text.text_len))
        return String(decoding: bytes, as: UTF8.self)
    }

    func textInputRect() -> NSRect? {
        guard let surface = handles.activeSurface(for: generation),
              let hostView else { return nil }
        var x = 0.0
        var y = 0.0
        var width = 0.0
        var height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        return NSRect(
            x: x,
            y: hostView.bounds.height - y - height,
            width: max(0, width),
            height: max(0, height)
        )
    }

    nonisolated func feed(
        _ bytes: Data,
        generation candidate: MacScopeGhosttySurfaceGeneration
    ) -> MacScopeGhosttySurfaceFeedAdmission {
        guard let surface = handles.activeSurface(for: candidate) else { return .closed }
        return bytes.withUnsafeBytes { rawBuffer in
            let pointer = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return macScopeGhosttyFeedAdmission(
                ghostty_surface_external_feed(surface, pointer, rawBuffer.count)
            )
        }
    }

    nonisolated func setProcessState(
        _ state: MacScopeGhosttySurfaceProcessState,
        generation candidate: MacScopeGhosttySurfaceGeneration
    ) -> MacScopeGhosttySurfaceFeedAdmission {
        guard let surface = handles.activeSurface(for: candidate) else { return .closed }
        var native = ghostty_external_process_state_s()
        native.struct_size = MemoryLayout<ghostty_external_process_state_s>.size
        native.abi_version = UInt32(GHOSTTY_EXTERNAL_IO_ABI_VERSION)
        switch state {
        case .running:
            native.state = Int32(bitPattern: GHOSTTY_EXTERNAL_PROCESS_RUNNING.rawValue)
        case let .exited(status):
            native.state = Int32(bitPattern: GHOSTTY_EXTERNAL_PROCESS_EXITED.rawValue)
            native.exit_code = UInt32(bitPattern: status)
        case let .signaled(signal):
            native.state = Int32(bitPattern: GHOSTTY_EXTERNAL_PROCESS_SIGNALED.rawValue)
            native.signal = signal
        case .closed:
            native.state = Int32(bitPattern: GHOSTTY_EXTERNAL_PROCESS_CLOSED.rawValue)
        }
        return macScopeGhosttyFeedAdmission(
            ghostty_surface_external_set_process_state(surface, &native)
        )
    }

    func retire(generation candidate: MacScopeGhosttySurfaceGeneration) {
        guard handles.retire(candidate) else { return }
        retireRuntimeCallbacks()
        _ = bridge?.retire(generation: candidate)
    }

    func stopFeed() {
        if handles.retire(generation) {
            retireRuntimeCallbacks()
        }
    }

    func invalidateCallbacks() {
        bridge?.invalidateCallbacks()
    }

    func detachDisplayAndWakeup() {
        stopThemeTracking()
        retireRuntimeCallbacks()
        if cursorIsHidden {
            NSCursor.unhide()
            cursorIsHidden = false
        }
        hostView = nil
    }

    func destroySurface() {
        if let surface = handles.takeSurfaceForDestruction() {
            ghostty_surface_free(surface)
        }
        stopThemeTracking()
        if let app {
            ghostty_app_free(app)
            self.app = nil
        }
    }

    func releaseBridgeBox() {
        bridge = nil
        runtimeRegistration = nil
    }

    private func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    private func retireRuntimeCallbacks() {
        guard let runtimeRegistration else { return }
        runtimeRegistry.retireAndUnpin(runtimeRegistration)
    }

    private func perform(_ intents: [MacScopeGhosttyActionRouter.Intent]) {
        guard handles.activeSurface(for: generation) != nil else { return }

        for intent in intents {
            guard handles.activeSurface(for: generation) != nil else { return }
            switch intent {
            case .scheduleRender:
                hostView?.requestRender()
            case .wakeup:
                tick()
            case .selectionChanged:
                hostView?.requestRender()
            case let .pointerChanged(style):
                applyPointerStyle(style)
            case let .updateTitleMetadata(value):
                titleMetadata = value
            case let .updateWorkingDirectoryMetadata(value):
                workingDirectoryMetadata = value
            case .bell:
                NSSound.beep()
            case .requestClose:
                _ = bridge?.callbackBox.requestClose(.surfaceRequest)
            case .activateHyperlink:
                // Native open-URL actions are routed with terminal-program provenance and denied
                // before reaching this executor. The adapter never launches another process.
                break
            case let .rendererHealth(health):
                if health == .unhealthy {
                    MacScopeGhosttyRuntime.productionShared.recordHealthFailure()
                }
            }
        }
    }

    private func applyPointerStyle(_ style: MacScopeGhosttyPointerStyle) {
        if style == .hidden {
            if !cursorIsHidden {
                NSCursor.hide()
                cursorIsHidden = true
            }
            return
        }

        if cursorIsHidden {
            NSCursor.unhide()
            cursorIsHidden = false
        }
        switch style {
        case .arrow:
            NSCursor.arrow.set()
        case .text:
            NSCursor.iBeam.set()
        case .pointingHand:
            NSCursor.pointingHand.set()
        case .hidden:
            break
        }
    }
}

private func macScopeGhosttyWithCString<T>(
    _ value: String,
    _ body: (UnsafePointer<CChar>, UInt) -> T
) -> T {
    value.withCString { pointer in body(pointer, UInt(value.utf8.count)) }
}

private func macScopeGhosttyBoundedCString(
    _ pointer: UnsafePointer<CChar>?,
    maximumUTF8ByteCount: Int
) -> String {
    guard let pointer, maximumUTF8ByteCount > 0 else { return "" }
    let count = strnlen(pointer, maximumUTF8ByteCount)
    let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
    return String(
        decoding: UnsafeBufferPointer(start: bytes, count: count),
        as: UTF8.self
    )
}

private func macScopeGhosttyPixelDimension(
    _ logicalDimension: CGFloat,
    backingScale: CGFloat
) -> UInt32? {
    guard logicalDimension.isFinite,
          logicalDimension >= 0,
          backingScale.isFinite,
          backingScale >= 1,
          backingScale <= 16
    else { return nil }
    let pixels = logicalDimension * backingScale
    guard pixels.isFinite, pixels <= 1_048_576 else { return nil }
    return UInt32(pixels.rounded(.towardZero))
}

private func macScopeGhosttyMods(_ flags: UInt) -> ghostty_input_mods_e {
    var mods = GHOSTTY_MODS_NONE.rawValue
    let nsFlags = NSEvent.ModifierFlags(rawValue: flags)
    if nsFlags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
    if nsFlags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
    if nsFlags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
    if nsFlags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
    if nsFlags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
    if flags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
    if flags & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
    if flags & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
    if flags & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
    return ghostty_input_mods_e(mods)
}

private func macScopeGhosttySendKey(
    _ surface: ghostty_surface_t,
    input: MacScopeGhosttyKeyInput,
    action: ghostty_input_action_e
) -> Bool {
    var key = ghostty_input_key_s()
    key.action = action
    key.keycode = UInt32(input.keyCode)
    key.mods = macScopeGhosttyMods(input.modifierFlags)
    key.consumed_mods = macScopeGhosttyMods(input.modifierFlags & ~UInt(NSEvent.ModifierFlags.control.rawValue | NSEvent.ModifierFlags.command.rawValue))
    key.unshifted_codepoint = input.charactersIgnoringModifiers?.unicodeScalars.first?.value ?? 0
    guard let text = input.characters, let scalar = text.unicodeScalars.first,
          scalar.value >= 0x20 else {
        return ghostty_surface_key(surface, key)
    }
    return text.withCString { pointer in
        key.text = pointer
        return ghostty_surface_key(surface, key)
    }
}

private func macScopeGhosttyModifierAction(
    _ input: MacScopeGhosttyKeyInput
) -> ghostty_input_action_e? {
    let modifier: UInt32
    switch input.keyCode {
    case 0x39: modifier = GHOSTTY_MODS_CAPS.rawValue
    case 0x38, 0x3C: modifier = GHOSTTY_MODS_SHIFT.rawValue
    case 0x3B, 0x3E: modifier = GHOSTTY_MODS_CTRL.rawValue
    case 0x3A, 0x3D: modifier = GHOSTTY_MODS_ALT.rawValue
    case 0x37, 0x36: modifier = GHOSTTY_MODS_SUPER.rawValue
    default: return nil
    }
    let active = macScopeGhosttyMods(input.modifierFlags).rawValue & modifier != 0
    return active ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
}

private func macScopeGhosttySendPointer(
    _ surface: ghostty_surface_t,
    input: MacScopeGhosttyPointerInput,
    height: CGFloat
) {
    let y = input.phase == .exited ? -1.0 : Double(height) - Double(input.location.y)
    ghostty_surface_mouse_pos(
        surface,
        input.phase == .exited ? -1 : Double(input.location.x),
        y,
        macScopeGhosttyMods(input.modifierFlags)
    )
}

private func macScopeGhosttySendButton(
    _ surface: ghostty_surface_t,
    input: MacScopeGhosttyPointerInput
) -> Bool {
    let state: ghostty_input_mouse_state_e = input.phase == .pressed
        ? GHOSTTY_MOUSE_PRESS
        : GHOSTTY_MOUSE_RELEASE
    let button: ghostty_input_mouse_button_e
    switch input.button {
    case .left: button = GHOSTTY_MOUSE_LEFT
    case .right: button = GHOSTTY_MOUSE_RIGHT
    case .middle: button = GHOSTTY_MOUSE_MIDDLE
    case .other, .none: button = GHOSTTY_MOUSE_UNKNOWN
    }
    return ghostty_surface_mouse_button(surface, state, button, macScopeGhosttyMods(input.modifierFlags))
}

private func macScopeGhosttyScrollMods(
    _ input: MacScopeGhosttyScrollInput
) -> ghostty_input_scroll_mods_t {
    let precision: Int32 = input.hasPreciseDeltas ? 1 : 0
    let momentum = Int32(input.momentumPhaseRawValue & 0b111) << 1
    return precision | momentum
}
#endif
