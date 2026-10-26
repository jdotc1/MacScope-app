import Foundation

/// Errors surfaced while translating an AppleScript command into a
/// `WorkspaceScriptingAPI` call. Distinct from `ScriptingError` because the rejection
/// happens *before* dispatch — these describe why an AppleScript event could not be
/// turned into a safe command at all.
enum AppleScriptTranslationError: LocalizedError, Equatable {
    /// The AppleScript command name is not in the exposed safe subset.
    case unsupportedCommand(String)
    /// A required AppleScript parameter was absent.
    case missingParameter(String)
    /// A parameter was present but the wrong shape (e.g. an address that is not a
    /// number/hex string, or an empty required name).
    case invalidParameter(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedCommand(name):
            return "AppleScript command '\(name)' is not exposed by MacScope."
        case let .missingParameter(name):
            return "AppleScript command is missing required parameter '\(name)'."
        case let .invalidParameter(detail):
            return "Invalid AppleScript parameter: \(detail)."
        }
    }
}

/// The result of translating one AppleScript event: the `WorkspaceScriptingAPI` command
/// identifier plus its JSON arguments, ready to hand to `WorkspaceScriptingAPI.execute`.
struct TranslatedScriptCommand: Equatable {
    var command: String
    var arguments: ScriptValue
}

/// Translates AppleScript commands (a command name + a parameter dictionary, as an
/// `NSScriptCommand` would supply) into `WorkspaceScriptingAPI` command JSON.
///
/// This is the THIN, SAFE bridge the task calls for: it exposes only a read-plus-
/// already-undoable-authoring subset of the full command surface, validates every
/// input, and rejects anything outside the allowlist. Live `NSScriptCommand`
/// scriptability (driven by the shipped `MacScope.sdef`) is a thin shell that builds
/// the parameter dictionary from the Apple event and calls `translate`; this layer is
/// kept pure so the whole mapping is unit-testable without a running app or an Apple
/// event dispatcher.
///
/// The *live* AppleScript wiring now ships: a single `NSScriptCommand` subclass,
/// `MacScopeScriptCommand`, is bound to every verb by `MacScope.sdef`. It reads
/// `evaluatedArguments`, runs them through `AppleScriptCommandRunner` (which calls
/// `translate`), and dispatches the result on the main-actor `WorkspaceScriptingAPI`
/// for the front document, resolved via `ScriptingHost.activeAPI` (set from
/// `MacScopeApp`'s `.onAppear`). This translator stays pure so the mapping remains
/// unit-testable without a running app or an Apple-event dispatcher; only that final
/// live Apple-event dispatch is verified by hand. See `MacScope.sdef` for the surface.
enum AppleScriptCommandTranslator {

    /// The exposed AppleScript verbs. Each maps to exactly one `WorkspaceScriptingAPI`
    /// command. Only SAFE commands appear: every read, plus the authoring mutations that
    /// already go through the store's *undoable* path (rename, set comment, set tag). No
    /// destructive/structural verb (mark-as-data, make-procedure, define-type, …) is
    /// exposed to AppleScript — those re-drive analysis and are reserved for the richer
    /// in-process / MCP bindings.
    enum Verb: String, CaseIterable {
        // Reads
        case getInfo = "get info"
        case getFunctions = "get functions"
        case getInstructions = "get instructions"
        case getNameAt = "get name at"
        case getComment = "get comment"
        // Undoable authoring
        case setName = "set name"
        case setComment = "set comment"
        case setTag = "set tag"
        // Generic escape hatch: run one already-allowlisted scripting command by id.
        case runCommand = "run command"
    }

    /// The set of `WorkspaceScriptingAPI` command ids reachable through the generic
    /// `run command` verb. A strict allowlist — NOT every registry command — so live
    /// AppleScript can never reach a structural/destructive op even via the escape
    /// hatch. Mirrors the per-verb exposure above plus the safe read-only navigation
    /// helpers.
    static let allowlistedCommandIDs: Set<String> = [
        "commands", "info",
        "functions", "instructions", "symbols", "strings",
        "imports", "exports", "sections",
        "name-at", "resolve-symbol",
        "xrefs", "callers", "callees", "basic-blocks",
        "rename", "set-comment", "set-tag",
    ]

    /// Translates a command name + parameter dictionary into a `WorkspaceScriptingAPI`
    /// call. Throws `AppleScriptTranslationError` for an unknown verb, a missing/invalid
    /// parameter, or a `run command` that names a non-allowlisted command.
    ///
    /// - Parameters:
    ///   - name: the AppleScript verb (the `.sdef` command name, e.g. `"set name"`).
    ///   - parameters: the evaluated Apple-event parameters as JSON values, keyed by the
    ///     `.sdef` parameter name (e.g. `["at": .int(0x1000), "to": .string("_main")]`).
    static func translate(command name: String, parameters: [String: ScriptValue]) throws -> TranslatedScriptCommand {
        guard let verb = Verb(rawValue: name) else {
            throw AppleScriptTranslationError.unsupportedCommand(name)
        }
        switch verb {
        case .getInfo:
            return TranslatedScriptCommand(command: "info", arguments: .object([:]))

        case .getFunctions:
            var args: [String: ScriptValue] = [:]
            if let limit = parameters["limit"] {
                args["limit"] = try positiveInt(limit, name: "limit")
            }
            return TranslatedScriptCommand(command: "functions", arguments: .object(args))

        case .getInstructions:
            // Either a function name OR an address; mirrors the underlying command.
            var args: [String: ScriptValue] = [:]
            if let function = parameters["function"] {
                args["function"] = .string(try nonEmptyString(function, name: "function"))
            } else if let address = parameters["at"] {
                args["address"] = .string(try addressString(address, name: "at"))
                if let count = parameters["count"] {
                    args["count"] = try positiveInt(count, name: "count")
                }
            } else {
                throw AppleScriptTranslationError.missingParameter("function or at")
            }
            return TranslatedScriptCommand(command: "instructions", arguments: .object(args))

        case .getNameAt:
            let address = try requireAddress(parameters, "at")
            return TranslatedScriptCommand(command: "name-at", arguments: .object(["address": address]))

        case .getComment:
            // There is no dedicated read-comment command; the comment rides the
            // `instructions` result. Surface it via a single-instruction `instructions`
            // read at the address so AppleScript can fetch it without a new API command.
            let address = try requireAddress(parameters, "at")
            return TranslatedScriptCommand(
                command: "instructions",
                arguments: .object(["address": address, "count": .int(1)])
            )

        case .setName:
            let address = try requireAddress(parameters, "at")
            let name = try nonEmptyString(require(parameters, "to"), name: "to")
            return TranslatedScriptCommand(
                command: "rename",
                arguments: .object(["address": address, "name": .string(name)])
            )

        case .setComment:
            let address = try requireAddress(parameters, "at")
            // An empty comment is allowed here — it clears the comment (the underlying
            // command treats "" as a clear). So only require presence, not non-empty.
            let comment = try string(require(parameters, "to"), name: "to")
            return TranslatedScriptCommand(
                command: "set-comment",
                arguments: .object(["address": address, "comment": .string(comment)])
            )

        case .setTag:
            let address = try requireAddress(parameters, "at")
            let tag = try string(require(parameters, "to"), name: "to")
            return TranslatedScriptCommand(
                command: "set-tag",
                arguments: .object(["address": address, "tag": .string(tag)])
            )

        case .runCommand:
            let id = try nonEmptyString(require(parameters, "command"), name: "command")
            guard allowlistedCommandIDs.contains(id) else {
                throw AppleScriptTranslationError.invalidParameter(
                    "command '\(id)' is not allowed via AppleScript"
                )
            }
            // Pass through caller-supplied arguments verbatim, but only as a JSON object.
            let arguments: ScriptValue
            switch parameters["arguments"] {
            case .none, .some(.null):
                arguments = .object([:])
            case let .some(value):
                guard case .object = value else {
                    throw AppleScriptTranslationError.invalidParameter("'arguments' must be a record/object")
                }
                arguments = value
            }
            return TranslatedScriptCommand(command: id, arguments: arguments)
        }
    }

    // MARK: - Parameter validation helpers

    private static func require(_ parameters: [String: ScriptValue], _ key: String) throws -> ScriptValue {
        guard let value = parameters[key] else {
            throw AppleScriptTranslationError.missingParameter(key)
        }
        return value
    }

    private static func requireAddress(_ parameters: [String: ScriptValue], _ key: String) throws -> ScriptValue {
        .string(try addressString(require(parameters, key), name: key))
    }

    /// Normalizes an address parameter to a canonical `"0x…"` string so the downstream
    /// command sees a consistent shape regardless of whether AppleScript supplied an
    /// integer or a string. Rejects anything that is not a valid address.
    private static func addressString(_ value: ScriptValue, name: String) throws -> String {
        guard let address = value.addressValue else {
            throw AppleScriptTranslationError.invalidParameter("\(name) must be an address (integer or 0x… string)")
        }
        return ScriptValue.hex(address).stringValue ?? "0x0"
    }

    private static func string(_ value: ScriptValue, name: String) throws -> String {
        guard let text = value.stringValue else {
            throw AppleScriptTranslationError.invalidParameter("\(name) must be text")
        }
        return text
    }

    private static func nonEmptyString(_ value: ScriptValue, name: String) throws -> String {
        let text = try string(value, name: name)
        guard !text.isEmpty else {
            throw AppleScriptTranslationError.invalidParameter("\(name) must not be empty")
        }
        return text
    }

    private static func positiveInt(_ value: ScriptValue, name: String) throws -> ScriptValue {
        guard let int = value.intValue, int >= 0 else {
            throw AppleScriptTranslationError.invalidParameter("\(name) must be a non-negative integer")
        }
        return .int(int)
    }
}
