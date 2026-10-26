import Combine
import Darwin
import Foundation

/// Lets MCP agents attach to open workspace windows (Settings ▸ Plugins ▸ "Allow agents to
/// attach", off by default). State machine per connection: authenticating (off main) → pending
/// consent → authorized → revoked/closed.
///
/// - **Endpoint:** `MCPAttachSocket.EndpointOwner` (flock-serialized single owner, 0700 directory,
///   0600 socket, per-launch token). Turning the setting off or quitting releases it.
/// - **Authentication:** mutual HMAC handshake on a background thread, bounded by a 5 s socket
///   timeout; a peer that is not this user or cannot prove the token is closed before anything
///   is bound or shown.
/// - **Grant:** pinned at the handshake to one window (an opaque id per registered store) and its
///   document generation (`workspaceID` + primary image id). It never migrates: Deny, Disconnect,
///   window close, document replacement, toggle-off and quit revoke it, and a late Allow for a
///   retired connection does nothing.
/// - **Budgets:** `maximumConnections` app-wide, one pending prompt per window, prompts expire
///   after `consentTimeout`, 10 s write-progress timeout per socket, MCPServer limits per request.
@MainActor
final class MCPAttachCoordinator: ObservableObject {
    static let enabledDefaultsKey = "MCPAttachEnabled"
    static let shared = MCPAttachCoordinator()
    nonisolated static let maximumConnections = 4
    static let handshakeTimeoutSeconds = 5
    static let writeTimeoutSeconds = 10

    /// The document as installed in the window. `installationID` changes on every installation
    /// (restore, reopen, fork, import), even when the persisted workspace and image IDs are the
    /// same, so a grant never survives reopening the same document (DP09-2 N1).
    struct DocumentGeneration: Equatable {
        let installationID: UUID
        let workspaceID: UUID
        let primaryImageID: UUID?
    }

    struct Connection: Identifiable {
        let id = UUID()
        let windowID: UUID
        weak var store: WorkspaceStore?
        /// The label shown in the trusted banner, read from the window itself (never the client).
        let workspaceName: String
        let generation: DocumentGeneration
        var consent: MCPAttachExecutor.Consent
        fileprivate let descriptor: Int32
        fileprivate let executor: MCPAttachExecutor
    }

    private struct Window {
        let id: UUID
        weak var store: WorkspaceStore?
        var lastActive: UInt64
    }

    @Published private(set) var connections: [Connection] = []
    @Published private(set) var listenerError: String?
    private(set) var isListening = false

    let directory: URL
    let consentTimeout: Duration
    private let defaults: UserDefaults
    private var windows: [ObjectIdentifier: Window] = [:]
    /// Revokes a window's grants the moment its document installation changes, so a pending or
    /// in-flight request is cancelled then rather than at its next grant check.
    private var installationObservers: [ObjectIdentifier: AnyCancellable] = [:]
    private var owner: MCPAttachSocket.EndpointOwner?
    private let instance = UUID().uuidString
    /// Every connection, from accept through authentication, consent and use, holds one of
    /// `maximumConnections` slots. Reserved on the accept thread before any per-connection thread
    /// exists, released when the socket is closed (DP09-2 N4).
    nonisolated let slots = MCPAttachAdmission(limit: MCPAttachCoordinator.maximumConnections)
    /// Advances on every start and stop, so a handshake that began under an earlier listener (and
    /// its token) can never bind to a later one.
    private(set) var listenerEpoch: UInt64 = 0
    /// Absolute bound on one handshake, from accept to the app's verdict.
    let handshakeDeadline: Duration
    private var defaultsObserver: NSObjectProtocol?
    private var activationCounter: UInt64 = 0
    private let makeExecutor: (WorkspaceStore) -> MCPAttachExecutor

    init(directory: URL = MCPAttachSocket.defaultDirectory(), defaults: UserDefaults = .standard,
         consentTimeout: Duration = .seconds(120),
         handshakeDeadline: Duration = .seconds(5),
         makeExecutor: @escaping (WorkspaceStore) -> MCPAttachExecutor = { MCPAttachExecutor(store: $0) }) {
        self.directory = directory
        self.defaults = defaults
        self.consentTimeout = consentTimeout
        self.handshakeDeadline = handshakeDeadline
        self.makeExecutor = makeExecutor
    }

    /// Starts following the Settings toggle (app launch).
    func activate() {
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncWithSetting() }
        }
        syncWithSetting()
    }

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledDefaultsKey) }

    func syncWithSetting() {
        if isEnabled { startListening() } else { stopListening() }
    }

    // MARK: Windows

    /// A workspace window registers itself while shown and reports when it becomes key.
    func register(_ store: WorkspaceStore) {
        activationCounter &+= 1
        let key = ObjectIdentifier(store)
        let id = windows[key]?.id ?? UUID()
        windows[key] = Window(id: id, store: store, lastActive: activationCounter)
        if installationObservers[key] == nil {
            installationObservers[key] = store.$documentInstallationID.dropFirst().sink { [weak self] _ in
                MainActor.assumeIsolated { self?.revokeAll(windowID: id) }
            }
        }
    }

    private func revokeAll(windowID: UUID) {
        for connection in connections where connection.windowID == windowID { revoke(connection.id) }
    }

    func noteActive(_ store: WorkspaceStore) { register(store) }

    func unregister(_ store: WorkspaceStore) {
        installationObservers[ObjectIdentifier(store)] = nil
        guard let window = windows.removeValue(forKey: ObjectIdentifier(store)) else { return }
        revokeAll(windowID: window.id)
    }

    enum Resolution: Equatable {
        case window(UUID)
        case refused(String)
    }

    /// An exact, unique workspace name, or (no name) the most recently active window. Duplicate
    /// names are refused rather than guessed. The refusal is the same whatever the reason, so an
    /// unconsented client learns nothing about which windows exist (DP09-2 N5).
    static let unresolvedWindow = "MacScope couldn't attach to a single open window. Omit --window to use the frontmost one."

    func resolveWindow(named name: String?) -> Resolution {
        windows = windows.filter { $0.value.store != nil }
        let live = windows.values.sorted { $0.lastActive > $1.lastActive }
        guard let name else {
            return live.first.map { .window($0.id) } ?? .refused(Self.unresolvedWindow)
        }
        let matches = live.filter { $0.store?.workspaceName == name }
        return matches.count == 1 ? .window(matches[0].id) : .refused(Self.unresolvedWindow)
    }

    private func store(for windowID: UUID) -> WorkspaceStore? {
        windows.values.first { $0.id == windowID }?.store
    }

    static func generation(of store: WorkspaceStore) -> DocumentGeneration {
        DocumentGeneration(installationID: store.documentInstallationID, workspaceID: store.workspaceID,
                           primaryImageID: store.snapshot.binaries.first?.id)
    }

    // MARK: Consent and revocation

    func connections(for store: WorkspaceStore) -> [Connection] {
        connections.filter { $0.store === store }
    }

    /// Allow only a still-pending connection whose window and document are unchanged.
    func allow(_ id: UUID) {
        guard let index = connections.firstIndex(where: { $0.id == id }),
              connections[index].consent == .pending, isGrantValid(connections[index]) else { return }
        connections[index].consent = .allowed
        connections[index].executor.setConsent(.allowed)
    }

    func deny(_ id: UUID) { revoke(id) }

    func disconnect(_ id: UUID) { revoke(id) }

    private func isGrantValid(_ connection: Connection) -> Bool {
        guard isListening, let store = connection.store, store === self.store(for: connection.windowID) else { return false }
        return Self.generation(of: store) == connection.generation
    }

    /// The grant check the executor runs before work, at commit and before releasing a read.
    private func authorize(_ id: UUID) -> Bool {
        guard let connection = connections.first(where: { $0.id == id }), connection.consent == .allowed else { return false }
        guard isGrantValid(connection) else {
            revoke(id)
            return false
        }
        return true
    }

    /// Revoke first (no later commit or read release can pass the grant check), then shut the
    /// socket: its input ends and the request session cancels queued and in-flight requests.
    private func revoke(_ id: UUID) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[index].consent = .revoked
        connections[index].executor.setConsent(.revoked)
        shutdown(connections[index].descriptor, SHUT_RDWR)
    }

    // MARK: Listener

    private func startListening() {
        guard owner == nil else { return }
        let owner: MCPAttachSocket.EndpointOwner
        do {
            owner = try MCPAttachSocket.EndpointOwner(directory: directory)
        } catch {
            listenerError = error.localizedDescription
            return
        }
        self.owner = owner
        listenerError = nil
        isListening = true
        listenerEpoch &+= 1
        let listener = owner.listener, token = owner.token, instance = instance
        let epoch = listenerEpoch, slots = slots, deadline = handshakeDeadline
        Thread.detachNewThread { [weak self] in
            while let client = MCPAttachSocket.accept(listener) {
                // Admission before any thread: over budget, the socket is closed right here.
                guard MCPAttachSocket.peerIsCurrentUser(client), slots.reserve() else {
                    Darwin.close(client)
                    continue
                }
                Self.authenticateOffMain(client: client, token: token, instance: instance, epoch: epoch,
                                         deadline: deadline, slots: slots, coordinator: self)
            }
        }
    }

    func stopListening() {
        guard let owner else { return }
        isListening = false
        listenerEpoch &+= 1
        for connection in connections { revoke(connection.id) }
        owner.release() // also removes this launch's token file
        self.owner = nil
    }

    /// Runs the handshake on its own thread. A watchdog shuts the socket at `deadline` whatever
    /// the peer does (per-read timeouts alone don't bound a slow trickle), so a silent or wrong peer
    /// holds one slot and one short-lived thread at most that long, and never the UI.
    nonisolated private static func authenticateOffMain(client: Int32, token: Data, instance: String, epoch: UInt64,
                                                        deadline: Duration, slots: MCPAttachAdmission,
                                                        coordinator: MCPAttachCoordinator?) {
        let connection = MCPAttachHandshakeConnection(
            shutdown: { _ = Darwin.shutdown(client, SHUT_RDWR) },
            close: { Darwin.close(client); slots.release() }
        )
        let seconds = Double(deadline.components.seconds) + Double(deadline.components.attoseconds) / 1e18
        connection.scheduleDeadline { action in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
        }
        Thread.detachNewThread {
            let readTimeout = max(1, Int(seconds.rounded(.up)))
            MCPAttachSocket.setTimeouts(client, receive: readTimeout, send: readTimeout)
            let window = MCPAttachHandshake.runServer(client, token: token, instance: instance)
            guard connection.completeHandshake(succeeded: window != nil), let window else { return }
            MCPAttachSocket.setTimeouts(client, receive: 0, send: writeTimeoutSeconds)
            Task { @MainActor in
                guard let coordinator else { Darwin.close(client); slots.release(); return }
                coordinator.bind(client: client, window: window, epoch: epoch, holdsSlot: true)
            }
        }
    }

    /// Binds an authenticated socket (tests call this directly; it then takes its own slot).
    func bind(client: Int32, window name: String?) {
        guard slots.reserve() else {
            _ = MCPAttachSocket.writeLine(MCPAttachHandshake.result(workspace: nil, error: "Too many agents are attached."), to: client)
            Darwin.close(client)
            return
        }
        bind(client: client, window: name, epoch: listenerEpoch, holdsSlot: true)
    }

    func bind(client: Int32, window name: String?, epoch: UInt64, holdsSlot: Bool) {
        func refuse(_ reason: String) {
            _ = MCPAttachSocket.writeLine(MCPAttachHandshake.result(workspace: nil, error: reason), to: client)
            Darwin.close(client)
            if holdsSlot { slots.release() }
        }
        // A handshake from before a stop/start (an older listener and token) never binds.
        guard isListening, epoch == listenerEpoch else { return refuse("MacScope isn't accepting agent connections.") }
        let windowID: UUID
        switch resolveWindow(named: name) {
        case .refused(let reason): return refuse(reason)
        case .window(let id): windowID = id
        }
        guard let store = store(for: windowID) else { return refuse(Self.unresolvedWindow) }
        guard !connections.contains(where: { $0.windowID == windowID && $0.consent == .pending }) else {
            return refuse("Another agent is already waiting for permission in that window.")
        }
        let executor = makeExecutor(store)
        let connection = Connection(windowID: windowID, store: store, workspaceName: store.workspaceName,
                                    generation: Self.generation(of: store), consent: .pending,
                                    descriptor: client, executor: executor)
        let id = connection.id
        executor.authorize = { [weak self] in self?.authorize(id) ?? false }
        connections.append(connection)
        // No workspace label before Allow (DP09-2 N5): the user sees it in the window's banner.
        guard MCPAttachSocket.writeLine(MCPAttachHandshake.result(workspace: nil, error: nil), to: client) else {
            finish(id)
            return
        }
        let server = MCPServer(
            api: WorkspaceScriptingAPI(store: store),
            configuration: .attached,
            asyncCommandExecutor: { name, arguments in try await executor.execute(name, arguments) },
            allowedCommands: MCPAttachExecutor.attachCommands
        )
        let handle = FileHandle(fileDescriptor: client, closeOnDealloc: false)
        Task { @MainActor [weak self] in
            await server.runStdioLoopAsync(input: handle, output: handle)
            self?.finish(id)
        }
        let timeout = consentTimeout
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            if let self, self.connections.first(where: { $0.id == id })?.consent == .pending { self.revoke(id) }
        }
    }

    private func finish(_ id: UUID) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        let connection = connections.remove(at: index)
        connection.executor.setConsent(.revoked)
        Darwin.close(connection.descriptor)
        slots.release()
    }
}

extension MCPServer.Configuration {
    /// Headless frame, output and per-tool time limits, with 4 concurrent requests per attached
    /// connection (mutations are serialized by the request session).
    static let attached = MCPServer.Configuration(
        maximumInputBytes: production.maximumInputBytes,
        maximumOutputBytes: production.maximumOutputBytes,
        maximumToolDurationNanoseconds: production.maximumToolDurationNanoseconds,
        maximumRememberedCancellations: production.maximumRememberedCancellations,
        maximumInFlightRequests: 4
    )
}

/// The app-wide connection budget: authenticating, pending and allowed connections together.
final class MCPAttachAdmission: @unchecked Sendable {
    let limit: Int
    private let lock = NSLock()
    private var held = 0

    init(limit: Int) { self.limit = limit }

    var count: Int { lock.withLock { held } }

    func reserve() -> Bool {
        lock.withLock {
            guard held < limit else { return false }
            held += 1
            return true
        }
    }

    func release() { lock.withLock { held = max(0, held - 1) } }
}

/// Owns the handshake's deadline and socket until retirement or successful transfer to bind.
/// Both shutdown and close execute under the same lock, so selecting expiry never grants an
/// operation permission beyond retirement. Injected operations must not reenter this owner.
final class MCPAttachHandshakeConnection: @unchecked Sendable {
    private enum State { case handshaking, expired, transferred, retired }
    private let lock = NSLock()
    private var state = State.handshaking
    private let shutdown: @Sendable () -> Void
    private let close: @Sendable () -> Void
    /// Test checkpoint after expiry selection, before the owned action. It runs outside the
    /// lock so a deterministic test can retire the connection at exactly that boundary.
    private let deadlineSelected: @Sendable () -> Void

    init(shutdown: @escaping @Sendable () -> Void,
         close: @escaping @Sendable () -> Void,
         deadlineSelected: @escaping @Sendable () -> Void = {}) {
        self.shutdown = shutdown
        self.close = close
        self.deadlineSelected = deadlineSelected
    }

    func scheduleDeadline(using schedule: (@escaping @Sendable () -> Void) -> Void) {
        schedule { self.expire() }
    }

    func completeHandshake(succeeded: Bool) -> Bool {
        lock.withLock {
            if succeeded, state == .handshaking {
                state = .transferred
                return true
            }
            retireLocked()
            return false
        }
    }

    func retire() {
        lock.withLock { retireLocked() }
    }

    private func retireLocked() {
        guard state == .handshaking || state == .expired else { return }
        state = .retired
        close()
    }

    private func expire() {
        let selected = lock.withLock {
            guard state == .handshaking else { return false }
            state = .expired
            return true
        }
        guard selected else { return }
        deadlineSelected()
        lock.withLock {
            guard state == .expired else { return }
            shutdown()
        }
    }
}
