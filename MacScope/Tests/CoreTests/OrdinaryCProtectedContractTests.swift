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

final class OrdinaryCProtectedContractTests: XCTestCase {
    private typealias C = OrdinaryC

    func testJinitProtectedRestoreGroupRequiresExactEffectsAndDefinition() throws {
        let pair = try OrdinaryCUpsamplerFixturePair.make(.jinit)
        try pair.requireFullTypedRowOwnership()
        try check(pair.opaque, restores: [(211, 0x3b164, "f6 57 43 a9", 1, "x21_0")])
    }

    func testJ12initProtectedRestoreGroupRequiresExactEffectsAndDefinition() throws {
        let pair = try OrdinaryCUpsamplerFixturePair.make(.j12init)
        try pair.requireFullTypedRowOwnership()
        try check(pair.opaque, restores: [(183, 0x3ba50, "f6 57 43 a9", 1, "x21_0")])
    }

    func testSkipProtectedRestoreGroupsRequireBothCurrentDefinitions() throws {
        try check(OrdinaryCRecordedCallFixture.skipVariable(), restores: [
            (53, 0x334ec, "f4 4f 43 a9", 0, "x20_0"),
            (54, 0x334f0, "f6 57 42 a9", 1, "x21_0")
        ])
    }

    private func check(_ fixture: OrdinaryCRecordedCallFixture,
                       restores: [(row: Int, address: UInt64, bytes: String, destination: Int, older: String)]) throws {
        let contract = try C.contract(for: fixture)
        let lines = C.lines(fixture.document)
        let original = try C.Program(lines: lines, contract: contract)
        XCTAssertEqual(Set(original.contract.calls.keys), Set(fixture.callRows))
        XCTAssertEqual(original.contract.exterior.count, fixture.start == 0x33418 ? 11 : 13)
        for restore in restores {
            XCTAssertEqual(fixture.rows[restore.row].address, restore.address)
            XCTAssertEqual(fixture.rows[restore.row].bytes, restore.bytes)
            XCTAssertEqual(fixture.rows[restore.row].mnemonic, "ldp")
            let indices = fixture.document.lines.indices.filter {
                fixture.document.lines[$0].sourceAddress == restore.address
                    && fixture.document.lines[$0].text.trimmingCharacters(in: .whitespaces)
                        == contract.exterior[restore.row]
            }
            XCTAssertEqual(indices.count, 1)
            let index = try XCTUnwrap(indices.first)
            XCTAssertNil(fixture.document.lines[index].syntheticPhiEdge)
            let payload = try XCTUnwrap(contract.exterior[restore.row])
            let sides = payload.components(separatedBy: " = ")
            XCTAssertEqual(sides.count, 2)
            let destinations = sides[0].components(separatedBy: ", ")
            XCTAssertEqual(destinations.count, 2)
            XCTAssertEqual(payload.components(separatedBy: "*(uint64_t *)").count - 1, 2)

            // A label and its one physical tuple may share a source address.
            // This checks the envelope boundary, not duplicate CFG-label admission.
            let label = try XCTUnwrap(contract.allowedLabels.sorted().first)
            var labelled = lines
            labelled.insert(.init(text: "\(label):", source: restore.address, envelope: .body), at: index)
            try envelope(labelled, contract)

            var missing = lines
            missing.remove(at: index)
            try refuses(missing, contract: contract,
                reason: "missing/duplicated protected row \(restore.row)")
            var phiOnly = lines
            phiOnly[index] = .init(text: lines[index].text, source: nil, envelope: .body,
                phiEdge: .init(blockAddress: restore.address,
                    predecessorAddress: fixture.rows[restore.row - 1].address))
            try refuses(phiOnly, contract: contract,
                reason: "missing/duplicated protected row \(restore.row)")
            var duplicated = lines
            duplicated.insert(lines[index], at: index)
            try refuses(duplicated, contract: contract,
                reason: "missing/duplicated protected row \(restore.row)")
            var extra = lines
            extra.insert(.init(text: "*(uint64_t *)(sp_1) = (uint64_t)(0x0);",
                source: restore.address, envelope: .body), at: index + 1)
            try refuses(extra, contract: contract,
                reason: "extra executable text at protected row \(restore.row)")

            let changedWidth = payload.replacingOccurrences(of: "uint64_t", with: "uint32_t")
            let changedAddress = payload.replacingOccurrences(of: "+ 0x8)", with: "+ 0x10)")
            let swapped = destinations.reversed().joined(separator: ", ") + " = " + sides[1]
            let oldDefinition = payload.replacingOccurrences(of: destinations[restore.destination], with: restore.older)
            let missingEffect = destinations[0] + " = " + sides[1].components(separatedBy: ", ")[0] + ";"
            for changed in [changedWidth, changedAddress, swapped, oldDefinition, missingEffect] {
                XCTAssertNotEqual(changed, payload)
                var document = fixture.document
                document.lines[index].text = changed
                // The pre-mutation certificate cannot absorb any altered effect.
                try refuses(C.lines(document), contract: contract,
                    reason: "missing/duplicated protected row \(restore.row)")
                // Nor may recertification infer an older definition or new operation.
                XCTAssertThrowsError(try program(replacing(fixture, document: document)))
            }
            let previousAddress = fixture.rows[restore.row - 1].address
            let previous = try XCTUnwrap(fixture.function.instructions.first {
                $0.source.address == previousAddress
            })
            XCTAssertNotEqual(previous.source.address, restore.address)
            var wrongSource = fixture.document
            wrongSource.lines[index].source = previous.source
            XCTAssertThrowsError(try program(replacing(fixture, document: wrongSource)))
        }
        // Whole-envelope transport must preserve call roles too, not just restores.
        let call = try XCTUnwrap(contract.calls.sorted(by: { $0.key < $1.key }).last?.value)
        let callIndex = try XCTUnwrap(fixture.document.lines.firstIndex {
            $0.sourceAddress == fixture.rows[call.row].address
                && $0.text.trimmingCharacters(in: .whitespaces) == call.payload
        })
        var changedCall = fixture.document
        changedCall.lines[callIndex].text = call.payload.replacingOccurrences(of: "; // call",
            with: "; *(uint64_t *)(sp_1) = (uint64_t)(0x0); // call")
        XCTAssertNotEqual(changedCall.lines[callIndex].text, call.payload)
        XCTAssertThrowsError(try program(replacing(fixture, document: changedCall)))
        let result = try XCTUnwrap(call.resultName)
        XCTAssertTrue(call.payload.hasPrefix(result + " = "))
        XCTAssertNotEqual(result, "x0_0")
        var oldCallResult = fixture.document
        oldCallResult.lines[callIndex].text = "x0_0" + String(call.payload.dropFirst(result.count))
        XCTAssertTrue(oldCallResult.lines[callIndex].text.hasPrefix("x0_0 = "))
        XCTAssertThrowsError(try program(replacing(fixture, document: oldCallResult)))
    }

    private func envelope(_ lines: [C.TextLine], _ contract: C.Contract) throws {
        try contract.validateEnvelope(lines: lines, tokens: C.lex(lines.map(\.text).joined(separator: "\n")))
    }

    private func refuses(_ lines: [C.TextLine], contract: C.Contract, reason: String) throws {
        do {
            _ = try C.Program(lines: lines, contract: contract)
            XCTFail("changed protected group was admitted")
        } catch let C.Failure.invalidContract(actual) {
            XCTAssertEqual(actual, reason)
        } catch {
            XCTFail("wrong protected-group failure: \(error)")
        }
    }

    private func program(_ fixture: OrdinaryCRecordedCallFixture) throws -> C.Program {
        try C.Program(lines: C.lines(fixture.document), contract: C.contract(for: fixture))
    }

    private func replacing(_ fixture: OrdinaryCRecordedCallFixture,
                           document: PseudocodeDocument) -> OrdinaryCRecordedCallFixture {
        .init(start: fixture.start, baselineText: fixture.baselineText, callRows: fixture.callRows,
            rows: fixture.rows, input: fixture.input, function: fixture.function, document: document)
    }
}
