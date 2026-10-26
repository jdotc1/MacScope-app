import Foundation
import XCTest
@testable import MacScope

/// XCTest packaging of the six retained real decoder/printer/build/export cases.
/// These compare omitted arguments with explicit empty/nil defaults; they do not
/// exercise active S1 proof behavior or establish a behavioral red for an inert API.
final class S1RenderInputAPIDefaultIdentityTests: XCTestCase {
    func testScalarNilCallerWidthDefaultIdentity() {
        assertDefaultIdentity(name: "scalar", words: [0x91000400, 0xd65f03c0],
                              mnemonics: ["add", "ret"], width: nil)
    }

    func testScalarX0CallerWidthDefaultIdentity() {
        assertDefaultIdentity(name: "scalar", words: [0x91000400, 0xd65f03c0],
                              mnemonics: ["add", "ret"], width: .x0)
    }

    func testScalarW0CallerWidthDefaultIdentity() {
        assertDefaultIdentity(name: "scalar", words: [0x91000400, 0xd65f03c0],
                              mnemonics: ["add", "ret"], width: .w0)
    }

    func testIndirectNilCallerWidthDefaultIdentity() {
        assertDefaultIdentity(name: "indirect", words: [0xf9400008, 0xd63f0100, 0xd65f03c0],
                              mnemonics: ["ldr", "blr", "ret"], width: nil)
    }

    func testIndirectX0CallerWidthDefaultIdentity() {
        assertDefaultIdentity(name: "indirect", words: [0xf9400008, 0xd63f0100, 0xd65f03c0],
                              mnemonics: ["ldr", "blr", "ret"], width: .x0)
    }

    func testIndirectW0CallerWidthDefaultIdentity() {
        assertDefaultIdentity(name: "indirect", words: [0xf9400008, 0xd63f0100, 0xd65f03c0],
                              mnemonics: ["ldr", "blr", "ret"], width: .w0)
    }

    private func assertDefaultIdentity(name: String, words: [UInt32], mnemonics: [String],
                                       width: MacIRCallerReturnEvidence.Width?,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let bytes = words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } }
        let decoded = ARM64Decoder().decode(Data(bytes), baseAddress: 0x1000, maxInstructionCount: words.count)
        XCTAssertEqual(decoded.map(\.mnemonic), mnemonics, file: file, line: line)
        XCTAssertEqual(decoded.flatMap(\.bytes), bytes, file: file, line: line)
        let rows = decoded.map { InstructionRow(address: $0.address, bytes: $0.byteText,
            mnemonic: $0.mnemonic, operands: $0.operands, hasBreakpoint: false, comment: $0.comment) }
        let printer = PseudocodePrinter(options: .default)
        let function = printer.buildFunction(functionName: name, startAddress: 0x1000,
            callerReturnWidth: width, instructions: rows)
        let document = printer.print(functionName: name, startAddress: 0x1000,
            callerReturnWidth: width, instructions: rows)
        XCTAssertEqual(document, printer.print(function: function), file: file, line: line)
        let input = PseudocodeRenderInput(imageSlot: .primary, functionName: name,
            startAddress: 0x1000, jumpTables: [:], objcSelectors: [:], nameOverrides: [:],
            signatureOverrides: [:], registerNameOverrides: [:], types: [], instructions: rows,
            callerReturnWidth: width)
        let export = DocumentExportService().pseudocodeText(for: input, options: .default)
        XCTAssertEqual(export, document.text, file: file, line: line)
        let explicitFunction = printer.buildFunction(functionName: name, startAddress: 0x1000,
            slotCallContracts: [:], callerReturnWidth: width, callerReturnType: nil, instructions: rows)
        let explicitDocument = printer.print(functionName: name, startAddress: 0x1000,
            slotCallContracts: [:], callerReturnWidth: width, callerReturnType: nil, instructions: rows)
        XCTAssertEqual(function, explicitFunction, file: file, line: line)
        XCTAssertEqual(document, explicitDocument, file: file, line: line)
        XCTAssertTrue(input.slotCallContracts.isEmpty, file: file, line: line)
        XCTAssertNil(input.callerReturnType, file: file, line: line)
        var explicitInput = input
        explicitInput.slotCallContracts = [:]
        explicitInput.callerReturnType = nil
        XCTAssertEqual(input, explicitInput, file: file, line: line)
        XCTAssertEqual(DocumentExportService().pseudocodeText(for: explicitInput, options: .default),
                       export, file: file, line: line)
    }
}
