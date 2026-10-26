import Foundation
import XCTest
#if canImport(MacScope)
@testable import MacScope
#if canImport(MacScopeAnalysisCore)
@testable import MacScopeAnalysisCore
#endif
#elseif canImport(RenderAll)
@testable import RenderAll
#endif

/// Source-only additions. No execution receipt is claimed. All APIs exist on the
/// frozen input, so admission failures are behavioral prerequisites, not compile RED.
final class RegionalSwitchControlTests: XCTestCase {
    // Stack-local read-only fence encloses setup, body and teardown. No shared
    // snapshot state is needed when suites or test instances execute in parallel.
    override func invokeTest() {
        let before = NSDictionary(dictionary:
            UserDefaults.standard.persistentDomain(forName: "org.macscope.app") ?? [:])
        defer {
            let after = UserDefaults.standard.persistentDomain(forName: "org.macscope.app") ?? [:]
            XCTAssertTrue(before.isEqual(to: after),
                          "Mode tests must not change the application preference domain")
        }
        super.invokeTest()
    }


    func testLegacyRecoveryRefusesCapturedTypedSwitches() throws {
        let fixture = try RegionalSwitchFixture.make(.jinit)
        let cfg = CFGBuilder.buildCFG(instructions: fixture.function.instructions)
        // Keep the entire captured native stream, metadata and original mapping.
        // This is an ordinary-recovery refusal control, not low-arity coverage.
        XCTAssertEqual(fixture.input.instructions, fixture.capture.input_rows)
        XCTAssertEqual(fixture.function.instructions.count, fixture.seed.rowCount)
        XCTAssertEqual(cfg.blocks.count, fixture.seed.blockCount)
        XCTAssertFalse(cfg.hasUnresolvedTargets)
        XCTAssertTrue(cfg.irreducibleBlocks.isEmpty)
        let switchRows = cfg.blocks.compactMap { block -> Int? in
            let last = block.endIndex - 1
            if case .switchDispatch = fixture.function.instructions[last].operation { return last }
            return nil
        }
        XCTAssertEqual(switchRows, fixture.capture.switch_facts.map(\.lifted_index))
        XCTAssertEqual(switchRows.count, 2)
        var options = DecompilerOptions.default
        options.structureControlFlow = true
        options.recoverGuardRegions = true
        XCTAssertNil(RegionTree.recoveryPlan(cfg: cfg, instructions: fixture.function.instructions,
            options: options, veto: .conditionalDoubleGuardToJoin),
            "Ordinary recovery must not inherit certified typed-switch admission")
    }

    /// The native-document proofs read the actual flag-on default document; the
    /// certificate controls around them stay on the flag-off model function.
    private func nativeFixture(_ seed: RegionalSwitchSeed) throws -> RegionalSwitchFixture {
        return try MacIRConfiguration.$ssaOverride.withValue(true) {
            return try RegionalSwitchFixture.make(seed)
        }
    }

    func testCapturedRoutingPreservesGroupsAndRejectsStaleCaseMap() throws {
        return try MacIRConfiguration.$ssaOverride.withValue(false) {
            let fixture = try RegionalSwitchFixture.make(.jinit)
            let cfg = CFGBuilder.buildCFG(instructions: fixture.function.instructions)
            let state = try XCTUnwrap(RegionalPhysicalStatePlan.prove(function: fixture.function, cfg: cfg),
                                     "PREREQUISITE: full decoded state, including both typed switches")
            let control = try XCTUnwrap(RegionTree.certifiedRegionalRecoveryPlan(
                function: fixture.function, cfg: cfg, certifiedBy: state))
            XCTAssertTrue(RegionTree.recoveryIsEquivalent(control, to: cfg))
            var blocks: [Int: [RegionTree.RecoveryRegion]] = [:]
            try collect(control, into: &blocks)
            XCTAssertEqual(Set(blocks.keys), Set(cfg.blocks.indices))
            _ = try XCTUnwrap(fixture.document.regionTree,
                             "PREREQUISITE: actual default emission must have been admitted")
            // Preserve all model/certificate controls below. Supersede only six
            // named physical-cell equality nodes with actual native AST ownership:
            // every ordinal/default, W32 source definition and residual route.
            _ = try OriginalDispatchOwnership.verify(try nativeFixture(.jinit))
            for fact in fixture.capture.switch_facts {
                let row = fact.lifted_index
                let block = try XCTUnwrap(cfg.blocks.first { $0.endIndex - 1 == row })
                let routes = try XCTUnwrap(blocks[block.index])
                XCTAssertEqual(routes.count, block.successors.count)
                XCTAssertTrue(routes.allSatisfy(transferOnly), "No alias can re-emit an original payload")
            }
            var changed = fixture.function
            let row = fixture.capture.switch_facts[0].lifted_index
            guard case let .switchDispatch(selector, originalCases, defaultTarget) = changed.instructions[row].operation else {
                return XCTFail("The captured dispatch operation is required")
            }
            var cases = originalCases
            cases[6].target = cases[2].target // both targets remain present; distinct topology is unchanged.
            changed.instructions[row].operation = .switchDispatch(index: selector, cases: cases, defaultTarget: defaultTarget)
            let changedCFG = CFGBuilder.buildCFG(instructions: changed.instructions)
            XCTAssertEqual(changedCFG.blocks.map(\.successors), cfg.blocks.map(\.successors))
            XCTAssertNil(RegionTree.certifiedRegionalRecoveryPlan(function: changed, cfg: changedCFG, certifiedBy: state),
                         "Topology equality cannot authorize changed original label membership")
        }
    }

    func testCapturedEmitterRefusesPayloadBearingSwitchRoute() throws {
        return try MacIRConfiguration.$ssaOverride.withValue(false) {
            let fixture = try RegionalSwitchFixture.make(.j12init)
            let cfg = CFGBuilder.buildCFG(instructions: fixture.function.instructions)
            let state = try XCTUnwrap(RegionalPhysicalStatePlan.prove(function: fixture.function, cfg: cfg),
                                     "PREREQUISITE: certify the complete real input first")
            let control = try XCTUnwrap(RegionTree.certifiedRegionalRecoveryPlan(
                function: fixture.function, cfg: cfg, certifiedBy: state))
            _ = try XCTUnwrap(fixture.document.regionTree, "PREREQUISITE: unmodified emission is admitted")
            let row = fixture.capture.switch_facts[0].lifted_index
            let dispatchBlock = try XCTUnwrap(cfg.blocks.first { $0.endIndex - 1 == row })
            let target = try XCTUnwrap(dispatchBlock.successors.first)
            var blocks: [Int: [RegionTree.RecoveryRegion]] = [:]
            try collect(control, into: &blocks)
            let payload: RegionTree.RecoveryRegion = .block(target, exits: try XCTUnwrap(blocks[target]))
            var replacements = 0
            func inject(_ node: RegionTree.RecoveryRegion) -> RegionTree.RecoveryRegion {
                switch node {
                case let .sequence(parts): return .sequence(parts.map(inject))
                case let .scope(target, body): return .scope(target: target, body: inject(body))
                case let .loop(header, body): return .loop(header: header, body: inject(body))
                case let .block(index, exits):
                    guard index == dispatchBlock.index else { return .block(index, exits: exits.map(inject)) }
                    var changed = exits
                    changed[0] = payload
                    replacements += 1
                    return .block(index, exits: changed)
                case .breakTo, .continueAt: return node
                }
            }
            let malformed = inject(control)
            XCTAssertEqual(replacements, 1)
            var originals: [Int: PseudocodeLine] = [:]
            for originalRow in state.boundaries.originalRows {
                let source = fixture.function.instructions[originalRow].source
                var candidates = fixture.document.lines.filter { $0.kind == .instruction && $0.source == source }
                if let call = fixture.capture.calls.first(where: { $0.lifted_index == originalRow }) {
                    candidates = candidates.filter {
                        RegionalSwitchFixture.payload($0.text) == RegionalSwitchFixture.payload(call.baseline_text)
                    }
                }
                XCTAssertEqual(candidates.count, 1, "PREREQUISITE: exact retained original at row \(originalRow)")
                originals[originalRow] = try XCTUnwrap(candidates.first)
            }
            XCTAssertNil(RegionalRecoveryEmitter.emit(function: fixture.function, state: state,
                control: malformed, cfg: cfg, originals: originals, depth: 0, lineOffset: 0,
                valueText: { $0.description }, commentSuffix: { _ in "" }, cancelled: { false }),
                "Refuse a payload route before any alias/default reuse can duplicate it")
        }
    }

    func testTypedSelectorRefusesOnePredecessorLoadWidth() throws {
        return try MacIRConfiguration.$ssaOverride.withValue(false) {
            let fixture = try RegionalSwitchFixture.make(.jinit)
            let row = 144, writer = 87
            let cfg = CFGBuilder.buildCFG(instructions: fixture.function.instructions)
            let context = try XCTUnwrap(RegionalPhysicalStatePlan.typedSelectorReadContext(
                function: fixture.function, cfg: cfg))
            let certificate = try XCTUnwrap(context.certificate(at: row))
            XCTAssertEqual(Set(certificate.reachingWritersByPredecessor.keys), Set([40, 41]))
            for writers in certificate.reachingWritersByPredecessor.values {
                XCTAssertEqual(writers, Set([52, 87]))
            }
            XCTAssertEqual(fixture.rows[writer].mnemonic, "ldp")
            XCTAssertEqual(fixture.rows[writer].operands, "w9, w8, [x19, #0x3c]")
            var bytes = try fixture.rows[writer].bytes.split(separator: " ").map {
                try XCTUnwrap(UInt8($0, radix: 16))
            }
            XCTAssertEqual(bytes.count, 4)
            guard bytes.count == 4 else { return XCTFail("one complete pair-load instruction required") }
            // LDP's width bit also scales its encoded displacement. The decoder
            // supplies every changed source/envelope field; no IR is hand-written.
            bytes[3] |= 0x80
            let decoded = ARM64Decoder().decode(Data(bytes), baseAddress: fixture.rows[writer].address)
            XCTAssertEqual(decoded.count, 1)
            let replacement = try XCTUnwrap(decoded.first)
            XCTAssertEqual(replacement.mnemonic, "ldp")
            XCTAssertEqual(replacement.operands, "x9, x8, [x19, #0x78]")
            var input = fixture.input
            input.instructions[writer] = InstructionRow(address: replacement.address,
                bytes: replacement.byteText, mnemonic: replacement.mnemonic,
                operands: replacement.operands, hasBreakpoint: false,
                comment: replacement.comment, structuredOperands: replacement.structuredOperands)
            XCTAssertEqual(input.instructions.indices.filter {
                input.instructions[$0] != fixture.rows[$0]
            }, [writer])
            let function = PseudocodePrinter(options: .default).buildFunction(
                functionName: input.functionName, startAddress: input.startAddress,
                jumpTables: input.jumpTables, objcSelectors: input.objcSelectors,
                constantStrings: input.constantStrings, signatureOverrides: input.signatureOverrides,
                authoredCallSignaturesByTarget: input.authoredCallSignaturesByTarget,
                directCallVoidResultTargets: input.directCallVoidResultTargets,
                slotCallContracts: input.slotCallContracts, callerReturnWidth: input.callerReturnWidth,
                callerReturnType: input.callerReturnType, types: input.types, instructions: input.instructions)
            let changedCFG = CFGBuilder.buildCFG(instructions: function.instructions)
            XCTAssertEqual(changedCFG.blocks, cfg.blocks)
            guard case let .binary(_, "-", markedInput, _) = function.instructions[row].operation else {
                return XCTFail("the original marked SUB must remain the candidate")
            }
            XCTAssertEqual(markedInput, .unknown("unavailable_w8"))
            let changedContext = try XCTUnwrap(RegionalPhysicalStatePlan.typedSelectorReadContext(
                function: function, cfg: changedCFG),
                "canonical decoded rows and initialized reads must pass before testing the certificate")
            XCTAssertNil(changedContext.certificate(at: row),
                "one reaching predecessor with a different load width invalidates the selector certificate")
            XCTAssertNil(RegionalPhysicalStatePlan.prove(function: function, cfg: changedCFG))
        }
    }

    private enum Failure: Error { case invalid }
    private func collect(_ node: RegionTree.RecoveryRegion,
                         into blocks: inout [Int: [RegionTree.RecoveryRegion]]) throws {
        switch node {
        case let .sequence(parts): for part in parts { try collect(part, into: &blocks) }
        case let .scope(_, body), let .loop(_, body): try collect(body, into: &blocks)
        case let .block(index, exits):
            XCTAssertNil(blocks[index], "Every original block must be owned exactly once")
            guard blocks[index] == nil else { throw Failure.invalid }
            blocks[index] = exits
            for exit in exits { try collect(exit, into: &blocks) }
        case .breakTo, .continueAt: break
        }
    }
    private func transferOnly(_ node: RegionTree.RecoveryRegion) -> Bool {
        switch node {
        case .breakTo, .continueAt: return true
        case let .sequence(parts): return parts.isEmpty
        case .block, .scope, .loop: return false
        }
    }
    private func descendants(_ node: PseudocodeRegionNode) -> [PseudocodeRegionNode] {
        [node] + node.children.flatMap(descendants)
    }
}
