import Foundation
@testable import MacScope

/// Instrumentation only. It never renders, executes a selector, hashes an input,
/// repairs an AST, or establishes that a supplied historical receipt is genuine.
/// Wiring must pass values from the original producer before its assertion fails.
enum F2J1CaptureRecorder {
    static let s1Selectors = [
        "CoreTests/S1InvariantCarrierProductionTests/testPureVectorAndScalarFootprintsPreserveInvariantRoot",
        "CoreTests/S1InvariantCarrierProductionTests/testSixRestoreChainHasExactNonvoidCallAndCapture",
        "CoreTests/S1InvariantCarrierProductionTests/testTerminalFrameDeallocationHasExactCall",
        "CoreTests/S1InvariantCarrierProductionTests/testTwoRestoreChainHasExactVoidCallAndCapture"
    ]
    static let j1Selector = "CoreTests/RegionalCallAuthorityTests/testConstantW21TerminalRetainsExactSkipVariableAdmission"

    #if DEBUG
    /// An owner installs this explicitly on the main actor. Nil makes the
    /// existing S1 export path execute without a recorder or extra render.
    @MainActor static var s1CaptureObserver: ((String, PseudocodePrinter.RenderCapture.Output) -> Void)? = nil
    #endif

    enum Failure: Error { case invalidIdentity, mismatchedRender, wrongSelectorOrMode, missingPreH05Attestation, mismatchedAST }
    enum Purpose: Equatable { case s1OnCFGAndPhis, preH05OffIdentity, j1OriginalAST }
    enum GateDecision: Equatable {
        case notObserved
        case accepted
        case refused(String)
        var observed: Bool { self != .notObserved }
    }
    struct Gates: Equatable {
        // These are supplied by the actual printer decision points. Absence is
        // explicit; a reimplementation of completeEdges/completePhis is not evidence.
        let completeEdges: GateDecision
        let completePhis: GateDecision
    }
    struct Identity: Equatable {
        let nonce: UUID
        let candidateSHA: String
        let selector: String
        let imageOwner: String
        let functionStart: UInt64
        let functionEnd: UInt64
        let effectiveBytesDigest: String
        let backend: String
        // Include effective environment/default settings and the actual builder
        // SSA/explicit-CFG choices. Do not infer requested mode from emitted text.
        let effectiveFlags: [String: String]
        let options: DecompilerOptions

        init(nonce: UUID, candidateSHA: String, selector: String, imageOwner: String,
             functionStart: UInt64, functionEnd: UInt64, effectiveBytesDigest: String,
             backend: String, effectiveFlags: [String: String], options: DecompilerOptions) throws {
            guard Self.hex(candidateSHA, length: 40), Self.hex(effectiveBytesDigest, length: 64),
                  !imageOwner.isEmpty, functionEnd > functionStart, !backend.isEmpty,
                  effectiveFlags["ssaEnabled"] != nil,
                  effectiveFlags["explicitCFGEnabled"] != nil else { throw Failure.invalidIdentity }
            self.nonce = nonce; self.candidateSHA = candidateSHA; self.selector = selector
            self.imageOwner = imageOwner; self.functionStart = functionStart; self.functionEnd = functionEnd
            self.effectiveBytesDigest = effectiveBytesDigest; self.backend = backend
            self.effectiveFlags = effectiveFlags; self.options = options
        }
        private static func hex(_ value: String, length: Int) -> Bool {
            value.utf8.count == length && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0)
            }
        }
    }
    struct Assertion: Equatable {
        let originalExpression: String
        // nil until the original assertion's same-run result is observed.
        let passed: Bool?
        let diagnostic: String?
    }
    struct Call: Equatable {
        let instructionOrdinal: Int
        let source: MacIRSourceSpan
        let frame: MacIRCallFrame
        let result: MacIRValue?
    }

    /// One immutable bundle owns document and source map together. Consumers
    /// retain this object, rather than combining separately produced text/maps.
    final class RenderSnapshot {
        let identity: Identity
        let function: MacIRFunction
        let document: PseudocodeDocument
        let presentationPhis: [MacIRPhi]
        let calls: [Call]
        var sourceMap: [PseudocodeLine] { document.lines }
        var instructionOrder: [MacIRSourceSpan] { function.instructions.map(\.source) }
        var refusals: [MacIRRefusal] { function.refusals }

        init(identity: Identity, function: MacIRFunction, document: PseudocodeDocument) throws {
            guard identity.functionStart == function.startAddress,
                  document.entryAddress == function.startAddress,
                  document.functionName == function.name,
                  identity.effectiveFlags["ssaEnabled"] == String(function.ssaEnabled),
                  function.endAddress.map({ $0 == identity.functionEnd }) ?? true,
                  function.instructions.allSatisfy({ identity.functionStart <= $0.source.address
                      && $0.source.address < identity.functionEnd }) else { throw Failure.mismatchedRender }
            self.identity = identity; self.function = function; self.document = document
            self.presentationPhis = PseudocodePrinter.presentationPhis(function)
            self.calls = function.instructions.enumerated().compactMap { ordinal, instruction in
                guard case let .call(frame, result) = instruction.operation else { return nil }
                return Call(instructionOrdinal: ordinal, source: instruction.source, frame: frame, result: result)
            }
        }
    }
    struct PreH05Attestation: Equatable {
        // This is an external owner attestation to retain, not a certificate
        // manufactured by this recorder. Plan must approve it before real capture.
        let candidateSHA: String
        let receiptReference: String
        let authority: String
    }
    struct Record {
        let purpose: Purpose
        let render: RenderSnapshot
        let assertion: Assertion
        let gates: Gates?
        let preH05: PreH05Attestation?
        var hasCompleteOnObservation: Bool {
            purpose == .s1OnCFGAndPhis && render.function.cfg != nil
                && gates?.completeEdges.observed == true && gates?.completePhis.observed == true
        }
    }
    struct ASTRecord {
        let render: RenderSnapshot
        let assertion: Assertion
        let program: OrdinaryC.Program
        let predicate: OrdinaryC.Expression
        let sourceRow: Int
        // Span indices are token offsets in this exact retained program. They
        // are neither binary addresses nor inferred producer coordinates.
        var predicateSpan: OrdinaryC.Span { predicate.span }
    }

    static func s1On(render: RenderSnapshot, gates: Gates, assertion: Assertion) throws -> Record {
        guard s1Selectors.contains(render.identity.selector), render.function.ssaEnabled else {
            throw Failure.wrongSelectorOrMode
        }
        return Record(purpose: .s1OnCFGAndPhis, render: render, assertion: assertion,
            gates: gates, preH05: nil)
    }
    static func preH05Off(render: RenderSnapshot, attestation: PreH05Attestation?,
                         assertion: Assertion) throws -> Record {
        guard s1Selectors.contains(render.identity.selector), !render.function.ssaEnabled else {
            throw Failure.wrongSelectorOrMode
        }
        guard let attestation, attestation.candidateSHA == render.identity.candidateSHA,
              !attestation.receiptReference.isEmpty, !attestation.authority.isEmpty else {
            throw Failure.missingPreH05Attestation
        }
        return Record(purpose: .preH05OffIdentity, render: render, assertion: assertion,
            gates: nil, preH05: attestation)
    }
    static func j1(render: RenderSnapshot, program: OrdinaryC.Program,
                   assertion: Assertion) throws -> ASTRecord {
        guard render.identity.selector == j1Selector, render.function.ssaEnabled else {
            throw Failure.wrongSelectorOrMode
        }
        let expected = OrdinaryC.lines(render.document)
        guard program.lines.map(\.text) == expected.map(\.text),
              program.lines.map(\.source) == expected.map(\.source),
              program.lines.map(\.phiEdge) == expected.map(\.phiEdge),
              program.lines.map(\.envelope) == expected.map(\.envelope) else { throw Failure.mismatchedAST }
        let predicates = program.code.compactMap { instruction -> OrdinaryC.Expression? in
            guard case let .branch(expression, _, _) = instruction.node,
                  (try? program.row(at: expression.span)) == 43 else { return nil }
            return expression
        }
        guard predicates.count == 1, let predicate = predicates.first else { throw Failure.mismatchedAST }
        return ASTRecord(render: render, assertion: assertion, program: program,
            predicate: predicate, sourceRow: 43)
    }
}
