import SwiftUI

/// Small SwiftUI boundary for the AppKit/Metal terminal host.
///
/// The default factory returns `nil`, which keeps this source compilable when GhosttyKit is not
/// linked. The feature/runtime integration lane supplies a factory only after its centralized
/// compile-time and startup-frozen availability checks pass.
@MainActor
struct MacScopeGhosttySurfaceRepresentable: NSViewRepresentable {
    typealias NSViewType = MacScopeGhosttySurfaceHostView
    typealias BackendFactory = @MainActor (
        MacScopeGhosttySurfaceGeneration
    ) -> (any MacScopeGhosttySurfaceBackend)?
    typealias AvailabilityCallback = @MainActor (Bool) -> Void

    let generation: MacScopeGhosttySurfaceGeneration
    let backendFactory: BackendFactory
    let availabilityChanged: AvailabilityCallback

    init(
        generation: MacScopeGhosttySurfaceGeneration,
        backendFactory: @escaping BackendFactory = { _ in nil },
        availabilityChanged: @escaping AvailabilityCallback = { _ in }
    ) {
        self.generation = generation
        self.backendFactory = backendFactory
        self.availabilityChanged = availabilityChanged
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MacScopeGhosttySurfaceHostView {
        let hostView = MacScopeGhosttySurfaceHostView(frame: .zero)
        context.coordinator.reconcile(
            hostView: hostView,
            generation: generation,
            backendFactory: backendFactory,
            availabilityChanged: availabilityChanged
        )
        return hostView
    }

    func updateNSView(
        _ hostView: MacScopeGhosttySurfaceHostView,
        context: Context
    ) {
        context.coordinator.reconcile(
            hostView: hostView,
            generation: generation,
            backendFactory: backendFactory,
            availabilityChanged: availabilityChanged
        )
    }

    static func dismantleNSView(
        _ hostView: MacScopeGhosttySurfaceHostView,
        coordinator: Coordinator
    ) {
        coordinator.dismantle(hostView: hostView)
    }

    @MainActor
    final class Coordinator: MacScopeGhosttySurfaceHostLifecycleSink {
        private final class RequestIdentity {}

        private struct Request {
            let identity: RequestIdentity
            let generation: MacScopeGhosttySurfaceGeneration
            let backendFactory: BackendFactory
            let availabilityChanged: AvailabilityCallback
        }

        private struct ReconcileInput {
            let hostView: MacScopeGhosttySurfaceHostView
            let generation: MacScopeGhosttySurfaceGeneration
            let backendFactory: BackendFactory
            let availabilityChanged: AvailabilityCallback
        }

        private struct AvailabilityPublication: Equatable {
            let generation: MacScopeGhosttySurfaceGeneration
            let isAvailable: Bool
        }

        private struct PendingAvailability {
            let requestIdentity: RequestIdentity
            let hostView: MacScopeGhosttySurfaceHostView
            let publication: AvailabilityPublication
            let callback: AvailabilityCallback
        }

        private var active: MacScopeGhosttySurfaceCoordinator?
        private var retiring: MacScopeGhosttySurfaceCoordinator?
        private weak var hostView: MacScopeGhosttySurfaceHostView?
        private var request: Request?
        private var requestWasAttempted = false
        private var generationHighWater: UInt64 = 0
        private var pendingReconcile: ReconcileInput?
        private var isReconciling = false
        private var pendingAvailability: PendingAvailability?
        private var availabilityTurnScheduled = false
        private var lastAvailability: AvailabilityPublication?
        private var isDismantled = false

        func reconcile(
            hostView: MacScopeGhosttySurfaceHostView,
            generation: MacScopeGhosttySurfaceGeneration,
            backendFactory: @escaping BackendFactory,
            availabilityChanged: @escaping AvailabilityCallback
        ) {
            guard !isDismantled else { return }
            // SwiftUI, backend factories, native attach, teardown, and availability observers can
            // all synchronously reenter this boundary. Retain only the latest input and drain it
            // after the current ownership transaction completes.
            let input = ReconcileInput(
                hostView: hostView,
                generation: generation,
                backendFactory: backendFactory,
                availabilityChanged: availabilityChanged
            )
            if let pendingReconcile {
                guard generation.generation >= pendingReconcile.generation.generation else {
                    return
                }
                guard generation.generation != pendingReconcile.generation.generation
                        || generation == pendingReconcile.generation
                else {
                    // A monotonic generation value identifies one coordinate. Conflicting reuse
                    // is invalid and must not replace the already queued authority.
                    return
                }
            }
            pendingReconcile = input
            drainPendingReconcile()
        }

        private func drainPendingReconcile() {
            guard !isReconciling, !isDismantled else { return }
            isReconciling = true
            defer { isReconciling = false }

            while !isDismantled, let input = pendingReconcile {
                pendingReconcile = nil
                performReconcile(input)
            }
        }

        private func performReconcile(_ input: ReconcileInput) {
            guard !isDismantled else { return }

            let repeatsCurrentRequest = request?.generation == input.generation
                && self.hostView === input.hostView
            let updatesCurrentBinding = active?.generation == input.generation
                && self.hostView === input.hostView
            guard updatesCurrentBinding
                    || repeatsCurrentRequest
                    || input.generation.generation > generationHighWater
            else {
                // Surface generations come from one monotonic allocator across session/request
                // replacements. A delayed, never-before-observed coordinate below the high-water
                // is just as stale as an exact replay and must remain inert.
                return
            }
            generationHighWater = max(generationHighWater, input.generation.generation)

            if let currentHost = self.hostView, currentHost !== input.hostView {
                retireActive()
                currentHost.removeLifecycleSink(self)
                currentHost.prepareForDismantle()
                self.hostView = nil
            }

            let preservesAttemptState = repeatsCurrentRequest
            let nextRequest = Request(
                identity: RequestIdentity(),
                generation: input.generation,
                backendFactory: input.backendFactory,
                availabilityChanged: input.availabilityChanged
            )
            request = nextRequest
            requestWasAttempted = preservesAttemptState && requestWasAttempted

            if self.hostView !== input.hostView {
                guard input.hostView.installLifecycleSink(self) else {
                    requestWasAttempted = true
                    scheduleAvailability(
                        false,
                        request: nextRequest,
                        hostView: input.hostView
                    )
                    return
                }
                self.hostView = input.hostView
            }

            // A valid replacement closes the prior generation immediately even if AppKit has not
            // attached the new host to a window yet. Same-generation transient window moves retain
            // their native surface and simply close feed/render admission while detached.
            if let active, active.generation != input.generation {
                retireActive()
            }
            activateIfPossible()
        }

        func ghosttyHostViewDidAttachToWindow(_ hostView: MacScopeGhosttySurfaceHostView) {
            guard !isDismantled,
                  self.hostView === hostView,
                  let request
            else { return }
            reconcile(
                hostView: hostView,
                generation: request.generation,
                backendFactory: request.backendFactory,
                availabilityChanged: request.availabilityChanged
            )
        }

        private func activateIfPossible() {
            guard !isDismantled,
                  let request,
                  let hostView,
                  hostView.window != nil
            else { return }

            if let pendingReconcile,
               pendingReconcile.generation.generation > request.generation.generation {
                return
            }

            if let active,
               active.generation == request.generation,
               active.isAttached(to: hostView)
            {
                active.requestRender()
                scheduleAvailability(
                    true,
                    request: request,
                    hostView: hostView
                )
                return
            }

            guard retiring == nil else { return }

            guard !requestWasAttempted else {
                scheduleAvailability(
                    false,
                    request: request,
                    hostView: hostView
                )
                return
            }

            if active != nil {
                retireActive()
                guard retiring == nil else { return }
            }

            requestWasAttempted = true

            guard let backend = request.backendFactory(request.generation) else {
                scheduleAvailability(
                    false,
                    request: request,
                    hostView: hostView
                )
                return
            }

            let coordinator = MacScopeGhosttySurfaceCoordinator(
                generation: request.generation,
                backend: backend
            )
            guard !isDismantled,
                  self.request?.identity === request.identity,
                  self.hostView === hostView,
                  hostView.window != nil,
                  !hasNewerPendingRequest(than: request.generation)
            else {
                coordinator.shutdown()
                return
            }
            do {
                try coordinator.attach(to: hostView)
                guard !isDismantled,
                      self.request?.identity === request.identity,
                      self.hostView === hostView,
                      hostView.window != nil,
                      retiring == nil,
                      !hasNewerPendingRequest(than: request.generation),
                      coordinator.isAttached(to: hostView)
                else {
                    coordinator.shutdown()
                    return
                }
                active = coordinator
                scheduleAvailability(
                    true,
                    request: request,
                    hostView: hostView
                )
                coordinator.requestRender()
            } catch {
                coordinator.shutdown()
                if !isDismantled,
                   self.request?.identity === request.identity,
                   self.hostView === hostView {
                    scheduleAvailability(false, request: request, hostView: hostView)
                }
            }
        }

        func dismantle(hostView: MacScopeGhosttySurfaceHostView) {
            guard !isDismantled else { return }
            isDismantled = true
            pendingReconcile = nil
            pendingAvailability = nil
            request = nil
            let boundHost = self.hostView
            boundHost?.removeLifecycleSink(self)
            retireActive()
            boundHost?.prepareForDismantle()
            if boundHost !== hostView {
                hostView.prepareForDismantle()
            }
            self.hostView = nil
            lastAvailability = nil
        }

        /// Neutral submission seam for SwiftUI integration after transcript admission.
        func feed(
            _ bytes: Data,
            generation: MacScopeGhosttySurfaceGeneration
        ) -> MacScopeGhosttySurfaceFeedAdmission {
            guard let active,
                  active.generation == generation,
                  let hostView,
                  active.isAttached(to: hostView)
            else { return .closed }
            return active.feed(bytes, for: generation)
        }

        /// Neutral lifecycle seam; the renderer never receives a process handle or PTY authority.
        func setProcessState(
            _ state: MacScopeGhosttySurfaceProcessState,
            generation: MacScopeGhosttySurfaceGeneration
        ) -> MacScopeGhosttySurfaceFeedAdmission {
            guard let active,
                  active.generation == generation,
                  let hostView,
                  active.isAttached(to: hostView)
            else { return .closed }
            return active.setProcessState(state, for: generation)
        }

        /// Broker-free qualification seam used to prove replacement and deferred teardown. The
        /// production feed path remains the exact-generation `feed` method above.
        func admitFixture(
            _ fixture: MacScopeGhosttySurfaceFixture,
            generation: MacScopeGhosttySurfaceGeneration,
            completion: @escaping @Sendable (MacScopeGhosttyFixtureAdmission) -> Void
        ) {
            guard let active,
                  active.generation == generation,
                  let hostView,
                  active.isAttached(to: hostView)
            else {
                completion(.rejected(.staleOrRetiredGeneration))
                return
            }
            active.admitFixture(fixture, for: generation, completion: completion)
        }

        private func retireActive() {
            guard let retiringCoordinator = active else { return }
            active = nil
            precondition(retiring == nil, "multiple Ghostty coordinators retiring for one host")
            retiring = retiringCoordinator
            retiringCoordinator.shutdown { [weak self, weak retiringCoordinator] in
                guard let self, let retiringCoordinator else { return }
                self.retirementDidFinish(retiringCoordinator)
            }
        }

        private func retirementDidFinish(
            _ retiredCoordinator: MacScopeGhosttySurfaceCoordinator
        ) {
            guard retiring === retiredCoordinator else { return }
            retiring = nil
            guard !isDismantled, !isReconciling, let request, let hostView else { return }
            reconcile(
                hostView: hostView,
                generation: request.generation,
                backendFactory: request.backendFactory,
                availabilityChanged: request.availabilityChanged
            )
        }

        private func hasNewerPendingRequest(
            than generation: MacScopeGhosttySurfaceGeneration
        ) -> Bool {
            (pendingReconcile?.generation.generation ?? 0) > generation.generation
        }

        private func scheduleAvailability(
            _ value: Bool,
            request: Request,
            hostView: MacScopeGhosttySurfaceHostView
        ) {
            let publication = AvailabilityPublication(
                generation: request.generation,
                isAvailable: value
            )
            guard lastAvailability != publication else { return }
            pendingAvailability = PendingAvailability(
                requestIdentity: request.identity,
                hostView: hostView,
                publication: publication,
                callback: request.availabilityChanged
            )
            guard !availabilityTurnScheduled else { return }
            availabilityTurnScheduled = true
            Task { @MainActor [weak self] in
                self?.deliverPendingAvailability()
            }
        }

        private func deliverPendingAvailability() {
            availabilityTurnScheduled = false
            guard !isDismantled, let pending = pendingAvailability else {
                pendingAvailability = nil
                return
            }
            pendingAvailability = nil
            guard let request,
                  request.identity === pending.requestIdentity,
                  request.generation == pending.publication.generation
            else { return }

            if pending.publication.isAvailable {
                guard hostView === pending.hostView,
                      let active,
                      active.generation == pending.publication.generation,
                      active.isAttached(to: pending.hostView)
                else { return }
            } else if let active,
                      active.generation == pending.publication.generation,
                      active.isAttached(to: pending.hostView) {
                return
            }

            guard lastAvailability != pending.publication else { return }
            lastAvailability = pending.publication
            pending.callback(pending.publication.isAvailable)
        }
    }
}
