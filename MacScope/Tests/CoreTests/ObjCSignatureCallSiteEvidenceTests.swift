import XCTest
@testable import MacScope

final class ObjCSignatureCallSiteEvidenceTests: XCTestCase {
    func testMatchingSelectorCarriesAddressAndStructuredShapes() throws {
        let function = try function(selector: "lookup:")
        let sites = ObjCSignatureCallSiteEvidence.collect(functions: [function], selector: "lookup:")
        XCTAssertEqual(sites.count, 1)
        let site = try XCTUnwrap(sites.first)
        XCTAssertEqual(site.address, 0x1004)
        XCTAssertEqual(site.functionAddress, 0x1000)
        XCTAssertEqual(site.selector, "lookup:")
        XCTAssertEqual(site.selrefAddress, 0x2000)
        XCTAssertEqual(site.source, "Structured MacIR")
        XCTAssertEqual(site.receiverShape, "register x0 version 1")
        XCTAssertEqual(site.selectorShape, "symbol selref")
        XCTAssertEqual(site.argumentShapes.count, 1)
        XCTAssertNil(site.argumentShapes[0].value)
        XCTAssertNil(site.argumentShapes[0].type)
        XCTAssertNil(site.argumentShapes[0].widthBits)
        XCTAssertEqual(site.returnShape.value, "register x0 version 2")
        XCTAssertNil(site.returnShape.type)
        XCTAssertNil(site.returnShape.widthBits)
    }

    func testUnrelatedSelectorAndTextOnlySelectorAreNotObservations() throws {
        let matched = try function(selector: "lookup:")
        XCTAssertTrue(ObjCSignatureCallSiteEvidence.collect(
            functions: [matched], selector: "unrelated:"
        ).isEmpty)
        let textOnly = try function(selector: "lookup:", includeSelectorEvidence: false)
        XCTAssertTrue(ObjCSignatureCallSiteEvidence.collect(
            functions: [textOnly], selector: "lookup:"
        ).isEmpty)
    }

    func testMissingReceiverAndResultRemainUnknown() throws {
        let function = try function(selector: "replace:with:", includeReceiverAndResult: false)
        let site = try XCTUnwrap(ObjCSignatureCallSiteEvidence.collect(
            functions: [function], selector: "replace:with:"
        ).first)
        XCTAssertNil(site.receiverShape)
        XCTAssertNil(site.returnShape.value)
        XCTAssertNil(site.returnShape.type)
        XCTAssertNil(site.returnShape.widthBits)
        XCTAssertEqual(site.argumentShapes.count, 2)
        XCTAssertTrue(site.argumentShapes.allSatisfy {
            $0.value == nil && $0.type == nil && $0.widthBits == nil
        })
    }

    func testZeroArgumentSelectorHasNoInventedParameters() throws {
        let function = try function(selector: "description")
        let site = try XCTUnwrap(ObjCSignatureCallSiteEvidence.collect(
            functions: [function], selector: "description"
        ).first)
        XCTAssertTrue(site.argumentShapes.isEmpty)
        XCTAssertNil(site.returnShape.type)
        XCTAssertNil(site.returnShape.widthBits)
    }

    func testCollectionIsBounded() throws {
        let base = try function(selector: "lookup:")
        var manyCalls = base
        manyCalls.instructions = (0..<17).map { index in
            var instruction = base.instructions[0]
            instruction.source.address += UInt64(index * 4)
            return instruction
        }
        let sites = ObjCSignatureCallSiteEvidence.collect(functions: [manyCalls], selector: "lookup:")
        XCTAssertEqual(sites.count, 16)
        XCTAssertEqual(sites.map(\.address), (0..<16).map { 0x1004 + UInt64($0 * 4) })
        let functions = (0..<9).map { index in
            var function = base
            function.instructions[0].source.address += UInt64(index * 0x100)
            return function
        }
        XCTAssertEqual(ObjCSignatureCallSiteEvidence.collect(functions: functions, selector: "lookup:").count, 8)
        var oversized = base
        oversized.instructions = Array(repeating: base.instructions[0], count: 2_049)
        XCTAssertTrue(ObjCSignatureCallSiteEvidence.collect(functions: [oversized], selector: "lookup:").isEmpty)
    }

    private func function(
        selector: String,
        includeSelectorEvidence: Bool = true,
        includeReceiverAndResult: Bool = true
    ) throws -> MacIRFunction {
        let evidence = try XCTUnwrap(MacIRCallSelectorEvidence(name: selector, selrefAddress: 0x2000))
        var entries = [MacIRCallArgument(
            location: .gpr(index: 1, carrierWidth: 64),
            role: .fixed(sourcePosition: 1),
            value: .symbol("selref"),
            selectorEvidence: includeSelectorEvidence ? evidence : nil
        )]
        if includeReceiverAndResult {
            entries.append(MacIRCallArgument(
                location: .gpr(index: 0, carrierWidth: 64),
                role: .fixed(sourcePosition: 0), value: .register(name: "x0", version: 1)
            ))
        }
        let arguments = try XCTUnwrap(MacIRCallArguments(entries))
        let signature = MacIRCallSignature(
            target: "_objc_msgSend", returnType: "id", parameters: [
                .init(index: 0, register: "x0", type: "id", name: "self"),
                .init(index: 1, register: "x1", type: "SEL", name: "_cmd"),
            ], isVariadic: true
        )
        let frame = try XCTUnwrap(MacIRCallFrame(
            target: "_objc_msgSend", knownSignature: signature,
            tailCountEvidence: includeSelectorEvidence
                ? .objectiveCSelectorColonCount(selector.filter { $0 == ":" }.count) : nil,
            controlInputs: .none, arguments: arguments
        ))
        return MacIRFunction(name: "caller", startAddress: 0x1000, instructions: [
            MacIRInstruction(
                source: .init(address: 0x1004, byteText: "", mnemonic: "bl", operands: "_objc_msgSend"),
                operation: .call(frame: frame, result: includeReceiverAndResult ? .register(name: "x0", version: 2) : nil)
            ),
        ])
    }
}
