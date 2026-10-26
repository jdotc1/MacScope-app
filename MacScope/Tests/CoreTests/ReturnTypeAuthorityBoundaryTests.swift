import Foundation
import XCTest
@testable import MacScope

final class ReturnTypeAuthorityBoundaryTests: XCTestCase {
    private let caller: UInt64 = 0x1000
    private let leaf: UInt64 = 0x1014
    private let marker = MacIRValue.unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker)
    private let withoutLeafDeclaration = "int caller(void);"
    private let withLeafDeclaration = "int caller(void);\nvoid leaf(void);"

    private struct Fixture {
        let analysis: ImageAnalysis
        let signatures: [UInt64: FunctionSignatureOverride]
        let types: [TypeDefinition]
    }

    private func fixture(header: String) throws -> Fixture {
        // The source-model leaf returns an int, but no declaration is supplied
        // unless the header explicitly contains the independent leaf line.
        let bodies: [UInt64: (String, [UInt32])] = [
            caller: ("caller", [0xa9bf7bfd, 0x94000004, 0xd2800000, 0xa8c17bfd, 0xd65f03c0]),
            leaf: ("leaf", [0x528000e0, 0xd65f03c0])
        ]
        let bytes = S1RecoveryMachOFixture.make(bodies: bodies, exported: [])
        let parsed = try MachOParser().parseWithFixupCoverage(bytes,
            options: MachOParseOptions(recoverStringLiterals: false,
                recoverObjectiveCMetadata: false, recoverSwiftMetadata: false,
                parseCodeSignature: false))
        XCTAssertTrue(parsed.coverage.isComplete && parsed.coverage.symbolInventoryIsComplete
            && parsed.coverage.exportInventoryIsComplete && parsed.coverage.functionStartsInventoryIsComplete
            && parsed.coverage.dataInCodeInventoryIsComplete)
        XCTAssertEqual(parsed.file.functionStarts.map(\.address), [caller, leaf])
        let section = try XCTUnwrap(parsed.file.sections.first { $0.sectionName == "__text" })
        let raw = bytes.subdata(in: Int(section.fileOffset)..<(Int(section.fileOffset) + Int(section.size)))
        let decoded = ARM64Decoder().decode(raw, baseAddress: section.address,
            maxInstructionCount: Int(section.size / 4))
        XCTAssertEqual(decoded.count, 7)
        XCTAssertEqual(section.size, 28)
        XCTAssertEqual(decoded.first { $0.address == caller + 4 }?.branchTarget, leaf)
        var analysis = ImageAnalysis()
        analysis.imageBytes = bytes
        analysis.instructions = decoded.map(InstructionRow.init(decoded:))
        analysis.functions = bodies.sorted { $0.key < $1.key }.map { address, body in
            FunctionSummary(id: UUID(), name: body.0, startAddress: address,
                endAddress: address + UInt64(body.1.count * 4), confidence: 1)
        }
        let declarations = CTypeHeaderParser.parse(header)
        XCTAssertTrue(declarations.diagnostics.isEmpty, declarations.diagnostics.joined(separator: "; "))
        var signatures: [UInt64: FunctionSignatureOverride] = [:]
        for prototype in declarations.prototypes {
            if let function = analysis.functions.first(where: { $0.name == prototype.name }) {
                signatures[function.startAddress] = prototype.signature
            }
        }
        return Fixture(analysis: analysis, signatures: signatures, types: declarations.types)
    }

    private func lift(_ fixture: Fixture, start: UInt64, ssa: Bool) throws -> MacIRFunction {
        let summary = try XCTUnwrap(fixture.analysis.functions.first { $0.startAddress == start })
        let rows = fixture.analysis.instructions.filter {
            $0.address >= summary.startAddress && $0.address < summary.endAddress
        }
        let function = PseudocodePrinter().buildFunction(functionName: summary.name, startAddress: start,
            signatureOverrides: fixture.signatures, types: fixture.types,
            explicitCFGEnabled: ssa, ssaEnabled: ssa, instructions: rows)
        XCTAssertEqual(function.ssaEnabled, ssa)
        return function
    }

    private func completeDiscardReport(_ fixture: Fixture, ssa: Bool) throws
        -> MacIRCallerReturnEvidence.ClosedWorldReport {
        let function = try lift(fixture, start: caller, ssa: ssa)
        let report = MacIRCallerReturnEvidence.collectClosedWorld(analysis: fixture.analysis,
            functions: [function], effectiveSignatures: fixture.signatures)
        XCTAssertEqual(report.evidence[leaf]?.count, 6)
        XCTAssertTrue(report.evidence[leaf]?.allSatisfy(\.satisfied) == true,
            "A missing image or caller proof must not make the authority negative pass")
        return report
    }

    private func assertUnresolved(_ function: MacIRFunction,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotEqual(function.returnType, "void", file: file, line: line)
        XCTAssertEqual(function.returnValue, marker, file: file, line: line)
        XCTAssertTrue(function.instructions.contains { $0.operation == .returnValue(marker) },
            file: file, line: line)
        let text = PseudocodePrinter().print(function: function).text
        XCTAssertTrue(text.contains("return unresolved_return_contract;"), text, file: file, line: line)
        XCTAssertFalse(text.contains("return;"), text, file: file, line: line)
    }

    private func assertVoid(_ function: MacIRFunction,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(function.returnType, "void", file: file, line: line)
        XCTAssertNil(function.returnValue, file: file, line: line)
        XCTAssertTrue(function.instructions.contains { $0.operation == .returnValue(nil) },
            file: file, line: line)
        let text = PseudocodePrinter().print(function: function).text
        XCTAssertTrue(text.contains("return;"), text, file: file, line: line)
        XCTAssertFalse(text.contains("unresolved_return_contract"), text, file: file, line: line)
    }

    func testPrivateIntegerResultDiscardedByEveryCallerStaysUnresolved() throws {
        for ssa in [false, true] {
            let value = try fixture(header: withoutLeafDeclaration)
            XCTAssertNil(value.signatures[leaf])
            let report = try completeDiscardReport(value, ssa: ssa)
            XCTAssertEqual(report.contracts.count, 0)
            XCTAssertEqual(report.census["discard_without_return_type_authority"], 1)
            XCTAssertTrue(report.refusals.contains {
                $0.functionAddress == leaf && $0.reason == "discard_without_return_type_authority"
            })
            assertUnresolved(try lift(value, start: leaf, ssa: ssa))
        }
    }

    func testIndependentVoidLeafDeclarationAndRemovedLineControl() throws {
        for ssa in [false, true] {
            let declared = try fixture(header: withLeafDeclaration)
            let removed = try fixture(header: withoutLeafDeclaration)
            XCTAssertEqual(declared.analysis.imageBytes, removed.analysis.imageBytes)
            XCTAssertEqual(declared.analysis.instructions, removed.analysis.instructions)
            XCTAssertEqual(declared.analysis.functions.map(\.name), removed.analysis.functions.map(\.name))
            XCTAssertEqual(declared.analysis.functions.map(\.startAddress), removed.analysis.functions.map(\.startAddress))
            XCTAssertEqual(declared.analysis.functions.map(\.endAddress), removed.analysis.functions.map(\.endAddress))
            XCTAssertEqual(declared.signatures[leaf]?.returnType, "void")
            XCTAssertNil(removed.signatures[leaf])
            XCTAssertEqual(declared.signatures[caller], removed.signatures[caller])
            let declaredReport = try completeDiscardReport(declared, ssa: ssa)
            let removedReport = try completeDiscardReport(removed, ssa: ssa)
            XCTAssertNil(declaredReport.contracts[leaf], "The declaration route, not this audit, supplies void")
            XCTAssertNil(removedReport.contracts[leaf])
            XCTAssertTrue(removedReport.refusals.contains {
                $0.functionAddress == leaf && $0.reason == "discard_without_return_type_authority"
            })
            assertVoid(try lift(declared, start: leaf, ssa: ssa))
            assertUnresolved(try lift(removed, start: leaf, ssa: ssa))
        }
    }

    private func lastVoidCall(header: String, ssa: Bool) throws -> MacIRFunction {
        let declarations = CTypeHeaderParser.parse(header)
        XCTAssertTrue(declarations.diagnostics.isEmpty, declarations.diagnostics.joined(separator: "; "))
        let callee = try XCTUnwrap(declarations.prototypes.first { $0.name == "callee" }?.signature)
        XCTAssertEqual(callee.returnType, "void")
        var own: [UInt64: FunctionSignatureOverride] = [:]
        if let signature = declarations.prototypes.first(where: { $0.name == "caller" })?.signature {
            own[caller] = signature
        }
        let rows: [InstructionRow] = [
            .init(address: 0x1000, bytes: "fd 7b bf a9", mnemonic: "stp", operands: "x29, x30, [sp, #-16]!", hasBreakpoint: false, comment: nil),
            .init(address: 0x1004, bytes: "ff 03 00 94", mnemonic: "bl", operands: "0x2000", hasBreakpoint: false, comment: nil),
            .init(address: 0x1008, bytes: "fd 7b c1 a8", mnemonic: "ldp", operands: "x29, x30, [sp], #16", hasBreakpoint: false, comment: nil),
            .init(address: 0x100c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let function = PseudocodePrinter().buildFunction(functionName: "caller", startAddress: caller,
            signatureOverrides: own, authoredCallSignaturesByTarget: ["0x2000": callee],
            types: declarations.types, explicitCFGEnabled: ssa, ssaEnabled: ssa, instructions: rows)
        XCTAssertEqual(function.ssaEnabled, ssa)
        let call = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1004 })
        guard case let .call(frame, result) = call.operation else {
            XCTFail("The fixture must reach an actual declared-void call")
            return function
        }
        XCTAssertEqual(frame.knownSignature?.returnType, "void")
        XCTAssertEqual(frame.knownSignature?.parameters.count, 0)
        XCTAssertNil(frame.typedIndirectSignature)
        XCTAssertNil(result, "Removing caller inference must not allocate a result for the actual void call")
        return function
    }

    func testLastDeclaredVoidCallDoesNotDeclareItsCallerVoid() throws {
        for ssa in [false, true] {
            assertUnresolved(try lastVoidCall(header: "void callee(void);", ssa: ssa))
        }
    }

    func testDeclaredVoidOwnFunctionSurvivesLastVoidCall() throws {
        for ssa in [false, true] {
            assertVoid(try lastVoidCall(header: "void callee(void);\nvoid caller(void);", ssa: ssa))
        }
    }
}
