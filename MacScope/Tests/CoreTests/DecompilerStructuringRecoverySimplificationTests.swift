import XCTest
@testable import MacScope

final class DecompilerStructuringRecoverySimplificationTests: XCTestCase {
    private func transfers(in node: RegionTree.RecoveryRegion) -> Int {
        switch node {
        case .sequence(let parts): return parts.reduce(0) { $0 + transfers(in: $1) }
        case .block(_, let exits): return exits.reduce(0) { $0 + transfers(in: $1) }
        case .scope(_, let body), .loop(_, let body): return transfers(in: body)
        case .breakTo, .continueAt: return 1
        }
    }

    func testNaturalLoopTailDoesNotNeedContinue() throws {
        let function = CP2GraphFixture.function([[0]])
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let plan = try XCTUnwrap(RegionTree.recoveryPlan(
            cfg: cfg, instructions: function.instructions, options: .recoveryOn,
            veto: .loopShapeUnsupported
        ))
        XCTAssertTrue(RegionTree.recoveryIsEquivalent(plan.root, to: cfg))
        XCTAssertEqual(transfers(in: plan.root), 0,
                       "The loop body's natural tail already returns to its header")
    }
    private func graph(_ edges: [[Int]]) -> CFG {
        CFG(blocks: edges.enumerated().map { index, successors in
            BasicBlock(index: index, startIndex: index, endIndex: index + 1,
                       successors: successors,
                       predecessors: edges.indices.filter { edges[$0].contains(index) },
                       isLoopHeader: false)
        }, entryIndex: 0, domTree: [:], postDomTree: [:], loopHeaders: [],
            backEdges: [], irreducibleBlocks: [], blockByStartIndex: [:],
            hasUnresolvedTargets: false)
    }

    private func scopes(in node: RegionTree.RecoveryRegion) -> Int {
        switch node {
        case .sequence(let parts): return parts.reduce(0) { $0 + scopes(in: $1) }
        case .block(_, let exits): return exits.reduce(0) { $0 + scopes(in: $1) }
        case .scope(_, let body): return 1 + scopes(in: body)
        case .loop(_, let body): return scopes(in: body)
        case .breakTo, .continueAt: return 0
        }
    }

    private func simplified(_ root: RegionTree.RecoveryRegion, edges: [[Int]],
                            file: StaticString = #filePath, line: UInt = #line) throws -> RegionTree.RecoveryRegion {
        let cfg = graph(edges)
        XCTAssertTrue(RegionTree.recoveryIsEquivalent(root, to: cfg), file: file, line: line)
        let result = try XCTUnwrap(RegionTree.simplifiedRecovery(root, to: cfg), file: file, line: line)
        XCTAssertTrue(RegionTree.recoveryIsEquivalent(result, to: cfg), file: file, line: line)
        return result
    }

    func testTailBreakAndItsUnusedScopeDisappearTogether() throws {
        let root: RegionTree.RecoveryRegion = .sequence([
            .scope(target: 1, body: .block(0, exits: [.breakTo(1)])),
            .block(1, exits: [])
        ])
        let result = try simplified(root, edges: [[1], []])
        XCTAssertEqual(transfers(in: result), 0)
        XCTAssertEqual(scopes(in: result), 0)
    }

    func testEmptySequenceDoesNotHideNaturalLoopTail() throws {
        let root: RegionTree.RecoveryRegion = .loop(header: 0, body: .sequence([
            .block(0, exits: [.continueAt(0)]), .sequence([])
        ]))
        let result = try simplified(root, edges: [[0]])
        XCTAssertEqual(transfers(in: result), 0)
    }

    func testGuardSuffixMovesOnceWithoutChangingBranchPolarity() throws {
        for takenSkips in [true, false] {
            let exits: [RegionTree.RecoveryRegion] = takenSkips
                ? [.breakTo(2), .sequence([])] : [.sequence([]), .breakTo(2)]
            let root: RegionTree.RecoveryRegion = .sequence([
                .scope(target: 2, body: .sequence([
                    .block(0, exits: exits), .block(1, exits: [.sequence([])])
                ])),
                .block(2, exits: [])
            ])
            let result = try simplified(root, edges: [takenSkips ? [2, 1] : [1, 2], [2], []])
            XCTAssertEqual(transfers(in: result), 0)
            XCTAssertEqual(scopes(in: result), 0)
            guard case .sequence(let parts) = result, parts.count == 2,
                  case .block(0, let rewrittenExits) = parts[0],
                  case .block(1, _) = rewrittenExits[takenSkips ? 1 : 0] else {
                return XCTFail("The suffix must occur only in its original branch arm")
            }
        }
    }

    func testScopeStartsAtFirstRegionThatUsesItsLabel() throws {
        let root: RegionTree.RecoveryRegion = .sequence([
            .scope(target: 2, body: .sequence([
                .block(0, exits: [.sequence([])]),
                .loop(header: 1, body: .block(1, exits: [.continueAt(1), .breakTo(2)]))
            ])), .block(2, exits: [])
        ])
        let result = try simplified(root, edges: [[1], [1, 2], []])
        XCTAssertEqual(scopes(in: result), 1, "The loop still needs its outer exit binding")
        XCTAssertEqual(transfers(in: result), 1, "Only the natural loop-tail continue disappears")
        guard case .sequence(let parts) = result, parts.count == 3,
              case .block(0, _) = parts[0], case .scope(2, _) = parts[1] else {
            return XCTFail("The straight-line prefix should be outside the labelled scope")
        }
    }

    func testInnerLoopDoesNotConsumeOuterContinue() throws {
        let root: RegionTree.RecoveryRegion = .loop(header: 0, body: .sequence([
            .block(0, exits: [.sequence([])]),
            .loop(header: 1, body: .block(1, exits: [.continueAt(0), .continueAt(1)]))
        ]))
        let result = try simplified(root, edges: [[1], [0, 1]])
        XCTAssertEqual(transfers(in: result), 1)
        let wrong: RegionTree.RecoveryRegion = .loop(header: 0, body: .sequence([
            .block(0, exits: [.sequence([])]),
            .loop(header: 1, body: .block(1, exits: [.sequence([]), .sequence([])]))
        ]))
        XCTAssertFalse(RegionTree.recoveryIsEquivalent(wrong, to: graph([[1], [0, 1]])))
    }

    func testLoopGuardUsesItsNaturalBackedgeWithoutDuplicatingSuffix() throws {
        let root: RegionTree.RecoveryRegion = .loop(header: 0, body: .sequence([
            .block(0, exits: [.continueAt(0), .sequence([])]),
            .block(1, exits: [.continueAt(0)])
        ]))
        let result = try simplified(root, edges: [[0, 1], [0]])
        XCTAssertEqual(transfers(in: result), 0)
    }

    func testMalformedInputCannotBeRepairedIntoAnAcceptedPlan() {
        let cfg = graph([[1], []])
        let malformed: [RegionTree.RecoveryRegion] = [
            .sequence([.block(0, exits: [.breakTo(1)]), .block(1, exits: [])]),
            .sequence([.block(0, exits: [.continueAt(0)]), .block(1, exits: [])]),
            .block(1, exits: []),
            .sequence([.block(0, exits: [.sequence([])]), .block(1, exits: []), .block(1, exits: [])]),
            .sequence([.scope(target: 1, body: .scope(target: 1, body: .block(0, exits: [.breakTo(1)]))),
                       .block(1, exits: [])]),
            .loop(header: 0, body: .sequence([]))
        ]
        for root in malformed {
            XCTAssertFalse(RegionTree.recoveryIsEquivalent(root, to: cfg))
            XCTAssertNil(RegionTree.simplifiedRecovery(root, to: cfg))
        }
    }

    func testOverdeepProposalFallsBackToTheOriginalProvenPlan() throws {
        let count = 270
        let root: RegionTree.RecoveryRegion = .sequence([
            .scope(target: count, body: .sequence((0..<count).map { index in
                .block(index, exits: [.breakTo(count), .sequence([])])
            })),
            .block(count, exits: [])
        ])
        let edges = (0..<count).map { [count, $0 + 1] } + [[]]
        let result = try simplified(root, edges: edges)
        XCTAssertEqual(transfers(in: result), count,
                       "An overdeep nested-guard proposal must retain the proven original")
        XCTAssertEqual(scopes(in: result), 1)
    }

    func testSimplifiedRecoveryPassesIndependentPrintedTextOracle() throws {
        let edges = [[1, 2], [0, 3], [], []]
        let function = CP2GraphFixture.function(edges)
        let document = PseudocodePrinter(options: .recoveryForSemantics).print(function: function)
        XCTAssertNil(document.structureFallback)
        _ = try CP2TextOracle.parse(document, edges: edges)
        XCTAssertTrue(CP2TextOracle.equivalent(document, edges: edges))
    }

    func testPrivateSiblingArmFoldsOnceAndLeavesSharedJoinOutside() throws {
        for privateArm in [0, 1] {
            let otherArm: RegionTree.RecoveryRegion = .block(1, exits: [.breakTo(3), .breakTo(4)])
            let root: RegionTree.RecoveryRegion = .sequence([
                .scope(target: 4, body: .sequence([
                    .scope(target: 3, body: .sequence([
                        .block(0, exits: privateArm == 0
                            ? [.sequence([]), otherArm] : [otherArm, .sequence([])]),
                        .block(2, exits: [.breakTo(4), .sequence([])])
                    ])),
                    .block(3, exits: [.sequence([])])
                ])),
                .block(4, exits: [])
            ])
            let cfg = graph([privateArm == 0 ? [2, 1] : [1, 2], [3, 4], [4, 3], [4], []])
            let folded = try XCTUnwrap(RegionTree.ssaPrivateArmRecovery(root, to: cfg))
            XCTAssertTrue(RegionTree.recoveryIsEquivalent(folded, to: cfg),
                          "Folding retains both ordered conditional routes")
            let result = try XCTUnwrap(RegionTree.simplifiedRecovery(folded, to: cfg))
            XCTAssertTrue(RegionTree.recoveryIsEquivalent(result, to: cfg),
                          "Lexical simplification preserves every original edge")
            XCTAssertEqual(transfers(in: root), 3)
            XCTAssertEqual(transfers(in: result), 2,
                           "The other arm can now fall through to the shared join")
            var occurrences: [Int] = []
            var branchExits: [RegionTree.RecoveryRegion] = []
            func visit(_ node: RegionTree.RecoveryRegion) {
                switch node {
                case let .sequence(parts): parts.forEach(visit)
                case let .block(block, exits):
                    occurrences.append(block)
                    if block == 0 { branchExits = exits }
                    exits.forEach(visit)
                case let .scope(_, body), let .loop(_, body): visit(body)
                case .breakTo, .continueAt: break
                }
            }
            visit(result)
            XCTAssertEqual(occurrences.sorted(), [0, 1, 2, 3, 4],
                           "Neither arm payload nor the shared continuation is duplicated")
            guard branchExits.count == 2, case .block(2, _) = branchExits[privateArm],
                  case .block(1, _) = branchExits[1 - privateArm] else {
                return XCTFail("Only the private sibling moves, into its original branch ordinal")
            }
        }
    }

    func testPrivateSiblingFoldRejectsSharedEntryAndLoopPrefix() throws {
        let shared: RegionTree.RecoveryRegion = .sequence([
            .block(0, exits: [.block(1, exits: [.sequence([])]), .sequence([])]),
            .block(2, exits: [])
        ])
        let cfg = graph([[1, 2], [2], []])
        let retained = try XCTUnwrap(RegionTree.ssaPrivateArmRecovery(shared, to: cfg))
        guard case let .sequence(parts) = retained, parts.count == 2,
              case let .block(0, exits) = parts[0],
              case let .sequence(empty) = exits[1] else {
            return XCTFail("A sibling with another incoming edge must stay outside both arms")
        }
        XCTAssertTrue(empty.isEmpty)
        let looping: RegionTree.RecoveryRegion = .sequence([
            .scope(target: 2, body: .sequence([
                .block(0, exits: [.breakTo(2), .sequence([])]),
                .loop(header: 1, body: .block(1, exits: [.continueAt(1), .breakTo(2)]))
            ])),
            .block(2, exits: [])
        ])
        let loopCFG = graph([[2, 1], [1, 2], []])
        let loopResult = try XCTUnwrap(RegionTree.ssaPrivateArmRecovery(looping, to: loopCFG))
        XCTAssertTrue(RegionTree.recoveryIsEquivalent(loopResult, to: loopCFG))
        XCTAssertEqual(transfers(in: loopResult), transfers(in: looping),
                       "A loop prefix keeps its existing scopes and transfers")
    }

    func testPrivateArmRecoveryExposesNestedScopeBeforeFoldingSibling() throws {
        let root: RegionTree.RecoveryRegion = .sequence([
            .scope(target: 4, body: .sequence([
                .scope(target: 3, body: .sequence([
                    .scope(target: 2, body: .sequence([
                        .block(0, exits: [.breakTo(2), .sequence([])]),
                        .block(1, exits: [.breakTo(3), .breakTo(4)])
                    ])),
                    .block(2, exits: [.breakTo(4), .sequence([])])
                ])),
                .block(3, exits: [.sequence([])])
            ])),
            .block(4, exits: [])
        ])
        let cfg = graph([[2, 1], [3, 4], [4, 3], [4], []])
        let result = try XCTUnwrap(RegionTree.simplifiedSSARecovery(root, to: cfg))
        XCTAssertTrue(RegionTree.recoveryIsEquivalent(result, to: cfg),
                      "Scope normalization and arm folding retain all ordered original edges")
        XCTAssertEqual(transfers(in: result), 2,
                       "The arm exposed by removing the inner scope must consume its private sibling")
        var blocks: [Int] = []
        func visit(_ node: RegionTree.RecoveryRegion) {
            switch node {
            case let .sequence(parts): parts.forEach(visit)
            case let .block(block, exits): blocks.append(block); exits.forEach(visit)
            case let .scope(_, body), let .loop(_, body): visit(body)
            case .breakTo, .continueAt: break
            }
        }
        visit(result)
        XCTAssertEqual(blocks.sorted(), [0, 1, 2, 3, 4],
                       "No original block is duplicated or removed while scopes are normalized")
    }

    func testPrivateSwitchHandlersMoveAcrossScopesWithoutDuplicatingSharedJoin() throws {
        let root: RegionTree.RecoveryRegion = .sequence([
            .scope(target: 4, body: .sequence([
                .scope(target: 3, body: .sequence([
                    .scope(target: 2, body: .sequence([
                        .scope(target: 1, body: .block(0, exits: [
                            .breakTo(3), .breakTo(1), .breakTo(2)
                        ])),
                        .block(1, exits: [.breakTo(4)])
                    ])),
                    .block(2, exits: [.breakTo(4)])
                ])),
                .block(3, exits: [.sequence([])])
            ])),
            .block(4, exits: [])
        ])
        let cfg = graph([[3, 1, 2], [4], [4], [4], []])
        let result = try XCTUnwrap(RegionTree.simplifiedSSARecovery(root, to: cfg))
        XCTAssertTrue(RegionTree.recoveryIsEquivalent(result, to: cfg),
                      "Noncontiguous handlers keep their original ordered successor edges")
        XCTAssertEqual(transfers(in: result), 0,
                       "Each private handler is lexical inside its original arm; the join stays outside")
        XCTAssertEqual(scopes(in: result), 0)
        guard case let .sequence(parts) = result, parts.count == 2,
              case let .block(0, exits) = parts[0], exits.count == 3,
              case .block(3, _) = exits[0], case .block(1, _) = exits[1],
              case .block(2, _) = exits[2], case .block(4, _) = parts[1] else {
            return XCTFail("Each handler must occur once in its original arm, with one shared continuation")
        }
    }

    func testNoncontiguousPrivateArmKeepsAliasedEntryAndLoopOutside() throws {
        let root: RegionTree.RecoveryRegion = .sequence([
            .scope(target: 3, body: .sequence([
                .scope(target: 2, body: .sequence([
                    .scope(target: 1, body: .block(0, exits: [
                        .breakTo(1), .breakTo(1), .breakTo(2)
                    ])),
                    .block(1, exits: [.breakTo(3)])
                ])),
                .loop(header: 2, body: .block(2, exits: [.continueAt(2), .breakTo(3)]))
            ])),
            .block(3, exits: [])
        ])
        let cfg = graph([[1, 1, 2], [3], [2, 3], []])
        let result = try XCTUnwrap(RegionTree.ssaPrivateArmRecovery(root, to: cfg))
        XCTAssertTrue(RegionTree.recoveryIsEquivalent(result, to: cfg))
        XCTAssertEqual(transfers(in: result), transfers(in: root),
                       "Aliased switch entries cannot duplicate a handler; loop ownership is excluded")
        XCTAssertEqual(scopes(in: result), scopes(in: root))
    }

    private func loopGraph(_ edges: [[Int]], backEdges: [(Int, Int)]) -> CFG {
        var cfg = graph(edges)
        cfg.backEdges = Set(backEdges.map { CFGEdge($0.0, $0.1) })
        cfg.loopHeaders = Set(backEdges.map(\.1))
        return cfg
    }

    private func blocks(in node: RegionTree.RecoveryRegion) -> [Int] {
        switch node {
        case let .sequence(parts): return parts.flatMap(blocks)
        case let .block(block, exits): return [block] + exits.flatMap(blocks)
        case let .scope(_, body), let .loop(_, body): return blocks(in: body)
        case .breakTo, .continueAt: return []
        }
    }

    private func exits(of target: Int, in node: RegionTree.RecoveryRegion) -> [RegionTree.RecoveryRegion]? {
        switch node {
        case let .sequence(parts):
            for part in parts { if let found = exits(of: target, in: part) { return found } }
        case let .block(block, exits):
            if block == target { return exits }
            for exit in exits { if let found = self.exits(of: target, in: exit) { return found } }
        case let .scope(_, body), let .loop(_, body): return exits(of: target, in: body)
        case .breakTo, .continueAt: break
        }
        return nil
    }

    func testPrivateArmFoldsInsideLoopBody() throws {
        let root: RegionTree.RecoveryRegion = .sequence([
            .scope(target: 4, body: .loop(header: 0, body: .sequence([
                .block(0, exits: [.sequence([])]),
                .scope(target: 3, body: .sequence([
                    .block(1, exits: [.sequence([]), .breakTo(3)]),
                    .block(2, exits: [.sequence([])])
                ])),
                .block(3, exits: [.continueAt(0), .breakTo(4)])
            ]))),
            .block(4, exits: [])
        ])
        let cfg = loopGraph([[1], [2, 3], [3], [0, 4], []], backEdges: [(3, 0)])
        XCTAssertTrue(RegionTree.recoveryIsEquivalent(root, to: cfg))
        let folded = try XCTUnwrap(RegionTree.ssaPrivateArmRecovery(root, to: cfg))
        XCTAssertTrue(RegionTree.recoveryIsEquivalent(folded, to: cfg),
                      "The fold keeps loop header, backedge, exit and ordered successors")
        let branch = try XCTUnwrap(exits(of: 1, in: folded))
        guard branch.count == 2, case .block(2, _) = branch[0] else {
            return XCTFail("The private arm inside the loop body must move into its owning branch")
        }
        XCTAssertEqual(blocks(in: folded).sorted(), [0, 1, 2, 3, 4], "No block is duplicated or lost")
        XCTAssertEqual(transfers(in: folded), transfers(in: root), "Loop transfers are untouched")
        guard case let .sequence(top) = folded, case let .scope(_, scoped) = top[0],
              case .loop(0, _) = scoped else {
            return XCTFail("The loop and its exit binding keep their lexical form")
        }
    }

    func testPrivateArmWithBackedgeSourceDoesNotFoldInLoop() throws {
        let root: RegionTree.RecoveryRegion = .sequence([
            .scope(target: 3, body: .loop(header: 0, body: .sequence([
                .block(0, exits: [.sequence([])]),
                .block(1, exits: [.sequence([]), .breakTo(3)]),
                .block(2, exits: [.sequence([])])
            ]))),
            .block(3, exits: [])
        ])
        let cfg = loopGraph([[1], [2, 3], [0], []], backEdges: [(2, 0)])
        XCTAssertTrue(RegionTree.recoveryIsEquivalent(root, to: cfg))
        let result = try XCTUnwrap(RegionTree.ssaPrivateArmRecovery(root, to: cfg))
        let branch = try XCTUnwrap(exits(of: 1, in: result))
        guard case let .sequence(arm) = branch[0], arm.isEmpty else {
            return XCTFail("The backedge source stays after its branch, not inside the arm")
        }
        XCTAssertTrue(RegionTree.recoveryIsEquivalent(result, to: cfg))
    }

    func testPrivateArmWithLoopExitSourceDoesNotFoldInLoop() throws {
        let root: RegionTree.RecoveryRegion = .sequence([
            .scope(target: 4, body: .loop(header: 0, body: .sequence([
                .block(0, exits: [.sequence([])]),
                .scope(target: 3, body: .sequence([
                    .block(1, exits: [.sequence([]), .breakTo(3)]),
                    .block(2, exits: [.breakTo(3), .breakTo(4)])
                ])),
                .block(3, exits: [.sequence([])])
            ]))),
            .block(4, exits: [])
        ])
        let cfg = loopGraph([[1], [2, 3], [3, 4], [0], []], backEdges: [(3, 0)])
        XCTAssertTrue(RegionTree.recoveryIsEquivalent(root, to: cfg))
        let result = try XCTUnwrap(RegionTree.ssaPrivateArmRecovery(root, to: cfg))
        let branch = try XCTUnwrap(exits(of: 1, in: result))
        guard case let .sequence(arm) = branch[0], arm.isEmpty else {
            return XCTFail("A block with an edge leaving the loop must not move into an arm")
        }
        XCTAssertTrue(RegionTree.recoveryIsEquivalent(result, to: cfg))
    }

    func testArmReachingBlockSharedWithAnotherArmDoesNotFoldInLoop() throws {
        let root: RegionTree.RecoveryRegion = .sequence([
            .scope(target: 5, body: .loop(header: 0, body: .sequence([
                .block(0, exits: [.sequence([])]),
                .scope(target: 2, body: .sequence([
                    .block(1, exits: [.breakTo(2), .sequence([])]),
                    .block(3, exits: [.sequence([])])
                ])),
                .block(2, exits: [.sequence([])]),
                .block(4, exits: [.continueAt(0), .breakTo(5)])
            ]))),
            .block(5, exits: [])
        ])
        let cfg = loopGraph([[1], [2, 3], [4], [2], [0, 5], []], backEdges: [(4, 0)])
        XCTAssertTrue(RegionTree.recoveryIsEquivalent(root, to: cfg))
        let result = try XCTUnwrap(RegionTree.ssaPrivateArmRecovery(root, to: cfg))
        XCTAssertTrue(RegionTree.recoveryIsEquivalent(result, to: cfg))
        let branch = try XCTUnwrap(exits(of: 1, in: result))
        XCTAssertFalse(branch.flatMap(blocks).contains(2),
                       "A block with predecessors in both arms stays outside every arm")
        XCTAssertEqual(blocks(in: result).sorted(), [0, 1, 2, 3, 4, 5])
    }

}
