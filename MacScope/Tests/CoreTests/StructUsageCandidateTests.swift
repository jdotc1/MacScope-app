import XCTest
@testable import MacScope

/// DP04 D1: usage-derived layout candidates from typed MacIR memory accesses.
final class StructUsageCandidateTests: XCTestCase {
    private func function(_ name: String, at start: UInt64, _ text: [(String, String)]) -> MacIRFunction {
        let rows = text.enumerated().map { index, pair in
            InstructionRow(address: start + UInt64(index * 4), bytes: "", mnemonic: pair.0, operands: pair.1,
                           hasBreakpoint: false, comment: nil)
        }
        return MacIRBuilder().buildFunction(name: name, startAddress: start, instructions: rows)
    }

    func testIdentityIncludesCarrierUnresolvedAccessAndIncompleteness() {
        func candidate(_ instructions: [(String, String)], budget: MacIRStructUsageAnalysis.Budget = .init()) -> StructLayoutCandidate {
            MacIRStructUsageAnalysis.candidate(for: .parameter(gprIndex: 0),
                in: function("_identity", at: 0x1000, instructions), budget: budget)
        }
        let scalar = candidate([("ldr", "w1, [x0]"), ("ret", "")])
        let vector = candidate([("ldr", "s1, [x0]"), ("ret", "")])
        XCTAssertEqual(scalar.fields.map(\.byteWidth), vector.fields.map(\.byteWidth))
        XCTAssertNotEqual(scalar.fields.first?.evidence.first?.carrier, vector.fields.first?.evidence.first?.carrier)
        XCTAssertNotEqual(scalar.candidateID, vector.candidateID, "the token binds the complete observation")

        let unresolved = candidate([("ldr", "w1, [x0]"), ("ldr", "x2, [x0, x3]"), ("ret", "")])
        XCTAssertEqual(unresolved.fields, scalar.fields)
        XCTAssertEqual(unresolved.unresolvedAccessAddresses, [0x1004])
        XCTAssertNotEqual(unresolved.candidateID, scalar.candidateID, "unresolved evidence is part of freshness")

        let call = [("ldr", "w1, [x0]"), ("bl", "_missing"), ("ret", "")]
        let missing = candidate(call)
        let emptyCallee = function("_missing", at: 0x2000, [("ret", "")])
        let budgeted = MacIRStructUsageAnalysis.candidate(for: .parameter(gprIndex: 0),
            in: function("_identity", at: 0x1000, call), callees: { _ in emptyCallee },
            budget: .init(maximumDepth: 0))
        XCTAssertEqual(missing.fields, scalar.fields)
        XCTAssertEqual(budgeted.fields, scalar.fields)
        XCTAssertEqual(missing.incompleteness, [.unresolvedCall])
        XCTAssertEqual(budgeted.incompleteness, [.budget])
        XCTAssertNotEqual(missing.candidateID, scalar.candidateID)
        XCTAssertNotEqual(budgeted.candidateID, missing.candidateID, "each incompleteness reason is bound")
    }

    func testOffsetsOverlapInteriorPointerAndDirectCall() throws {
        let f = function("_f", at: 0x1000, [
            ("ldr", "x1, [x0, #0x8]"),
            ("ldr", "w2, [x0, #0x8]"),     // same offset, narrower view: a conflict
            ("str", "x3, [x0, #0x18]"),
            ("add", "x4, x0, #0x10"),      // derived pointer: root + 0x10
            ("ldr", "w5, [x4, #0x4]"),     // root + 0x14
            ("ldur", "x6, [x0, #-0x8]"),   // negative: interior pointer
            ("ldr", "x7, [x0, x2]"),       // register-indexed: unresolved
            ("ret", ""),
        ])
        let candidate = MacIRStructUsageAnalysis.candidate(for: .parameter(gprIndex: 0), in: f)
        let described = candidate.fields.map { "\($0.offset):\($0.byteWidth):\($0.roles.map(\.rawValue))" }
        XCTAssertEqual(described, ["-8:8:[\"read\"]", "8:4:[\"read\"]", "8:8:[\"read\"]",
                                   "20:4:[\"read\"]", "24:8:[\"write\"]"], "\(described)")
        XCTAssertEqual(candidate.conflicts.map(\.range), [8 ..< 16], "mixed widths overlap, never replaced")
        XCTAssertEqual(candidate.unknownGaps, [0 ..< 8, 16 ..< 20], "holes stay unknown")
        XCTAssertEqual(candidate.extentLowerBound, 0x20)
        XCTAssertTrue(candidate.needsRebase)
        XCTAssertEqual(candidate.unresolvedAccessAddresses, [0x1018])
        XCTAssertTrue(candidate.incompleteness.isEmpty)
        XCTAssertEqual(candidate.candidateID,
                       MacIRStructUsageAnalysis.candidate(for: .parameter(gprIndex: 0), in: f).candidateID,
                       "deterministic identity")

        // One validated direct-call edge: g passes root + 0x20 to f.
        let g = function("_g", at: 0x2000, [("ldr", "x9, [x0]"), ("add", "x0, x0, #0x20"), ("bl", "_f"), ("ret", "")])
        let viaCall = MacIRStructUsageAnalysis.candidate(for: .parameter(gprIndex: 0), in: g,
                                                         callees: { $0 == "_f" ? f : nil })
        XCTAssertEqual(viaCall.fields.first { $0.offset == 0x20 + 0x18 }?.evidence.first?.viaCalls, ["_f"],
                       "\(viaCall.fields.map(\.offset))")
        XCTAssertTrue(viaCall.fields.contains { $0.offset == 0 && $0.byteWidth == 8 }, "g's own access")
        XCTAssertEqual(viaCall.extentLowerBound, 0x20 + 0x20)
        // Without the callee the edge is unresolved, not guessed.
        XCTAssertEqual(MacIRStructUsageAnalysis.candidate(for: .parameter(gprIndex: 0), in: g).incompleteness,
                       [.unresolvedCall])

        // A recursive edge stops (visited set), and the budget stop is reported.
        let h = function("_h", at: 0x3000, [("ldr", "x1, [x0]"), ("add", "x0, x0, #0x8"), ("bl", "_h"), ("ret", "")])
        let recursive = MacIRStructUsageAnalysis.candidate(for: .parameter(gprIndex: 0), in: h,
                                                           callees: { $0 == "_h" ? h : nil })
        XCTAssertEqual(recursive.incompleteness, [.recursion])
        let budgeted = MacIRStructUsageAnalysis.candidate(for: .parameter(gprIndex: 0), in: g,
                                                          callees: { $0 == "_f" ? f : nil },
                                                          budget: .init(maximumDepth: 0))
        XCTAssertEqual(budgeted.incompleteness, [.budget])
        XCTAssertFalse(budgeted.fields.contains { $0.offset == 0x38 }, "no transfer past the budget")
    }
}
