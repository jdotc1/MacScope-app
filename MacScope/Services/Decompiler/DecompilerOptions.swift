import Foundation

/// User-tunable preferences that change how the decompiler *emits* pseudocode
/// (as opposed to how the IR is built). Previously these were hard-coded inside
/// `PseudocodePrinter`/`emitBody` (a 1024-instruction size gate, always-on
/// region structuring, always-emitted `__nop()` intrinsics). This is the pure
/// bridge `(UserDefaults keys) -> decompiler options -> emitted text`, mirroring
/// `DisassemblyDisplayOptions` for the listing path, so toggling a preference in
/// Settings actually changes the produced pseudocode.
///
/// Pure value type with no SwiftUI/UserDefaults dependency baked in: constructed
/// from a `UserDefaults` (or directly, for tests) and consumed by
/// `PseudocodePrinter`. Keeping the read pure makes the whole emission path
/// table-testable — the same function renders differently per option, asserted
/// on the produced string.
struct DecompilerOptions: Equatable, Sendable {
    /// Prefer structured control flow (`if`/`while`/`for`) over `goto`. When
    /// true (the shipped default) the printer runs the dominator/region
    /// structurer and only falls back to the legacy goto-emitting renderer on a
    /// shape it cannot structure faithfully. When false the user has asked for
    /// the raw goto-form output: the region structurer is skipped entirely and
    /// every function is emitted by the legacy structurer (which renders
    /// unstructured branches as `goto`). This never changes which instructions
    /// are emitted — only how control flow is presented.
    var structureControlFlow: Bool

    /// Elide dead code: instructions that can never be reached. Today this is the
    /// conservative, provably-correct case — straight-line instructions that
    /// follow an unconditional `return`/`ret` inside the same emitted range (a
    /// `ret` is a total function exit, so anything textually after it on the same
    /// linear path is unreachable). Off by default so output stays byte-identical
    /// with the proven renderer until the user opts in.
    var deadCodeElimination: Bool

    /// Elide `nop` padding. `nop` carries no semantics, so it is hidden from the
    /// pseudocode view. When true the printer drops `__nop()` intrinsic lines.
    /// Off by default so output stays byte-identical until the user opts in.
    var nopElision: Bool

    /// Maximum instruction count for which the printer attempts CFG/region
    /// structuring. Functions larger than this skip structuring and use the
    /// legacy linear (goto) renderer directly — structuring very large functions
    /// is expensive and rarely improves readability. Was hard-coded at 1024.
    /// Clamped into `functionSizeGateRange` when read so a hostile/garbage
    /// default can't push it to a pathological value.
    var functionSizeGate: Int

    /// Proof-checked recovery runs only after the original structurer vetoes.
    /// Turning all three switches off selects the pre-CP2 behaviour exactly.
    var recoverSharedTails: Bool
    var recoverLoopExits: Bool
    var recoverGuardRegions: Bool

    /// Maximum original IR instructions in one shared tail; the recovery also
    /// caps total added instruction occurrences at 64 per function.
    var sharedTailInstructionLimit: Int

    /// Named transfers as a percentage of removed legacy gotos. The default
    /// allows no increase in explicit transfers; values are clamped to 0...400.
    var recoveryMaxTransferRatioPercent: Int

    /// Extra four-space indentation levels admitted over the legacy rendering.
    /// Clamped to 0...16 both at construction and at the point of admission.
    var recoveryMaxAdditionalNesting: Int

    /// Shipped defaults: every option in its pre-feature behaviour, so an
    /// un-configured app emits exactly as before. CP2's bounded recovery ships
    /// off until its output passes a readability admission rule (CP6).
    static let `default` = DecompilerOptions(
        structureControlFlow: true,
        deadCodeElimination: false,
        nopElision: false,
        functionSizeGate: 1024,
        recoverSharedTails: false,
        recoverLoopExits: false,
        recoverGuardRegions: false
    )

    /// The function-size gate is clamped into this range so a corrupt/hostile
    /// UserDefaults value (e.g. negative or astronomically large) can never
    /// produce a pathological structuring attempt. The lower bound keeps at
    /// least trivial functions structurable; the upper bound caps the work.
    static let functionSizeGateRange = 16...65_536

    // MARK: - UserDefaults keys

    /// The `UserDefaults`/`@AppStorage` keys these options read from. Kept in one
    /// place so the Settings UI and this reader can never drift apart on the
    /// string literal.
    enum Key {
        static let structureControlFlow = "decompilerStructureControlFlow"
        static let deadCodeElimination = "decompilerDeadCodeElimination"
        static let nopElision = "decompilerNopElision"
        static let functionSizeGate = "decompilerFunctionSizeGate"
        static let recoverSharedTails = "decompilerRecoverSharedTails"
        static let recoverLoopExits = "decompilerRecoverLoopExits"
        static let recoverGuardRegions = "decompilerRecoverGuardRegions"
        static let sharedTailInstructionLimit = "decompilerSharedTailInstructionLimit"
        static let recoveryMaxTransferRatioPercent = "decompilerRecoveryMaxTransferRatioPercent"
        static let recoveryMaxAdditionalNesting = "decompilerRecoveryMaxAdditionalNesting"
    }

    /// Reads the options from a `UserDefaults`. Absent keys fall back to the
    /// shipped default (so a fresh install emits unchanged), and
    /// `functionSizeGate` is clamped into `functionSizeGateRange`. Pure aside from
    /// the defaults read — no side effects.
    ///
    /// `UserDefaults.object(forKey:)` is used for the booleans so an *absent* key
    /// keeps the (possibly non-false) default rather than silently reading
    /// `false`.
    init(userDefaults: UserDefaults) {
        // Test-run injection never consults app-domain mode keys. Explicit
        // isolated suites still exercise the complete preference parser below.
        if userDefaults === UserDefaults.standard, MacIRConfiguration.installedTestBaseline != nil {
            self = .default
            return
        }
        let base = Self.default
        func bool(_ key: String, default fallback: Bool) -> Bool {
            userDefaults.object(forKey: key) == nil ? fallback : userDefaults.bool(forKey: key)
        }
        self.structureControlFlow = bool(Key.structureControlFlow, default: base.structureControlFlow)
        self.deadCodeElimination = bool(Key.deadCodeElimination, default: base.deadCodeElimination)
        self.nopElision = bool(Key.nopElision, default: base.nopElision)
        self.recoverSharedTails = bool(Key.recoverSharedTails, default: base.recoverSharedTails)
        self.recoverLoopExits = bool(Key.recoverLoopExits, default: base.recoverLoopExits)
        self.recoverGuardRegions = bool(Key.recoverGuardRegions, default: base.recoverGuardRegions)
        self.sharedTailInstructionLimit = userDefaults.object(forKey: Key.sharedTailInstructionLimit) == nil
            ? base.sharedTailInstructionLimit : min(max(userDefaults.integer(forKey: Key.sharedTailInstructionLimit), 0), 64)
        self.recoveryMaxTransferRatioPercent = userDefaults.object(forKey: Key.recoveryMaxTransferRatioPercent) == nil
            ? base.recoveryMaxTransferRatioPercent : min(max(userDefaults.integer(forKey: Key.recoveryMaxTransferRatioPercent), 0), 400)
        self.recoveryMaxAdditionalNesting = userDefaults.object(forKey: Key.recoveryMaxAdditionalNesting) == nil
            ? base.recoveryMaxAdditionalNesting : min(max(userDefaults.integer(forKey: Key.recoveryMaxAdditionalNesting), 0), 16)
        if userDefaults.object(forKey: Key.functionSizeGate) == nil {
            self.functionSizeGate = base.functionSizeGate
        } else {
            self.functionSizeGate = Self.clampGate(userDefaults.integer(forKey: Key.functionSizeGate))
        }
    }

    /// Direct memberwise init (for tests / programmatic construction). Clamps the
    /// gate so every constructed value already satisfies the invariant.
    init(
        structureControlFlow: Bool,
        deadCodeElimination: Bool,
        nopElision: Bool,
        functionSizeGate: Int,
        recoverSharedTails: Bool = false,
        recoverLoopExits: Bool = false,
        recoverGuardRegions: Bool = false,
        sharedTailInstructionLimit: Int = 12,
        recoveryMaxTransferRatioPercent: Int = 100,
        recoveryMaxAdditionalNesting: Int = 3
    ) {
        self.structureControlFlow = structureControlFlow
        self.deadCodeElimination = deadCodeElimination
        self.nopElision = nopElision
        self.functionSizeGate = Self.clampGate(functionSizeGate)
        self.recoverSharedTails = recoverSharedTails
        self.recoverLoopExits = recoverLoopExits
        self.recoverGuardRegions = recoverGuardRegions
        self.sharedTailInstructionLimit = min(max(sharedTailInstructionLimit, 0), 64)
        self.recoveryMaxTransferRatioPercent = min(max(recoveryMaxTransferRatioPercent, 0), 400)
        self.recoveryMaxAdditionalNesting = min(max(recoveryMaxAdditionalNesting, 0), 16)
    }

    private static func clampGate(_ raw: Int) -> Int {
        min(max(raw, functionSizeGateRange.lowerBound), functionSizeGateRange.upperBound)
    }
}
