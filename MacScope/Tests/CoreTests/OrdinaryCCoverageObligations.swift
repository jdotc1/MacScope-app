import Foundation

/// Acceptance accounting is independent of a finite whole-function scenario
/// pass. Empty implementations do not turn unported obligations into skipped
/// successes. SOURCE_ONLY / NOT_RUN. This is an explicit incomplete-coverage
/// report, NOT a behavioral product RED or a deliberately failing test.
enum OrdinaryCCoverageObligations {
    struct Gap: Equatable {
        let obligation: String
        let functions: [UInt64]
        let reason: String
    }
    static let gaps: [Gap] = [
        .init(obligation: "parsed-boundary-color-witnesses", functions: [0x26c78,0x2893c],
              reason: "17 historical regional-only cases per function need independent parsed-def-use entry bindings: cold first ordinal0,8 guards,7 shifts,1 high-bit TST. Old regional variable bindings are not accepted."),
        .init(obligation: "complete-source-edge-observation", functions: [0x26c78,0x2893c,0x3ae18,0x3b774,0x33418],
              reason: "The candidate records actual parsed transfers, but an independently frozen plural-origin source-edge/operand-span relation with successor ordinals remains required for full edge credit."),
        .init(obligation: "complete-actual-candidate-mutations", functions: [0x26c78,0x2893c,0x3ae18,0x3b774],
              reason: "Counter-step, alpha-renaming and authority controls are implemented. Actual-AST pointer-stride, W truncation, shift mask, stale joins/dynamic calls, early/missing X28 reload, CCMP and CSEL numerical mutations remain required; runtime/parser failure cannot count as a kill."),
        .init(obligation: "fused-writer-observation", functions: [0x26c78,0x2893c],
              reason: "Explicit source-bound subtraction assignments are observed. A printer choosing fused prefix/postfix/for decrement needs an explicit writer-to-parsed-update source relation; numerical matching cannot choose its observation site.")
    ]
}

