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

/// Native presentation prerequisite only. A RED here is production behavior,
/// not parser/marker/ABI-envelope setup. A PASS is NOT semantic equivalence,
/// full row/edge ownership, carrier-provenance proof, or native scalar size acceptance.
/// Those independent gates must follow on the same exact frozen inputs.
final class NativeScalarPresentationTests: XCTestCase {
    private typealias F = NativeScalarFixture
    private typealias A = OrdinaryCOutputAudit

    private func prerequisite(_ fixture: F, nativeLoadRows: [Int], subsBranches: [(Int, Int)],
                              cmpBranches: [(Int, Int)], expectedTerminalPayload: String? = nil,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let document = fixture.document
        let context = "NATIVE_SCALAR_PRESENTATION_PREREQUISITE \(fixture.seed.name)@\(NativeScalarContext.hex(fixture.seed.start)); not semantic acceptance\n\(document.text)"
        XCTAssertEqual(document.functionName, fixture.seed.name, context, file: file, line: line)
        XCTAssertEqual(document.entryAddress, fixture.seed.start, context, file: file, line: line)
        XCTAssertEqual(document.lines.first?.text, fixture.capture.signature, context, file: file, line: line)
        XCTAssertEqual(document.parameters, fixture.originalParameters, context, file: file, line: line)
        XCTAssertEqual(document.returnType, fixture.original.returnType, context, file: file, line: line)
        let terminalAddress = try XCTUnwrap(fixture.rows.last?.address, file: file, line: line)
        let terminal = document.lines(sourcedAt: terminalAddress).filter {
            $0.text.trimmingCharacters(in: .whitespaces).hasPrefix("return")
        }.map { $0.text.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(terminal, [expectedTerminalPayload ?? fixture.capture.terminalPayload], context, file: file, line: line)
        XCTAssertFalse(A.matches(#"rgn_[a-z]+_"#, document.text), context, file: file, line: line)
        let tokens = try A.lex(document.text)
        XCTAssertFalse(tokens.contains { A.isRawControlHelper($0.text) }, context, file: file, line: line)
        XCTAssertFalse(tokens.contains { $0.text == "goto" }, context, file: file, line: line)
        for index in tokens.indices where ["break", "continue"].contains(tokens[index].text) {
            XCTAssertTrue(index + 1 < tokens.count && tokens[index + 1].text == ";", context, file: file, line: line)
        }
        // These exact originals have direct literal CMP/SUBS predicates. A
        // synthesized boolean is not justified merely by changing its prefix.
        XCTAssertFalse(tokens.contains { $0.text == "bool" }, context, file: file, line: line)
        XCTAssertFalse(tokens.contains { A.matches(#"(?:^|_)flag[0-9_]*$"#, $0.text) }, context, file: file, line: line)

        // Initial presentation smoke accepts sound source/carrier coalescing
        // and fresh native MacIRValue.temporary identities when an original
        // signed binding cannot hold the proven unsigned source representation.
        // Neither this bank nor tmp_<N> spelling maps a candidate to a register:
        // complete source-slot/interference ownership remains a separate gate.
        var nativeNameBank = Set(fixture.original.nameBindings.map(\.name))
        for instruction in fixture.original.instructions {
            let destinations: [MacIRValue]
            switch instruction.operation {
            case let .assign(value, _), let .binary(value, _, _, _), let .load(value, _): destinations = [value]
            case let .loadWriteback(value, base, _, _, _): destinations = [value, base]
            case let .storeWriteback(_, base, _, _, _): destinations = [base]
            case let .intrinsic(value, _, _): destinations = value.map { [$0] } ?? []
            default: destinations = []
            }
            nativeNameBank.formUnion(destinations.map(fixture.originalName))
        }
        for row in nativeLoadRows {
            let instruction = fixture.original.instructions[row]
            let destination: MacIRValue
            switch instruction.operation {
            case let .load(value, _): destination = value
            case let .loadWriteback(value, _, _, _, _): destination = value
            default:
                XCTFail("frozen native load row changed: \(row)", file: file, line: line); continue
            }
            _ = destination // Native type/row identity above is not a spelling pin.
            let lhsNames = try scalarAssignedNames(at: row, fixture: fixture)
            XCTAssertTrue(lhsNames.contains { nativePresentationName($0, originalBank: nativeNameBank) },
                "row \(row) has no native source-definition name (coalescing/fresh native allocation permitted)\n\(context)", file: file, line: line)
        }
        for (writer, consumer) in subsBranches {
            guard case let .binary(destination, operation, _, _) = fixture.original.instructions[writer].operation,
                  operation == "-", fixture.rows[writer].mnemonic == "subs" else {
                XCTFail("frozen SUBS source identity changed", file: file, line: line); continue
            }
            _ = destination
            let names = Set(try scalarAssignedNames(at: writer, fixture: fixture).filter {
                nativePresentationName($0, originalBank: nativeNameBank)
            })
            let condition = try predicateTokens(at: consumer, fixture: fixture)
            XCTAssertFalse(names.intersection(Set(condition)).isEmpty,
                "SUBS consumer must directly read a native result defined at its writer row, not an old operand or synthesized flag\n\(context)", file: file, line: line)
            XCTAssertTrue(condition.contains("0") || condition.contains("0x0") || (condition.count == 1 && names.contains(condition[0])),
                "SUBS latch must test the resulting zero/nonzero value\n\(context)", file: file, line: line)
        }
        for (writer, consumer) in cmpBranches {
            XCTAssertEqual(fixture.rows[writer].mnemonic, "cmp", context, file: file, line: line)
            let condition = try predicateTokens(at: consumer, fixture: fixture)
            XCTAssertFalse(condition.isEmpty, "missing direct writer-owned predicate at row \(consumer)\n\(context)", file: file, line: line)
            XCTAssertTrue(condition.contains { ["<", ">", "<=", ">=", "==", "!="].contains($0) },
                "original CMP predicate replaced by an opaque flag\n\(context)", file: file, line: line)
        }
        // No reconstructed pair/writeback tuple exception is imported from the
        // captured-call call adapter. Check actual tokens, not comments/strings.
        for lineValue in document.lines where lineValue.kind != .signature && lineValue.kind != .metadata {
            let words = try A.lex(lineValue.text).map(\.text)
            var depth = 0
            var topLevelComma = false
            for word in words {
                if word == "(" || word == "[" { depth += 1 }
                if word == ")" || word == "]" { depth -= 1 }
                if word == "," && depth == 0 { topLevelComma = true }
            }
            let declarationList: Bool
            if let type = words.first, OrdinaryC.CType.named(type) != nil, words.last == ";", words.count >= 3 {
                let body = Array(words.dropFirst().dropLast())
                declarationList = body.enumerated().allSatisfy { index, word in
                    index.isMultiple(of: 2) ? A.identifier(word) : word == ","
                } && !body.count.isMultiple(of: 2)
            } else { declarationList = false }
            XCTAssertFalse(topLevelComma && !declarationList,
                "new native body must use separate scalar statements, not tuples\n\(context)", file: file, line: line)
        }
    }

    /// Lexical smoke only. Native temporary allocation uses canonical tmp_<N> for
    /// a nonnegative Int, avoiding existing names. N is never interpreted as a
    /// register, source row, definition slot, value or coalescing certificate.
    private func nativePresentationName(_ name: String, originalBank: Set<String>) -> Bool {
        if originalBank.contains(name) { return true }
        guard name.hasPrefix("tmp_"), let index = Int(name.dropFirst(4)), index >= 0 else { return false }
        return name == "tmp_\(index)"
    }

    private func scalarAssignedNames(at row: Int, fixture: F) throws -> [String] {
        try fixture.document.lines(sourcedAt: fixture.rows[row].address).flatMap { line in
            let words = try A.lex(line.text).map(\.text)
            return words.indices.compactMap { index in
                index + 1 < words.count && words[index + 1] == "=" && A.identifier(words[index]) ? words[index] : nil
            }
        }
    }

    private func predicateTokens(at row: Int, fixture: F) throws -> [String] {
        let lines = fixture.document.lines(sourcedAt: fixture.rows[row].address)
        for line in lines {
            let words = try A.lex(line.text).map(\.text)
            guard let start = words.firstIndex(where: { $0 == "if" || $0 == "while" }),
                  start + 1 < words.count, words[start + 1] == "(" else { continue }
            var depth = 1, end = start + 2
            while end < words.count {
                if words[end] == "(" { depth += 1 }
                if words[end] == ")" { depth -= 1 }
                if depth == 0 { return Array(words[(start + 2)..<end]) }
                end += 1
            }
        }
        return []
    }

    func testOriginalExtrgbRGB8RequiresNativePresentation() throws {
        let fixture = try F.make(.interleavedRGB8)
        try prerequisite(fixture, nativeLoadRows: [2, 11, 13, 15],
            subsBranches: [(18, 19)], cmpBranches: [(0, 1), (22, 24)])
    }

    func testOriginalNoscaleRequiresNativePresentation() throws {
        let fixture = try F.make(.entryNoscale8)
        // No return evidence is available, and missing evidence does not establish void.
        try prerequisite(fixture, nativeLoadRows: [0], subsBranches: [(2, 3)], cmpBranches: [],
            expectedTerminalPayload: "return unresolved_return_contract; // return")
    }

    func testOriginalNullRGB8RequiresNativePresentation() throws {
        // Excluded native subject: real refusal and exact captured39a output assertions.
        // The original contract remains preserved evidence, not numerical PASS credit.
        let fixture = try RegionalSchema2Bindings39A.make(function: "_null_convert", start: 0x3704)
        try ExcludedNullFallback39A.requireCaptured(fixture)
    }
    func testPhiTransportIdentityRequiresExactPrinterTypeChain() throws {
        let signed: MacIRValue = .argument(bindingID: .gpr(0))
        let loop: MacIRValue = .register(name: "x1", version: 4)
        let next: MacIRValue = .register(name: "x1", version: 1)
        let loaded: MacIRValue = .temporary(42)
        var parameter = MacIRFunctionParameter(index: 0, register: "x0", type: "int64_t", name: "input")
        parameter.sourcePosition = 0
        let source = MacIRSourceSpan(address: 0x3814, byteText: "2d 00 40 f9", mnemonic: "ldr", operands: "x13, [x1]")
        let add = MacIRSourceSpan(address: 0x3774, byteText: "21 20 00 91", mnemonic: "add", operands: "x1, x1, #8")
        let function = MacIRFunction(name: "typed_copy", startAddress: 0x3704, parameters: [parameter],
            instructions: [
                .init(source: add, operation: .binary(destination: next, op: "+", left: loop, right: .immediate(8))),
                .init(source: source, operation: .load(destination: loaded, address: signed),
                      memoryAccess: .init(byteWidth: 8, extensionKind: .none)),
                .init(source: .init(address: 0x4000, byteText: "", mnemonic: "synthetic", operands: ""),
                      operation: .intrinsic(destination: nil, name: "compare", arguments: [signed, next]))])
        let printer = PseudocodePrinter(options: .default)
        let names = PseudocodeNameContext(function: function)
        let types = printer.phiTransportSourceTypes(in: function, names: names,
            phiTypes: [(loop, "int64_t")], inferPlainScalars: true)
        XCTAssertEqual(types[signed], "int64_t")
        XCTAssertEqual(types[next], "int64_t")
        XCTAssertEqual(types[loaded], "uint64_t")
        XCTAssertEqual(PseudocodePrinter.phiTransportValue(next, type: "int64_t", sourceType: types[next]), next)
        let projected = PseudocodePrinter.phiTransportValue(loaded, type: "int64_t", sourceType: types[loaded])
        XCTAssertEqual(projected, .binaryExpression(op: MacIRBuilder.signedProjectionOperator,
            left: .unary(op: "(uint64_t)", value: loaded), right: .immediate(64)))
        // An absent chain is not an inferred identity. Structured recovery can
        // rewrite scalar expressions and deliberately does not use flat facts.
        let declarations = printer.phiTransportSourceTypes(in: function, names: names,
            phiTypes: [(loop, "int64_t")], inferPlainScalars: false)
        XCTAssertNil(declarations[next])
        XCTAssertNotEqual(PseudocodePrinter.phiTransportValue(next, type: "int64_t", sourceType: declarations[next]), next)
    }

    func testPhiTransportRefusesConflictingUnsignedNarrowAndSnapshotFacts() {
        let value: MacIRValue = .temporary(42)
        for source in [nil, "uint64_t", "int32_t", "uint32_t", "__uint128_t"] as [String?] {
            XCTAssertNotEqual(PseudocodePrinter.phiTransportValue(value, type: "int64_t", sourceType: source), value)
        }
        // Whole-vector destinations keep the original transport (no narrowing).
        XCTAssertEqual(PseudocodePrinter.phiTransportValue(value, type: "__uint128_t", sourceType: "__uint128_t"), value)
        let a: MacIRValue = .argument(bindingID: .gpr(0))
        let b: MacIRValue = .argument(bindingID: .gpr(1))
        var p = MacIRFunctionParameter(index: 0, register: "x0", type: "int64_t", name: "same")
        var q = MacIRFunctionParameter(index: 1, register: "x1", type: "uint64_t", name: "same")
        p.sourcePosition = 0; q.sourcePosition = 1
        let function = MacIRFunction(name: "conflicting_copy", startAddress: 0, parameters: [p, q], instructions: [])
        let printer = PseudocodePrinter(options: .default)
        let names = PseudocodeNameContext(function: function)
        let facts = printer.phiTransportSourceTypes(in: function, names: names, phiTypes: [], inferPlainScalars: true)
        XCTAssertNil(facts[a]); XCTAssertNil(facts[b]); XCTAssertNil(facts[value])
        // A generated-looking name conveys no snapshot declaration or type.
        XCTAssertNotEqual(PseudocodePrinter.phiTransportValue(value, type: "int64_t", sourceType: facts[value]), value)
        let conflicting = printer.phiTransportSourceTypes(in: function, names: names,
            phiTypes: [(value, "int64_t"), (value, "uint64_t")], inferPlainScalars: true)
        XCTAssertNil(conflicting[value])
        let boundary = MacIRFunction(name: "hex_boundary", startAddress: 0, instructions: [
            .init(source: .init(address: 0, byteText: "", mnemonic: "synthetic", operands: ""),
                  operation: .assign(destination: value, source: .immediate(Int64(Int32.min))))])
        let boundaryFacts = printer.phiTransportSourceTypes(in: boundary,
            names: PseudocodeNameContext(function: boundary), phiTypes: [], inferPlainScalars: true)
        XCTAssertNil(boundaryFacts[value])
        XCTAssertNotEqual(PseudocodePrinter.phiTransportValue(value, type: "int32_t", sourceType: boundaryFacts[value]), value)
    }

}
