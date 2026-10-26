import Darwin
import XCTest
@testable import MacScope

final class SnapshotBuiltFunctionCacheTests: XCTestCase {
    private typealias Key = SnapshotBuiltFunctionCache.Key

    private func key() -> Key {
        Key(snapshotID: UUID(), slot: .primary, startAddress: 0x1000, functionName: "leaf",
            instructions: [InstructionRow(address: 0x1000, bytes: "c0 03 5f d6", mnemonic: "ret",
                                          operands: "", hasBreakpoint: false, comment: nil)])
    }

    private func build(_ key: Key) -> MacIRFunction {
        PseudocodePrinter().buildFunction(functionName: key.functionName, startAddress: key.startAddress,
            jumpTables: key.jumpTables, objcSelectors: key.objcSelectors, constantStrings: key.constantStrings,
            signatureOverrides: key.signatureOverrides,
            authoredCallSignaturesByTarget: key.authoredCallSignaturesByTarget,
            directCallVoidResultTargets: key.directCallVoidResultTargets, slotCallContracts: key.slotCallContracts,
            callerReturnWidth: key.callerReturnWidth, callerReturnType: key.callerReturnType,
            types: key.types, explicitCFGEnabled: key.explicitCFGEnabled,
            ssaEnabled: key.ssaEnabled, instructions: key.instructions)
    }

    func testEqualKeyReusesCompletedFunction() throws {
        let cache = SnapshotBuiltFunctionCache()
        let first = key()
        var buildCount = 0
        var functions: [MacIRFunction] = []
        for input in [first, first] {
            if let function = cache.function(for: input) {
                functions.append(function)
            } else {
                buildCount += 1
                let function = build(input)
                cache.record(function, for: input)
                functions.append(function)
            }
        }
        XCTAssertEqual(buildCount, 1)
        XCTAssertEqual(functions[0], functions[1])
        // Caller/contract copies must not mutate the cached original.
        functions[1].instructions[0].source.operands = "changed caller copy"
        XCTAssertEqual(try XCTUnwrap(cache.function(for: first)).instructions[0].source.operands, "")
        XCTAssertNil(SnapshotBuiltFunctionCache().function(for: first), "another call tree starts cold")
    }

    func testEachEffectiveArgumentAndIdentityChangeMisses() {
        let cache = SnapshotBuiltFunctionCache()
        let base = key()
        cache.record(build(base), for: base)
        let signature = FunctionSignatureOverride(returnType: "int")
        let changes: [(String, (inout Key) -> Void)] = [
            ("snapshot revision", { $0.snapshotID = UUID() }),
            ("slot", { $0.slot = ImageSlot(rawValue: 1) }),
            ("start", { $0.startAddress += 4 }),
            ("functionName", { $0.functionName = "renamed" }),
            ("jumpTables", { $0.jumpTables = [0x1000: [0x1010, 0x1020]] }),
            ("objcSelectors", { $0.objcSelectors = [0x2000: "selector:"] }),
            ("constantStrings", { $0.constantStrings = [0x2000: .init(text: "text", kind: .cString)] }),
            ("selected signature", { $0.signatureOverrides[0x1000] = signature }),
            ("other signature", { $0.signatureOverrides[0x2000] = signature }),
            ("authored signatures", { $0.authoredCallSignaturesByTarget["callee"] = signature }),
            ("direct void targets", { $0.directCallVoidResultTargets["callee"] = .init(returnType: "void") }),
            ("slot contracts", { $0.slotCallContracts[0x1000] = .init(returnType: "int", parameters: []) }),
            ("caller width", { $0.callerReturnWidth = .x0 }),
            ("caller type", { $0.callerReturnType = "void" }),
            ("types", { $0.types = [.init(kind: .struct, name: "Record")] }),
            ("rows", { $0.instructions[0].operands = "x30" }),
            ("structured operands", { $0.instructions[0].structuredOperands = .init(coverage: .partial) }),
            ("SSA mode", { $0.ssaEnabled.toggle() }),
            ("CFG mode", { $0.explicitCFGEnabled.toggle() })
        ]
        for (label, change) in changes {
            var changed = base
            change(&changed)
            XCTAssertNotEqual(base, changed, label)
            XCTAssertNil(cache.function(for: changed), label)
        }
        XCTAssertNotNil(cache.function(for: base))
    }

    func testFullSignatureMapAndWidthDiscriminateEnrichedAuthority() {
        let cache = SnapshotBuiltFunctionCache()
        var base = key()
        base.signatureOverrides[0x2000] = .init(returnType: "int")
        cache.record(build(base), for: base)
        var selected = base
        selected.signatureOverrides[base.startAddress] = .init(returnType: "void")
        XCTAssertNil(cache.function(for: selected))
        var other = base
        other.signatureOverrides[0x2000] = .init(returnType: "long")
        XCTAssertNil(cache.function(for: other))
        for width in [MacIRCallerReturnEvidence.Width.w0, .x0] {
            var enriched = base
            enriched.callerReturnWidth = width
            XCTAssertNil(cache.function(for: enriched))
        }
        cache.record(build(selected), for: selected)
        XCTAssertNotNil(cache.function(for: selected))
        XCTAssertNil(cache.function(for: base))
    }

    func testOrderedTypesAndRowsAndJumpTargetsCannotAlias() {
        let cache = SnapshotBuiltFunctionCache()
        var base = key()
        base.types = [.init(kind: .struct, name: "Duplicate"), .init(kind: .union, name: "Duplicate")]
        var next = base.instructions[0]
        next.address += 4
        base.instructions.append(next)
        base.jumpTables = [0x1000: [0x1004, 0x1008]]
        cache.record(build(base), for: base)
        var changed = base
        changed.types.reverse()
        XCTAssertNil(cache.function(for: changed))
        changed = base
        changed.instructions.reverse()
        XCTAssertNil(cache.function(for: changed))
        changed = base
        changed.jumpTables[0x1000]?.reverse()
        XCTAssertNil(cache.function(for: changed))
    }

    func testCensusBypassesLookupAndInsertionEvenForEmptyOutputValue() {
        let input = key()
        let function = build(input)
        var normal = ProcessInfo.processInfo.environment
        normal.removeValue(forKey: "MACSCOPE_C2_OUT")
        for output in ["", "/unused/census"] {
            let cache = SnapshotBuiltFunctionCache()
            var census = normal
            census["MACSCOPE_C2_OUT"] = output
            cache.record(function, for: input, environment: census)
            XCTAssertNil(cache.function(for: input, environment: normal))
            cache.record(function, for: input, environment: normal)
            XCTAssertNil(cache.function(for: input, environment: census))
            XCTAssertNotNil(cache.function(for: input, environment: normal))
        }
    }

    func testCancellationBypassesHitsAndAdmission() {
        let cache = SnapshotBuiltFunctionCache()
        let input = key()
        let function = build(input)
        cache.record(function, for: input, isCancelled: true)
        XCTAssertNil(cache.function(for: input))
        cache.record(function, for: input)
        XCTAssertNil(cache.function(for: input, isCancelled: true))
        XCTAssertNotNil(cache.function(for: input))
        var cancelled = function
        cancelled.refusals.append(.init(reason: .cancelled, scope: .function, detail: nil))
        let fresh = key()
        cache.record(cancelled, for: fresh)
        XCTAssertNil(cache.function(for: fresh))
    }

    func testCachedAndUncachedOptionSetsPreserveRefusalsAndJumpTableEdges() throws {
        try MacIRConfiguration.$explicitCFGOverride.withValue(true) {
            var input = key()
            input.instructions = [("mov", "x1, #7"), ("br", "x8"),
                                  ("mov", "x0, x1"), ("ret", "")].enumerated().map { index, row in
                InstructionRow(address: 0x1000 + UInt64(index * 4), bytes: "00 00 00 00",
                               mnemonic: row.0, operands: row.1, hasBreakpoint: false, comment: nil)
            }
            // Preserve duplicate case order and an external case with no owned block.
            input.jumpTables = [0x1004: [0x1008, 0x2000, 0x1008]]
            let cache = SnapshotBuiltFunctionCache()
            var previous: Key?
            for ssa in [false, true] {
                try MacIRConfiguration.$ssaOverride.withValue(ssa) {
                    let captured = key()
                    XCTAssertEqual(captured.ssaEnabled, ssa)
                    XCTAssertTrue(captured.explicitCFGEnabled)
                    input.ssaEnabled = captured.ssaEnabled
                    input.explicitCFGEnabled = captured.explicitCFGEnabled
                    XCTAssertNil(cache.function(for: input), "a different option set must build afresh")
                    let uncached = build(input)
                    cache.record(uncached, for: input)
                    let cached = try XCTUnwrap(cache.function(for: input))
                    XCTAssertEqual(cached, build(input))
                    XCTAssertEqual(cached.refusals, uncached.refusals)
                    XCTAssertEqual(cached.cfg, uncached.cfg)
                    let graph = try XCTUnwrap(cached.cfg)
                    let dispatch = try XCTUnwrap(graph.blocks.first { $0.startAddress == 0x1000 })
                    XCTAssertEqual(dispatch.successors.map(\.kind), [.jumpTable, .jumpTable, .jumpTable])
                    XCTAssertEqual(dispatch.successors.map(\.label), [0, 1, 2])
                    XCTAssertNil(dispatch.successors[1].to)
                    XCTAssertTrue(cached.refusals.contains { $0.reason == .targetOutsideFunction })
                    if ssa {
                        XCTAssertTrue(cached.refusals.contains { $0.reason == .jumpTableOutsideFunction })
                    }
                    if let previous { XCTAssertNil(cache.function(for: previous)) }
                    previous = input
                }
            }
        }
    }

    func testBuildUsesCapturedModesWhenDefaultsChangeAfterKeyCreation() throws {
        MacIRConfiguration.$ssaOverride.withValue(false) {
            MacIRConfiguration.$explicitCFGOverride.withValue(false) {
                let input = key()
                XCTAssertFalse(input.ssaEnabled)
                XCTAssertFalse(input.explicitCFGEnabled)
                MacIRConfiguration.$ssaOverride.withValue(true) {
                    MacIRConfiguration.$explicitCFGOverride.withValue(true) {
                        let changed = key()
                        XCTAssertTrue(changed.ssaEnabled)
                        XCTAssertTrue(changed.explicitCFGEnabled)
                        let function = build(input)
                        XCTAssertFalse(function.ssaEnabled)
                        XCTAssertNil(function.cfg, "a build must use the modes in its key, not resample defaults")
                        let cache = SnapshotBuiltFunctionCache()
                        cache.record(function, for: input)
                        XCTAssertNil(cache.function(for: input), "changed ambient modes still bypass admission")
                    }
                }
            }
        }
    }

    func testDisabledPhaseClockIsSilent() throws {
        XCTAssertNotEqual(ProcessInfo.processInfo.environment["MACSCOPE_PERF_PHASES"], "1",
                          "This focused selector requires the clock's default, disabled environment")
        fflush(stdout)
        let pipe = Pipe()
        let saved = dup(STDOUT_FILENO)
        XCTAssertGreaterThanOrEqual(saved, 0)
        guard saved >= 0 else { return }
        let redirected = dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        XCTAssertGreaterThanOrEqual(redirected, 0)
        let token = MacScopePerfPhaseClock.begin("test.disabled", function: 0x1000)
        MacScopePerfPhaseClock.end(token)
        fflush(stdout)
        _ = dup2(saved, STDOUT_FILENO)
        close(saved)
        try pipe.fileHandleForWriting.close()
        XCTAssertNil(token)
        XCTAssertEqual(pipe.fileHandleForReading.readDataToEndOfFile(), Data())
    }
}
