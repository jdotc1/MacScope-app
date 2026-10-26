import XCTest
@testable import MacScope

final class NativeValueNavigationTests: XCTestCase {
    func testAdmittedNativeVimPhiRetainsIncomingLabels() throws {
        // Reuse one retained provider result and its recorded admission status.
        let url = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/NativeDecompilerWireCP4.json")
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        let fixture = try XCTUnwrap(objects.first { $0["name"] as? String == "vim_10000200c" })
        XCTAssertEqual(fixture["accepted"] as? Bool, true)
        XCTAssertEqual(fixture["cppError"] as? String, "")
        let resultObject = try XCTUnwrap(fixture["result"])
        let result = try JSONDecoder().decode(
            NativeDecompilerWireStructuredResult.self,
            from: JSONSerialization.data(withJSONObject: resultObject)
        )
        XCTAssertEqual(result.phis.count, 1)
        let phi = try XCTUnwrap(result.phis.first)
        let report = try NativeValueNavigationIndex(result: result)
            .query(seedValueID: phi.outputSSAValueID, direction: .definitions)
        let incoming = report.rows.filter { $0.site == .phi(phi.id) }
        XCTAssertEqual(incoming.count, 4)
        XCTAssertEqual(incoming.map(\.relatedValueID), phi.incoming.map { Optional($0.ssaValueID) })
        XCTAssertEqual(incoming.map(\.predecessorBlockID), phi.incoming.map(\.sourceBlockID))
        XCTAssertEqual(incoming.map(\.incomingEdgeID), phi.incoming.map(\.edgeID))
        XCTAssertTrue(report.limitsReached.isEmpty)
    }

    func testDefinitionsKeepBothPhiPredecessorsAndVisitValuesOnce() throws {
        let index = try NativeValueNavigationIndex(result: NativeValueNavigationFixture().result)
        let report = try index.query(seedValueID: "v.sum", direction: .definitions)
        let incoming = report.rows.filter { $0.site == .phi("phi.join") }
        XCTAssertEqual(incoming.map(\.relatedValueID), ["v.left", "v.right"])
        XCTAssertEqual(incoming.map(\.predecessorBlockID), ["block.left", "block.right"])
        XCTAssertEqual(incoming.map(\.incomingEdgeID), ["edge.left", "edge.right"])
        XCTAssertEqual(Set(report.visitedValueIDs).count, report.visitedValueIDs.count)
        XCTAssertTrue(report.visitedValueIDs.contains("v.entry"))
        XCTAssertTrue(report.boundaries.contains { $0.kind == .functionEntry })
        XCTAssertTrue(report.boundaries.contains { $0.kind == .constant })
        XCTAssertFalse(report.isBudgetLimited)
    }

    func testUsesDoNotDoubleCountMultiequalOrCrossCallAndStore() throws {
        let index = try NativeValueNavigationIndex(result: NativeValueNavigationFixture().result)
        let report = try index.query(seedValueID: "v.left", direction: .uses)
        XCTAssertEqual(report.rows.filter { $0.site == .phi("phi.join") && $0.valueID == "v.left" }.count, 1)
        XCTAssertFalse(report.rows.contains { $0.site == .operation("op.phi") })
        XCTAssertTrue(report.rows.contains { $0.site == .operation("op.call") })
        XCTAssertTrue(report.rows.contains { $0.site == .operation("op.store") })
        XCTAssertTrue(report.rows.contains { $0.site == .operation("op.return") })
        XCTAssertFalse(report.visitedValueIDs.contains("v.called"), "A use at a call does not prove dependence of the return value.")
        XCTAssertTrue(report.boundaries.contains { $0.kind == .call })
        XCTAssertTrue(report.boundaries.contains { $0.kind == .memory })
    }

    func testLoadedAndCallReturnedValuesDoNotAcquireInventedDefinitions() throws {
        let index = try NativeValueNavigationIndex(result: NativeValueNavigationFixture().result)
        let loaded = try index.query(seedValueID: "v.loaded", direction: .definitions)
        XCTAssertEqual(loaded.visitedValueIDs, ["v.loaded"])
        XCTAssertEqual(loaded.rows.map(\.site), [.operation("op.load")])
        XCTAssertTrue(loaded.boundaries.contains { $0.kind == .memory })
        let called = try index.query(seedValueID: "v.called", direction: .definitions)
        XCTAssertEqual(called.visitedValueIDs, ["v.called"])
        XCTAssertTrue(called.boundaries.contains { $0.kind == .call })
    }

    func testAuthenticationEffectStopsAnOtherwiseTraversableOperation() throws {
        var fixture = NativeValueNavigationFixture()
        let offset = try XCTUnwrap(fixture.operations.firstIndex { $0.id == "op.sum" })
        fixture.operations[offset].authenticationEffect = .init(
            kind: .transformedOutput, outputSSAValueID: "v.sum"
        )
        let report = try NativeValueNavigationIndex(result: fixture.result)
            .query(seedValueID: "v.sum", direction: .definitions)
        XCTAssertEqual(report.visitedValueIDs, ["v.sum"])
        XCTAssertEqual(report.boundaries.map(\.kind), [.authentication])
    }

    func testValueTokenContextSelectsRecordedInputWithoutGuessingByName() throws {
        let index = try NativeValueNavigationIndex(result: NativeValueNavigationFixture().result)
        let candidates = try index.candidates(forTokenID: "token.merged")
        XCTAssertEqual(candidates.candidates.map(\.id), ["v.merged"])
        XCTAssertFalse(candidates.requiresChoice)
        let ambiguous = try index.candidates(forTokenID: "token.shared")
        XCTAssertEqual(ambiguous.candidates.map(\.id), ["v.left", "v.right"])
        XCTAssertTrue(ambiguous.requiresChoice)
        XCTAssertTrue(ambiguous.usesStorageAssociationOnly)
    }

    func testSourceOverlapAloneDoesNotSelectAValue() throws {
        var fixture = NativeValueNavigationFixture()
        fixture.tokens = [fixture.token("source.only", "merged", 1, 0x101c, [])]
        let selection = try NativeValueNavigationIndex(result: fixture.result)
            .candidates(forTokenID: "source.only")
        XCTAssertTrue(selection.candidates.isEmpty)
    }

    func testCandidateLimitNeverMakesAnAmbiguousSelectionLookUnique() throws {
        var limits = NativeValueNavigationLimits()
        limits.maximumCandidates = 1
        let selection = try NativeValueNavigationIndex(
            result: NativeValueNavigationFixture().result, limits: limits
        ).candidates(forTokenID: "token.shared")
        XCTAssertEqual(selection.candidates.count, 1)
        XCTAssertTrue(selection.requiresChoice)
        XCTAssertTrue(selection.limitsReached.contains(.candidateCount))
    }

    func testRowsDepthAndValueLimitsAreVisible() throws {
        let result = NativeValueNavigationFixture().result
        var limits = NativeValueNavigationLimits()
        limits.maximumRows = 1
        var report = try NativeValueNavigationIndex(result: result, limits: limits)
            .query(seedValueID: "v.sum", direction: .definitions)
        XCTAssertEqual(report.rows.count, 1)
        XCTAssertTrue(report.limitsReached.contains(.rows))

        limits = .init()
        limits.maximumDepth = 0
        report = try NativeValueNavigationIndex(result: result, limits: limits)
            .query(seedValueID: "v.sum", direction: .definitions)
        XCTAssertEqual(report.visitedValueIDs, ["v.sum"])
        XCTAssertTrue(report.limitsReached.contains(.depth))

        limits = .init()
        limits.maximumVisitedValues = 1
        report = try NativeValueNavigationIndex(result: result, limits: limits)
            .query(seedValueID: "v.sum", direction: .definitions)
        XCTAssertEqual(report.visitedValueIDs, ["v.sum"])
        XCTAssertTrue(report.limitsReached.contains(.visitedValues))
    }

    func testLoopCarriedPhiTerminatesAndPreservesItsBackedge() throws {
        var fixture = NativeValueNavigationFixture()
        fixture.phis = [.init(
            id: "phi.join", blockID: "block.join", varnodeID: "vn.merged",
            outputSSAValueID: "v.merged", incoming: [
                .init(sourceBlockID: "block.left", edgeID: "edge.left", ssaValueID: "v.left"),
                // Query-level cycle fixture: source/edge still identify the alternative;
                // this fixture is not claimed to pass the complete native CFG validator.
                .init(sourceBlockID: "block.right", edgeID: "edge.right", ssaValueID: "v.merged")
            ]
        )]
        let operationIndex = try XCTUnwrap(fixture.operations.firstIndex { $0.id == "op.phi" })
        fixture.operations[operationIndex] = fixture.operation(
            "op.phi", .multiequal, 3, ["vn.shared", "vn.merged"], "vn.merged", "block.join", 0x1018
        )
        let bindingIndex = try XCTUnwrap(fixture.bindings.firstIndex { $0.operationID == "op.phi" })
        fixture.bindings[bindingIndex] = .init(
            operationID: "op.phi", inputSSAValueIDs: ["v.left", "v.merged"], outputSSAValueID: "v.merged"
        )
        let report = try NativeValueNavigationIndex(result: fixture.result)
            .query(seedValueID: "v.merged", direction: .definitions)
        XCTAssertEqual(Set(report.visitedValueIDs).count, report.visitedValueIDs.count)
        XCTAssertTrue(report.rows.contains { $0.relatedValueID == "v.merged" && $0.incomingEdgeID == "edge.right" })
        XCTAssertLessThanOrEqual(report.visitedValueIDs.count, 3)
    }

    func testDuplicateAndDanglingRecordsFailWithoutDictionaryTrap() {
        var fixture = NativeValueNavigationFixture()
        fixture.values.append(fixture.values[0])
        XCTAssertThrowsError(try NativeValueNavigationIndex(result: fixture.result)) { error in
            XCTAssertEqual(error as? NativeValueNavigationFailure, .duplicateRecord("SSA value", "v.entry"))
        }
        fixture = .init()
        fixture.bindings[0] = .init(
            operationID: "op.left", inputSSAValueIDs: ["v.missing"], outputSSAValueID: "v.left"
        )
        XCTAssertThrowsError(try NativeValueNavigationIndex(result: fixture.result))
    }

    func testCancellationIsNotPublishedAsAnEmptySuccessfulQuery() throws {
        let result = NativeValueNavigationFixture().result
        XCTAssertThrowsError(try NativeValueNavigationIndex(result: result, isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
        let index = try NativeValueNavigationIndex(result: result)
        XCTAssertThrowsError(try index.query(seedValueID: "v.sum", direction: .definitions, isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testDisjointFunctionCodeRangesRejectNavigationAcrossAHole() {
        let function = NativeDecompilerWireFunctionIdentity(
            functionID: "split", name: "split", entryAddress: .init(0x1000),
            endAddressExclusive: .init(0x1040), codeRanges: [
                .init(startAddress: .init(0x1000), endAddressExclusive: .init(0x1010)),
                .init(startAddress: .init(0x1030), endAddressExclusive: .init(0x1040))
            ]
        )
        let hole = NativeDecompilerWireSourceRange(
            imageID: "image", startAddress: .init(0x1018), endAddressExclusive: .init(0x101c)
        )
        XCTAssertFalse(NativeValueNavigationIndex.admits(range: hole, imageID: "image", function: function))
        let valid = NativeDecompilerWireSourceRange(
            imageID: "image", startAddress: .init(0x1034), endAddressExclusive: .init(0x1038)
        )
        XCTAssertTrue(NativeValueNavigationIndex.admits(range: valid, imageID: "image", function: function))
        XCTAssertFalse(NativeValueNavigationIndex.admits(range: valid, imageID: "other-image", function: function))
    }

    func testAdjacentExactFunctionExtentsAdmitContinuouslyCoveredSourceRange() {
        let function = NativeDecompilerWireFunctionIdentity(
            functionID: "adjacent", name: "adjacent", entryAddress: .init(0x1000),
            endAddressExclusive: .init(0x1020), codeRanges: [
                .init(startAddress: .init(0x1000), endAddressExclusive: .init(0x1010)),
                .init(startAddress: .init(0x1010), endAddressExclusive: .init(0x1020))
            ]
        )
        let range = NativeDecompilerWireSourceRange(
            imageID: "image", startAddress: .init(0x100c), endAddressExclusive: .init(0x1014)
        )
        XCTAssertTrue(NativeValueNavigationIndex.admits(range: range, imageID: "image", function: function))
    }
}
