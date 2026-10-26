import Foundation

/// Runs MCP tool calls for an agent attached to an open GUI window (`MacScope --mcp-attach`),
/// under the attach policy (DP09):
/// - **Capabilities v1** (`attachCommands`): reads, annotations, types and patches. No document
///   lifecycle (open/save), no navigation (`goto`), no structural re-analysis (`make-*`,
///   rebase/segment overrides) and no command that performs fresh analysis or parsing
///   synchronously on the MainActor (`call-argument-audit`, `define-types-from-c`,
///   `neon-hitrate`). `MCPServer` enforces the same set in `tools/list` and dispatch.
///   `read-evidence` and `reconstruction-jobs` are admitted as bounded reads of
///   already-materialised state, with no analysis or decode. They run through
///   `executeAsync`'s inline path and use their own read limits rather than the detached
///   snapshot work budget. `neon-hitrate` remains excluded because it builds fresh MacIR.
/// - **Navigator commands** (`NavigatorMCPCommands.attachable`): every `navigator-*` read and
///   `navigator-accept` (author `navigator` only; one undo group like any other attached edit).
///   `navigator-revert` is not attached: reverting is the analyst's decision, and an agent reads
///   what a revert would do with `navigator-preview-revert`. The toolchain and provenance reads
///   parse bytes in a detached task; the store reads are bounded by a 256-row page.
/// - **Grant fence:** `authorize` (the coordinator's grant for this connection, window and
///   document generation) is checked at the start, again at the nonsuspending commit point, and
///   before a read result is released. After Deny, Disconnect, toggle-off, window close or a
///   document replacement nothing commits and no late read is returned.
/// - **Off the MainActor:** heavy reads go through `executeAsync`, and list reads through the shared
///   snapshot builders (snapshot captured on main, rows built in a detached task). A mutation commits on main without forcing synchronous re-analysis;
///   the store's asynchronous re-flow then belongs to the document, not to this connection.
/// - **Undo:** one request-owned top-level group, opened and closed inside the nonsuspending
///   commit, named "Agent: <command>". The commit waits until no host event group is open (DP09-2
///   N2), so agent and human edits undo independently and autosave never sees half an agent edit.
/// - **Rate:** at most `maximumRequestsPerSecond` per connection.
@MainActor
final class MCPAttachExecutor {
    enum Consent: Equatable { case pending, allowed, revoked }

    /// Client-visible failures. Before consent they carry no workspace names, paths or details.
    enum Failure: LocalizedError, Equatable {
        case consentPending
        case notAuthorized
        case rateLimited
        case unavailableWhenAttached
        case busy

        var errorDescription: String? {
            switch self {
            case .consentPending: "Waiting for permission in MacScope: the user must click Allow in the window, then retry."
            case .notAuthorized: "This agent connection is not authorized (denied, disconnected, or the window or document changed)."
            case .rateLimited: "Too many requests on this connection; slow down and retry."
            case .unavailableWhenAttached: "That tool isn't available while attached to an open window."
            case .busy: "MacScope is busy with an edit in that window; retry shortly."
            }
        }
    }

    static let attachCommands: Set<String> = [
        // Reads (heavy ones run detached through executeAsync).
        "commands", "info", "functions", "symbols", "strings", "imports", "exports", "sections",
        "relocations", "instructions", "basic-blocks", "decompile", "search", "xrefs", "callers",
        "callees", "name-at", "read-bytes", "resolve-symbol", "list-types", "list-image-types",
        "bookmarks", "local-labels", "register-names", "manual-xrefs", "segment-overrides",
        "parameter-binding-audit", "stack-locals", "recover-struct-candidate", "indirect-call-targets",
        // Non-mutating reads with no stated exclusion reason (DEF-A06).
        "read-evidence", "reconstruction-jobs",
        // Navigator surface: the reads and acceptance (not `navigator-revert`).
        "navigator-facts", "navigator-frontier", "navigator-dependents", "navigator-primitives",
        "navigator-preview-revert", "navigator-accept", "navigator-toolchain",
        "navigator-resolve-provenance",
        // Annotations.
        "rename", "set-comment", "set-tag", "set-color", "add-bookmark", "remove-bookmark",
        "set-local-label", "clear-local-label", "rename-register", "clear-register-name",
        "set-stack-local", "accept-struct-candidate",
        "set-operand-format", "set-signature", "set-type", "add-xref", "suppress-xref",
        // Types and patches.
        "define-type", "patch-bytes", "clear-patch",
    ]
    static let maximumRequestsPerSecond = 20
    /// 5 ms waits for an open host undo group to close (about one second in all).
    static let maximumUndoGroupWaits = 200

    weak var store: WorkspaceStore?
    private(set) var consent: Consent = .pending
    /// The coordinator's live grant check; true only while this connection may act on its window.
    var authorize: () -> Bool = { true }
    private let api: (WorkspaceStore) -> WorkspaceScriptingAPI
    private let now: () -> UInt64
    private var recentRequests: [UInt64] = []
    private var snapshotReads: [UUID: Task<ScriptValue, Error>] = [:]

    init(store: WorkspaceStore,
         api: @escaping (WorkspaceStore) -> WorkspaceScriptingAPI = {
             WorkspaceScriptingAPI(store: $0, nativeDecompiler: NativeDecompilerRuntimeRegistry.productionShared)
         },
         now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.store = store
        self.api = api
        self.now = now
    }

    func setConsent(_ consent: Consent) {
        // Revocation is final for a connection.
        guard self.consent != .revoked else { return }
        self.consent = consent
        if consent == .revoked {
            for read in snapshotReads.values { read.cancel() }
        }
    }

    private func requireGrant() throws -> WorkspaceStore {
        switch consent {
        case .pending: throw Failure.consentPending
        case .revoked: throw Failure.notAuthorized
        case .allowed: break
        }
        guard let store, authorize() else { throw Failure.notAuthorized }
        return store
    }

    /// The `MCPServer.AsyncCommandExecutor` for this connection. `MCPServer` has already applied
    /// the attach command set, argument validation, size and deadline limits.
    func execute(_ command: String, _ arguments: ScriptValue) async throws -> ScriptValue {
        _ = try requireGrant()
        try admitRate()
        guard Self.attachCommands.contains(command) else { throw Failure.unavailableWhenAttached }
        let store = try requireGrant()
        let api = api(store)
        let mutates = (WorkspaceScriptingAPI.availableCommands + NavigatorMCPCommands.catalog)
            .first { $0.name == command }?.mutates ?? true
        if !mutates, WorkspaceScriptingAPI.snapshotListCommands.contains(command) {
            // List reads: rows are built from a snapshot captured here, in a detached task the
            // request owns (cancelled with it), never on the MainActor (DP09-2 N3).
            try HeadlessAutomationAuthority.validate(command: command, arguments: arguments)
            let snapshot = store.snapshot
            let bounded = Self.boundedArguments(command, arguments)
            let catalog = command == "commands"
                ? WorkspaceScriptingAPI.availableCommands + NavigatorMCPCommands.catalog : []
            let probe = api.snapshotReadCheckpoint
            let work = Task.detached(priority: Task.currentPriority) {
                try WorkspaceScriptingAPI.snapshotListRead(command, arguments: bounded, snapshot: snapshot,
                                                            scope: .attached, commandCatalog: catalog) {
                    probe?()
                    try Task.checkCancellation()
                }
            }
            let readID = UUID()
            snapshotReads[readID] = work
            defer { snapshotReads[readID] = nil }
            let output = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            try Task.checkCancellation()
            _ = try requireGrant() // no read is released after revocation or a document change
            return command == "commands" ? Self.attachCatalog(output) : output
        }
        guard mutates else {
            let output = try await HeadlessAutomationAuthority.executeAsync(
                command: command, arguments: Self.boundedArguments(command, arguments), api: api,
                proposingPrincipal: .mcp)
            _ = try requireGrant() // no read is released after revocation or a document change
            return command == "commands" ? Self.attachCatalog(output) : output
        }
        try Task.checkCancellation()
        try HeadlessAutomationAuthority.validate(command: command, arguments: arguments)
        // The window's UndoManager groups by event: a group may already be open for a human edit
        // in this run-loop turn. Committing inside it would make one undo step revert both, so
        // wait (bounded) until no group is open, then commit in a top-level group of our own.
        let undo = store.undoManager
        var waits = 0
        while undo.groupingLevel > 0 {
            guard waits < Self.maximumUndoGroupWaits else { throw Failure.busy }
            waits += 1
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        // Commit point: no suspension from this grant check to the end of the edit.
        _ = try requireGrant()
        guard undo.groupingLevel == 0 else { throw Failure.busy }
        // Exactly one top-level group, named for the agent. With event grouping on, an explicit
        // begin would first open an automatic event group around ours: the name would sit on the
        // inner group (the Edit menu then reads a bare "Undo", release check of 8b6f1ac2d) and,
        // outside a user event, that automatic group would stay open until the next event, so a
        // later edit could join it. Event grouping is suspended for this nonsuspending commit only.
        let groupsByEvent = undo.groupsByEvent
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        defer {
            undo.setActionName("Agent: \(command)")
            undo.endUndoGrouping()
            undo.groupsByEvent = groupsByEvent
        }
        if NavigatorMCPCommands.handles(command) {
            // `navigator-accept`: the navigator bridge runs inside the group opened above.
            return try NavigatorMCPCommands.execute(command: command, arguments: arguments, surface: .live(store))
        }
        return try api.execute(command, arguments: arguments, proposingPrincipal: .mcp,
                               forcesSynchronousReanalysis: false)
    }

    /// Row-returning reads get a finite default and a hard cap when attached, so one request can't
    /// build an image-sized result on the MainActor (DP09-2 N3); instruction ranges are clamped.
    static let limitedCommands: Set<String> = [
        "functions", "symbols", "strings", "imports", "exports", "sections", "relocations", "list-image-types",
    ]
    static let defaultRowLimit = 1_000
    static let maximumRowLimit = 5_000
    static let maximumInstructionCount = 2_000

    static func boundedArguments(_ command: String, _ arguments: ScriptValue) -> ScriptValue {
        guard case .object(var fields) = arguments else { return arguments }
        // Xrefs enforce their requested prefix and hard budgets inside the detached selector.
        // Preserve an absent limit: exceeding the cap must refuse an incomplete list, not
        // silently turn the complete-list request into a default-sized prefix.
        if command == "xrefs" { return arguments }
        if limitedCommands.contains(command) {
            let requested = fields["limit"]?.intValue.map { Int(max(0, $0)) } ?? defaultRowLimit
            fields["limit"] = .int(Int64(min(requested, maximumRowLimit)))
        } else if command == "instructions" {
            let named = fields["function"]?.stringValue != nil
            let requested = fields["count"]?.intValue ?? Int64(named ? maximumInstructionCount : 16)
            // A present null/nonstring selector is still an address read. Never raise the
            // caller's count; named-function compatibility is handled by the row selector.
            fields["count"] = .int(max(0, min(requested, Int64(maximumInstructionCount))))
        }
        return .object(fields)
    }

    /// `commands` lists only what an attached agent may call (DP09-2 N6), the same set as tools/list.
    static func attachCatalog(_ output: ScriptValue) -> ScriptValue {
        guard case .array(let entries) = output else { return output }
        return .array(entries.filter { entry in
            entry["name"]?.stringValue.map(attachCommands.contains) ?? false
        })
    }

    private func admitRate() throws {
        let current = now()
        let window: UInt64 = 1_000_000_000
        recentRequests.removeAll { current &- $0 >= window }
        guard recentRequests.count < Self.maximumRequestsPerSecond else { throw Failure.rateLimited }
        recentRequests.append(current)
    }
}
