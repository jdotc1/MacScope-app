import XCTest
@testable import MacScope

final class DebuggerVariableInspectionModelTests: XCTestCase {
    func testVariableInspectionValuesAreSendableAndHashable() {
        Self.assertSendableAndHashable(DebuggerVariablePathToken.self)
        Self.assertSendableAndHashable(DebuggerVariableScopeRequest.self)
        Self.assertSendableAndHashable(DebuggerVariableExpansionRequest.self)
        Self.assertSendableAndHashable(DebuggerVariableNode.self)
        Self.assertSendableAndHashable(DebuggerVariableChildExpansionState.self)
        Self.assertSendableAndHashable(DebuggerVariableSnapshot.self)
        Self.assertSendableAndHashable(DebuggerWatchExpressionRequest.self)
        Self.assertSendableAndHashable(DebuggerWatchExpressionResult.self)
    }

    func testVariablePathTokenIsCoordinateAndComponentScoped() throws {
        let fixture = try Self.fixture()
        let token = try XCTUnwrap(DebuggerVariablePathToken(
            coordinate: fixture.coordinate,
            components: ["locals", "object", "field"]
        ))
        let same = try XCTUnwrap(DebuggerVariablePathToken(
            coordinate: fixture.coordinate,
            components: ["locals", "object", "field"]
        ))
        let differentPath = try XCTUnwrap(DebuggerVariablePathToken(
            coordinate: fixture.coordinate,
            components: ["locals", "object", "other"]
        ))
        let otherFixture = try Self.fixture(stopRevision: 2)
        let differentStop = try XCTUnwrap(DebuggerVariablePathToken(
            coordinate: otherFixture.coordinate,
            components: ["locals", "object", "field"]
        ))

        XCTAssertEqual(token, same)
        XCTAssertNotEqual(token, differentPath)
        XCTAssertNotEqual(token, differentStop)
        XCTAssertEqual(token.lowercaseHex.utf8.count, 64)
    }

    func testVariablePathTokenRejectsEmptyControlAndOversizedComponents() throws {
        let coordinate = try Self.fixture().coordinate

        XCTAssertNil(DebuggerVariablePathToken(coordinate: coordinate, components: []))
        XCTAssertNil(DebuggerVariablePathToken(coordinate: coordinate, components: ["local\nname"]))
        XCTAssertNil(DebuggerVariablePathToken(
            coordinate: coordinate,
            components: [String(repeating: "x", count: DebuggerVariablePathToken.maximumComponentUTF8Bytes + 1)]
        ))
        XCTAssertNil(DebuggerVariablePathToken(
            coordinate: coordinate,
            components: Array(repeating: "x", count: DebuggerVariablePathToken.maximumComponentCount + 1)
        ))
    }

    func testVariableNodeAndSnapshotEnforceBounds() throws {
        let fixture = try Self.fixture()
        let token = try Self.token(fixture.coordinate, "locals", "argc")
        let node = try XCTUnwrap(DebuggerVariableNode(
            id: token,
            name: "argc",
            typeName: "Int32",
            value: .value("1"),
            childCount: 0
        ))

        XCTAssertFalse(node.isExpandable)
        XCTAssertEqual(node.pathComponents, ["argc"])
        XCTAssertNotNil(DebuggerVariableSnapshot(
            coordinate: fixture.coordinate,
            scope: .arguments,
            nodes: [node],
            depth: 0,
            wasTruncated: false
        ))
        XCTAssertNil(DebuggerVariableNode(
            id: token,
            name: "bad\nname",
            value: .value("1"),
            childCount: 0
        ))
        XCTAssertNil(DebuggerVariableNode(
            id: token,
            name: "argc",
            value: .value("1"),
            childCount: 0,
            pathComponents: ["locals", "bad\ncomponent"]
        ))
        XCTAssertNil(DebuggerVariableNode(
            id: token,
            name: "argc",
            value: .value("1"),
            childCount: 0,
            pathComponents: Array(repeating: "x", count: DebuggerVariablePathToken.maximumComponentCount + 1)
        ))
        XCTAssertNil(DebuggerVariableSnapshot(
            coordinate: fixture.coordinate,
            scope: .locals,
            nodes: Array(repeating: node, count: DebuggerVariableSnapshot.maximumNodeCount + 1),
            depth: 0,
            wasTruncated: true
        ))
        XCTAssertNil(DebuggerVariableSnapshot(
            coordinate: fixture.coordinate,
            scope: .locals,
            nodes: [node],
            depth: DebuggerVariableSnapshot.maximumDepth + 1,
            wasTruncated: false
        ))
    }

    func testExpandableVariableRetainsBoundedExpansionPathComponents() throws {
        let fixture = try Self.fixture()
        let components = ["locals", "0", "aggregate"]
        let token = try XCTUnwrap(DebuggerVariablePathToken(
            coordinate: fixture.coordinate,
            components: components
        ))
        let node = try XCTUnwrap(DebuggerVariableNode(
            id: token,
            name: "aggregate",
            typeName: "Pair",
            value: .value("{...}"),
            childCount: 2,
            pathComponents: components
        ))

        XCTAssertTrue(node.isExpandable)
        XCTAssertEqual(node.pathComponents, components)
        XCTAssertEqual(node.childExpansion, .notLoaded)
        XCTAssertTrue(node.children.isEmpty)
    }

    func testVariableNodeRetainsLoadedChildrenUnderParentPath() throws {
        let fixture = try Self.fixture()
        let parentComponents = ["locals", "0", "aggregate"]
        let childComponents = parentComponents + ["left"]
        let parentToken = try XCTUnwrap(DebuggerVariablePathToken(
            coordinate: fixture.coordinate,
            components: parentComponents
        ))
        let childToken = try XCTUnwrap(DebuggerVariablePathToken(
            coordinate: fixture.coordinate,
            components: childComponents
        ))
        let child = try XCTUnwrap(DebuggerVariableNode(
            id: childToken,
            name: "left",
            typeName: "Int",
            value: .value("1"),
            childCount: 0,
            pathComponents: childComponents
        ))
        let parent = try XCTUnwrap(DebuggerVariableNode(
            id: parentToken,
            name: "aggregate",
            typeName: "Pair",
            value: .value("{...}"),
            childCount: 1,
            pathComponents: parentComponents,
            children: [child]
        ))

        XCTAssertEqual(parent.childExpansion, .loaded)
        XCTAssertEqual(parent.children, [child])
        XCTAssertNil(DebuggerVariableNode(
            id: parentToken,
            name: "aggregate",
            typeName: "Pair",
            value: .value("{...}"),
            childCount: 1,
            pathComponents: parentComponents,
            children: [
                try XCTUnwrap(DebuggerVariableNode(
                    id: childToken,
                    name: "wrong",
                    value: .value("1"),
                    childCount: 0,
                    pathComponents: ["statics", "wrong"]
                )),
            ]
        ))
    }

    func testVariableNodeExpansionStateMustMatchLoadedChildren() throws {
        let fixture = try Self.fixture()
        let token = try Self.token(fixture.coordinate, "locals", "aggregate")

        XCTAssertNotNil(DebuggerVariableNode(
            id: token,
            name: "aggregate",
            value: .value("{...}"),
            childCount: 2,
            childExpansion: .loading
        ))
        XCTAssertNil(DebuggerVariableNode(
            id: token,
            name: "aggregate",
            value: .value("{...}"),
            childCount: 0,
            childExpansion: .loading
        ))
        XCTAssertNil(DebuggerVariableNode(
            id: token,
            name: "aggregate",
            value: .value("{...}"),
            childCount: 2,
            childExpansion: .failed(reason: "bad\nreason")
        ))
    }

    func testVariableSnapshotReplacesChildrenForExactExpansionRequest() throws {
        let fixture = try Self.fixture()
        let parentComponents = ["locals", "0", "aggregate"]
        let childComponents = parentComponents + ["0", "left"]
        let parentToken = try XCTUnwrap(DebuggerVariablePathToken(
            coordinate: fixture.coordinate,
            components: parentComponents
        ))
        let childToken = try XCTUnwrap(DebuggerVariablePathToken(
            coordinate: fixture.coordinate,
            components: childComponents
        ))
        let parent = try XCTUnwrap(DebuggerVariableNode(
            id: parentToken,
            name: "aggregate",
            typeName: "Pair",
            value: .value("{...}"),
            childCount: 1,
            pathComponents: parentComponents
        ))
        let child = try XCTUnwrap(DebuggerVariableNode(
            id: childToken,
            name: "left",
            typeName: "Int",
            value: .value("1"),
            childCount: 0,
            pathComponents: childComponents
        ))
        let request = try XCTUnwrap(DebuggerVariableExpansionRequest(
            coordinate: fixture.coordinate,
            token: parentToken,
            pathComponents: parentComponents,
            depth: 1
        ))
        let snapshot = try XCTUnwrap(DebuggerVariableSnapshot(
            coordinate: fixture.coordinate,
            scope: .locals,
            nodes: [parent],
            depth: 0,
            wasTruncated: false
        ))
        let replaced = try XCTUnwrap(snapshot.replacingChildren(
            matching: request,
            with: [child],
            wasTruncated: true
        ))

        XCTAssertEqual(replaced.nodes[0].children, [child])
        XCTAssertEqual(replaced.nodes[0].childExpansion, .loaded)
        XCTAssertTrue(replaced.wasTruncated)
        let wrongScopeComponents = ["arguments", "0", "aggregate"]
        let wrongScopeToken = try XCTUnwrap(DebuggerVariablePathToken(
            coordinate: fixture.coordinate,
            components: wrongScopeComponents
        ))
        XCTAssertNil(snapshot.replacingChildren(
            matching: try XCTUnwrap(DebuggerVariableExpansionRequest(
                coordinate: fixture.coordinate,
                token: wrongScopeToken,
                pathComponents: wrongScopeComponents,
                depth: 1
            )),
            with: [child],
            wasTruncated: false
        ))
    }

    func testExpansionRequestCarriesOpaqueTokenAndRejectsInvalidDepth() throws {
        let fixture = try Self.fixture()
        let components = ["locals", "0", "object"]
        let token = try XCTUnwrap(DebuggerVariablePathToken(
            coordinate: fixture.coordinate,
            components: components
        ))

        XCTAssertNotNil(DebuggerVariableExpansionRequest(
            coordinate: fixture.coordinate,
            token: token,
            pathComponents: components,
            depth: 1
        ))
        XCTAssertNil(DebuggerVariableExpansionRequest(
            coordinate: fixture.coordinate,
            token: token,
            pathComponents: ["locals", "0", "other"],
            depth: 1
        ))
        XCTAssertNil(DebuggerVariableExpansionRequest(
            coordinate: fixture.coordinate,
            token: token,
            pathComponents: components,
            depth: 2
        ))
        let malformedComponents = ["locals", "object"]
        let malformedToken = try XCTUnwrap(DebuggerVariablePathToken(
            coordinate: fixture.coordinate,
            components: malformedComponents
        ))
        XCTAssertNil(DebuggerVariableExpansionRequest(
            coordinate: fixture.coordinate,
            token: malformedToken,
            pathComponents: malformedComponents,
            depth: 1
        ))
        XCTAssertNil(DebuggerVariableExpansionRequest(
            coordinate: fixture.coordinate,
            token: token,
            pathComponents: components,
            depth: DebuggerVariableSnapshot.maximumDepth + 1
        ))
    }

    func testVariableSnapshotTransitionsOnlyExactNodeForLoadingFailureAndRetry() throws {
        let fixture = try Self.fixture()
        let components = ["locals", "0", "object"]
        let token = try XCTUnwrap(DebuggerVariablePathToken(
            coordinate: fixture.coordinate,
            components: components
        ))
        let node = try XCTUnwrap(DebuggerVariableNode(
            id: token,
            name: "object",
            value: .value("{...}"),
            childCount: 1,
            pathComponents: components
        ))
        let snapshot = try XCTUnwrap(DebuggerVariableSnapshot(
            coordinate: fixture.coordinate,
            scope: .locals,
            nodes: [node],
            depth: 0,
            wasTruncated: false
        ))
        let request = try XCTUnwrap(DebuggerVariableExpansionRequest(
            coordinate: fixture.coordinate,
            token: token,
            pathComponents: components,
            depth: 1
        ))

        let loading = try XCTUnwrap(snapshot.transitioningChildren(
            matching: request,
            to: .loading
        ))
        XCTAssertEqual(loading.nodes[0].childExpansion, .loading)
        let failed = try XCTUnwrap(loading.transitioningChildren(
            matching: request,
            to: .failed(reason: "LLDB child read failed.")
        ))
        XCTAssertEqual(failed.nodes[0].childExpansion, .failed(reason: "LLDB child read failed."))
        let retrying = try XCTUnwrap(failed.transitioningChildren(
            matching: request,
            to: .loading
        ))
        XCTAssertEqual(retrying.nodes[0].childExpansion, .loading)
    }

    func testWatchExpressionRequestTrimsAndRejectsUnsafeInputs() throws {
        let coordinate = try Self.fixture().coordinate
        let request = try XCTUnwrap(DebuggerWatchExpressionRequest(
            coordinate: coordinate,
            expression: "  argc + 1  "
        ))

        XCTAssertEqual(request.expression, "argc + 1")
        XCTAssertNil(DebuggerWatchExpressionRequest(coordinate: coordinate, expression: "   "))
        XCTAssertNil(DebuggerWatchExpressionRequest(coordinate: coordinate, expression: "argc\nprocess kill"))
        XCTAssertNil(DebuggerWatchExpressionRequest(
            coordinate: coordinate,
            expression: String(repeating: "x", count: DebuggerWatchExpressionRequest.maximumExpressionUTF8Bytes + 1)
        ))
    }

    func testVariableSnapshotAndWatchResultUseInspectionFreshnessPolicy() throws {
        let fixture = try Self.fixture()
        let token = try Self.token(fixture.coordinate, "locals", "argc")
        let node = try XCTUnwrap(DebuggerVariableNode(
            id: token,
            name: "argc",
            value: .value("1"),
            childCount: 0
        ))
        let snapshot = try XCTUnwrap(DebuggerVariableSnapshot(
            coordinate: fixture.coordinate,
            scope: .locals,
            nodes: [node],
            depth: 0,
            wasTruncated: false
        ))
        let request = try XCTUnwrap(DebuggerWatchExpressionRequest(
            coordinate: fixture.coordinate,
            expression: "argc + 1"
        ))
        let result = try XCTUnwrap(DebuggerWatchExpressionResult(
            request: request,
            value: .value("2")
        ))

        XCTAssertEqual(
            snapshot.freshness(
                currentStop: fixture.stop,
                currentAuthority: fixture.authority,
                currentThread: fixture.thread,
                currentFrame: fixture.frame,
                processState: .paused(processID: 123, reason: .breakpoint(address: Self.stoppedAddress))
            ),
            .fresh(fixture.coordinate)
        )
        XCTAssertEqual(
            result.freshness(
                currentStop: Self.stop(stopRevision: 2),
                currentAuthority: fixture.authority,
                currentThread: fixture.thread,
                currentFrame: fixture.frame,
                processState: .paused(processID: 123, reason: .breakpoint(address: Self.stoppedAddress))
            ),
            .stale(reason: .stopChanged)
        )
    }

    private struct Fixture {
        let stop: DebuggerStopCoordinate
        let authority: DebuggerSessionTargetAuthority
        let thread: DebuggerThreadIdentity
        let frame: DebuggerFrameIdentity
        let coordinate: DebuggerInspectionCoordinate
    }

    private static let stoppedAddress: UInt64 = 0x1_0000_1000

    private static func fixture(stopRevision: UInt64 = 1) throws -> Fixture {
        let stop = Self.stop(stopRevision: stopRevision)
        let authority = try Self.authority(processID: 123)
        let thread = try XCTUnwrap(DebuggerThreadIdentity(index: 1, tid: 0xabc))
        let frame = try XCTUnwrap(DebuggerFrameIdentity(
            thread: thread,
            frameIndex: 0,
            programCounter: Self.stoppedAddress,
            canonicalFunctionName: "main"
        ))
        let coordinate = try XCTUnwrap(DebuggerInspectionCoordinate(
            stop: stop,
            targetAuthority: authority,
            thread: thread,
            frame: frame
        ))
        return Fixture(
            stop: stop,
            authority: authority,
            thread: thread,
            frame: frame,
            coordinate: coordinate
        )
    }

    private static func token(
        _ coordinate: DebuggerInspectionCoordinate,
        _ components: String...
    ) throws -> DebuggerVariablePathToken {
        try XCTUnwrap(DebuggerVariablePathToken(
            coordinate: coordinate,
            components: components
        ))
    }

    private static func stop(stopRevision: UInt64 = 1) -> DebuggerStopCoordinate {
        let epoch = DebuggerSessionEpoch(
            rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
        let session = DebuggerSessionCoordinate(
            epoch: epoch,
            lifecycleRevision: DebuggerLifecycleRevision(rawValue: 3)
        )
        return DebuggerStopCoordinate(
            session: session,
            stopRevision: DebuggerStopRevision(rawValue: stopRevision)
        )
    }

    private static func authority(
        processID: Int32,
        executableSHA256: String = String(repeating: "a", count: 64)
    ) throws -> DebuggerSessionTargetAuthority {
        try DebuggerSessionTargetAuthority(origin: .attached(identity(
            processID: processID,
            executableSHA256: executableSHA256
        )))
    }

    private static func identity(
        processID: Int32,
        executableSHA256: String = String(repeating: "a", count: 64)
    ) throws -> DebuggerLocalProcessIdentity {
        let start = try XCTUnwrap(DebuggerProcessStartIdentity(seconds: 1_700_000_000, microseconds: 42))
        return try XCTUnwrap(DebuggerLocalProcessIdentity(
            processID: processID,
            startTime: start,
            realUserID: 501,
            effectiveUserID: 501,
            canonicalExecutablePath: "/Applications/Fixture.app/Contents/MacOS/Fixture",
            executableDeviceID: 10,
            executableFileID: UInt64(processID) + 1_000,
            executableByteCount: 4096,
            executableSHA256: executableSHA256,
            architecture: .arm64,
            machOUUID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
            codeIdentity: nil
        ))
    }

    private static func assertSendableAndHashable<T: Sendable & Hashable>(_ type: T.Type) {}
}
