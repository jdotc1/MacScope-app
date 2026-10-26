import XCTest
@testable import MacScope

final class ReturnContractTableTests: XCTestCase {
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


    private typealias Facts = ReturnContractTable.LocalFacts
    private typealias Producer = BuilderState.ReturnContractProducer
    private let a: UInt64 = 0x1000
    private let b: UInt64 = 0x2000
    private let c: UInt64 = 0x3000
    private let d: UInt64 = 0x4000

    private func header(_ kind: ReturnContract.Kind) -> ReturnContract {
        .init(kind: kind, tier: .header, evidence: [.init(source: .header, at: nil, detail: "declared")])
    }

    private func site(_ caller: UInt64, _ target: UInt64,
                      _ consumption: CallSiteContract.Consumption = .discarded,
                      tail: Bool = false) -> CallSiteContract {
        .init(address: caller, target: .direct(target), consumption: consumption, isTailCall: tail)
    }

    private func build(_ facts: [UInt64: Facts], sites: [UInt64: [CallSiteContract]] = [:],
                       exported: Set<UInt64> = [], addressTaken: Set<UInt64> = [], complete: Bool = true,
                       file: StaticString = #filePath, line: UInt = #line) -> ReturnContractTable {
        let key = ReturnContractTable.Key(snapshotID: UUID(), slot: .primary)
        let image = ImageFacts(functionStarts: Set(facts.keys), exported: exported, addressTaken: addressTaken,
            closedWorldGuards: ["complete": complete], imageComplete: complete)
        let forward = ReturnContractTable.build(key: key, imageFacts: image, localFacts: facts, callSites: sites)
        let reversed = ReturnContractTable.build(key: key, imageFacts: image, localFacts: facts,
            callSites: sites, reverseSeeding: true)
        XCTAssertEqual(forward.entries, reversed.entries, file: file, line: line)
        XCTAssertFalse(forward.report.capExceeded, file: file, line: line)
        XCTAssertFalse(reversed.report.capExceeded, file: file, line: line)
        XCTAssertLessThanOrEqual(forward.report.contractChanges, 8 * facts.count, file: file, line: line)
        XCTAssertLessThanOrEqual(reversed.report.contractChanges, 8 * facts.count, file: file, line: line)
        XCTAssertEqual(forward.entries.count, facts.count, file: file, line: line)
        return forward
    }

    private func spans(_ start: UInt64, _ operations: [(String, String)]) -> [MacIRSourceSpan] {
        operations.enumerated().map {
            .init(address: start + UInt64($0.offset * 4), byteText: "", mnemonic: $0.element.0,
                  operands: $0.element.1)
        }
    }

    private func ir(_ start: UInt64, _ operations: [(String, String)]) -> MacIRFunction {
        let rows = operations.enumerated().map {
            InstructionRow(address: start + UInt64($0.offset * 4), bytes: "", mnemonic: $0.element.0,
                operands: $0.element.1, hasBreakpoint: false, comment: nil)
        }
        return MacIRBuilder().buildFunction(name: "fixture", startAddress: start, instructions: rows)
    }

    func testTailChainsRequireOwnValueConsumptionInBothOrders() {
        let shape = ReturnContract.ReturnShape.gpr(width: 64, type: "int *")
        for kind: ReturnContract.Kind in [.void, .value(shape)] {
            let authority = header(kind)
            let facts = [a: Facts(exits: [.tailCall(b)]), b: Facts(exits: [.tailCall(c)]),
                c: Facts(header: authority, producers: [.load], exits: [.returnInstruction(c)]), d: Facts()]
            let sites = [a: [site(a, b, .flowsToReturn, tail: true)],
                b: [site(b, c, .flowsToReturn, tail: true)], d: [site(d, a)]]
            let table = build(facts, sites: sites)
            for address in [a, b] {
                XCTAssertEqual(table.entries[address]?.kind, kind == .void ? .void : .unresolved(.producerOnly))
                XCTAssertEqual(table.entries[address]?.tier, kind == .void ? .derived : nil)
                if kind != .void {
                    XCTAssertTrue(table.entries[address]?.evidence.contains {
                        $0.source == .producer && $0.detail.contains("int *")
                    } == true)
                }
            }
            XCTAssertEqual(table.entries[c]?.kind, authority.kind)
            XCTAssertEqual(table.entries[c]?.tier, authority.tier)
            XCTAssertTrue(table.entries[c]?.evidence.contains { $0.source == .header } == true)
            if kind != .void {
                var consumed = sites
                consumed[d] = [site(d, a, .read(width: 64, type: "int *"))]
                let read = build(facts, sites: consumed)
                XCTAssertEqual(read.entries[a]?.kind, .value(shape))
                XCTAssertEqual(read.entries[b]?.kind, .value(shape))
            }
        }
    }

    func testCatalogValueTailWithoutConsumerRemainsOpenWorld() {
        let source = spans(a, [("mov", "x0, x2"), ("mov", "w2, w3"), ("b", "0x5869c")])
        let key = ReturnContractTable.Key(snapshotID: UUID(), slot: .primary)
        let image = ImageFacts(functionStarts: [a], addressTaken: [a])
        let facts = [a: Facts(sources: source)]
        let catalog = ReturnContractTable.headerContract(type: "void *", source: .catalog, at: 0x5869c)
        let first = ReturnContractTable.build(key: key, imageFacts: image, localFacts: facts,
            callSites: [:], externalContracts: [0x5869c: catalog])
        let second = ReturnContractTable.build(key: key, imageFacts: image, localFacts: facts,
            callSites: [:], reverseSeeding: true, externalContracts: [0x5869c: catalog])
        XCTAssertEqual(first.entries, second.entries)
        XCTAssertFalse(first.report.capExceeded)
        XCTAssertFalse(second.report.capExceeded)
        XCTAssertEqual(first.entries[a]?.kind, .unresolved(.openWorld))
        XCTAssertNil(first.entries[a]?.tier)
        XCTAssertTrue(first.entries[a]?.evidence.contains {
            $0.source == .producer && $0.detail.contains("void *") && $0.detail.contains("362140")
        } == true)
    }

    func testHeaderVoidBreaksTailCycle() {
        let authority = header(.void)
        let table = build([a: Facts(header: authority, exits: [.tailCall(b)]), b: Facts(exits: [.tailCall(a)])],
            sites: [a: [site(a, b, .flowsToReturn, tail: true)], b: [site(b, a, .flowsToReturn, tail: true)]])
        XCTAssertEqual(table.entries[a]?.kind, .void)
        XCTAssertEqual(table.entries[a]?.tier, .header)
        XCTAssertEqual(table.entries[b]?.kind, .void)
    }

    func testTypedConsumptionFlowsBackThroughReturnedCallee() {
        let table = build([a: Facts(producers: [.load], exits: [.returnInstruction(a)]),
            b: Facts(producers: [.calleeResult(a)], exits: [.returnInstruction(b)]), c: Facts()],
            sites: [b: [site(b, a, .flowsToReturn)], c: [site(c, b, .read(width: 64, type: "int *"))]])
        XCTAssertEqual(table.entries[a]?.kind, .value(.gpr(width: 64, type: "int *")))
        XCTAssertEqual(table.entries[b]?.kind, .value(.gpr(width: 64, type: "int *")))
    }

    func testTailVoidAndTypedReadConflictIsTerminal() {
        let table = build([a: Facts(exits: [.tailCall(b)]), b: Facts(header: header(.void)), c: Facts()],
            sites: [a: [site(a, b, .flowsToReturn, tail: true)], c: [site(c, a, .read(width: 64, type: nil))]])
        XCTAssertEqual(table.entries[a]?.kind, .unresolved(.conflict))
        XCTAssertNil(table.entries[a]?.tier)
        XCTAssertEqual(ReturnContractTable.Cell.conflict.joined(.void), .conflict)
        XCTAssertEqual(ReturnContractTable.Cell.conflict.joined(.value(.gpr(width: 64, type: nil), typeDisputed: false)), .conflict)
    }

    func testTypeDisagreementPublishesWidthAndCannotNarrowAgain() {
        let first = ReturnContractTable.Cell.value(.gpr(width: 64, type: "int *"), typeDisputed: false)
        let second = ReturnContractTable.Cell.value(.gpr(width: 64, type: "char *"), typeDisputed: false)
        let disputed = ReturnContractTable.Cell.value(.gpr(width: 64, type: nil), typeDisputed: true)
        XCTAssertEqual(first.joined(second), disputed)
        XCTAssertEqual(second.joined(first), disputed)
        XCTAssertEqual(disputed.joined(first), disputed)
        XCTAssertEqual(disputed.kind, .value(.gpr(width: 64, type: nil)))
        let table = build([a: Facts(producers: [.load]), b: Facts(), c: Facts()], sites: [
            b: [site(b, a, .read(width: 64, type: "int *"))],
            c: [site(c, a, .read(width: 64, type: "char *"))]])
        XCTAssertEqual(table.entries[a]?.kind, .value(.gpr(width: 64, type: nil)))
        XCTAssertEqual(table.entries[a]?.tier, .derived)
    }

    func testWidthAndRegisterClassDisagreementConflict() {
        let wide = ReturnContractTable.Cell.value(.gpr(width: 64, type: nil), typeDisputed: false)
        let narrow = ReturnContractTable.Cell.value(.gpr(width: 32, type: nil), typeDisputed: false)
        let floating = ReturnContractTable.Cell.value(.fpr(width: 64, type: nil), typeDisputed: false)
        XCTAssertEqual(wide.joined(narrow), .conflict)
        XCTAssertEqual(narrow.joined(wide), .conflict)
        XCTAssertEqual(wide.joined(floating), .conflict)
        XCTAssertEqual(wide.joined(.void), .conflict)
        XCTAssertEqual(ReturnContractTable.Cell.pending.joined(wide), wide)
        XCTAssertEqual(wide.joined(.pending), wide)
    }

    func testImmutableAuthorityRecordsDerivedDisagreement() {
        let table = build([a: Facts(header: header(.void), producers: [.constant]), b: Facts()],
            sites: [b: [site(b, a, .read(width: 64, type: nil))]])
        XCTAssertEqual(table.entries[a]?.kind, .void)
        XCTAssertEqual(table.entries[a]?.tier, .header)
        XCTAssertTrue(table.entries[a]?.evidence.contains { $0.detail.contains("conflict") } == true)
    }

    func testDiscardAndProducerAloneGrantNoReturnAuthority() {
        let table = build([a: Facts(producers: [.unknown]), b: Facts(), c: Facts(producers: [.constant])],
            sites: [b: [site(b, a), site(b + 4, c)]])
        XCTAssertEqual(table.entries[a]?.kind, .unresolved(.directOnlyPrivate))
        XCTAssertEqual(table.entries[c]?.kind, .unresolved(.producerOnly))
    }

    func testClosedWorldDiscardCertificateIsNotTypeAuthority() {
        let facts: [UInt64: Facts] = [a: Facts(producers: [.unknown], closedWorldVoid: true, requiresImageGuard: true), b: Facts()]
        let sites = [b: [site(b, a)]]
        let admitted = build(facts, sites: sites)
        XCTAssertEqual(admitted.entries[a]?.kind, .unresolved(.directOnlyPrivate))
        XCTAssertNil(admitted.entries[a]?.tier)
        XCTAssertTrue(admitted.entries[a]?.evidence.contains {
            $0.source == .discard && $0.at == a
                && $0.detail == "closed-world discard does not establish a void return type"
        } == true)
        let refused = build(facts, sites: sites, complete: false)
        XCTAssertEqual(refused.entries[a]?.kind, .unresolved(.imageGuard))
    }

    func testOpenWorldStillAcceptsTypedInternalConsumers() {
        let table = build([a: Facts(producers: [.load]), b: Facts()],
            sites: [b: [site(b, a, .read(width: 32, type: "uint32_t"))]], exported: [a], addressTaken: [a])
        XCTAssertEqual(table.entries[a]?.kind, .value(.gpr(width: 32, type: "uint32_t")))
    }

    func testCalleeResultOnlyRefinesAnIndependentValueContract() {
        let shape = ReturnContract.ReturnShape.gpr(width: 64, type: "size_t")
        let facts = [a: Facts(header: header(.value(shape)), producers: [.load]),
            b: Facts(sources: spans(b, [("bl", "0x1000"), ("ret", "")])),
            c: Facts(producers: [.calleeResult(a), .constant]), d: Facts()]
        var sites = [b: [site(b, a, .flowsToReturn)], c: [site(c, a, .flowsToReturn)],
            d: [site(d, b), site(d + 4, c)]]
        let unread = build(facts, sites: sites)
        XCTAssertEqual(unread.entries[b]?.kind, .unresolved(.producerOnly))
        XCTAssertEqual(unread.entries[c]?.kind, .unresolved(.producerOnly))
        XCTAssertTrue(unread.entries[b]?.evidence.contains {
            $0.source == .producer && $0.detail.contains("size_t")
        } == true)
        sites[d] = [site(d, b, .read(width: 64, type: nil)), site(d + 4, c)]
        let read = build(facts, sites: sites)
        XCTAssertEqual(read.entries[b]?.kind, .value(shape))
        XCTAssertEqual(read.report.rawReadOnlyValues.map(\.address), [b])
        XCTAssertEqual(read.report.rawReadOnlyValues.first?.readSites.map(\.callSite), [d])
        XCTAssertEqual(read.report.assumptions, ["no interprocedural register allocation"])
        XCTAssertTrue(read.entries[b]?.evidence.contains {
            $0.detail == "assumption: no interprocedural register allocation"
        } == true)
        sites[d] = [site(d, b, .read(width: 64, type: "size_t")), site(d + 4, c)]
        let typed = build(facts, sites: sites)
        XCTAssertEqual(typed.entries[b]?.kind, .value(shape))
        XCTAssertTrue(typed.report.rawReadOnlyValues.isEmpty)
    }

    func testProducerConsistencyAndParameterPassthrough() {
        let value = header(.value(.gpr(width: 64, type: nil)))
        for producers: Set<Producer> in [[.unknown], [.passthroughParameter], []] {
            let table = build([a: Facts(producers: producers, exits: [.returnInstruction(a)]), b: Facts()],
                sites: [b: [site(b, a, .read(width: 64, type: "int64_t"))]])
            XCTAssertEqual(table.entries[a]?.kind, .unresolved(.contractWithoutProducer))
            XCTAssertNil(table.entries[a]?.tier)
            XCTAssertTrue(table.entries[a]?.evidence.contains { $0.source == .consumer } == true)
        }
        let admitted = build([a: Facts(header: value, producers: [.passthroughParameter],
            exits: [.returnInstruction(a)], hasX0Parameter: true)])
        XCTAssertEqual(admitted.entries[a]?.kind, value.kind)
        XCTAssertEqual(admitted.entries[a]?.tier, .header)
    }

    func testHeaderValueKeepsAuthorityWithoutNameableProducer() {
        let value = header(.value(.gpr(width: 64, type: "int64_t")))
        for producers: Set<Producer> in [[.unknown], [.passthroughParameter], []] {
            for lifted in [true, false] {
                let table = build([a: Facts(header: value, producers: producers,
                    exits: [.returnInstruction(a)], lifted: lifted)])
                XCTAssertEqual(table.entries[a]?.kind, value.kind)
                XCTAssertEqual(table.entries[a]?.tier, .header)
                XCTAssertTrue(table.entries[a]?.evidence.contains {
                    $0.source == .producer && $0.at == a && $0.detail == "unknown"
                } == true)
                XCTAssertTrue(table.entries[a]?.evidence.contains { $0.source == .header } == true)
            }
        }
    }

    func testRawObservationsDoNotConflictWithDeclaredWidths() {
        let narrow = ReturnContract.Kind.value(.gpr(width: 32, type: "int"))
        let mixed = build([a: Facts(producers: [.load]), b: Facts(), c: Facts()], sites: [
            b: [site(b, a, .read(width: 64, type: nil))],
            c: [site(c, a, .read(width: 32, type: "int"))]])
        XCTAssertEqual(mixed.entries[a]?.kind, narrow)
        let inherited = build([a: Facts(exits: [.tailCall(b)]),
            b: Facts(header: header(narrow), producers: [.load]), c: Facts()], sites: [
            a: [site(a, b, .flowsToReturn, tail: true)],
            c: [site(c, a, .read(width: 64, type: nil))]])
        XCTAssertEqual(inherited.entries[a]?.kind, narrow)
        let conflicting = build([a: Facts(exits: [.tailCall(b)]),
            b: Facts(header: header(narrow), producers: [.load]), c: Facts()], sites: [
            a: [site(a, b, .flowsToReturn, tail: true)],
            c: [site(c, a, .read(width: 64, type: "int64_t"))]])
        XCTAssertEqual(conflicting.entries[a]?.kind, .value(.gpr(width: 64, type: "int64_t")))
        XCTAssertTrue(conflicting.entries[a]?.evidence.contains {
            $0.source == .producer && $0.detail.contains("width: 32")
        } == true)
        let declared = build([a: Facts(producers: [.load]), b: Facts(), c: Facts()], sites: [
            b: [site(b, a, .read(width: 64, type: "int64_t"))],
            c: [site(c, a, .read(width: 32, type: "int"))]])
        XCTAssertEqual(declared.entries[a]?.kind, .unresolved(.conflict))
    }

    func testDeclaredConsumerShapeDoesNotConflictWithProducerShape() {
        for tail in [false, true] {
            let facts = [a: Facts(producers: tail ? [] : [.calleeResult(b)],
                exits: tail ? [.tailCall(b)] : [.returnInstruction(a)]),
                b: Facts(header: header(.value(.gpr(width: 64, type: "int *"))), producers: [.load]), c: Facts()]
            for (width, type) in [(32, "int"), (64, "size_t")] {
                let table = build(facts, sites: [a: [site(a, b, .flowsToReturn, tail: tail)],
                    c: [site(c, a, .read(width: width, type: type))]])
                XCTAssertEqual(table.entries[a]?.kind, .value(.gpr(width: width, type: type)))
                XCTAssertTrue(table.entries[a]?.evidence.contains {
                    $0.source == .producer && $0.detail.contains("int *")
                } == true)
            }
        }
    }

    func testEveryUnresolvedReasonHasAReportedEntry() {
        var observed: Set<ReturnContract.Reason> = []
        func expect(_ reason: ReturnContract.Reason, _ facts: [UInt64: Facts],
                    _ sites: [UInt64: [CallSiteContract]], complete: Bool = true) {
            let table = build(facts, sites: sites, complete: complete)
            XCTAssertEqual(table.entries[a]?.kind, .unresolved(reason))
            XCTAssertNil(table.entries[a]?.tier)
            XCTAssertGreaterThanOrEqual(table.report.byReason[reason.rawValue, default: 0], 1)
            observed.insert(reason)
        }
        expect(.notLifted, [a: Facts(lifted: false)], [:])
        expect(.imageGuard, [a: Facts(requiresImageGuard: true)], [:], complete: false)
        expect(.openWorld, [a: Facts()], [:])
        expect(.callerUnproven, [a: Facts(), b: Facts()], [b: [site(b, a, .unknown)]])
        expect(.slotVetoed, [a: Facts(slotVetoes: ["incompatible store"]), b: Facts()], [b: [site(b, a)]])
        expect(.cycleUnbroken, [a: Facts()], [a: [site(a, a, .flowsToReturn)]])
        expect(.producerOnly, [a: Facts(producers: [.constant]), b: Facts()], [b: [site(b, a)]])
        expect(.directOnlyPrivate, [a: Facts(producers: [.unknown]), b: Facts()], [b: [site(b, a)]])
        expect(.contractWithoutProducer, [a: Facts(producers: [.unknown]), b: Facts()],
            [b: [site(b, a, .read(width: 64, type: "int64_t"))]])
        expect(.conflict, [a: Facts(exits: [.tailCall(b)]), b: Facts(header: header(.void)), c: Facts()],
            [a: [site(a, b, .flowsToReturn, tail: true)], c: [site(c, a, .read(width: 64, type: nil))]])
        XCTAssertEqual(observed, Set(ReturnContract.Reason.allCases))
    }

    func testFlowToAuthoritativeVoidIsDiscardEvidence() {
        let table = build([a: Facts(producers: [.unknown]), b: Facts(header: header(.void))],
            sites: [b: [site(b, a, .flowsToReturn)]])
        XCTAssertEqual(table.entries[a]?.kind, .unresolved(.directOnlyPrivate))
        XCTAssertTrue(table.entries[a]?.evidence.contains { $0.source == .discard } == true)
    }

    func testNoReturnExitPropagationSuppressesUnreachableReturn() {
        let source = spans(a, [("bl", "0x2000"), ("ret", "")])
        let table = build([a: Facts(producers: [.calleeResult(b)], exits: [.returnInstruction(a + 4)], sources: source),
            b: Facts(exits: [.tailCall(c)]), c: Facts(exits: [.trap(c)])],
            sites: [a: [site(a, b, .flowsToReturn)], b: [site(b, c, .flowsToReturn, tail: true)]])
        for address in [a, b, c] { XCTAssertEqual(table.entries[address]?.kind, .noReturn) }
        let mixed = build([a: Facts(exits: [.tailCall(b), .trap(a + 4)]), b: Facts(header: header(.void))],
            sites: [a: [site(a, b, .flowsToReturn, tail: true)]])
        XCTAssertEqual(mixed.entries[a]?.kind, .void)
    }

    func testNonReturningArmsDoNotConflictWithReturnedValue() {
        let shape = ReturnContract.ReturnShape.gpr(width: 64, type: "int *")
        let table = build([a: Facts(exits: [.tailCall(b), .tailCall(c), .infiniteLoop(a + 4)]),
            b: Facts(header: header(.value(shape)), producers: [.load]), c: Facts(exits: [.trap(c)]), d: Facts()],
            sites: [a: [site(a, b, .flowsToReturn, tail: true), site(a + 4, c, .flowsToReturn, tail: true)],
                d: [site(d, a, .read(width: 64, type: "int *"))]])
        XCTAssertEqual(table.entries[a]?.kind, .value(shape))
        XCTAssertEqual(table.entries[c]?.kind, .noReturn)
        let unseeded = build([a: Facts(producers: [.passthroughParameter], exits: [.returnInstruction(a)])])
        XCTAssertEqual(unseeded.entries[a]?.kind, .unresolved(.openWorld))
    }

    func testMixedReturningExitsDoNotInheritVoid() {
        let shape = ReturnContract.ReturnShape.gpr(width: 64, type: nil)
        for secondKind: ReturnContract.Kind in [.value(shape), .void, .unresolved(.openWorld)] {
            let facts = [a: Facts(exits: [.tailCall(b), .tailCall(c)]),
                b: Facts(header: header(.value(shape)), producers: [.load]),
                c: Facts(header: header(secondKind), producers: [.load]), d: Facts()]
            var sites = [a: [site(a, b, .flowsToReturn, tail: true), site(a + 4, c, .flowsToReturn, tail: true)]]
            XCTAssertEqual(build(facts, sites: sites).entries[a]?.kind, .unresolved(.openWorld))
            sites[d] = [site(d, a, .read(width: 64, type: nil))]
            XCTAssertEqual(build(facts, sites: sites).entries[a]?.kind, .value(shape))
        }
        let mixed = [a: Facts(producers: [.load], exits: [.returnInstruction(a), .tailCall(b)]),
            b: Facts(header: header(.void)), c: Facts()]
        let tails = [a: [site(a + 4, b, .flowsToReturn, tail: true)]]
        XCTAssertEqual(build(mixed, sites: tails).entries[a]?.kind, .unresolved(.openWorld))
        var read = tails
        read[c] = [site(c, a, .read(width: 64, type: nil))]
        XCTAssertEqual(build(mixed, sites: read).entries[a]?.kind, .value(shape))
    }

    func testProducerKindsAndCalleeCopies() {
        let cases: [([(String, String)], Set<Producer>)] = [
            ([("mov", "x0, #7"), ("ret", "")], [.constant]),
            ([("ldr", "x0, [x1]"), ("ret", "")], [.load]),
            ([("add", "x0, x1, x2"), ("ret", "")], [.arithmetic]),
            ([("cset", "w0, eq"), ("ret", "")], [.compareSet]),
            ([("ret", "")], [.passthroughParameter]),
            ([("bl", "0x2000"), ("ret", "")], [.calleeResult(b)]),
            ([("bl", "0x2000"), ("mov", "x19, x0"), ("bl", "0x3000"), ("mov", "x0, x19"), ("ret", "")], [.calleeResult(b)]),
            ([("bl", "0x2000"), ("mov", "w0, w0"), ("ret", "")], [.arithmetic]),
            ([("bl", "0x2000"), ("mov", "x1, x0"), ("bl", "0x3000"), ("mov", "x0, x1"), ("ret", "")], [.unknown])
        ]
        for (operations, expected) in cases {
            let proof = BuilderState.returnContractProducerFacts(sources: spans(a, operations), entry: a)
            XCTAssertEqual(proof.producers[a + UInt64((operations.count - 1) * 4)], expected, "\(operations)")
        }
    }

    func testProducerJoinsAndExitRefusals() {
        let joined = BuilderState.returnContractProducerFacts(sources: spans(a, [
            ("cbz", "x1, 0x100c"), ("mov", "x0, #1"), ("b", "0x1010"),
            ("ldr", "x0, [x2]"), ("ret", "")]), entry: a)
        XCTAssertEqual(joined.producers[a + 16], [.constant, .load])
        let tail = BuilderState.returnContractProducerFacts(sources: spans(a, [("b", "0x2000")]), entry: a,
            knownFunctionStarts: [a, b])
        XCTAssertEqual(tail.exits, [.tailCall(b)])
        let loop = BuilderState.returnContractProducerFacts(sources: spans(a, [("b", "0x1000")]), entry: a)
        XCTAssertEqual(loop.exits, [.infiniteLoop(a)])
        let trap = BuilderState.returnContractProducerFacts(sources: spans(a, [("brk", "#0")]), entry: a)
        XCTAssertEqual(trap.exits, [.trap(a)])
        let abort = BuilderState.returnContractProducerFacts(sources: spans(a, [("bl", "_abort"), ("ret", "")]), entry: a)
        XCTAssertEqual(abort.exits, [.noReturnCall(a)])
        XCTAssertTrue(abort.producers.isEmpty)
        for operations in [[("b", "0x2000")], [("br", "x8")], [("unsupported", "x0"), ("ret", "")], [("ret", "x9")]] {
            let proof = BuilderState.returnContractProducerFacts(sources: spans(a, operations), entry: a)
            XCTAssertEqual(proof.exits, [.unknown(a)])
            XCTAssertEqual(proof.producers[a], [.unknown])
        }
        let duplicate = spans(a, [("ret", "")]) + spans(a, [("ret", "")])
        XCTAssertEqual(BuilderState.returnContractProducerFacts(sources: duplicate, entry: a).exits, [.unknown(a)])
    }

    func testProvenNoReturnCallExcludesLaterConsumerAndReturn() {
        let proof = BuilderState.returnContractProducerFacts(sources: spans(a, [
            ("bl", "0x2000"), ("bl", "0x3000"), ("ret", "")]), entry: a,
            noReturnCallSites: [a], knownFunctionStarts: [a, b, c])
        XCTAssertEqual(proof.reachableAddresses, [a])
        XCTAssertFalse(proof.reachableAddresses.contains(a + 4))
        XCTAssertFalse(proof.reachableAddresses.contains(a + 8))
        XCTAssertTrue(proof.producers.isEmpty)
        XCTAssertEqual(proof.exits, [.noReturnCall(a)])
    }

    func testConsumptionAgreesWithCallResultUses() throws {
        let callee = ir(a, [("ret", "")])
        let discarded = ir(b, [("bl", "0x1000"), ("mov", "x0, #0"), ("ret", "")])
        let read = ir(c, [("bl", "0x1000"), ("str", "x0, [x1]"), ("mov", "x0, #0"), ("ret", "")])
        let flowing = ir(d, [("bl", "0x1000"), ("ret", "")])
        let sites = MacIRCallerReturnEvidence.collectCallSites(functions: [callee, discarded, read, flowing])
        XCTAssertEqual(sites[b]?.first?.consumption, .discarded)
        XCTAssertEqual(sites[c]?.first?.consumption, .read(width: 64, type: nil))
        XCTAssertEqual(sites[d]?.first?.consumption, .flowsToReturn)
        guard case let .call(_, result) = try XCTUnwrap(read.instructions.first).operation,
              case let .store(source, _) = try XCTUnwrap(read.instructions.first { $0.source.address == c + 4 }).operation else {
            return XCTFail("fixture must expose a call result and its store")
        }
        XCTAssertEqual(source, result)
        guard case let .assign(_, source) = try XCTUnwrap(discarded.instructions.first { $0.source.address == b + 4 }).operation else {
            return XCTFail("discard must be an explicit independent overwrite")
        }
        XCTAssertEqual(source, .immediate(0))
        let text = PseudocodePrinter().print(function: read).text
        XCTAssertTrue(text.contains("x0_1 = 0x1000(); // call"), text)
        XCTAssertTrue(text.contains("*(unavailable_x1) = x0_1;"), text)
        let unknown = ir(d, [("bl", "0x1000"), ("br", "x8")])
        XCTAssertEqual(MacIRCallerReturnEvidence.collectCallSites(functions: [callee, unknown])[d]?.first?.consumption, .unknown)
    }

    func testCatalogNoReturnHasNoReturnAndNoCallerFallthrough() throws {
        let halting = ir(a, [("bl", "_abort")])
        let proof = BuilderState.returnContractProducerFacts(sources: halting.instructions.map(\.source), entry: a)
        let table = build([a: Facts(producers: Set(proof.producers.values.flatMap { $0 }), exits: proof.exits)])
        XCTAssertEqual(table.entries[a]?.kind, .noReturn)
        XCTAssertFalse(halting.instructions.contains { if case .returnValue = $0.operation { return true }; return false })
        let text = PseudocodePrinter().print(function: halting).text
        XCTAssertFalse(text.contains("return "), text)
        XCTAssertFalse(text.contains("return;"), text)
        let caller = ir(b, [("bl", "_abort"), ("mov", "x0, #1"), ("ret", "")])
        let cfg = CFGBuilder.buildCFG(instructions: caller.instructions)
        let index = try XCTUnwrap(caller.instructions.firstIndex { $0.source.address == b })
        let callBlock = try XCTUnwrap(cfg.blocks.first { $0.instructionRange.contains(index) })
        XCTAssertTrue(callBlock.successors.isEmpty)
    }

    private func declaredVoidSnapshot() -> WorkspaceSnapshot {
        var analysis = ImageAnalysis()
        analysis.functions = [
            FunctionSummary(id: UUID(), name: "declared_void", startAddress: a, endAddress: a + 4, confidence: 1),
            FunctionSummary(id: UUID(), name: "caller", startAddress: b, endAddress: b + 8, confidence: 1)
        ]
        analysis.instructions = [
            InstructionRow(address: a, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
            InstructionRow(address: b, bytes: "", mnemonic: "bl", operands: "0x1000", hasBreakpoint: false, comment: nil),
            InstructionRow(address: b + 4, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        var snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        snapshot.insertImage(binary: BinaryImage(id: UUID(), name: "fixture", path: "/fixture/return-contract",
            kind: "executable", architecture: "arm64", slot: .primary), analysis: analysis)
        for address in [a, b] {
            snapshot.addressOverrides[.primary(address)] = AddressOverride(signature: .init(returnType: "void", args: []))
        }
        return snapshot
    }

    func testFeatureFlagPublishesDiagnosticsWithoutChangingCanonicalSyntheticRender() throws {
        let suite = "ReturnContractTableTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let preference = "MacScopeReturnContractTable"
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = DocumentExportService()
        func render(_ snapshot: WorkspaceSnapshot) -> [String] {
            [a, b].map {
                service.pseudocodeText(for: snapshot.pseudocodeRenderInput(selectedAddress: $0, in: .primary), options: .default)
            }
        }
        defaults.removeObject(forKey: preference)
        let withoutFlag = MacIRConfiguration.$returnContractOverride.withValue(defaults.bool(forKey: preference)) {
            let absent = declaredVoidSnapshot()
            XCTAssertNotNil(absent.imageWideIndirectCalls(in: .primary, compute: true))
            XCTAssertNil(absent.returnContractTable(in: .primary, compute: false))
            return render(absent)
        }
        defaults.set(false, forKey: preference)
        MacIRConfiguration.$returnContractOverride.withValue(defaults.bool(forKey: preference)) {
            let off = declaredVoidSnapshot()
            XCTAssertNotNil(off.imageWideIndirectCalls(in: .primary, compute: true))
            XCTAssertNil(off.returnContractTable(in: .primary, compute: false))
            XCTAssertEqual(render(off), withoutFlag)
        }
        defaults.set(true, forKey: preference)
        return try MacIRConfiguration.$returnContractOverride.withValue(defaults.bool(forKey: preference)) {
            let on = declaredVoidSnapshot()
            XCTAssertNotNil(on.imageWideIndirectCalls(in: .primary, compute: true))
            let table = try XCTUnwrap(on.returnContractTable(in: .primary, compute: false))
            XCTAssertEqual(table.entries.count, 2)
            XCTAssertEqual(table.entries[a]?.kind, .void)
            XCTAssertEqual(table.entries[b]?.kind, .void)
            XCTAssertEqual(table.report.byKind["void"], 2)
            XCTAssertEqual(table.report.byTier["0"], 2)
            XCTAssertTrue(table.report.byReason.isEmpty)
            XCTAssertFalse(table.report.capExceeded)
            let diagnostics = try XCTUnwrap(on.closedWorldCallerReturnReport(in: .primary, compute: false))
            XCTAssertEqual(diagnostics.byKind, table.report.byKind)
            XCTAssertEqual(diagnostics.byTier, table.report.byTier)
            XCTAssertEqual(diagnostics.byReason, table.report.byReason)
            XCTAssertEqual(render(on), withoutFlag)
        }
    }

    func testHeaderReturnShapeMappings() {
        let mappings: [(String, ReturnContract.Kind)] = [
            ("uint32_t", .value(.gpr(width: 32, type: "uint32_t"))),
            ("float", .value(.fpr(width: 32, type: "float"))),
            ("double", .value(.fpr(width: 64, type: "double"))),
            ("void", .void)
        ]
        for (type, expected) in mappings {
            let contract = ReturnContractTable.headerContract(type: type)
            XCTAssertEqual(contract.kind, expected)
            XCTAssertEqual(contract.tier, .header)
        }
        let noReturn = ReturnContractTable.headerContract(type: "void", noReturn: true)
        XCTAssertEqual(noReturn.kind, .noReturn)
        XCTAssertEqual(noReturn.tier, .header)
    }

    func testConsumerOfImmutableVoidCannotAuthorizeItsReturnedCallee() {
        let table = build([a: Facts(producers: [.unknown]),
            b: Facts(header: header(.void), producers: [.calleeResult(a)]), c: Facts()],
            sites: [b: [site(b, a, .flowsToReturn)], c: [site(c, b, .read(width: 64, type: "int *"))]])
        XCTAssertEqual(table.entries[a]?.kind, .unresolved(.directOnlyPrivate))
        XCTAssertEqual(table.entries[b]?.kind, .void)
        XCTAssertTrue(table.entries[b]?.evidence.contains { $0.detail.contains("conflict") } == true)
    }

    func testStructuralNoReturnSuppressesDeadCallConsumption() {
        let callerRows = spans(b, [("bl", "0x1000"), ("bl", "0x3000"),
            ("str", "x0, [x1]"), ("ret", "")])
        let table = build([a: Facts(exits: [.trap(a)]),
            b: Facts(producers: [.calleeResult(c)], exits: [.returnInstruction(b + 12)], sources: callerRows),
            c: Facts(producers: [.load], exits: [.returnInstruction(c)])],
            sites: [b: [site(b, a, .read(width: 64, type: nil)), site(b + 4, c, .read(width: 64, type: nil))]])
        XCTAssertEqual(table.entries[a]?.kind, .noReturn)
        XCTAssertEqual(table.entries[b]?.kind, .noReturn)
        XCTAssertEqual(table.entries[c]?.kind, .unresolved(.openWorld))
        XCTAssertEqual(table.callSites[b]?.map(\.address), [b])
    }

    func testCompatibleDerivedTypeDoesNotConflictWithWidthOnlyHeader() {
        let shape = ReturnContract.ReturnShape.gpr(width: 64, type: nil)
        let table = build([a: Facts(header: header(.value(shape)), producers: [.load]), b: Facts()],
            sites: [b: [site(b, a, .read(width: 64, type: "int *"))]])
        XCTAssertEqual(table.entries[a]?.kind, .value(shape))
        XCTAssertEqual(table.entries[a]?.tier, .header)
        XCTAssertFalse(table.entries[a]?.evidence.contains { $0.detail.contains("conflict") } == true)
    }

    func testUnavailableLiftCannotPublishAValueContract() {
        let table = build([a: Facts(lifted: false), b: Facts()],
            sites: [b: [site(b, a, .read(width: 64, type: nil))]])
        XCTAssertEqual(table.entries[a]?.kind, .unresolved(.notLifted))
        XCTAssertNil(table.entries[a]?.tier)
    }

    func testImmutableConcreteTypeRecordsSameWidthDisagreement() {
        let shape = ReturnContract.ReturnShape.gpr(width: 64, type: "int *")
        let table = build([a: Facts(header: header(.value(shape)), producers: [.load]), b: Facts()],
            sites: [b: [site(b, a, .read(width: 64, type: "char *"))]])
        XCTAssertEqual(table.entries[a]?.kind, .value(shape))
        XCTAssertEqual(table.entries[a]?.tier, .header)
        XCTAssertTrue(table.entries[a]?.evidence.contains { $0.detail.contains("conflict") } == true)
    }

    func testTyped32BitConsumerAgreesWithInherited32BitTail() throws {
        let result = MacIRValue.register(name: "x0", version: 1)
        let empty = try XCTUnwrap(MacIRCallArguments([]))
        let producer = try XCTUnwrap(MacIRCallFrame(target: "0x1000", knownSignature: nil,
            controlInputs: .none, arguments: empty))
        let arguments = try XCTUnwrap(MacIRCallArguments([MacIRCallArgument(
            location: .gpr(index: 0, carrierWidth: 32), role: .fixed(sourcePosition: 0), value: result)]))
        let signature = MacIRCallSignature(target: "_consume_int", returnType: "void", parameters: [
            MacIRCallParameter(index: 0, register: "w0", type: "int")])
        let consumer = try XCTUnwrap(MacIRCallFrame(target: "_consume_int", knownSignature: signature,
            controlInputs: .none, arguments: arguments))
        func instruction(_ address: UInt64, _ mnemonic: String, _ operands: String,
                         _ operation: MacIROperation) -> MacIRInstruction {
            MacIRInstruction(source: MacIRSourceSpan(address: address, byteText: "", mnemonic: mnemonic,
                operands: operands), operation: operation)
        }
        let caller = MacIRFunction(name: "consumer", startAddress: c, instructions: [
            instruction(c, "bl", "0x1000", .call(frame: producer, result: result)),
            instruction(c + 4, "bl", "_consume_int", .call(frame: consumer, result: nil)),
            instruction(c + 8, "ret", "", .returnValue(nil))
        ])
        let tail = ir(a, [("b", "0x2000")])
        let target = ir(b, [("mov", "w0, #7"), ("ret", "")])
        let sites = MacIRCallerReturnEvidence.collectCallSites(functions: [tail, target, caller])
        XCTAssertEqual(sites[c]?.first?.consumption, .read(width: 32, type: "int"))
        let shape = ReturnContract.ReturnShape.gpr(width: 32, type: "int")
        let table = build([a: Facts(exits: [.tailCall(b)]),
            b: Facts(header: header(.value(shape)), producers: [.constant], exits: [.returnInstruction(b + 4)]),
            c: Facts()], sites: sites)
        XCTAssertEqual(table.entries[a]?.kind, .value(shape))
        XCTAssertEqual(table.entries[b]?.kind, .value(shape))
    }

    func testEveryExistingDirectCallerUnavailableUsesCallerUnproven() {
        for consumption: CallSiteContract.Consumption in [.discarded, .flowsToReturn, .unknown] {
            let facts = [a: Facts(name: "callee", producers: [.constant]),
                b: Facts(lifted: false), c: Facts(lifted: false)]
            let sites = [b: [site(b, a, consumption)], c: [site(c, a, consumption)]]
            let table = build(facts, sites: sites)
            XCTAssertEqual(table.entries[a]?.kind, .unresolved(.callerUnproven))
            XCTAssertNil(table.entries[a]?.tier)
            XCTAssertEqual(table.report.unliftedCallerEntries.map(\.address), [a])
            XCTAssertEqual(table.report.unliftedCallerEntries.first?.name, "callee")
            XCTAssertEqual(table.report.unliftedCallerEntries.first?.callers, [b, c])
            XCTAssertTrue(table.entries[a]?.evidence.contains {
                $0.at == b && ($0.source == .consumer || $0.source == .discard)
            } == true)
            XCTAssertEqual(build(facts, sites: sites, exported: [a]).entries[a]?.kind, .unresolved(.openWorld))
            let escaped = build(facts, sites: sites, addressTaken: [a])
            XCTAssertEqual(escaped.entries[a]?.kind, .unresolved(.openWorld))
            XCTAssertTrue(escaped.report.unliftedCallerEntries.isEmpty)
        }
        let mixed = build([a: Facts(producers: [.constant]), b: Facts(lifted: false), c: Facts()],
            sites: [b: [site(b, a)], c: [site(c, a)]])
        XCTAssertEqual(mixed.entries[a]?.kind, .unresolved(.producerOnly))
        XCTAssertTrue(mixed.report.unliftedCallerEntries.isEmpty)
        let declaredCaller = build([a: Facts(producers: [.constant]),
            b: Facts(header: header(.void), lifted: false)], sites: [b: [site(b, a)]])
        XCTAssertEqual(declaredCaller.entries[a]?.kind, .unresolved(.producerOnly))
        XCTAssertTrue(declaredCaller.report.unliftedCallerEntries.isEmpty)
        let noCallers = build([a: Facts(producers: [.constant])])
        XCTAssertEqual(noCallers.entries[a]?.kind, .unresolved(.openWorld))
        XCTAssertTrue(noCallers.report.unliftedCallerEntries.isEmpty)
    }

    func testMixedVoidTailReturnMeasurementDoesNotEstablishVoid() {
        let facts = [a: Facts(name: "mixed", producers: [.load],
                exits: [.returnInstruction(a), .tailCall(b), .trap(a + 8)]),
            b: Facts(header: header(.void)), c: Facts()]
        var sites = [a: [site(a + 4, b, .flowsToReturn, tail: true)]]
        let unresolved = build(facts, sites: sites)
        XCTAssertEqual(unresolved.entries[a]?.kind, .unresolved(.openWorld))
        XCTAssertNil(unresolved.entries[a]?.tier)
        XCTAssertEqual(unresolved.report.mixedVoidTailReturns.map(\.address), [a])
        XCTAssertEqual(unresolved.report.mixedVoidTailReturns.first?.name, "mixed")
        XCTAssertEqual(unresolved.report.mixedVoidTailReturns.first?.voidTailTargets, [b])
        XCTAssertEqual(unresolved.report.mixedVoidTailReturns.first?.plainReturnSites, [a])
        sites[c] = [site(c, a, .read(width: 64, type: nil))]
        let value = build(facts, sites: sites)
        XCTAssertEqual(value.entries[a]?.kind, .value(.gpr(width: 64, type: nil)))
        XCTAssertEqual(value.report.mixedVoidTailReturns.map(\.address), [a])
        let derived = build([a: Facts(exits: [.returnInstruction(a), .tailCall(b)]),
            b: Facts(exits: [.tailCall(c)]), c: Facts(header: header(.void))], sites: [
                a: [site(a + 4, b, .flowsToReturn, tail: true)],
                b: [site(b, c, .flowsToReturn, tail: true)]])
        XCTAssertEqual(derived.entries[b]?.tier, .derived)
        XCTAssertEqual(derived.report.mixedVoidTailReturns.map(\.address), [a])
    }

    func testMixedVoidTailReturnMeasurementExcludesUnprovenArms() {
        for kind: ReturnContract.Kind in [.value(.gpr(width: 64, type: "int")), .unresolved(.openWorld), .noReturn] {
            let table = build([a: Facts(exits: [.returnInstruction(a), .tailCall(b), .tailCall(c)]),
                b: Facts(header: header(.void)), c: Facts(header: header(kind))], sites: [
                    a: [site(a + 4, b, .flowsToReturn, tail: true), site(a + 8, c, .flowsToReturn, tail: true)]])
            XCTAssertEqual(table.report.mixedVoidTailReturns.map(\.address), kind == .noReturn ? [a] : [])
        }
        for exits: Set<BuilderState.ReturnContractExit> in [
            [.tailCall(b)], [.returnInstruction(a)], [.returnInstruction(a), .tailCall(b), .unknown(a + 8)]
        ] {
            let table = build([a: Facts(exits: exits), b: Facts(header: header(.void))],
                sites: [a: [site(a + 4, b, .flowsToReturn, tail: true)]])
            XCTAssertTrue(table.report.mixedVoidTailReturns.isEmpty)
        }
        let closedWorld = build([a: Facts(exits: [.returnInstruction(a), .tailCall(b)]),
            b: Facts(closedWorldVoid: true)], sites: [a: [site(a + 4, b, .flowsToReturn, tail: true)]])
        XCTAssertEqual(closedWorld.entries[b]?.kind, .unresolved(.directOnlyPrivate))
        XCTAssertNil(closedWorld.entries[b]?.tier)
        XCTAssertTrue(closedWorld.entries[b]?.evidence.contains {
            $0.source == .discard && $0.at == b
                && $0.detail == "closed-world discard does not establish a void return type"
        } == true)
        XCTAssertTrue(closedWorld.report.mixedVoidTailReturns.isEmpty)
    }

    func testLookupIsAddressExact() {
        let table = build([a: Facts(header: header(.void))])
        XCTAssertEqual(table.contract(forFunctionAt: a)?.kind, .void)
        XCTAssertEqual(table.contract(forDirectCallTo: .direct(a))?.kind, .void)
        XCTAssertNil(table.contract(forDirectCallTo: .direct(a + 4)))
        XCTAssertNil(table.contract(forDirectCallTo: .import("fixture")))
        XCTAssertNil(table.contract(forDirectCallTo: .unknown))
        XCTAssertEqual(table.report.byKind["void"], 1)
        XCTAssertEqual(table.report.byTier["0"], 1)
        XCTAssertTrue(table.report.byReason.isEmpty)
    }
    private func slotTailFixture(_ operations: [(String, String)], field: String = "error_exit",
        returnType: String = "void", enabled: Bool = true,
        suppliedContracts: [UInt64: FunctionPointerSignatureV1]? = nil) throws
        -> (SlotTypedPrototypeBinding.Report, ReturnContractTable, MacIRFunction) {
        let parsed = CTypeHeaderParser.parse("""
            struct Ops { \(returnType) (*\(field))(struct Ops *ops); };
            struct Context { struct Ops *err; };
            void dispatch(struct Context *context);
            """)
        let signature = try XCTUnwrap(parsed.prototypes.first { $0.name == "dispatch" }?.signature)
        let rows = operations.enumerated().map {
            InstructionRow(address: a + UInt64($0.offset * 4), bytes: "00 00 00 00", mnemonic: $0.element.0,
                operands: $0.element.1, hasBreakpoint: false, comment: nil)
        }
        let function = PseudocodePrinter().buildFunction(functionName: "dispatch", startAddress: a,
            signatureOverrides: [a: signature], types: parsed.types, instructions: rows)
        let report = SlotTypedPrototypeBinding.analyze(builtFunctions: [function], originalInstructions: rows,
            functionStarts: [a], importedPrototypes: [a: signature], effectiveSignatures: [a: signature],
            types: parsed.types, headerLayoutDefinitions: parsed.types, includeSlotTails: enabled)
        var analysis = ImageAnalysis()
        analysis.functions = [FunctionSummary(id: UUID(), name: "dispatch", startAddress: a,
            endAddress: a + UInt64(rows.count * 4), confidence: 1)]
        analysis.instructions = rows
        return MacIRConfiguration.$returnContractOverride.withValue(enabled) {
            let table = ReturnContractTable.collect(key: .init(snapshotID: UUID(), slot: .primary), analysis: analysis,
                functions: [function], signatures: [:], types: parsed.types, callerWidths: [:],
                slots: MacIRSlotReturnAuthority.collect(functions: [], types: parsed.types, signatures: [:], callerReturns: [:]),
                indirect: MacIRIndirectTargetResolution.resolve(functions: [], functionStarts: [a]), slotCalls: suppliedContracts ?? report.callContracts)
            return (report, table, function)
        }
    }

    func testErrorExitTypedSlotTailDerivesVoid() throws {
        let (report, table, function) = try slotTailFixture([
            ("ldr", "x8, [x0]"), ("mov", "w9, #7"), ("str", "w9, [x8, #40]"),
            ("ldr", "x1, [x8]"), ("br", "x1")])
        XCTAssertEqual(report.callContracts[a + 16]?.returnType, "void")
        XCTAssertEqual(table.entries[a]?.kind, .void)
        XCTAssertEqual(table.entries[a]?.tier, .derived)
        XCTAssertEqual(table.callSites[a]?.last?.isTailCall, true)
        XCTAssertEqual(function.instructions.last?.source.mnemonic, "br")
        XCTAssertTrue(report.callProofRows.first?.pointerChase.joined().contains("error_exit") == true)
    }

    func testSIMDTypedSlotTailWithRestoredFrameDerivesVoid() throws {
        let (report, table, _) = try slotTailFixture([
            ("stp", "x29, x30, [sp, #-16]!"), ("mov", "x29, sp"),
            ("ldr", "x8, [x0]"), ("ldr", "x5, [x8]"),
            ("ldp", "x29, x30, [sp], #16"), ("br", "x5")], field: "color_convert_simd")
        XCTAssertEqual(report.callContracts[a + 20]?.returnType, "void")
        XCTAssertEqual(table.entries[a]?.kind, .void)
        XCTAssertEqual(table.entries[a]?.tier, .derived)
    }

    func testValueTypedSlotTailIsProducerOnly() throws {
        let (report, table, _) = try slotTailFixture([
            ("ldr", "x8, [x0]"), ("ldr", "x5, [x8]"), ("br", "x5")], returnType: "int")
        XCTAssertEqual(report.callContracts[a + 8]?.returnType, "int32_t")
        guard case .unresolved = table.entries[a]?.kind else { return XCTFail("value slot is not own value authority") }
        XCTAssertTrue(table.entries[a]?.evidence.contains { $0.source == .producer && $0.detail.contains("int") } == true)
    }

    func testIndexedJumpAndUnpoppedOrClobberedFramesRefuseSlotTails() throws {
        let bodies: [[(String, String)]] = [
            [("adr", "x8, #0x2000"), ("ldr", "x5, [x8, x2, lsl #3]"), ("br", "x5")],
            [("sub", "sp, sp, #16"), ("ldr", "x8, [x0]"), ("ldr", "x5, [x8]"), ("br", "x5")],
            [("mov", "x30, x2"), ("ldr", "x8, [x0]"), ("ldr", "x5, [x8]"), ("br", "x5")],
            [("ldrb", "w9, [sp], #16"), ("ldr", "x8, [x0]"), ("ldr", "x5, [x8]"), ("br", "x5")],
            [("stp", "x29, x30, [sp, #-16]!"), ("str", "x2, [sp, #8]"),
             ("ldr", "x8, [x0]"), ("ldr", "x5, [x8]"), ("ldp", "x29, x30, [sp], #16"), ("br", "x5")]
        ]
        for body in bodies {
            let (report, table, _) = try slotTailFixture(body)
            XCTAssertTrue(report.callContracts.isEmpty)
            XCTAssertTrue(report.refusals.contains { $0.reason == "br_not_proven_tail" })
            XCTAssertFalse(table.callSites[a]?.contains { $0.isTailCall } == true)
            XCTAssertNotEqual(table.entries[a]?.kind, .void)
        }
    }

    func testTypedSlotTailFlagOffEmitsAndConsumesNoContract() throws {
        let body = [("ldr", "x8, [x0]"), ("ldr", "x5, [x8]"), ("br", "x5")]
        let (off, offTable, offFunction) = try slotTailFixture(body, enabled: false)
        let (on, onTable, onFunction) = try slotTailFixture(body)
        XCTAssertTrue(off.callContracts.isEmpty)
        XCTAssertFalse(offTable.callSites[a]?.contains { $0.isTailCall } == true)
        XCTAssertNotEqual(offTable.entries[a]?.kind, .void)
        XCTAssertEqual(on.callContracts.count, 1)
        XCTAssertEqual(onTable.entries[a]?.kind, .void)
        let (_, staleTable, _) = try slotTailFixture(body, enabled: false, suppliedContracts: on.callContracts)
        XCTAssertEqual(staleTable.entries, offTable.entries)
        XCTAssertFalse(staleTable.callSites[a]?.contains { $0.isTailCall } == true)
        XCTAssertEqual(offFunction.instructions, onFunction.instructions)
    }

    private func returnContractInput(_ rows: [InstructionRow]) -> PseudocodeRenderInput {
        PseudocodeRenderInput(imageSlot: .primary, functionName: "_table_render_fixture",
            startAddress: a, jumpTables: [:], objcSelectors: [:], nameOverrides: [:],
            signatureOverrides: [:], registerNameOverrides: [:], types: [], instructions: rows,
            callerReturnWidth: nil)
    }

    private func renderedContractFunction(_ input: PseudocodeRenderInput,
                                          knownTargets: [UInt64: String] = [:]) -> MacIRFunction {
        if !knownTargets.isEmpty {
            // Isolate the already-existing builder tail seam. Production printer
            // target forwarding is a separate change, not part of this fix.
            var function = MacIRBuilder().buildFunction(name: input.functionName,
                startAddress: input.startAddress,
                authoritativeReturnLocation: input.callerReturnType.map {
                    DarwinARM64ParameterBinder.returnLocation(for: $0, resolver: TypeAtlasDarwinARM64LayoutResolver())
                }, authoritativeReturnType: input.callerReturnType,
                callerReturnWidth: input.callerReturnWidth,
                authoredCallSignaturesByTarget: input.authoredCallSignaturesByTarget,
                knownTailCallTargets: knownTargets, instructions: input.instructions)
            if let type = input.callerReturnType { function.returnType = type }
            return function
        }
        return PseudocodePrinter().buildFunction(functionName: input.functionName, startAddress: input.startAddress,
            signatureOverrides: input.signatureOverrides,
            authoredCallSignaturesByTarget: input.authoredCallSignaturesByTarget,
            callerReturnWidth: input.callerReturnWidth, callerReturnType: input.callerReturnType,
            types: input.types,
            instructions: input.instructions)
    }

    func testCompletedVoidTailAuthorityFillsMissingReturnOnlyWhenEnabled() throws {
        // B at 0x1000, target 0x2000: imm26 = 0x400. These authored bytes
        // accompany explicit rows; no decoder or execution receipt is implied.
        let rows = [InstructionRow(address: a, bytes: "00 04 00 14", mnemonic: "b",
            operands: "0x2000", hasBreakpoint: false, comment: nil)]
        let facts = [a: Facts(sources: spans(a, [("b", "0x2000")])),
                     b: Facts(header: header(.void), exits: [.returnInstruction(b)])]
        let table = build(facts, sites: [a: [site(a, b, .flowsToReturn, tail: true)]])
        let contract = try XCTUnwrap(table.entries[a])
        XCTAssertEqual(contract.kind, .void)
        XCTAssertEqual(contract.tier, .derived)
        let original = returnContractInput(rows)
        var off = original
        off.admitReturnContract(contract, enabled: false)
        XCTAssertEqual(off, original, "disabled handoff is byte-preserving input identity")
        var on = original
        on.admitReturnContract(contract, enabled: true)
        XCTAssertEqual(on.callerReturnType, "void")
        XCTAssertEqual(on.signatureOverrides, original.signatureOverrides)
        let refused = renderedContractFunction(off, knownTargets: [b: "_table_callee"])
        let admitted = renderedContractFunction(on, knownTargets: [b: "_table_callee"])
        XCTAssertEqual(refused.returnValue, .unknown("unresolved_return_contract"))
        XCTAssertEqual(admitted.instructions.last?.operation, .returnValue(nil))
        let before = PseudocodePrinter().print(function: refused).text
        let after = PseudocodePrinter().print(function: admitted).text
        XCTAssertTrue(before.contains("return unresolved_return_contract;"), before)
        XCTAssertTrue(after.contains("_table_callee();"), after)
        XCTAssertTrue(after.contains("return;"), after)
        XCTAssertFalse(after.contains("unresolved_return_contract"), after)
    }

    func testConsumerBackedCalleeResultAuthorityReachesPrinterWithoutProducerOnlyPromotion() throws {
        let operations = [("stp", "x29, x30, [sp, #-16]!"), ("bl", "_table_callee"),
                          ("ldp", "x29, x30, [sp], #16"), ("ret", "")]
        // STP pre-index; BL (0x2000 - 0x1004)/4; LDP post-index; RET x30.
        let bytes = ["fd 7b bf a9", "ff 03 00 94", "fd 7b c1 a8", "c0 03 5f d6"]
        let rows = operations.enumerated().map { index, operation in
            InstructionRow(address: a + UInt64(index * 4), bytes: bytes[index],
                mnemonic: operation.0, operands: operation.1, hasBreakpoint: false, comment: nil)
        }
        let shape = ReturnContract.ReturnShape.gpr(width: 64, type: "uint64_t")
        let facts = [a: Facts(sources: spans(a, operations), resolvedTargets: [a + 4: b]),
                     b: Facts(header: header(.value(shape)), producers: [.constant],
                              exits: [.returnInstruction(b)]), d: Facts()]
        let forwarding = CallSiteContract(address: a + 4, target: .direct(b),
            consumption: .flowsToReturn, isTailCall: false)
        let unread = build(facts, sites: [a: [forwarding], d: [site(d, a)]])
        XCTAssertEqual(unread.entries[a]?.kind, .unresolved(.producerOnly))
        let consumed = build(facts, sites: [a: [forwarding],
            d: [site(d, a, .read(width: 64, type: "uint64_t"))]])
        let contract = try XCTUnwrap(consumed.entries[a])
        XCTAssertEqual(contract.kind, .value(shape))
        XCTAssertEqual(contract.tier, .derived)
        var input = returnContractInput(rows)
        input.authoredCallSignaturesByTarget = ["_table_callee": .init(returnType: "uint64_t", args: [])]
        var producerOnly = input
        producerOnly.admitReturnContract(try XCTUnwrap(unread.entries[a]), enabled: true)
        XCTAssertEqual(producerOnly, input)
        XCTAssertEqual(renderedContractFunction(producerOnly).returnValue,
                       .unknown("unresolved_return_contract"))
        var off = input
        off.admitReturnContract(contract, enabled: false)
        XCTAssertEqual(off, input)
        input.admitReturnContract(contract, enabled: true)
        XCTAssertEqual(input.callerReturnWidth, .x0)
        XCTAssertEqual(input.callerReturnType, "uint64_t")
        let function = renderedContractFunction(input)
        guard case let .call(_, result?) = function.instructions.first(where: {
            if case .call = $0.operation { return true }; return false
        })?.operation else { return XCTFail("expected the same-source callee result") }
        XCTAssertEqual(function.returnValue, result)
        XCTAssertEqual(function.instructions.last?.operation, .returnValue(result))
        let text = PseudocodePrinter().print(function: function).text
        XCTAssertTrue(text.contains("uint64_t _table_render_fixture("), text)
        XCTAssertTrue(text.contains("_table_callee("), text)
        XCTAssertTrue(text.contains("return "), text)
        XCTAssertFalse(text.contains("unresolved_return_contract"), text)
    }

    func testReturnContractHandoffPreservesPrecedenceAndEveryRefusal() {
        let original = returnContractInput([])
        let value = header(.value(.gpr(width: 64, type: "uint64_t")))
        for reason in ReturnContract.Reason.allCases {
            var input = original
            input.admitReturnContract(.init(kind: .unresolved(reason), tier: nil, evidence: []), enabled: true)
            XCTAssertEqual(input, original, reason.rawValue)
        }
        for kind: ReturnContract.Kind in [.noReturn, .value(.fpr(width: 64, type: "double")),
            .value(.hfa(count: 2, element: "double")), .value(.gprPair(type: "pair")),
            .value(.indirect(type: "large")), .value(.gpr(width: 16, type: nil))] {
            var input = original
            input.admitReturnContract(header(kind), enabled: true)
            XCTAssertEqual(input, original)
        }
        for contract in [ReturnContract(kind: .void, tier: nil, evidence: []),
                         ReturnContract(kind: .void, tier: .derived, evidence: []),
                         ReturnContract(kind: .value(.gpr(width: 64, type: "double")),
                            tier: .header, evidence: [.init(source: .header, at: a, detail: "mismatched carrier")])] {
            var input = original
            input.admitReturnContract(contract, enabled: true)
            XCTAssertEqual(input, original)
        }
        var declared = original
        declared.signatureOverrides[a] = .init(returnType: "void", args: [])
        let declaration = declared
        declared.admitReturnContract(value, enabled: true)
        XCTAssertEqual(declared, declaration)
        var existing = original
        existing.callerReturnType = "void"
        let existingType = existing
        existing.admitReturnContract(value, enabled: true)
        XCTAssertEqual(existing, existingType)
        var narrow = original
        narrow.callerReturnWidth = .w0
        let narrowWidth = narrow
        narrow.admitReturnContract(value, enabled: true)
        narrow.admitReturnContract(header(.void), enabled: true)
        XCTAssertEqual(narrow, narrowWidth)
        var catalog = original
        catalog.functionName = "_strlen"
        let catalogInput = catalog
        catalog.admitReturnContract(header(.void), enabled: true)
        XCTAssertEqual(catalog, catalogInput)
        var unnamed = original
        unnamed.admitReturnContract(header(.value(.gpr(width: 32, type: nil))), enabled: true)
        XCTAssertEqual(unnamed, original, "width-only authority must not admit an unrelated FP result or invent a type")
    }

    private func missingVoidTailSnapshot(wrapperName: String = "_table_wrapper") -> WorkspaceSnapshot {
        var analysis = ImageAnalysis()
        analysis.functions = [
            FunctionSummary(id: UUID(), name: wrapperName, startAddress: a, endAddress: a + 4, confidence: 1),
            FunctionSummary(id: UUID(), name: "_table_callee", startAddress: b, endAddress: b + 4, confidence: 1)
        ]
        analysis.instructions = [
            InstructionRow(address: a, bytes: "00 04 00 14", mnemonic: "b", operands: "0x2000",
                hasBreakpoint: false, comment: nil),
            InstructionRow(address: b, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "",
                hasBreakpoint: false, comment: nil)
        ]
        var snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        snapshot.insertImage(binary: BinaryImage(id: UUID(), name: "fixture", path: "/fixture/table-tail",
            kind: "executable", architecture: "arm64", slot: .primary), analysis: analysis)
        snapshot.addressOverrides[.primary(b)] = AddressOverride(signature: .init(returnType: "void", args: []))
        return snapshot
    }

    func testMissingContractWorkspaceHandoffIsFlagGatedAndDoesNotComputeColdTable() throws {
        let service = DocumentExportService()
        XCTAssertFalse(MacIRConfiguration.installedTestBaseline?.returnContract ?? false)
        let absent = missingVoidTailSnapshot()
        let absentInput = absent.pseudocodeRenderInput(selectedAddress: a, in: .primary)
        XCTAssertNil(absentInput.callerReturnType)
        let absentText = service.pseudocodeText(for: absentInput, options: .default)
        MacIRConfiguration.$returnContractOverride.withValue(false) {
            let off = missingVoidTailSnapshot()
            let offInput = off.pseudocodeRenderInput(selectedAddress: a, in: .primary)
            XCTAssertNil(offInput.callerReturnType)
            XCTAssertEqual(service.pseudocodeText(for: offInput, options: .default), absentText)
        }
        try MacIRConfiguration.$returnContractOverride.withValue(true) {
            let on = missingVoidTailSnapshot()
            let cold = on.pseudocodeRenderInput(selectedAddress: a, in: .primary)
            XCTAssertNil(on.returnContractTable(in: .primary, compute: false))
            XCTAssertNil(cold.callerReturnType, "handoff must not trigger table computation")
            XCTAssertNotNil(on.imageWideIndirectCalls(in: .primary, compute: true))
            let table = try XCTUnwrap(on.returnContractTable(in: .primary, compute: false))
            XCTAssertEqual(table.entries[a]?.kind, .void)
            let warm = on.pseudocodeRenderInput(selectedAddress: a, in: .primary)
            XCTAssertEqual(warm.callerReturnType, "void")
            let text = service.pseudocodeText(for: warm, options: .default)
            XCTAssertNotEqual(text, absentText)
            XCTAssertTrue(text.contains("void _table_wrapper("), text)
            XCTAssertEqual(warm.instructions, cold.instructions)
            XCTAssertEqual(warm.signatureOverrides, cold.signatureOverrides)
            var renamedCatalog = missingVoidTailSnapshot(wrapperName: "_strlen")
            renamedCatalog.addressOverrides[.primary(a)] = AddressOverride(customName: "_renamed_for_display")
            XCTAssertNotNil(renamedCatalog.imageWideIndirectCalls(in: .primary, compute: true))
            let catalogInput = renamedCatalog.pseudocodeRenderInput(selectedAddress: a, in: .primary)
            XCTAssertEqual(catalogInput.functionName, "_renamed_for_display")
            XCTAssertNil(catalogInput.callerReturnType, "presentation renaming must not bypass original catalog authority")
        }
    }

    func testGPRHandoffDoesNotBorrowLaterFPScratchCarrier() throws {
        let rows = [
            InstructionRow(address: a, bytes: "e0 00 80 d2", mnemonic: "mov", operands: "x0, #7",
                hasBreakpoint: false, comment: nil),
            InstructionRow(address: a + 4, bytes: "40 00 67 9e", mnemonic: "fmov", operands: "d0, x2",
                hasBreakpoint: false, comment: nil),
            InstructionRow(address: a + 8, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "",
                hasBreakpoint: false, comment: nil)
        ]
        let original = returnContractInput(rows)
        var unnamed = original
        unnamed.admitReturnContract(header(.value(.gpr(width: 64, type: nil))), enabled: true)
        XCTAssertEqual(unnamed, original)
        var typed = original
        typed.admitReturnContract(header(.value(.gpr(width: 64, type: "uint64_t"))), enabled: true)
        let function = renderedContractFunction(typed)
        guard case let .assign(destination, _) = function.instructions.first?.operation else {
            return XCTFail("expected authored integer producer")
        }
        XCTAssertEqual(function.returnValue, destination, "the GPR declaration must select x0, not the later d0 write")
        let text = PseudocodePrinter().print(function: function).text
        XCTAssertFalse(text.contains("return d0"), text)
        XCTAssertFalse(text.contains("unresolved_return_contract"), text)
    }

    func testTyped32BitGPRHandoffSelectsW0WithoutWidening() throws {
        let rows = [
            InstructionRow(address: a, bytes: "e0 03 01 2a", mnemonic: "mov", operands: "w0, w1",
                hasBreakpoint: false, comment: nil),
            InstructionRow(address: a + 4, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "",
                hasBreakpoint: false, comment: nil)
        ]
        var input = returnContractInput(rows)
        input.admitReturnContract(header(.value(.gpr(width: 32, type: "uint32_t"))), enabled: true)
        XCTAssertEqual(input.callerReturnWidth, .w0)
        XCTAssertEqual(input.callerReturnType, "uint32_t")
        let function = renderedContractFunction(input)
        guard case let .assign(destination, _) = function.instructions.first?.operation else {
            return XCTFail("expected authored 32-bit producer")
        }
        XCTAssertEqual(function.returnValue, destination)
        let text = PseudocodePrinter().print(function: function).text
        XCTAssertTrue(text.contains("uint32_t _table_render_fixture("), text)
        XCTAssertFalse(text.contains("unresolved_return_contract"), text)
    }

    // Byte-bearing regression fixtures keep observational discard
    // separate from own-return authority. No new production proof is installed.
    private func discardCounterexampleIR(_ start: UInt64,
                           _ operations: [(String, String, String)]) -> MacIRFunction {
        let rows = operations.enumerated().map {
            InstructionRow(address: start + UInt64($0.offset * 4), bytes: $0.element.0,
                           mnemonic: $0.element.1, operands: $0.element.2,
                           hasBreakpoint: false, comment: nil)
        }
        return MacIRBuilder().buildFunction(name: "discard_counterexample", startAddress: start, instructions: rows)
    }

    private func withDiscardCounterexampleModes(_ body: () throws -> Void) rethrows {
        for ssa in [false, true] {
            try MacIRConfiguration.$ssaOverride.withValue(ssa) {
                for enabled in [false, true] {
                    try MacIRConfiguration.$returnContractOverride.withValue(enabled) { try body() }
                }
            }
        }
    }

    private func discardCounterexampleTable(_ callers: [MacIRFunction], exported: Set<UInt64> = [],
                              addressTaken: Set<UInt64> = [],
                              authority: ReturnContract? = nil) -> ReturnContractTable {
        let callee = discardCounterexampleIR(a, [("e0 00 80 52", "mov", "w0, #7"),
                                   ("c0 03 5f d6", "ret", "")])
        let functions = [callee] + callers
        let sites = MacIRCallerReturnEvidence.collectCallSites(functions: functions)
        var facts: [UInt64: Facts] = [:]
        for function in functions {
            facts[function.startAddress] = Facts(
                sources: function.instructions.map(\.source))
        }
        facts[a]?.header = authority
        return build(facts, sites: sites, exported: exported, addressTaken: addressTaken)
    }

    private func discardCounterexampleCaller(_ start: UInt64 = 0x2000) -> MacIRFunction {
        // Save/restore LR around BL. Encodings are for a=0x1000 and PC=start+4.
        precondition(start == b || start == c)
        return discardCounterexampleIR(start, [("fd 7b bf a9", "stp", "x29, x30, [sp, #-0x10]!"),
            (start == b ? "ff fb ff 97" : "ff f7 ff 97", "bl", "0x1000"),
            ("00 00 80 52", "mov", "w0, #0"),
            ("fd 7b c1 a8", "ldp", "x29, x30, [sp], #0x10"),
            ("c0 03 5f d6", "ret", "")])
    }

    private func assertDiscardCounterexampleRefused(_ table: ReturnContractTable,
                                      _ reason: ReturnContract.Reason,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(table.entries[a]?.kind, .unresolved(reason), file: file, line: line)
        XCTAssertNotEqual(table.entries[a]?.kind, .void, file: file, line: line)
        XCTAssertFalse(table.entries[a]?.evidence.contains {
            $0.detail == "existing complete closed-world certificate"
        } ?? true, file: file, line: line)
    }

    func testDiscardedResultAddressTakenStoreRefusesVoidBothModes() {
        withDiscardCounterexampleModes {
            // ADR x8,+16 forms a at 0xff0; STR stores the function pointer.
            // This literal image fact is not inferred from a discarded call.
            let installer = discardCounterexampleIR(a - 16, [("88 00 00 10", "adr", "x8, 0x1000"),
                ("28 00 00 f9", "str", "x8, [x1]"), ("c0 03 5f d6", "ret", "")])
            let table = discardCounterexampleTable([discardCounterexampleCaller(), installer], addressTaken: [a])
            XCTAssertEqual(table.callSites[b]?.first?.consumption, .discarded)
            assertDiscardCounterexampleRefused(table, .openWorld)
        }
    }

    func testDiscardedResultAddressTakenRebaseRefusesVoidBothModes() {
        withDiscardCounterexampleModes {
            // A data-cell rebase to a establishes address-taking independently
            // of the instruction bytes and both direct callers' kills.
            let rebaseTarget: UInt64 = 0x1000
            let table = discardCounterexampleTable([discardCounterexampleCaller(), discardCounterexampleCaller(c)],
                                    addressTaken: [rebaseTarget])
            XCTAssertEqual(table.callSites[b]?.first?.consumption, .discarded)
            XCTAssertEqual(table.callSites[c]?.first?.consumption, .discarded)
            assertDiscardCounterexampleRefused(table, .openWorld)
        }
    }

    func testDiscardedResultExportedWithDiscardRefusesVoidBothModes() {
        withDiscardCounterexampleModes {
            let table = discardCounterexampleTable([discardCounterexampleCaller()], exported: [a])
            XCTAssertEqual(table.callSites[b]?.first?.consumption, .discarded)
            assertDiscardCounterexampleRefused(table, .openWorld)
        }
    }

    func testDiscardedResultExportedWithTwoDiscardsRefusesVoidBothModes() {
        withDiscardCounterexampleModes {
            // More dead internal callers do not bound callers outside the image.
            let table = discardCounterexampleTable([discardCounterexampleCaller(), discardCounterexampleCaller(c)],
                                    exported: [a])
            XCTAssertEqual(table.callSites[b]?.first?.consumption, .discarded)
            XCTAssertEqual(table.callSites[c]?.first?.consumption, .discarded)
            assertDiscardCounterexampleRefused(table, .openWorld)
        }
    }

    func testDiscardedResultUnknownContinuationRefusesVoidBothModes() {
        withDiscardCounterexampleModes {
            // Deliberately unproved transfer: no modeled return/kill after this BL.
            let unknown = discardCounterexampleIR(b, [("00 fc ff 97", "bl", "0x1000"),
                                        ("00 01 1f d6", "br", "x8")])
            let table = discardCounterexampleTable([unknown])
            XCTAssertEqual(table.callSites[b]?.first?.consumption, .unknown)
            assertDiscardCounterexampleRefused(table, .callerUnproven)
        }
    }

    func testDiscardedResultOneUnknownOfTwoCallersRefusesVoidBothModes() {
        withDiscardCounterexampleModes {
            // Deliberately unproved transfer, not a claimed ABI-complete returning caller.
            let unknown = discardCounterexampleIR(c, [("00 f8 ff 97", "bl", "0x1000"),
                                        ("00 01 1f d6", "br", "x8")])
            let table = discardCounterexampleTable([discardCounterexampleCaller(), unknown])
            XCTAssertEqual(table.callSites[b]?.first?.consumption, .discarded)
            XCTAssertEqual(table.callSites[c]?.first?.consumption, .unknown)
            assertDiscardCounterexampleRefused(table, .callerUnproven)
        }
    }

    func testDiscardedResultDirectTailForwardingRefusesVoidBothModes() {
        withDiscardCounterexampleModes {
            let tail = discardCounterexampleIR(b, [("00 fc ff 17", "b", "0x1000")])
            let table = discardCounterexampleTable([tail])
            XCTAssertEqual(table.callSites[b]?.first?.consumption, .flowsToReturn)
            XCTAssertEqual(table.callSites[b]?.first?.isTailCall, true)
            assertDiscardCounterexampleRefused(table, .producerOnly)
        }
    }

    func testDiscardedResultTailAndDiscardRefuseVoidBothModes() {
        withDiscardCounterexampleModes {
            let tail = discardCounterexampleIR(c, [("00 f8 ff 17", "b", "0x1000")])
            let table = discardCounterexampleTable([discardCounterexampleCaller(), tail])
            XCTAssertEqual(table.callSites[b]?.first?.consumption, .discarded)
            XCTAssertEqual(table.callSites[c]?.first?.consumption, .flowsToReturn)
            XCTAssertEqual(table.callSites[c]?.first?.isTailCall, true)
            assertDiscardCounterexampleRefused(table, .producerOnly)
        }
    }

    func testDiscardedResultDiscardedDeclaredIntRemainsIntBothModes() {
        withDiscardCounterexampleModes {
            let declared = header(.value(.gpr(width: 32, type: "int")))
            let table = discardCounterexampleTable([discardCounterexampleCaller()], authority: declared)
            XCTAssertEqual(table.callSites[b]?.first?.consumption, .discarded)
            XCTAssertEqual(table.entries[a]?.kind, declared.kind)
            XCTAssertEqual(table.entries[a]?.tier, .header)
        }
    }

    func testDiscardedResultTwoDiscardersDoNotEstablishVoidBothModes() {
        withDiscardCounterexampleModes {
            let table = discardCounterexampleTable([discardCounterexampleCaller(), discardCounterexampleCaller(c)])
            XCTAssertEqual(table.callSites[b]?.first?.consumption, .discarded)
            XCTAssertEqual(table.callSites[c]?.first?.consumption, .discarded)
            assertDiscardCounterexampleRefused(table, .producerOnly)
        }
    }

}
