import XCTest
@testable import MacScope

final class ReturnContractGuardedZeroTests: XCTestCase {
    private let a: UInt64 = 0x1000
    private let caller: UInt64 = 0x4000
    private typealias Operation = (String, String)

    // Explicit source rows are the fixtures; no decoder is invoked.
    private func sources(_ operations: [Operation]) -> [MacIRSourceSpan] {
        let rows = operations.enumerated().map { index, operation in
            InstructionRow(address: a + UInt64(index * 4), bytes: "",
                mnemonic: operation.0, operands: operation.1, hasBreakpoint: false, comment: nil)
        }
        return rows.map { MacIRSourceSpan(address: $0.address, byteText: $0.bytes,
            mnemonic: $0.mnemonic, operands: $0.operands) }
    }
    private var framedUnknownCall: [Operation] {
        [("stp", "x29, x30, [sp, #-16]!"), ("blr", "x8"), ("ldp", "x29, x30, [sp], #16")]
    }
    private func zeroTaken(_ register: String = "x0") -> [Operation] {
        framedUnknownCall + [("cbz", "\(register), 0x1014"), ("mov", "w0, #1"), ("ret", "")]
    }
    private func zeroFallthrough(_ register: String = "x0") -> [Operation] {
        framedUnknownCall + [("cbnz", "\(register), 0x1014"), ("ret", ""), ("mov", "w0, #1"), ("ret", "")]
    }
    private func contract(_ operations: [Operation], width: Int = 64,
                          type: String? = "uint64_t", enabled: Bool = true,
                          consumption: CallSiteContract.Consumption? = nil,
                          extraConsumption: CallSiteContract.Consumption? = nil) throws -> ReturnContract {
        try MacIRConfiguration.$returnContractOverride.withValue(enabled) {
            let facts: [UInt64: ReturnContractTable.LocalFacts] = [
                a: .init(name: "guarded_result", sources: sources(operations)),
                caller: .init(name: "independent_consumer", producers: [.constant], exits: [.returnInstruction(caller)])
            ]
            var sites = [CallSiteContract(address: caller, target: .direct(a),
                consumption: consumption ?? .read(width: width, type: type), isTailCall: false)]
            if let extraConsumption {
                sites.append(.init(address: caller + 4, target: .direct(a), consumption: extraConsumption, isTailCall: false))
            }
            let table = ReturnContractTable.build(key: .init(snapshotID: UUID(), slot: .primary),
                imageFacts: .init(functionStarts: [a, caller], imageComplete: true),
                localFacts: facts, callSites: [caller: sites])
            return try XCTUnwrap(table.entries[a])
        }
    }
    private func assertValue(_ operations: [Operation], width: Int, type: String,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let result = try contract(operations, width: width, type: type)
        XCTAssertEqual(result.kind, .value(.gpr(width: width, type: type)), file: file, line: line)
        XCTAssertEqual(result.tier, .derived, file: file, line: line)
        XCTAssertTrue(result.evidence.contains { $0.source == .consumer }, file: file, line: line)
        XCTAssertTrue(result.evidence.contains {
            $0.source == .producer && $0.detail.contains("guardedZero")
        }, file: file, line: line)
    }
    private func assertRefused(_ operations: [Operation], reason: ReturnContract.Reason,
                               width: Int = 64, type: String? = "uint64_t", enabled: Bool = true,
                               consumption: CallSiteContract.Consumption? = nil,
                               extraConsumption: CallSiteContract.Consumption? = nil,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let result = try contract(operations, width: width, type: type, enabled: enabled,
            consumption: consumption, extraConsumption: extraConsumption)
        XCTAssertEqual(result.kind, .unresolved(reason), file: file, line: line)
        XCTAssertNil(result.tier, file: file, line: line)
    }

    func testX0CBZTakenPreservesIndependentUInt64Contract() throws {
        try assertValue(zeroTaken(), width: 64, type: "uint64_t")
    }
    func testW0CBZTakenPreservesIndependentUInt32Contract() throws {
        try assertValue(zeroTaken("w0"), width: 32, type: "uint32_t")
    }
    func testX0CBNZFallthroughPreservesIndependentInt64Contract() throws {
        try assertValue(zeroFallthrough(), width: 64, type: "int64_t")
    }
    func testW0CBNZFallthroughPreservesIndependentInt32Contract() throws {
        try assertValue(zeroFallthrough("w0"), width: 32, type: "int32_t")
    }
    func testWideZeroPredicateCanSupportNarrowDeclaredResultWithoutInventingType() throws {
        try assertValue(zeroTaken(), width: 32, type: "int32_t")
    }
    func testZeroEdgeMayReachSharedReturnThroughUnconditionalBranch() throws {
        let rows = framedUnknownCall + [("cbz", "x0, 0x1018"), ("mov", "w0, #1"),
            ("b", "0x101c"), ("b", "0x101c"), ("ret", "")]
        try assertValue(rows, width: 64, type: "uint64_t")
    }
    func testRenamedCarrierCopyUsesTheGuardedRegisterAndDeclaredType() throws {
        let rows = framedUnknownCall + [("mov", "x9, x0"), ("cbz", "x9, 0x101c"),
            ("mov", "w0, #1"), ("b", "0x1020"), ("mov", "x0, x9"), ("ret", "")]
        try assertValue(rows, width: 64, type: "int64_t")
    }
    func testSeparateZeroAndConstantReturnsKeepExactDeclaredPointerType() throws {
        let rows = framedUnknownCall + [("cbz", "x0, 0x101c"), ("mov", "x0, #1"),
            ("ret", ""), ("nop", ""), ("ret", "")]
        try assertValue(rows, width: 64, type: "void *")
    }

    func testNonzeroEdgeDoesNotProveAZeroProducer() throws {
        let rows = framedUnknownCall + [("cbnz", "x0, 0x1014"), ("mov", "w0, #1"), ("ret", "")]
        try assertRefused(rows, reason: .contractWithoutProducer)
    }
    func testGuardOnAnotherRegisterCannotValidateX0() throws {
        try assertRefused(zeroTaken("x9"), reason: .contractWithoutProducer)
    }
    func testIdenticalTargetAndFallthroughDoesNotConstrainCarrier() throws {
        let rows = framedUnknownCall + [("cbz", "x0, 0x1010"), ("ret", "")]
        try assertRefused(rows, reason: .contractWithoutProducer)
    }
    func testEntryBypassRequiresProducerOnEveryReturnPath() throws {
        let rows: [Operation] = [("cbz", "x1, 0x101c"), ("stp", "x29, x30, [sp, #-16]!"),
            ("blr", "x8"), ("ldp", "x29, x30, [sp], #16"), ("cbz", "x0, 0x101c"),
            ("mov", "w0, #1"), ("nop", ""), ("ret", "")]
        try assertRefused(rows, reason: .contractWithoutProducer)
    }
    func testCallAfterZeroPredicateClobbersItsProducerEvidence() throws {
        let rows = framedUnknownCall + [("cbz", "x0, 0x1018"), ("mov", "w0, #1"),
            ("b", "0x1024"), ("stp", "x29, x30, [sp, #-16]!"), ("blr", "x9"),
            ("ldp", "x29, x30, [sp], #16"), ("ret", "")]
        try assertRefused(rows, reason: .contractWithoutProducer)
    }
    func testW0ZeroPredicateDoesNotEstablishUpperBitsOfUInt64Result() throws {
        try assertRefused(zeroTaken("w0"), reason: .contractWithoutProducer, width: 64, type: "uint64_t")
    }
    func testUntypedConsumerDoesNotTurnZeroWidthIntoSourceType() throws {
        try assertRefused(zeroTaken(), reason: .contractWithoutProducer, type: nil)
    }
    func testDiscardingCallerLeavesGuardedProducerOnly() throws {
        try assertRefused(zeroTaken(), reason: .producerOnly, consumption: .discarded)
    }
    func testExplicitDisabledScopeKeepsUnknownCallResultRefusal() throws {
        try assertRefused(zeroTaken(), reason: .contractWithoutProducer, enabled: false)
    }
    func testUnmodeledReachableRowCannotBeBypassedByZeroEvidence() throws {
        let rows = framedUnknownCall + [("cbz", "x0, 0x1018"), ("mov", "w0, #1"),
            ("b", "0x101c"), ("opaque_fixture", "x2"), ("ret", "")]
        try assertRefused(rows, reason: .contractWithoutProducer)
    }
    func testConflictingIndependentWidthsRemainConflict() throws {
        try assertRefused(zeroTaken(), reason: .conflict,
            extraConsumption: .read(width: 32, type: "uint32_t"))
    }
    func testKnownCalleeProducerIsNotReplacedByNarrowGuardFallback() {
        let rows = sources([("stp", "x29, x30, [sp, #-16]!"), ("bl", "0x2000"),
            ("ldp", "x29, x30, [sp], #16"), ("cbz", "w0, 0x1014"),
            ("mov", "w0, #1"), ("ret", "")])
        let off = MacIRConfiguration.$returnContractOverride.withValue(false) {
            BuilderState.returnContractProducerFacts(sources: rows, entry: a,
                resolvedTargetsByCallSite: [a + 4: 0x2000])
        }
        let on = MacIRConfiguration.$returnContractOverride.withValue(true) {
            BuilderState.returnContractProducerFacts(sources: rows, entry: a,
                resolvedTargetsByCallSite: [a + 4: 0x2000])
        }
        XCTAssertEqual(on, off, "existing known callee authority must retain its full shape")
        XCTAssertEqual(on.producers[a + 20], [.calleeResult(0x2000), .constant])
        MacIRConfiguration.$returnContractOverride.withValue(true) {
            let shape = ReturnContract.ReturnShape.gpr(width: 64, type: "uint64_t")
            let declared = ReturnContract(kind: .value(shape), tier: .header,
                evidence: [.init(source: .header, at: 0x2000, detail: "declared callee result")])
            let facts: [UInt64: ReturnContractTable.LocalFacts] = [
                a: .init(sources: rows, resolvedTargets: [a + 4: 0x2000]),
                0x2000: .init(header: declared, producers: [.constant], exits: [.returnInstruction(0x2000)]),
                caller: .init(producers: [.constant], exits: [.returnInstruction(caller)])
            ]
            let table = ReturnContractTable.build(key: .init(snapshotID: UUID(), slot: .primary),
                imageFacts: .init(functionStarts: [a, 0x2000, caller], imageComplete: true),
                localFacts: facts, callSites: [caller: [.init(address: caller, target: .direct(a),
                    consumption: .read(width: 64, type: "uint64_t"), isTailCall: false)]])
            XCTAssertEqual(table.entries[a]?.kind, .value(shape))
        }
    }

    func testIndependentHeaderAndCatalogAuthorityAreNotReplacedByGuardWidth() throws {
        try MacIRConfiguration.$returnContractOverride.withValue(true) {
            // Only independent own declarations enter LocalFacts.header. A slot
            // observation must not be relabeled as one to bypass its refusal.
            for source: Evidence.Source in [.header, .catalog] {
                for kind: ReturnContract.Kind in [.void, .value(.gpr(width: 64, type: "uint64_t"))] {
                    let declared = ReturnContract(kind: kind, tier: .header,
                        evidence: [.init(source: source, at: a, detail: "independent declared authority")])
                    let facts: [UInt64: ReturnContractTable.LocalFacts] = [
                        a: .init(header: declared, sources: sources(zeroTaken("w0")))
                    ]
                    let table = ReturnContractTable.build(key: .init(snapshotID: UUID(), slot: .primary),
                        imageFacts: .init(functionStarts: [a], imageComplete: true),
                        localFacts: facts, callSites: [:])
                    let result = try XCTUnwrap(table.entries[a])
                    XCTAssertEqual(result.kind, kind)
                    XCTAssertEqual(result.tier, .header)
                }
            }
        }
    }

    func testAbsentAndFalsePreferenceKeepCompleteProducerFactsEqual() throws {
        guard MacIRConfiguration.installedTestBaseline == nil else {
            throw XCTSkip("Preference fallback is inactive with an installed baseline")
        }
        let defaults = UserDefaults.standard
        let key = "MacScopeReturnContractTable"
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let rows = sources(zeroTaken())
        MacIRConfiguration.$returnContractOverride.withValue(nil) {
            defaults.removeObject(forKey: key)
            let absent = BuilderState.returnContractProducerFacts(sources: rows, entry: a)
            defaults.set(false, forKey: key)
            let off = BuilderState.returnContractProducerFacts(sources: rows, entry: a)
            XCTAssertEqual(absent, off)
            XCTAssertEqual(off.producers[a + 20], [.unknown, .constant])
        }
    }

    private func guardedRenderInput(_ register: String,
                                    name: String = "_guarded_render_fixture") -> PseudocodeRenderInput {
        // Authored STP; BLR x8; LDP; CBZ {W0,X0}, +8; MOV W0,#1; RET.
        // The table and printer receive the same instruction addresses and operands.
        let bytes = ["fd 7b bf a9", "00 01 3f d6", "fd 7b c1 a8",
                     register == "w0" ? "40 00 00 34" : "40 00 00 b4",
                     "20 00 80 52", "c0 03 5f d6"]
        let rows = zeroTaken(register).enumerated().map { index, operation in
            InstructionRow(address: a + UInt64(index * 4), bytes: bytes[index],
                mnemonic: operation.0, operands: operation.1, hasBreakpoint: false, comment: nil)
        }
        return PseudocodeRenderInput(imageSlot: .primary, functionName: name,
            startAddress: a, jumpTables: [:], objcSelectors: [:], nameOverrides: [:],
            signatureOverrides: [:], registerNameOverrides: [:], types: [], instructions: rows,
            callerReturnWidth: nil)
    }

    private func guardedRenderedFunction(_ input: PseudocodeRenderInput) -> MacIRFunction {
        PseudocodePrinter().buildFunction(functionName: input.functionName, startAddress: input.startAddress,
            signatureOverrides: input.signatureOverrides,
            authoredCallSignaturesByTarget: input.authoredCallSignaturesByTarget,
            callerReturnWidth: input.callerReturnWidth, callerReturnType: input.callerReturnType,
            types: input.types, instructions: input.instructions)
    }

    func testGuardedW0WidthRefusalSurvivesRenderingWithX0PositiveControl() throws {
        try MacIRConfiguration.$returnContractOverride.withValue(true) {
            for register in ["w0", "x0"] {
                let width = register == "w0" ? 32 : 64
                let rows = sources(zeroTaken(register))
                let producers = BuilderState.returnContractProducerFacts(sources: rows, entry: a)
                XCTAssertEqual(producers.producers[a + 20], [.guardedZero(width: width), .constant])
                let result = try contract(zeroTaken(register), width: 64, type: "uint64_t")
                let original = guardedRenderInput(register)
                var input = original
                input.admitReturnContract(result, enabled: true)
                let function = guardedRenderedFunction(input)
                let text = PseudocodePrinter().print(function: function).text
                XCTAssertTrue(function.instructions.contains { $0.source.address == a + 20 },
                              "the authored return must reach rendering")
                if register == "w0" {
                    XCTAssertEqual(result.kind, .unresolved(.contractWithoutProducer))
                    XCTAssertNil(result.tier)
                    XCTAssertEqual(input, original)
                    XCTAssertNil(input.callerReturnType)
                    XCTAssertNil(input.callerReturnWidth)
                    XCTAssertNotEqual(function.returnType, "uint64_t")
                    XCTAssertFalse(text.contains("uint64_t _guarded_render_fixture("), text)
                    let baseline = PseudocodePrinter().print(function: guardedRenderedFunction(original)).text
                    XCTAssertEqual(text, baseline, "refusal must survive the complete rendering handoff")
                } else {
                    XCTAssertEqual(result.kind, .value(.gpr(width: 64, type: "uint64_t")))
                    XCTAssertEqual(result.tier, .derived)
                    XCTAssertEqual(input.callerReturnType, "uint64_t")
                    XCTAssertEqual(input.callerReturnWidth, .x0)
                    XCTAssertEqual(function.returnType, "uint64_t")
                    XCTAssertTrue(text.contains("uint64_t _guarded_render_fixture("), text)
                }
            }
        }
    }

    func testGuardedZeroDerivedContractCannotReplaceRenderedHeaderOrCatalogAuthority() throws {
        try MacIRConfiguration.$returnContractOverride.withValue(true) {
            let derived = try contract(zeroTaken("w0"), width: 32, type: "uint32_t")
            XCTAssertEqual(derived.kind, .value(.gpr(width: 32, type: "uint32_t")))
            XCTAssertEqual(derived.tier, .derived)
            XCTAssertTrue(derived.evidence.contains {
                $0.source == .producer && $0.detail.contains("guardedZero")
            })
            // Positive control: without authority, this very producer-backed entry
            // must affect the printed declaration; an inert handoff cannot pass.
            var unclaimed = guardedRenderInput("w0")
            unclaimed.admitReturnContract(derived, enabled: true)
            XCTAssertEqual(unclaimed.callerReturnType, "uint32_t")
            let claimed = guardedRenderedFunction(unclaimed)
            XCTAssertEqual(claimed.returnType, "uint32_t")
            XCTAssertTrue(PseudocodePrinter().print(function: claimed).text
                .contains("uint32_t _guarded_render_fixture("))

            var header = guardedRenderInput("w0")
            header.signatureOverrides[a] = .init(returnType: "void", args: [])
            let catalog = guardedRenderInput("w0", name: "_strlen")
            let catalogSignature = try XCTUnwrap(CallSignatureCatalog.standard.signature(for: "_strlen"))
            XCTAssertNotEqual(catalogSignature.returnType, "uint32_t",
                              "catalog authority must conflict with the proposed derived type")
            // buildFunction does not apply a catalog signature to the function header.
            // Catalog precedence here means preserving its untouched rendering,
            // not synthesizing a catalog-typed header inside this test helper.
            let catalogBaseline = guardedRenderedFunction(catalog)
            XCTAssertNotEqual(catalogBaseline.returnType, "uint32_t")
            for (original, expectedType) in [(header, "void"), (catalog, catalogBaseline.returnType)] {
                var input = original
                input.admitReturnContract(derived, enabled: true)
                XCTAssertEqual(input, original, "derived evidence cannot replace existing authority")
                XCTAssertNil(input.callerReturnType)
                XCTAssertNil(input.callerReturnWidth)
                let function = guardedRenderedFunction(input)
                XCTAssertEqual(function.returnType, expectedType)
                let text = PseudocodePrinter().print(function: function).text
                XCTAssertTrue(text.contains("\(expectedType) \(input.functionName)("), text)
                XCTAssertFalse(text.contains("uint32_t \(input.functionName)("), text)
                XCTAssertEqual(text, PseudocodePrinter().print(function: guardedRenderedFunction(original)).text)
            }
        }
    }


}
