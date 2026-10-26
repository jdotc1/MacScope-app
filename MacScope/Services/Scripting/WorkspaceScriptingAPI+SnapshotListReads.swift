import Foundation

/// Admission for the legacy flat lists and instruction selector, not a caller-supplied argument.
/// Only the attached executor opts into finite attached bounds; inline and ordinary async
/// callers keep their existing nil/no-limit and explicit-limit contracts.
enum SnapshotListReadScope: Equatable, Sendable {
    case nonattached
    case attached
}

/// The list reads that need only an immutable `WorkspaceSnapshot`. The command registry runs
/// them inline (CLI/AppleScript); async bindings and the attached executor run
/// the same code in a detached task over a snapshot captured on the MainActor, so building an
/// image-sized list never holds the UI (DP09-2 N3). `checkpoint` runs every
/// `checkpointInterval` rows and throws to cancel.
extension WorkspaceScriptingAPI {
    /// Async callers own the complete snapshot preparation and materialization task.
    func executeSnapshotListRead(_ command: String, arguments: ScriptValue) async throws -> ScriptValue {
        try Task.checkCancellation()
        let snapshot = store.snapshot
        let catalog = command == "commands" ? Self.availableCommands : []
        let probe = snapshotReadCheckpoint
        let work = Task.detached(priority: Task.currentPriority) {
            try Self.snapshotListRead(command, arguments: arguments, snapshot: snapshot, commandCatalog: catalog) {
                probe?()
                try Task.checkCancellation()
            }
        }
        let output = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
        return output
    }

    nonisolated static let snapshotListCommands: Set<String> = [
        "functions", "instructions", "symbols", "strings", "imports", "exports", "sections", "relocations",
        "list-types", "list-image-types", "indirect-call-targets", "stack-locals", "recover-struct-candidate",
        "commands", "info", "xrefs", "callers", "callees", "name-at", "read-bytes", "resolve-symbol",
        "bookmarks", "local-labels", "register-names", "manual-xrefs", "segment-overrides",
    ]
    nonisolated static let checkpointInterval = 256
    nonisolated static let maximumSnapshotSelectionWork = 100_000
    nonisolated static let maximumSnapshotRows = 5_000
    nonisolated static let maximumSnapshotInstructionRows = 2_000

    nonisolated static func snapshotListRead(
        _ command: String,
        arguments: ScriptValue,
        snapshot: WorkspaceSnapshot,
        scope: SnapshotListReadScope = .nonattached,
        selectionWorkLimit: Int = maximumSnapshotSelectionWork,
        commandCatalog: [ScriptingCommandInfo] = [],
        checkpoint: () throws -> Void = {}
    ) throws -> ScriptValue {
        let limit: Int? = scope == .attached
            ? min(rowLimit(arguments) ?? maximumSnapshotRows, maximumSnapshotRows)
            : rowLimit(arguments)
        func rows<Element>(_ all: [Element], _ make: (Element) -> ScriptValue) throws -> ScriptValue {
            let selected = all.prefix(limit ?? all.count)
            var out: [ScriptValue] = []
            out.reserveCapacity(selected.count)
            for (index, element) in selected.enumerated() {
                if index % checkpointInterval == 0 { try checkpoint() }
                out.append(make(element))
            }
            return .array(out)
        }

        switch command {
        case "xrefs":
            return try snapshotXRefRead(arguments, snapshot: snapshot,
                selectionWorkLimit: selectionWorkLimit, checkpoint: checkpoint)

        case "functions":
            return try rows(snapshot.functions) { function in
                .object([
                    "name": .string(snapshot.displayName(at: function.startAddress, default: function.name)),
                    "address": .hex(function.startAddress),
                    "end": .hex(function.endAddress),
                    "confidence": .double(function.confidence),
                ])
            }

        case "list-types", "list-image-types":
            return try snapshotTypeListRead(command, arguments: arguments, snapshot: snapshot, checkpoint: checkpoint)

        case "indirect-call-targets":
            return try boundedIndirectCallTargets(arguments: arguments, snapshot: snapshot, checkpoint: checkpoint)

        case "stack-locals":
            return try boundedStackLocals(arguments: arguments, snapshot: snapshot, checkpoint: checkpoint)

        case "recover-struct-candidate":
            return try boundedStructCandidate(arguments: arguments, snapshot: snapshot, checkpoint: checkpoint)

        case "instructions":
            try checkpoint()
            let named = arguments["function"]?.stringValue != nil
            let function: FunctionSummary?
            let start: UInt64
            if named {
                function = try boundedSnapshotFunction(arguments, snapshot: snapshot, scope: scope, checkpoint: checkpoint)
                start = 0
            } else {
                function = nil
                start = try address(arguments, "address")
            }
            // Named-function reads historically ignore count and return the whole function.
            // Address reads keep their requested count (default 16). Only attach adds a cap.
            let requested: Int? = named ? nil : Int(max(0, arguments["count"]?.intValue ?? 16))
            let count: Int? = scope == .attached
                ? min(requested ?? maximumSnapshotInstructionRows, maximumSnapshotInstructionRows)
                : requested
            guard count != 0 else { return .array([]) }
            var output: [ScriptValue] = []
            output.reserveCapacity(min(count ?? snapshot.instructions.count, snapshot.instructions.count))
            // Select incrementally, checkpointing nonmatches too. Never allocate an image-sized
            // filtered collection merely to take a small prefix (including named functions).
            for (index, row) in snapshot.instructions.enumerated() {
                guard scope != .attached || index < min(selectionWorkLimit, maximumSnapshotSelectionWork) else {
                    throw ScriptingError.invalidArgument("instruction selection exceeds the snapshot work budget")
                }
                if index % checkpointInterval == 0 { try checkpoint() }
                let matches: Bool
                if let function {
                    matches = function.endAddress > function.startAddress
                        ? row.address >= function.startAddress && row.address < function.endAddress
                        : row.address == function.startAddress
                } else {
                    matches = row.address >= start
                }
                guard matches else { continue }
                output.append(instructionObject(row, snapshot))
                if let count, output.count == count { break }
            }
            try checkpoint()
            return .array(output)

        case "symbols":
            return try rows(snapshot.symbols) { symbol in
                .object([
                    "name": .string(symbol.name),
                    "address": symbol.address.map(ScriptValue.hex) ?? .null,
                    "kind": .string(symbol.kind),
                ])
            }

        case "strings":
            return try rows(snapshot.stringLiterals) { literal in
                .object(["value": .string(literal.value), "address": .hex(literal.address)])
            }

        case "imports":
            return try rows(snapshot.imports) { item in
                .object([
                    "name": .string(item.name),
                    "library": item.libraryName.map(ScriptValue.string) ?? .null,
                    "ordinal": item.libraryOrdinal.map { .int(Int64($0)) } ?? .null,
                ])
            }

        case "exports":
            return try rows(snapshot.exports) { item in
                .object([
                    "name": .string(item.name),
                    "address": item.address.map(ScriptValue.hex) ?? .null,
                    "source": .string(item.source),
                ])
            }

        case "sections":
            // Apply the same display override only to admitted rows, without mapping all sections.
            return try rows(snapshot.sections) { original in
                let override = snapshot.segmentOverride(for: original.name, in: snapshot.primarySlot)
                var display = original
                if let override {
                    display.name = override.resolvedName(default: original.name)
                    display.address = override.rebased(original.address)
                }
                return .object([
                    "name": .string(display.name),
                    "originalName": .string(original.name),
                    "address": .hex(display.address),
                    "size": .count(display.size),
                    "fileOffset": .hex(display.fileOffset),
                    "executable": .bool(display.isExecutable),
                    "zeroFill": .bool(display.isZeroFill),
                ])
            }

        case "relocations":
            return try rows(snapshot.relocations) { reloc in
                var fields: [String: ScriptValue] = [
                    "address": .hex(reloc.address),
                    "section": .string(reloc.sectionName),
                    "typeCode": .count(UInt64(reloc.typeCode)),
                    "pcRelative": .bool(reloc.isPCRelative),
                ]
                if let typeName = reloc.typeName { fields["type"] = .string(typeName) }
                if let symbolName = reloc.symbolName { fields["symbol"] = .string(symbolName) }
                if let symbolIndex = reloc.symbolIndex { fields["symbolIndex"] = .count(UInt64(symbolIndex)) }
                if let addend = reloc.addend { fields["addend"] = .int(addend) }
                if reloc.widthInBytes > 0 { fields["width"] = .count(UInt64(reloc.widthInBytes)) }
                return .object(fields)
            }

        default:
            return try attachedSnapshotRead(command, arguments: arguments, snapshot: snapshot,
                                            commandCatalog: commandCatalog, checkpoint: checkpoint)
        }
    }

    /// Xref limits apply before selection and row encoding in both inline and detached reads.
    /// An absent limit retains the complete-list contract within the finite result budget.
    nonisolated static func snapshotXRefRead(
        _ arguments: ScriptValue,
        snapshot: WorkspaceSnapshot,
        selectionWorkLimit: Int = maximumSnapshotSelectionWork,
        resultLimit: Int = maximumSnapshotRows,
        checkpoint: () throws -> Void = {}
    ) throws -> ScriptValue {
        let direction: WorkspaceSnapshot.XRefQueryDirection
        if let to = arguments["to"]?.addressValue {
            direction = .to(to)
        } else if let from = arguments["from"]?.addressValue {
            direction = .from(from)
        } else {
            throw ScriptingError.missingArgument("to or from")
        }
        let filter = try resolveImageSlotFilter(arguments, snapshot: snapshot)
        let rowSlot = filter ?? snapshot.primarySlot
        let refs: [XRef]
        do {
            refs = try snapshot.boundedEffectiveXRefs(direction, in: filter, limit: rowLimit(arguments),
                maximumRows: min(resultLimit, maximumSnapshotRows),
                maximumWork: min(selectionWorkLimit, maximumSnapshotSelectionWork), checkpoint: checkpoint)
        } catch WorkspaceSnapshot.XRefQueryFailure.workBudget {
            throw ScriptingError.invalidArgument("xrefs exceeds the snapshot work budget")
        } catch WorkspaceSnapshot.XRefQueryFailure.resultBudget {
            throw ScriptingError.invalidArgument("xrefs exceeds the snapshot result budget; request a smaller limit")
        }
        var rows: [ScriptValue] = []
        rows.reserveCapacity(refs.count)
        for (index, ref) in refs.enumerated() {
            if index % checkpointInterval == 0 { try checkpoint() }
            rows.append(.object([
                "from": .hex(ref.from), "to": .hex(ref.to), "kind": .string(ref.kind),
                "imageSlot": .int(Int64(rowSlot.rawValue)),
            ]))
        }
        try checkpoint()
        return .array(rows)
    }

    /// Same name/address ambiguity policy as resolveFunction, with incremental checkpoints.
    /// Bounded analysis/metadata callers retain attached budgets by default. The legacy
    /// instruction-list route explicitly passes its scope so large nonattached lists remain valid.
    nonisolated static func boundedSnapshotFunction(
        _ arguments: ScriptValue, snapshot: WorkspaceSnapshot,
        scope: SnapshotListReadScope = .attached, checkpoint: () throws -> Void
    ) throws -> FunctionSummary {
        let name = arguments["function"]?.stringValue
        let address = arguments["address"]?.addressValue
        guard name != nil || address != nil else { throw ScriptingError.missingArgument("function or address") }
        var matches: [FunctionSummary] = []
        var containing: FunctionSummary?
        var preceding: FunctionSummary?
        for (index, function) in snapshot.functions.enumerated() {
            guard scope != .attached || index < maximumSnapshotSelectionWork else {
                throw ScriptingError.invalidArgument("function selection exceeds the snapshot work budget")
            }
            if index % checkpointInterval == 0 { try checkpoint() }
            if let name {
                if function.name == name || snapshot.displayName(at: function.startAddress, default: function.name) == name {
                    guard scope != .attached || matches.count < maximumSnapshotRows else {
                        throw ScriptingError.invalidArgument("ambiguous function selection exceeds the result budget")
                    }
                    matches.append(function)
                }
            } else if let address {
                let contains = function.endAddress > function.startAddress
                    ? address >= function.startAddress && address < function.endAddress
                    : address == function.startAddress
                if contains, containing == nil { containing = function }
                if function.startAddress <= address,
                   preceding.map({ function.startAddress > $0.startAddress }) ?? true { preceding = function }
            }
        }
        if let name {
            guard let first = matches.first else { throw ScriptingError.invalidArgument("no function named '\(name)'") }
            guard matches.count == 1 else {
                throw ScriptingError.ambiguousFunctionSelector(name: name, addresses: matches.map(\.startAddress))
            }
            return first
        }
        guard let function = containing ?? preceding else { throw ScriptingError.invalidArgument("no function at that address") }
        return function
    }
}
