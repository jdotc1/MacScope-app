import XCTest
@testable import MacScope

final class DebuggerLocalProcessIdentityReobservationTests: XCTestCase {
    func testStableCompleteIdentityResolvesAfterExactlyTwoObservationsWithoutEligibilityPolicy() async throws {
        let expected = try identity(processID: 71)
        let first = try evidence(
            identity: expected,
            displayName: "Before retirement",
            dynamicState: DebuggerLocalProcessDynamicState(isTraced: true)
        )
        let second = try evidence(
            identity: expected,
            displayName: "After retirement",
            dynamicState: DebuggerLocalProcessDynamicState(targetDisallowsDebugging: true)
        )
        let provider = ReobservationEvidenceProvider(
            observations: [.resolved(first), .resolved(second)]
        )
        let reobserver: any DebuggerLocalProcessIdentityReobserving =
            DebuggerLocalProcessIdentityObserver(provider: provider)

        let result = await reobserver.reobserveIdentity(expected)

        XCTAssertEqual(result, .resolved(expected))
        let observationCount = await provider.observationCount
        XCTAssertEqual(observationCount, 2)
    }

    func testDisappearanceAndAccessDenialAreForwardedAtTheExactObservation() async throws {
        let expected = try identity(processID: 72)
        let complete = try evidence(identity: expected)
        let cases: [(
            [DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationEvidence>],
            DebuggerLocalProcessResolution<DebuggerLocalProcessIdentity>,
            Int
        )] = [
            ([.unknown(.disappeared)], .unknown(.disappeared), 1),
            (
                [.resolved(complete), .unknown(.disappeared)],
                .unknown(.disappeared),
                2
            ),
            ([.unknown(.metadataAccessDenied)], .unknown(.metadataAccessDenied), 1),
            (
                [.resolved(complete), .unknown(.metadataAccessDenied)],
                .unknown(.metadataAccessDenied),
                2
            ),
        ]

        for (observations, expectedResult, expectedCount) in cases {
            let provider = ReobservationEvidenceProvider(observations: observations)
            let reobserver: any DebuggerLocalProcessIdentityReobserving =
                DebuggerLocalProcessIdentityObserver(provider: provider)

            let result = await reobserver.reobserveIdentity(expected)

            XCTAssertEqual(result, expectedResult)
            let observationCount = await provider.observationCount
            XCTAssertEqual(observationCount, expectedCount)
        }
    }

    func testIncompleteOrUnstableObservationCannotFabricateSurvival() async throws {
        let expected = try identity(processID: 73)
        let incoherent = try evidence(
            identity: expected,
            fingerprintProcessID: expected.processID + 1
        )
        let cases: [(
            [DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationEvidence>],
            DebuggerLocalProcessResolution<DebuggerLocalProcessIdentity>,
            Int
        )] = [
            ([.unknown(.unstableSnapshot)], .unknown(.unstableSnapshot), 1),
            (
                [
                    .resolved(try evidence(identity: expected)),
                    .unknown(.unstableSnapshot),
                ],
                .unknown(.unstableSnapshot),
                2
            ),
            ([.resolved(incoherent)], .unknown(.identityChanged), 1),
        ]

        for (observations, expectedResult, expectedCount) in cases {
            let provider = ReobservationEvidenceProvider(observations: observations)
            let reobserver: any DebuggerLocalProcessIdentityReobserving =
                DebuggerLocalProcessIdentityObserver(provider: provider)

            let result = await reobserver.reobserveIdentity(expected)

            XCTAssertEqual(result, expectedResult)
            let observationCount = await provider.observationCount
            XCTAssertEqual(observationCount, expectedCount)
        }
    }

    func testAttachIneligibilityCannotClassifyIdentityOnlyReobservation() async throws {
        let expected = try identity(processID: 76)
        let complete = try evidence(identity: expected)
        let cases: [(
            [DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationEvidence>],
            Int
        )] = [
            ([.ineligible(.translatedArchitecture)], 1),
            ([.resolved(complete), .ineligible(.unsupportedArchitecture)], 2),
        ]

        for (observations, expectedCount) in cases {
            let provider = ReobservationEvidenceProvider(observations: observations)
            let reobserver: any DebuggerLocalProcessIdentityReobserving =
                DebuggerLocalProcessIdentityObserver(provider: provider)

            let result = await reobserver.reobserveIdentity(expected)

            XCTAssertEqual(result, .unknown(.identityChanged))
            let observationCount = await provider.observationCount
            XCTAssertEqual(observationCount, expectedCount)
        }
    }

    func testTwoObservationInstabilityReportsIdentityChange() async throws {
        let expected = try identity(processID: 74)
        let changed = try identity(processID: 74, executableFileID: 8_002)
        let provider = ReobservationEvidenceProvider(
            observations: [
                .resolved(try evidence(identity: expected)),
                .resolved(try evidence(identity: changed)),
            ]
        )
        let reobserver: any DebuggerLocalProcessIdentityReobserving =
            DebuggerLocalProcessIdentityObserver(provider: provider)

        let result = await reobserver.reobserveIdentity(expected)

        XCTAssertEqual(result, .unknown(.identityChanged))
        let observationCount = await provider.observationCount
        XCTAssertEqual(observationCount, 2)
    }

    func testStableReplacementIdentityDoesNotProveExpectedProcessSurvived() async throws {
        let expected = try identity(processID: 75)
        let replacement = try identity(
            processID: 75,
            executableSHA256: String(repeating: "b", count: 64)
        )
        let replacementEvidence = try evidence(identity: replacement)
        let provider = ReobservationEvidenceProvider(
            observations: [.resolved(replacementEvidence), .resolved(replacementEvidence)]
        )
        let reobserver: any DebuggerLocalProcessIdentityReobserving =
            DebuggerLocalProcessIdentityObserver(provider: provider)

        let result = await reobserver.reobserveIdentity(expected)

        XCTAssertEqual(result, .unknown(.identityChanged))
        let observationCount = await provider.observationCount
        XCTAssertEqual(observationCount, 2)
    }

    private func identity(
        processID: Int32,
        executableFileID: UInt64 = 8_001,
        executableSHA256: String = String(repeating: "a", count: 64)
    ) throws -> DebuggerLocalProcessIdentity {
        try XCTUnwrap(
            DebuggerLocalProcessIdentity(
                processID: processID,
                startTime: XCTUnwrap(
                    DebuggerProcessStartIdentity(seconds: 7_000_001, microseconds: 19)
                ),
                realUserID: 501,
                effectiveUserID: 501,
                canonicalExecutablePath: "/tmp/MacScopeReobservationFixture-" + String(processID),
                executableDeviceID: 7,
                executableFileID: executableFileID,
                executableByteCount: 4_096,
                executableSHA256: executableSHA256,
                architecture: .arm64,
                machOUUID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
                codeIdentity: nil
            )
        )
    }

    private func evidence(
        identity: DebuggerLocalProcessIdentity,
        fingerprintProcessID: Int32? = nil,
        displayName: String = "Fixture",
        dynamicState: DebuggerLocalProcessDynamicState = .init()
    ) throws -> DebuggerLocalProcessAuthorizationEvidence {
        let fingerprint = try XCTUnwrap(
            DebuggerLocalProcessCatalogFingerprint(
                processID: fingerprintProcessID ?? identity.processID,
                startTime: identity.startTime,
                realUserID: identity.realUserID,
                effectiveUserID: identity.effectiveUserID,
                canonicalExecutablePath: identity.canonicalExecutablePath,
                executableDeviceID: identity.executableDeviceID,
                executableFileID: identity.executableFileID,
                executableByteCount: identity.executableByteCount,
                executableChangeTimeNanoseconds: 900,
                architecture: identity.architecture,
                machOUUID: identity.machOUUID,
                codeIdentity: identity.codeIdentity
            )
        )
        return DebuggerLocalProcessAuthorizationEvidence(
            catalogEvidence: DebuggerLocalProcessCatalogEvidence(
                fingerprint: fingerprint,
                displayName: displayName,
                parentProcessID: 1,
                savedUserID: identity.realUserID,
                dynamicState: dynamicState
            ),
            identity: identity
        )
    }
}

private actor ReobservationEvidenceProvider: DebuggerLocalProcessEvidenceProviding {
    private var observations:
        [DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationEvidence>]
    private(set) var observationCount = 0

    init(
        observations: [
            DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationEvidence>
        ]
    ) {
        self.observations = observations
    }

    func processIDs() async -> DebuggerLocalProcessResolution<[Int32]> {
        .unknown(.unstableSnapshot)
    }

    func catalogEvidence(
        processID: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessCatalogEvidence> {
        .unknown(.unstableSnapshot)
    }

    func authorizationEvidence(
        processID: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationEvidence> {
        observationCount += 1
        guard !observations.isEmpty else { return .unknown(.unstableSnapshot) }
        return observations.removeFirst()
    }
}
