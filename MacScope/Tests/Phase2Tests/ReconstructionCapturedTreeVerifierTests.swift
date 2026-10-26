import XCTest
@testable import MacScope

final class ReconstructionCapturedTreeVerifierTests: XCTestCase {
    typealias Verifier = ReconstructionCapturedTreeVerifier

    func testExactExpandedPathAndComponentLimitsAreAccepted() throws {
        let capture = try Verifier.Capture(
            limits: .init(
                maximumExpandedPathUTF8Bytes: 5,
                maximumExpandedComponentWork: 3
            )
        )
        let cancellation = ReconstructionCancellation()

        let directory = try capture.append(
            parentIndex: 0,
            rawComponent: "a",
            normalizedComponent: "a",
            kind: .directory,
            cancellation: cancellation
        )
        let leaf = try capture.append(
            parentIndex: directory,
            rawComponent: "bc",
            normalizedComponent: "bc",
            kind: .regularFile,
            cancellation: cancellation
        )

        let plan = try capture.makeVerificationPlan(cancellation: cancellation)

        XCTAssertEqual(try capture.materializeNormalizedRelativePath(
            to: leaf,
            cancellation: cancellation
        ), "a/bc")
        XCTAssertEqual(plan.expandedPathUTF8ByteCount, 5)
        XCTAssertEqual(plan.expandedComponentWork, 3)
    }

    func testSelectedRootIdentityPrefixAndEveryAdmittedNodeChargeAttemptedWork() throws {
        var attemptedWork: [(pathBytes: Int, componentWork: Int)] = []
        let capture = try Verifier.Capture(
            limits: .init(
                maximumExpandedPathUTF8Bytes: 10,
                maximumExpandedComponentWork: 6
            ),
            normalizedRootIdentityComponent: "r",
            attemptedWorkObserver: { pathBytes, componentWork in
                attemptedWork.append((pathBytes, componentWork))
            }
        )
        let cancellation = ReconstructionCancellation()
        let directory = try capture.append(
            parentIndex: 0,
            rawComponent: "a",
            normalizedComponent: "a",
            kind: .directory,
            cancellation: cancellation
        )
        _ = try capture.append(
            parentIndex: directory,
            rawComponent: "bc",
            normalizedComponent: "bc",
            kind: .regularFile,
            cancellation: cancellation
        )

        let plan = try capture.makeVerificationPlan(cancellation: cancellation)
        XCTAssertEqual(plan.expandedPathUTF8ByteCount, 10)
        XCTAssertEqual(plan.expandedComponentWork, 6)
        XCTAssertEqual(attemptedWork.map(\.pathBytes), [1, 3, 6])
        XCTAssertEqual(attemptedWork.map(\.componentWork), [1, 2, 3])
    }

    func testOneByteOverExpandedPathLimitRejectsBeforeTreeMutation() throws {
        let capture = try Verifier.Capture(
            limits: .init(
                maximumExpandedPathUTF8Bytes: 4,
                maximumExpandedComponentWork: 10
            )
        )
        let cancellation = ReconstructionCancellation()
        let directory = try capture.append(
            parentIndex: 0,
            rawComponent: "a",
            normalizedComponent: "a",
            kind: .directory,
            cancellation: cancellation
        )

        XCTAssertThrowsError(try capture.append(
            parentIndex: directory,
            rawComponent: "bc",
            normalizedComponent: "bc",
            kind: .regularFile,
            cancellation: cancellation
        )) { error in
            XCTAssertEqual(
                error as? Verifier.VerificationError,
                .expandedPathUTF8ByteLimitExceeded
            )
        }

        let plan = try capture.makeVerificationPlan(cancellation: cancellation)
        XCTAssertEqual(plan.nodes.count, 2)
        XCTAssertEqual(plan.expandedPathUTF8ByteCount, 1)
        XCTAssertEqual(plan.expandedComponentWork, 1)
        XCTAssertNil(plan.nodes[directory].firstChildIndex)
    }

    func testOneWorkUnitOverComponentLimitRejectsBeforeTreeMutation() throws {
        let capture = try Verifier.Capture(
            limits: .init(
                maximumExpandedPathUTF8Bytes: 10,
                maximumExpandedComponentWork: 2
            )
        )
        let cancellation = ReconstructionCancellation()
        let directory = try capture.append(
            parentIndex: 0,
            rawComponent: "a",
            normalizedComponent: "a",
            kind: .directory,
            cancellation: cancellation
        )

        XCTAssertThrowsError(try capture.append(
            parentIndex: directory,
            rawComponent: "bc",
            normalizedComponent: "bc",
            kind: .regularFile,
            cancellation: cancellation
        )) { error in
            XCTAssertEqual(
                error as? Verifier.VerificationError,
                .expandedComponentWorkLimitExceeded
            )
        }

        let plan = try capture.makeVerificationPlan(cancellation: cancellation)
        XCTAssertEqual(plan.nodes.count, 2)
        XCTAssertEqual(plan.expandedPathUTF8ByteCount, 1)
        XCTAssertEqual(plan.expandedComponentWork, 1)
        XCTAssertNil(plan.nodes[directory].firstChildIndex)
    }

    func testDeepSharedPrefixFanoutCannotAmplifyExpandedPathsPastBudget() throws {
        // Eight one-byte prefix components contribute 64 expanded path bytes. Each one-byte
        // leaf below that prefix contributes another 17; four leaves therefore end exactly at
        // 132 bytes, while the fifth would raise the aggregate to 149.
        let capture = try Verifier.Capture(
            limits: .init(
                maximumExpandedPathUTF8Bytes: 148,
                maximumExpandedComponentWork: 100
            )
        )
        let cancellation = ReconstructionCancellation()
        var parent = 0
        for _ in 0..<8 {
            parent = try capture.append(
                parentIndex: parent,
                rawComponent: "p",
                normalizedComponent: "p",
                kind: .directory,
                cancellation: cancellation
            )
        }
        for leaf in ["a", "b", "c", "d"] {
            _ = try capture.append(
                parentIndex: parent,
                rawComponent: leaf,
                normalizedComponent: leaf,
                kind: .regularFile,
                cancellation: cancellation
            )
        }

        XCTAssertThrowsError(try capture.append(
            parentIndex: parent,
            rawComponent: "e",
            normalizedComponent: "e",
            kind: .regularFile,
            cancellation: cancellation
        )) { error in
            XCTAssertEqual(
                error as? Verifier.VerificationError,
                .expandedPathUTF8ByteLimitExceeded
            )
        }

        let plan = try capture.makeVerificationPlan(cancellation: cancellation)
        XCTAssertEqual(plan.nodes.count, 13)
        XCTAssertEqual(plan.expandedPathUTF8ByteCount, 132)
        XCTAssertEqual(plan.expandedComponentWork, 72)
    }

    func testPlanUsesCompactSiblingLinksForOneEdgePerNodeTraversal() throws {
        let capture = try Verifier.Capture(
            limits: .init(
                maximumExpandedPathUTF8Bytes: 64,
                maximumExpandedComponentWork: 64
            )
        )
        let cancellation = ReconstructionCancellation()
        let directory = try capture.append(
            parentIndex: 0,
            rawComponent: "z",
            normalizedComponent: "z",
            kind: .directory,
            cancellation: cancellation
        )
        let leaf = try capture.append(
            parentIndex: directory,
            rawComponent: "leaf",
            normalizedComponent: "leaf",
            kind: .regularFile,
            cancellation: cancellation
        )
        let sibling = try capture.append(
            parentIndex: 0,
            rawComponent: "alias",
            normalizedComponent: "alias",
            kind: .symbolicLink,
            cancellation: cancellation
        )

        let plan = try capture.makeVerificationPlan(cancellation: cancellation)

        XCTAssertEqual(plan.nodes[0].firstChildIndex, directory)
        XCTAssertEqual(plan.nodes[directory].firstChildIndex, leaf)
        XCTAssertEqual(plan.nodes[directory].nextSiblingIndex, sibling)
        XCTAssertNil(plan.nodes[leaf].firstChildIndex)
        XCTAssertNil(plan.nodes[leaf].nextSiblingIndex)
        XCTAssertNil(plan.nodes[sibling].firstChildIndex)
        XCTAssertEqual(plan.expandedComponentWork, 4)
    }

    func testAccountingIsIndependentOfSiblingCaptureOrder() throws {
        let limits = Verifier.Limits(
            maximumExpandedPathUTF8Bytes: 64,
            maximumExpandedComponentWork: 64
        )
        let cancellation = ReconstructionCancellation()
        let first = try Verifier.Capture(limits: limits)
        let firstDirectory = try first.append(
            parentIndex: 0,
            rawComponent: "dir",
            normalizedComponent: "dir",
            kind: .directory,
            cancellation: cancellation
        )
        _ = try first.append(
            parentIndex: firstDirectory,
            rawComponent: "x",
            normalizedComponent: "x",
            kind: .regularFile,
            cancellation: cancellation
        )
        _ = try first.append(
            parentIndex: 0,
            rawComponent: "top",
            normalizedComponent: "top",
            kind: .regularFile,
            cancellation: cancellation
        )

        let second = try Verifier.Capture(limits: limits)
        _ = try second.append(
            parentIndex: 0,
            rawComponent: "top",
            normalizedComponent: "top",
            kind: .regularFile,
            cancellation: cancellation
        )
        let secondDirectory = try second.append(
            parentIndex: 0,
            rawComponent: "dir",
            normalizedComponent: "dir",
            kind: .directory,
            cancellation: cancellation
        )
        _ = try second.append(
            parentIndex: secondDirectory,
            rawComponent: "x",
            normalizedComponent: "x",
            kind: .regularFile,
            cancellation: cancellation
        )

        let firstPlan = try first.makeVerificationPlan(cancellation: cancellation)
        let secondPlan = try second.makeVerificationPlan(cancellation: cancellation)
        XCTAssertEqual(firstPlan.expandedPathUTF8ByteCount, 11)
        XCTAssertEqual(secondPlan.expandedPathUTF8ByteCount, 11)
        XCTAssertEqual(firstPlan.expandedComponentWork, 4)
        XCTAssertEqual(secondPlan.expandedComponentWork, 4)
        XCTAssertEqual(firstPlan.nodes.count, secondPlan.nodes.count)
    }

    func testCancellationPreventsAppendPathMaterializationAndPlanCreation() throws {
        let capture = try Verifier.Capture(
            limits: .init(
                maximumExpandedPathUTF8Bytes: 64,
                maximumExpandedComponentWork: 64
            )
        )
        let cancelledAppend = ReconstructionCancellation()
        cancelledAppend.cancel()

        XCTAssertThrowsError(try capture.append(
            parentIndex: 0,
            rawComponent: "blocked",
            normalizedComponent: "blocked",
            kind: .regularFile,
            cancellation: cancelledAppend
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }

        let active = ReconstructionCancellation()
        let admitted = try capture.append(
            parentIndex: 0,
            rawComponent: "accepted",
            normalizedComponent: "accepted",
            kind: .regularFile,
            cancellation: active
        )
        active.cancel()

        XCTAssertThrowsError(try capture.materializeNormalizedRelativePath(
            to: admitted,
            cancellation: active
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertThrowsError(try capture.makeVerificationPlan(cancellation: active)) { error in
            XCTAssertTrue(error is CancellationError)
        }

        let plan = try capture.makeVerificationPlan(cancellation: ReconstructionCancellation())
        XCTAssertEqual(plan.nodes.count, 2)
    }

    func testRawComponentMustCanonicallyMatchNormalizedComponent() throws {
        let capture = try Verifier.Capture(
            limits: .init(
                maximumExpandedPathUTF8Bytes: 64,
                maximumExpandedComponentWork: 64
            )
        )
        let cancellation = ReconstructionCancellation()
        let raw = "e\u{301}"

        let node = try capture.append(
            parentIndex: 0,
            rawComponent: raw,
            normalizedComponent: "é",
            kind: .regularFile,
            cancellation: cancellation
        )
        XCTAssertEqual(
            try capture.materializeNormalizedRelativePath(to: node, cancellation: cancellation),
            "é"
        )

        XCTAssertThrowsError(try capture.append(
            parentIndex: 0,
            rawComponent: raw,
            normalizedComponent: "e",
            kind: .regularFile,
            cancellation: cancellation
        )) { error in
            XCTAssertEqual(error as? Verifier.VerificationError, .invalidComponent)
        }
    }
}
