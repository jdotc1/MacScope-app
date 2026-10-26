import XCTest
@testable import MacScope

/// HOP-5c: format-string-aware variadic recovery. Synthetic instruction fixtures in the style of
/// `MacIRCallArgumentRecoveryTests`; every anonymous argument must come from an exact store into
/// its Apple arm64 stack slot (variadic arguments never travel in x1-x7 on Darwin).
final class FormatStringVariadicRecoveryTests: XCTestCase {
    private let page: UInt64 = 0x1_0000_4000
    private var formatAddress: UInt64 { page + 0x650 }
    private var stringAddress: UInt64 { page + 0x700 }

    // MARK: - Parser

    func testParserPrintfIntsStringsDoublesAndLengthModifiers() throws {
        let arguments = try XCTUnwrap(FormatStringParser.arguments(
            of: "%d %i %u %x %s %p %c %f %ld %lld %zu %hhd %Lf\n", flavor: .printf
        ))
        XCTAssertEqual(arguments.map(\.type), [
            "int", "int", "unsigned int", "unsigned int", "const char *", "void *", "int",
            "double", "long", "long long", "size_t", "int", "double",
        ])
        XCTAssertTrue(arguments.allSatisfy { $0.role == .value })
    }

    func testParserStarWidthAndPrecisionConsumeIntArgumentsFirst() throws {
        let arguments = try XCTUnwrap(FormatStringParser.arguments(of: "%*d|%-*.*s|%.3f", flavor: .printf))
        XCTAssertEqual(arguments.map(\.type), ["int", "int", "int", "int", "const char *", "double"])
        XCTAssertEqual(arguments.map(\.role), [
            .fieldWidth, .value, .fieldWidth, .precision, .value, .value,
        ])
        XCTAssertEqual(arguments[0].directive, "%*d")
    }

    func testParserPercentPercentConsumesNothing() {
        XCTAssertEqual(FormatStringParser.arguments(of: "100%% done%%", flavor: .printf)?.count, 0)
        XCTAssertEqual(FormatStringParser.arguments(of: "%%d", flavor: .printf)?.count, 0)
    }

    func testParserOSLogAnnotationsAndFoundationObjects() throws {
        let osLog = try XCTUnwrap(FormatStringParser.arguments(
            of: "user %{public}s id %{private}d obj %{public, mask.hash}@", flavor: .osLog
        ))
        XCTAssertEqual(osLog.map(\.type), ["const char *", "int", "id"])

        let foundation = try XCTUnwrap(FormatStringParser.arguments(of: "%@ = %ld (%C)", flavor: .foundation))
        XCTAssertEqual(foundation.map(\.type), ["id", "long", "unichar"])
    }

    func testParserRejectsMalformedAndUnsupportedFormats() {
        for format in ["trailing %", "%y", "%1$d", "%*1$d", "%hhlld", "%Ld", "%ls%q"] {
            XCTAssertNil(FormatStringParser.arguments(of: format, flavor: .printf), format)
        }
        XCTAssertNil(FormatStringParser.arguments(of: "%@", flavor: .printf), "%@ is not printf")
        XCTAssertNil(FormatStringParser.arguments(of: "%{public s", flavor: .osLog))
        XCTAssertEqual(FormatStringParser.Flavor(attributeKind: "CFString"), .foundation)
        XCTAssertNil(FormatStringParser.Flavor(attributeKind: "scanf"))
    }

    // MARK: - Catalog

    func testCatalogAttachesPackFormatAttributeToHandWrittenSeeds() {
        let catalog = CallSignatureCatalog.standard
        XCTAssertEqual(catalog.signature(for: "_printf")?.format,
                       CallFormatAttribute(kind: "printf", formatIndex: 1, firstArgIndex: 2))
        XCTAssertEqual(catalog.signature(for: "_snprintf")?.format?.formatIndex, 3)
        XCTAssertEqual(catalog.signature(for: "_NSLog")?.format?.kind, "NSString")
        XCTAssertNil(catalog.signature(for: "_vprintf")?.format, "va_list consumers have no tail")
        XCTAssertNil(catalog.signature(for: "_puts")?.format)
        // The declaration text (the seed regression anchor) is unchanged.
        XCTAssertEqual(catalog.signature(for: "_printf")?.declarationText,
                       "int32_t _printf(const char * format, ...)")
    }

    func testCatalogDropsFormatAttributeThatDoesNotDescribeTheWinningSignature() {
        let catalog = CallSignatureCatalog([
            CallSignatureSpec(canonicalName: "logf", returnType: "void",
                              parameters: [.init(type: "int", name: "level"),
                                           .init(type: "const char *", name: "format")],
                              isVariadic: true),
            CallSignatureSpec(canonicalName: "logf", returnType: "void",
                              parameters: [.init(type: "const char *", name: "format")],
                              isVariadic: true,
                              format: .init(kind: "printf", formatIndex: 1, firstArgIndex: 2)),
        ])
        XCTAssertNil(catalog.signature(for: "logf")?.format)
    }

    // MARK: - Builder: recovered tails

    func testPrintfIntsStringsAndDoubleBindToStackSlotsNotRegisters() throws {
        let rows = [
            row(0x1000, "sub", "sp, sp, #0x30"),
            row(0x1004, "mov", "w8, #0x5"),
            row(0x1008, "str", "x8, [sp]"),
            row(0x100c, "adrp", "x9, \(hex(page))"),
            row(0x1010, "add", "x9, x9, #0x700"),
            row(0x1014, "str", "x9, [sp, #0x8]"),
            row(0x1018, "fmov", "d0, #1.5"),
            row(0x101c, "str", "d0, [sp, #0x10]"),
            row(0x1020, "mov", "x1, #0x63"),
            row(0x1024, "adrp", "x0, \(hex(page))"),
            row(0x1028, "add", "x0, x0, #0x650"),
            row(0x102c, "bl", "_printf"),
            row(0x1030, "add", "sp, sp, #0x30"),
            row(0x1034, "ret"),
        ]
        let strings = [
            formatAddress: MacIRConstantString(text: "%d %s %f\n", kind: .cString),
            stringAddress: MacIRConstantString(text: "name", kind: .cString),
        ]
        let frame = try callFrame(in: build(rows, constantStrings: strings), target: "_printf")

        guard case let .formatString(evidence) = frame.tailCountEvidence else {
            return XCTFail("expected format-string evidence, got \(String(describing: frame.tailCountEvidence))")
        }
        XCTAssertEqual(evidence.argumentTypes, ["int", "const char *", "double"])
        XCTAssertEqual(evidence.format, "%d %s %f\n")
        XCTAssertEqual(evidence.formatAddress, formatAddress)
        XCTAssertEqual(evidence.formatSourcePosition, 0)
        XCTAssertEqual(MacIRCallFormatStringEvidence.provenance, "formatString")

        let tail = frame.arguments.canonicalPhysicalEntriesForAudit.filter { $0.tailOrdinal != nil }
        XCTAssertEqual(tail.map(\.location), [
            .callStack(byteOffset: 0, size: 8, alignment: 8),
            .callStack(byteOffset: 8, size: 8, alignment: 8),
            .callStack(byteOffset: 16, size: 8, alignment: 8),
        ])
        XCTAssertEqual(tail.map(\.tailOrdinal), [0, 1, 2])
        XCTAssertNil(frame.arguments.argument(at: .gpr(index: 1)),
                     "x1 is never a variadic carrier on Apple arm64")
        XCTAssertNil(frame.arguments.argument(at: .simd(index: 0)))

        let rendered = try XCTUnwrap(frame.completeKnownVariadicRenderValues())
        XCTAssertEqual(rendered.count, 4)
        XCTAssertEqual(rendered.first, .symbol("\"%d %s %f\\n\""))

        let text = render(rows, constantStrings: strings)
        XCTAssertTrue(text.contains("printf(\"%d %s %f\\n\", "), text)
    }

    func testStarWidthConsumesTwoSlotsFromStorePair() throws {
        let rows = [
            row(0x2000, "sub", "sp, sp, #0x20"),
            row(0x2004, "mov", "w8, #0x8"),
            row(0x2008, "mov", "w9, #0x2a"),
            row(0x200c, "stp", "x8, x9, [sp]"),
            row(0x2010, "adrp", "x0, \(hex(page))"),
            row(0x2014, "add", "x0, x0, #0x650"),
            row(0x2018, "bl", "_printf"),
            row(0x201c, "ret"),
        ]
        let frame = try callFrame(
            in: build(rows, constantStrings: [formatAddress: .init(text: "[%*d]", kind: .cString)]),
            target: "_printf"
        )
        XCTAssertEqual(frame.expectedTailCount, 2)
        XCTAssertEqual(frame.completeKnownVariadicRenderValues()?.count, 3)
    }

    func testPercentPercentFormatRecordsAnEmptyTail() throws {
        let rows = [
            row(0x2100, "adrp", "x0, \(hex(page))"),
            row(0x2104, "add", "x0, x0, #0x650"),
            row(0x2108, "bl", "_printf"),
            row(0x210c, "ret"),
        ]
        let frame = try callFrame(
            in: build(rows, constantStrings: [formatAddress: .init(text: "100%%\n", kind: .cString)]),
            target: "_printf"
        )
        XCTAssertEqual(frame.expectedTailCount, 0)
        XCTAssertEqual(frame.completeKnownVariadicRenderValues(), [.symbol("\"100%%\\n\"")])
    }

    func testNSLogConstantCFStringObjectArgument() throws {
        let rows = [
            row(0x2200, "sub", "sp, sp, #0x10"),
            row(0x2204, "str", "x19, [sp]"),
            row(0x2208, "adr", "x0, \(hex(formatAddress))"),
            row(0x220c, "bl", "_NSLog"),
            row(0x2210, "ret"),
        ]
        let frame = try callFrame(
            in: build(rows, constantStrings: [formatAddress: .init(text: "value: %@", kind: .cfString)]),
            target: "_NSLog"
        )
        guard case let .formatString(evidence) = frame.tailCountEvidence else {
            return XCTFail("expected format-string evidence")
        }
        XCTAssertEqual(evidence.kind, "NSString")
        XCTAssertEqual(evidence.argumentTypes, ["id"])
        XCTAssertEqual(frame.completeKnownVariadicRenderValues()?.first, .symbol("@\"value: %@\""))
    }

    func testCLibraryMinusO0PatternThroughStackPointerCopy() throws {
        // reconstruction-c-sample `main`: printf("%u:%u\n", input, output) at -O0.
        let rows = [
            row(0x4a0, "sub", "sp, sp, #0xe0"),
            row(0x510, "mov", "x10, x8"),
            row(0x514, "ldr", "w8, [sp, #0x28]"),
            row(0x518, "mov", "x9, sp"),
            row(0x51c, "str", "x10, [x9]"),
            row(0x520, "str", "x8, [x9, #0x8]"),
            row(0x524, "adrp", "x0, \(hex(page))"),
            row(0x528, "add", "x0, x0, #0x650"),
            row(0x52c, "bl", "_printf"),
            row(0x530, "ret"),
        ]
        let frame = try callFrame(
            in: build(rows, constantStrings: [formatAddress: .init(text: "%u:%u\n", kind: .cString)]),
            target: "_printf"
        )
        guard case let .formatString(evidence) = frame.tailCountEvidence else {
            return XCTFail("expected format-string evidence")
        }
        XCTAssertEqual(evidence.argumentTypes, ["unsigned int", "unsigned int"])
        XCTAssertEqual(frame.completeKnownVariadicRenderValues()?.count, 3)
    }

    func testDoubleConstantMaterializedAsBitsRendersAsDouble() throws {
        let rows = [
            row(0x2300, "sub", "sp, sp, #0x10"),
            row(0x2304, "mov", "x8, #0x4000000000000000"),
            row(0x2308, "str", "x8, [sp]"),
            row(0x230c, "adrp", "x0, \(hex(page))"),
            row(0x2310, "add", "x0, x0, #0x650"),
            row(0x2314, "bl", "_printf"),
            row(0x2318, "ret"),
        ]
        let frame = try callFrame(
            in: build(rows, constantStrings: [formatAddress: .init(text: "%f", kind: .cString)]),
            target: "_printf"
        )
        XCTAssertEqual(frame.completeKnownVariadicRenderValues()?.last, .symbol("2.0"))
    }

    // MARK: - Builder: fixed arguments only

    func testNonConstantFormatBindsOnlyFixedArguments() throws {
        let rows = [
            row(0x3000, "str", "x8, [sp]"),
            row(0x3004, "ldr", "x0, [x20, #0x8]"),
            row(0x3008, "bl", "_printf"),
            row(0x300c, "ret"),
        ]
        let frame = try callFrame(
            in: build(rows, constantStrings: [formatAddress: .init(text: "%d", kind: .cString)]),
            target: "_printf"
        )
        assertFixedOnly(frame, fixedCount: 1)
    }

    func testMalformedFormatBindsOnlyFixedArguments() throws {
        for text in ["%d %", "%1$d", "%y"] {
            let rows = [
                row(0x3100, "str", "x8, [sp]"),
                row(0x3104, "str", "x9, [sp, #0x8]"),
                row(0x3108, "adrp", "x0, \(hex(page))"),
                row(0x310c, "add", "x0, x0, #0x650"),
                row(0x3110, "bl", "_printf"),
                row(0x3114, "ret"),
            ]
            let frame = try callFrame(
                in: build(rows, constantStrings: [formatAddress: .init(text: text, kind: .cString)]),
                target: "_printf"
            )
            assertFixedOnly(frame, fixedCount: 1, text)
        }
    }

    func testMissingSlotStoreNeverFabricatesAnArgument() throws {
        // Two directives, one stored slot; AAPCS-style values in x1/x2 are not variadic carriers.
        let rows = [
            row(0x3200, "mov", "x1, #0x1"),
            row(0x3204, "mov", "x2, #0x2"),
            row(0x3208, "str", "x1, [sp]"),
            row(0x320c, "adrp", "x0, \(hex(page))"),
            row(0x3210, "add", "x0, x0, #0x650"),
            row(0x3214, "bl", "_printf"),
            row(0x3218, "ret"),
        ]
        let frame = try callFrame(
            in: build(rows, constantStrings: [formatAddress: .init(text: "%d %d", kind: .cString)]),
            target: "_printf"
        )
        assertFixedOnly(frame, fixedCount: 1)
    }

    func testStoresBeforeAnEarlierCallDoNotFeedALaterCall() throws {
        let rows = [
            row(0x3300, "str", "x8, [sp]"),
            row(0x3304, "bl", "_rand"),
            row(0x3308, "adrp", "x0, \(hex(page))"),
            row(0x330c, "add", "x0, x0, #0x650"),
            row(0x3310, "bl", "_printf"),
            row(0x3314, "ret"),
        ]
        let frame = try callFrame(
            in: build(rows, constantStrings: [formatAddress: .init(text: "%d", kind: .cString)]),
            target: "_printf"
        )
        assertFixedOnly(frame, fixedCount: 1)
    }

    func testFormatStringKindMustMatchTheAttribute() throws {
        let printfRows = [
            row(0x3400, "adrp", "x0, \(hex(page))"),
            row(0x3404, "add", "x0, x0, #0x650"),
            row(0x3408, "bl", "_printf"),
            row(0x340c, "ret"),
        ]
        let cfFrame = try callFrame(
            in: build(printfRows, constantStrings: [formatAddress: .init(text: "hi", kind: .cfString)]),
            target: "_printf"
        )
        assertFixedOnly(cfFrame, fixedCount: 1)

        let nslogRows = [
            row(0x3500, "adrp", "x0, \(hex(page))"),
            row(0x3504, "add", "x0, x0, #0x650"),
            row(0x3508, "bl", "_NSLog"),
            row(0x350c, "ret"),
        ]
        let cFrame = try callFrame(
            in: build(nslogRows, constantStrings: [formatAddress: .init(text: "hi", kind: .cString)]),
            target: "_NSLog"
        )
        assertFixedOnly(cFrame, fixedCount: 1)
    }

    func testWithoutConstantStringsOutputIsUnchanged() throws {
        let rows = [
            row(0x3600, "str", "x8, [sp]"),
            row(0x3604, "adrp", "x0, \(hex(page))"),
            row(0x3608, "add", "x0, x0, #0x650"),
            row(0x360c, "bl", "_printf"),
            row(0x3610, "ret"),
        ]
        let frame = try callFrame(in: build(rows), target: "_printf")
        assertFixedOnly(frame, fixedCount: 1)
        XCTAssertEqual(render(rows), render(rows, constantStrings: [:]))
    }

    // MARK: - Frame validation

    func testFrameRejectsTailOutsideItsAppleStackSlot() throws {
        let signature = try XCTUnwrap(CallSignatureCatalog.standard.signature(for: "_printf"))
        let evidence = MacIRCallFormatStringEvidence(
            kind: "printf", formatSourcePosition: 0, format: "%d", formatAddress: formatAddress,
            formatStringKind: .cString, argumentTypes: ["int"]
        )
        let fixed = MacIRCallArgument(
            location: .gpr(index: 0, carrierWidth: 64), role: .fixed(sourcePosition: 0),
            value: .register(name: "x0", version: 1)
        )
        func frame(tailLocation: MacIRCallArgumentLocation, scope: MacIRCallArgumentObservationScope?) -> MacIRCallFrame? {
            guard let scope,
                  let arguments = MacIRCallArguments([
                      fixed,
                      MacIRCallArgument(location: tailLocation, role: .anonymousVariadic(tailOrdinal: 0),
                                        value: .immediate(1)),
                  ], observationScope: scope) else { return nil }
            return MacIRCallFrame(target: "_printf", knownSignature: signature,
                                  tailCountEvidence: .formatString(evidence),
                                  controlInputs: .none, arguments: arguments)
        }
        XCTAssertNotNil(frame(tailLocation: .callStack(byteOffset: 0, size: 8, alignment: 8),
                              scope: .init(callStackRanges: [0..<8])))
        XCTAssertNil(frame(tailLocation: .gpr(index: 1, carrierWidth: 64),
                           scope: .init(gprIndices: [1])), "AAPCS64 register placement is wrong on Darwin")
        XCTAssertNil(frame(tailLocation: .callStack(byteOffset: 8, size: 8, alignment: 8),
                           scope: .init(callStackRanges: [0..<16])))
    }

    // MARK: - Helpers

    private func assertFixedOnly(
        _ frame: MacIRCallFrame,
        fixedCount: Int,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(frame.tailCountEvidence, message, file: file, line: line)
        XCTAssertTrue(frame.arguments.canonicalPhysicalEntriesForAudit.allSatisfy { $0.tailOrdinal == nil },
                      message, file: file, line: line)
        XCTAssertEqual(frame.denseFixedRenderValues().count, fixedCount, message, file: file, line: line)
    }

    private func hex(_ value: UInt64) -> String { "0x" + String(value, radix: 16) }

    private func build(
        _ rows: [InstructionRow],
        constantStrings: [UInt64: MacIRConstantString] = [:]
    ) -> MacIRFunction {
        MacIRBuilder().buildFunction(
            name: "hop5c_format_recovery",
            constantStrings: constantStrings,
            instructions: rows
        )
    }

    private func render(
        _ rows: [InstructionRow],
        constantStrings: [UInt64: MacIRConstantString] = [:]
    ) -> String {
        PseudocodePrinter().print(
            functionName: "hop5c_format_recovery",
            constantStrings: constantStrings,
            instructions: rows
        ).text
    }

    private func row(_ address: UInt64, _ mnemonic: String, _ operands: String = "") -> InstructionRow {
        InstructionRow(address: address, bytes: "", mnemonic: mnemonic, operands: operands,
                       hasBreakpoint: false, comment: nil)
    }

    private func callFrame(in function: MacIRFunction, target: String) throws -> MacIRCallFrame {
        for instruction in function.instructions {
            if case let .call(frame, _) = instruction.operation, frame.target == target {
                return frame
            }
        }
        throw MissingCall(target: target)
    }

    private struct MissingCall: Error { let target: String }
}
