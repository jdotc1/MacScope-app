import Foundation

/// Pure, unit-testable value types for the two remaining Tier-3 debugger
/// runtime surfaces:
///
///  * BACKGROUND WAIT-STOP — the `events -> state -> snapshot` state machine that
///    lets the UI issue a run command (continue / step) and then *await* the
///    process stopping again in the background, surfacing an honest
///    "running, waiting to stop" in-flight state instead of blocking the UI.
///  * CALL-STACK FRAME SELECTION — the validated `selectFrame(_:)` request plus
///    the pure selection / gating logic that re-reads the chosen frame's
///    registers / locals and resolves the frame PC the listing navigates to.
///
/// Everything here is pure (`Equatable`, no SwiftUI, no live transport) so the
/// reducer transitions and the selection/validation logic are headless-testable
/// against the existing `DebuggerCoreTests` / `DebuggerAuthoringTests` style.

// MARK: - Background wait-for-stop state machine

/// The outcome of awaiting a stop after a run command was issued. The transport
/// (or a poll) produces one of these; the reducer consumes it to advance state.
///
/// `stillRunning` is the honest "we polled and the process has not stopped yet"
/// signal — the machine stays in `.waitingForStop` rather than guessing.
enum DebuggerRunEvent: Equatable {
    /// The process stopped again (breakpoint, step completion, signal, …).
    case stopped(reason: DebuggerPauseReason)
    /// The process exited normally with an optional exit code.
    case exited(code: Int32?)
    /// The process crashed / was killed by a fatal signal.
    case crashed(signal: String)
    /// A poll observed the process is still running; keep waiting.
    case stillRunning
    /// Awaiting the stop failed (transport error, timeout). The machine surfaces
    /// the reason and returns to a terminal-but-recoverable failed state.
    case failed(reason: String)
}

/// The kind of run command that put the process back into motion. Used only to
/// phrase the in-flight status honestly ("Continuing…", "Stepping…").
enum DebuggerRunIntent: Equatable {
    case resume
    case stepOver
    case stepInto
    case stepOut

    var inFlightVerb: String {
        switch self {
        case .resume:
            "Continuing"
        case .stepOver:
            "Stepping over"
        case .stepInto:
            "Stepping into"
        case .stepOut:
            "Stepping out"
        }
    }

    var controlledRuntimeAction: DebuggerControlAction {
        switch self {
        case .resume:
            .continueExecution
        case .stepOver:
            .stepOver
        case .stepInto:
            .stepInto
        case .stepOut:
            .stepOut
        }
    }
}

/// The state of the background wait-for-stop machine.
///
/// The lifecycle is: `.idle` → (run command issued) → `.waitingForStop` →
/// (`.stopped` event) → `.stopped`, or `.exited` / `.crashed` / `.failed` on the
/// corresponding terminal events. A `.stillRunning` poll keeps the machine in
/// `.waitingForStop`. Issuing a new run command is only legal from `.idle` or a
/// terminal-stopped state — never while already waiting.
enum DebuggerWaitStopState: Equatable {
    /// No run command is in flight; the process is stopped (or not yet started).
    case idle
    /// A run command was issued; the machine is awaiting the next stop event.
    /// Carries the intent so the UI can phrase the in-flight status honestly.
    case waitingForStop(intent: DebuggerRunIntent)
    /// A non-killing detach is in flight. This is neither a stopped nor a
    /// terminal state, and no new debugger command may be issued until exact
    /// detach or failure evidence replaces it.
    case detaching
    /// The process stopped again with the given reason.
    case stopped(reason: DebuggerPauseReason)
    /// The process exited (terminal).
    case exited(code: Int32?)
    /// The process crashed (terminal).
    case crashed(signal: String)
    /// Awaiting the stop failed; carries a human-readable reason (recoverable —
    /// a fresh run command may be issued once the session is re-validated).
    case failed(reason: String)

    /// `true` while a run command is in flight and the UI should show a
    /// "running, waiting to stop" affordance rather than the stopped controls.
    var isWaiting: Bool {
        if case .waitingForStop = self { return true }
        return false
    }

    /// `true` when the process is currently stopped and frame/register controls
    /// should be live.
    var isStopped: Bool {
        if case .stopped = self { return true }
        // `.idle` models a not-yet-run-or-freshly-stopped session; it is not
        // itself a "stopped at a definite reason" state, so it is not reported
        // as stopped here. Use `canIssueRunCommand` to gate run commands.
        return false
    }

    /// `true` once the process has finished (exited or crashed) and no further
    /// run command can resume it.
    var isTerminated: Bool {
        switch self {
        case .exited, .crashed:
            return true
        case .idle, .waitingForStop, .detaching, .stopped, .failed:
            return false
        }
    }

    /// A run command (continue / step) may be issued only when the machine is not
    /// already waiting and the process has not terminated.
    var canIssueRunCommand: Bool {
        switch self {
        case .idle, .stopped, .failed:
            return true
        case .waitingForStop, .detaching, .exited, .crashed:
            return false
        }
    }

    /// A short, honest status line for the current state.
    var statusDetail: String {
        switch self {
        case .idle:
            "Stopped."
        case .waitingForStop(let intent):
            "\(intent.inFlightVerb)… waiting for the process to stop."
        case .detaching:
            "Detaching… no debugger commands are available."
        case .stopped(let reason):
            "Stopped: \(reason.displayTitle)."
        case .exited(let code):
            code.map { "Process exited with code \($0)." } ?? "Process exited."
        case .crashed(let signal):
            "Process crashed: \(signal)."
        case .failed(let reason):
            reason
        }
    }
}

/// The pure reducer for the background wait-for-stop lifecycle. Kept as a value
/// type with static-style transitions so the `events -> state` mapping is fully
/// unit-testable without a live transport or the UI.
///
/// Usage from the live layer:
///   1. `beginRun(_:)` when a continue/step command is *issued* → enters
///      `.waitingForStop`.
///   2. background task polls/awaits the transport; each observation is fed
///      through `apply(_:)` → `.stillRunning` keeps waiting, a `.stopped` /
///      `.exited` / `.crashed` / `.failed` event advances to the matching state.
struct DebuggerWaitStopMachine: Equatable {
    private(set) var state: DebuggerWaitStopState

    init(state: DebuggerWaitStopState = .idle) {
        self.state = state
    }

    /// Issues a run command, moving from a runnable state into `.waitingForStop`.
    /// Returns `true` when the transition was legal; when the machine is already
    /// waiting or terminated the call is a no-op and returns `false` (the caller
    /// surfaces "already running" / "process ended" rather than double-issuing).
    @discardableResult
    mutating func beginRun(_ intent: DebuggerRunIntent) -> Bool {
        guard state.canIssueRunCommand else { return false }
        state = .waitingForStop(intent: intent)
        return true
    }

    /// Folds a single observed run event into the state. Events that arrive when
    /// the machine is not waiting are ignored (a late stop event after the user
    /// already terminated, for example) so the reducer never regresses a terminal
    /// state — except `.failed`, which is always honored so a transport error is
    /// never swallowed.
    mutating func apply(_ event: DebuggerRunEvent) {
        switch event {
        case .failed(let reason):
            // A transport failure is always surfaced, even from a terminal state,
            // so the cause is never hidden.
            state = .failed(reason: reason)
            return
        case .stopped, .exited, .crashed, .stillRunning:
            break
        }

        // All non-failure events only advance an in-flight wait; a stray event in
        // any other state is ignored to avoid regressing the lifecycle.
        guard case .waitingForStop = state else { return }

        switch event {
        case .stopped(let reason):
            state = .stopped(reason: reason)
        case .exited(let code):
            state = .exited(code: code)
        case .crashed(let signal):
            state = .crashed(signal: signal)
        case .stillRunning:
            // Keep waiting; the in-flight intent is preserved.
            break
        case .failed:
            break // handled above
        }
    }

    /// Resets the machine to `.idle` (e.g. after a fresh launch / attach replaces
    /// the session) so a new wait lifecycle can begin cleanly.
    mutating func reset() {
        state = .idle
    }

    /// Resets the lifecycle to the state implied by a freshly produced snapshot —
    /// used after a launch / attach replaces the whole session, so the machine
    /// reflects the new process's stopped/running/exited posture directly rather
    /// than waiting for a run command to be issued first.
    mutating func reset(to snapshot: DebuggerSessionSnapshot) {
        state = DebuggerWaitStopMachine.state(for: snapshot)
    }

    /// Derives the wait-stop machine state implied by a freshly produced session
    /// snapshot. This bridges the snapshot the live transport returns back into
    /// the lifecycle (snapshot is the source of truth for the *result* of a wait):
    ///
    ///  * a paused live process → `.stopped(reason:)`,
    ///  * an exited process → `.exited(code:)`,
    ///  * a running (not-yet-stopped) live process → `.waitingForStop`,
    ///  * an unavailable/failed state → `.failed`,
    ///  * anything else (no live session) → `.idle`.
    ///
    /// `intent` phrases the in-flight verb when the snapshot is still running.
    static func state(
        for snapshot: DebuggerSessionSnapshot,
        runningIntent intent: DebuggerRunIntent = .resume
    ) -> DebuggerWaitStopState {
        switch snapshot.processState {
        case .paused(_, let reason):
            return snapshot.hasLiveProcessSession ? .stopped(reason: reason) : .idle
        case .running:
            return snapshot.hasLiveProcessSession ? .waitingForStop(intent: intent) : .idle
        case .exited(let code):
            return .exited(code: code)
        case .unavailable(let reason):
            return .failed(reason: reason)
        case .detaching:
            return .detaching
        case .notAttached, .launching, .batchStopped:
            return .idle
        }
    }
}

// MARK: - Call-stack frame selection

/// A normalized request to select stack frame `index` on the stopped target so a
/// subsequent register / locals read reflects that frame, and the listing can
/// navigate to the frame's PC.
///
/// The index is a 0-based backtrace position (`frame #0` is the innermost
/// frame). Validation is bounds-checked against the recovered frame count so a
/// raw out-of-range index never reaches the `frame select <index>` command.
struct DebuggerFrameSelectionRequest: Equatable {
    /// 0-based LLDB frame index (`frame select <index>`).
    var index: Int

    static func parse(
        index: Int,
        frameCount: Int
    ) -> Result<DebuggerFrameSelectionRequest, DebuggerAuthoringParseError> {
        guard index >= 0 else {
            return .failure(.invalid("Frame index must be zero or a positive whole number."))
        }
        guard frameCount > 0 else {
            return .failure(.invalid("No stack frames are available to select."))
        }
        guard index < frameCount else {
            return .failure(.invalid("Frame index \(index) is out of range (0…\(frameCount - 1))."))
        }
        return .success(DebuggerFrameSelectionRequest(index: index))
    }
}

/// The pure result of resolving a frame selection against a session snapshot: the
/// selected frame summary plus the PC the listing should navigate to. Kept pure
/// / `Equatable` so the gating + resolution is unit-testable without the UI.
struct DebuggerFrameSelection: Equatable {
    var index: Int
    var frame: DebuggerFrameSummary

    /// The instruction the selected frame is executing; what the listing
    /// navigates / highlights when this frame is chosen.
    var programCounter: UInt64 {
        frame.address
    }

    /// Resolves a frame-selection request against a session snapshot. Gated to a
    /// stopped (paused) live session — selecting a frame on a running, exited, or
    /// detached session is rejected so a stale frame can never be navigated to.
    ///
    /// Returns `.failure` with the same human-readable reason the view model
    /// surfaces verbatim, mirroring the thread-selection idiom.
    static func resolve(
        index: Int,
        in snapshot: DebuggerSessionSnapshot
    ) -> Result<DebuggerFrameSelection, DebuggerAuthoringParseError> {
        guard snapshot.canSelectFrameLiveProcess else {
            return .failure(.invalid("Frame selection requires a paused live debug process."))
        }

        switch DebuggerFrameSelectionRequest.parse(index: index, frameCount: snapshot.frames.count) {
        case .failure(let error):
            return .failure(error)
        case .success(let request):
            // Prefer the frame whose LLDB `index` matches the request; fall back to
            // positional indexing (frames are normally index-ordered, but a
            // backtrace gap shouldn't crash the selection). The parse step already
            // bounds-checked `request.index` against `frames.count`.
            let frame = snapshot.frames.first(where: { $0.index == request.index })
                ?? snapshot.frames[request.index]
            return .success(DebuggerFrameSelection(index: request.index, frame: frame))
        }
    }
}

// MARK: - Register / memory value formatting

/// The display interpretation the debugger panel applies to an already-read
/// register or memory value. This is *pure presentation*: the underlying value
/// LLDB returned is never re-read or mutated — only re-rendered from the same raw
/// bits — so toggling the format issues no transport command.
///
///  * `hex` — the raw bit pattern as a zero-padded `0x…` literal (the canonical
///    form LLDB's `--format x` already prints).
///  * `decimal` — the bits read as an unsigned integer.
///  * `signedDecimal` — the bits read as a two's-complement signed integer.
///  * `float` — the bits *reinterpreted* (not converted) as the IEEE-754 value of
///    the matching width (64-bit → `Double`, 32-bit → `Float`).
enum DebuggerValueFormat: String, CaseIterable, Equatable {
    case hex
    case decimal
    case signedDecimal
    case float

    /// Short, stable title for the format picker.
    var displayTitle: String {
        switch self {
        case .hex: "Hex"
        case .decimal: "Decimal"
        case .signedDecimal: "Signed"
        case .float: "Float"
        }
    }
}

/// Pure, headless-testable renderer that re-formats an already-read scalar value
/// under a chosen `DebuggerValueFormat`. The input is the raw bit pattern plus a
/// bit width (a register / memory word is 64-bit on ARM64; a `w`-register or a
/// 4-byte memory cell is 32-bit), so the signed and float interpretations are
/// width-correct (e.g. `0xffffffff` is `-1` as a 32-bit signed value but
/// `4294967295` as a 64-bit one).
///
/// Nothing here touches a live transport: the value was already read by the
/// snapshot; this only changes how the same bits are displayed.
enum DebuggerValueFormatter {
    /// Renders `bits` (already masked to `bitWidth`) under `format`.
    ///
    /// - `bitWidth` is 32 or 64; any other width is treated as 64-bit (the ARM64
    ///   default) so an unexpected width still renders rather than crashing.
    static func format(bits rawBits: UInt64, bitWidth: Int = 64, as format: DebuggerValueFormat) -> String {
        let width = (bitWidth == 32) ? 32 : 64
        let bits = maskedBits(rawBits, bitWidth: width)

        switch format {
        case .hex:
            let hexDigits = width / 4
            return "0x" + String(bits, radix: 16, uppercase: false).leftPadded(to: hexDigits, with: "0")
        case .decimal:
            return String(bits)
        case .signedDecimal:
            return String(signedValue(of: bits, bitWidth: width))
        case .float:
            return floatString(of: bits, bitWidth: width)
        }
    }

    /// Parses the raw bit pattern out of a register / memory value string LLDB
    /// printed (canonically a `0x…` hex scalar from `--format x`, but a bare
    /// decimal token is accepted too). Trailing annotations LLDB appends (a symbol
    /// name after the value, e.g. `0x… echo\`main + 8`) are ignored — only the
    /// leading numeric token is read. Returns `nil` when no leading numeric token
    /// is present (so a non-numeric value falls back to its original text).
    static func rawBits(from value: String) -> UInt64? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else {
            return nil
        }
        let scalar = String(token)
        if scalar.hasPrefix("0x") || scalar.hasPrefix("0X") {
            return UInt64(scalar.dropFirst(2), radix: 16)
        }
        // A bare decimal token (some LLDB formats print one); negative tokens are
        // re-encoded as their two's-complement bit pattern so the signed/float
        // interpretations stay consistent.
        if let unsigned = UInt64(scalar) {
            return unsigned
        }
        if let signed = Int64(scalar) {
            return UInt64(bitPattern: signed)
        }
        return nil
    }

    /// Convenience wrapper: re-renders a register / memory value *string* under a
    /// format, returning the original text unchanged when the value carries no
    /// parseable leading numeric token (so a symbolic-only value is never mangled).
    static func reformat(value: String, bitWidth: Int = 64, as format: DebuggerValueFormat) -> String {
        // The canonical hex form is exactly what the snapshot already stores; keep
        // the original text (symbol annotations and all) rather than re-deriving it.
        if format == .hex { return value }
        guard let bits = rawBits(from: value) else { return value }
        return self.format(bits: bits, bitWidth: bitWidth, as: format)
    }

    private static func maskedBits(_ bits: UInt64, bitWidth: Int) -> UInt64 {
        guard bitWidth < 64 else { return bits }
        let mask = (UInt64(1) << UInt64(bitWidth)) - 1
        return bits & mask
    }

    private static func signedValue(of bits: UInt64, bitWidth: Int) -> Int64 {
        if bitWidth >= 64 {
            return Int64(bitPattern: bits)
        }
        let signBit = UInt64(1) << UInt64(bitWidth - 1)
        if bits & signBit != 0 {
            // Sign-extend: set every bit above the width before reinterpreting.
            let extended = bits | ~((UInt64(1) << UInt64(bitWidth)) - 1)
            return Int64(bitPattern: extended)
        }
        return Int64(bits)
    }

    private static func floatString(of bits: UInt64, bitWidth: Int) -> String {
        if bitWidth == 32 {
            let value = Float(bitPattern: UInt32(truncatingIfNeeded: bits))
            return floatDescription(value.isFinite ? Double(value) : specialDouble(value))
        }
        let value = Double(bitPattern: bits)
        return floatDescription(value)
    }

    /// Maps a non-finite `Float` to the matching `Double` special value so the
    /// description renders `inf` / `-inf` / `nan` consistently across widths.
    private static func specialDouble(_ value: Float) -> Double {
        if value.isNaN { return Double.nan }
        return value > 0 ? Double.infinity : -Double.infinity
    }

    private static func floatDescription(_ value: Double) -> String {
        if value.isNaN { return "nan" }
        if value.isInfinite { return value < 0 ? "-inf" : "inf" }
        return String(value)
    }
}
