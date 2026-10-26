import Darwin
import Foundation

enum HeadlessJSONError: LocalizedError {
    case invalid

    var errorDescription: String? { "Invalid bounded JSON." }
}

/// Owns framing output independently of the workspace actor. Each complete NDJSON
/// line is written in one serialized span, even when requests complete out of order.
private actor MCPResponseWriter {
    let output: FileHandle
    private var failed = false
    init(output: FileHandle) { self.output = output }
    func write(_ data: Data) throws {
        guard !failed else { throw HeadlessProtocolIOError.writeFailure }
        do { try HeadlessProtocolIO.writeLine(data, to: output) }
        catch { failed = true; throw error }
    }
}

/// Session-scoped admission and cancellation never require MainActor. Cancelled
/// reads retain a bounded retirement slot until their owned task actually returns;
/// a reused ID cannot consume a late completion from the previous invocation.
actor MCPRequestSession {
    typealias Execute = @Sendable (Data) async -> Data?
    private struct Entry: Sendable {
        let token: UUID
        let request: Data
        let responseID: Phase2ProductionJSONValue?
        let mutation: Bool
        var task: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        var terminal = false
        var cancellation: (code: Int, message: String)?
    }
    private let configuration: MCPServer.Configuration
    private let mutatingCommands: Set<String>
    private let execute: Execute
    private let output: @Sendable (Data) async throws -> Void
    private var entries: [String: Entry] = [:]
    private var mutationQueue: [String] = []
    private var activeMutation: String?
    private var accepting = true
    private var outputFailed = false
    private var pendingWrites = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    init(configuration: MCPServer.Configuration, mutatingCommands: Set<String>,
         execute: @escaping Execute, output: @escaping @Sendable (Data) async throws -> Void) {
        self.configuration = configuration
        self.mutatingCommands = mutatingCommands
        self.execute = execute
        self.output = output
    }

    var inFlightCount: Int { entries.count }
    var isAcceptingRequests: Bool { accepting }
    var pendingTerminalWriteCount: Int { pendingWrites }
    var isAwaitingInputDrain: Bool { !drainWaiters.isEmpty }

    func receiveOversized() async { await emitError(id: nil, code: -32700, message: "Parse error") }

    func receive(_ data: Data) async {
        guard accepting, !data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) else { return }
        let value: Phase2ProductionJSONValue
        do {
            value = try Phase2StrictJSONParser().parse(data, limits: .init(
                maximumBytes: configuration.maximumInputBytes, maximumDepth: 16,
                maximumTokens: 100_000, maximumMembersAndElements: 50_000))
        } catch { await receiveOversized(); return }
        guard var fields = value.objectValue, fields["jsonrpc"] == .string("2.0"),
              let method = fields["method"]?.stringValue, !method.isEmpty,
              method.utf8.count <= 256,
              !method.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              fields["id"] == nil || Self.key(fields["id"]) != nil else {
            await emitError(id: nil, code: -32600, message: "Invalid Request")
            return
        }
        let responseID = fields["id"]
        if method == "notifications/cancelled" {
            guard responseID == nil else {
                await emitError(id: responseID, code: -32600, message: "Invalid Request")
                return
            }
            if let params = fields["params"]?.objectValue,
               Set(params.keys).isSubset(of: ["requestId", "reason"]),
               let key = Self.key(params["requestId"]) {
                await cancel(key, code: -32800, message: "Request cancelled")
            }
            return
        }
        if responseID == nil && method.hasPrefix("notifications/") { return }
        let key = Self.key(responseID) ?? "anonymous:" + UUID().uuidString
        guard entries[key] == nil else {
            await emitError(id: responseID, code: -32600, message: "Request ID is already in flight")
            return
        }
        guard entries.count + pendingWrites < configuration.maximumInFlightRequests else {
            if responseID != nil { await emitError(id: responseID, code: -32000, message: "Too many in-flight requests") }
            return
        }
        // Preserve arbitrary JSON numeric IDs independently of legacy scripting
        // number conversion. The handler sees a surrogate; the terminal restores
        // the exact admitted ID lexeme, including explicit null.
        if responseID != nil { fields["id"] = .number("0") }
        let mutation = method == "tools/call"
            && mutatingCommands.contains(fields["params"]?.objectValue?["name"]?.stringValue ?? "")
        let token = UUID()
        entries[key] = Entry(token: token, request: Phase2ProductionJSONValue.object(fields).canonicalJSONBytes(),
                             responseID: responseID, mutation: mutation)
        let duration = configuration.maximumToolDurationNanoseconds
        entries[key]?.deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: duration) } catch { return }
            await self?.expire(key, token: token)
        }
        if mutation {
            mutationQueue.append(key)
            startNextMutation()
        } else { start(key) }
    }

    private func start(_ key: String) {
        guard let entry = entries[key] else { return }
        let operation = execute
        entries[key]?.task = Task.detached { [weak self] in
            let response = await operation(entry.request)
            await self?.complete(key, token: entry.token, response: response)
        }
    }

    private func startNextMutation() {
        guard accepting, activeMutation == nil else { return }
        while !mutationQueue.isEmpty {
            let key = mutationQueue.removeFirst()
            guard entries[key] != nil else { continue }
            activeMutation = key
            start(key)
            return
        }
    }

    private func expire(_ key: String, token: UUID) async {
        guard entries[key]?.token == token else { return }
        await cancel(key, code: -32001, message: "Request deadline exceeded")
    }

    private func cancel(_ key: String, code: Int, message: String) async {
        guard var entry = entries[key], !entry.terminal else { return }
        entry.task?.cancel()
        entry.deadline?.cancel()
        // A running mutation owns the truth of its commit. Its result must decide
        // whether cancellation preceded admission or arrived after durable work.
        if entry.mutation && entry.task != nil {
            if entry.cancellation == nil { entry.cancellation = (code, message) }
            entries[key] = entry
            return
        }
        entry.terminal = true
        entries[key] = entry
        if entry.task == nil {
            entries.removeValue(forKey: key)
            mutationQueue.removeAll { $0 == key }
        }
        if entry.responseID != nil { await emitError(id: entry.responseID, code: code, message: message) }
    }

    private func complete(_ key: String, token: UUID, response: Data?) async {
        guard let entry = entries[key], entry.token == token else { return }
        entry.deadline?.cancel()
        entries.removeValue(forKey: key)
        if !entry.terminal, let response, let id = entry.responseID {
            if let cancellation = entry.cancellation,
               let fields = try? Phase2StrictJSONParser().parse(response, limits: .providerEnvelope).objectValue,
               fields["error"]?.objectValue?["code"] == .number("-32800") {
                await emitError(id: id, code: cancellation.code, message: cancellation.message)
            } else {
                await emit(Self.restoringID(id, response: response, maximumBytes: configuration.maximumOutputBytes))
            }
        }
        if activeMutation == key { activeMutation = nil; startNextMutation() }
        resumeDrainIfEmpty()
    }

    /// EOF retires read results and queued work, but waits for every running task's
    /// cleanup acknowledgment and every terminal write before transport teardown.
    /// Running mutations preserve committed truth rather than claim rollback.
    func finishInput() async {
        accepting = false
        let keys = Array(entries.keys)
        for key in keys {
            await cancel(key, code: -32800, message: "Input closed")
        }
        resumeDrainIfEmpty()
        if !entries.isEmpty || pendingWrites != 0 {
            await withCheckedContinuation { drainWaiters.append($0) }
        }
    }

    private func resumeDrainIfEmpty() {
        guard entries.isEmpty, pendingWrites == 0 else { return }
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func emitError(id: Phase2ProductionJSONValue?, code: Int, message: String) async {
        guard let id else {
            await emit(Self.error(id: .null, code: code, message: message))
            return
        }
        await emit(Self.error(id: id, code: code, message: message))
    }

    private func emit(_ data: Data) async {
        guard !outputFailed else { return }
        pendingWrites += 1
        defer { pendingWrites -= 1; resumeDrainIfEmpty() }
        do { try await output(data) }
        catch {
            // A broken response transport cannot authorize further mutations. Keep
            // running tasks until their owned cleanup acknowledges cancellation.
            outputFailed = true
            accepting = false
            for key in Array(entries.keys) {
                guard var entry = entries[key] else { continue }
                entry.task?.cancel()
                entry.deadline?.cancel()
                entry.terminal = true
                if entry.task == nil { entries.removeValue(forKey: key) }
                else { entries[key] = entry }
            }
            mutationQueue.removeAll()
        }
    }

    private static func error(id: Phase2ProductionJSONValue, code: Int, message: String) -> Data {
        Phase2ProductionJSONValue.object(["jsonrpc": .string("2.0"), "id": id,
            "error": .object(["code": .integer(code), "message": .string(message)])]).canonicalJSONBytes()
    }

    private static func restoringID(_ id: Phase2ProductionJSONValue, response: Data, maximumBytes: Int) -> Data {
        guard var fields = try? Phase2StrictJSONParser().parse(response, limits: .init(
            maximumBytes: maximumBytes, maximumDepth: 32, maximumTokens: 1_000_000,
            maximumMembersAndElements: 500_000)).objectValue else {
            return error(id: id, code: -32603, message: "Invalid response")
        }
        fields["id"] = id
        let bytes = Phase2ProductionJSONValue.object(fields).canonicalJSONBytes()
        return bytes.count <= maximumBytes ? bytes : error(id: id, code: -32603, message: "Response exceeds limit")
    }

    private static func key(_ value: Phase2ProductionJSONValue?) -> String? {
        switch value {
        case .null?: return "null"
        case .string(let text)? where text.utf8.count <= 256
            && !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains):
            return "string:" + text
        case .number(let source)? where source.utf8.count <= 256:
            let negative = source.first == "-"
            let unsigned = negative ? String(source.dropFirst()) : source
            let parts = unsigned.lowercased().split(separator: "e")
            let decimal = parts[0].split(separator: ".", omittingEmptySubsequences: false)
            var digits = String(decimal.joined().drop(while: { $0 == "0" }))
            if digits.isEmpty { return "number:0" }
            let exponent: Int64
            if parts.count == 2 {
                guard let parsed = Int64(parts[1]) else { return "number:" + source }
                exponent = parsed
            } else { exponent = 0 }
            let scaled = exponent.subtractingReportingOverflow(Int64(decimal.count == 2 ? decimal[1].count : 0))
            guard !scaled.overflow else { return "number:" + source }
            var scale = scaled.partialValue
            while digits.last == "0", scale < Int64.max { digits.removeLast(); scale += 1 }
            return "number:" + (negative ? "-" : "") + digits + "e" + String(scale)
        default: return nil
        }
    }
}

/// Strict JSON admission shared by the two headless adapters. The Phase 2 parser rejects
/// duplicate keys, malformed Unicode, excessive depth/token counts, and trailing bytes before
/// the value is converted into the legacy scripting DTO.
enum HeadlessJSON {
    static func decode(_ data: Data, maximumBytes: Int) throws -> ScriptValue {
        let limits = Phase2StrictJSONLimits(
            maximumBytes: maximumBytes,
            maximumDepth: 16,
            maximumTokens: 100_000,
            maximumMembersAndElements: 50_000
        )
        let value: Phase2ProductionJSONValue
        do {
            value = try Phase2StrictJSONParser().parse(data, limits: limits)
        } catch {
            throw HeadlessJSONError.invalid
        }
        return try convert(value)
    }

    /// JSON Schema integers include decimal/exponent spellings (1.0 and 1e3).
    /// Normalize their decimal digits before any floating-point conversion so an
    /// address or signed delta above 2^53 never silently rounds to another byte.
    /// The strict JSON parser has already validated the number grammar.
    private static func exactInteger(_ source: String) -> Int64? {
        if let direct = Int64(source) { return direct }
        let negative = source.first == "-"
        let unsigned = negative ? String(source.dropFirst()) : source
        let exponentParts = unsigned.split(whereSeparator: { $0 == "e" || $0 == "E" })
        guard exponentParts.count == 1 || exponentParts.count == 2 else { return nil }
        let mantissa = exponentParts[0]
        let decimalParts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        guard decimalParts.count == 1 || decimalParts.count == 2 else { return nil }
        let fractionCount = decimalParts.count == 2 ? decimalParts[1].count : 0
        var digits = decimalParts.joined()
        guard !digits.isEmpty, digits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        digits = String(digits.drop(while: { $0 == "0" }))
        if digits.isEmpty { return 0 }
        let exponent: Int64
        if exponentParts.count == 2 {
            let exponentSource = String(exponentParts[1])
            let exponentNegative = exponentSource.first == "-"
            let magnitudeSource = (exponentSource.first == "+" || exponentNegative)
                ? String(exponentSource.dropFirst()) : exponentSource
            let magnitude = String(magnitudeSource.drop(while: { $0 == "0" }))
            guard magnitude.isEmpty || magnitude.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let value = Int64(magnitude.isEmpty ? "0" : magnitude) else { return nil }
            exponent = exponentNegative ? -value : value
        } else {
            exponent = 0
        }
        let scale = exponent.subtractingReportingOverflow(Int64(fractionCount))
        guard !scale.overflow else { return nil }
        if scale.partialValue >= 0 {
            guard digits.count <= 19, scale.partialValue <= Int64(19 - digits.count) else { return nil }
            digits += String(repeating: "0", count: Int(scale.partialValue))
        } else {
            // Avoid negating Int64.min; a nonzero fractional value cannot be an integer.
            guard scale.partialValue >= -Int64(digits.count) else { return nil }
            let removed = Int(-scale.partialValue)
            guard digits.suffix(removed).allSatisfy({ $0 == "0" }) else { return nil }
            digits.removeLast(removed)
        }
        guard !digits.isEmpty, digits.count <= 19 else { return nil }
        return Int64((negative ? "-" : "") + digits)
    }

    private static func convert(_ value: Phase2ProductionJSONValue) throws -> ScriptValue {
        switch value {
        case .null:
            return .null
        case .bool(let value):
            return .bool(value)
        case .number(let source):
            if let integer = exactInteger(source) { return .int(integer) }
            guard let number = Double(source), number.isFinite else {
                throw HeadlessJSONError.invalid
            }
            return .double(number)
        case .string(let value):
            return .string(value)
        case .array(let values):
            return .array(try values.map(convert))
        case .object(let fields):
            return .object(try fields.mapValues(convert))
        }
    }
}

enum HeadlessAutomationAuthorityError: LocalizedError, Equatable {
    case unavailableCommand
    case invalidArguments
    case invalidScript

    var errorDescription: String? {
        switch self {
        case .unavailableCommand: "The command is unavailable through headless automation."
        case .invalidArguments: "The command arguments are invalid for headless automation."
        case .invalidScript: "The script is invalid for headless automation."
        }
    }
}

/// Closed authority for the legacy external adapters. New scripting commands do not silently
/// become remotely callable. In particular, the filesystem-bearing commands are intentionally
/// absent: headless clients cannot read arbitrary dSYMs, write arbitrary paths, or emit a whole
/// patched binary through stdout.
@MainActor
enum HeadlessAutomationAuthority {
    struct ScriptStep {
        let command: String
        let arguments: ScriptValue
    }

    static let maximumScriptSteps = 1_024
    static let maximumContainerMembers = 4_096
    static let maximumArgumentStringBytes = 256 * 1_024
    static let maximumListRows = 10_000
    static let maximumReadBytes = 1 * 1_024 * 1_024
    /// The bounded search engine admits 256 UTF-8 bytes (after trimming); that limit is a
    /// performance bound, so the surface documents and enforces the same number. A longer query
    /// is refused with `{error: "invalidPattern", detail: "tooLong"}` (`searchRefusal`).
    static let maximumSearchQueryBytes = 256

    private static let allowedCommandNames: Set<String> = [
        "add-bookmark", "add-xref", "basic-blocks", "bookmarks", "callees", "callers",
        "call-argument-audit", "clear-local-label", "clear-patch", "clear-register-name",
        "clear-segment-override", "commands", "decompile", "define-type",
        "define-types-from-c", "exports", "functions", "goto", "imports", "info",
        "instructions", "list-image-types", "list-types", "local-labels", "make-alignment", "make-array",
        "make-data", "make-procedure", "make-string", "make-undefined", "manual-xrefs",
        "name-at", "neon-hitrate", "open-workspace", "parameter-binding-audit", "patch-bytes", "read-bytes", "read-evidence",
        "rebase-segment", "reconstruction-jobs", "register-names", "relocations", "remove-bookmark", "rename", "rename-register",
        "rename-segment", "resolve-symbol", "save-workspace", "search", "sections", "segment-overrides",
        "set-color", "set-comment", "set-local-label", "set-operand-format", "set-signature",
        "set-tag", "set-type", "strings", "suppress-xref", "symbols", "xrefs",
        // DP04 C2: durable stack local rename/retype and the local listing (orphans included).
        "set-stack-local", "stack-locals",
        // DP04 D2: struct recovery (read-only candidate; explicit acceptance into the catalog).
        "recover-struct-candidate", "accept-struct-candidate",
        // Read-only single-target resolution of indirect calls through memory slots.
        "indirect-call-targets",
    ]

    /// The existing headless commands plus the navigator commands (`MCPServer+Navigator.swift`),
    /// which are closed-list members like the rest: catalog exposure and execution both use it.
    static var availableCommands: [ScriptingCommandInfo] {
        WorkspaceScriptingAPI.availableCommands.filter { allowedCommandNames.contains($0.name) }
            + NavigatorMCPCommands.catalog
    }

    private static func admits(_ command: String) -> Bool {
        allowedCommandNames.contains(command) || NavigatorMCPCommands.handles(command)
    }

    /// Describes the existing headless command contract. It does not grant authority:
    /// both catalog exposure and execution still use the closed command allowlist.
    static func inputSchema(for command: ScriptingCommandInfo) -> ScriptValue {
        var properties: [String: ScriptValue] = [:]
        for argument in command.arguments {
            properties[argument] = argumentSchema(command: command.name, argument: argument)
        }
        var schema: [String: ScriptValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false),
        ]
        let required = requiredArguments(for: command.name)
        if !required.isEmpty { schema["required"] = .array(required.map(ScriptValue.string)) }

        // Legacy function resolution prefers the name when both selectors are present.
        // The call-audit resolver separately requires exactly one selector.
        if command.arguments.contains("function") && command.arguments.contains("address") {
            let keyword = command.name == "call-argument-audit" ? "oneOf" : "anyOf"
            schema[keyword] = .array([requiredSchema(["function"]), requiredSchema(["address"])])
        } else if command.name == "xrefs" {
            schema["anyOf"] = .array([requiredSchema(["to"]), requiredSchema(["from"])])
        } else if command.name == "patch-bytes" {
            schema["anyOf"] = .array([
                requiredSchema(["bytes"]),
                .object([
                    "required": .array([.string("nop")]),
                    "properties": .object(["nop": .object(["const": .bool(true)])]),
                ]),
            ])
        }
        if command.name == "set-signature" {
            schema["not"] = requiredSchema(["isNoReturn", "noReturnState"])
        }
        return .object(schema)
    }

    private static func requiredSchema(_ names: [String]) -> ScriptValue {
        .object(["required": .array(names.map(ScriptValue.string))])
    }

    private static func requiredArguments(for command: String) -> [String] {
        if NavigatorMCPCommands.handles(command) { return NavigatorMCPCommands.requiredArguments(for: command) }
        switch command {
        case "read-evidence": return ["operation"]
        case "rename": return ["address", "name"]
        case "set-comment": return ["address", "comment"]
        case "set-tag": return ["address", "tag"]
        case "set-type": return ["address", "type"]
        case "set-color": return ["address", "color"]
        case "set-operand-format": return ["address", "format"]
        case "set-local-label": return ["address", "label"]
        case "make-array": return ["address", "count"]
        case "make-alignment": return ["address", "boundary"]
        case "rename-register": return ["register", "name"]
        case "clear-register-name": return ["register"]
        case "set-stack-local": return ["local"]
        case "recover-struct-candidate": return ["parameter"]
        case "accept-struct-candidate": return ["parameter", "candidate", "name"]
        case "add-xref", "suppress-xref": return ["from", "to"]
        case "goto", "search": return ["query"]
        case "open-workspace": return ["path"]
        case "resolve-symbol", "define-type": return ["name"]
        case "define-types-from-c": return ["source"]
        case "rename-segment", "clear-segment-override": return ["section"]
        case "rebase-segment": return ["section", "delta"]
        case "read-bytes", "name-at", "make-data", "make-procedure", "make-string",
             "make-undefined", "patch-bytes", "clear-patch", "set-signature",
             "add-bookmark", "remove-bookmark", "clear-local-label":
            return ["address"]
        default: return []
        }
    }

    private static func argumentSchema(command: String, argument: String) -> ScriptValue {
        if NavigatorMCPCommands.handles(command) { return NavigatorMCPCommands.argumentSchema(argument) }
        func integer(_ minimum: Int64, _ maximum: Int64) -> ScriptValue {
            .object([
                "type": .string("integer"), "minimum": .int(minimum), "maximum": .int(maximum),
            ])
        }
        let string: ScriptValue = .object(["type": .string("string")])
        let boolean: ScriptValue = .object(["type": .string("boolean")])
        switch (command, argument) {
        case ("read-evidence", "operation"):
            // Preserve the new external subset; discovery never admits native,
            // shell, mutation, principal, or caller-supplied replay authority.
            return .object([
                "type": .string("string"),
                "enum": .array(TypedReadRegistry.ExternalOperation.allCases.map {
                    .string($0.rawValue)
                }),
            ])
        case (_, "limit"):
            return integer(0, Int64(maximumListRows))
        case ("list-image-types", "kind"):
            return .object([
                "type": .string("string"),
                "enum": .array(TypeAtlasKind.allCases.map { .string($0.rawValue) }),
            ])
        case ("instructions", "count"):
            return integer(0, Int64(maximumListRows))
        case ("read-bytes", "count"):
            return integer(0, Int64(maximumReadBytes))
        case ("make-array", "count"):
            return integer(1, Int64(DataShapeOverride.maxElementCount))
        case ("make-alignment", "boundary"):
            var boundaries: [ScriptValue] = []
            var value: Int64 = 2
            let maximum = Int64(DataShapeOverride.maxAlignment)
            while value <= maximum {
                boundaries.append(.int(value))
                // Avoid overflow even if the underlying limit changes later.
                guard value <= maximum / 2 else { break }
                value *= 2
            }
            return .object(["type": .string("integer"), "enum": .array(boundaries)])
        case ("make-string", "length"):
            return integer(1, min(Int64(maximumReadBytes), Int64(DataShapeOverride.maxStringLength)))
        case ("make-data", "isData"), ("make-procedure", "isProcedure"),
             ("make-undefined", "isUndefined"), ("patch-bytes", "nop"),
             ("set-signature", "isNoReturn"):
            return boolean
        case ("set-signature", "returnType"):
            return .object(["type": .array([.string("string"), .string("null")])])
        case ("set-signature", "args"):
            return .object([
                "type": .array([.string("array"), .string("null")]),
                "maxItems": .int(Int64(maximumContainerMembers)),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object(["name": string, "type": string]),
                    "required": .array([.string("type")]),
                ]),
            ])
        case ("set-signature", "variadicState"):
            return .object([
                "type": .string("string"),
                "enum": .array(["unspecified", "fixed", "variadic"].map(ScriptValue.string)),
            ])
        case ("set-signature", "noReturnState"):
            return .object([
                "type": .string("string"),
                "enum": .array(["unspecified", "returns", "noReturn"].map(ScriptValue.string)),
            ])
        case ("define-type", "fields"):
            return .object([
                "type": .string("array"),
                "maxItems": .int(Int64(maximumContainerMembers)),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object(["name": string, "type": string]),
                ]),
            ])
        case (_, "address"), (_, "from"), (_, "to"):
            return .object([
                "anyOf": .array([string, integer(0, Int64.max)]),
                "description": .string("Unsigned address. Prefer a hexadecimal string to preserve all 64 bits."),
            ])
        case ("rebase-segment", "delta"):
            return .object(["anyOf": .array([string, integer(Int64.min, Int64.max)])])
        case ("search", "query"):
            return .object([
                "type": .string("string"),
                "description": .string(
                    "Text, regular expression or hex pattern; at most \(maximumSearchQueryBytes) UTF-8 bytes after trimming. A longer query, or an invalid regular expression, returns {error: \"invalidPattern\", detail}."
                ),
            ])
        case (_, WorkspaceScriptingAPI.imageSlotFilterArgument):
            // DEF-A04: row filter for search / callers / callees / xrefs; every row carries `imageSlot`.
            return .object([
                "anyOf": .array([integer(0, Int64(Int32.max)), string]),
                "description": .string(
                    "Restrict the rows to one loaded image: a slot index or an image-owner ID (UUID). Omit to search every image (search) or read the primary image (callers, callees, xrefs). Every row reports the `imageSlot` that produced it."
                ),
            ])
        case (_, WorkspaceScriptingAPI.imageSelectorArgument):
            // MS-19: optional; omitted means the primary image (never the focused image).
            return .object([
                "anyOf": .array([integer(0, Int64(Int32.max)), string]),
                "description": .string(
                    "Image to read: a slot index (0 is the primary image) or an image-owner ID (UUID). Omit for the primary image."
                ),
            ])
        case ("recover-struct-candidate", "parameter"), ("accept-struct-candidate", "parameter"):
            return integer(0, 7)
        case ("accept-struct-candidate", "choices"):
            return .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object(["offset": .object(["type": .string("integer")]),
                                           "width": .object(["type": .string("integer")])]),
                    "required": .array([.string("offset"), .string("width")]),
                    "additionalProperties": .bool(false),
                ]),
            ])
        default:
            return string
        }
    }

    static func scriptSteps(from script: ScriptValue) throws -> [ScriptStep] {
        guard case .array(let values) = script, values.count <= maximumScriptSteps else {
            throw HeadlessAutomationAuthorityError.invalidScript
        }
        return try values.map { value in
            guard case .object(let fields) = value,
                  Set(fields.keys).isSubset(of: ["command", "arguments"]),
                  let command = fields["command"]?.stringValue,
                  !command.isEmpty else {
                throw HeadlessAutomationAuthorityError.invalidScript
            }
            let arguments: ScriptValue
            switch fields["arguments"] {
            case .none, .some(.null):
                arguments = .object([:])
            case .some(let value):
                guard case .object = value else {
                    throw HeadlessAutomationAuthorityError.invalidScript
                }
                arguments = value
            }
            try validate(command: command, arguments: arguments)
            return ScriptStep(command: command, arguments: arguments)
        }
    }

    static func validate(command: String, arguments: ScriptValue) throws {
        guard admits(command),
              let commandInfo = availableCommands.first(where: { $0.name == command }),
              case .object(let fields) = arguments,
              Set(fields.keys).isSubset(of: Set(commandInfo.arguments)) else {
            throw admits(command)
                ? HeadlessAutomationAuthorityError.invalidArguments
                : HeadlessAutomationAuthorityError.unavailableCommand
        }
        try validateValue(arguments, depth: 0)
        for key in [WorkspaceScriptingAPI.imageSelectorArgument, WorkspaceScriptingAPI.imageSlotFilterArgument] {
            guard let image = fields[key] else { continue }
            // Shape only; membership is checked against the workspace by the command, whose
            // typed error names the valid slots.
            switch image {
            case .int(let slot) where (0...Int64(Int32.max)).contains(slot): break
            case .string(let selector) where selector.utf8.count <= 64: break
            default: throw HeadlessAutomationAuthorityError.invalidArguments
            }
        }
        if NavigatorMCPCommands.handles(command) {
            try NavigatorMCPCommands.validate(command: command, fields: fields)
            return
        }

        switch command {
        case "read-evidence":
            _ = try WorkspaceScriptingAPI.readEvidenceOperation(arguments)
        case "functions", "symbols", "strings", "imports", "exports", "sections", "relocations":
            try validateOptionalInteger(fields["limit"], range: 0...Int64(maximumListRows))
        case "list-image-types":
            try validateOptionalInteger(fields["limit"], range: 0...Int64(maximumListRows))
            if let kind = fields["kind"], kind.stringValue.flatMap(TypeAtlasKind.init(rawValue:)) == nil {
                throw HeadlessAutomationAuthorityError.invalidArguments
            }
        case "instructions":
            try validateOptionalInteger(fields["count"], range: 0...Int64(maximumListRows))
        case "read-bytes":
            try validateOptionalInteger(fields["count"], range: 0...Int64(maximumReadBytes))
        case "make-string":
            if let length = fields["length"] {
                try validateOptionalInteger(length, range: 1...Int64(maximumReadBytes))
            }
        case "make-array":
            try validateOptionalInteger(fields["count"], range: 1...Int64(DataShapeOverride.maxElementCount))
        case "make-alignment":
            try validateOptionalInteger(fields["boundary"], range: 2...Int64(DataShapeOverride.maxAlignment))
        case "rebase-segment":
            if let delta = fields["delta"] {
                switch delta {
                case .int, .string: break
                default: throw HeadlessAutomationAuthorityError.invalidArguments
                }
            }
        case "make-data":
            try validateOptionalBool(fields["isData"])
        case "make-procedure":
            try validateOptionalBool(fields["isProcedure"])
        case "make-undefined":
            try validateOptionalBool(fields["isUndefined"])
        case "patch-bytes":
            try validateOptionalBool(fields["nop"])
        case "recover-struct-candidate":
            try validateOptionalInteger(fields["parameter"], range: 0...7)
        case "accept-struct-candidate":
            try validateOptionalInteger(fields["parameter"], range: 0...7)
            guard fields["candidate"]?.stringValue.map({ $0.utf8.count <= 128 }) == true,
                  fields["name"]?.stringValue.map({ $0.utf8.count <= 256 }) == true,
                  fields["local"].map({ value in
                      value.stringValue.flatMap(MacIRStackStorage.entryRange(forAuthoringKey:)) != nil
                  }) ?? true else {
                throw HeadlessAutomationAuthorityError.invalidArguments
            }
            if let choices = fields["choices"] {
                guard let list = choices.arrayValue, list.count <= 256, list.allSatisfy({ choice in
                    guard case .object(let entry) = choice, Set(entry.keys) == ["offset", "width"] else { return false }
                    return entry["offset"]?.intValue != nil && entry["width"]?.intValue != nil
                }) else { throw HeadlessAutomationAuthorityError.invalidArguments }
            }
        case "set-stack-local":
            guard let local = fields["local"]?.stringValue,
                  MacIRStackStorage.entryRange(forAuthoringKey: local) != nil,
                  fields["name"] != nil || fields["type"] != nil,
                  [fields["name"], fields["type"]].allSatisfy({ value in
                      value == nil || value?.stringValue.map { $0.utf8.count <= 1_024 } == true
                  }) else {
                throw HeadlessAutomationAuthorityError.invalidArguments
            }
        case "open-workspace", "save-workspace":
            // HOP-6: the only path-bearing headless tools; the path names a .mscope package.
            if let path = fields["path"], path.stringValue.map({ $0.utf8.count <= 4_096 }) != true {
                throw HeadlessAutomationAuthorityError.invalidArguments
            }
        default:
            break
        }
    }

    static func execute(
        command: String,
        arguments: ScriptValue,
        api: WorkspaceScriptingAPI,
        proposingPrincipal: Phase2Principal = .human
    ) throws -> ScriptValue {
        try validate(command: command, arguments: arguments)
        if NavigatorMCPCommands.handles(command) {
            return try NavigatorMCPCommands.execute(command: command, arguments: arguments, surface: .live(api.store))
        }
        if let refusal = searchRefusal(command: command, arguments: arguments) { return refusal }
        guard command == "commands" else {
            return try api.execute(command, arguments: arguments, proposingPrincipal: proposingPrincipal)
        }
        return .array(availableCommands.map { info in
            .object([
                "name": .string(info.name),
                "summary": .string(info.summary),
                "mutates": .bool(info.mutates),
                "arguments": .array(info.arguments.map(ScriptValue.string)),
            ])
        })
    }

    /// Default async transport uses the same closed command/argument authority and principal.
    /// The catalog command retains the headless filtered catalog rather than exposing API-only tools.
    static func executeAsync(
        command: String,
        arguments: ScriptValue,
        api: WorkspaceScriptingAPI,
        proposingPrincipal: Phase2Principal = .human
    ) async throws -> ScriptValue {
        try validate(command: command, arguments: arguments)
        if NavigatorMCPCommands.handles(command) {
            return try await NavigatorMCPCommands.executeAsync(command: command, arguments: arguments, surface: .live(api.store))
        }
        if let refusal = searchRefusal(command: command, arguments: arguments) { return refusal }
        if command == "commands" {
            return try execute(command: command, arguments: arguments, api: api,
                proposingPrincipal: proposingPrincipal)
        }
        return try await api.executeAsync(command, arguments: arguments,
            proposingPrincipal: proposingPrincipal)
    }

    /// Typed refusals for `search` that must never read as an empty result (DEF-A03, DEF-A09).
    /// Returned as an ordinary result value `{error, detail}` after `validate`, so inline, async
    /// and attached transports answer identically and the engine's own cap is never reached:
    /// - a query over `maximumSearchQueryBytes` (measured on the trimmed query, as the engine
    ///   does) is `invalidPattern` with detail `tooLong`;
    /// - a regex-mode query that does not compile is `invalidPattern` with the compiler's message.
    /// Text and hex modes are unchanged: an unparseable hex pattern still searches to no rows.
    static func searchRefusal(command: String, arguments: ScriptValue) -> ScriptValue? {
        guard command == "search", case .object(let fields) = arguments,
              let query = fields["query"]?.stringValue else { return nil }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.utf8.count <= maximumSearchQueryBytes else {
            return invalidPatternRefusal(detail: "tooLong")
        }
        let mode = fields["mode"]?.stringValue.flatMap(BinarySearchMode.init(rawValue:))
        guard mode == .regex, let message = BinarySearchService().validate(query: needle, mode: .regex) else {
            return nil
        }
        return invalidPatternRefusal(detail: message)
    }

    private static func invalidPatternRefusal(detail: String) -> ScriptValue {
        .object(["error": .string("invalidPattern"), "detail": .string(detail)])
    }

    private static func validateOptionalInteger(
        _ value: ScriptValue?, range: ClosedRange<Int64>
    ) throws {
        guard let value else { return }
        guard case .int(let integer) = value, range.contains(integer) else {
            throw HeadlessAutomationAuthorityError.invalidArguments
        }
    }

    private static func validateOptionalBool(_ value: ScriptValue?) throws {
        guard let value else { return }
        guard value.boolValue != nil else {
            throw HeadlessAutomationAuthorityError.invalidArguments
        }
    }

    private static func validateValue(_ value: ScriptValue, depth: Int) throws {
        guard depth <= 16 else { throw HeadlessAutomationAuthorityError.invalidArguments }
        switch value {
        case .string(let value):
            guard value.utf8.count <= maximumArgumentStringBytes else {
                throw HeadlessAutomationAuthorityError.invalidArguments
            }
        case .array(let values):
            guard values.count <= maximumContainerMembers else {
                throw HeadlessAutomationAuthorityError.invalidArguments
            }
            for value in values { try validateValue(value, depth: depth + 1) }
        case .object(let fields):
            guard fields.count <= maximumContainerMembers,
                  fields.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
                throw HeadlessAutomationAuthorityError.invalidArguments
            }
            for value in fields.values { try validateValue(value, depth: depth + 1) }
        case .double(let number):
            guard number.isFinite else {
                throw HeadlessAutomationAuthorityError.invalidArguments
            }
        case .null, .bool, .int:
            break
        }
    }
}

enum HeadlessProtocolIOError: LocalizedError {
    case descriptorFailure
    case writeFailure

    var errorDescription: String? {
        switch self {
        case .descriptorFailure: "Could not isolate the headless protocol output descriptor."
        case .writeFailure: "Could not write the complete headless protocol response."
        }
    }
}

/// Captures the original stdout descriptor, then sends every incidental `print` or library log
/// to `/dev/null`. Protocol bytes are written only through the captured descriptor.
enum HeadlessProtocolIO {
    static func isolateStandardOutput() throws -> FileHandle {
        signal(SIGPIPE, SIG_IGN)
        let replacement = open("/dev/null", O_WRONLY | O_CLOEXEC)
        guard replacement >= 0 else { throw HeadlessProtocolIOError.descriptorFailure }
        defer { close(replacement) }
        return try isolate(outputDescriptor: STDOUT_FILENO, replacingWith: replacement)
    }

    static func isolate(
        outputDescriptor: Int32, replacingWith replacementDescriptor: Int32
    ) throws -> FileHandle {
        let protocolDescriptor = dup(outputDescriptor)
        guard protocolDescriptor >= 0 else { throw HeadlessProtocolIOError.descriptorFailure }
        let descriptorFlags = fcntl(protocolDescriptor, F_GETFD)
        guard descriptorFlags >= 0,
              fcntl(protocolDescriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0,
              dup2(replacementDescriptor, outputDescriptor) >= 0 else {
            close(protocolDescriptor)
            throw HeadlessProtocolIOError.descriptorFailure
        }
        return FileHandle(fileDescriptor: protocolDescriptor, closeOnDealloc: true)
    }

    static func writeLine(_ data: Data, to output: FileHandle) throws {
        try write(data, to: output)
        try write(Data([0x0A]), to: output)
    }

    static func write(_ data: Data, to output: FileHandle) throws {
        var written = 0
        try data.withUnsafeBytes { bytes in
            while written < bytes.count {
                let result = Darwin.write(
                    output.fileDescriptor,
                    bytes.baseAddress?.advanced(by: written),
                    bytes.count - written
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw HeadlessProtocolIOError.writeFailure }
                written += result
            }
        }
    }
}

/// A Model Context Protocol (JSON-RPC 2.0) server over the scripting command surface.
/// The protocol handler is request-in/response-out; `runStdioLoop` is the bounded NDJSON
/// transport. One server instance owns one API/store and one cancellation ledger.
@MainActor
struct MCPServer {
    struct Configuration: Sendable {
        static let production = Configuration(
            maximumInputBytes: 1 * 1_024 * 1_024,
            maximumOutputBytes: 8 * 1_024 * 1_024,
            maximumToolDurationNanoseconds: 30 * 1_000_000_000,
            maximumRememberedCancellations: 1_024
        )

        let maximumInputBytes: Int
        let maximumOutputBytes: Int
        let maximumToolDurationNanoseconds: UInt64
        let maximumRememberedCancellations: Int
        let maximumInFlightRequests: Int

        init(
            maximumInputBytes: Int,
            maximumOutputBytes: Int,
            maximumToolDurationNanoseconds: UInt64,
            maximumRememberedCancellations: Int,
            maximumInFlightRequests: Int = 64
        ) {
            precondition(maximumInputBytes > 0)
            precondition(maximumOutputBytes >= 512)
            precondition(maximumToolDurationNanoseconds > 0)
            precondition(maximumRememberedCancellations > 0)
            precondition(maximumInFlightRequests > 0 && maximumInFlightRequests <= 1_024)
            self.maximumInputBytes = maximumInputBytes
            self.maximumOutputBytes = maximumOutputBytes
            self.maximumToolDurationNanoseconds = maximumToolDurationNanoseconds
            self.maximumRememberedCancellations = maximumRememberedCancellations
            self.maximumInFlightRequests = maximumInFlightRequests
        }
    }

    static let protocolVersion = "2024-11-05"
    static let serverName = "macscope"
    static let serverVersion = "0.1.0"

    let api: WorkspaceScriptingAPI
    private let configuration: Configuration
    private let monotonicNow: @MainActor () -> UInt64
    private let validateWorkspaceIdentity: @MainActor () throws -> Void
    typealias AsyncCommandExecutor = @MainActor @Sendable (String, ScriptValue) async throws -> ScriptValue
    private let asyncCommandExecutor: AsyncCommandExecutor?
    /// When set (MCP attach), the only tools listed and dispatched; others are unavailable.
    private let allowedCommands: Set<String>?
    private let session: SessionState

    init(
        api: WorkspaceScriptingAPI,
        configuration: Configuration = .production,
        monotonicNow: @escaping @MainActor () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        validateWorkspaceIdentity: @escaping @MainActor () throws -> Void = {},
        asyncCommandExecutor: AsyncCommandExecutor? = nil,
        allowedCommands: Set<String>? = nil
    ) {
        self.api = api
        self.asyncCommandExecutor = asyncCommandExecutor
        self.allowedCommands = allowedCommands
        self.configuration = configuration
        self.monotonicNow = monotonicNow
        self.validateWorkspaceIdentity = validateWorkspaceIdentity
        session = SessionState(maximumCancellations: configuration.maximumRememberedCancellations)
    }

    // MARK: - JSON-RPC handling

    /// Handles exactly one decoded JSON-RPC request. A valid notification executes but never
    /// receives a response; an invalid request always receives an Invalid Request response.
    func handle(_ request: ScriptValue) -> ScriptValue? {
        guard case .object(let fields) = request else {
            return error(nil, -32600, "Invalid Request")
        }
        let idIsPresent = fields.keys.contains("id")
        let id = fields["id"]
        guard validResponseID(id, isPresent: idIsPresent) else {
            return error(nil, -32600, "Invalid Request")
        }
        let isNotification = !idIsPresent
        guard fields["jsonrpc"]?.stringValue == "2.0",
              let method = fields["method"]?.stringValue,
              !method.isEmpty,
              method.utf8.count <= 256,
              !method.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return error(id, -32600, "Invalid Request")
        }

        let response: ScriptValue?
        switch method {
        case "initialize":
            guard validObjectParams(fields["params"]) else {
                response = error(id, -32602, "Invalid params")
                break
            }
            response = result(id, initializeResult())
        case "ping":
            guard validObjectParams(fields["params"]) else {
                response = error(id, -32602, "Invalid params")
                break
            }
            response = result(id, .object([:]))
        case "tools/list":
            guard validObjectParams(fields["params"]) else {
                response = error(id, -32602, "Invalid params")
                break
            }
            response = result(id, toolsListResult())
        case "tools/call":
            response = toolsCall(id: id, requestKey: requestKey(id), params: fields["params"])
        case "notifications/cancelled":
            guard isNotification else {
                return error(id, -32600, "Invalid Request")
            }
            recordCancellation(fields["params"])
            return nil
        case let name where name.hasPrefix("notifications/"):
            return isNotification ? nil : error(id, -32601, "Method not found")
        default:
            response = error(id, -32601, "Method not found")
        }
        return isNotification ? nil : response
    }

    /// Strictly parses one message and returns one bounded response, or nil for a valid
    /// notification/blank line.
    func handleMessage(_ data: Data) -> Data? {
        guard !data.allSatisfy(Self.isJSONWhitespace) else { return nil }
        guard data.count <= configuration.maximumInputBytes else {
            return encodeBounded(error(nil, -32700, "Parse error"))
        }
        let request: ScriptValue
        do {
            request = try HeadlessJSON.decode(data, maximumBytes: configuration.maximumInputBytes)
        } catch {
            return encodeBounded(self.error(nil, -32700, "Parse error"))
        }
        guard let response = handle(request) else { return nil }
        return encodeBounded(response)
    }

    func handleLine(_ line: String) -> String? {
        guard let response = handleMessage(Data(line.utf8)) else { return nil }
        return String(data: response, encoding: .utf8)
    }

    /// Bounded newline-delimited JSON transport. Oversized lines are drained through their
    /// delimiter, receive one parse error, and cannot desynchronize the following request.
    func runStdioLoop(
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput
    ) {
        let reader = BoundedLineReader(
            descriptor: input.fileDescriptor,
            maximumLineBytes: configuration.maximumInputBytes
        )
        while true {
            let event: BoundedLineReader.Event
            do {
                event = try reader.next()
            } catch {
                return
            }
            let response: Data?
            switch event {
            case .message(let data):
                response = handleMessage(data)
            case .oversized:
                response = encodeBounded(error(nil, -32700, "Parse error"))
            case .end:
                return
            }
            guard let response else { continue }
            do {
                try HeadlessProtocolIO.writeLine(response, to: output)
            } catch {
                return
            }
        }
    }

    // MARK: - Method results

    private func initializeResult() -> ScriptValue {
        .object([
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": .object(["tools": .object([:])]),
            "serverInfo": .object(["name": .string(Self.serverName), "version": .string(Self.serverVersion)]),
        ])
    }

    private func toolsListResult() -> ScriptValue {
        .object(["tools": .array(HeadlessAutomationAuthority.availableCommands.filter {
            allowedCommands?.contains($0.name) ?? true
        }.map { command in
            return .object([
                "name": .string(command.name),
                "description": .string(command.summary + (command.mutates ? " (mutates the workspace)" : "")),
                "inputSchema": HeadlessAutomationAuthority.inputSchema(for: command),
                "annotations": .object([
                    "readOnlyHint": .bool(!command.mutates),
                    "destructiveHint": .bool(command.mutates),
                ]),
            ])
        })])
    }

    /// The production transport owns cancellation outside MainActor. Commands still
    /// enter the same closed authority, workspace identity and principal boundary.
    func makeRequestSession(output: @escaping @Sendable (Data) async throws -> Void) -> MCPRequestSession {
        MCPRequestSession(configuration: configuration,
            mutatingCommands: Set(HeadlessAutomationAuthority.availableCommands.filter(\.mutates).map(\.name)),
            execute: { data in await handleMessageAsync(data) }, output: output)
    }

    func handleMessageAsync(_ data: Data) async -> Data? {
        guard let request = try? HeadlessJSON.decode(data, maximumBytes: configuration.maximumInputBytes),
              case .object(let fields) = request,
              fields["jsonrpc"]?.stringValue == "2.0",
              fields["method"]?.stringValue == "tools/call",
              validResponseID(fields["id"], isPresent: fields.keys.contains("id")) else {
            return handleMessage(data)
        }
        let response = await toolsCallAsync(id: fields["id"], requestKey: nil, params: fields["params"])
        return fields.keys.contains("id") ? encodeBounded(response) : nil
    }

    /// Blocking reads live on a detached transport task; provider suspension or a busy
    /// MainActor cannot prevent that task from cancelling the exact in-flight operation.
    func runStdioLoopAsync(input: FileHandle = .standardInput,
                           output: FileHandle = .standardOutput) async {
        let writer = MCPResponseWriter(output: output)
        let reader = BoundedLineReader(descriptor: input.fileDescriptor,
                                       maximumLineBytes: configuration.maximumInputBytes)
        let requests = makeRequestSession(output: { data in
            do { try await writer.write(data) }
            catch { reader.stop(); throw error }
        })
        await Task.detached {
            do {
                while true {
                    switch try reader.next() {
                    case .message(let data): await requests.receive(data)
                    case .oversized: await requests.receiveOversized()
                    case .end:
                        await requests.finishInput()
                        return
                    }
                }
            } catch {
                await requests.finishInput()
            }
        }.value
    }

    private func toolsCallAsync(
        id: ScriptValue?, requestKey: RequestKey?, params: ScriptValue?
    ) async -> ScriptValue {
        guard case .some(.object(let fields)) = params,
              Set(fields.keys).isSubset(of: ["name", "arguments", "_meta"]),
              let name = fields["name"]?.stringValue,
              !name.isEmpty,
              name.utf8.count <= 256,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return error(id, -32602, "Invalid params")
        }
        if let metadata = fields["_meta"], case .object = metadata {
            // Metadata is admitted only as an object and is deliberately not forwarded.
        } else if fields["_meta"] != nil {
            return error(id, -32602, "Invalid params")
        }
        let arguments: ScriptValue
        switch fields["arguments"] {
        case .none, .some(.null):
            arguments = .object([:])
        case .some(let value):
            guard case .object = value else { return error(id, -32602, "Invalid params") }
            arguments = value
        }
        if let allowedCommands, !allowedCommands.contains(name) {
            return toolFailure(id, "Tool is unavailable through headless automation.")
        }
        do {
            try HeadlessAutomationAuthority.validate(command: name, arguments: arguments)
        } catch HeadlessAutomationAuthorityError.unavailableCommand {
            return toolFailure(id, "Tool is unavailable through headless automation.")
        } catch {
            return self.error(id, -32602, "Invalid params")
        }

        if Task.isCancelled {
            return error(id, -32800, "Request cancelled")
        }
        let started = monotonicNow()
        do {
            try validateWorkspaceIdentity()
        } catch {
            return toolFailure(id, "Workspace identity validation failed.")
        }

        let output: ScriptValue?
        var failureMessage = "Tool call failed."
        do {
            try Task.checkCancellation()
            if let asyncCommandExecutor {
                output = try await asyncCommandExecutor(name, arguments)
            } else {
                output = try await HeadlessAutomationAuthority.executeAsync(
                    command: name, arguments: arguments, api: api, proposingPrincipal: .mcp
                )
            }
        } catch {
            // Scripting errors are user-facing descriptions ("no function named 'x'"); surface them
            // so an agent can correct its call instead of retrying blind.
            output = nil
            if let described = (error as? LocalizedError)?.errorDescription, !described.isEmpty {
                failureMessage = "Tool call failed: " + String(described.prefix(1_024))
            }
        }
        do {
            try validateWorkspaceIdentity()
        } catch {
            return toolFailure(id, "Workspace identity validation failed.")
        }
        // A mutation that already committed is reported as committed: answering "cancelled" or
        // "deadline exceeded" for applied work invites a retry that applies it twice.
        let committedMutation = output != nil && HeadlessAutomationAuthority.availableCommands
            .first(where: { $0.name == name })?.mutates != false
        if Task.isCancelled, !committedMutation {
            return error(id, -32800, "Request cancelled")
        }
        let finished = monotonicNow()
        let elapsed = finished >= started ? finished - started : UInt64.max
        guard elapsed <= configuration.maximumToolDurationNanoseconds || committedMutation else {
            return error(id, -32001, "Request deadline exceeded")
        }

        guard let output else {
            return toolFailure(id, failureMessage)
        }
        // The async binding encodes off the MainActor: a large (bounded) result never blocks the
        // UI while it is serialized (DP09-2 N3).
        let limit = configuration.maximumOutputBytes / 2
        let encoded: String? = await Task.detached(priority: Task.currentPriority) {
            guard let data = try? output.jsonData(), data.count <= limit else { return nil }
            return String(data: data, encoding: .utf8)
        }.value
        guard let text = encoded else {
            return error(id, -32603, "Response exceeds limit")
        }
        return result(id, .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "isError": .bool(false),
        ]))
    }

    private func toolsCall(
        id: ScriptValue?, requestKey: RequestKey?, params: ScriptValue?
    ) -> ScriptValue {
        guard case .some(.object(let fields)) = params,
              Set(fields.keys).isSubset(of: ["name", "arguments", "_meta"]),
              let name = fields["name"]?.stringValue,
              !name.isEmpty,
              name.utf8.count <= 256,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return error(id, -32602, "Invalid params")
        }
        if let metadata = fields["_meta"], case .object = metadata {
            // Metadata is admitted only as an object and is deliberately not forwarded.
        } else if fields["_meta"] != nil {
            return error(id, -32602, "Invalid params")
        }
        let arguments: ScriptValue
        switch fields["arguments"] {
        case .none, .some(.null):
            arguments = .object([:])
        case .some(let value):
            guard case .object = value else { return error(id, -32602, "Invalid params") }
            arguments = value
        }
        if let allowedCommands, !allowedCommands.contains(name) {
            return toolFailure(id, "Tool is unavailable through headless automation.")
        }
        do {
            try HeadlessAutomationAuthority.validate(command: name, arguments: arguments)
        } catch HeadlessAutomationAuthorityError.unavailableCommand {
            return toolFailure(id, "Tool is unavailable through headless automation.")
        } catch {
            return self.error(id, -32602, "Invalid params")
        }

        if let requestKey, session.consumeCancellation(requestKey) {
            return error(id, -32800, "Request cancelled")
        }
        let started = monotonicNow()
        do {
            try validateWorkspaceIdentity()
        } catch {
            return toolFailure(id, "Workspace identity validation failed.")
        }

        let output: ScriptValue?
        var failureMessage = "Tool call failed."
        do {
            output = try HeadlessAutomationAuthority.execute(
                command: name, arguments: arguments, api: api, proposingPrincipal: .mcp
            )
        } catch {
            // Scripting errors are user-facing descriptions ("no function named 'x'"); surface them
            // so an agent can correct its call instead of retrying blind.
            output = nil
            if let described = (error as? LocalizedError)?.errorDescription, !described.isEmpty {
                failureMessage = "Tool call failed: " + String(described.prefix(1_024))
            }
        }
        do {
            try validateWorkspaceIdentity()
        } catch {
            return toolFailure(id, "Workspace identity validation failed.")
        }
        // A mutation that already committed is reported as committed: answering "cancelled" or
        // "deadline exceeded" for applied work invites a retry that applies it twice.
        let committedMutation = output != nil && HeadlessAutomationAuthority.availableCommands
            .first(where: { $0.name == name })?.mutates != false
        if let requestKey, session.consumeCancellation(requestKey), !committedMutation {
            return error(id, -32800, "Request cancelled")
        }
        let finished = monotonicNow()
        let elapsed = finished >= started ? finished - started : UInt64.max
        guard elapsed <= configuration.maximumToolDurationNanoseconds || committedMutation else {
            return error(id, -32001, "Request deadline exceeded")
        }

        guard let output else {
            return toolFailure(id, failureMessage)
        }
        guard let outputData = try? output.jsonData(),
              outputData.count <= configuration.maximumOutputBytes / 2,
              let text = String(data: outputData, encoding: .utf8) else {
            return error(id, -32603, "Response exceeds limit")
        }
        return result(id, .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "isError": .bool(false),
        ]))
    }

    private func toolFailure(_ id: ScriptValue?, _ message: String) -> ScriptValue {
        result(id, .object([
            "content": .array([.object(["type": .string("text"), "text": .string(message)])]),
            "isError": .bool(true),
        ]))
    }

    private func recordCancellation(_ params: ScriptValue?) {
        guard case .some(.object(let fields)) = params,
              Set(fields.keys).isSubset(of: ["requestId", "reason"]),
              let key = requestKey(fields["requestId"]) else { return }
        session.recordCancellation(key)
    }

    // MARK: - Envelopes and encoding

    private func result(_ id: ScriptValue?, _ value: ScriptValue) -> ScriptValue {
        .object(["jsonrpc": .string("2.0"), "id": id ?? .null, "result": value])
    }

    private func error(_ id: ScriptValue?, _ code: Int, _ message: String) -> ScriptValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id ?? .null,
            "error": .object(["code": .int(Int64(code)), "message": .string(message)]),
        ])
    }

    private func encodeBounded(_ response: ScriptValue) -> Data {
        if let data = try? response.jsonData(), data.count <= configuration.maximumOutputBytes {
            return data
        }
        let id = response["id"] ?? .null
        let fallback = error(id, -32603, "Response exceeds limit")
        if let data = try? fallback.jsonData(), data.count <= configuration.maximumOutputBytes {
            return data
        }
        return Data(#"{"error":{"code":-32603,"message":"Internal error"},"id":null,"jsonrpc":"2.0"}"#.utf8)
    }

    private func validObjectParams(_ params: ScriptValue?) -> Bool {
        guard let params else { return true }
        if case .object = params { return true }
        return false
    }

    private func validResponseID(_ id: ScriptValue?, isPresent: Bool) -> Bool {
        guard isPresent else { return true }
        switch id {
        case .some(.null), .some(.int):
            return true
        case .some(.double(let value)):
            return value.isFinite
        case .some(.string(let value)):
            return value.utf8.count <= 256
                && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        default:
            return false
        }
    }

    private func requestKey(_ id: ScriptValue?) -> RequestKey? {
        switch id {
        case .some(.int(let value)): return .integer(value)
        case .some(.double(let value)) where value.isFinite: return .number(value)
        case .some(.string(let value)) where value.utf8.count <= 256: return .string(value)
        default: return nil
        }
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private enum RequestKey: Hashable {
        case integer(Int64)
        case number(Double)
        case string(String)
    }

    private final class SessionState {
        private let maximumCancellations: Int
        private var cancelled: Set<RequestKey> = []
        private var cancellationOrder: [RequestKey] = []

        init(maximumCancellations: Int) {
            self.maximumCancellations = maximumCancellations
        }

        func recordCancellation(_ key: RequestKey) {
            guard cancelled.insert(key).inserted else { return }
            cancellationOrder.append(key)
            if cancellationOrder.count > maximumCancellations {
                cancelled.remove(cancellationOrder.removeFirst())
            }
        }

        func consumeCancellation(_ key: RequestKey) -> Bool {
            guard cancelled.remove(key) != nil else { return false }
            cancellationOrder.removeAll { $0 == key }
            return true
        }
    }

    private final class BoundedLineReader: @unchecked Sendable {
        enum Event: Sendable {
            case message(Data)
            case oversized
            case end
        }

        private let descriptor: Int32
        private let maximumLineBytes: Int
        private var storage = Data()
        private var discardingOversizedLine = false
        private var reachedEOF = false
        private let stopLock = NSLock()
        private var stopped = false

        func stop() { stopLock.withLock { stopped = true } }
        private var isStopped: Bool { stopLock.withLock { stopped } }

        init(descriptor: Int32, maximumLineBytes: Int) {
            self.descriptor = descriptor
            self.maximumLineBytes = maximumLineBytes
        }

        func next() throws -> Event {
            while true {
                if isStopped { return .end }
                if discardingOversizedLine {
                    if let newline = storage.firstIndex(of: 0x0A) {
                        storage.removeSubrange(storage.startIndex...newline)
                        discardingOversizedLine = false
                        return .oversized
                    }
                    storage.removeAll(keepingCapacity: true)
                    if reachedEOF {
                        discardingOversizedLine = false
                        return .oversized
                    }
                    try readChunk()
                    continue
                }

                if let newline = storage.firstIndex(of: 0x0A) {
                    let line = Data(storage[..<newline])
                    storage.removeSubrange(storage.startIndex...newline)
                    return line.count <= maximumLineBytes ? .message(line) : .oversized
                }
                if storage.count > maximumLineBytes {
                    discardingOversizedLine = true
                    continue
                }
                if reachedEOF {
                    guard !storage.isEmpty else { return .end }
                    let line = storage
                    storage.removeAll()
                    return line.count <= maximumLineBytes ? .message(line) : .oversized
                }
                try readChunk()
            }
        }

        private func readChunk() throws {
            var bytes = [UInt8](repeating: 0, count: 16 * 1_024)
            while true {
                if isStopped { reachedEOF = true; return }
                // Poll, rather than close a descriptor underneath a read, so a
                // failed output unblocks an idle client without FD-reuse races.
                var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&descriptorState, 1, 25)
                if ready < 0, errno == EINTR { continue }
                guard ready >= 0 else { throw HeadlessProtocolIOError.descriptorFailure }
                if ready == 0 { continue }
                let count = bytes.withUnsafeMutableBytes { buffer in
                    Darwin.read(descriptor, buffer.baseAddress, buffer.count)
                }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw HeadlessProtocolIOError.descriptorFailure }
                if count == 0 {
                    reachedEOF = true
                } else {
                    storage.append(contentsOf: bytes.prefix(count))
                }
                return
            }
        }
    }
}
