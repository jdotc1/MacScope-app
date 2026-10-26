import Foundation

/// Authoring-layer value types for the Tier-2 debugger surfaces: conditional
/// breakpoint editing, register writes, and memory-address reads.
///
/// These mirror the existing debugger model idiom (pure, `Equatable`, parsing /
/// validation expressed as static factories that return either a normalized
/// request or a human-readable rejection reason). Keeping the parsing here makes
/// `DebuggerPanelViewModel` thin and leaves every non-UI decision unit-testable
/// without touching SwiftUI or a live LLDB transport.

// MARK: - Conditional breakpoint editing

/// A normalized edit to a single breakpoint's condition expression and
/// ignore/hit-count metadata. Reconciled into an existing breakpoint, this
/// preserves the address / enabled-state / accumulated hit-count plumbing the
/// gutter bridge already relies on while overlaying the authored condition and
/// ignore count.
struct DebuggerBreakpointEdit: Equatable {
    var address: UInt64
    /// Trimmed condition expression, or `nil` when the author cleared the field.
    var condition: String?
    var ignoreCount: Int

    /// Parses raw author input (a free-form condition string + an ignore-count
    /// text field) for a given breakpoint address. Returns `.failure` with a
    /// human-readable reason when the inputs cannot form a valid edit; the view
    /// model surfaces that reason verbatim.
    static func parse(
        address: UInt64,
        conditionText: String,
        ignoreCountText: String
    ) -> Result<DebuggerBreakpointEdit, DebuggerAuthoringParseError> {
        let trimmedCondition = conditionText.trimmingCharacters(in: .whitespacesAndNewlines)
        if DebuggerAuthoringValidation.containsUnsupportedControlCharacters(trimmedCondition) {
            return .failure(.invalid("Breakpoint condition contains unsupported control characters."))
        }

        let normalizedCondition = trimmedCondition.isEmpty ? nil : trimmedCondition

        let trimmedIgnore = ignoreCountText.trimmingCharacters(in: .whitespacesAndNewlines)
        let ignoreCount: Int
        if trimmedIgnore.isEmpty {
            ignoreCount = 0
        } else if let parsed = Int(trimmedIgnore), parsed >= 0, parsed <= Int(UInt32.max) {
            // LLDB's --ignore-count is a uint32; a larger value would be silently
            // truncated by LLDB (firing the breakpoint far sooner than intended), so
            // reject it here rather than passing through a misleading count.
            ignoreCount = parsed
        } else {
            return .failure(.invalid("Ignore count must be a whole number from 0 to \(UInt32.max)."))
        }

        return .success(
            DebuggerBreakpointEdit(
                address: address,
                condition: normalizedCondition,
                ignoreCount: ignoreCount
            )
        )
    }

    /// Applies this edit onto an existing breakpoint, preserving its enabled
    /// state and accumulated hit count.
    func applied(to breakpoint: DebuggerBreakpoint) -> DebuggerBreakpoint {
        DebuggerBreakpoint(
            address: address,
            isEnabled: breakpoint.isEnabled,
            condition: condition,
            hitCount: breakpoint.hitCount,
            ignoreCount: ignoreCount
        )
    }
}

// MARK: - Register write

/// A normalized request to write `value` into the named register on the stopped
/// target. `name` is a bare register identifier (e.g. `x0`, `pc`); `value` is a
/// hex (`0x...`) or decimal literal accepted by `register write`.
struct DebuggerRegisterWriteRequest: Equatable {
    var name: String
    var value: String

    var displayName: String {
        "\(name) = \(value)"
    }

    static func parse(
        name nameText: String,
        value valueText: String
    ) -> Result<DebuggerRegisterWriteRequest, DebuggerAuthoringParseError> {
        let name = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return .failure(.invalid("Enter a register name before writing."))
        }
        guard DebuggerAuthoringValidation.isValidRegisterName(name) else {
            return .failure(.invalid("Register name \(name) is not a valid identifier."))
        }

        let value = valueText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return .failure(.invalid("Enter a value before writing register \(name)."))
        }
        guard DebuggerAuthoringValidation.isValidRegisterValue(value) else {
            return .failure(.invalid("Register value \(value) must be a hex (0x…) or decimal literal."))
        }

        return .success(DebuggerRegisterWriteRequest(name: name, value: value))
    }
}

// MARK: - Memory read

/// A normalized request to read `byteCount` bytes starting at `address` from the
/// stopped target.
struct DebuggerMemoryReadRequest: Equatable {
    /// Default number of bytes when the author leaves the count field empty.
    static let defaultByteCount = 64
    /// Upper bound matched to the bounded stack-window posture of the live
    /// session so an authored read can never request an unbounded dump.
    static let maximumByteCount = 4096

    var address: UInt64
    var byteCount: Int

    var displayName: String {
        "\(byteCount) byte\(byteCount == 1 ? "" : "s") at \(address.hexAddress)"
    }

    static func parse(
        addressText: String,
        byteCountText: String
    ) -> Result<DebuggerMemoryReadRequest, DebuggerAuthoringParseError> {
        guard let address = DebuggerAuthoringValidation.parseHexAddress(addressText) else {
            return .failure(.invalid("Enter a valid hex address (for example 0x100003f80)."))
        }

        let trimmedCount = byteCountText.trimmingCharacters(in: .whitespacesAndNewlines)
        let byteCount: Int
        if trimmedCount.isEmpty {
            byteCount = defaultByteCount
        } else if let parsed = Int(trimmedCount) {
            guard parsed > 0 else {
                return .failure(.invalid("Byte count must be a positive whole number."))
            }
            guard parsed <= maximumByteCount else {
                return .failure(.invalid("Byte count must not exceed \(maximumByteCount)."))
            }
            byteCount = parsed
        } else {
            return .failure(.invalid("Byte count must be a positive whole number."))
        }

        return .success(DebuggerMemoryReadRequest(address: address, byteCount: byteCount))
    }
}

// MARK: - Memory write

/// A normalized request to write `bytes` starting at `address` on the stopped
/// target. The author types a space-separated sequence of byte literals (each
/// `0x..`-prefixed or a bare 1-2 hex-digit token); parsing here turns that into a
/// validated `[UInt8]` so the LLDB `memory write` command never receives a raw
/// user string. Pure / `Equatable` so the parse is unit-testable without a live
/// transport.
struct DebuggerMemoryWriteRequest: Equatable {
    /// Upper bound matched to the bounded posture of the live session so an
    /// authored write can never push an unbounded blob through the command line.
    static let maximumByteCount = 4096

    var address: UInt64
    var bytes: [UInt8]

    var byteCount: Int { bytes.count }

    var displayName: String {
        "\(byteCount) byte\(byteCount == 1 ? "" : "s") at \(address.hexAddress)"
    }

    /// The space-separated `0x..` byte tokens LLDB's `memory write` expects, in
    /// write order. Each byte is rendered as a fixed two-digit `0x` literal so the
    /// command is unambiguous regardless of how the author typed the input.
    var lldbValueTokens: [String] {
        bytes.map { String(format: "0x%02x", $0) }
    }

    static func parse(
        addressText: String,
        bytesText: String
    ) -> Result<DebuggerMemoryWriteRequest, DebuggerAuthoringParseError> {
        guard let address = DebuggerAuthoringValidation.parseHexAddress(addressText) else {
            return .failure(.invalid("Enter a valid hex address (for example 0x100003f80)."))
        }

        let trimmed = bytesText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.invalid("Enter one or more byte values to write (for example 0x2a 0xff)."))
        }

        // Tokens are separated by any run of whitespace; commas are tolerated so a
        // pasted `0x2a, 0xff` list parses without manual cleanup.
        let tokens = trimmed
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard !tokens.isEmpty else {
            return .failure(.invalid("Enter one or more byte values to write (for example 0x2a 0xff)."))
        }
        guard tokens.count <= maximumByteCount else {
            return .failure(.invalid("Byte count must not exceed \(maximumByteCount)."))
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(tokens.count)
        for token in tokens {
            guard let byte = DebuggerAuthoringValidation.parseHexByte(token) else {
                return .failure(.invalid("Byte value \(token) must be a hex byte from 0x00 to 0xff."))
            }
            bytes.append(byte)
        }

        return .success(DebuggerMemoryWriteRequest(address: address, bytes: bytes))
    }
}

// MARK: - Run to cursor

enum DebuggerRunToCursorRequestError: Error, Equatable, Sendable {
    case invalidObservedStopID
    case inconsistentResolvedAddress
}

/// Complete immutable authority for one checked Run to Cursor operation.
///
/// The workspace-qualified address, exact mapping projection, module instance, process, stop, and
/// inventory revision remain paired until the production controller revalidates them after taking
/// its operation gate. `observedStopID` is carried separately because it is direct LLDB stop
/// evidence and is deliberately not part of workspace correlation.
struct DebuggerRunToCursorRequest: Hashable, Sendable {
    let resolvedAddress: DebuggerResolvedRuntimeAddress
    let observedStopID: UInt32

    init(
        resolvedAddress: DebuggerResolvedRuntimeAddress,
        observedStopID: UInt32
    ) throws {
        guard observedStopID > 0 else {
            throw DebuggerRunToCursorRequestError.invalidObservedStopID
        }
        let key = resolvedAddress.projectionKey
        let instance = resolvedAddress.moduleInstanceID
        guard key.stopCoordinate == instance.stop,
              key.observedPID == instance.processID,
              key.inventoryRevision == instance.inventoryRevision,
              resolvedAddress.workspaceCoordinate.slot == resolvedAddress.imageAddress.slot else {
            throw DebuggerRunToCursorRequestError.inconsistentResolvedAddress
        }
        self.resolvedAddress = resolvedAddress
        self.observedStopID = observedStopID
    }

    var displayName: String {
        "run to \(resolvedAddress.runtimeAddress.hexAddress)"
    }
}

// MARK: - Expression evaluation

/// A normalized request to evaluate `expression` in the current stopped frame of
/// the live target. `expression` is a free-form C/C++/Swift expression string the
/// author typed; it is validated to reject control characters (mirroring the
/// register / memory / condition validators) so it can never break out of the
/// LLDB `expression --` command on the transport.
/// Authored watch definitions survive debugger stops, but carry no evaluated value or authority.
/// Persistence may serialize only these definitions, never DebuggerWatchEvaluation.
struct DebuggerWatchDefinition: Identifiable, Codable, Equatable {
    let id: UUID
    let expression: String

    init(id: UUID = UUID(), expression: String) throws {
        let request = try DebuggerExpressionRequest.parse(expression).get()
        guard request.expression.utf8.count <= 1_024 else {
            throw DebuggerAuthoringParseError.invalid("Watch expression must not exceed 1,024 UTF-8 bytes.")
        }
        self.id = id
        self.expression = request.expression
    }

    private enum CodingKeys: String, CodingKey { case id, expression }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: container.decode(UUID.self, forKey: .id),
                      expression: container.decode(String.self, forKey: .expression))
    }
}

struct DebuggerWatchEvaluation: Equatable {
    let coordinate: DebuggerInspectionCoordinate
    let value: String?
    let type: String?
    let error: String?
}

struct DebuggerExpressionRequest: Equatable {
    /// Maximum authored expression length. LLDB happily accepts long expressions,
    /// but a bounded length keeps a pasted blob from overwhelming the command
    /// session; the limit is generous enough for any realistic hand-typed expr.
    static let maximumLength = 1024

    var expression: String

    var displayName: String {
        expression
    }

    /// Parses raw author input into a normalized request, or returns `.failure`
    /// with a human-readable reason the view model surfaces verbatim. The input is
    /// trimmed; an empty expression and any control/newline character are rejected
    /// (a newline would terminate the LLDB command line early and let the
    /// remainder be interpreted as a separate command — the injection vector this
    /// validator closes).
    static func parse(
        _ expressionText: String
    ) -> Result<DebuggerExpressionRequest, DebuggerAuthoringParseError> {
        let trimmed = expressionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.invalid("Enter an expression to evaluate."))
        }
        guard trimmed.count <= maximumLength else {
            return .failure(.invalid("Expression must not exceed \(maximumLength) characters."))
        }
        guard !DebuggerAuthoringValidation.containsUnsupportedControlCharacters(trimmed) else {
            return .failure(.invalid("Expression contains unsupported control characters."))
        }

        return .success(DebuggerExpressionRequest(expression: trimmed))
    }
}

/// The parsed result of an `expression --` evaluation: the value text LLDB
/// printed and, when LLDB annotated one, the value's type. Pure / `Equatable` so
/// the parse is unit-testable without a live transport.
struct DebuggerExpressionResult: Equatable {
    var value: String
    var type: String?
    /// A typed post-expression authority snapshot when the backend can refresh the same exact
    /// stop before returning. Legacy backends leave this nil; callers must then keep mapping
    /// unavailable rather than reuse pre-expression module authority.
    var refreshedSnapshot: DebuggerSessionSnapshot?

    init(
        value: String,
        type: String?,
        refreshedSnapshot: DebuggerSessionSnapshot? = nil
    ) {
        self.value = value
        self.type = type
        self.refreshedSnapshot = refreshedSnapshot
    }

    var displayName: String {
        if let type, !type.isEmpty {
            return "(\(type)) \(value)"
        }
        return value
    }
}

// MARK: - Thread selection

/// A single recovered thread of the stopped process. Distinct from the
/// snapshot's lightweight `DebuggerThreadSummary` (which carries top-frame /
/// queue detail parsed from a backtrace): `DebuggerThread` is the authoring-layer
/// view used by the threads tab and the `selectThread` action, carrying the
/// system thread id plus the LLDB thread index used to issue `thread select`.
struct DebuggerThread: Identifiable, Equatable {
    /// LLDB thread index (`thread #<index>`), the 1-based token used to select.
    var index: Int
    /// System / kernel thread id (`tid = 0x…`) when LLDB reported one.
    var tid: UInt64?
    var name: String?
    var isSelected: Bool
    var stopReason: DebuggerPauseReason?

    var id: Int { index }

    init(
        index: Int,
        tid: UInt64? = nil,
        name: String? = nil,
        isSelected: Bool = false,
        stopReason: DebuggerPauseReason? = nil
    ) {
        self.index = index
        self.tid = tid
        self.name = name
        self.isSelected = isSelected
        self.stopReason = stopReason
    }

    var displayName: String {
        if let name, !name.isEmpty {
            return "Thread #\(index) (\(name))"
        }
        return "Thread #\(index)"
    }
}

/// A normalized request to select LLDB thread `index` on the stopped target so a
/// subsequent frame / register read reflects that thread. The index is validated
/// to be a positive integer (LLDB thread indexes are 1-based), so the
/// `thread select <index>` command never receives a raw user string.
struct DebuggerThreadSelectionRequest: Equatable {
    var index: Int

    static func parse(
        index: Int
    ) -> Result<DebuggerThreadSelectionRequest, DebuggerAuthoringParseError> {
        guard index > 0 else {
            return .failure(.invalid("Thread index must be a positive whole number."))
        }
        return .success(DebuggerThreadSelectionRequest(index: index))
    }
}

// MARK: - Launch invocation editing (arguments / environment / working dir)

/// A single authored environment override (one row in the env list editor). Kept
/// `Identifiable` so the SwiftUI list can iterate it with stable identity while
/// every validation decision stays here in the model.
struct DebuggerEnvironmentEntry: Identifiable, Equatable {
    let id: UUID
    var key: String
    var value: String

    init(id: UUID = UUID(), key: String = "", value: String = "") {
        self.id = id
        self.key = key
        self.value = value
    }

    /// `true` when the author has not typed anything in either field; blank rows
    /// are dropped (rather than rejected) so a trailing empty editor row never
    /// blocks a launch.
    var isBlank: Bool {
        !DebuggerAuthoredInputValidation.containsUnsupportedControlCharacters(key)
            && !DebuggerAuthoredInputValidation.containsUnsupportedControlCharacters(value)
            && key.trimmingCharacters(in: .whitespaces).isEmpty
            && value.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// A normalized launch invocation authored in the GUI: the parsed argument
/// vector, the environment overrides as a `[String: String]` map, and an
/// optional working directory. This is what the view model overlays onto the
/// selected target's `DebuggerLaunchConfiguration` before launching.
///
/// Parsing lives entirely here (pure, `Equatable`, `Result`-returning) so the
/// SwiftUI editor stays a thin binding over raw strings and every accept/reject
/// decision is headless-testable.
struct DebuggerLaunchInvocationDraft: Equatable {
    var arguments: [String]
    var environment: [String: String]
    var workingDirectory: String?

    init(
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil
    ) {
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    /// Parses the three raw GUI inputs into a normalized draft. Returns
    /// `.failure` with a human-readable reason that the view model surfaces
    /// verbatim (mirroring the other authoring parsers).
    ///
    /// - `argumentsText` is shell-word split (single/double quotes + backslash
    ///   escaping); an unterminated quote is rejected.
    /// - `environmentEntries` require `[A-Za-z_][A-Za-z0-9_]*` keys and reject
    ///   control characters and duplicate keys; blank rows are skipped.
    /// - `workingDirectoryText` is trimmed; when non-empty it is rejected unless
    ///   it is an absolute (or tilde) path free of control characters.
    static func parse(
        argumentsText: String,
        environmentEntries: [DebuggerEnvironmentEntry],
        workingDirectoryText: String
    ) -> Result<DebuggerLaunchInvocationDraft, DebuggerAuthoringParseError> {
        let arguments: [String]
        switch DebuggerLaunchArgumentParser.split(argumentsText) {
        case .success(let parsed):
            // Reject control characters in any split argument (the splitter treats
            // them as literal word characters, so they would otherwise pass through
            // to the LLDB run-args command unvalidated). Mirrors the condition/env
            // validators; also catches a stray `\r` the splitter doesn't word-break on.
            for argument in parsed where DebuggerAuthoringValidation.containsUnsupportedControlCharacters(argument) {
                return .failure(.invalid("Launch arguments contain unsupported control characters."))
            }
            arguments = parsed
        case .failure(let error):
            return .failure(error)
        }

        var environment: [String: String] = [:]
        for entry in environmentEntries where !entry.isBlank {
            let key = entry.key.trimmingCharacters(in: .whitespaces)
            if DebuggerAuthoredInputValidation.containsUnsupportedControlCharacters(entry.key) {
                let keyDescription = key.isEmpty ? "Environment key" : "Environment key \(key)"
                return .failure(.invalid(
                    "\(keyDescription) contains unsupported control characters."
                ))
            }
            guard !key.isEmpty else {
                return .failure(.invalid("Environment key cannot be empty."))
            }
            guard !key.contains("=") else {
                return .failure(.invalid("Environment key \(key) cannot contain '='."))
            }
            // A key starting with '-' could be misparsed as an LLDB flag by the
            // `settings set target.env-vars` command; reject it (the command also
            // gains a `--` terminator on the transport side).
            guard !key.hasPrefix("-") else {
                return .failure(.invalid("Environment key \(key) cannot start with '-'."))
            }
            guard DebuggerAuthoredInputValidation.isValidEnvironmentKey(key) else {
                return .failure(.invalid(
                    "Environment key \(key) must use ASCII letters, digits, or '_' and cannot start with a digit."
                ))
            }
            guard environment[key] == nil else {
                return .failure(.invalid("Environment key \(key) is set more than once."))
            }
            // The value keeps interior whitespace (only leading/trailing trim) so
            // `FLAG= ` style values stay faithful, but control characters are
            // rejected to match the launch-configuration validator.
            let value = entry.value.trimmingCharacters(in: .whitespaces)
            guard !DebuggerAuthoredInputValidation.containsUnsupportedControlCharacters(entry.value) else {
                return .failure(.invalid("Environment value for \(key) contains unsupported control characters."))
            }
            environment[key] = value
        }

        let trimmedWorkingDirectory = workingDirectoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let workingDirectory: String?
        if trimmedWorkingDirectory.isEmpty {
            workingDirectory = nil
        } else if DebuggerAuthoringValidation.containsUnsupportedControlCharacters(trimmedWorkingDirectory) {
            return .failure(.invalid("Working directory contains unsupported control characters."))
        } else if trimmedWorkingDirectory.hasPrefix("/")
            || trimmedWorkingDirectory == "~"
            || trimmedWorkingDirectory.hasPrefix("~/") {
            // Absolute, or the current user's home (`~` / `~/…`). `~user` forms (another
            // user's home) are not accepted — they rarely round-trip predictably.
            workingDirectory = trimmedWorkingDirectory
        } else {
            return .failure(.invalid("Working directory must be an absolute path (for example /tmp)."))
        }

        return .success(
            DebuggerLaunchInvocationDraft(
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory
            )
        )
    }

    /// Overlays this draft onto an existing launch configuration, replacing its
    /// argument vector and environment map and, when the author supplied one, its
    /// working directory (an empty cwd field leaves the configuration's default
    /// in place).
    func applied(to configuration: DebuggerLaunchConfiguration) -> DebuggerLaunchConfiguration {
        var updated = configuration
        updated.arguments = arguments
        updated.environment = environment
        if let workingDirectory {
            updated.workingDirectory = workingDirectory
        }
        return updated
    }
}

/// Clean-room POSIX-style shell-word splitter for the launch arguments field.
/// Supports single quotes (literal), double quotes (backslash escapes `"` and
/// `\`), and bare backslash escaping. Whitespace separates words; quotes can
/// abut to form a single word (`a"b c"` → `ab c`). An unterminated quote or a
/// trailing backslash is a parse error rather than a silently dropped character.
enum DebuggerLaunchArgumentParser {
    static func split(_ text: String) -> Result<[String], DebuggerAuthoringParseError> {
        var words: [String] = []
        var current = ""
        var hasCurrentWord = false
        var iterator = text.makeIterator()

        enum Mode {
            case normal
            case singleQuote
            case doubleQuote
        }
        var mode: Mode = .normal

        while let character = iterator.next() {
            switch mode {
            case .normal:
                if character == "\\" {
                    guard let escaped = iterator.next() else {
                        return .failure(.invalid("Arguments end with a dangling backslash escape."))
                    }
                    current.append(escaped)
                    hasCurrentWord = true
                } else if character == "'" {
                    mode = .singleQuote
                    hasCurrentWord = true
                } else if character == "\"" {
                    mode = .doubleQuote
                    hasCurrentWord = true
                } else if character == " " || character == "\t" || character == "\n" {
                    if hasCurrentWord {
                        words.append(current)
                        current = ""
                        hasCurrentWord = false
                    }
                } else {
                    current.append(character)
                    hasCurrentWord = true
                }
            case .singleQuote:
                if character == "'" {
                    mode = .normal
                } else {
                    current.append(character)
                }
            case .doubleQuote:
                if character == "\\" {
                    guard let escaped = iterator.next() else {
                        return .failure(.invalid("Arguments end with a dangling backslash escape."))
                    }
                    // Inside double quotes only `"` and `\` are escapable; other
                    // sequences keep the backslash literally (POSIX behavior).
                    if escaped == "\"" || escaped == "\\" {
                        current.append(escaped)
                    } else {
                        current.append("\\")
                        current.append(escaped)
                    }
                } else if character == "\"" {
                    mode = .normal
                } else {
                    current.append(character)
                }
            }
        }

        switch mode {
        case .normal:
            if hasCurrentWord {
                words.append(current)
            }
            return .success(words)
        case .singleQuote, .doubleQuote:
            return .failure(.invalid("Arguments contain an unterminated quote."))
        }
    }
}

// MARK: - Shared parse error

enum DebuggerAuthoringParseError: LocalizedError, Equatable {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let reason):
            reason
        }
    }

    var reason: String {
        switch self {
        case .invalid(let reason):
            reason
        }
    }
}

// MARK: - Shared validation primitives

enum DebuggerAuthoringValidation {
    static func containsUnsupportedControlCharacters(_ value: String) -> Bool {
        DebuggerAuthoredInputValidation.containsUnsupportedControlCharacters(value)
    }

    /// Register identifiers are bare alphanumeric names (optionally containing an
    /// underscore), matching the tokens LLDB exposes (`x0`, `pc`, `cpsr`, …).
    static func isValidRegisterName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 32 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        // A name that is purely numeric is not a register identifier.
        return name.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    /// Accepts a hex (`0x…`) or decimal integer literal that fits in 64 bits.
    static func isValidRegisterValue(_ value: String) -> Bool {
        if let hex = hexBody(of: value) {
            return UInt64(hex, radix: 16) != nil
        }
        return UInt64(value) != nil
    }

    /// Parses a single byte literal for the memory-write editor. Accepts an
    /// explicit `0x..` byte (1-2 hex digits) or a bare 1-2 hex-digit token (a byte
    /// is unambiguous without the prefix, unlike an address), rejecting anything
    /// that does not fit in 8 bits.
    static func parseHexByte(_ token: String) -> UInt8? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let body: String
        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            body = String(trimmed.dropFirst(2))
        } else {
            body = trimmed
        }
        guard !body.isEmpty, body.count <= 2 else { return nil }
        return UInt8(body, radix: 16)
    }

    static func parseHexAddress(_ rawAddress: String) -> UInt64? {
        let trimmed = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let hex = hexBody(of: trimmed) else { return nil }
        guard !hex.isEmpty else { return nil }
        return UInt64(hex, radix: 16)
    }

    /// Returns the hex digit body of `value` when it is an explicit `0x` literal,
    /// otherwise `nil`. Address / value parsing requires the `0x` prefix so a
    /// bare decimal is never silently reinterpreted as hex.
    private static func hexBody(of value: String) -> String? {
        guard value.count > 2 else {
            return value.hasPrefix("0x") || value.hasPrefix("0X") ? "" : nil
        }
        guard value.hasPrefix("0x") || value.hasPrefix("0X") else { return nil }
        return String(value.dropFirst(2))
    }
}
