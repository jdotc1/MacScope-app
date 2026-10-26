import Foundation
import XCTest

/// Focused, newly authored grammar/evaluation controls. These are NOT real
/// binary coverage and cannot substitute for the five semantic selectors.
final class OrdinaryCParserTests: XCTestCase {
    func testAuditSwitchLabelsRemainSeparateFromUserLabels() throws {
        var switches = OrdinaryCOutputAudit.Parser(tokens: try OrdinaryCOutputAudit.lex("""
        void sample(int value) {
            switch (value) {
                case 1: { break; }
                default: { break; }
            }
            switch (value) {
                case 2: { break; }
                default: { break; }
            }
        }
        """))
        try switches.parse()
        XCTAssertTrue(switches.errors.isEmpty, "case/default labels do not declare user labels")
        XCTAssertTrue(switches.labels.isEmpty, "switch labels must reach the switch-label handler")
        XCTAssertEqual(switches.transferScope.count, 4, "all case/default bodies are parsed")
        XCTAssertTrue(switches.transferScope.values.allSatisfy { $0 == ["switch"] },
                      "case/default breaks retain their enclosing switch")

        var scope = OrdinaryCOutputAudit.Parser(tokens: try OrdinaryCOutputAudit.lex(
            "void sample(void) { user_label: { value = 1; } }"))
        try scope.parse()
        XCTAssertEqual(scope.errors, ["labelled non-loop scope user_label"])

        var duplicate = OrdinaryCOutputAudit.Parser(tokens: try OrdinaryCOutputAudit.lex(
            "void sample(void) { repeated: value = 1; repeated: value = 2; }"))
        try duplicate.parse()
        XCTAssertEqual(duplicate.errors, ["duplicate label repeated"])
    }

    private typealias C = OrdinaryC
    private enum FailureKind { case syntax, contract, uninitialized, undefined, authority }
    private func require(_ kind: FailureKind, file: StaticString = #filePath, line: UInt = #line,
                         _ action: () throws -> Void) {
        do { try action(); XCTFail("expected fail-closed \(kind)", file: file, line: line) }
        catch let failure as C.Failure {
            switch (kind, failure) {
            case (.syntax, .unsupportedSyntax), (.contract, .invalidContract), (.uninitialized, .uninitializedRead),
                 (.undefined, .undefinedC), (.authority, .callAuthorityViolation): break
            default: XCTFail("wrong failure: \(failure)", file: file, line: line)
            }
        } catch { XCTFail("infrastructure failure: \(error)", file: file, line: line) }
    }
    private struct Unit {
        let program: C.Program
        let scenario: C.Scenario
        func run() throws -> C.Result { try C.Machine(program: program, scenario: scenario).run() }
    }
    private func unit(_ body: [String], memory: [UInt64: UInt8] = [:], effects: [Int: [C.MemoryEffect]] = [:],
                      exterior: [Int: String] = [:], input: UInt64 = 1,
                      call: C.FrozenCall? = nil, permissions: Set<C.Permission> = [], dead: Set<Int> = [],
                      responses: [C.OpaqueResponse] = [], inputType: C.CType = .i64) throws -> Unit {
        let inputDeclaration = inputType == .jpegPointer ? "jpeg_decompress_struct *input" : "int64_t input"
        let signature = "int64_t oracle(\(inputDeclaration)) {", terminal = 999
        var lines: [C.TextLine] = [.init(text: signature, source: nil, envelope: .signature),
                                 .init(text: "// parser unit only, not a third-party positive fixture", source: nil, envelope: .metadata)]
        lines += body.enumerated().map { .init(text: $0.element, source: 0x1000 + UInt64($0.offset * 4), envelope: .body) }
        lines.append(.init(text: "return result; // return", source: 0x1000 + UInt64(terminal * 4), envelope: .body))
        lines.append(.init(text: "}", source: nil, envelope: .closingBrace))
        var rows = Dictionary(uniqueKeysWithValues: body.indices.map { (UInt64(0x1000 + $0 * 4), $0) })
        rows[0x1000 + UInt64(terminal * 4)] = terminal
        let contract = C.Contract(signature: signature, inputs: [.init(name: "input", type: inputType, entrySlot: 0)], fields: [],
            calls: call.map { [$0.row:$0] } ?? [:], exterior: exterior, terminalRow: terminal,
            terminalPayload: "return result; // return", terminalName: "result", returnType: .i64,
            rowsByAddress: rows, allowedLabels: Set(rows.keys.map { "L_" + String($0, radix: 16) }),
            memoryEffects: effects, helpers: Dictionary(uniqueKeysWithValues: body.indices.map { ($0, Set(["__adrp","__a64_sdiv32"])) }),
            deadResults: dead, permissions: permissions)
        return try .init(program: C.Program(lines: lines, contract: contract), scenario: .init(name: "parser-unit",
            inputs: ["input": .init(input, inputType)], memory: memory, responses: responses))
    }
    func testMultipleStatementsCommentsAndNativeGotoAreFullyParsed() throws {
        let result = try unit(["int64_t result; result = 1; goto L_1008; result = 7;",
                               "// goto 0xBAD; break fake; __unknown(ignored)", "L_1008: result = result + 2;"]).run()
        XCTAssertEqual(result.terminal?.bits, 3)
    }
    func testUnknownUnreachableExecutableAndStringDecoysAreRejected() {
        require(.syntax) { _ = try unit(["result = 1; if (false) { unknown_helper(1); }"]) }
        require(.syntax) { _ = try unit(["result = 1; if (false) { tmp = __unknown(\"goto L_1000;\"); }"]) }
        require(.syntax) { _ = try unit(["result = 1; /* unterminated"]) }
        require(.syntax) { _ = try unit(["result = 1; #define value 7"]) }
    }
    func testLabelledTransfersNumericGotoAndNonloopBreakFailClosed() {
        require(.syntax) { _ = try unit(["int64_t result = 0; while (input) { break L_1000; }"]) }
        require(.syntax) { _ = try unit(["int64_t result = 0; while (input) { continue L_1000; }"]) }
        require(.syntax) { _ = try unit(["result = 1; goto 0x1000;"]) }
        require(.syntax) { _ = try unit(["result = 1; L_1000: { break; }"]) }
        require(.syntax) { _ = try unit(["result = 1; L_1000: int64_t value;"]) }
    }
    func testWhileDoForContinueDestinationsAndInnermostBreak() throws {
        let whileResult = try unit(["int64_t result = 0; int64_t count = 4; while (--count != 0) { if (count == 2) continue; result = result + count; }"]).run()
        XCTAssertEqual(whileResult.terminal?.bits, 4)
        let doResult = try unit(["int64_t result = 0; int64_t count = 4; do { if (count == 3) continue; result = result + count; } while (--count != 0);"]).run()
        XCTAssertEqual(doResult.terminal?.bits, 7)
        let forResult = try unit(["int64_t result = 0; int64_t count; for (count = 0; count < 4; ++count) { if (count == 2) continue; int64_t inner = 2; while (inner) { result = result + count; break; } }"]).run()
        XCTAssertEqual(forResult.terminal?.bits, 4)
    }
    func testSkippedInitializerAndUndeclaredMultiDefinitionFail() {
        require(.uninitialized) { _ = try unit(["goto L_1008;", "int64_t result = 7;", "L_1008: ;"]).run() }
        require(.syntax) { _ = try unit(["if (input) result = 1; else result = 2;"]) }
        require(.syntax) { _ = try unit(["result = other + 1; other = result + 1;"]) }
        require(.syntax) { _ = try unit(["int64_t result = 1; { int64_t result = 2; }"]) }
    }
    func testGroupedDeclarationsMeanDistinctUninitializedStorageNotCommaOperator() throws {
        let result = try unit(["uint64_t a, b, c; a = 1; b = 2; c = a + b; result = (int64_t)c;"]).run()
        XCTAssertEqual(result.terminal?.bits, 3)
        require(.uninitialized) { _ = try unit(["int64_t result, uninitialized; result = uninitialized;"]).run() }
        require(.syntax) { _ = try unit(["int64_t a, b = 2; result = b;"]) }
        require(.syntax) { _ = try unit(["result = (1, 2);"]) }
    }
    func testIntegerPromotionsSignedBoundaryAndShiftLeftType() throws {
        let result = try unit(["uint8_t small = 255; result = small + 1;"]).run()
        XCTAssertEqual(result.terminal?.bits, 256)
        let shifted = try unit(["uint32_t narrow = 0xffffffff; uint64_t count = 1; result = (int64_t)(narrow << count);"]).run()
        XCTAssertEqual(shifted.terminal?.bits, 0xffff_fffe, "right64 does not widen promoted-left32")
        let signed = try unit(["uint64_t bits = 0xffffffffffffffff; result = bits < 0x8000000000000000 ? (int64_t)bits : -1 - (int64_t)(~bits);"]).run()
        XCTAssertEqual(signed.terminal?.bits, UInt64.max)
        let carry = try unit(["uint32_t bits = 0xfffffff9; result = (uint32_t)(bits + (uint32_t)7) < (uint32_t)7;"]).run()
        XCTAssertEqual(carry.terminal?.bits, 1)
    }
    func testSignedOverflowUndefinedShiftsAndImplementationDefinedNarrowingRefused() {
        require(.undefined) { _ = try unit(["int32_t value = 0x7fffffff; result = value + 1;"]).run() }
        require(.undefined) { _ = try unit(["result = (int32_t)0xffffffff;"]).run() }
        require(.undefined) { _ = try unit(["result = -1 << 1;"]).run() }
        require(.undefined) { _ = try unit(["result = (uint32_t)1 << (uint64_t)32;"]).run() }
        require(.syntax) { _ = try unit(["uint032_t result = 1;"]) }
        require(.syntax) { _ = try unit(["result = 01;"]) }
        require(.syntax) { _ = try unit(["result = 1U;"]) }
    }
    func testLazyLogicalAndTernaryDoNotReadUntakenUninitializedArm() throws {
        let result = try unit(["int64_t missing; result = (false && missing) || (true ? 1 : missing);"]).run()
        XCTAssertEqual(result.terminal?.bits, 1)
        require(.syntax) { _ = try unit(["result = true ? 1 : missing;"]) }
    }
    func testPreAndPostDecrementTimingAreNotInterchanged() throws {
        let prefix = try unit(["int64_t n = 2; result = --n != 0;"]).run()
        let postfix = try unit(["int64_t n = 1; result = n-- != 0;"]).run()
        XCTAssertEqual(prefix.terminal?.bits, 1); XCTAssertEqual(postfix.terminal?.bits, 1)
        let lastPrefix = try unit(["int64_t n = 1; result = --n != 0;"]).run()
        XCTAssertEqual(lastPrefix.terminal?.bits, 0)
        require(.undefined) { _ = try unit(["int64_t n = 1; result = n++ + n;"]) }
        require(.undefined) { _ = try unit(["int64_t n = 1; n = n++; result = n;"]) }
    }
    func testExplicitUnsignedCastsZeroHighAndSignedLoadExtends() throws {
        let zeroHigh = try unit(["uint64_t value = 0x8000000012345678; result = (int64_t)(uint32_t)value;"]).run()
        XCTAssertEqual(zeroHigh.terminal?.bits, 0x1234_5678)
        let bytes: [UInt64: UInt8] = [0x2000:0xfd,0x2001:0xff,0x2002:0xff,0x2003:0xff]
        let signed = try unit(["value = *(int32_t *)((uint64_t)0x2000); result = (int64_t)value;"], memory: bytes,
                              effects: [0:[.init(loading: true, bytes: 4)]]).run()
        XCTAssertEqual(signed.terminal?.bits, UInt64.max - 2)
    }
    func testBytePointerCastsAccumulateOffsetsAndTypedLoadsPreserveProvenance() throws {
        let bytes = Dictionary(uniqueKeysWithValues: (0..<8).map { (UInt64(0x2238 + $0), UInt8($0 + 1)) })
        let expressions = [
            "*(uint64_t *)((uint8_t *)(input) + 0x238)",
            "*(const uint64_t *)((const uint8_t *)(input) + 0x240 - 8)",
            "*(uint64_t *)((uint8_t *)(input) - (-0x238))"
        ]
        for expression in expressions {
            let result = try unit(["address = (uint8_t *)(input); value = \(expression); result = (int64_t)value;"],
                memory: bytes, effects: [0: [.init(loading: true, bytes: 8)]], input: 0x2000,
                inputType: .jpegPointer).run()
            XCTAssertEqual(result.terminal?.bits, 0x0807_0605_0403_0201, expression)
            XCTAssertEqual(result.events, [.load(.init(row: 0, effectOrdinal: 0), 0, 0x2238, 8, 0x0807_0605_0403_0201)],
                           "typed loads retain exact site, width, address and bits")
            let cast = try XCTUnwrap(result.commits.first { $0.name == "address" }?.value)
            XCTAssertTrue(cast.type.bytePointer, "cast parses as a pointer conversion")
            XCTAssertEqual(cast.objectAddress, .init(base: 0x2000, owner: "jpeg_decompress_struct", offset: 0),
                           "cast retains the proved object identity")
            let offset = try XCTUnwrap(result.evaluations.last { $0.value.type.bytePointer && $0.value.bits == 0x2238 }?.value)
            XCTAssertEqual(offset.objectAddress, .init(base: 0x2000, owner: "jpeg_decompress_struct", offset: 0x238),
                           "addition/subtraction accumulates bytes on the original object")
        }
        let origin = C.Origin(row: 7, occurrence: 2)
        let base = C.Value(0x2000, .jpegPointer, origins: [origin])
        let cast = try C.converted(base, to: .init(64, true, pointee: "uint8_t"))
        let shifted = try C.binary("+", cast, .init(8, .i32))
        XCTAssertEqual(shifted.origins, [origin], "byte addressing does not erase existing call authority")
        XCTAssertEqual(shifted.objectAddress, .init(base: 0x2000, owner: "jpeg_decompress_struct", offset: 8))
    }

    func testBytePointerCastsRejectNonPointersPointerArithmeticAndLostProvenance() {
        require(.syntax) { _ = try unit(["address = (uint8_t *)(input); result = 1;"]) }
        for expression in [
            "(uint8_t *)(input) + (uint8_t *)(input)",
            "(uint8_t *)(input) == (uint8_t *)(input)",
            "(uint8_t *)(input) < (uint8_t *)(input)",
            "*(uint64_t *)((uint8_t *)(7))",
            "*(uint64_t *)(7)",
            "*(uint64_t *)((uint8_t *)((uint64_t)input))",
            "(uint32_t *)(input)",
            "(uint8_t *)((uint32_t *)(input))"
        ] {
            require(.syntax) { _ = try unit(["value = \(expression); result = 1;"], inputType: .jpegPointer) }
        }
    }

    func testBytePointerOffsetsRejectOverflowAndPreserveMemoryAndConstChecks() {
        require(.undefined) {
            _ = try unit(["address = (uint8_t *)(input) - 1; result = 1;"], input: 0, inputType: .jpegPointer).run()
        }
        require(.undefined) {
            _ = try unit(["address = (uint8_t *)(input) + 1; result = 1;"], input: .max, inputType: .jpegPointer).run()
        }
        require(.contract) {
            _ = try unit(["value = *(uint64_t *)((uint8_t *)(input) + 8); result = 1;"], inputType: .jpegPointer)
        }
        require(.contract) {
            _ = try unit(["value = *(uint64_t *)((uint8_t *)(input) + 8); result = 1;"],
                         effects: [0: [.init(loading: true, bytes: 4)]], inputType: .jpegPointer)
        }
        require(.syntax) {
            _ = try unit(["*(const uint64_t *)((uint8_t *)(input)) = 1; result = 1;"],
                         effects: [0: [.init(loading: false, bytes: 8)]], inputType: .jpegPointer)
        }
    }

    func testFrozenTupleCapturesAllAddressesBeforeCommitAndPairsArePerAccessWidth() throws {
        let tuple = "first, second = *(uint32_t *)((uint64_t)0x2000), *(uint32_t *)((uint64_t)0x2004);"
        let bytes = Dictionary(uniqueKeysWithValues: (0..<8).map { (UInt64(0x2000 + $0), UInt8($0 + 1)) })
        let result = try unit([tuple, "result = (int64_t)first + (int64_t)second;"], memory: bytes,
            effects: [0:[.init(loading: true, bytes: 4), .init(loading: true, bytes: 4)]], exterior: [0:tuple]).run()
        XCTAssertEqual(result.events.count, 2)
        guard case let .load(firstSite, _, _, firstWidth, _) = result.events[0],
              case let .load(secondSite, _, _, secondWidth, _) = result.events[1] else { return XCTFail("two ordered real loads") }
        XCTAssertEqual(firstWidth, 4); XCTAssertEqual(secondWidth, 4)
        XCTAssertEqual(firstSite.effectOrdinal, 0); XCTAssertEqual(secondSite.effectOrdinal, 1)
        require(.syntax) { _ = try unit([tuple, "result = (int64_t)first;"]) }
    }
    func testSequentialEdgeCopiesAreNotInventedParallelAssignments() throws {
        let result = try unit(["int64_t a = 1; int64_t b = 2; a = b; b = a; result = b;"]).run()
        XCTAssertEqual(result.terminal?.bits, 2, "printed sequential copy loses old a, as C does")
        let captured = try unit(["int64_t a = 1; int64_t b = 2; old = a; a = b; b = old; result = b;"]).run()
        XCTAssertEqual(captured.terminal?.bits, 1)
    }
    func testA64SDivOnlyNamedHelperHasZeroAndMinimumSpecialCases() throws {
        let zero = try unit(["result = __a64_sdiv32(7, 0);"]).run()
        XCTAssertEqual(zero.terminal?.bits, 0)
        let minimum = try unit(["result = __a64_sdiv32(0x80000000, 0xffffffff);"]).run()
        XCTAssertEqual(minimum.terminal?.bits, 0xffff_ffff_8000_0000)
        require(.syntax) { _ = try unit(["result = __a64_sdiv32_extra(1, 1);"]) }
        require(.syntax) { _ = try unit(["result = 7 / 2;"]) }
    }
    func testDeadOpaqueResultReadIsRejectedEvenInUnreachableUnusedCopy() {
        let call = C.FrozenCall(row: 0, payload: "answer = original(input); // call", target: "original", resultName: "answer", control: nil,
                               arguments: [.init(register: 0, width: 64)])
        require(.authority) {
            _ = try unit([call.payload, "result = 1; if (false) { unused = answer; }"], call: call, dead: [0])
        }
        let printless = C.FrozenCall(row: 0, payload: "original(input); // call", target: "original", resultName: nil, control: nil,
                                    arguments: [.init(register: 0, width: 64)])
        require(.contract) { _ = try unit(["invented = " + printless.payload, "result = 1;"], call: printless) }
    }
    func testSameExactCallGetsFreshDynamicResponseAndDeclaredResultIsNotInitializedByDeclaration() throws {
        let call = C.FrozenCall(row: 2, payload: "answer = original(input); // call", target: "original", resultName: "answer", control: nil,
                               arguments: [.init(register: 0, width: 64)])
        let result = try unit(["int64_t answer; int64_t result = 0; int64_t count = 2;", "while (count) {", call.payload,
                               "--count; }"], call: call, dead: [2], responses: [
                                .init(row:2,result:0x8000_0000_0000_0000,writes:[],expectedArguments:[1],expectedControl:[]),
                                .init(row:2,result:7,writes:[],expectedArguments:[1],expectedControl:[])]).run()
        let events = result.events.compactMap { if case let .call(call) = $0 { return call }; return nil }
        XCTAssertEqual(events.map(\.result), [0x8000_0000_0000_0000,7]); XCTAssertEqual(events.map(\.occurrence), [0,1])
        require(.uninitialized) { _ = try unit(["uint64_t result; result = result + 1;"]).run() }
    }
    func testSignedRepresentationTransportDoesNotGrantUnrelatedSelectionPermission() throws {
        let call = C.FrozenCall(row: 0, payload: "answer = original(input); // call", target: "original", resultName: "answer", control: nil,
                               arguments: [.init(register: 0, width: 64)])
        let conversion = "bits = (uint64_t)answer; transported = ((bits & ((uint64_t)1 << 63)) == 0) ? (int64_t)bits : -1 - (int64_t)(uint64_t)(~bits); result = 1;"
        let response = C.OpaqueResponse(row: 0, result: 0x8000_0000_1234_5678, writes: [], expectedArguments: [1], expectedControl: [])
        let result = try unit([call.payload, conversion], call: call, responses: [response]).run()
        XCTAssertEqual(result.commits.first { $0.name == "transported" }?.value.bits, response.result)
        require(.authority) {
            _ = try unit([call.payload, conversion.replacingOccurrences(of: "(~bits)", with: "(~(bits + (uint64_t)1))")], call: call, responses: [response])
        }
    }
    func testOriginalSignedCallResultDeclarationAndPredefinitionReadAreChecked() {
        let call = C.FrozenCall(row: 1, payload: "answer = original(input); // call", target: "original", resultName: "answer", control: nil,
                               arguments: [.init(register: 0, width: 64)])
        require(.contract) { _ = try unit(["uint64_t answer;", call.payload, "result = 1;"], call: call) }
        require(.uninitialized) {
            _ = try unit(["int64_t answer; ignored = answer;", call.payload, "result = 1;"], call: call,
                         responses: [.init(row: 1, result: 0, writes: [], expectedArguments: [1], expectedControl: [])]).run()
        }
    }

}
