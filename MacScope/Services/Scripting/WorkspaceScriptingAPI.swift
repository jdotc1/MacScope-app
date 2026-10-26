import CryptoKit
import Darwin
import Foundation

enum ScriptingError: LocalizedError, Equatable {
    case unknownCommand(String)
    case missingArgument(String)
    case invalidArgument(String)
    /// A `function` name selector matched more than one function in the command's image
    /// scope — two equal display labels, two equal raw names, or one function's display
    /// label colliding with another function's raw name. `addresses` lists every matching
    /// function start in analysis order so the caller can retry with an `address` selector.
    case ambiguousFunctionSelector(name: String, addresses: [UInt64])
    /// An explicit `image` selector (MS-19) named no image loaded in this workspace.
    /// `validSlots` lists every loaded image's slot, ascending.
    case unknownImage(selector: String, validSlots: [Int])

    var errorDescription: String? {
        switch self {
        case .unknownCommand(let name): "Unknown scripting command '\(name)'."
        case .missingArgument(let name): "Missing required argument '\(name)'."
        case .invalidArgument(let detail): "Invalid argument: \(detail)."
        case .ambiguousFunctionSelector(let name, let addresses):
            "Ambiguous function selector '\(name)': \(addresses.count) functions match (\(addresses.map { "0x" + String($0, radix: 16) }.joined(separator: ", "))); select by `address` instead."
        case .unknownImage(let selector, let validSlots):
            validSlots.isEmpty
                ? "Unknown image '\(selector)': no images are loaded; omit `image` for the primary image."
                : "Unknown image '\(selector)': valid image slots are \(validSlots.map(String.init).joined(separator: ", ")) (pass a slot index or an image-owner ID; omit `image` for the primary image)."
        }
    }
}

/// Describes a built-in scripting command so a binding can introspect the surface
/// (the `commands` command returns these).
struct ScriptingCommandInfo: Equatable, Sendable {
    var name: String
    var summary: String
    var mutates: Bool
    var arguments: [String]
}

/// Read-only commands whose CPU-heavy work runs over an immutable snapshot. The async
/// binding executes them off MainActor with request-owned cooperative cancellation.
enum ScriptingSnapshotRead: String, Sendable, CaseIterable {
    case decompile
    case parameterBindingAudit = "parameter-binding-audit"
    case basicBlocks = "basic-blocks"
}

/// MainActor state a snapshot read needs, captured once at admission.
struct ScriptingSnapshotReadContext: Sendable {
    let snapshot: WorkspaceSnapshot
    let focusedSlot: ImageSlot
}

/// One scripted/MCP `decompile` request handed to the native (SLEIGH) decompiler: the same
/// app-owned runtime the pseudocode pane and the reconstruction loop drive.
struct ScriptingNativeDecompileRequest: Sendable {
    let snapshot: WorkspaceSnapshot
    let imageSlot: ImageSlot
    let functionID: UUID
    let startAddress: UInt64
}

/// Outcome of one native attempt. Anything other than a completed, non-blank document makes
/// `decompile` fall back to MacIR and report why in `fallbackReason`.
enum ScriptingNativeDecompileOutcome: Equatable, Sendable {
    /// The native runtime answered; a nil or blank document reports `native-empty`.
    case completed(NativeDecompilerWirePseudocodeDocument?)
    /// Native is disabled, shut down, not packaged, or cannot project this image.
    case unavailable
    /// Native ran and failed; `code` is short and machine-readable (`timed-out`, `busy`, ...).
    case failed(code: String)

    /// The pane's terminal classification, reused so scripting and UI agree on "unavailable".
    static func terminal(_ reason: NativeDecompilerPresentationTerminalReason) -> Self {
        if reason.isUnavailable { return .unavailable }
        switch reason {
        case .provider(let code, _): return .failed(code: code.rawValue)
        case .client(let failure): return .failed(code: "client-\(failure.rawValue)")
        case .invalidReply: return .failed(code: "invalid-reply")
        case .transportFailure: return .failed(code: "transport-failure")
        case .projection(let error): return .failed(code: "projection-\(error)")
        case .runtimeValidation(let error): return .failed(code: "runtime-validation-\(error)")
        case .runtime(let error): return .failed(code: "runtime-\(error)")
        }
    }
}

/// Injectable native decompile seam. Production binds the app-owned
/// `NativeDecompilerRuntimeRegistry`; tests inject fixed outcomes without the XPC service.
/// Called from a detached task, never on MainActor.
protocol ScriptingNativeDecompiling: Sendable {
    func decompile(_ request: ScriptingNativeDecompileRequest) async -> ScriptingNativeDecompileOutcome
}

/// `backend` / `fallbackReason` values carried by every `decompile` result.
enum ScriptingDecompileBackend {
    static let native = "native"
    static let macIR = "macir"
    static let nativeUnavailable = "native-unavailable"
    static let nativeEmpty = "native-empty"
    static func nativeFailed(_ code: String) -> String { "native-failed: \(code)" }
}

/// The in-process automation surface: named commands that query and mutate the loaded
/// workspace, exchanging JSON (`ScriptValue`). This is the single place where a command
/// identifier maps to a real `WorkspaceStore` operation — every binding (a Python
/// embed, an MCP / JSON-RPC server, a CLI) drives THIS. Mutating commands go through
/// the store's undoable authoring methods, so scripted edits are reversible exactly
/// like manual ones.
@MainActor
struct WorkspaceScriptingAPI {
    let store: WorkspaceStore
    /// Observes each cooperative checkpoint of an async snapshot read immediately before
    /// that checkpoint tests cancellation. Production passes nil; tests use it to hold a
    /// detached read at an exact boundary without wall-clock timing.
    let snapshotReadCheckpoint: (@Sendable () -> Void)?
    /// Native-first `decompile` for the async binding (MCP). Nil, and every synchronous
    /// binding, serves MacIR with `fallbackReason: native-unavailable`.
    let nativeDecompiler: (any ScriptingNativeDecompiling)?

    init(
        store: WorkspaceStore,
        snapshotReadCheckpoint: (@Sendable () -> Void)? = nil,
        nativeDecompiler: (any ScriptingNativeDecompiling)? = nil
    ) {
        self.store = store
        self.snapshotReadCheckpoint = snapshotReadCheckpoint
        self.nativeDecompiler = nativeDecompiler
    }

    /// Runs a single command by identifier with JSON arguments, returning a JSON result.
    /// `forcesSynchronousReanalysis: false` (MCP attached to a GUI window) leaves a mutation's
    /// re-flow on the store's normal off-main path, so an agent edit never blocks the UI on analysis.
    func execute(
        _ command: String,
        arguments: ScriptValue = .object([:]),
        proposingPrincipal: Phase2Principal = .human,
        forcesSynchronousReanalysis: Bool = true
    ) throws -> ScriptValue {
        guard let handler = Self.registry[command] else { throw ScriptingError.unknownCommand(command) }
        if command == "read-evidence" {
            return try Self.readEvidence(arguments, store: store, proposingPrincipal: proposingPrincipal)
        }
        // A mutating command may re-drive analysis (mark-as-data/procedure, patch, …). The store
        // re-flows that OFF the main actor for the interactive UI, but a script is synchronous and
        // expects mutate-then-query to be deterministic — so force the re-flow to complete inline
        // for the span of this command. Read-only commands skip the wrapper (no re-flow to force).
        guard handler.info.mutates, forcesSynchronousReanalysis else { return try handler.run(arguments, store) }
        return try store.withSynchronousReanalysis { try handler.run(arguments, store) }
    }

    /// Async bindings keep bounded search off MainActor. The detached scan owns an immutable
    /// snapshot; its cancellation follows this request and no partial result mutates the store.
    /// The CPU-heavy snapshot reads (`decompile`, `parameter-binding-audit`, `basic-blocks`)
    /// follow the same ownership model and observe cancellation at their phase/loop
    /// boundaries. Other commands retain the existing synchronous authority and mutation
    /// semantics.
    func executeAsync(
        _ command: String,
        arguments: ScriptValue = .object([:]),
        proposingPrincipal: Phase2Principal = .human
    ) async throws -> ScriptValue {
        if Self.snapshotListCommands.contains(command) {
            return try await executeSnapshotListRead(command, arguments: arguments)
        }
        guard command == "search" else {
            if let read = ScriptingSnapshotRead(rawValue: command) {
                return try await executeSnapshotRead(read, arguments: arguments)
            }
            // Pre-commit boundary. Everything from this check through the handler's return
            // is synchronous on MainActor with no suspension point, so a cancellation that
            // precedes it leaves no effect, and one that arrives later cannot interrupt the
            // commit: the transport then reports the committed receipt, never "cancelled".
            try Task.checkCancellation()
            return try execute(command, arguments: arguments, proposingPrincipal: proposingPrincipal)
        }
        try Task.checkCancellation()
        let query = try Self.string(arguments, "query")
        // The bounded engine admits 256 UTF-8 bytes. The headless and attached authorities refuse
        // a longer query with the typed `invalidPattern(tooLong)` before this point
        // (`HeadlessAutomationAuthority.searchRefusal`); a direct caller still gets this error
        // rather than the engine's empty invalid-query result presented as an exact search.
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count <= 256 else {
            throw ScriptingError.invalidArgument("bounded search query exceeds 256 UTF-8 bytes")
        }
        let mode = BinarySearchMode(rawValue: arguments["mode"]?.stringValue ?? "text") ?? .text
        let snapshot = store.snapshot
        let scope = Self.searchScope(
            filter: try Self.resolveImageSlotFilter(arguments, snapshot: snapshot),
            focusedSlot: store.focusedImageSlot)
        let capturedScope = scope
        let scan = Task.detached(priority: Task.currentPriority) {
            try Task.checkCancellation()
            let outcome = BinarySearchService().searchBounded(
                query: query, mode: mode, in: snapshot, scope: capturedScope,
                isCancelled: { Task.isCancelled }
            )
            guard !outcome.isCancelled else { throw CancellationError() }
            try Task.checkCancellation()
            return outcome
        }
        let outcome = try await withTaskCancellationHandler {
            try await scan.value
        } onCancel: {
            scan.cancel()
        }
        try Task.checkCancellation()
        return .object([
            "total": outcome.isTruncated ? .null : .int(Int64(outcome.lowerBound)),
            "lowerBound": .int(Int64(outcome.lowerBound)),
            "isTruncated": .bool(outcome.isTruncated),
            "results": .array(outcome.results.map(Self.searchRow)),
        ])
    }

    /// Runs one heavy read over an immutable snapshot captured on MainActor. The detached
    /// task is owned by this request: parent cancellation cancels it, each checkpoint throws
    /// `CancellationError`, and a cancelled read never publishes a partial result. Read-only,
    /// so discarding a result that completed concurrently with cancellation is truthful.
    private func executeSnapshotRead(
        _ read: ScriptingSnapshotRead,
        arguments: ScriptValue
    ) async throws -> ScriptValue {
        try Task.checkCancellation()
        let context = ScriptingSnapshotReadContext(
            snapshot: store.snapshot, focusedSlot: store.focusedImageSlot
        )
        let probe = snapshotReadCheckpoint
        let native = read == .decompile ? nativeDecompiler : nil
        let cancellation = PseudocodeRenderingThread.Cancellation()
        let work = Task.detached(priority: Task.currentPriority) {
            let checkpoint: @Sendable () throws -> Void = {
                probe?()
                try cancellation.check()
                try Task.checkCancellation()
            }
            if let native {
                return try await WorkspaceScriptingAPI.decompileNativeFirst(
                    arguments, snapshot: context.snapshot, native: native, checkpoint: checkpoint
                )
            }
            if read == .decompile {
                return try await PseudocodeRenderingThread.run {
                    try WorkspaceScriptingAPI.runSnapshotRead(
                        read, arguments: arguments, context: context, checkpoint: checkpoint
                    )
                }
            }
            return try WorkspaceScriptingAPI.runSnapshotRead(
                read, arguments: arguments, context: context, checkpoint: checkpoint
            )
        }
        let output = try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            cancellation.cancel()
            work.cancel()
        }
        try Task.checkCancellation()
        return output
    }

    /// The single implementation of each snapshot read. The synchronous registry passes a
    /// no-op checkpoint, so async and legacy results are produced by the same code.
    nonisolated static func runSnapshotRead(
        _ read: ScriptingSnapshotRead,
        arguments: ScriptValue,
        context: ScriptingSnapshotReadContext,
        checkpoint: () throws -> Void
    ) throws -> ScriptValue {
        switch read {
        case .decompile:
            return try decompileObject(arguments, snapshot: context.snapshot, checkpoint: checkpoint)
        case .parameterBindingAudit:
            return try parameterBindingAuditRead(arguments, snapshot: context.snapshot,
                slot: context.focusedSlot, checkpoint: checkpoint)
        case .basicBlocks:
            return try basicBlocksObject(arguments, snapshot: context.snapshot, checkpoint: checkpoint)
        }
    }

    /// Native-first `decompile`: asks the native runtime for the function the selector resolves
    /// to in the selected image (the primary image unless `image` names another; the same
    /// binding MacIR uses), and falls back to MacIR when native is unavailable, fails, or
    /// returns no document. Cancellation observed after the native await throws instead of
    /// falling back. Checkpoints: entry, after the native await, then the MacIR checkpoints on
    /// fallback.
    nonisolated static func decompileNativeFirst(
        _ arguments: ScriptValue,
        snapshot: WorkspaceSnapshot,
        native: any ScriptingNativeDecompiling,
        checkpoint: @escaping @Sendable () throws -> Void
    ) async throws -> ScriptValue {
        try checkpoint()
        let slot = try resolveImageSlot(arguments, snapshot: snapshot)
        let function = try resolveDecompileFunction(arguments, in: slot, snapshot: snapshot)
        let outcome = await native.decompile(ScriptingNativeDecompileRequest(
            snapshot: snapshot,
            imageSlot: slot,
            functionID: function.id,
            startAddress: function.startAddress
        ))
        try checkpoint()
        let fallbackReason: String
        switch outcome {
        case .completed(let document?)
            where !document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            var fields = nativeDecompileObject(function: function, document: document)
            fields.merge(imageProvenanceFields(slot: slot, snapshot: snapshot)) { _, label in label }
            return .object(fields)
        case .completed:
            fallbackReason = ScriptingDecompileBackend.nativeEmpty
        case .unavailable:
            fallbackReason = ScriptingDecompileBackend.nativeUnavailable
        case .failed(let code):
            fallbackReason = ScriptingDecompileBackend.nativeFailed(code)
        }
        return try await PseudocodeRenderingThread.run {
            try decompileObject(
                arguments, snapshot: snapshot, fallbackReason: fallbackReason, checkpoint: checkpoint
            )
        }
    }

    nonisolated private static func nativeDecompileObject(
        function: FunctionSummary,
        document: NativeDecompilerWirePseudocodeDocument
    ) -> [String: ScriptValue] {
        var lines: [ScriptValue] = []
        for (index, text) in document.text.split(
            separator: "\n", omittingEmptySubsequences: false
        ).enumerated() {
            lines.append(.object(["n": .int(Int64(index + 1)), "text": .string(String(text))]))
        }
        return [
            "function": .string(function.name),
            "address": .hex(function.startAddress),
            "pseudocode": .string(document.text),
            "structured": .bool(false),
            "lines": .array(lines),
            "backend": .string(ScriptingDecompileBackend.native),
            "language": .string(document.language),
            "complete": .bool(document.isComplete),
            "truncated": .bool(document.isTruncated),
        ]
    }

    /// `decompile`'s function binding in the selected image. For the primary slot (the MS-06
    /// default) this is exactly the primary-image resolver; for a sibling it reads functions and
    /// display names from that image only, with the same name/address selector policy.
    nonisolated private static func resolveDecompileFunction(
        _ arguments: ScriptValue,
        in slot: ImageSlot,
        snapshot: WorkspaceSnapshot
    ) throws -> FunctionSummary {
        try resolveFunction(
            arguments, in: snapshot.analysis(in: slot)?.functions ?? [], slot: slot, snapshot: snapshot
        )
    }

    /// Checkpoints: entry, after body extraction, after MacIR build, inside the printer every
    /// `PseudocodePrinter.cancellationCheckpointInterval` emission steps (statements, region
    /// entries, structured instructions), after print, and every 1,024 serialized lines. The
    /// stop bound is one MacIR build or one printer checkpoint interval.
    nonisolated private static func decompileObject(
        _ arguments: ScriptValue,
        snapshot: WorkspaceSnapshot,
        fallbackReason: String = ScriptingDecompileBackend.nativeUnavailable,
        checkpoint: () throws -> Void
    ) throws -> ScriptValue {
        try checkpoint()
        // Every per-image input below reads `slot`: the primary image by default, so the
        // primary-slot path is the pre-MS-19 computation unchanged.
        let slot = try resolveImageSlot(arguments, snapshot: snapshot)
        let function = try resolveDecompileFunction(arguments, in: slot, snapshot: snapshot)
        let target = snapshot.pseudocodeTarget(selectedAddress: function.startAddress, in: slot)
        let machineUsage = snapshot.machineCallUsageHandoff(for: target, in: slot)
        try checkpoint()
        // Exactly the two phases of `PseudocodePrinter.print(functionName:...)`, split so
        // cancellation is observed between the MacIR build and rendering.
        let printer = PseudocodePrinter()
        let irFunction = printer.buildFunction(
            functionName: snapshot.displayName(at: function.startAddress, in: slot, default: function.name),
            startAddress: function.startAddress,
            jumpTables: snapshot.resolvedJumpTables(in: slot),
            objcSelectors: snapshot.analysis(in: slot)?.objcSelectors ?? [:],
            constantStrings: snapshot.constantStrings(in: slot),
            signatureOverrides: snapshot.functionSignatureOverrides(in: slot),
            authoredCallSignaturesByTarget: snapshot.authoredCallSignaturesByTarget(in: slot),
            directCallVoidResultTargets: snapshot.directCallVoidResultTargets(in: slot),
            machineCallUsage: machineUsage?.usage,
            machineUsageContext: machineUsage?.context,
            types: snapshot.typeDefinitions,
            instructions: target?.instructions ?? []
        )
        try checkpoint()
        let document = try printer.print(
            function: irFunction,
            ownDirectCallAddresses: snapshot.ownDirectCallAddresses(in: slot),
            types: snapshot.typeDefinitions,
            nameOverrides: snapshot.functionNameOverrides(in: slot),
            registerNameOverrides: snapshot.registerNameOverrides(forProcedureAt: function.startAddress, in: slot),
            stackLocalOverrides: snapshot.stackLocalOverrides(forProcedureAt: function.startAddress, in: slot),
            checkpoint: checkpoint
        )
        try checkpoint()
        var lines: [ScriptValue] = []
        lines.reserveCapacity(document.lines.count)
        for (index, line) in document.lines.enumerated() {
            if index > 0, index.isMultiple(of: 1_024) { try checkpoint() }
            lines.append(pseudocodeLineObject(line))
        }
        var fields: [String: ScriptValue] = [
            "function": .string(function.name),
            "address": .hex(function.startAddress),
            "pseudocode": .string(document.text),
            "structured": .bool(document.regionTree != nil),
            "lines": .array(lines),
            "backend": .string(ScriptingDecompileBackend.macIR),
            "fallbackReason": .string(fallbackReason),
        ]
        fields.merge(imageProvenanceFields(slot: slot, snapshot: snapshot)) { _, label in label }
        if let regionTree = document.regionTree {
            fields["regions"] = pseudocodeRegionObject(regionTree)
        }
        if let structureFallback = document.structureFallback {
            fields["structureFallback"] = .string(structureFallback.rawValue)
        }
        return .object(fields)
    }

    /// Checkpoints: entry, every 4,096 scanned image instructions, after body extraction,
    /// after MacIR build, and after the audit.
    nonisolated private static func parameterBindingAuditRead(
        _ arguments: ScriptValue,
        snapshot: WorkspaceSnapshot,
        slot: ImageSlot,
        checkpoint: () throws -> Void
    ) throws -> ScriptValue {
        try checkpoint()
        guard let analysis = snapshot.analysis(in: slot) else {
            throw ScriptingError.invalidArgument("no analyzed image exists in the focused slot")
        }
        let function = try resolveFunction(
            arguments, in: analysis.functions, slot: slot, snapshot: snapshot
        )
        let overrides = snapshot.overrides(in: slot)
        var instructions: [InstructionRow] = []
        for (index, row) in analysis.instructions.enumerated() {
            if index > 0, index.isMultiple(of: 4_096) { try checkpoint() }
            let isExcludedFromCode = overrides[row.address].map {
                $0.isData || $0.isUndefined || !($0.dataShape?.isEmpty ?? true)
            } ?? false
            guard row.address >= function.startAddress, !isExcludedFromCode else { continue }
            let inBody = function.endAddress > function.startAddress
                ? row.address < function.endAddress
                : row.address == function.startAddress
            if inBody { instructions.append(row) }
        }
        try checkpoint()
        let irFunction = PseudocodePrinter().buildFunction(
            functionName: snapshot.displayName(
                at: function.startAddress,
                in: slot,
                default: function.name
            ),
            startAddress: function.startAddress,
            jumpTables: snapshot.resolvedJumpTables(in: slot),
            objcSelectors: analysis.objcSelectors,
            signatureOverrides: snapshot.functionSignatureOverrides(in: slot),
            authoredCallSignaturesByTarget: snapshot.authoredCallSignaturesByTarget(in: slot),
            types: snapshot.typeDefinitions,
            instructions: instructions
        )
        try checkpoint()
        let audit = irFunction.parameterBindingAudit()
        try checkpoint()
        return parameterBindingAuditObject(audit)
    }

    /// Successor discovery scans every image control-flow edge once per block, so the
    /// per-block checkpoint bounds post-cancellation work to one edge scan.
    nonisolated private static func basicBlocksObject(
        _ arguments: ScriptValue,
        snapshot: WorkspaceSnapshot,
        checkpoint: () throws -> Void
    ) throws -> ScriptValue {
        try checkpoint()
        let function = try resolveFunction(arguments, snapshot)
        // Use the canonical `functionRange` (the same bound `callers`/`callees` use) so a
        // zero-width function still contains its own start block instead of yielding [].
        let range = snapshot.functionRange(function)
        let blocks = snapshot.basicBlocks
            .filter { range.contains($0.startAddress) }
            .sorted { $0.startAddress < $1.startAddress }
        let edges = snapshot.controlFlowEdges
        var values: [ScriptValue] = []
        values.reserveCapacity(blocks.count)
        for block in blocks {
            try checkpoint()
            let successors = edges
                .filter { $0.from >= block.startAddress && $0.from < block.endAddress }
                .map { ScriptValue.object(["to": .hex($0.to), "kind": .string($0.kind)]) }
            values.append(.object([
                "start": .hex(block.startAddress),
                "end": .hex(block.endAddress),
                "instructionCount": .int(Int64(block.instructionCount)),
                "successors": .array(successors),
            ]))
        }
        return .array(values)
    }

    /// Runs a batch script: an array of `{ "command": ..., "arguments": {...} }` steps,
    /// returning each result in order. This is the primitive a Python/MCP/CLI client
    /// sends; a single round-trip drives a whole automation sequence.
    func runScript(_ script: ScriptValue) throws -> ScriptValue {
        guard let steps = script.arrayValue else {
            throw ScriptingError.invalidArgument("a script must be a JSON array of steps")
        }
        var results: [ScriptValue] = []
        for step in steps {
            guard let command = step["command"]?.stringValue else {
                throw ScriptingError.missingArgument("command")
            }
            // Reject a present-but-non-object `arguments`. Otherwise a misencoded step
            // (e.g. `"arguments": 5`) would pass straight through — every argument
            // lookup misses, so a read command silently runs with its defaults (e.g.
            // an unbounded result set) instead of reporting the malformed step.
            let arguments: ScriptValue
            switch step["arguments"] {
            case .none, .some(.null):
                arguments = .object([:])
            case let .some(value):
                guard case .object = value else {
                    throw ScriptingError.invalidArgument("step 'arguments' must be a JSON object")
                }
                arguments = value
            }
            results.append(try execute(command, arguments: arguments))
        }
        return .array(results)
    }

    /// The introspectable command surface (sorted by name).
    static var availableCommands: [ScriptingCommandInfo] {
        registry.values.map(\.info).sorted { $0.name < $1.name }
    }

    // MARK: - Registry

    static func readEvidenceOperation(_ arguments: ScriptValue) throws -> TypedReadRegistry.ExternalOperation {
        guard case .object(let fields) = arguments, Set(fields.keys) == ["operation"],
              let rawValue = fields["operation"]?.stringValue,
              let operation = TypedReadRegistry.ExternalOperation(rawValue: rawValue) else {
            throw ScriptingError.invalidArgument("read-evidence requires one supported operation")
        }
        return operation
    }

    private static func readEvidence(
        _ arguments: ScriptValue,
        store: WorkspaceStore,
        proposingPrincipal: Phase2Principal
    ) throws -> ScriptValue {
        let operation = try readEvidenceOperation(arguments)
        switch store.preparePhase2Read(operation: operation.operationID, proposingPrincipal: proposingPrincipal) {
        case .prepared(let prepared):
            if proposingPrincipal == .cli || proposingPrincipal == .mcp {
                // Each external call creates its own invocation and accepts no
                // caller-supplied replay handle. Its acceptance lives only until
                // this response is encoded, including transport rejection paths.
                var invocationAcceptor = Phase2EvidenceAcceptor()
                let execution = store.executePhase2Read(prepared, acceptingWith: &invocationAcceptor)
                return try readEvidenceResult(execution, authorization: prepared.authorization)
            }
            return try readEvidenceResult(store.executePhase2Read(prepared), authorization: prepared.authorization)
        case .unavailable(let reason):
            return .object([
                "schemaVersion": .int(1), "operation": .string(operation.rawValue),
                "status": .string("unavailable"), "reason": .string(reason.rawValue),
            ])
        case .rejected(let disposition):
            return .object([
                "schemaVersion": .int(1), "operation": .string(operation.rawValue),
                "status": .string("unavailable"), "reason": .string(disposition.rawValue),
            ])
        }
    }

    /// Only the app-accepted record supplies facts. Delayed, duplicate, cancelled,
    /// or stale candidates remain unavailable and never expose candidate data.
    static func readEvidenceResult(
        _ execution: Phase2ReadExecution,
        authorization: Phase2ReadAuthorization
    ) throws -> ScriptValue {
        var output: [String: ScriptValue] = [
            "schemaVersion": .int(1),
            "operation": .string(authorization.canonicalDescriptor.id.rawValue),
            "disposition": .string(execution.disposition.rawValue),
            "status": .string("unavailable"),
        ]
        guard authorization.isValid else {
            output["reason"] = .string("unauthorized")
            return .object(output)
        }
        guard TypedReadRegistry.ExternalOperation(rawValue: authorization.canonicalDescriptor.id.rawValue) != nil else {
            output["reason"] = .string("unsupported")
            return .object(output)
        }
        guard execution.disposition == .accepted,
              let evidence = execution.acceptedEvidence,
              execution.outcome.evidenceIDs == [evidence.evidenceID],
              evidence.candidateID == execution.candidate.candidateID,
              evidence.invocationID == authorization.request.invocationID,
              evidence.sequence == authorization.request.sequence,
              evidence.descriptor == authorization.canonicalDescriptor,
              evidence.precondition == authorization.request.precondition,
              evidence.data == execution.candidate.data else {
            output["reason"] = .string(execution.disposition.rawValue)
            return .object(output)
        }
        output["proposingPrincipal"] = .string(readPrincipalName(authorization.request.proposingPrincipal))
        output["authorizingPrincipal"] = .string(readPrincipalName(authorization.authorizingPrincipal))
        output["producingPrincipal"] = .string(readPrincipalName(evidence.producingPrincipal))
        output["evidenceID"] = .string(evidence.evidenceID.uuidString)
        output["invocationID"] = .string(evidence.invocationID.uuidString)
        output["sequence"] = .string(String(evidence.sequence))
        output["payloadDigest"] = .string(evidence.payloadDigest)
        output["descriptor"] = try exactReadJSON(evidence.descriptor)
        output["subject"] = try exactReadJSON(authorization.request.subject)
        output["precondition"] = try exactReadJSON(evidence.precondition)
        output["citations"] = try exactReadJSON(evidence.citations)
        switch evidence.data {
        case .value(let value):
            output["status"] = .string("accepted")
            output["facts"] = try readFacts(value)
        case .unavailable(let reason):
            output["reason"] = .string(reason.rawValue)
        case .conflict:
            // This adapter's three operations do not publish conflicts as facts.
            output["reason"] = .string("conflict")
        }
        return .object(output)
    }

    private static func readPrincipalName(_ principal: Phase2Principal) -> String {
        switch principal {
        case .app: "app"
        case .human: "human"
        case .model: "model"
        case .cli: "cli"
        case .mcp: "mcp"
        default: "unavailable"
        }
    }

    private static func readFacts(_ value: Phase2ReadFactValue) throws -> ScriptValue {
        switch value {
        case .boolean(let value): return .bool(value)
        case .signedInteger(let value): return .string(String(value))
        case .unsignedInteger(let value): return .string(String(value))
        case .text(let value): return .string(value)
        case .staticLocation(let value): return try exactReadJSON(value)
        case .list(let values): return .array(try values.map(readFacts))
        case .object(let fields):
            var object: [String: ScriptValue] = [:]
            for field in fields { object[field.name] = try readFacts(field.value) }
            return .object(object)
        }
    }

    /// `reconstruction-jobs`: the pure `ReconstructionJobStatusSummary` of every durable job (or the
    /// one named by `job`), newest creation first. Numbers are exact decimal strings.
    static func reconstructionJobsStatus(_ arguments: ScriptValue,
        state: ReconstructionWorkspaceState,
        lifecycle: ReconstructionLifecycleTimestamps = .empty) throws -> ScriptValue {
        let jobIDs: [UUID]
        if let raw = arguments["job"]?.stringValue {
            guard let jobID = UUID(uuidString: raw), state.jobs.contains(where: { $0.jobID == jobID }) else {
                throw ScriptingError.invalidArgument("job must name an existing Reconstruction job UUID")
            }
            jobIDs = [jobID]
        } else {
            jobIDs = state.jobs.sorted { ($0.creationOrdinal ?? 0) > ($1.creationOrdinal ?? 0) }.map(\.jobID)
        }
        return .array(try jobIDs.prefix(64).compactMap { jobID in
            try ReconstructionJobStatusSummary.make(jobID: jobID, state: state, lifecycle: lifecycle).map(exactReadJSON)
        })
    }

    /// Codable metadata is parsed as exact number lexemes and rendered as decimal
    /// strings. Neither UInt64 addresses nor revision identities cross Double/NSNumber.
    private static func exactReadJSON<Value: Encodable>(_ value: Value) throws -> ScriptValue {
        let bytes = try JSONEncoder().encode(value)
        let json = try Phase2StrictJSONParser().parse(bytes, limits: .init(
            maximumBytes: Phase2ReadLimits.maximum.encodedResultBytes,
            maximumDepth: 32, maximumTokens: 100_000, maximumMembersAndElements: 50_000
        ))
        func convert(_ value: Phase2ProductionJSONValue) -> ScriptValue {
            switch value {
            case .null: return .null
            case .bool(let value): return .bool(value)
            case .number(let source): return .string(source)
            case .string(let value): return .string(value)
            case .array(let values): return .array(values.map(convert))
            case .object(let fields): return .object(fields.mapValues(convert))
            }
        }
        return convert(json)
    }

    private struct Command {
        var info: ScriptingCommandInfo
        var run: @MainActor (ScriptValue, WorkspaceStore) throws -> ScriptValue
    }

    nonisolated static func address(_ arguments: ScriptValue, _ key: String) throws -> UInt64 {
        guard let value = arguments[key] else { throw ScriptingError.missingArgument(key) }
        guard let address = value.addressValue else { throw ScriptingError.invalidArgument("\(key) must be an address") }
        return address
    }

    private static func string(_ arguments: ScriptValue, _ key: String) throws -> String {
        guard let value = arguments[key] else { throw ScriptingError.missingArgument(key) }
        guard let text = value.stringValue else { throw ScriptingError.invalidArgument("\(key) must be a string") }
        return text
    }

    /// A non-negative row cap from the `limit` argument (nil = no limit). A negative
    /// value is clamped to 0 so it can never trap `Collection.prefix(_:)`, which
    /// requires a non-negative length.
    nonisolated static func rowLimit(_ arguments: ScriptValue) -> Int? {
        arguments["limit"]?.intValue.map { Int(max(0, $0)) }
    }

    /// Validates the bounded C type-name subset accepted by scripted signature
    /// authoring. This is deliberately a syntax seam, not an ABI classifier:
    /// opaque identifiers, record types, and fixed/unsized arrays are valid here
    /// even when `DarwinARM64ParameterBinder` later leaves them unbound.
    ///
    /// Accepted forms are an optionally-qualified scalar/opaque/record base,
    /// followed by zero or more qualified `*` levels and then zero or more `[]`
    /// or decimal `[N]` suffixes. Parenthesized/function/block declarators,
    /// expressions in array bounds, and non-ASCII extension spellings are outside
    /// this conservative grammar and fail before any workspace mutation.
    private static func isValidSignatureParameterType(_ source: String) -> Bool {
        guard let tokens = signatureParameterTypeTokens(source), !tokens.isEmpty else {
            return false
        }

        var position = 0
        var baseWords: [String] = []
        while position < tokens.count,
              case let .identifier(word) = tokens[position] {
            baseWords.append(word)
            position += 1
        }
        guard isValidSignatureParameterBase(baseWords) else { return false }

        var pointerCount = 0
        while position < tokens.count, tokens[position] == .star {
            pointerCount += 1
            position += 1
            while position < tokens.count,
                  case let .identifier(qualifier) = tokens[position],
                  signaturePointerQualifiers.contains(qualifier) {
                position += 1
            }
        }

        while position < tokens.count, tokens[position] == .leftBracket {
            position += 1
            if position < tokens.count, tokens[position] == .decimalNumber {
                position += 1
            }
            guard position < tokens.count, tokens[position] == .rightBracket else {
                return false
            }
            position += 1
        }

        // `void *` is a valid data pointer; a named parameter whose entire type is
        // bare `void` is not a value-bearing parameter row.
        let unqualifiedBase = baseWords.filter { !signatureBaseQualifiers.contains($0) }
        if unqualifiedBase == ["void"], pointerCount == 0 { return false }
        return position == tokens.count
    }

    private enum SignatureParameterTypeToken: Equatable {
        case identifier(String)
        case decimalNumber
        case star
        case leftBracket
        case rightBracket
    }

    private static let signatureParameterTypeMaxBytes = 4_096
    private static let signatureBaseQualifiers: Set<String> = [
        "const", "volatile", "restrict", "__restrict", "__restrict__", "_Atomic",
    ]
    private static let signaturePointerQualifiers: Set<String> = [
        "const", "volatile", "restrict", "__restrict", "__restrict__",
    ]
    private static let signatureRecordKeywords: Set<String> = ["struct", "union", "enum"]
    private static let signatureFundamentalIntegerWords: Set<String> = [
        "signed", "unsigned", "char", "short", "int", "long",
    ]
    private static let signatureReservedWords: Set<String> = [
        "_Alignas", "_Alignof", "_Atomic", "_Bool", "_Complex", "_Generic",
        "_Imaginary", "_Noreturn", "_Static_assert", "_Thread_local",
        "auto", "break", "case", "char", "const", "continue", "default", "do",
        "double", "else", "enum", "extern", "float", "for", "goto", "if",
        "inline", "int", "long", "register", "restrict", "return", "short",
        "signed", "sizeof", "static", "struct", "switch", "typedef", "union",
        "unsigned", "void", "volatile", "while",
    ]

    private static func signatureParameterTypeTokens(
        _ source: String
    ) -> [SignatureParameterTypeToken]? {
        let bytes = Array(source.utf8)
        guard !bytes.isEmpty, bytes.count <= signatureParameterTypeMaxBytes else {
            return nil
        }

        var tokens: [SignatureParameterTypeToken] = []
        var position = 0
        while position < bytes.count {
            let byte = bytes[position]
            if isASCIISpace(byte) {
                position += 1
                continue
            }
            if isASCIIIdentifierStart(byte) {
                let start = position
                position += 1
                while position < bytes.count, isASCIIIdentifierContinue(bytes[position]) {
                    position += 1
                }
                tokens.append(.identifier(String(decoding: bytes[start..<position], as: UTF8.self)))
                continue
            }
            if isASCIIDigit(byte) {
                position += 1
                while position < bytes.count, isASCIIDigit(bytes[position]) {
                    position += 1
                }
                tokens.append(.decimalNumber)
                continue
            }
            switch byte {
            case 0x2A: tokens.append(.star)         // *
            case 0x5B: tokens.append(.leftBracket) // [
            case 0x5D: tokens.append(.rightBracket)// ]
            default: return nil
            }
            position += 1
        }
        return tokens
    }

    private static func isValidSignatureParameterBase(_ words: [String]) -> Bool {
        let base = words.filter { !signatureBaseQualifiers.contains($0) }
        guard !base.isEmpty else { return false }

        if base.count == 2,
           signatureRecordKeywords.contains(base[0]),
           isSignatureOpaqueIdentifier(base[1]) {
            return true
        }
        if base.count == 1 {
            let word = base[0]
            if word == "void" || word == "bool" || word == "_Bool"
                || word == "float" || word == "double" {
                return true
            }
            if signatureFundamentalIntegerWords.contains(word) {
                return isValidFundamentalIntegerWords(base)
            }
            return isSignatureOpaqueIdentifier(word)
        }
        if Set(base).isSubset(of: signatureFundamentalIntegerWords) {
            return isValidFundamentalIntegerWords(base)
        }
        if base.count == 2, Set(base) == Set(["long", "double"]) {
            return true
        }
        return false
    }

    private static func isValidFundamentalIntegerWords(_ words: [String]) -> Bool {
        let signedCount = words.filter { $0 == "signed" }.count
        let unsignedCount = words.filter { $0 == "unsigned" }.count
        let charCount = words.filter { $0 == "char" }.count
        let shortCount = words.filter { $0 == "short" }.count
        let intCount = words.filter { $0 == "int" }.count
        let longCount = words.filter { $0 == "long" }.count
        guard signedCount <= 1,
              unsignedCount <= 1,
              signedCount + unsignedCount <= 1,
              charCount <= 1,
              shortCount <= 1,
              intCount <= 1,
              longCount <= 2 else {
            return false
        }
        if charCount == 1 {
            return shortCount == 0 && intCount == 0 && longCount == 0
        }
        if shortCount == 1 {
            return charCount == 0 && longCount == 0
        }
        if longCount > 0 {
            return charCount == 0 && shortCount == 0
        }
        return intCount == 1 || signedCount == 1 || unsignedCount == 1
    }

    private static func isSignatureOpaqueIdentifier(_ word: String) -> Bool {
        guard !word.isEmpty, !signatureReservedWords.contains(word) else { return false }
        let bytes = Array(word.utf8)
        guard let first = bytes.first, isASCIIIdentifierStart(first) else { return false }
        return bytes.dropFirst().allSatisfy(isASCIIIdentifierContinue)
    }

    private static func isASCIISpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
    }

    private static func isASCIIIdentifierStart(_ byte: UInt8) -> Bool {
        byte == 0x5F || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    private static func isASCIIIdentifierContinue(_ byte: UInt8) -> Bool {
        isASCIIIdentifierStart(byte) || isASCIIDigit(byte)
    }

    /// Parses a SIGNED rebase delta: a JSON integer (handling negatives), or a string of
    /// the form `[-]0x…` (hex) or `[-]…` (decimal). Returns nil on an unparseable input.
    /// Unlike `addressValue` this MUST accept negatives — a rebase can shift addresses down.
    static func signedDelta(_ value: ScriptValue) -> Int64? {
        if let intValue = value.intValue { return intValue }
        guard let text = value.stringValue else { return nil }
        var body = text.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        var negative = false
        if body.hasPrefix("-") { negative = true; body = String(body.dropFirst()) }
        else if body.hasPrefix("+") { body = String(body.dropFirst()) }
        let magnitude: UInt64?
        if body.lowercased().hasPrefix("0x") {
            magnitude = UInt64(body.dropFirst(2), radix: 16)
        } else {
            magnitude = UInt64(body)
        }
        guard let magnitude else { return nil }
        if negative {
            // -magnitude as Int64, two's-complement safe for the full negative range
            // (including Int64.min, whose magnitude is 2^63 and exceeds Int64.max).
            guard magnitude <= UInt64(Int64.max) + 1 else { return nil }
            return Int64(bitPattern: ~magnitude &+ 1)
        }
        guard magnitude <= UInt64(Int64.max) else { return nil }
        return Int64(magnitude)
    }

    /// Resolves a function from a `function` name argument or an `address` (a function
    /// start, or any address inside a function's range).
    /// Acceptance commits the undoable authoring layer even when derived analysis fails.
    /// Report both outcomes so callers can correct/clear the retained edit rather than
    /// interpreting a thrown error as evidence that the document stayed unchanged.
    private static func committedPatchResult(
        _ address: UInt64, patch: BytePatch, diagnostic: String?
    ) -> ScriptValue {
        var fields: [String: ScriptValue] = [
            "ok": .bool(true), "committed": .bool(true), "address": .hex(address),
            "bytes": .string(patch.byteText),
            "reanalysisStatus": .string(diagnostic == nil ? "no-error-reported" : "failed"),
        ]
        if let diagnostic { fields["reanalysisDiagnostic"] = .string(diagnostic) }
        return .object(fields)
    }

    /// Primary-image resolver: the scope of `functions`, `instructions`, `decompile`, the
    /// call graph and register-rename commands (the snapshot's primary convenience projections).
    /// Name writes that these reads observe (`rename`, `rename-register`, `clear-register-name`)
    /// bind to the same `snapshot.primarySlot`, never to live focus, so a rename made while a
    /// sibling image is focused is still the label `functions` lists and the selector resolves.
    nonisolated static func resolveFunction(_ arguments: ScriptValue, _ snapshot: WorkspaceSnapshot) throws -> FunctionSummary {
        try resolveFunction(arguments, in: snapshot.functions, slot: snapshot.primarySlot, snapshot: snapshot)
    }

    /// Slot-aware resolver for commands that intentionally target a focused image
    /// rather than the snapshot's primary-image convenience projections. Name selectors
    /// match the effective display label in `slot` (the same name `functions` lists, so a
    /// user rename wins) or the raw analysis name, and fail closed on any ambiguity.
    /// Address selectors keep their existing interior/zero-width/nearest-preceding semantics.
    nonisolated private static func resolveFunction(
        _ arguments: ScriptValue,
        in functions: [FunctionSummary],
        slot: ImageSlot,
        snapshot: WorkspaceSnapshot
    ) throws -> FunctionSummary {
        if let name = arguments["function"]?.stringValue {
            return try resolveFunctionName(name, in: functions) { function in
                snapshot.displayName(at: function.startAddress, in: slot, default: function.name)
            }
        }
        if let target = arguments["address"]?.addressValue {
            // The canonical resolver handles interior addresses AND zero-width functions
            // (end collapsed to start) the same way the GUI does — a bare `target < endAddress`
            // test would never match inside a zero-width function.
            if let function = functions.first(where: { function in
                function.endAddress > function.startAddress
                    ? target >= function.startAddress && target < function.endAddress
                    : target == function.startAddress
            }) ?? functions
                .filter({ $0.startAddress <= target })
                .max(by: { $0.startAddress < $1.startAddress }) {
                return function
            }
            throw ScriptingError.invalidArgument("no function at that address")
        }
        throw ScriptingError.missingArgument("function or address")
    }

    /// The general name-selector policy (MS-06). A function is a candidate when `name`
    /// equals its effective display label (user rename / imported name, read in the
    /// command's image scope) OR its raw analysis name, so the listed name round-trips and
    /// unrenamed raw names keep working. More than one candidate — duplicate display labels,
    /// duplicate raw names, or one function's label equal to a different function's raw
    /// name — is rejected with a typed ambiguity error instead of picking array order.
    /// `call-argument-audit` deliberately does NOT use this: its structural contract
    /// matches raw names only (`resolveCallArgumentAuditFunction`).
    nonisolated static func resolveFunctionName(
        _ name: String,
        in functions: [FunctionSummary],
        displayName: (FunctionSummary) -> String
    ) throws -> FunctionSummary {
        let matches = functions.filter { function in
            function.name == name || displayName(function) == name
        }
        guard let first = matches.first else {
            throw ScriptingError.invalidArgument("no function named '\(name)'")
        }
        guard matches.count == 1 else {
            throw ScriptingError.ambiguousFunctionSelector(
                name: name, addresses: matches.map(\.startAddress)
            )
        }
        return first
    }

    nonisolated static func instructionObject(_ row: InstructionRow, _ snapshot: WorkspaceSnapshot) -> ScriptValue {
        var fields: [String: ScriptValue] = [
            "address": .hex(row.address),
            "bytes": .string(row.bytes),
            "mnemonic": .string(row.mnemonic),
            "operands": .string(row.operands),
        ]
        if let comment = snapshot.displayComment(at: row.address, default: row.comment) {
            fields["comment"] = .string(comment)
        }
        return .object(fields)
    }

    nonisolated private static func pseudocodeLineObject(_ line: PseudocodeLine) -> ScriptValue {
        var fields: [String: ScriptValue] = [
            "n": .int(Int64(line.lineNumber)),
            "kind": .string(line.kind.rawValue),
            "text": .string(line.text),
        ]
        if let address = line.sourceAddress {
            fields["address"] = .hex(address)
        }
        return .object(fields)
    }

    nonisolated private static func pseudocodeRegionObject(_ node: PseudocodeRegionNode) -> ScriptValue {
        var fields: [String: ScriptValue] = [
            "kind": .string(node.kind.rawValue),
            "startLine": .int(Int64(node.startLine)),
            "endLine": .int(Int64(node.endLine)),
            "children": .array(node.children.map { pseudocodeRegionObject($0) }),
        ]
        if let condition = node.condition {
            fields["condition"] = .string(condition)
        }
        if let conditionSourceAddress = node.conditionSourceAddress {
            fields["conditionAddress"] = .hex(conditionSourceAddress)
        }
        return .object(fields)
    }

    nonisolated private static func parameterBindingAuditObject(
        _ audit: MacIRParameterBindingAudit
    ) -> ScriptValue {
        let records = audit.records.map { record -> ScriptValue in
            .object([
                "function": .string(record.function),
                "declaration_mode": .string(record.declarationMode.rawValue),
                "row_ordinal": .int(Int64(record.rowOrdinal)),
                "binding": record.binding.map(ScriptValue.string) ?? .null,
                "source_position": record.sourcePosition.map { .int(Int64($0)) } ?? .null,
                "location": .string(record.location),
                "evidence": .string(record.evidence),
                "name": .string(record.name),
                "type": .string(record.type),
                "body_uses": .array(record.bodyUses.map { use in
                    .object([
                        "address": .hex(use.address),
                        "occurrence": .int(Int64(use.occurrence)),
                    ])
                }),
            ])
        }
        let danglingBodyUses = audit.danglingBodyUses.map { dangling in
            ScriptValue.object([
                "binding": .string(dangling.binding),
                "address": .hex(dangling.use.address),
                "occurrence": .int(Int64(dangling.use.occurrence)),
            ])
        }
        return .object([
            "schema": .string(MacIRParameterBindingAudit.schema),
            "validation_scope": .string("structural-candidate"),
            "combined_oracle_comparison": .bool(false),
            "function": .string(audit.function),
            "address": .hex(audit.address),
            "declaration_mode": .string(audit.declarationMode.rawValue),
            "records": .array(records),
            "dangling_body_uses": .array(danglingBodyUses),
        ])
    }

    private struct CallArgumentSafeRenderClassification {
        var included: Bool
        var reason: String
    }

    /// One active-runtime sample per MacScope process. Standalone sweep invocations use a
    /// fresh process and the producer independently snapshots/rechecks the same identity.
    private static var cachedCallArgumentAuditToolchainIdentity: ScriptValue?

    /// The call-audit contract is stricter than the legacy shared resolver: callers must
    /// provide exactly one selector, and a present selector must have the right JSON type.
    private static func resolveCallArgumentAuditFunction(
        _ arguments: ScriptValue,
        in functions: [FunctionSummary]
    ) throws -> FunctionSummary {
        let hasFunction = arguments["function"] != nil
        let hasAddress = arguments["address"] != nil
        guard hasFunction != hasAddress else {
            if hasFunction {
                throw ScriptingError.invalidArgument(
                    "function and address are mutually exclusive"
                )
            }
            throw ScriptingError.missingArgument("function or address")
        }
        // ★ Insight
        //
        // Local/static symbols can legitimately duplicate a name, and malformed or
        // synthetic analysis snapshots can contain overlapping ranges. Picking the
        // first match would make audit identity depend on array order. An exact start
        // does not outrank another containing range: the frozen selector contract also
        // accepts interior addresses, so every matching range is equally relevant and
        // ambiguity must fail closed.
        if hasFunction {
            guard let name = arguments["function"]?.stringValue else {
                throw ScriptingError.invalidArgument("function must be a string")
            }
            let matches = functions.filter { $0.name == name }
            guard !matches.isEmpty else {
                throw ScriptingError.invalidArgument("no function named '\(name)'")
            }
            guard matches.count == 1 else {
                throw ScriptingError.invalidArgument(
                    "function selector '\(name)' is ambiguous (\(matches.count) matches)"
                )
            }
            return matches[0]
        }
        guard arguments["address"]?.addressValue != nil else {
            throw ScriptingError.invalidArgument("address must be an address")
        }
        let target = arguments["address"]!.addressValue!
        let matches = functions.filter { function in
            function.endAddress > function.startAddress
                ? target >= function.startAddress && target < function.endAddress
                : target == function.startAddress
        }
        guard !matches.isEmpty else {
            throw ScriptingError.invalidArgument("no function at that address")
        }
        guard matches.count == 1 else {
            let targetText = ScriptValue.hex(target).stringValue ?? "<invalid-address>"
            throw ScriptingError.invalidArgument(
                "address selector \(targetText) is ambiguous (\(matches.count) matches)"
            )
        }
        return matches[0]
    }

    private static func callArgumentAuditInteger(
        _ value: Int,
        field: String,
        minimum: Int = Int.min
    ) throws -> ScriptValue {
        guard value >= minimum, let exact = Int64(exactly: value) else {
            throw ScriptingError.invalidArgument("\(field) is outside the audit integer range")
        }
        return .int(exact)
    }

    private static func callArgumentAuditString(
        _ value: String,
        field: String,
        allowEmpty: Bool = false
    ) throws -> ScriptValue {
        guard (allowEmpty || !value.isEmpty),
              !value.unicodeScalars.contains(where: { scalar in
                  if scalar.value == 0x2028 || scalar.value == 0x2029 { return true }
                  switch scalar.properties.generalCategory {
                  case .control, .format, .surrogate, .privateUse, .unassigned:
                      return true
                  default:
                      return false
                  }
              }) else {
            throw ScriptingError.invalidArgument("\(field) is not a canonical audit string")
        }
        return .string(value)
    }

    private static func isCanonicalAuditValueRegister(_ name: String) -> Bool {
        if ["sp", "wsp", "xzr", "wzr"].contains(name) { return true }
        guard let prefix = name.first,
              let index = Int(name.dropFirst()),
              String(index) == String(name.dropFirst()) else {
            return false
        }
        switch prefix {
        case "x", "w": return (0...30).contains(index)
        case "s", "d", "q", "v": return (0...31).contains(index)
        default: return false
        }
    }

    /// Structural identity only: selector substitutions and every other printer-only
    /// projection are deliberately excluded. Root depth is zero; nodes at depth 32 are
    /// accepted, while attempting to serialize any child at depth 33 fails closed.
    static func callArgumentAuditValueObject(
        _ value: MacIRValue,
        depth: Int = 0
    ) throws -> ScriptValue {
        guard depth <= 32 else {
            throw ScriptingError.invalidArgument(
                "call argument value exceeds the structural recursion limit"
            )
        }
        switch value {
        case let .register(name, version):
            guard isCanonicalAuditValueRegister(name), version >= 0 else {
                throw ScriptingError.invalidArgument("call argument register identity is invalid")
            }
            return .object([
                "kind": .string("register"),
                "name": .string(name),
                "version": try callArgumentAuditInteger(
                    version, field: "value_identity.version", minimum: 0
                ),
            ])
        case let .argument(bindingID):
            let bindingKind = switch bindingID.kind {
            case .gpr: "gpr"
            case .simd: "simd"
            case .entryStack: "entry-stack"
            }
            return .object([
                "kind": .string("argument"),
                "binding_kind": .string(bindingKind),
                "binding_value": try callArgumentAuditInteger(
                    bindingID.value, field: "value_identity.binding_value", minimum: 0
                ),
            ])
        case let .argumentFragment(rowID, offset, size):
            return .object([
                "kind": .string("argument-fragment"),
                "source_row": try callArgumentAuditString(rowID.rawValue, field: "value_identity.source_row"),
                "byte_offset": try callArgumentAuditInteger(offset, field: "value_identity.byte_offset", minimum: 0),
                "size": try callArgumentAuditInteger(size, field: "value_identity.size", minimum: 1),
            ])
        case let .abiComposite(type, fragments):
            guard (1...4).contains(fragments.count) else {
                throw ScriptingError.invalidArgument("aggregate fragment count is outside 1...4")
            }
            return .object([
                "kind": .string("abi-composite"),
                "type": try callArgumentAuditString(type, field: "value_identity.type"),
                "fragments": .array(try fragments.map {
                    try callArgumentAuditValueObject($0, depth: depth + 1)
                }),
            ])
        case let .immediate(immediate):
            return .object(["kind": .string("immediate"), "value": .int(immediate)])
        case let .stackSlot(offset):
            return .object(["kind": .string("stack-slot"), "offset": .int(offset)])
        case let .symbol(name):
            return .object([
                "kind": .string("symbol"),
                "name": try callArgumentAuditString(name, field: "value_identity.name"),
            ])
        case let .temporary(index):
            return .object([
                "kind": .string("temporary"),
                "index": try callArgumentAuditInteger(
                    index, field: "value_identity.index", minimum: 0
                ),
            ])
        case let .bitTest(nested, bit):
            guard (0...127).contains(bit) else {
                throw ScriptingError.invalidArgument("value_identity.bit is outside 0...127")
            }
            return .object([
                "kind": .string("bit-test"),
                "value": try callArgumentAuditValueObject(nested, depth: depth + 1),
                "bit": .int(bit),
            ])
        case let .unary(op, nested):
            return .object([
                "kind": .string("unary"),
                "operator": try callArgumentAuditString(op, field: "value_identity.operator"),
                "value": try callArgumentAuditValueObject(nested, depth: depth + 1),
            ])
        case let .binaryExpression(op, left, right):
            return .object([
                "kind": .string("binary"),
                "operator": try callArgumentAuditString(op, field: "value_identity.operator"),
                "left": try callArgumentAuditValueObject(left, depth: depth + 1),
                "right": try callArgumentAuditValueObject(right, depth: depth + 1),
            ])
        case let .signedBitfield(field):
            return .object([
                "kind": .string("signed-bitfield"),
                "source": try callArgumentAuditValueObject(field.source, depth: depth + 1),
                "operand_bits": .int(Int64(field.operandBits)),
                "source_lsb": .int(field.sourceLSB),
                "field_bits": .int(field.fieldBits),
                "insert_lsb": .int(field.insertLSB),
                "origin": .object([
                    "function_name": .string(field.origin.functionName),
                    "function_start": .string(String(field.origin.functionStart, radix: 16)),
                    "instruction_address": .string(String(field.origin.instructionAddress, radix: 16)),
                    "mnemonic": .string(field.origin.mnemonic),
                    "source_register": .string(field.origin.sourceRegister),
                    "destination_register": .string(field.origin.destinationRegister),
                    "definition": try callArgumentAuditValueObject(field.origin.definition, depth: depth + 2),
                    "definition_bits": .int(Int64(field.origin.definitionBits)),
                ]),
            ])
        case let .unknown(text):
            return .object([
                "kind": .string("unknown"),
                "text": try callArgumentAuditString(
                    text, field: "value_identity.text", allowEmpty: true
                ),
            ])
        }
    }

    private static func callArgumentAuditLocationObject(
        _ location: MacIRCallArgumentLocation
    ) throws -> ScriptValue {
        switch location {
        case let .gpr(index, carrierWidth):
            guard (0..<8).contains(index), carrierWidth == 32 || carrierWidth == 64 else {
                throw ScriptingError.invalidArgument("call argument GPR location is invalid")
            }
            return .object([
                "kind": .string("gpr"),
                "index": .int(Int64(index)),
                "carrier_width": .int(Int64(carrierWidth)),
                "scalar_width": .null,
                "byte_offset": .null,
                "size": .null,
                "alignment": .null,
            ])
        case let .simd(index, scalarWidth):
            guard (0..<8).contains(index), scalarWidth == 32 || scalarWidth == 64 else {
                throw ScriptingError.invalidArgument("call argument SIMD location is invalid")
            }
            return .object([
                "kind": .string("simd"),
                "index": .int(Int64(index)),
                "carrier_width": .null,
                "scalar_width": .int(Int64(scalarWidth)),
                "byte_offset": .null,
                "size": .null,
                "alignment": .null,
            ])
        case let .callStack(byteOffset, size, alignment):
            let (end, overflow) = byteOffset.addingReportingOverflow(size)
            guard byteOffset >= 0, size > 0, alignment > 0,
                  alignment.nonzeroBitCount == 1, byteOffset.isMultiple(of: alignment),
                  !overflow, end > byteOffset else {
                throw ScriptingError.invalidArgument("call argument stack location is invalid")
            }
            return .object([
                "kind": .string("call-stack"),
                "index": .null,
                "carrier_width": .null,
                "scalar_width": .null,
                "byte_offset": try callArgumentAuditInteger(
                    byteOffset, field: "location.byte_offset", minimum: 0
                ),
                "size": try callArgumentAuditInteger(size, field: "location.size", minimum: 1),
                "alignment": try callArgumentAuditInteger(
                    alignment, field: "location.alignment", minimum: 1
                ),
            ])
        }
    }

    private static func callArgumentAuditObservationObject(
        _ scope: MacIRCallArgumentObservationScope
    ) throws -> ScriptValue {
        .object([
            "gpr_indices": .array(scope.canonicalGPRIndicesForAudit.map {
                .int(Int64($0))
            }),
            "scalar_simd_indices": .array(scope.canonicalScalarSIMDIndicesForAudit.map {
                .int(Int64($0))
            }),
            "call_stack_ranges": .array(try scope.canonicalCallStackRangesForAudit.map { range in
                .object([
                    "start": try callArgumentAuditInteger(
                        range.lowerBound, field: "observation.call_stack_ranges.start", minimum: 0
                    ),
                    "end": try callArgumentAuditInteger(
                        range.upperBound, field: "observation.call_stack_ranges.end", minimum: 1
                    ),
                ])
            }),
        ])
    }

    private static func isConservativeAuditSelectorIdentifier(_ selector: String) -> Bool {
        guard let first = selector.utf8.first,
              first == 0x5f || (0x41...0x5a).contains(first) || (0x61...0x7a).contains(first) else {
            return false
        }
        return selector.utf8.dropFirst().allSatisfy { byte in
            byte == 0x5f
                || (0x41...0x5a).contains(byte)
                || (0x61...0x7a).contains(byte)
                || (0x30...0x39).contains(byte)
        }
    }

    /// ★ Insight
    ///
    /// A rendered call line may repeat `_objc_msgSend(...)` in its diagnostic comment even
    /// when the executable statement is a valid bracket message. Match only the statement
    /// before its one top-level semicolon, using the same conservative grammar as the frozen
    /// Python producer/comparator.
    static func isExactZeroSelectorMessageForAudit(
        _ renderedLine: String,
        selector: String
    ) -> Bool {
        guard isConservativeAuditSelectorIdentifier(selector),
              !renderedLine.contains("\r"), !renderedLine.contains("\n") else {
            return false
        }
        var inString = false
        var escaped = false
        var depth = 0
        var semicolon: String.Index?
        statementScan: for index in renderedLine.indices {
            let character = renderedLine[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            switch character {
            case "\"":
                inString = true
            case "(", "[":
                depth += 1
            case ")", "]":
                depth -= 1
                if depth < 0 { return false }
            case ";" where depth == 0:
                semicolon = index
                break statementScan
            default:
                break
            }
        }
        guard let semicolon else { return false }
        let body = String(renderedLine[..<semicolon])
            .trimmingCharacters(in: .whitespaces)
        let suffix = String(renderedLine[renderedLine.index(after: semicolon)...])
        guard suffix.isEmpty || suffix.hasPrefix(" //"),
              body.hasSuffix("]"),
              let openBracket = body.firstIndex(of: "[") else {
            return false
        }
        let prefix = String(body[..<openBracket])
            .trimmingCharacters(in: .whitespaces)
        guard prefix.isEmpty || prefix == "return" || prefix.hasSuffix("=") else {
            return false
        }
        let closingBracket = body.index(before: body.endIndex)
        var bracketDepth = 0
        inString = false
        escaped = false
        for index in body[openBracket...].indices {
            let character = body[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            switch character {
            case "\"":
                inString = true
            case "[":
                bracketDepth += 1
            case "]":
                bracketDepth -= 1
                if bracketDepth < 0 || (bracketDepth == 0 && index != closingBracket) {
                    return false
                }
            default:
                break
            }
        }
        guard !inString, bracketDepth == 0 else { return false }
        let contentStart = body.index(after: openBracket)
        let content = String(body[contentStart..<closingBracket])
        let marker = " \(selector)"
        guard content.hasSuffix(marker) else { return false }
        return !content.dropLast(marker.count)
            .trimmingCharacters(in: .whitespaces)
            .isEmpty
    }

    nonisolated static func machineCallArgumentAuditClassifications(
        frame: MacIRCallFrame
    ) -> [MacIRCallArgumentPhysicalKey: (included: Bool, reason: String)]? {
        guard frame.knownSignature == nil, let rendered = frame.machineRenderArguments else { return nil }
        let keys = Set(rendered.compactMap { $0.location.physicalKey })
        var result: [MacIRCallArgumentPhysicalKey: (included: Bool, reason: String)] = [:]
        for argument in frame.arguments.canonicalPhysicalEntriesForAudit {
            guard argument.role == .unknown, let key = argument.location.physicalKey else { return nil }
            result[key] = keys.contains(key)
                ? (true, "machine-register-input") : (false, "unknown-gap")
        }
        return result
    }

    private static func callArgumentAuditSafeClassifications(
        frame: MacIRCallFrame,
        renderedLine: String
    ) throws -> [MacIRCallArgumentPhysicalKey: CallArgumentSafeRenderClassification] {
        let arguments = frame.arguments.canonicalPhysicalEntriesForAudit
        var result: [MacIRCallArgumentPhysicalKey: CallArgumentSafeRenderClassification] = [:]
        if frame.knownSignature != nil {
            var fixedPositions: Set<Int> = []
            let formatTailRenders: Bool = {
                guard case .formatString = frame.tailCountEvidence else { return false }
                return frame.completeKnownVariadicRenderValues() != nil
            }()
            for argument in arguments {
                if case let .anonymousVariadic(tailOrdinal) = argument.role,
                   case .formatString = frame.tailCountEvidence,
                   tailOrdinal >= 0,
                   let key = argument.location.physicalKey {
                    // HOP-5c: a format-string tail renders exactly when the frame is complete.
                    result[key] = CallArgumentSafeRenderClassification(
                        included: formatTailRenders,
                        reason: formatTailRenders ? "format-string-tail" : "format-string-tail-gap"
                    )
                    continue
                }
                guard case let .fixed(sourcePosition) = argument.role,
                      sourcePosition >= 0 else {
                    throw ScriptingError.invalidArgument(
                        "known call contains a non-fixed Phase-A argument"
                    )
                }
                fixedPositions.insert(sourcePosition)
            }
            var denseFixedCount = 0
            while fixedPositions.contains(denseFixedCount) { denseFixedCount += 1 }

            let selectorRows = arguments.filter { $0.selectorEvidence != nil }
            var completeZeroMessage = false
            if frame.expectedTailCount == 0,
               selectorRows.count == 1,
               let selector = selectorRows[0].selectorEvidence,
               selectorRows[0].location == .gpr(index: 1, carrierWidth: 64),
               selectorRows[0].role == .fixed(sourcePosition: 1),
               fixedPositions == Set([0, 1]),
               isConservativeAuditSelectorIdentifier(selector.name) {
                guard isExactZeroSelectorMessageForAudit(renderedLine, selector: selector.name) else {
                    throw ScriptingError.invalidArgument(
                        "zero-tail Objective-C call did not render as its bracket message"
                    )
                }
                completeZeroMessage = true
            }
            for argument in arguments where argument.tailOrdinal == nil {
                guard let key = argument.location.physicalKey,
                      let position = argument.sourcePosition else {
                    throw ScriptingError.invalidArgument("known call argument lacks a physical key")
                }
                result[key] = if completeZeroMessage {
                    CallArgumentSafeRenderClassification(
                        included: true, reason: "objc-complete-message"
                    )
                } else if position < denseFixedCount {
                    CallArgumentSafeRenderClassification(included: true, reason: "fixed-prefix")
                } else {
                    CallArgumentSafeRenderClassification(included: false, reason: "fixed-gap")
                }
            }
            return result
        }

        if let machine = machineCallArgumentAuditClassifications(frame: frame) {
            return machine.mapValues {
                CallArgumentSafeRenderClassification(included: $0.included, reason: $0.reason)
            }
        }

        let observation = frame.arguments.observationScope
        let observedGPRs = Set(observation.canonicalGPRIndicesForAudit)
        let argumentGPRs = Set(arguments.compactMap { argument -> Int? in
            guard case let .gpr(index, _) = argument.location else { return nil }
            return index
        })
        let allArgumentsAreGPR = arguments.allSatisfy {
            if case .gpr = $0.location { return true }
            return false
        }
        let hasObservedSIMD = !observation.canonicalScalarSIMDIndicesForAudit.isEmpty
        let hasObservedStack = !observation.canonicalCallStackRangesForAudit.isEmpty
        let canRenderPrefix = allArgumentsAreGPR
            && !hasObservedSIMD
            && !hasObservedStack
            && observedGPRs.contains(0)
        var denseUnknownCount = 0
        if canRenderPrefix {
            while observedGPRs.contains(denseUnknownCount)
                    && argumentGPRs.contains(denseUnknownCount) {
                denseUnknownCount += 1
            }
        }
        for argument in arguments {
            guard argument.role == .unknown, let key = argument.location.physicalKey else {
                throw ScriptingError.invalidArgument(
                    "unknown call contains a non-unknown or invalid argument"
                )
            }
            let classification: CallArgumentSafeRenderClassification
            if canRenderPrefix,
               case let .gpr(index, _) = argument.location,
               index < denseUnknownCount {
                classification = CallArgumentSafeRenderClassification(
                    included: true, reason: "unknown-gpr-prefix"
                )
            } else if case .callStack = argument.location {
                classification = CallArgumentSafeRenderClassification(
                    included: false, reason: "unproven-stack"
                )
            } else if hasObservedStack {
                classification = CallArgumentSafeRenderClassification(
                    included: false, reason: "unproven-stack"
                )
            } else if case .simd = argument.location {
                classification = CallArgumentSafeRenderClassification(
                    included: false, reason: "unproven-bank-order"
                )
            } else if hasObservedSIMD {
                classification = CallArgumentSafeRenderClassification(
                    included: false, reason: "unproven-bank-order"
                )
            } else {
                classification = CallArgumentSafeRenderClassification(
                    included: false, reason: "unknown-gap"
                )
            }
            result[key] = classification
        }
        return result
    }

    private static func callArgumentAuditArgumentObject(
        _ argument: MacIRCallArgument,
        classification: CallArgumentSafeRenderClassification
    ) throws -> ScriptValue {
        let role: String
        let sourcePosition: ScriptValue
        let tailOrdinal: ScriptValue
        switch argument.role {
        case let .fixed(position):
            role = "fixed"
            sourcePosition = try callArgumentAuditInteger(
                position, field: "argument.source_position", minimum: 0
            )
            tailOrdinal = .null
        case let .anonymousVariadic(ordinal):
            // HOP-5c: only format-string tails pass frame validation.
            role = "anonymous-variadic"
            sourcePosition = .null
            tailOrdinal = try callArgumentAuditInteger(
                ordinal, field: "argument.tail_ordinal", minimum: 0
            )
        case .unknown:
            role = "unknown"
            sourcePosition = .null
            tailOrdinal = .null
        }
        let selectorName: ScriptValue
        let selectorAddress: ScriptValue
        if let selector = argument.selectorEvidence {
            selectorName = try callArgumentAuditString(
                selector.name, field: "argument.selector_name"
            )
            selectorAddress = .hex(selector.selrefAddress)
        } else {
            selectorName = .null
            selectorAddress = .null
        }
        return .object([
            "location": try callArgumentAuditLocationObject(argument.location),
            "role": .string(role),
            "source_position": sourcePosition,
            "tail_ordinal": tailOrdinal,
            "value_identity": try callArgumentAuditValueObject(argument.value),
            "selector_name": selectorName,
            "selector_selref_address": selectorAddress,
            "safe_render_included": .bool(classification.included),
            "safe_render_reason": .string(classification.reason),
        ])
    }

    private static func callArgumentAuditControlObject(
        _ control: MacIRCallControlInput
    ) throws -> ScriptValue {
        let role = switch control.role {
        case .indirectTarget: "indirect-target"
        case .pointerAuthenticationModifier: "pointer-authentication-modifier"
        }
        guard let register = control.register.registerName else {
            throw ScriptingError.invalidArgument("call control register is invalid")
        }
        return .object([
            "role": .string(role),
            "register": .string(register),
            "value_identity": try callArgumentAuditValueObject(control.value),
        ])
    }

    private static func callArgumentAuditTailObject(
        _ evidence: MacIRCallTailCountEvidence?
    ) throws -> ScriptValue {
        guard let evidence else { return .null }
        switch evidence {
        case let .objectiveCSelectorColonCount(count):
            return .object([
                "kind": .string("objective-c-selector-colon-count"),
                "expected_tail_count": try callArgumentAuditInteger(
                    count, field: "tail_count_evidence.expected_tail_count", minimum: 0
                ),
            ])
        case let .formatString(format):
            return .object([
                "kind": .string("format-string"),
                "provenance": .string(MacIRCallFormatStringEvidence.provenance),
                "format_attribute_kind": try callArgumentAuditString(
                    format.kind, field: "tail_count_evidence.format_attribute_kind"
                ),
                "format_address": .hex(format.formatAddress),
                "expected_tail_count": try callArgumentAuditInteger(
                    format.argumentTypes.count,
                    field: "tail_count_evidence.expected_tail_count",
                    minimum: 0
                ),
            ])
        }
    }

    struct CallArgumentAuditFileFingerprint: Equatable {
        let canonicalPath: String
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64
        let sha256: String
    }

    struct CallArgumentAuditRenderedBinding: Equatable {
        let line: PseudocodeLine
        let occurrence: Int
        let utf8SHA256: String
    }

    typealias CallArgumentAuditToolRunner = (
        _ executableURL: URL,
        _ arguments: [String],
        _ environment: [String: String],
        _ timeout: TimeInterval
    ) throws -> String

    private struct CallArgumentAuditFileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64
    }

    private struct CallArgumentAuditProcessStreamCapture: Sendable {
        let data: Data
        let overflowed: Bool
        let readError: Int32?
        let cancelled: Bool
    }

    private final class CallArgumentAuditProcessCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout: CallArgumentAuditProcessStreamCapture?
        private var stderr: CallArgumentAuditProcessStreamCapture?
        private var cancellationRequested = false

        func setStdout(_ capture: CallArgumentAuditProcessStreamCapture) {
            lock.lock()
            stdout = capture
            lock.unlock()
        }

        func setStderr(_ capture: CallArgumentAuditProcessStreamCapture) {
            lock.lock()
            stderr = capture
            lock.unlock()
        }

        func requestCancellation() {
            lock.lock()
            cancellationRequested = true
            lock.unlock()
        }

        func isCancellationRequested() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancellationRequested
        }

        func snapshot() -> (
            stdout: CallArgumentAuditProcessStreamCapture?,
            stderr: CallArgumentAuditProcessStreamCapture?
        ) {
            lock.lock()
            defer { lock.unlock() }
            return (stdout, stderr)
        }
    }

    nonisolated static let callArgumentAuditProcessOutputLimit = 64 * 1_024
    nonisolated private static let callArgumentAuditProcessReadChunkSize = 16 * 1_024
    nonisolated private static let callArgumentAuditProcessPollMilliseconds: Int32 = 20

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func callArgumentAuditFileIdentity(
        _ value: stat
    ) -> CallArgumentAuditFileIdentity {
        CallArgumentAuditFileIdentity(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            size: Int64(value.st_size),
            modificationSeconds: Int64(value.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            changeSeconds: Int64(value.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(value.st_ctimespec.tv_nsec)
        )
    }

    nonisolated static let callArgumentAuditFileReadChunkSize = 1 * 1_024 * 1_024

    /// ★ Insight ─────────────────────────────────────
    /// Whole-file provenance does not require whole-file residency. Hash exactly the
    /// descriptor-bound `st_size` in fixed chunks, then require immediate EOF; this
    /// bounds memory while making both concurrent truncation and append fail closed.
    /// The outer path/descriptor identity recheck still detects replacement or edits
    /// that occur after the EOF probe.
    /// ─────────────────────────────────────────────────
    static func callArgumentAuditDescriptorDigest(
        descriptor: Int32,
        expectedSize: Int64,
        chunkSize: Int = callArgumentAuditFileReadChunkSize,
        afterChunk: ((Int64) throws -> Void)? = nil
    ) throws -> String {
        guard expectedSize >= 0, chunkSize > 0,
              chunkSize <= callArgumentAuditFileReadChunkSize else {
            throw ScriptingError.invalidArgument("invalid audit file digest bounds")
        }
        var hasher = SHA256()
        var totalRead: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while totalRead < expectedSize {
            let requestCount = min(chunkSize, Int(expectedSize - totalRead))
            let byteCount = buffer.withUnsafeMutableBytes { storage in
                Darwin.read(descriptor, storage.baseAddress, requestCount)
            }
            if byteCount < 0 {
                if errno == EINTR { continue }
                let diagnostic = String(cString: strerror(errno))
                throw ScriptingError.invalidArgument(
                    "cannot read complete audit file: \(diagnostic)"
                )
            }
            guard byteCount > 0 else {
                throw ScriptingError.invalidArgument(
                    "audit file changed size while it was fingerprinted"
                )
            }
            hasher.update(data: Data(buffer.prefix(byteCount)))
            totalRead += Int64(byteCount)
            try afterChunk?(totalRead)
        }

        var extraByte: UInt8 = 0
        while true {
            let extraCount = Darwin.read(descriptor, &extraByte, 1)
            if extraCount < 0, errno == EINTR { continue }
            if extraCount < 0 {
                let diagnostic = String(cString: strerror(errno))
                throw ScriptingError.invalidArgument(
                    "cannot finish reading audit file: \(diagnostic)"
                )
            }
            guard extraCount == 0 else {
                throw ScriptingError.invalidArgument(
                    "audit file changed size while it was fingerprinted"
                )
            }
            break
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func callArgumentAuditFileFingerprint(
        at originalURL: URL
    ) throws -> CallArgumentAuditFileFingerprint {
        let standardized = originalURL.standardizedFileURL
        guard standardized.path.hasPrefix("/") else {
            throw ScriptingError.invalidArgument("audit file path must be absolute")
        }
        let canonical = standardized.resolvingSymlinksInPath().standardizedFileURL
        var pathBefore = stat()
        guard stat(canonical.path, &pathBefore) == 0 else {
            let diagnostic = String(cString: strerror(errno))
            throw ScriptingError.invalidArgument("cannot stat audit file: \(diagnostic)")
        }
        guard pathBefore.st_mode & S_IFMT == S_IFREG else {
            throw ScriptingError.invalidArgument("audit file is not a canonical regular file")
        }

        let descriptor = open(canonical.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            let diagnostic = String(cString: strerror(errno))
            throw ScriptingError.invalidArgument("cannot open audit file: \(diagnostic)")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var descriptorBefore = stat()
        guard fstat(descriptor, &descriptorBefore) == 0,
              descriptorBefore.st_mode & S_IFMT == S_IFREG else {
            throw ScriptingError.invalidArgument("cannot bind audit file descriptor metadata")
        }
        let initialIdentity = callArgumentAuditFileIdentity(pathBefore)
        guard callArgumentAuditFileIdentity(descriptorBefore) == initialIdentity,
              initialIdentity.size >= 0 else {
            throw ScriptingError.invalidArgument("audit file changed while it was opened")
        }

        // Whole-file hashing is the audit's longest synchronous phase; observe the
        // owning request's cancellation once per bounded chunk. Outside a task this is a no-op.
        let digest = try callArgumentAuditDescriptorDigest(
            descriptor: descriptor, expectedSize: initialIdentity.size,
            afterChunk: { _ in try Task.checkCancellation() }
        )

        var descriptorAfter = stat()
        var pathAfter = stat()
        guard fstat(descriptor, &descriptorAfter) == 0,
              stat(canonical.path, &pathAfter) == 0,
              callArgumentAuditFileIdentity(descriptorAfter) == initialIdentity,
              callArgumentAuditFileIdentity(pathAfter) == initialIdentity else {
            throw ScriptingError.invalidArgument(
                "audit file metadata or content changed while it was fingerprinted"
            )
        }
        return CallArgumentAuditFileFingerprint(
            canonicalPath: canonical.path,
            device: initialIdentity.device,
            inode: initialIdentity.inode,
            size: initialIdentity.size,
            modificationSeconds: initialIdentity.modificationSeconds,
            modificationNanoseconds: initialIdentity.modificationNanoseconds,
            changeSeconds: initialIdentity.changeSeconds,
            changeNanoseconds: initialIdentity.changeNanoseconds,
            sha256: digest
        )
    }

    private static func runningExecutableURL() throws -> URL {
        var capacity: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &capacity)
        guard capacity > 0 else {
            throw ScriptingError.invalidArgument("cannot resolve the running executable path")
        }
        var buffer = [CChar](repeating: 0, count: Int(capacity))
        let status = buffer.withUnsafeMutableBufferPointer { pointer in
            _NSGetExecutablePath(pointer.baseAddress, &capacity)
        }
        guard status == 0 else {
            throw ScriptingError.invalidArgument("cannot resolve the running executable path")
        }
        let path = buffer.withUnsafeBufferPointer { pointer in
            String(cString: pointer.baseAddress!)
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    }

    private static func configureCallArgumentAuditProcessPipe(
        descriptor: Int32,
        label: String
    ) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let diagnostic = String(cString: strerror(errno))
            throw ScriptingError.invalidArgument(
                "cannot configure audit child \(label) pipe: \(diagnostic)"
            )
        }
    }

    /// ★ Insight ─────────────────────────────────────
    /// A timeout cannot cancel a blocking pipe `read`, and bounding only the retained
    /// `Data` still lets an overflowing child deadlock on a full pipe. Nonblocking
    /// chunk reads let both workers keep draining/discarding after the evidence cap,
    /// while a short poll interval makes cancellation deterministic on every exit path.
    /// ─────────────────────────────────────────────────
    nonisolated private static func drainCallArgumentAuditProcessStream(
        descriptor: Int32,
        capture: CallArgumentAuditProcessCapture
    ) -> CallArgumentAuditProcessStreamCapture {
        var retained = Data()
        retained.reserveCapacity(callArgumentAuditProcessOutputLimit)
        var overflowed = false
        var buffer = [UInt8](repeating: 0, count: callArgumentAuditProcessReadChunkSize)

        while !capture.isCancellationRequested() {
            let byteCount = buffer.withUnsafeMutableBytes { storage in
                Darwin.read(descriptor, storage.baseAddress, storage.count)
            }
            if byteCount > 0 {
                let remaining = max(0, callArgumentAuditProcessOutputLimit - retained.count)
                let retainedCount = min(byteCount, remaining)
                if retainedCount > 0 {
                    retained.append(contentsOf: buffer.prefix(retainedCount))
                }
                if byteCount > retainedCount { overflowed = true }
                continue
            }
            if byteCount == 0 {
                return CallArgumentAuditProcessStreamCapture(
                    data: retained, overflowed: overflowed, readError: nil, cancelled: false
                )
            }

            let readError = errno
            if readError == EINTR { continue }
            if readError != EAGAIN && readError != EWOULDBLOCK {
                return CallArgumentAuditProcessStreamCapture(
                    data: retained, overflowed: overflowed,
                    readError: readError, cancelled: false
                )
            }

            var event = pollfd(
                fd: descriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let pollStatus = Darwin.poll(
                &event, 1, callArgumentAuditProcessPollMilliseconds
            )
            if pollStatus < 0, errno != EINTR {
                return CallArgumentAuditProcessStreamCapture(
                    data: retained, overflowed: overflowed,
                    readError: errno, cancelled: false
                )
            }
        }

        return CallArgumentAuditProcessStreamCapture(
            data: retained, overflowed: overflowed, readError: nil, cancelled: true
        )
    }

    static func runCallArgumentAuditProcess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> String {
        guard timeout > 0, timeout.isFinite else {
            throw ScriptingError.invalidArgument("audit child timeout must be positive and finite")
        }
        try Task.checkCancellation()
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let stdoutHandle = standardOutput.fileHandleForReading
        let stderrHandle = standardError.fileHandleForReading
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }
        try configureCallArgumentAuditProcessPipe(
            descriptor: stdoutHandle.fileDescriptor, label: "stdout"
        )
        try configureCallArgumentAuditProcessPipe(
            descriptor: stderrHandle.fileDescriptor, label: "stderr"
        )
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput
        process.standardError = standardError
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        try Task.checkCancellation()
        do {
            try process.run()
        } catch {
            throw ScriptingError.invalidArgument(
                "cannot launch audit child \(executableURL.path): \(error.localizedDescription)"
            )
        }

        let capture = CallArgumentAuditProcessCapture()
        let drains = DispatchGroup()
        drains.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            defer { drains.leave() }
            capture.setStdout(drainCallArgumentAuditProcessStream(
                descriptor: stdoutHandle.fileDescriptor, capture: capture
            ))
        }
        drains.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            defer { drains.leave() }
            capture.setStderr(drainCallArgumentAuditProcessStream(
                descriptor: stderrHandle.fileDescriptor, capture: capture
            ))
        }

        let deadline = DispatchTime.now() + timeout
        var cancelled = false
        var terminatedInTime = false
        while DispatchTime.now() < deadline {
            if Task.isCancelled { cancelled = true; break }
            if terminated.wait(timeout: min(deadline, .now() + 0.025)) == .success {
                terminatedInTime = true
                break
            }
        }
        if !terminatedInTime {
            let ownedPID = process.processIdentifier
            if process.isRunning { process.terminate() }
            if terminated.wait(timeout: .now() + 0.25) == .timedOut,
               process.isRunning {
                let killStatus = kill(ownedPID, SIGKILL)
                let killError = errno
                if killStatus != 0, killError != ESRCH {
                    process.terminate()
                }
                process.waitUntilExit()
            }
            if process.isRunning {
                process.waitUntilExit()
            }
            capture.requestCancellation()
            drains.wait()
            process.terminationHandler = nil
            if cancelled { throw CancellationError() }
            throw ScriptingError.invalidArgument(
                "audit child \(executableURL.lastPathComponent) exceeded \(timeout) seconds"
            )
        }
        let drainDeadline = DispatchTime.now() + 1
        var drained = false
        while DispatchTime.now() < drainDeadline {
            if Task.isCancelled {
                capture.requestCancellation()
                drains.wait()
                process.terminationHandler = nil
                throw CancellationError()
            }
            if drains.wait(timeout: min(drainDeadline, .now() + 0.025)) == .success {
                drained = true
                break
            }
        }
        if !drained {
            capture.requestCancellation()
            drains.wait()
            process.terminationHandler = nil
            throw ScriptingError.invalidArgument(
                "audit child \(executableURL.lastPathComponent) output drain timed out"
            )
        }
        process.terminationHandler = nil
        let captured = capture.snapshot()
        guard let stdoutCapture = captured.stdout, let stderrCapture = captured.stderr else {
            throw ScriptingError.invalidArgument("audit child output capture was incomplete")
        }
        for (label, stream) in [("stdout", stdoutCapture), ("stderr", stderrCapture)] {
            if stream.cancelled {
                throw ScriptingError.invalidArgument("audit child \(label) capture was cancelled")
            }
            if let readError = stream.readError {
                throw ScriptingError.invalidArgument(
                    "audit child \(label) read failed: \(String(cString: strerror(readError)))"
                )
            }
            if stream.overflowed {
                throw ScriptingError.invalidArgument(
                    "audit child \(label) exceeded \(callArgumentAuditProcessOutputLimit) bytes"
                )
            }
        }
        guard let stdout = String(data: stdoutCapture.data, encoding: .utf8) else {
            throw ScriptingError.invalidArgument("audit child stdout is not valid UTF-8")
        }
        guard let stderr = String(data: stderrCapture.data, encoding: .utf8) else {
            throw ScriptingError.invalidArgument("audit child stderr is not valid UTF-8")
        }
        guard process.terminationStatus == 0 else {
            let diagnostic = stderr.split(whereSeparator: \.isNewline).first.map(String.init)
                ?? "exit \(process.terminationStatus)"
            throw ScriptingError.invalidArgument(
                "audit child \(executableURL.lastPathComponent) failed: \(diagnostic)"
            )
        }
        return stdout
    }

    private static func exactCallArgumentAuditToolLines(
        _ output: String,
        label: String
    ) throws -> [String] {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            throw ScriptingError.invalidArgument("active \(label) output is not normalized")
        }
        for line in lines {
            _ = try callArgumentAuditString(line, field: "active \(label) output")
        }
        return lines
    }

    private static func canonicalCallArgumentAuditURL(
        _ rawPath: String,
        label: String,
        requireDirectory: Bool
    ) throws -> URL {
        _ = try callArgumentAuditString(rawPath, field: label)
        let standardized = URL(fileURLWithPath: rawPath).standardizedFileURL
        guard standardized.path.hasPrefix("/") else {
            throw ScriptingError.invalidArgument("\(label) must be absolute")
        }
        let canonical = standardized.resolvingSymlinksInPath().standardizedFileURL
        let values = try? canonical.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        let valid = requireDirectory ? values?.isDirectory == true : values?.isRegularFile == true
        guard valid else {
            throw ScriptingError.invalidArgument("\(label) does not resolve to the expected file type")
        }
        return canonical
    }

    private static func callArgumentAuditURL(
        _ child: URL,
        isWithin directory: URL
    ) -> Bool {
        child.path == directory.path || child.path.hasPrefix(directory.path + "/")
    }

    static func sampleCallArgumentAuditToolchainIdentity(
        environment sourceEnvironment: [String: String],
        runner: CallArgumentAuditToolRunner
    ) throws -> ScriptValue {
        var environment = sourceEnvironment
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        environment["LANGUAGE"] = "C"
        let developerPath: String
        if let configured = environment["DEVELOPER_DIR"], !configured.isEmpty {
            developerPath = configured
        } else {
            let output = try runner(
                URL(fileURLWithPath: "/usr/bin/xcode-select"), ["-p"], environment, 10
            )
            let lines = try exactCallArgumentAuditToolLines(
                output, label: "developer directory"
            )
            guard lines.count == 1 else {
                throw ScriptingError.invalidArgument("active developer directory is ambiguous")
            }
            developerPath = lines[0]
        }
        let developerDirectory = try canonicalCallArgumentAuditURL(
            developerPath, label: "DEVELOPER_DIR", requireDirectory: true
        )
        environment["DEVELOPER_DIR"] = developerDirectory.path

        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        func xcrunOutput(_ arguments: [String]) throws -> String {
            try runner(xcrun, arguments, environment, 10)
        }
        func exactSingleLine(_ output: String, label: String) throws -> String {
            let lines = try exactCallArgumentAuditToolLines(output, label: label)
            guard lines.count == 1 else {
                throw ScriptingError.invalidArgument("active \(label) output is ambiguous")
            }
            return lines[0]
        }

        let xcodebuild = try canonicalCallArgumentAuditURL(
            exactSingleLine(
                try xcrunOutput(["--find", "xcodebuild"]), label: "xcodebuild path"
            ),
            label: "xcodebuild path",
            requireDirectory: false
        )
        let clang = try canonicalCallArgumentAuditURL(
            exactSingleLine(try xcrunOutput(["--find", "clang"]), label: "clang path"),
            label: "clang path",
            requireDirectory: false
        )
        let sdk = try canonicalCallArgumentAuditURL(
            exactSingleLine(
                try xcrunOutput(["--sdk", "macosx", "--show-sdk-path"]),
                label: "macOS SDK path"
            ),
            label: "macOS SDK path",
            requireDirectory: true
        )
        guard callArgumentAuditURL(xcodebuild, isWithin: developerDirectory),
              callArgumentAuditURL(clang, isWithin: developerDirectory),
              callArgumentAuditURL(sdk, isWithin: developerDirectory) else {
            throw ScriptingError.invalidArgument(
                "active Xcode, clang, and macOS SDK do not share one DEVELOPER_DIR"
            )
        }

        let xcodeLines = try exactCallArgumentAuditToolLines(
            try runner(xcodebuild, ["-version"], environment, 10),
            label: "Xcode version"
        )
        guard xcodeLines.count == 2,
              xcodeLines[0].hasPrefix("Xcode "),
              xcodeLines[1].hasPrefix("Build version ") else {
            throw ScriptingError.invalidArgument("active Xcode version output is malformed")
        }
        let xcodeVersion = String(xcodeLines[0].dropFirst("Xcode ".count))
        let xcodeBuild = String(xcodeLines[1].dropFirst("Build version ".count))
        let versionComponents = xcodeVersion.split(separator: ".", omittingEmptySubsequences: false)
        guard !versionComponents.isEmpty,
              versionComponents.allSatisfy({ component in
                  !component.isEmpty && component.utf8.allSatisfy({ (0x30...0x39).contains($0) })
              }),
              !xcodeBuild.isEmpty,
              xcodeBuild.utf8.allSatisfy({ byte in
                  (0x30...0x39).contains(byte)
                      || (0x41...0x5a).contains(byte)
                      || (0x61...0x7a).contains(byte)
              }) else {
            throw ScriptingError.invalidArgument("active Xcode version fields are malformed")
        }
        let sdkVersion = try exactSingleLine(
            try xcrunOutput(["--sdk", "macosx", "--show-sdk-version"]),
            label: "macOS SDK version"
        )
        let sdkVersionComponents = sdkVersion.split(
            separator: ".", omittingEmptySubsequences: false
        )
        guard !sdkVersionComponents.isEmpty,
              sdkVersionComponents.allSatisfy({ component in
                  !component.isEmpty && component.utf8.allSatisfy({ (0x30...0x39).contains($0) })
              }) else {
            throw ScriptingError.invalidArgument("active macOS SDK version is malformed")
        }
        let clangLines = try exactCallArgumentAuditToolLines(
            try runner(clang, ["--version"], environment, 10),
            label: "clang version"
        )
        guard let clangVersion = clangLines.first else {
            throw ScriptingError.invalidArgument("active clang version output is empty")
        }

        let xcodeVersionValue = try callArgumentAuditString(
            xcodeVersion, field: "toolchain_identity.xcode_version"
        )
        let xcodeBuildValue = try callArgumentAuditString(
            xcodeBuild, field: "toolchain_identity.xcode_build"
        )
        let sdkCanonicalValue = try callArgumentAuditString(
            "macosx\(sdkVersion)", field: "toolchain_identity.sdk_canonical_name"
        )
        let sdkVersionValue = try callArgumentAuditString(
            sdkVersion, field: "toolchain_identity.sdk_version"
        )
        let clangVersionValue = try callArgumentAuditString(
            clangVersion, field: "toolchain_identity.clang_version"
        )
        return .object([
            "xcode_version": xcodeVersionValue,
            "xcode_build": xcodeBuildValue,
            "sdk_canonical_name": sdkCanonicalValue,
            "sdk_version": sdkVersionValue,
            "clang_version": clangVersionValue,
        ])
    }

    private static func activeToolchainIdentityObject() throws -> ScriptValue {
        if let cachedCallArgumentAuditToolchainIdentity {
            return cachedCallArgumentAuditToolchainIdentity
        }
        let identity = try sampleCallArgumentAuditToolchainIdentity(
            environment: ProcessInfo.processInfo.environment
        ) { executableURL, arguments, environment, timeout in
            try runCallArgumentAuditProcess(
                executableURL: executableURL,
                arguments: arguments,
                environment: environment,
                timeout: timeout
            )
        }
        cachedCallArgumentAuditToolchainIdentity = identity
        return identity
    }

    static func callArgumentAuditRenderedBinding(
        instructionAddress: UInt64,
        document: PseudocodeDocument
    ) throws -> CallArgumentAuditRenderedBinding {
        let matchingLines = document.lines.filter { $0.sourceAddress == instructionAddress }
        guard matchingLines.count == 1, let line = matchingLines.first,
              let lineIndex = document.lines.firstIndex(where: {
                  $0.lineNumber == line.lineNumber
              }) else {
            throw ScriptingError.invalidArgument(
                "call at \(ScriptValue.hex(instructionAddress).stringValue ?? "") does not bind to exactly one rendered line"
            )
        }
        let lineBytes = Data(line.text.utf8)
        let occurrence = document.lines[..<lineIndex].reduce(into: 0) { count, prior in
            if Data(prior.text.utf8) == lineBytes { count += 1 }
        }
        return CallArgumentAuditRenderedBinding(
            line: line,
            occurrence: occurrence,
            utf8SHA256: sha256Hex(lineBytes)
        )
    }

    static func callArgumentAuditFocusIsStable(
        capturedSlot: ImageSlot,
        capturedBinary: BinaryImage,
        currentSlot: ImageSlot,
        currentSnapshot: WorkspaceSnapshot
    ) -> Bool {
        currentSlot == capturedSlot
            && currentSnapshot.binary(in: capturedSlot) == capturedBinary
    }

    private static func callArgumentAuditCallObject(
        instruction: MacIRInstruction,
        frame: MacIRCallFrame,
        document: PseudocodeDocument
    ) throws -> (value: ScriptValue, lineIdentity: String) {
        let binding = try callArgumentAuditRenderedBinding(
            instructionAddress: instruction.source.address,
            document: document
        )
        let line = binding.line
        let classifications = try callArgumentAuditSafeClassifications(
            frame: frame, renderedLine: line.text
        )
        let arguments = try frame.arguments.canonicalPhysicalEntriesForAudit.map { argument in
            guard let key = argument.location.physicalKey,
                  let classification = classifications[key] else {
                throw ScriptingError.invalidArgument(
                    "call argument lacks a canonical safe-render classification"
                )
            }
            return try callArgumentAuditArgumentObject(
                argument, classification: classification
            )
        }
        let controls = try frame.controlInputs.canonicalControlInputsForAudit.map {
            try callArgumentAuditControlObject($0)
        }
        let knownSignature: ScriptValue = if let target = frame.knownSignature?.target {
            try callArgumentAuditString(target, field: "known_signature_id")
        } else {
            .null
        }
        var fields: [String: ScriptValue] = [
            "instruction_address": .hex(instruction.source.address),
            "target": try callArgumentAuditString(frame.target, field: "call.target"),
            "known_signature_id": knownSignature,
            "tail_count_evidence": try callArgumentAuditTailObject(frame.tailCountEvidence),
            "rendered_line_ordinal": try callArgumentAuditInteger(
                line.lineNumber, field: "rendered_line_ordinal", minimum: 1
            ),
            "rendered_occurrence_ordinal": try callArgumentAuditInteger(
                binding.occurrence, field: "rendered_occurrence_ordinal", minimum: 0
            ),
            "rendered_utf8_sha256": .string(binding.utf8SHA256),
            "observation": try callArgumentAuditObservationObject(
                frame.arguments.observationScope
            ),
            "control_inputs": .array(controls),
            "arguments": .array(arguments),
        ]
        if let richArguments = frame.richArguments {
            fields["authored_rich_signature_id"] = .string(frame.target)
            fields["rich_source_arguments"] = .array(try richArguments.map { argument in
                .object([
                    "source_row": try callArgumentAuditString(argument.rowID.rawValue, field: "rich.source_row"),
                    "source_position": try callArgumentAuditInteger(argument.sourcePosition,
                        field: "rich.source_position", minimum: 0),
                    "type": try callArgumentAuditString(argument.type, field: "rich.type"),
                    "pieces": .array(try argument.pieces.map { piece in
                        let register: String
                        switch piece.register {
                        case let .simd(index, width): register = "\(width == 64 ? "d" : "s")\(index)"
                        case let .gpr(index, width): register = "\(width == 64 ? "x" : "w")\(index)"
                        }
                        return .object([
                            "register": .string(register),
                            "byte_offset": try callArgumentAuditInteger(piece.valueByteOffset,
                                field: "rich.piece.byte_offset", minimum: 0),
                            "size": try callArgumentAuditInteger(piece.size,
                                field: "rich.piece.size", minimum: 1),
                            "value_identity": try callArgumentAuditValueObject(piece.value),
                            "rendered": .bool(true),
                        ])
                    }),
                ])
            })
        }
        if let indirectResultPointer = frame.indirectResultPointer {
            fields["indirect_result_pointer"] = try callArgumentAuditValueObject(indirectResultPointer)
        }
        let value = ScriptValue.object(fields)
        return (value, "\(line.lineNumber):\(binding.occurrence)")
    }

    private static let registry: [String: Command] = {
        var commands: [Command] = []
        func add(_ name: String, _ summary: String, mutates: Bool = false, arguments: [String] = [],
                 _ run: @escaping @MainActor (ScriptValue, WorkspaceStore) throws -> ScriptValue) {
            commands.append(Command(info: ScriptingCommandInfo(name: name, summary: summary, mutates: mutates, arguments: arguments), run: run))
        }

        // --- Introspection ---
        add("commands", "List the available scripting commands.") { _, _ in
            .array(availableCommands.map { info in
                .object([
                    "name": .string(info.name),
                    "summary": .string(info.summary),
                    "mutates": .bool(info.mutates),
                    "arguments": .array(info.arguments.map(ScriptValue.string)),
                ])
            })
        }

        add("info", "Summary of the loaded binary.") { _, store in
            let snapshot = store.snapshot
            let binary = snapshot.binaries.first
            return .object([
                "name": .string(binary?.name ?? ""),
                "format": .string(binary?.kind ?? ""),
                "architecture": .string(binary?.architecture ?? ""),
                "functionCount": .int(Int64(snapshot.functions.count)),
                "instructionCount": .int(Int64(snapshot.instructions.count)),
                "symbolCount": .int(Int64(snapshot.symbols.count)),
                "stringCount": .int(Int64(snapshot.stringLiterals.count)),
            ])
        }

        // --- Reads ---
        add("reconstruction-jobs", "Durable Reconstruction job status: state, terminal reason, failed-task diagnostics, decompiler backend per task (native or macir + fallbackReason), and a completed source job's final synthesis (accepted revision, harness passed/total, provenance, elapsed), and the durable lifecycle (created/started/finished ms) with elapsed + elapsedSource (wall-clock, or phase-sum for older rows). Pass `job` (UUID) for one job.",
            arguments: ["job"]) { arguments, store in
            try reconstructionJobsStatus(arguments, state: store.reconstructionState,
                lifecycle: store.reconstructionLifecycle)
        }

        add("read-evidence", "Read app-authorized typed workspace evidence; integer identities use exact decimal strings.",
            arguments: ["operation"]) { arguments, store in
            try readEvidence(arguments, store: store, proposingPrincipal: .human)
        }
        add("functions", "List the primary image's discovered functions. `name` is the effective display name (a `rename` wins); every primary-image `function` selector accepts it, as well as an unambiguous raw analysis name.", arguments: ["limit"]) { arguments, store in
            try snapshotListRead("functions", arguments: arguments, snapshot: store.snapshot)
        }

        add("instructions", "Instructions of a function (by `function` display or raw name) or a range (`address`, `count`).",
            arguments: ["function", "address", "count"]) { arguments, store in
            try snapshotListRead("instructions", arguments: arguments, snapshot: store.snapshot)
        }

        add("symbols", "List symbols.", arguments: ["limit"]) { arguments, store in
            try snapshotListRead("symbols", arguments: arguments, snapshot: store.snapshot)
        }

        add("strings", "List string literals.", arguments: ["limit"]) { arguments, store in
            try snapshotListRead("strings", arguments: arguments, snapshot: store.snapshot)
        }

        add("imports", "List dynamic imports (symbols resolved from other libraries).", arguments: ["limit"]) { arguments, store in
            try snapshotListRead("imports", arguments: arguments, snapshot: store.snapshot)
        }

        add("exports", "List exported symbols.", arguments: ["limit"]) { arguments, store in
            try snapshotListRead("exports", arguments: arguments, snapshot: store.snapshot)
        }

        add("sections", "List the binary's segments/sections (name, address, size, file offset, executable). Reflects any user rename/rebase; `originalName` carries the pre-override name.",
            arguments: ["limit"]) { arguments, store in
            try snapshotListRead("sections", arguments: arguments, snapshot: store.snapshot)
        }

        add("relocations", "List the binary's relocations (address, section, type, symbol, addend). Format-neutral across ELF and Mach-O; optional fields are omitted when absent.",
            arguments: ["limit"]) { arguments, store in
            try snapshotListRead("relocations", arguments: arguments, snapshot: store.snapshot)
        }

        add("read-bytes", "Read raw bytes at a virtual address as a hex string (default count 16, clamped to the section). Reads the primary image by default; `image` (a slot index or an image-owner ID) selects another loaded image. The result carries `imageSlot` and `imageOwner`.",
            arguments: ["address", "count", imageSelectorArgument]) { arguments, store in
            let snapshot = store.snapshot
            let target = try address(arguments, "address")
            let requested = arguments["count"]?.intValue.map { Int(max(0, $0)) } ?? 16
            // MS-19: the primary image unless `image` names another; for the primary slot these
            // are exactly the flat `sections`/`imageBytes` projections read before.
            let slot = try resolveImageSlot(arguments, snapshot: snapshot)
            let imageAnalysis = snapshot.analysis(in: slot)
            let provenance = imageProvenanceFields(slot: slot, snapshot: snapshot)
            func result(_ fields: [String: ScriptValue]) -> ScriptValue {
                .object(fields.merging(provenance) { _, label in label })
            }
            guard let section = (imageAnalysis?.sections ?? []).first(where: { $0.address <= target && target < $0.address &+ $0.size }) else {
                throw ScriptingError.invalidArgument("address \(ScriptValue.hex(target).stringValue ?? "") is not in any mapped section")
            }
            let delta = target - section.address
            // Clamp the read to the section end, then to the retained slice — all bounds
            // checked BEFORE any Int cast so a malformed fileOffset/size can't trap.
            let available = min(UInt64(requested), section.size - delta)
            // A zero-fill (BSS) section has no file bytes — its fileOffset is a placeholder,
            // so the in-memory image is zeros. Return zeros rather than reading the wrong
            // file region (which would otherwise be the slice header at fileOffset 0).
            if section.isZeroFill {
                let n = Int(min(available, UInt64(Int.max)))
                return result(["address": .hex(target), "length": .count(UInt64(n)), "hex": .string(String(repeating: "00", count: n))])
            }
            // Checked add: a malformed huge fileOffset must not WRAP into a small valid
            // index and silently return bytes from an unrelated file region.
            let (sliceStart, overflowed) = section.fileOffset.addingReportingOverflow(delta)
            let bytes = imageAnalysis?.imageBytes ?? Data()
            var hex = ""
            var length = 0
            if !overflowed, sliceStart <= UInt64(bytes.count) {
                let start = Int(sliceStart)
                let n = Int(min(available, UInt64(bytes.count - start)))
                let slice = bytes.subdata(in: start..<(start + n))
                hex = slice.map { String(format: "%02x", $0) }.joined()
                length = slice.count
            }
            return result(["address": .hex(target), "length": .count(UInt64(length)), "hex": .string(hex)])
        }

        add("xrefs", "Cross-references to (`to`) or from (`from`) an address, with user add/suppress edits applied. Optional `limit` selects a prefix; excessive scan or result work is refused. Every row carries `imageSlot`; the optional `imageSlot` argument reads that image instead of the primary image.", arguments: ["to", "from", "limit", WorkspaceScriptingAPI.imageSlotFilterArgument]) { arguments, store in
            try snapshotListRead("xrefs", arguments: arguments, snapshot: store.snapshot)
        }

        add("name-at", "The display name at an address in the primary image (custom name if set).", arguments: ["address"]) { arguments, store in
            let snapshot = store.snapshot
            let target = try address(arguments, "address")
            let parsed = snapshot.functions.first(where: { $0.startAddress == target })?.name
                ?? snapshot.symbols.first(where: { $0.address == target })?.name
                ?? ""
            let name = snapshot.displayName(at: target, default: parsed)
            return name.isEmpty ? .null : .string(name)
        }

        // --- Mutations (undoable through the store) ---
        // `rename` binds to the primary image — the image `functions`, `name-at` and the general
        // `function` selector read — not to live focus, so the label it writes is always the one
        // those commands report and resolve, whichever image the UI has focused.
        add("rename", "Set a custom name at an address in the primary image (the image `functions` and `name-at` read; independent of the focused image).", mutates: true, arguments: ["address", "name"]) { arguments, store in
            let target = try address(arguments, "address")
            let name = try string(arguments, "name")
            store.setCustomName(target, in: store.snapshot.primarySlot, name: name)
            return .object(["ok": .bool(true), "address": .hex(target), "name": .string(name)])
        }

        // Like `rename`, these address-authoring writes bind to the primary image — the image
        // whose comment/tag/label/bookmark reads report them — never to live focus.
        add("set-comment", "Set a comment at an address in the primary image (empty clears it; the image `instructions` reads; independent of the focused image).", mutates: true, arguments: ["address", "comment"]) { arguments, store in
            let target = try address(arguments, "address")
            let comment = try string(arguments, "comment")
            store.setCustomComment(target, in: store.snapshot.primarySlot, comment: comment.isEmpty ? nil : comment)
            return .object(["ok": .bool(true), "address": .hex(target)])
        }

        add("set-tag", "Set a free-text tag at an address in the primary image (empty clears it; independent of the focused image).", mutates: true, arguments: ["address", "tag"]) { arguments, store in
            let target = try address(arguments, "address")
            let tag = try string(arguments, "tag")
            store.setTag(target, in: store.snapshot.primarySlot, tag: tag.isEmpty ? nil : tag)
            return .object(["ok": .bool(true), "address": .hex(target)])
        }

        // --- Navigation / search ---
        // `goto` is classified as mutating. It is not a durable authoring edit (no undo entry, no
        // dirty mark), but it changes shared MainActor workspace state that later commands observe:
        // the focused image (which `overrideKey` uses to target every subsequent authoring edit),
        // the selection, the editor mode, navigation history and the native-decompiler drive.
        // The mutation classification is what keeps that truthful at every binding: MCP serializes
        // it with other mutations in arrival order, a queued goto cancelled before admission never
        // runs, the async path checks cancellation immediately before the synchronous commit, and a
        // goto that already navigated is reported as committed rather than "cancelled".
        add("goto", "Navigate to a hex address or symbol name.", mutates: true, arguments: ["query"]) { arguments, store in
            let query = try string(arguments, "query")
            let ok = store.goTo(query: query)
            return .object(["ok": .bool(ok), "address": store.selectedAddress.map(ScriptValue.hex) ?? .null])
        }

        add("search", "Search the binary (`mode`: text | regex | hex). The query is at most 256 UTF-8 bytes; a longer query, or an invalid regex, is refused with {error: invalidPattern, detail}. Every result row carries `imageSlot`; the optional `imageSlot` argument restricts the search to one loaded image.",
            arguments: ["query", "mode", WorkspaceScriptingAPI.imageSlotFilterArgument]) { arguments, store in
            let query = try string(arguments, "query")
            let mode = BinarySearchMode(rawValue: arguments["mode"]?.stringValue ?? "text") ?? .text
            let snapshot = store.snapshot
            let scope = searchScope(
                filter: try resolveImageSlotFilter(arguments, snapshot: snapshot),
                focusedSlot: store.focusedImageSlot)
            let outcome = BinarySearchService().searchWithCount(query: query, mode: mode, in: snapshot, scope: scope)
            return .object([
                "total": .int(Int64(outcome.total)),
                "results": .array(outcome.results.map(searchRow)),
            ])
        }

        add("neon-hitrate", "One bounded libjpeg.8.dylib NEON instruction and exact typed MacIR lift measurement.") { _, store in
            try Self.libjpegNEONHitRate(snapshot: store.snapshot)
        }

        // --- Decompiler ---
        add("decompile", "Pseudocode for a function (by `function` display or raw name, or `address`) in the primary image by default; `image` (a slot index or an image-owner ID) selects another loaded image, and the focused image is never implied. MCP tries the native SLEIGH decompiler first; the result's `backend` is `native` or `macir`, a MacIR result carries `fallbackReason` (`native-unavailable`, `native-empty`, or `native-failed: <code>`), and every result names the image that answered in `imageSlot` and `imageOwner`.", arguments: ["function", "address", imageSelectorArgument]) { arguments, store in
            try runSnapshotRead(.decompile, arguments: arguments,
                context: ScriptingSnapshotReadContext(snapshot: store.snapshot, focusedSlot: store.focusedImageSlot),
                checkpoint: {})
        }

        add(
            "parameter-binding-audit",
            "Candidate-only structural parameter binding facts from typed MacIR argument nodes (focused image; `function` display or raw name, or `address`).",
            arguments: ["function", "address"]
        ) { arguments, store in
            try runSnapshotRead(.parameterBindingAudit, arguments: arguments,
                context: ScriptingSnapshotReadContext(snapshot: store.snapshot, focusedSlot: store.focusedImageSlot),
                checkpoint: {})
        }

        add(
            "call-argument-audit",
            "Candidate-only structural call argument facts from one rendered MacIR function (focused image; exactly one of `function` raw structural name or `address`; display renames are not selectors).",
            arguments: ["function", "address"]
        ) { arguments, store in
            let slot = store.focusedImageSlot
            let snapshot = store.snapshot
            guard slot.rawValue >= 0,
                  let binary = snapshot.binary(in: slot),
                  let analysis = snapshot.analysis(in: slot) else {
                throw ScriptingError.invalidArgument(
                    "no bounded analyzed image exists in the focused slot"
                )
            }
            let function = try resolveCallArgumentAuditFunction(
                arguments, in: analysis.functions
            )
            let binaryURL = URL(fileURLWithPath: binary.path)
            let executableURL = try runningExecutableURL()
            let initialBinaryFingerprint = try callArgumentAuditFileFingerprint(at: binaryURL)
            let initialExecutableFingerprint = try callArgumentAuditFileFingerprint(
                at: executableURL
            )
            let overrides = snapshot.overrides(in: slot)
            let instructions = analysis.instructions.filter { row in
                let override = overrides[row.address]
                let isExcludedFromCode = override.map {
                    $0.isData || $0.isUndefined || !($0.dataShape?.isEmpty ?? true)
                } ?? false
                guard row.address >= function.startAddress, !isExcludedFromCode else {
                    return false
                }
                return function.endAddress > function.startAddress
                    ? row.address < function.endAddress
                    : row.address == function.startAddress
            }

            let machineUsage = snapshot.machineCallUsageHandoff(
                for: (function: function, instructions: instructions), in: slot)

            // This is the command's single MacIR construction. Render and audit this exact
            // object; do not call a convenience printer overload that would rebuild it.
            let printer = PseudocodePrinter()
            let irFunction = printer.buildFunction(
                functionName: function.name,
                startAddress: function.startAddress,
                jumpTables: snapshot.resolvedJumpTables(in: slot),
                objcSelectors: analysis.objcSelectors,
                constantStrings: analysis.constantStrings,
                signatureOverrides: snapshot.functionSignatureOverrides(in: slot),
                authoredCallSignaturesByTarget: snapshot.authoredCallSignaturesByTarget(in: slot),
                directCallVoidResultTargets: snapshot.directCallVoidResultTargets(in: slot),
                machineCallUsage: machineUsage?.usage,
                machineUsageContext: machineUsage?.context,
                types: snapshot.typeDefinitions,
                instructions: instructions
            )
            // Audit output is structural. Presentation-only function/call/register overlays
            // are intentionally absent, while signature overrides already participated above.
            try Task.checkCancellation()
            let document = printer.print(
                function: irFunction,
                ownDirectCallAddresses: snapshot.ownDirectCallAddresses(in: slot),
                types: snapshot.typeDefinitions
            )
            try Task.checkCancellation()

            let structuralCalls: [(instruction: MacIRInstruction, frame: MacIRCallFrame)] =
                irFunction.instructions.compactMap { instruction in
                    guard case let .call(frame, _) = instruction.operation else { return nil }
                    return (instruction, frame)
                }.sorted { left, right in
                    left.instruction.source.address < right.instruction.source.address
                }
            for pair in zip(structuralCalls, structuralCalls.dropFirst())
            where pair.0.instruction.source.address == pair.1.instruction.source.address {
                throw ScriptingError.invalidArgument("call audit contains a duplicate call address")
            }

            var lineIdentities: Set<String> = []
            var callValues: [ScriptValue] = []
            callValues.reserveCapacity(structuralCalls.count)
            for structuralCall in structuralCalls {
                if let signatureTarget = structuralCall.frame.knownSignature?.target,
                   signatureTarget != structuralCall.frame.target {
                    throw ScriptingError.invalidArgument(
                        "call target and known signature identity disagree"
                    )
                }
                let serialized = try callArgumentAuditCallObject(
                    instruction: structuralCall.instruction,
                    frame: structuralCall.frame,
                    document: document
                )
                guard lineIdentities.insert(serialized.lineIdentity).inserted else {
                    throw ScriptingError.invalidArgument(
                        "call audit duplicates a rendered call-line identity"
                    )
                }
                callValues.append(serialized.value)
            }

            let toolchainIdentity = try activeToolchainIdentityObject()

            // Re-resolve and re-fingerprint both complete files, then recheck the exact
            // focus immediately before publication. This detects symlink retargeting,
            // atomic replacement, content drift, and cross-image focus changes.
            let finalBinaryFingerprint = try callArgumentAuditFileFingerprint(at: binaryURL)
            let finalExecutableURL = try runningExecutableURL()
            let finalExecutableFingerprint = try callArgumentAuditFileFingerprint(
                at: finalExecutableURL
            )
            let liveSnapshot = store.snapshot
            guard callArgumentAuditFocusIsStable(
                capturedSlot: slot,
                capturedBinary: binary,
                currentSlot: store.focusedImageSlot,
                currentSnapshot: liveSnapshot
            ),
            finalBinaryFingerprint == initialBinaryFingerprint,
            finalExecutableURL == executableURL,
            finalExecutableFingerprint == initialExecutableFingerprint else {
                throw ScriptingError.invalidArgument(
                    "focused image or bound whole-file provenance changed during the audit"
                )
            }
            return .object([
                "schema": .string("call-argument-audit-v1"),
                "validation_scope": .string("structural-candidate"),
                "combined_oracle_comparison": .bool(false),
                "image_slot": .int(Int64(slot.rawValue)),
                "binary_sha256": .string(initialBinaryFingerprint.sha256),
                "producer_executable_sha256": .string(initialExecutableFingerprint.sha256),
                "toolchain_identity": toolchainIdentity,
                "function": .object([
                    "start_address": .hex(function.startAddress),
                    "display_name": try callArgumentAuditString(
                        function.name, field: "function.display_name", allowEmpty: true
                    ),
                ]),
                "calls": .array(callValues),
            ])
        }

        // --- Call graph ---
        add("callers", "Call sites that target a function (by `function` display or raw name, or `address`). Every row carries `imageSlot`; the optional `imageSlot` argument reads that image instead of the primary image.",
            arguments: ["function", "address", WorkspaceScriptingAPI.imageSlotFilterArgument]) { arguments, store in
            let snapshot = store.snapshot
            let filter = try resolveImageSlotFilter(arguments, snapshot: snapshot)
            let view = filter.map { imageProjection(of: snapshot, in: $0) } ?? snapshot
            let function = try resolveFunction(arguments, view)
            let slot = filter ?? view.primarySlot
            return .array(view.callers(of: function).map { callEdgeRow($0, slot: slot) })
        }
        add("callees", "Functions called from within a function (by `function` display or raw name, or `address`). Every row carries `imageSlot`; the optional `imageSlot` argument reads that image instead of the primary image.",
            arguments: ["function", "address", WorkspaceScriptingAPI.imageSlotFilterArgument]) { arguments, store in
            let snapshot = store.snapshot
            let filter = try resolveImageSlotFilter(arguments, snapshot: snapshot)
            let view = filter.map { imageProjection(of: snapshot, in: $0) } ?? snapshot
            let function = try resolveFunction(arguments, view)
            let slot = filter ?? view.primarySlot
            return .array(view.callees(of: function).map { callEdgeRow($0, slot: slot) })
        }
        add("basic-blocks", "Control-flow basic blocks of a function (by `function` display or raw name, or `address`), each with its outgoing edges.",
            arguments: ["function", "address"]) { arguments, store in
            try runSnapshotRead(.basicBlocks, arguments: arguments,
                context: ScriptingSnapshotReadContext(snapshot: store.snapshot, focusedSlot: store.focusedImageSlot),
                checkpoint: {})
        }
        add("resolve-symbol", "Resolve a symbol name to an address.", arguments: ["name"]) { arguments, store in
            store.snapshot.address(forSymbolName: try string(arguments, "name")).map(ScriptValue.hex) ?? .null
        }

        // --- Authoring: types / signatures / formats (all undoable) ---
        // Like `rename`, `set-type`, `set-color`, `set-operand-format` and the make-* marks bind to
        // the primary image (the image `functions`/`instructions`/`decompile` read and whose
        // analysis a structural mark re-drives), never to live focus. Patches also target primary
        // to match scripted export. Signatures stay focused, matching the focused audits.
        add("set-type", "Apply a type name at an address in the primary image (empty clears; independent of the focused image).", mutates: true, arguments: ["address", "type"]) { arguments, store in
            let target = try address(arguments, "address")
            let type = try string(arguments, "type")
            store.setAppliedType(target, in: store.snapshot.primarySlot, name: type.isEmpty ? nil : type)
            return .object(["ok": .bool(true), "address": .hex(target)])
        }
        add("set-signature", "Set a function's signature in the focused image (the image parameter-binding-audit and call-argument-audit read; decompile reads the primary image): returnType, tri-state args, variadicState, and noReturnState.",
            mutates: true, arguments: ["address", "returnType", "args", "variadicState", "noReturnState", "isNoReturn"]) { arguments, store in
            let target = try address(arguments, "address")
            let existing = store.snapshot.addressOverrides[store.overrideKey(target)]?.signature

            let returnType: String?
            switch arguments["returnType"] {
            case .none:
                returnType = existing?.returnType
            case .some(.null):
                returnType = nil
            case let .some(.string(value)):
                returnType = value
            case .some:
                throw ScriptingError.invalidArgument("returnType must be a string or null")
            }

            let noReturnState: FunctionSignatureOverride.NoReturnState
            switch (arguments["noReturnState"], arguments["isNoReturn"]) {
            case (.some, .some):
                throw ScriptingError.invalidArgument("provide either noReturnState or isNoReturn, not both")
            case let (.some(.string(value)), .none):
                guard let parsed = FunctionSignatureOverride.NoReturnState(rawValue: value) else {
                    throw ScriptingError.invalidArgument(
                        "noReturnState must be one of unspecified|returns|noReturn"
                    )
                }
                noReturnState = parsed
            case (.some, .none):
                throw ScriptingError.invalidArgument(
                    "noReturnState must be one of unspecified|returns|noReturn"
                )
            case let (.none, .some(.bool(value))):
                noReturnState = value ? .noReturn : .returns
            case (.none, .some):
                throw ScriptingError.invalidArgument("isNoReturn must be a boolean")
            case (.none, .none):
                noReturnState = existing?.noReturnState ?? .unspecified
            }

            let variadicState: FunctionSignatureOverride.VariadicState
            switch arguments["variadicState"] {
            case .none:
                variadicState = existing?.variadicState ?? .unspecified
            case let .some(.string(value)):
                guard let parsed = FunctionSignatureOverride.VariadicState(rawValue: value) else {
                    throw ScriptingError.invalidArgument("variadicState must be one of unspecified|fixed|variadic")
                }
                variadicState = parsed
            case .some:
                throw ScriptingError.invalidArgument("variadicState must be one of unspecified|fixed|variadic")
            }

            let parameterList: FunctionSignatureOverride.ParameterListState
            let quarantinedLegacyArgs: [LegacyArgOverride]
            switch arguments["args"] {
            case .none:
                parameterList = existing?.parameterList ?? .unspecified
                quarantinedLegacyArgs = existing?.quarantinedLegacyArgs ?? []
            case .some(.null):
                parameterList = .unspecified
                quarantinedLegacyArgs = []
            case let .some(.array(values)):
                var rowTokens = Set<String>()
                let rows = try values.enumerated().map { index, value -> ArgOverride in
                    guard case let .object(fields) = value else {
                        throw ScriptingError.invalidArgument("args[\(index)] must be an object")
                    }
                    guard case let .some(.string(type)) = fields["type"],
                          !type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ScriptingError.invalidArgument("args[\(index)].type must be a non-empty string")
                    }
                    guard Self.isValidSignatureParameterType(type) else {
                        throw ScriptingError.invalidArgument(
                            "args[\(index)].type must be a valid parameter type declaration"
                        )
                    }
                    let name: String
                    switch fields["name"] {
                    case .none:
                        name = "arg\(index)"
                    case let .some(.string(value)):
                        name = value
                    case .some:
                        throw ScriptingError.invalidArgument("args[\(index)].name must be a string")
                    }
                    var rowToken: String
                    repeat {
                        rowToken = UUID().uuidString.lowercased()
                    } while !rowTokens.insert(rowToken).inserted
                    return ArgOverride(rowToken: rowToken, name: name, type: type, provenance: .script)
                }
                parameterList = .authoritative(rows)
                // A present args value is an intentional active-list replacement;
                // stale ambiguous legacy rows no longer describe the authored list.
                quarantinedLegacyArgs = []
            case .some:
                throw ScriptingError.invalidArgument("args must be an array or null")
            }

            // Parsing and merge complete before this sole mutation point, so a malformed
            // late field cannot partially update return/no-return or parameter state.
            let signature = FunctionSignatureOverride(
                returnType: returnType,
                parameterList: parameterList,
                variadicState: variadicState,
                quarantinedLegacyArgs: quarantinedLegacyArgs,
                noReturnState: noReturnState
            )
            store.setSignature(target, signature)
            return .object(["ok": .bool(true), "address": .hex(target)])
        }
        add("set-color", "Set a color tag at an address in the primary image (red/orange/yellow/green/blue/purple/gray; empty clears; independent of the focused image).",
            mutates: true, arguments: ["address", "color"]) { arguments, store in
            let target = try address(arguments, "address")
            let color = try string(arguments, "color")
            let slot = store.snapshot.primarySlot
            if color.isEmpty {
                store.setColorTag(target, in: slot, color: nil)
            } else if let tag = ColorTag(rawValue: color) {
                store.setColorTag(target, in: slot, color: tag)
            } else {
                // Don't silently clear on a typo'd value — surface it.
                throw ScriptingError.invalidArgument("color must be one of \(ColorTag.allCases.map(\.rawValue).joined(separator: "|"))")
            }
            return .object(["ok": .bool(true), "address": .hex(target)])
        }
        add("set-operand-format", "Format an immediate operand at an address in the primary image (hex/decimal/character/unsignedDecimal/octal/binary/negativeHex; empty clears; independent of the focused image).",
            mutates: true, arguments: ["address", "format"]) { arguments, store in
            let target = try address(arguments, "address")
            let format = try string(arguments, "format")
            let slot = store.snapshot.primarySlot
            if format.isEmpty {
                store.setOperandFormat(target, in: slot, nil)
            } else if let parsed = OperandFormat(rawValue: format) {
                store.setOperandFormat(target, in: slot, parsed)
            } else {
                throw ScriptingError.invalidArgument("format must be one of \(OperandFormat.allCases.map(\.rawValue).joined(separator: "|"))")
            }
            return .object(["ok": .bool(true), "address": .hex(target)])
        }
        add("make-data", "Mark an address in the primary image as data (true) or code (false). Re-drives the primary image's analysis (what `functions`/`instructions` read; independent of the focused image).", mutates: true, arguments: ["address", "isData"]) { arguments, store in
            let target = try address(arguments, "address")
            let isData = arguments["isData"]?.boolValue ?? true
            store.setIsData(target, in: store.snapshot.primarySlot, isData)
            return .object(["ok": .bool(true), "address": .hex(target), "isData": .bool(isData)])
        }
        add("make-procedure", "Force a function start at an address in the primary image (true) or clear it (false). Re-drives the primary image's discovery (what `functions` lists; independent of the focused image).",
            mutates: true, arguments: ["address", "isProcedure"]) { arguments, store in
            let target = try address(arguments, "address")
            let isProcedure = arguments["isProcedure"]?.boolValue ?? true
            store.setMarkAsProcedure(target, in: store.snapshot.primarySlot, isProcedure)
            return .object(["ok": .bool(true), "address": .hex(target), "isProcedure": .bool(isProcedure)])
        }
        add("make-array", "Mark an address in the primary image (independent of the focused image) as an array of `count` elements of `elementType` (e.g. int32_t). The span becomes data. Optional `format` (hex/decimal/character/unsignedDecimal/octal/binary/negativeHex) materializes each element's value in the listing.",
            mutates: true, arguments: ["address", "elementType", "count", "format"]) { arguments, store in
            let target = try address(arguments, "address")
            let elementType = arguments["elementType"]?.stringValue
            guard let count = arguments["count"]?.intValue, count > 0,
                  count <= Int64(DataShapeOverride.maxElementCount) else {
                throw ScriptingError.invalidArgument("count must be a positive integer <= \(DataShapeOverride.maxElementCount)")
            }
            var displayFormat: OperandFormat?
            if let format = arguments["format"]?.stringValue, !format.isEmpty {
                guard let parsed = OperandFormat(rawValue: format) else {
                    throw ScriptingError.invalidArgument("format must be one of \(OperandFormat.allCases.map(\.rawValue).joined(separator: "|"))")
                }
                displayFormat = parsed
            }
            store.makeArray(target, in: store.snapshot.primarySlot, elementType: (elementType?.isEmpty == false) ? elementType : nil, count: Int(count), displayFormat: displayFormat)
            return .object(["ok": .bool(true), "address": .hex(target), "count": .int(count)])
        }
        add("make-alignment", "Mark an address in the primary image as alignment padding to a power-of-two byte boundary (2/4/8/16…; independent of the focused image).",
            mutates: true, arguments: ["address", "boundary"]) { arguments, store in
            let target = try address(arguments, "address")
            guard let boundary = arguments["boundary"]?.intValue, boundary > 1,
                  boundary <= Int64(DataShapeOverride.maxAlignment),
                  boundary & (boundary - 1) == 0 else {
                throw ScriptingError.invalidArgument("boundary must be a power of two (2, 4, 8, 16…) up to \(DataShapeOverride.maxAlignment)")
            }
            store.makeAlignment(target, in: store.snapshot.primarySlot, boundary: Int(boundary))
            return .object(["ok": .bool(true), "address": .hex(target), "boundary": .int(boundary)])
        }
        add("make-string", "Mark an address in the primary image as a string: NUL-terminated C string (default) or fixed `length` bytes. The span becomes data (independent of the focused image).",
            mutates: true, arguments: ["address", "length"]) { arguments, store in
            let target = try address(arguments, "address")
            if let length = arguments["length"]?.intValue {
                guard length > 0, length <= Int64(DataShapeOverride.maxStringLength) else {
                    throw ScriptingError.invalidArgument("length must be a positive integer <= \(DataShapeOverride.maxStringLength)")
                }
                store.makeString(target, in: store.snapshot.primarySlot, length: Int(length))
                return .object(["ok": .bool(true), "address": .hex(target), "length": .int(length)])
            }
            store.makeString(target, in: store.snapshot.primarySlot, length: nil)
            return .object(["ok": .bool(true), "address": .hex(target), "nullTerminated": .bool(true)])
        }
        add("make-undefined", "Mark an address in the primary image as UNDEFINED (true) or defined (false) — removes it from code analysis and renders a raw .byte undefined directive. Re-drives the primary image's analysis (independent of the focused image).",
            mutates: true, arguments: ["address", "isUndefined"]) { arguments, store in
            let target = try address(arguments, "address")
            let isUndefined = arguments["isUndefined"]?.boolValue ?? true
            store.setMarkAsUndefined(target, in: store.snapshot.primarySlot, isUndefined)
            return .object(["ok": .bool(true), "address": .hex(target), "isUndefined": .bool(isUndefined)])
        }
        add("patch-bytes", "Overwrite the primary image bytes at an address, independent of the focused image, with hex `bytes` (e.g. '1f 20 03 d5'), or `nop`: true for a NOP. The listing re-decodes the patch. Re-drives analysis.",
            mutates: true, arguments: ["address", "bytes", "nop"]) { arguments, store in
            let target = try address(arguments, "address")
            if arguments["nop"]?.boolValue == true {
                guard store.patchNOP(target, in: store.snapshot.primarySlot),
                      let patch = store.snapshot.patches(in: store.snapshot.primarySlot)[target] else {
                    throw ScriptingError.invalidArgument(store.lastIssue ?? "The NOP patch could not be applied")
                }
                return committedPatchResult(target, patch: patch, diagnostic: store.lastIssue)
            }
            let hex = try string(arguments, "bytes")
            guard let patch = BytePatch.parse(hex: hex) else {
                throw ScriptingError.invalidArgument("bytes must be an even-length hex string (e.g. '1f 20 03 d5')")
            }
            guard store.setPatch(target, in: store.snapshot.primarySlot, patch) else {
                throw ScriptingError.invalidArgument(store.lastIssue ?? "The byte patch could not be applied")
            }
            return committedPatchResult(target, patch: patch, diagnostic: store.lastIssue)
        }
        add("clear-patch", "Remove a primary image byte patch at an address, independent of the focused image, restoring the original bytes.", mutates: true, arguments: ["address"]) { arguments, store in
            let target = try address(arguments, "address")
            store.clearPatch(target, in: store.snapshot.primarySlot)
            return .object(["ok": .bool(true), "address": .hex(target)])
        }
        add("append-code-cave", "Author or clear one ARM64 executable cave for a primary-image function. Supply its function entry, branch site and instruction bytes as hex. Save Patched Binary admits supported signed thin Mach-O layouts and the native decompiler follows the generated branch; unsupported layouts refuse without an output.",
            mutates: true, arguments: ["functionAddress", "branchAddress", "bytes", "clear"]) { arguments, store in
            let entry = try address(arguments, "functionAddress")
            let slot = store.snapshot.primarySlot
            let clearing = arguments["clear"]?.boolValue == true
            if clearing {
                guard store.clearAppendedExecutableCave(at: entry, in: slot) else {
                    throw ScriptingError.invalidArgument(store.lastIssue ?? "The appended cave could not be cleared")
                }
                return .object([
                    "ok": .bool(true), "functionAddress": .hex(entry),
                    "branchAddress": .hex(entry), "byteCount": .count(0)
                ])
            }
            guard let function = store.snapshot.analysis(in: slot)?.functions.first(where: {
                $0.startAddress == entry
            }) else {
                throw ScriptingError.invalidArgument("functionAddress must name a function entry in the primary image")
            }
            let branch = try address(arguments, "branchAddress")
            guard let parsed = BytePatch.parse(hex: try string(arguments, "bytes")) else {
                throw ScriptingError.invalidArgument("bytes must contain 1–4096 bytes of even-length instruction hex")
            }
            let bytes = Data(parsed.bytes)
            guard store.setAppendedExecutableCave(
                functionID: function.id, in: slot,
                branchSourceAddress: branch, codeBytes: bytes
            ) else {
                throw ScriptingError.invalidArgument(store.lastIssue ?? "The appended cave could not be authored")
            }
            return .object([
                "ok": .bool(true), "functionAddress": .hex(entry),
                "branchAddress": .hex(branch), "byteCount": .count(UInt64(bytes.count))
            ])
        }

        // --- Produce-executable: write the patched binary (wraps MachOPatchWriter) ---
        add("save-patched-binary", "Apply the primary image's byte patches to its CAPTURED thin Mach-O bytes (the image as loaded into this workspace, not the file now at its path), independent of the focused image, and write the result. Give a `path` to write to disk, or omit it to return the patched bytes base64-encoded. Surfaces MachOPatchWriter's typed errors (fat binary, unmapped/overrun patch, not-Mach-O). A changed signed executable is re-signed ad hoc in process (`signing: ad-hoc`, no team identity); `warnings` names entitlements an ad-hoc signature cannot honor. Otherwise the output is UNSIGNED (`unsigned: true`) — re-sign with `codesign -f -s - <path>` before running.",
            arguments: ["path"]) { arguments, store in
            // MS-15: derive the output from the primary image's CAPTURED bytes through the same
            // capture/prepare/recheck helper as the GUI, never from the file now at `binary.path`.
            let slot = store.snapshot.primarySlot
            let patchedData: Data
            let prepared: PreparedMachOPatchExport
            let capture: PatchedBinaryExportCapture
            do {
                capture = try store.capturePatchedBinaryExport(in: slot)
                prepared = try capture.prepare()
                patchedData = try store.finishPatchedBinaryExport(prepared, in: slot)
            } catch PatchedBinaryExportError.noImage {
                throw ScriptingError.invalidArgument("no binary is loaded to patch")
            } catch let error as LocalizedError {
                // Surface the writer's / preparation's exact, actionable message (same as the GUI path).
                throw ScriptingError.invalidArgument(error.errorDescription ?? "patch write failed")
            }
            if let path = arguments["path"]?.stringValue, !path.isEmpty {
                let destination = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                do {
                    try capture.write(patchedData, to: destination)
                } catch {
                    throw ScriptingError.invalidArgument("could not write the patched binary to \(destination.lastPathComponent): \(error.localizedDescription)")
                }
                return .object([
                    "ok": .bool(true),
                    "path": .string(destination.path),
                    "patchCount": .int(Int64(prepared.patchCount)),
                    "byteCount": .count(UInt64(patchedData.count)),
                    "unsigned": .bool(Self.isUnsigned(prepared.signing)),
                    "signing": .string(Self.signingKind(prepared.signing)),
                    "warnings": .array(Self.signingWarnings(prepared.signing).map(ScriptValue.string)),
                    "note": .string(prepared.signing.summary),
                ])
            }
            return .object([
                "ok": .bool(true),
                "patchCount": .int(Int64(prepared.patchCount)),
                "byteCount": .count(UInt64(patchedData.count)),
                "unsigned": .bool(Self.isUnsigned(prepared.signing)),
                "signing": .string(Self.signingKind(prepared.signing)),
                "warnings": .array(Self.signingWarnings(prepared.signing).map(ScriptValue.string)),
                "bytesBase64": .string(patchedData.base64EncodedString()),
            ])
        }

        // --- Register renames in pseudocode (scoped to a procedure, undoable) ---
        add("rename-register", "Rename a REGISTER in the decompiled pseudocode for a primary-image function (by `function` display or raw name, or `address` inside it; independent of the focused image). `register` is the register id (e.g. x19); `name` is the display name. The rename shows at every occurrence of that register in the function's body and survives save/reopen + re-analysis.",
            mutates: true, arguments: ["function", "address", "register", "name"]) { arguments, store in
            let function = try resolveFunction(arguments, store.snapshot)
            let register = try string(arguments, "register")
            guard !register.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ScriptingError.invalidArgument("register must be a non-empty identifier (e.g. x19)")
            }
            let name = try string(arguments, "name")
            store.renameRegister(
                procedureStart: function.startAddress, in: store.snapshot.primarySlot,
                register: register, name: name
            )
            return .object(["ok": .bool(true), "address": .hex(function.startAddress), "register": .string(register), "name": .string(name)])
        }
        add("clear-register-name", "Clear a register rename for a primary-image function (by `function` display or raw name, or `address` inside it; independent of the focused image), restoring the raw register identifier in the pseudocode.",
            mutates: true, arguments: ["function", "address", "register"]) { arguments, store in
            let function = try resolveFunction(arguments, store.snapshot)
            let register = try string(arguments, "register")
            guard !register.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ScriptingError.invalidArgument("register must be a non-empty identifier (e.g. x19)")
            }
            store.renameRegister(
                procedureStart: function.startAddress, in: store.snapshot.primarySlot,
                register: register, name: nil
            )
            return .object(["ok": .bool(true), "address": .hex(function.startAddress), "register": .string(register)])
        }
        add("register-names", "List the register renames for a primary-image function (by `function` display or raw name, or `address` inside it) as {register: name} pairs.",
            arguments: ["function", "address"]) { arguments, store in
            let function = try resolveFunction(arguments, store.snapshot)
            let names = store.snapshot.registerNameOverrides(forProcedureAt: function.startAddress)
            return .object([
                "address": .hex(function.startAddress),
                "renames": .object(names.mapValues(ScriptValue.string)),
            ])
        }

        // --- DP04 C1: stack local names/types (scoped to a procedure, undoable) ---
        add("set-stack-local", "Rename and/or retype a STACK LOCAL in the decompiled pseudocode for a primary-image function (by `function` display or raw name, or `address` inside it). `local` is the local's entry-SP byte range `lo:hi` (e.g. -24:-16, as `stack-locals` reports it). `name` sets the name and `type` the C type; an empty value clears that field, an omitted one keeps it. The edit survives save/reopen and re-analysis; a range that no longer matches a local is kept as an orphan.",
            mutates: true, arguments: ["function", "address", "local", "name", "type"]) { arguments, store in
            let function = try resolveFunction(arguments, store.snapshot)
            let local = try string(arguments, "local")
            guard let range = MacIRStackStorage.entryRange(forAuthoringKey: local) else {
                throw ScriptingError.invalidArgument("local must be an entry-SP byte range lo:hi (e.g. -24:-16)")
            }
            let name = arguments["name"]?.stringValue
            let type = arguments["type"]?.stringValue
            guard name != nil || type != nil else { throw ScriptingError.invalidArgument("provide name and/or type") }
            if let name, !name.isEmpty, !PseudocodePrinter.isCIdentifier(name) {
                throw ScriptingError.invalidArgument("name must be a C identifier")
            }
            if let type, !type.isEmpty, !PseudocodePrinter.isTypeSpelling(type) {
                throw ScriptingError.invalidArgument("type must be a C type spelling (identifiers and trailing *)")
            }
            store.editStackLocal(procedureStart: function.startAddress, in: store.snapshot.primarySlot,
                                 entryRange: range, name: name, typeName: type)
            let stored = store.snapshot.stackLocalOverrides(forProcedureAt: function.startAddress, in: store.snapshot.primarySlot)[local]
            return .object([
                "ok": .bool(true), "address": .hex(function.startAddress), "local": .string(local),
                "name": stored?.name.map(ScriptValue.string) ?? .null,
                "type": stored?.typeName.map(ScriptValue.string) ?? .null,
            ])
        }
        add("stack-locals", "List a primary-image function's recovered stack locals (by `function` display or raw name, or `address` inside it) keyed by entry-SP range `lo:hi`, its stack local edits with `orphan: true` for an edit whose range matches no recovered local, and its register renames (`registers`) with `orphan: true` for a register the function never references.",
            arguments: ["function", "address"]) { arguments, store in
            let snapshot = store.snapshot
            let slot = snapshot.primarySlot
            let function = try resolveFunction(arguments, snapshot)
            let edits = snapshot.stackLocalOverrides(forProcedureAt: function.startAddress, in: slot)
            let irFunction = PseudocodePrinter().buildFunction(
                functionName: snapshot.displayName(at: function.startAddress, in: slot, default: function.name),
                startAddress: function.startAddress,
                jumpTables: snapshot.resolvedJumpTables(in: slot),
                objcSelectors: snapshot.analysis(in: slot)?.objcSelectors ?? [:],
                constantStrings: snapshot.constantStrings(in: slot),
                signatureOverrides: snapshot.functionSignatureOverrides(in: slot),
                authoredCallSignaturesByTarget: snapshot.authoredCallSignaturesByTarget(in: slot),
                types: snapshot.typeDefinitions,
                instructions: snapshot.pseudocodeTarget(selectedAddress: function.startAddress, in: slot)?.instructions ?? []
            )
            var recovered: [String: ScriptValue] = [:]
            for local in irFunction.localVariables {
                guard let storage = local.stackStorage else { continue }
                recovered[storage.authoringKey] = .object([
                    "name": .string(local.name), "type": .string(local.type),
                    "role": .string(storage.role.rawValue), "escapes": .bool(storage.escapes),
                ])
            }
            // A register rename applies to every occurrence (x and w views); it is an orphan
            // when the function's rows never name that register.
            var referenced = Set<String>()
            for row in irFunction.instructions {
                for token in row.source.operands.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                    guard let first = token.first, first == "x" || first == "w",
                          let index = Int(token.dropFirst()), (0...30).contains(index) else { continue }
                    referenced.insert("x\(index)")
                }
            }
            let registerNames = snapshot.registerNameOverrides(forProcedureAt: function.startAddress, in: slot)
            return .object([
                "address": .hex(function.startAddress),
                "recovered": .object(recovered),
                "registers": .object(registerNames.reduce(into: [:]) { result, entry in
                    let key = entry.key.hasPrefix("w") ? "x" + entry.key.dropFirst() : entry.key
                    result[entry.key] = .object(["name": .string(entry.value), "orphan": .bool(!referenced.contains(key))])
                }),
                "edits": .object(edits.reduce(into: [:]) { result, entry in
                    result[entry.key] = .object([
                        "name": entry.value.name.map(ScriptValue.string) ?? .null,
                        "type": entry.value.typeName.map(ScriptValue.string) ?? .null,
                        "orphan": .bool(recovered[entry.key] == nil),
                    ])
                }),
            ])
        }

        // --- DP04 D2: struct recovery from usage (read-only candidate, explicit acceptance) ---
        add("recover-struct-candidate", "Read-only: the usage-derived layout candidate for parameter `parameter` (GPR index, x0 = 0) of a primary-image function (by `function` display or raw name, or `address` inside it): fields by offset/width with evidence addresses, overlap conflicts, unknown gaps, the extent lower bound, whether the root is an interior pointer, unresolved accesses and incomplete reasons. Direct callees receiving root + k contribute (bounded). Nothing is mutated; `candidate` is the id `accept-struct-candidate` checks.",
            arguments: ["function", "address", "parameter"]) { arguments, store in
            let function = try resolveFunction(arguments, store.snapshot)
            guard let parameter = arguments["parameter"]?.intValue, (0...7).contains(parameter) else {
                throw ScriptingError.invalidArgument("parameter must be a GPR argument index 0...7")
            }
            let candidate = Self.structCandidate(snapshot: store.snapshot, function: function, parameter: Int(parameter))
            return Self.scriptValue(candidate)
        }
        add("accept-struct-candidate", "Accept a struct candidate from `recover-struct-candidate` as a new catalog type `name` (undoable, one step). `candidate` must equal the id the current analysis produces (stale evidence is rejected). Each overlap needs one entry in `choices` [{offset, width}]. The type is packed with explicit `_unknown_0x…` byte members for unobserved bytes, so every observed offset is reproduced exactly; an interior-pointer root is refused. `local` (entry-SP range `lo:hi`) optionally types that stack local as `name *`.",
            mutates: true, arguments: ["function", "address", "parameter", "candidate", "name", "choices", "local"]) { arguments, store in
            let function = try resolveFunction(arguments, store.snapshot)
            guard let parameter = arguments["parameter"]?.intValue, (0...7).contains(parameter) else {
                throw ScriptingError.invalidArgument("parameter must be a GPR argument index 0...7")
            }
            let expected = try string(arguments, "candidate")
            let name = try string(arguments, "name")
            let candidate = Self.structCandidate(snapshot: store.snapshot, function: function, parameter: Int(parameter))
            guard candidate.candidateID == expected else {
                throw ScriptingError.invalidArgument("the candidate is stale: recover it again (current \(candidate.candidateID))")
            }
            var choices: [StructCandidateTypeAdapter.Choice] = []
            if let list = arguments["choices"]?.arrayValue {
                for element in list {
                    guard let offset = element["offset"]?.intValue, let width = element["width"]?.intValue else {
                        throw ScriptingError.invalidArgument("each choice needs an integer offset and width")
                    }
                    choices.append(.init(offset: offset, byteWidth: Int(width)))
                }
            }
            var local: (procedureStart: UInt64, imageSlot: ImageSlot, entryRange: Range<Int64>)?
            if let key = arguments["local"]?.stringValue {
                guard let range = MacIRStackStorage.entryRange(forAuthoringKey: key) else {
                    throw ScriptingError.invalidArgument("local must be an entry-SP byte range lo:hi")
                }
                local = (function.startAddress, store.snapshot.primarySlot, range)
            }
            let definition: TypeDefinition
            do {
                definition = try StructCandidateTypeAdapter.typeDefinition(
                    for: candidate, name: name, choices: choices, existing: store.snapshot.typeDefinitions)
            } catch let refusal as StructCandidateTypeAdapter.Refusal {
                throw ScriptingError.invalidArgument(Self.refusalText(refusal))
            }
            store.acceptStructCandidate(definition, assigningStackLocal: local)
            return .object([
                "ok": .bool(true), "name": .string(name), "candidate": .string(expected),
                "fields": .array(definition.fields.map { .object(["name": .string($0.name), "type": .string($0.type)]) }),
                "local": local.map { .string(MacIRStackStorage.authoringKey(for: $0.entryRange)) } ?? .null,
            ])
        }

        add("indirect-call-targets", "Read-only: for a primary-image function (by `function` display or raw name, or `address` inside it), each indirect call through a memory slot (`ldr xN, [obj, #off]; blr xN`) that resolves to exactly one function: function-local when the single store reaches the load in one block, or signature-typed when the root parameter's declared type names a struct and image-wide exactly one function is stored to that slot. Refused calls carry a reason (noSlot, noStore, multipleValues, poisoned, notDominating). Indexed and multi-target slots are never guessed.",
            arguments: ["function", "address"]) { arguments, store in
            let function = try resolveFunction(arguments, store.snapshot)
            return Self.indirectCallTargets(snapshot: store.snapshot, function: function)
        }

        // --- Per-procedure local labels (undoable) ---
        add("set-local-label", "Set a LOCAL LABEL (a function-scoped name) at an address in the primary image (the image `local-labels` reads; independent of the focused image) — rendered in the listing/pseudocode within the enclosing function. Empty `label` clears it. Distinct from `rename` (a global symbol name).",
            mutates: true, arguments: ["address", "label"]) { arguments, store in
            let target = try address(arguments, "address")
            let label = try string(arguments, "label")
            store.setLocalLabel(target, in: store.snapshot.primarySlot, label: label.isEmpty ? nil : label)
            return .object(["ok": .bool(true), "address": .hex(target), "label": .string(label)])
        }
        add("clear-local-label", "Clear the local label at an address in the primary image (independent of the focused image).", mutates: true, arguments: ["address"]) { arguments, store in
            let target = try address(arguments, "address")
            store.setLocalLabel(target, in: store.snapshot.primarySlot, label: nil)
            return .object(["ok": .bool(true), "address": .hex(target)])
        }
        add("local-labels", "List the primary image's user local labels (address -> label).") { _, store in
            .array(store.snapshot.localLabels(in: store.snapshot.primarySlot).sorted { $0.key < $1.key }.map { address, label in
                .object(["address": .hex(address), "label": .string(label)])
            })
        }

        // --- Manual cross-references (add / suppress, undoable) ---
        // Like `rename`, these bind to the primary image — the image `xrefs` reads (its
        // effective xrefs merge only same-image edits) — never to live focus.
        add("add-xref", "Add a cross-reference the recovery missed in the primary image (the image `xrefs` reads; independent of the focused image): `from` -> `to`, with `kind` (call|string|selref|classref|data, default call).",
            mutates: true, arguments: ["from", "to", "kind"]) { arguments, store in
            let from = try address(arguments, "from")
            let to = try address(arguments, "to")
            let kind = arguments["kind"]?.stringValue ?? XRefKind.call
            store.addManualXRef(from: from, to: to, kind: kind, in: store.snapshot.primarySlot)
            return .object(["ok": .bool(true), "from": .hex(from), "to": .hex(to), "kind": .string(kind)])
        }
        add("suppress-xref", "Suppress a spurious recovered cross-reference in the primary image (independent of the focused image): `from` -> `to`, with `kind` (default call).",
            mutates: true, arguments: ["from", "to", "kind"]) { arguments, store in
            let from = try address(arguments, "from")
            let to = try address(arguments, "to")
            let kind = arguments["kind"]?.stringValue ?? XRefKind.call
            store.suppressXRef(from: from, to: to, kind: kind, in: store.snapshot.primarySlot)
            return .object(["ok": .bool(true), "from": .hex(from), "to": .hex(to), "kind": .string(kind)])
        }
        add("manual-xrefs", "List the primary image's user cross-reference edits (added/suppressed).") { _, store in
            let primarySlot = store.snapshot.primarySlot
            return .array(store.snapshot.manualXRefs.filter { $0.imageSlot == primarySlot }.map { edit in
                .object([
                    "from": .hex(edit.from),
                    "to": .hex(edit.to),
                    "kind": .string(edit.kind),
                    "suppressed": .bool(edit.isSuppression),
                ])
            })
        }

        // --- Bookmarks (undoable) ---
        add("add-bookmark", "Add (or rename) a named bookmark at an address in the primary image (the image `bookmarks` lists; independent of the focused image).", mutates: true, arguments: ["address", "name"]) { arguments, store in
            let target = try address(arguments, "address")
            let name = arguments["name"]?.stringValue ?? ""
            store.addBookmark(at: target, in: store.snapshot.primarySlot, name: name)
            return .object(["ok": .bool(true), "address": .hex(target), "name": .string(name)])
        }
        add("remove-bookmark", "Remove the bookmark at an address in the primary image (independent of the focused image).", mutates: true, arguments: ["address"]) { arguments, store in
            let target = try address(arguments, "address")
            store.removeBookmark(at: target, in: store.snapshot.primarySlot)
            return .object(["ok": .bool(true), "address": .hex(target)])
        }
        add("bookmarks", "List the primary image's navigation bookmarks (address-sorted).") { _, store in
            let primarySlot = store.snapshot.primarySlot
            return .array(store.snapshot.sortedBookmarks().filter { $0.imageSlot == primarySlot }.map { bookmark in
                .object(["address": .hex(bookmark.address), "name": .string(bookmark.name)])
            })
        }

        // --- Segment / section display overrides (rename + rebase) ---
        add("rename-segment", "Rename a segment/section's displayed name (empty `name` clears the rename). Keys on the section's ORIGINAL `section` name.",
            mutates: true, arguments: ["section", "name"]) { arguments, store in
            let sectionName = try string(arguments, "section")
            let name = arguments["name"]?.stringValue ?? ""
            store.renameSegment(sectionName: sectionName, displayName: name)
            return .object(["ok": .bool(true), "section": .string(sectionName), "name": .string(name)])
        }
        add("rebase-segment", "Shift a section's DISPLAYED addresses by a signed `delta` byte offset (0 clears the rebase). Analysis is untouched. Keys on the ORIGINAL `section` name. `delta` accepts a (possibly negative) integer or a hex string ('0x1000', '-0x1000').",
            mutates: true, arguments: ["section", "delta"]) { arguments, store in
            let sectionName = try string(arguments, "section")
            guard let deltaValue = arguments["delta"], let delta = signedDelta(deltaValue) else {
                throw ScriptingError.invalidArgument("delta must be an integer or hex string")
            }
            store.rebaseSegment(sectionName: sectionName, delta: delta)
            return .object(["ok": .bool(true), "section": .string(sectionName), "delta": .int(delta)])
        }
        add("clear-segment-override", "Remove the rename + rebase on a section.", mutates: true, arguments: ["section"]) { arguments, store in
            let sectionName = try string(arguments, "section")
            store.clearSegmentOverride(sectionName: sectionName)
            return .object(["ok": .bool(true), "section": .string(sectionName)])
        }
        add("segment-overrides", "List the user segment/section display overrides (rename + rebase).") { _, store in
            .array(store.snapshot.segmentOverrides.sorted { $0.originalName < $1.originalName }.map { override in
                .object([
                    "section": .string(override.originalName),
                    "displayName": override.displayName.map(ScriptValue.string) ?? .null,
                    "rebaseDelta": .int(override.rebaseDelta),
                ])
            })
        }

        // --- Type catalog ---
        add("list-types", "List the user-defined type catalog.") { _, store in
            .array(store.snapshot.typeDefinitions.map { type in
                .object([
                    "name": .string(type.name),
                    "kind": .string(type.kind.rawValue),
                    "fields": .array(type.fields.map { .object(["name": .string($0.name), "type": .string($0.type)]) }),
                ])
            })
        }
        add("list-image-types", "RX-02a Type Atlas (read-only): the types of one image — Objective-C classes, categories and protocols (name only), Swift classes/structs/enums, and the workspace user types — with members (offset + evidence: descriptor|staticEvaluation|authored|unknown; an unknown layout has a null offset), conformances, methods (selector, IMP, selref users) and users (classref xref sources, or addresses a user type is applied to). Reads the primary image by default; `image` (a slot index or an image-owner ID) selects another loaded image. Optional `kind` filters (swiftClass|swiftStruct|swiftEnum|objcClass|objcCategory|objcProtocol|userType); optional `limit` caps the rows. The result carries `imageSlot`, `imageOwner`, `total` and `types`.",
            arguments: [imageSelectorArgument, "kind", "limit"]) { arguments, store in
            let snapshot = store.snapshot
            let slot = try resolveImageSlot(arguments, snapshot: snapshot)
            var entries = snapshot.typeCatalog(in: slot).entries
            if let kindText = arguments["kind"]?.stringValue {
                guard let kind = TypeAtlasKind(rawValue: kindText) else {
                    throw ScriptingError.invalidArgument(
                        "kind must be one of \(TypeAtlasKind.allCases.map(\.rawValue).joined(separator: "|"))"
                    )
                }
                entries = entries.filter { $0.kind == kind }
            }
            let total = entries.count
            if let limit = arguments["limit"]?.intValue {
                entries = Array(entries.prefix(Int(max(0, min(limit, Int64(Int32.max))))))
            }
            var result = imageProvenanceFields(slot: slot, snapshot: snapshot)
            result["total"] = .count(UInt64(total))
            result["types"] = .array(entries.map(typeAtlasEntryValue))
            return .object(result)
        }
        add("define-type", "Add/update a type — kind: struct|union|enum|typedef, plus fields[] of {name, type}.",
            mutates: true, arguments: ["kind", "name", "fields"]) { arguments, store in
            let name = try string(arguments, "name")
            // True upsert BY NAME: reuse an existing same-named type's id so a repeat
            // call updates in place (the catalog enforces UNIQUE names, like the UI's
            // editor) instead of appending a duplicate that collapses on save. An omitted
            // kind or fields keeps the existing value: updating only `kind` must not erase
            // a struct's fields.
            let existing = store.snapshot.typeDefinitions.first(where: { $0.name == name })
            let rich = existing.map { definition in
                definition.layoutRules != .default || definition.vectorByteSize != nil
                    || definition.enumValuesIncomplete != nil || definition.fields.contains { field in
                    field.bitWidth != nil || field.bitOffset != nil || field.isPacked != nil
                        || field.layoutIsUnknown != nil || field.isAtomic != nil
                        || field.minimumAlignment != nil || field.minimumAlignmentType != nil
                        || field.inlineAggregateKind != nil || !field.inlineFields.isEmpty
                        || field.inlineAggregateLayoutRules != .default || field.promotesInlineFields
                        || (field.declaratorSemanticsV1 != nil && field.declaratorSemanticsV1 != .ordinary)
                }
            } ?? false
            let kind: TypeKind
            switch arguments["kind"] {
            case .none, .some(.null):
                kind = existing?.kind ?? .struct
            case .some(let value):
                guard let parsed = value.stringValue.flatMap(TypeKind.init(rawValue:)) else {
                    throw ScriptingError.invalidArgument("kind must be struct|union|enum|typedef")
                }
                kind = parsed
            }
            var fields: [FieldDef]
            switch arguments["fields"] {
            case .none, .some(.null):
                fields = existing?.fields ?? []
            case .some(let value):
                guard let elements = value.arrayValue else {
                    throw ScriptingError.invalidArgument("fields must be an array of {name, type}")
                }
                fields = try elements.map { element in
                    guard let fieldName = element["name"]?.stringValue, !fieldName.isEmpty,
                          let fieldType = element["type"]?.stringValue, !fieldType.isEmpty else {
                        throw ScriptingError.invalidArgument("each field needs a string name and type")
                    }
                    return FieldDef(name: fieldName, type: fieldType)
                }
            }
            if let existing, rich {
                guard kind == existing.kind,
                      fields.count == existing.fields.count,
                      zip(fields, existing.fields).allSatisfy({ pair in
                          pair.0.name == pair.1.name && pair.0.type == pair.1.type
                      }) else {
                    throw ScriptingError.invalidArgument("Unsupported lossy replacement of a rich type definition")
                }
                // Plain input may acknowledge identical leaves; it cannot erase richer storage authority.
                fields = existing.fields
            }
            let id = existing?.id ?? UUID()
            store.upsertTypeDefinition(TypeDefinition(id: id, kind: kind, name: name, fields: fields,
                layoutRules: existing?.layoutRules ?? .default,
                vectorByteSize: existing?.vectorByteSize,
                enumValuesIncomplete: existing?.enumValuesIncomplete,
                // An accepted inferred layout keeps its evidence record only while its fields
                // are unchanged; an edited layout is fully authored.
                inferenceProvenance: existing.flatMap { $0.fields == fields ? $0.inferenceProvenance : nil }))
            return .object(["ok": .bool(true), "name": .string(name)])
        }
        add("define-types-from-c", "Parse pasted C source (`source`) — struct/union/enum/typedef declarations — and add the recovered types to the catalog (undoable). Names that already exist or can't be parsed are skipped with a diagnostic, never overwritten.",
            mutates: true, arguments: ["source"]) { arguments, store in
            let source = try string(arguments, "source")
            let summary = store.defineTypesFromCHeader(source)
            return .object([
                "ok": .bool(true),
                "added": .array(summary.addedNames.map { .string($0) }),
                "diagnostics": .array(summary.diagnostics.map { .string($0) }),
            ])
        }

        // --- Debug symbols (dSYM) import ---
        add("read-debug-symbols", "Read a .dSYM bundle (or bare DWARF Mach-O) at `path` and inject its recovered, demangled function names as name overrides on the loaded binary (undoable). The dSYM's LC_UUID must match the loaded binary; pass an `uuid` to override the expected UUID (otherwise the loaded binary's UUID is used), but a dSYM whose UUID differs from the binary's own LC_UUID is always refused (imageUUIDMismatch). Surfaces the importer's typed failures (uuidMismatch / notMachO / dwarfBinaryNotFound / noFunctionsRecovered / …) as errors.",
            mutates: true, arguments: ["path", "uuid"]) { arguments, store in
            let path = try string(arguments, "path")
            guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ScriptingError.invalidArgument("path must be a non-empty path to a .dSYM bundle or DWARF Mach-O")
            }
            guard let binary = store.snapshot.binaries.first else {
                throw ScriptingError.invalidArgument("open a binary before reading its debug symbols")
            }
            // An explicit `uuid` argument overrides the loaded binary's UUID (lets a caller
            // verify against a UUID they already trust); otherwise the loaded binary's UUID
            // is the gate — exactly as the GUI import does.
            let expectedUUID = arguments["uuid"]?.stringValue ?? binary.metadata.uuid
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)

            // Validate + recover first so the importer's TYPED errors surface as ScriptingError
            // (the store's GUI path swallows them into an alert channel). On success we have the
            // exact recovered set to report; the store call below performs the undoable injection.
            let result: DSYMImportResult
            do {
                result = try DSYMImportService().importDebugSymbols(at: url, expectedUUID: expectedUUID)
            } catch let error as DSYMImportError {
                throw ScriptingError.invalidArgument(error.errorDescription ?? "debug-symbols import failed")
            } catch {
                throw ScriptingError.invalidArgument("could not read debug symbols at \(url.lastPathComponent): \(error.localizedDescription)")
            }
            // HS-9: an overriding `uuid` vouches for the dSYM, never for the image.
            do {
                try result.requireMatchingImage(uuid: binary.metadata.uuid)
            } catch let error as DSYMImportError {
                throw ScriptingError.invalidArgument(error.errorDescription ?? "debug-symbols UUID mismatch")
            }

            // Inject the ALREADY-PARSED result through the same undoable store seam the GUI uses
            // (applies addressability + demangling, registers one Undo group) — NO second parse,
            // so there is no TOCTOU window and the reported counts match what was actually applied.
            store.debugSymbolsResultMessage = nil
            store.debugSymbolsImportError = nil
            let injectedCount = store.injectDebugSymbols(result)
            if let storeError = store.debugSymbolsImportError {
                throw ScriptingError.invalidArgument(storeError)
            }

            return .object([
                "ok": .bool(true),
                "matchedUUID": .string(result.matchedUUID),
                "recoveredFromDWARF": .int(Int64(result.functions.count)),
                "injectedCount": .int(Int64(injectedCount)),
                "dwarf": .string(result.dwarfURL.lastPathComponent),
                "note": .string(store.debugSymbolsResultMessage ?? ""),
            ])
        }

        // --- Workspace documents (HOP-6; WorkspaceScriptingAPI+WorkspaceDocument.swift) ---
        for command in workspaceDocumentCommands {
            commands.append(Command(info: command.info, run: command.run))
        }

        return Dictionary(uniqueKeysWithValues: commands.map { ($0.info.name, $0) })
    }()
}
