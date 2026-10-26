import Foundation
import XCTest
@testable import MacScope

final class FunctionVersionMatcherTests: XCTestCase {
    // MARK: - Fixtures

    private func function(
        _ id: String,
        _ address: UInt64,
        name: String? = nil,
        size: UInt64 = 0x40,
        body: String? = nil,
        instructions: Int? = 10,
        cfg: String? = nil,
        blocks: Int? = 1,
        edges: Int? = 0,
        callees: [String]? = [],
        imports: [String]? = [],
        strings: [String]? = []
    ) -> FunctionVersionFingerprint {
        FunctionVersionFingerprint(
            id: id, address: address, symbolName: name, size: size,
            basicBlockCount: blocks, edgeCount: edges, cfgShapeHash: cfg,
            normalizedBodyHash: body, instructionCount: instructions,
            calleeIDs: callees, importedCalleeNames: imports, stringReferences: strings)
    }

    /// A small program; `shift` relocates every address, as a rebuilt binary would.
    private func program(prefix: String, shift: UInt64) -> [FunctionVersionFingerprint] {
        [
            function("\(prefix)main", 0x1000 + shift, name: "_main", body: "main-body", cfg: "main-cfg",
                     blocks: 3, edges: 3, callees: ["\(prefix)parse", "\(prefix)emit"], imports: ["_exit"]),
            function("\(prefix)parse", 0x1100 + shift, name: "_parse", body: "parse-body", cfg: "parse-cfg",
                     blocks: 4, edges: 5, strings: ["usage"]),
            function("\(prefix)emit", 0x1200 + shift, name: "_emit", body: "emit-body", cfg: "emit-cfg",
                     blocks: 2, edges: 1, imports: ["_puts"]),
            function("\(prefix)util", 0x1300 + shift, name: "_util", body: "util-body", cfg: "util-cfg"),
        ]
    }

    // MARK: - Identity

    func testIdenticalVersionsAreAllUnchanged() throws {
        let result = try FunctionVersionMatcher(
            old: program(prefix: "o.", shift: 0), new: program(prefix: "n.", shift: 0x4000)).match()

        XCTAssertEqual(result.matches.map(\.oldID), ["o.main", "o.parse", "o.emit", "o.util"])
        XCTAssertEqual(result.matches.map(\.newID), ["n.main", "n.parse", "n.emit", "n.util"])
        XCTAssertTrue(result.matches.allSatisfy { $0.basis == .symbolName && $0.confidence == .high })
        XCTAssertTrue(result.matches.allSatisfy { !$0.isChanged && !$0.symbolNameChanged })
        XCTAssertEqual(result.unchangedMatches.count, 4)
        XCTAssertTrue(result.changedMatches.isEmpty)
        XCTAssertTrue(result.addedIDs.isEmpty)
        XCTAssertTrue(result.removedIDs.isEmpty)
        XCTAssertTrue(result.unresolved.isEmpty)
    }

    func testStrippedFunctionIsMatchedByNormalizedBody() throws {
        let old = [function("o.helper", 0x2000, name: "_helper", body: "helper-body", cfg: "h-cfg")]
        let new = [function("n.helper", 0x2400, name: nil, body: "helper-body", cfg: "h-cfg")]

        let match = try XCTUnwrap(FunctionVersionMatcher(old: old, new: new).match().match(forOldID: "o.helper"))

        XCTAssertEqual(match.newID, "n.helper")
        XCTAssertEqual(match.basis, .normalizedBody)
        XCTAssertEqual(match.confidence, .high)
        XCTAssertTrue(match.symbolNameChanged)
        XCTAssertFalse(match.isChanged, "a stripped symbol is not a code change")
    }

    func testGeneratedNamesAreNeverNameEvidence() throws {
        // Equal `sub_<hex>` spellings are address coincidence, not identity.
        let old = [function("o.a", 0x2000, name: "sub_2000", body: "a"), function("o.b", 0x3000, name: nil, body: "b")]
        let new = [function("n.a", 0x3000, name: nil, body: "b2"), function("n.b", 0x2000, name: "sub_2000", body: "c")]

        let result = try FunctionVersionMatcher(old: old, new: new).match()

        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertEqual(result.removedIDs, ["o.a", "o.b"])
        XCTAssertEqual(result.addedIDs, ["n.b", "n.a"])
        XCTAssertTrue(FunctionVersionFingerprinting.isGeneratedName("sub_100003f00"))
        XCTAssertTrue(FunctionVersionFingerprinting.isGeneratedName("sub_0x0000000100003f00"), "MacScope's own fallback spelling")
        XCTAssertTrue(FunctionVersionFingerprinting.isGeneratedName("loc_0x100003f00"))
        XCTAssertFalse(FunctionVersionFingerprinting.isGeneratedName("sub_0x"))
        XCTAssertTrue(FunctionVersionFingerprinting.isGeneratedName("_entry"))
        XCTAssertFalse(FunctionVersionFingerprinting.isGeneratedName("sub_parse"))
        XCTAssertFalse(FunctionVersionFingerprinting.isGeneratedName("_main"))
    }

    // MARK: - Change detection

    func testChangedFunctionReportsExactlyTheDifferingFingerprints() throws {
        let old = [
            function("o.f", 0x1000, name: "_f", size: 0x40, body: "f1", cfg: "f-cfg1", blocks: 2, edges: 1),
            function("o.g", 0x1100, name: "_g", body: "g", cfg: "g-cfg", imports: ["_malloc"]),
            function("o.h", 0x1200, name: "_h", body: "h", cfg: "h-cfg", strings: ["old text"]),
        ]
        let new = [
            function("n.f", 0x1000, name: "_f", size: 0x48, body: "f2", cfg: "f-cfg2", blocks: 3, edges: 3),
            function("n.g", 0x1100, name: "_g", body: "g", cfg: "g-cfg", imports: ["_calloc"]),
            function("n.h", 0x1200, name: "_h", body: "h", cfg: "h-cfg", strings: ["new text"]),
        ]

        let result = try FunctionVersionMatcher(old: old, new: new).match()

        XCTAssertEqual(result.match(forOldID: "o.f")?.differences, [.body, .controlFlow, .size])
        XCTAssertEqual(result.match(forOldID: "o.g")?.differences, [.callees])
        XCTAssertEqual(result.match(forOldID: "o.h")?.differences, [.stringReferences])
        XCTAssertEqual(result.changedMatches.map(\.oldID), ["o.f", "o.g", "o.h"])
    }

    func testSemanticImmediateChangeIsReportedByAnalysisAdapter() throws {
        func image(_ immediate: String) -> ImageAnalysis {
            var value = ImageAnalysis()
            let id = UUID()
            value.functions = [FunctionSummary(id: id, name: "_constant", startAddress: 0x1000,
                                               endAddress: 0x1008, confidence: 1)]
            value.instructions = [
                InstructionRow(address: 0x1000, bytes: "20 00 80 52", mnemonic: "mov", operands: "w0, #\(immediate)", hasBreakpoint: false, comment: nil),
                InstructionRow(address: 0x1004, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
            ]
            return value
        }
        let oldAnalysis = image("1")
        let newAnalysis = image("2")
        let old = FunctionVersionFingerprintAdapter.fingerprints(from: oldAnalysis)
        let new = FunctionVersionFingerprintAdapter.fingerprints(from: newAnalysis)

        XCTAssertEqual(old.first?.normalizedBodyHash, new.first?.normalizedBodyHash,
                       "normalized matching should remain tolerant of changed immediate values")
        let report = try VersionCompareComputation.build(old: oldAnalysis, new: newAnalysis).report
        XCTAssertEqual(report.summary.changed, 1)
        XCTAssertEqual(report.summary.unchanged, 0)
        XCTAssertEqual(report.rows.first?.status, .changed)
        XCTAssertEqual(report.rows.first?.differences, [.body])
    }

    func testUnknownFingerprintsNeverReportDifferences() throws {
        let old = [function("o.f", 0x1000, name: "_f", body: nil, cfg: "c", blocks: nil, edges: nil, callees: nil, imports: nil, strings: nil)]
        let new = [function("n.f", 0x1000, name: "_f", body: "b", cfg: nil, blocks: 2, edges: 1)]

        let match = try XCTUnwrap(FunctionVersionMatcher(old: old, new: new).match().matches.first)

        XCTAssertEqual(match.differences, [])
    }

    func testAddedAndRemovedFunctions() throws {
        var old = program(prefix: "o.", shift: 0)
        old.append(function("o.legacy", 0x1400, name: "_legacy", body: "legacy-body", cfg: "legacy-cfg"))
        var new = program(prefix: "n.", shift: 0)
        new.append(function("n.feature", 0x1500, name: "_feature", body: "feature-body", cfg: "feature-cfg"))
        new.append(function("n.feature2", 0x1600, name: nil, body: "feature2-body", cfg: "feature2-cfg"))

        let result = try FunctionVersionMatcher(old: old, new: new).match()

        XCTAssertEqual(result.matches.count, 4)
        XCTAssertEqual(result.removedIDs, ["o.legacy"])
        XCTAssertEqual(result.addedIDs, ["n.feature", "n.feature2"])
        XCTAssertTrue(result.unresolved.isEmpty)
    }

    // MARK: - Ambiguity

    func testDuplicateBodiesStayUnresolvedInsteadOfGuessed() throws {
        let old = [
            function("o.d1", 0x1000, body: "dup", cfg: "dup-cfg"),
            function("o.d2", 0x1100, body: "dup", cfg: "dup-cfg"),
            function("o.x", 0x1200, body: "triple", cfg: "t-cfg"),
            function("o.y", 0x1300, body: "triple", cfg: "t-cfg"),
        ]
        let new = [
            function("n.d1", 0x2000, body: "dup", cfg: "dup-cfg"),
            function("n.d2", 0x2100, body: "dup", cfg: "dup-cfg"),
            function("n.x", 0x2200, body: "triple", cfg: "t-cfg"),
        ]

        let result = try FunctionVersionMatcher(old: old, new: new).match()

        XCTAssertTrue(result.matches.isEmpty, "no duplicate may be guessed")
        XCTAssertEqual(result.unresolved, [
            FunctionVersionUnresolvedGroup(oldIDs: ["o.d1", "o.d2"], newIDs: ["n.d1", "n.d2"], bases: [.duplicateNormalizedBody]),
            FunctionVersionUnresolvedGroup(oldIDs: ["o.x", "o.y"], newIDs: ["n.x"], bases: [.duplicateNormalizedBody]),
        ])
        XCTAssertTrue(result.addedIDs.isEmpty, "unresolved functions are not added")
        XCTAssertTrue(result.removedIDs.isEmpty, "unresolved functions are not removed")
    }

    func testDuplicateSymbolNamesStayUnresolved() throws {
        let old = [function("o.a", 0x1000, name: "_static", body: "a"), function("o.b", 0x1100, name: "_static", body: "b")]
        let new = [function("n.a", 0x1000, name: "_static", body: "a2"), function("n.b", 0x1100, name: "_static", body: "b2")]

        let result = try FunctionVersionMatcher(old: old, new: new).match()

        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertEqual(result.unresolved.map(\.bases), [[.duplicateSymbolName]])
    }

    // MARK: - Call-graph propagation

    func testCallGraphPropagationResolvesStrippedChangedCallee() throws {
        // The callee lost its symbol AND changed its body, so neither name nor body evidence
        // exists; its single block and no callees make the CFG+callee key uninformative. Only the
        // matched caller's context identifies it. A same-shaped function elsewhere is irrelevant.
        let old = [
            function("o.main", 0x1000, name: "_main", body: "main", cfg: "main-cfg", blocks: 2, edges: 1, callees: ["o.leaf"]),
            function("o.leaf", 0x1100, name: "_leaf", size: 0x20, body: "leaf-v1", cfg: "leaf-shape"),
        ]
        let new = [
            function("n.main", 0x3000, name: "_main", body: "main", cfg: "main-cfg", blocks: 2, edges: 1, callees: ["n.leaf"]),
            function("n.leaf", 0x3100, name: nil, size: 0x20, body: "leaf-v2", cfg: "leaf-shape"),
            function("n.decoy", 0x3200, name: nil, size: 0x20, body: "decoy", cfg: "leaf-shape"),
        ]

        let result = try FunctionVersionMatcher(old: old, new: new).match()

        let leaf = try XCTUnwrap(result.match(forOldID: "o.leaf"))
        XCTAssertEqual(leaf.newID, "n.leaf")
        XCTAssertEqual(leaf.basis, .callGraphPropagation)
        XCTAssertEqual(leaf.confidence, .low)
        XCTAssertEqual(leaf.propagatedFromOldCallerID, "o.main")
        XCTAssertEqual(leaf.propagatedFromNewCallerID, "n.main")
        XCTAssertEqual(leaf.differences, [.body])
        // The caller's callee set compares through the matching, so it is unchanged.
        XCTAssertEqual(result.match(forOldID: "o.main")?.differences, [])
        XCTAssertEqual(result.addedIDs, ["n.decoy"])
        XCTAssertTrue(result.removedIDs.isEmpty)
    }

    func testCallGraphPropagationAbstainsWhenCandidatesAreAmbiguous() throws {
        let old = [
            function("o.main", 0x1000, name: "_main", body: "main", cfg: "main-cfg", callees: ["o.a", "o.b"]),
            function("o.a", 0x1100, body: "a1", cfg: "leaf-shape"),
            function("o.b", 0x1200, body: "b1", cfg: "leaf-shape"),
        ]
        let new = [
            function("n.main", 0x1000, name: "_main", body: "main", cfg: "main-cfg", callees: ["n.a", "n.b"]),
            function("n.a", 0x1100, body: "a2", cfg: "leaf-shape"),
            function("n.b", 0x1200, body: "b2", cfg: "leaf-shape"),
        ]

        let result = try FunctionVersionMatcher(old: old, new: new).match()

        XCTAssertEqual(result.matches.map(\.oldID), ["o.main"])
        XCTAssertEqual(result.match(forOldID: "o.main")?.differences, [],
                       "unresolved callees are unknown, not evidence of a change")
        XCTAssertEqual(result.unresolved, [
            FunctionVersionUnresolvedGroup(oldIDs: ["o.a", "o.b"], newIDs: ["n.a", "n.b"], bases: [.conflictingCallGraphCandidates]),
        ])
    }

    func testCallGraphPropagationRejectsPairAmbiguousInAnotherCallerContext() throws {
        let old = [
            function("o.main", 0x1000, name: "_main", body: "main", cfg: "main-cfg", callees: ["o.a"]),
            function("o.other", 0x1010, name: "_other", body: "other", cfg: "other-cfg", callees: ["o.a"]),
            function("o.a", 0x1100, body: "a", cfg: "leaf-shape"),
        ]
        let new = [
            function("n.main", 0x2000, name: "_main", body: "main", cfg: "main-cfg", callees: ["n.x"]),
            function("n.other", 0x2010, name: "_other", body: "other", cfg: "other-cfg", callees: ["n.x", "n.y"]),
            function("n.x", 0x2100, body: "x", cfg: "leaf-shape"),
            function("n.y", 0x2200, body: "y", cfg: "leaf-shape"),
        ]

        let result = try FunctionVersionMatcher(old: old, new: new).match()

        XCTAssertEqual(result.matches.map(\.oldID), ["o.main", "o.other"])
        XCTAssertNil(result.match(forOldID: "o.a"), "a sole proposal from one caller cannot override an ambiguous caller")
        XCTAssertEqual(result.unresolved, [
            FunctionVersionUnresolvedGroup(oldIDs: ["o.a"], newIDs: ["n.x", "n.y"], bases: [.conflictingCallGraphCandidates]),
        ])
    }

    // MARK: - Manual resolution

    func testManualPinResolvesAmbiguityAndRecomputesDeterministically() throws {
        let old = [
            function("o.d1", 0x1000, body: "dup", cfg: "dup-cfg"),
            function("o.d2", 0x1100, body: "dup", cfg: "dup-cfg"),
        ]
        let new = [
            function("n.d1", 0x2000, body: "dup", cfg: "dup-cfg"),
            function("n.d2", 0x2100, body: "dup", cfg: "dup-cfg"),
        ]
        let matcher = try FunctionVersionMatcher(old: old, new: new)
        let ambiguous = try matcher.match()
        XCTAssertEqual(ambiguous.unresolved.count, 1)

        let resolved = try matcher.resolve(ambiguous, pinning: FunctionVersionManualPin(oldID: "o.d1", newID: "n.d2"))

        let pinned = try XCTUnwrap(resolved.match(forOldID: "o.d1"))
        XCTAssertEqual(pinned.newID, "n.d2")
        XCTAssertEqual(pinned.basis, .manual)
        XCTAssertEqual(pinned.confidence, .userConfirmed)
        // With the pin removing one candidate per side, the remaining pair is unique by body.
        let remaining = try XCTUnwrap(resolved.match(forOldID: "o.d2"))
        XCTAssertEqual(remaining.newID, "n.d1")
        XCTAssertEqual(remaining.basis, .normalizedBody)
        XCTAssertTrue(resolved.unresolved.isEmpty)
        XCTAssertEqual(resolved.manualPins, [FunctionVersionManualPin(oldID: "o.d1", newID: "n.d2")])
        XCTAssertEqual(resolved, try matcher.match(pins: resolved.manualPins))
    }

    func testManualPinIsValidated() throws {
        let old = program(prefix: "o.", shift: 0) + [function("o.lost", 0x1400, body: "lost")]
        let new = program(prefix: "n.", shift: 0) + [function("n.found", 0x1400, body: "found"), function("n.other", 0x1500, body: "other")]
        let matcher = try FunctionVersionMatcher(old: old, new: new)
        let result = try matcher.match()

        XCTAssertThrowsError(try matcher.resolve(result, pinning: FunctionVersionManualPin(oldID: "o.missing", newID: "n.found"))) {
            XCTAssertEqual($0 as? FunctionVersionMatcherError, .unknownOldID("o.missing"))
        }
        XCTAssertThrowsError(try matcher.resolve(result, pinning: FunctionVersionManualPin(oldID: "o.lost", newID: "n.missing"))) {
            XCTAssertEqual($0 as? FunctionVersionMatcherError, .unknownNewID("n.missing"))
        }
        XCTAssertThrowsError(try matcher.resolve(result, pinning: FunctionVersionManualPin(oldID: "o.main", newID: "n.found"))) {
            XCTAssertEqual($0 as? FunctionVersionMatcherError, .oldAlreadyMatched("o.main"))
        }
        XCTAssertThrowsError(try matcher.resolve(result, pinning: FunctionVersionManualPin(oldID: "o.lost", newID: "n.util"))) {
            XCTAssertEqual($0 as? FunctionVersionMatcherError, .newAlreadyMatched("n.util"))
        }
        let first = FunctionVersionManualPin(oldID: "o.lost", newID: "n.found")
        let second = FunctionVersionManualPin(oldID: "o.lost", newID: "n.other")
        XCTAssertThrowsError(try matcher.match(pins: [second, first])) {
            XCTAssertEqual($0 as? FunctionVersionMatcherError, .conflictingPins(first, second))
        }
        XCTAssertThrowsError(try FunctionVersionMatcher(old: old + [function("o.main", 0x9000)], new: new)) {
            XCTAssertEqual($0 as? FunctionVersionMatcherError, .duplicateOldID("o.main"))
        }

        let pinned = try matcher.resolve(result, pinning: first)
        XCTAssertEqual(pinned.match(forOldID: "o.lost")?.newID, "n.found")
        XCTAssertEqual(pinned.match(forOldID: "o.lost")?.differences, [.body])
        XCTAssertEqual(pinned.addedIDs, ["n.other"])
        XCTAssertTrue(pinned.removedIDs.isEmpty)
    }

    // MARK: - Determinism

    func testShuffledInputOrderProducesIdenticalOutput() throws {
        var old = program(prefix: "o.", shift: 0)
        var new = program(prefix: "n.", shift: 0x10)
        old += [
            function("o.d1", 0x2000, body: "dup", cfg: "dup-cfg"),
            function("o.d2", 0x2100, body: "dup", cfg: "dup-cfg"),
            function("o.leaf", 0x2200, body: "leaf-1", cfg: "leaf-shape"),
            function("o.gone", 0x2300, name: "_gone", body: "gone"),
        ]
        old[0] = function("o.main", 0x1000, name: "_main", body: "main-body", cfg: "main-cfg",
                          blocks: 3, edges: 3, callees: ["o.parse", "o.emit", "o.leaf"], imports: ["_exit"])
        new += [
            function("n.d1", 0x3000, body: "dup", cfg: "dup-cfg"),
            function("n.d2", 0x3100, body: "dup", cfg: "dup-cfg"),
            function("n.leaf", 0x3200, body: "leaf-2", cfg: "leaf-shape"),
            function("n.new", 0x3300, name: "_new", body: "new"),
        ]
        new[0] = function("n.main", 0x1010, name: "_main", body: "main-body-2", cfg: "main-cfg",
                          blocks: 3, edges: 3, callees: ["n.parse", "n.emit", "n.leaf"], imports: ["_exit"])
        let pins = [FunctionVersionManualPin(oldID: "o.d2", newID: "n.d1")]
        let reference = try FunctionVersionMatcher(old: old, new: new).match(pins: pins)
        XCTAssertEqual(reference.match(forOldID: "o.leaf")?.basis, .callGraphPropagation)
        XCTAssertEqual(reference.match(forOldID: "o.d1")?.newID, "n.d2")

        var generator = SplitMix64(seed: 0x4D38_5645_5253)
        for _ in 0..<25 {
            let shuffled = try FunctionVersionMatcher(
                old: old.shuffled(using: &generator), new: new.shuffled(using: &generator)).match(pins: pins)
            XCTAssertEqual(shuffled, reference)
        }
    }

    // MARK: - Adapter

    func testAdapterFingerprintsAreAddressIndependentAndMatchAcrossRelocation() throws {
        let old = FunctionVersionFingerprintAdapter.fingerprints(from: analysis(shift: 0, stripHelper: false))
        let new = FunctionVersionFingerprintAdapter.fingerprints(from: analysis(shift: 0x1_0000, stripHelper: true))
        XCTAssertEqual(old.count, 2)
        XCTAssertEqual(new.count, 2)
        let (oldMain, oldHelper) = (old[0], old[1])
        let (newMain, newHelper) = (new[0], new[1])

        XCTAssertEqual(oldHelper.symbolName, "_helper")
        XCTAssertNil(newHelper.symbolName, "generated sub_ names are not symbols")
        XCTAssertEqual(oldHelper.normalizedBodyHash, newHelper.normalizedBodyHash)
        XCTAssertEqual(oldHelper.cfgShapeHash, newHelper.cfgShapeHash)
        XCTAssertEqual(oldHelper.basicBlockCount, 2)
        XCTAssertEqual(oldHelper.edgeCount, 2)
        XCTAssertEqual(oldHelper.instructionCount, 3)
        XCTAssertEqual(oldHelper.stringReferences, ["hello"])
        XCTAssertEqual(oldMain.calleeIDs, [oldHelper.id])
        XCTAssertEqual(oldMain.importedCalleeNames, ["_puts"])
        XCTAssertEqual(oldMain.normalizedBodyHash, newMain.normalizedBodyHash)

        let result = try FunctionVersionMatcher(old: old, new: new).match()
        XCTAssertEqual(result.match(forOldID: oldMain.id)?.basis, .symbolName)
        XCTAssertEqual(result.match(forOldID: oldHelper.id)?.newID, newHelper.id)
        XCTAssertEqual(result.match(forOldID: oldHelper.id)?.basis, .normalizedBody)
        XCTAssertTrue(result.matches.allSatisfy { !$0.isChanged })
    }

    func testOperandMaskingKeepsRegistersAndMasksLiterals() {
        XCTAssertEqual(
            FunctionVersionFingerprinting.normalizedInstruction(mnemonic: "LDR", operands: "x0, [x1, #0x10]"),
            "ldr x0, [x1, #imm]")
        XCTAssertEqual(
            FunctionVersionFingerprinting.normalizedInstruction(mnemonic: "bl", operands: "sub_100003f00"),
            "bl label")
        XCTAssertEqual(
            FunctionVersionFingerprinting.normalizedInstruction(mnemonic: "add", operands: "v3.4s, v1.4s, v2.4s"),
            "add v3.4s, v1.4s, v2.4s")
        XCTAssertEqual(
            FunctionVersionFingerprinting.normalizedInstruction(mnemonic: "adrp", operands: "x8, 0x100004000"),
            FunctionVersionFingerprinting.normalizedInstruction(mnemonic: "adrp", operands: "x8, 0x200004000"))
        XCTAssertEqual(
            FunctionVersionFingerprinting.semanticInstruction(mnemonic: "adrp", operands: "x8, 0x100004000"),
            FunctionVersionFingerprinting.semanticInstruction(mnemonic: "adrp", operands: "x8, 0x200004000"),
            "relocated absolute addresses should not become semantic code changes")
        for mnemonic in ["b.ne", "b.lo", "bc.eq"] {
            XCTAssertEqual(
                FunctionVersionFingerprinting.semanticInstruction(mnemonic: mnemonic, operands: "0x1000003d8"),
                FunctionVersionFingerprinting.semanticInstruction(mnemonic: mnemonic, operands: "0x100000434"),
                "\(mnemonic): a relocated conditional-branch target is not a code change")
        }
        XCTAssertNotEqual(
            FunctionVersionFingerprinting.normalizedInstruction(mnemonic: "mov", operands: "x0, x1"),
            FunctionVersionFingerprinting.normalizedInstruction(mnemonic: "mov", operands: "x0, x2"))
    }

    func testPointerAuthLRLabelRelocationIsNotASemanticChange() {
        for mnemonic in ["autiasppc", "autibsppc", "retaasppc", "retabsppc"] {
            XCTAssertEqual(
                FunctionVersionFingerprinting.semanticInstruction(mnemonic: mnemonic, operands: "0x100003ff8"),
                FunctionVersionFingerprinting.semanticInstruction(mnemonic: mnemonic, operands: "0x200003ff8"),
                "\(mnemonic): a relocated signing-site label is not a code change")
        }
        XCTAssertNotEqual(
            FunctionVersionFingerprinting.semanticInstruction(mnemonic: "autiasppcr", operands: "x1"),
            FunctionVersionFingerprinting.semanticInstruction(mnemonic: "autiasppcr", operands: "x2"))
    }

    private func analysis(shift: UInt64, stripHelper: Bool) -> ImageAnalysis {
        let main = UUID()
        let helper = UUID()
        func hex(_ value: UInt64) -> String { "0x" + String(value + shift, radix: 16) }
        func row(_ address: UInt64, _ mnemonic: String, _ operands: String) -> InstructionRow {
            InstructionRow(address: address + shift, bytes: "00 00 00 00", mnemonic: mnemonic,
                           operands: operands, hasBreakpoint: false, comment: nil)
        }
        var analysis = ImageAnalysis()
        analysis.functions = [
            FunctionSummary(id: helper, name: stripHelper ? "sub_\(String(0x1020 + shift, radix: 16))" : "_helper",
                            startAddress: 0x1020 + shift, endAddress: 0x102C + shift, confidence: 1),
            FunctionSummary(id: main, name: "_main", startAddress: 0x1000 + shift, endAddress: 0x1010 + shift, confidence: 1),
        ]
        analysis.instructions = [
            row(0x1028, "ret", ""),
            row(0x1000, "stp", "x29, x30, [sp, #-0x10]!"),
            row(0x1004, "bl", hex(0x1020)),
            row(0x1008, "bl", hex(0x3000)),
            row(0x100C, "ret", ""),
            row(0x1020, "adrp", "x0, \(hex(0x4000))"),
            row(0x1024, "cbz", "x0, \(hex(0x1028))"),
        ]
        analysis.basicBlocks = [
            BasicBlockSummary(id: UUID(), functionID: main, startAddress: 0x1000 + shift, endAddress: 0x1010 + shift, instructionCount: 4),
            BasicBlockSummary(id: UUID(), functionID: helper, startAddress: 0x1020 + shift, endAddress: 0x1028 + shift, instructionCount: 2),
            BasicBlockSummary(id: UUID(), functionID: helper, startAddress: 0x1028 + shift, endAddress: 0x102C + shift, instructionCount: 1),
        ]
        analysis.controlFlowEdges = [
            ControlFlowEdge(id: UUID(), from: 0x1004 + shift, to: 0x1020 + shift, kind: "call"),
            ControlFlowEdge(id: UUID(), from: 0x1024 + shift, to: 0x1028 + shift, kind: "branch"),
            ControlFlowEdge(id: UUID(), from: 0x1024 + shift, to: 0x1028 + shift, kind: "fallthrough"),
        ]
        analysis.xrefs = [
            XRef(id: UUID(), from: 0x1004 + shift, to: 0x1020 + shift, kind: XRefKind.call),
            XRef(id: UUID(), from: 0x1008 + shift, to: 0x3000 + shift, kind: XRefKind.call),
            XRef(id: UUID(), from: 0x1020 + shift, to: 0x4000 + shift, kind: XRefKind.string),
        ]
        analysis.symbols = [
            SymbolSummary(id: UUID(), name: "_puts", address: 0x3000 + shift, kind: "stub", libraryName: nil),
        ]
        analysis.stringLiterals = [
            StringLiteralSummary(id: UUID(), value: "hello", address: 0x4000 + shift, sourceSection: "__cstring", byteLength: 6),
        ]
        return analysis
    }
}

/// Seeded generator so shuffles are reproducible across runs.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
