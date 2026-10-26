import Foundation
import XCTest
@testable import MacScope
#if canImport(Darwin)
import Darwin
import Security
#endif

final class DebuggerLocalProcessIdentityTests: XCTestCase {
    func testCatalogObservationNeverInvokesAuthorizationPass() async throws {
        let evidence = try makeCatalogEvidence(processID: 41)
        let provider = FakeLocalProcessEvidenceProvider(
            processIDs: [41],
            catalog: [41: .resolved(evidence)],
            authorization: [:]
        )
        let observer = DebuggerLocalProcessIdentityObserver(provider: provider)

        let result = await observer.observeCatalog(processID: 41, policy: .fixture)

        guard case let .resolved(observation) = result else {
            return XCTFail("Expected a catalog observation, got \(result)")
        }
        XCTAssertEqual(observation.fingerprint, evidence.fingerprint)
        XCTAssertEqual(observation.displayName, "Fixture")
        let authorizationPassCount = await provider.authorizationPassCount
        XCTAssertEqual(authorizationPassCount, 0)
    }

    func testAuthorizationRequiresTwoEqualPassesAndSelectedFingerprint() async throws {
        let evidence = try makeAuthorizationEvidence(processID: 42)
        let provider = FakeLocalProcessEvidenceProvider(
            processIDs: [42],
            catalog: [:],
            authorization: [42: [.resolved(evidence), .resolved(evidence)]]
        )
        let observer = DebuggerLocalProcessIdentityObserver(provider: provider)
        let selection = try XCTUnwrap(
            DebuggerLocalProcessCatalogSelection(
                discoveryGeneration: 9,
                fingerprint: evidence.fingerprint
            )
        )

        let result = await observer.authorize(selection: selection, policy: .fixture)

        guard case let .resolved(grant) = result else {
            return XCTFail("Expected authorization, got \(result)")
        }
        XCTAssertEqual(grant.discoveryGeneration, 9)
        XCTAssertEqual(grant.identity, evidence.identity)
        let authorizationPassCount = await provider.authorizationPassCount
        XCTAssertEqual(authorizationPassCount, 2)
    }

    func testAuthorizationFailsClosedWhenSecondPassChangesIdentity() async throws {
        let original = try makeAuthorizationEvidence(processID: 43)
        let changed = try makeAuthorizationEvidence(processID: 43, executableFileID: 99)
        let provider = FakeLocalProcessEvidenceProvider(
            processIDs: [43],
            catalog: [:],
            authorization: [43: [.resolved(original), .resolved(changed)]]
        )
        let observer = DebuggerLocalProcessIdentityObserver(provider: provider)
        let selection = try XCTUnwrap(
            DebuggerLocalProcessCatalogSelection(
                discoveryGeneration: 2,
                fingerprint: original.fingerprint
            )
        )

        let result = await observer.authorize(selection: selection, policy: .fixture)

        XCTAssertEqual(result.denial, .identityChanged)
        XCTAssertFalse(result.isResolved)
    }

    func testAuthorizationReclassifiesEveryPassAndStopsBeforeSecondWhenIneligible() async throws {
        let evidence = try makeAuthorizationEvidence(processID: 49, isTraced: true)
        let provider = FakeLocalProcessEvidenceProvider(
            processIDs: [49],
            catalog: [:],
            authorization: [49: [.resolved(evidence), .resolved(evidence)]]
        )
        let observer = DebuggerLocalProcessIdentityObserver(provider: provider)
        let selection = try XCTUnwrap(DebuggerLocalProcessCatalogSelection(
            discoveryGeneration: 4,
            fingerprint: evidence.fingerprint
        ))

        let result = await observer.authorize(selection: selection, policy: .fixture)

        XCTAssertEqual(result.denial, .alreadyTraced)
        let passCount = await provider.authorizationPassCount
        XCTAssertEqual(passCount, 1)
    }

    func testAttachPreflightRevalidatesTwoEqualEligibleObservationsAgainstSelectedIdentity() async throws {
        let evidence = try makeAuthorizationEvidence(processID: 53)
        let provider = FakeLocalProcessEvidenceProvider(
            processIDs: [53],
            catalog: [:],
            authorization: [53: [.resolved(evidence), .resolved(evidence)]]
        )
        let observer = DebuggerLocalProcessIdentityObserver(provider: provider)
        let revalidator: any DebuggerLocalProcessIdentityRevalidating = observer
        let request = DebuggerLocalAttachRequest(selectedIdentity: evidence.identity)

        let result = await revalidator.revalidateAttachRequest(request, policy: .fixture)

        XCTAssertEqual(result, .resolved(evidence.identity))
        let authorizationPassCount = await provider.authorizationPassCount
        XCTAssertEqual(authorizationPassCount, 2)
    }

    func testAttachPreflightRejectsStableObservationThatDiffersFromSelectedCompleteIdentity() async throws {
        let selected = try makeAuthorizationEvidence(processID: 54)
        let changed = try makeAuthorizationEvidence(
            processID: 54,
            executableSHA256: String(repeating: "b", count: 64)
        )
        // The lightweight catalog fingerprint deliberately excludes the whole-file digest. This
        // proves transport preflight compares the complete selected identity rather than only PID
        // or the discovery fingerprint.
        XCTAssertEqual(selected.fingerprint, changed.fingerprint)
        let provider = FakeLocalProcessEvidenceProvider(
            processIDs: [54],
            catalog: [:],
            authorization: [54: [.resolved(changed), .resolved(changed)]]
        )
        let revalidator: any DebuggerLocalProcessIdentityRevalidating =
            DebuggerLocalProcessIdentityObserver(provider: provider)

        let result = await revalidator.revalidateAttachRequest(
            DebuggerLocalAttachRequest(selectedIdentity: selected.identity),
            policy: .fixture
        )

        XCTAssertEqual(result, .unknown(.identityChanged))
        let authorizationPassCount = await provider.authorizationPassCount
        XCTAssertEqual(authorizationPassCount, 2)
    }

    func testAttachPreflightRejectsDriftDisappearanceAndAmbiguityWithoutExtraObservation() async throws {
        let selected = try makeAuthorizationEvidence(processID: 55)
        let drifted = try makeAuthorizationEvidence(processID: 55, executableFileID: 99)
        let cases: [(
            [DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationEvidence>],
            DebuggerLocalProcessResolution<DebuggerLocalProcessIdentity>,
            Int
        )] = [
            ([.resolved(selected), .resolved(drifted)], .unknown(.identityChanged), 2),
            ([.unknown(.disappeared)], .unknown(.disappeared), 1),
            ([.resolved(selected), .unknown(.disappeared)], .unknown(.disappeared), 2),
            ([.unknown(.unstableSnapshot)], .unknown(.unstableSnapshot), 1),
        ]

        for (observations, expected, expectedPassCount) in cases {
            let provider = FakeLocalProcessEvidenceProvider(
                processIDs: [55],
                catalog: [:],
                authorization: [55: observations]
            )
            let revalidator: any DebuggerLocalProcessIdentityRevalidating =
                DebuggerLocalProcessIdentityObserver(provider: provider)

            let result = await revalidator.revalidateAttachRequest(
                DebuggerLocalAttachRequest(selectedIdentity: selected.identity),
                policy: .fixture
            )

            XCTAssertEqual(result, expected)
            let authorizationPassCount = await provider.authorizationPassCount
            XCTAssertEqual(authorizationPassCount, expectedPassCount)
        }
    }

    func testAttachPreflightAppliesEligibilityPolicyBeforeTransportAuthority() async throws {
        let traced = try makeAuthorizationEvidence(processID: 56, isTraced: true)
        let provider = FakeLocalProcessEvidenceProvider(
            processIDs: [56],
            catalog: [:],
            authorization: [56: [.resolved(traced), .resolved(traced)]]
        )
        let revalidator: any DebuggerLocalProcessIdentityRevalidating =
            DebuggerLocalProcessIdentityObserver(provider: provider)

        let result = await revalidator.revalidateAttachRequest(
            DebuggerLocalAttachRequest(selectedIdentity: traced.identity),
            policy: .fixture
        )

        XCTAssertEqual(result, .ineligible(.alreadyTraced))
        let authorizationPassCount = await provider.authorizationPassCount
        XCTAssertEqual(authorizationPassCount, 1)
    }

    func testEligibilityRejectsOwnedTracedTranslatedAndDifferentUserEvidence() async throws {
        let cases: [(DebuggerLocalProcessCatalogEvidence, DebuggerLocalAttachDenial)] = [
            (try makeCatalogEvidence(processID: 44, isTraced: true), .alreadyTraced),
            (try makeCatalogEvidence(processID: 45, isTranslated: true), .translatedArchitecture),
            (try makeCatalogEvidence(processID: 46, realUserID: 502, effectiveUserID: 502), .differentUser),
        ]

        for (evidence, expectedDenial) in cases {
            let provider = FakeLocalProcessEvidenceProvider(
                processIDs: [evidence.fingerprint.processID],
                catalog: [evidence.fingerprint.processID: .resolved(evidence)],
                authorization: [:]
            )
            let observer = DebuggerLocalProcessIdentityObserver(provider: provider)
            let result = await observer.observeCatalog(
                processID: evidence.fingerprint.processID,
                policy: .fixture
            )

            guard case let .resolved(observation) = result else {
                return XCTFail("Expected observable ineligible row")
            }
            XCTAssertEqual(observation.eligibility.denial, expectedDenial)
            XCTAssertFalse(observation.eligibility.isAttachable)
        }

        let owned = try makeCatalogEvidence(processID: 47)
        let provider = FakeLocalProcessEvidenceProvider(
            processIDs: [47],
            catalog: [47: .resolved(owned)],
            authorization: [:]
        )
        let observer = DebuggerLocalProcessIdentityObserver(provider: provider)
        let policy = DebuggerLocalProcessObservationPolicy(
            hostRealUserID: 501,
            hostEffectiveUserID: 501,
            selfProcessID: 9_999,
            excludedInfrastructure: [owned.instanceKey]
        )
        let result = await observer.observeCatalog(processID: 47, policy: policy)
        guard case let .resolved(observation) = result else {
            return XCTFail("Expected observable owned row")
        }
        XCTAssertEqual(observation.eligibility.denial, .selfOrOwnedInfrastructure)
    }

    func testDisplayNameIsControlSanitizedAndBounded() async throws {
        let evidence = try makeCatalogEvidence(
            processID: 48,
            displayName: String(repeating: "x", count: 300) + "\nforged"
        )
        let provider = FakeLocalProcessEvidenceProvider(
            processIDs: [48],
            catalog: [48: .resolved(evidence)],
            authorization: [:]
        )
        let observer = DebuggerLocalProcessIdentityObserver(provider: provider)

        let result = await observer.observeCatalog(processID: 48, policy: .fixture)

        guard case let .resolved(observation) = result else {
            return XCTFail("Expected catalog observation")
        }
        XCTAssertLessThanOrEqual(observation.displayName.utf8.count, 256)
        XCTAssertFalse(observation.displayName.contains("\n"))
    }

    func testUnknownSecurityPolicyRemainsUnknownAndDoesNotBecomeAProvenDenial() async throws {
        let evidence = try makeCatalogEvidence(
            processID: 50,
            hasUnknownSecurityPolicy: true
        )
        let provider = FakeLocalProcessEvidenceProvider(
            processIDs: [50],
            catalog: [50: .resolved(evidence)],
            authorization: [:]
        )

        let result = await DebuggerLocalProcessIdentityObserver(provider: provider)
            .observeCatalog(processID: 50, policy: .fixture)

        guard case let .resolved(observation) = result else {
            return XCTFail("Expected a catalog observation")
        }
        XCTAssertEqual(observation.eligibility, .unknown(.authorizationDeniedUnclassified))
    }

    func testPositiveTargetDebuggingProhibitionIsIneligible() async throws {
        let evidence = try makeCatalogEvidence(
            processID: 51,
            targetDisallowsDebugging: true
        )
        let provider = FakeLocalProcessEvidenceProvider(
            processIDs: [51],
            catalog: [51: .resolved(evidence)],
            authorization: [:]
        )

        let result = await DebuggerLocalProcessIdentityObserver(provider: provider)
            .observeCatalog(processID: 51, policy: .fixture)

        guard case let .resolved(observation) = result else {
            return XCTFail("Expected a catalog observation")
        }
        XCTAssertEqual(observation.eligibility, .ineligible(.targetDisallowsDebugging))
    }

    func testProviderFailureClassificationIsForwardedWithoutCallingAuthorization() async {
        let provider = FakeLocalProcessEvidenceProvider(
            processIDs: [52],
            catalog: [52: .unknown(.metadataAccessDenied)],
            authorization: [:]
        )

        let result = await DebuggerLocalProcessIdentityObserver(provider: provider)
            .observeCatalog(processID: 52, policy: .fixture)

        XCTAssertEqual(result.denial, .metadataAccessDenied)
        let authorizationPassCount = await provider.authorizationPassCount
        XCTAssertEqual(authorizationPassCount, 0)
    }

    #if canImport(Darwin)
    func testSecurityStatusInterpreterDistinguishesPlatformOrdinaryUnsignedAndFailure() {
        let platform = DarwinSecurityStatusInterpreter.observe(
            status: errSecSuccess,
            facts: DarwinSecuritySigningFacts(
                identifier: "com.apple.fixture",
                teamIdentifier: "APPLE",
                codeDirectorySHA256: String(repeating: "a", count: 64),
                platformValue: true,
                signingFlags: 1
            )
        )
        XCTAssertEqual(platform.identity?.isPlatformBinary, true)
        XCTAssertFalse(platform.policyIsUnknown)

        let ordinary = DarwinSecurityStatusInterpreter.observe(
            status: errSecSuccess,
            facts: DarwinSecuritySigningFacts(
                identifier: "com.example.fixture",
                teamIdentifier: "TEAM",
                codeDirectorySHA256: nil,
                platformValue: nil,
                signingFlags: 2
            )
        )
        XCTAssertEqual(ordinary.identity?.isPlatformBinary, false)
        XCTAssertFalse(ordinary.policyIsUnknown)

        let unsigned = DarwinSecurityStatusInterpreter.observe(status: errSecCSUnsigned)
        XCTAssertNil(unsigned.identity)
        XCTAssertFalse(unsigned.policyIsUnknown)

        let accessFailure = DarwinSecurityStatusInterpreter.observe(status: errSecAuthFailed)
        XCTAssertNil(accessFailure.identity)
        XCTAssertTrue(accessFailure.policyIsUnknown)
    }

    func testProcessReadInterpreterClassifiesShortErrnoAndStrictPaths() {
        XCTAssertEqual(
            DarwinProcessReadInterpreter.fixedSizeResult(
                returnedByteCount: 7,
                expectedByteCount: 8,
                capturedErrno: 0
            ).denial,
            .unstableSnapshot
        )
        XCTAssertEqual(
            DarwinProcessReadInterpreter.fixedSizeResult(
                returnedByteCount: 0,
                expectedByteCount: 8,
                capturedErrno: EACCES
            ).denial,
            .metadataAccessDenied
        )
        XCTAssertEqual(
            DarwinProcessReadInterpreter.fixedSizeResult(
                returnedByteCount: 0,
                expectedByteCount: 8,
                capturedErrno: ESRCH
            ).denial,
            .disappeared
        )

        let valid = Array("/tmp/Fixture".utf8).map(CChar.init(bitPattern:)) + [0, 0]
        XCTAssertEqual(
            DarwinProcessReadInterpreter.pathResult(
                bytes: valid,
                returnedByteCount: Int32(valid.count - 2),
                capturedErrno: 0
            ),
            .resolved("/tmp/Fixture")
        )
        XCTAssertEqual(
            DarwinProcessReadInterpreter.pathResult(
                bytes: valid,
                returnedByteCount: Int32(valid.count),
                capturedErrno: 0
            ).denial,
            .unstableSnapshot
        )
        var embeddedNUL = valid
        embeddedNUL[4] = 0
        XCTAssertEqual(
            DarwinProcessReadInterpreter.pathResult(
                bytes: embeddedNUL,
                returnedByteCount: Int32(valid.count - 2),
                capturedErrno: 0
            ).denial,
            .unstableSnapshot
        )
    }

    func testMachOParserAcceptsThinAndNoUUID() throws {
        let uuid = try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let withUUID = makeThinMachO(architecture: .arm64, uuid: uuid)
        let observation = DarwinMachOParser.observe(
            fileByteCount: UInt64(withUUID.count),
            expectedArchitecture: .arm64,
            read: memoryReader(withUUID)
        )
        XCTAssertEqual(observation, .value(DarwinMachOObservation(
            architecture: .arm64,
            uuid: uuid
        )))

        let withoutUUID = makeThinMachO(architecture: .arm64e, uuid: nil)
        XCTAssertEqual(
            DarwinMachOParser.observe(
                fileByteCount: UInt64(withoutUUID.count),
                expectedArchitecture: .arm64e,
                read: memoryReader(withoutUUID)
            ),
            .value(DarwinMachOObservation(architecture: .arm64e, uuid: nil))
        )
    }

    func testMachOParserAcceptsAlignedFAT32AndFAT64() {
        for is64Bit in [false, true] {
            let fixture = makeFatMachO(is64Bit: is64Bit, reserved: 0, alignment: 3)
            XCTAssertEqual(
                DarwinMachOParser.observe(
                    fileByteCount: UInt64(fixture.count),
                    expectedArchitecture: .arm64,
                    read: memoryReader(fixture)
                ),
                .value(DarwinMachOObservation(architecture: .arm64, uuid: nil))
            )
        }
    }

    func testMachOParserRejectsMalformedFatAndUUIDAndReportsCancellation() {
        let badAlignment = makeFatMachO(is64Bit: false, reserved: 0, alignment: 63)
        XCTAssertEqual(
            DarwinMachOParser.observe(
                fileByteCount: UInt64(badAlignment.count),
                expectedArchitecture: .arm64,
                read: memoryReader(badAlignment)
            ),
            .malformed
        )

        let badReserved = makeFatMachO(is64Bit: true, reserved: 1, alignment: 3)
        XCTAssertEqual(
            DarwinMachOParser.observe(
                fileByteCount: UInt64(badReserved.count),
                expectedArchitecture: .arm64,
                read: memoryReader(badReserved)
            ),
            .malformed
        )

        let overlapping = makeFatMachO(
            is64Bit: false,
            reserved: 0,
            alignment: 0,
            forcedSliceOffset: 8
        )
        XCTAssertEqual(
            DarwinMachOParser.observe(
                fileByteCount: UInt64(overlapping.count),
                expectedArchitecture: .arm64,
                read: memoryReader(overlapping)
            ),
            .malformed
        )

        let oversizedUUID = makeThinMachO(
            architecture: .arm64,
            uuid: UUID(),
            uuidCommandByteCount: 32
        )
        XCTAssertEqual(
            DarwinMachOParser.observe(
                fileByteCount: UInt64(oversizedUUID.count),
                expectedArchitecture: .arm64,
                read: memoryReader(oversizedUUID)
            ),
            .malformed
        )

        XCTAssertEqual(
            DarwinMachOParser.observe(
                fileByteCount: 64,
                expectedArchitecture: .arm64,
                read: { _, _ in .cancelled }
            ),
            .cancelled
        )
    }

    func testAuthorizationHasherHandlesInterruptedShortDeadlineAndCancellation() {
        let interrupted = ScriptedDarwinReader([
            .interrupted,
            .value(Data("abc".utf8)),
        ])
        XCTAssertEqual(
            DarwinAuthorizationHasher.sha256(
                byteCount: 3,
                deadlineExpired: { false },
                isCancelled: { false },
                read: interrupted.read
            ),
            .success("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        )

        let short = ScriptedDarwinReader([.endOfFile])
        XCTAssertEqual(
            DarwinAuthorizationHasher.sha256(
                byteCount: 3,
                deadlineExpired: { false },
                isCancelled: { false },
                read: short.read
            ),
            .unstable
        )
        XCTAssertEqual(
            DarwinAuthorizationHasher.sha256(
                byteCount: 3,
                deadlineExpired: { true },
                isCancelled: { false },
                read: { _, _ in .endOfFile }
            ),
            .timeout
        )
        XCTAssertEqual(
            DarwinAuthorizationHasher.sha256(
                byteCount: 3,
                deadlineExpired: { false },
                isCancelled: { true },
                read: { _, _ in .endOfFile }
            ),
            .cancelled
        )

        var cancellationBecameVisible = false
        XCTAssertEqual(
            DarwinAuthorizationHasher.sha256(
                byteCount: 3,
                deadlineExpired: { false },
                isCancelled: { cancellationBecameVisible },
                read: { _, _ in
                    cancellationBecameVisible = true
                    return .value(Data("abc".utf8))
                }
            ),
            .cancelled
        )
    }
    #endif
}

#if canImport(Darwin)
private final class ScriptedDarwinReader: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [DarwinReadResult<Data>]

    init(_ steps: [DarwinReadResult<Data>]) {
        self.steps = steps
    }

    func read(offset _: UInt64, count _: Int) -> DarwinReadResult<Data> {
        lock.withLock {
            guard !steps.isEmpty else { return .endOfFile }
            return steps.removeFirst()
        }
    }
}

private func memoryReader(_ data: Data) -> (UInt64, Int) -> DarwinReadResult<Data> {
    { offset, count in
        guard offset <= UInt64(data.count),
              count >= 0,
              let end = Int(exactly: offset)?.addingReportingOverflow(count),
              !end.overflow,
              end.partialValue <= data.count else {
            return .endOfFile
        }
        return .value(data[Int(offset)..<end.partialValue])
    }
}

private func makeThinMachO(
    architecture: DebuggerLocalProcessArchitecture,
    uuid: UUID?,
    uuidCommandByteCount: UInt32 = 24
) -> Data {
    var data = Data()
    data.appendLE(UInt32(0xfeed_facf))
    data.appendLE(UInt32(bitPattern: CPU_TYPE_ARM64))
    data.appendLE(architecture == .arm64e ? 2 : 0)
    data.appendLE(2)
    data.appendLE(uuid == nil ? 0 : 1)
    data.appendLE(uuid == nil ? 0 : uuidCommandByteCount)
    data.appendLE(0)
    data.appendLE(0)
    if let uuid {
        data.appendLE(0x1b)
        data.appendLE(uuidCommandByteCount)
        Swift.withUnsafeBytes(of: uuid.uuid) { data.append(contentsOf: $0) }
        if uuidCommandByteCount > 24 {
            data.append(Data(repeating: 0, count: Int(uuidCommandByteCount - 24)))
        }
    }
    return data
}

private func makeFatMachO(
    is64Bit: Bool,
    reserved: UInt32,
    alignment: UInt32,
    forcedSliceOffset: UInt64? = nil
) -> Data {
    let thin = makeThinMachO(architecture: .arm64, uuid: nil)
    let sliceOffset = forcedSliceOffset ?? 40
    var data = Data()
    data.appendBE(UInt32(is64Bit ? 0xcafe_babf : 0xcafe_babe))
    data.appendBE(UInt32(1))
    data.appendBE(UInt32(bitPattern: CPU_TYPE_ARM64))
    data.appendBE(UInt32(0))
    if is64Bit {
        data.appendBE(sliceOffset)
        data.appendBE(UInt64(thin.count))
        data.appendBE(alignment)
        data.appendBE(reserved)
    } else {
        data.appendBE(UInt32(sliceOffset))
        data.appendBE(UInt32(thin.count))
        data.appendBE(alignment)
    }
    if sliceOffset > UInt64(data.count) {
        data.append(Data(repeating: 0, count: Int(sliceOffset) - data.count))
    }
    data.append(thin)
    return data
}

private extension Data {
    mutating func appendLE(_ value: UInt32) {
        append(contentsOf: Swift.withUnsafeBytes(of: value.littleEndian, Array.init))
    }

    mutating func appendBE(_ value: UInt32) {
        append(contentsOf: Swift.withUnsafeBytes(of: value.bigEndian, Array.init))
    }

    mutating func appendBE(_ value: UInt64) {
        append(contentsOf: Swift.withUnsafeBytes(of: value.bigEndian, Array.init))
    }
}
#endif

private actor FakeLocalProcessEvidenceProvider: DebuggerLocalProcessEvidenceProviding {
    let processIDsValue: [Int32]
    let catalogValues: [Int32: DebuggerLocalProcessResolution<DebuggerLocalProcessCatalogEvidence>]
    var authorizationValues: [Int32: [DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationEvidence>]]
    private(set) var authorizationPassCount = 0

    init(
        processIDs: [Int32],
        catalog: [Int32: DebuggerLocalProcessResolution<DebuggerLocalProcessCatalogEvidence>],
        authorization: [Int32: [DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationEvidence>]]
    ) {
        processIDsValue = processIDs
        catalogValues = catalog
        authorizationValues = authorization
    }

    func processIDs() async -> DebuggerLocalProcessResolution<[Int32]> {
        .resolved(processIDsValue)
    }

    func catalogEvidence(
        processID: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessCatalogEvidence> {
        catalogValues[processID] ?? .unknown(.disappeared)
    }

    func authorizationEvidence(
        processID: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationEvidence> {
        authorizationPassCount += 1
        guard var values = authorizationValues[processID], !values.isEmpty else {
            return .unknown(.disappeared)
        }
        let result = values.removeFirst()
        authorizationValues[processID] = values
        return result
    }
}

private extension DebuggerLocalProcessObservationPolicy {
    static let fixture = DebuggerLocalProcessObservationPolicy(
        hostRealUserID: 501,
        hostEffectiveUserID: 501,
        selfProcessID: 9_999,
        excludedInfrastructure: []
    )
}

private func makeCatalogEvidence(
    processID: Int32,
    displayName: String = "Fixture",
    realUserID: UInt32 = 501,
    effectiveUserID: UInt32 = 501,
    executableFileID: UInt64 = 32,
    isSystem: Bool = false,
    isTraced: Bool = false,
    isExiting: Bool = false,
    isZombie: Bool = false,
    isTranslated: Bool = false,
    targetDisallowsDebugging: Bool = false,
    hasUnknownSecurityPolicy: Bool = false
) throws -> DebuggerLocalProcessCatalogEvidence {
    let start = try XCTUnwrap(DebuggerProcessStartIdentity(seconds: 100, microseconds: 2))
    let fingerprint = try XCTUnwrap(
        DebuggerLocalProcessCatalogFingerprint(
            processID: processID,
            startTime: start,
            realUserID: realUserID,
            effectiveUserID: effectiveUserID,
            canonicalExecutablePath: "/tmp/Fixture-\(processID)",
            executableDeviceID: 16,
            executableFileID: executableFileID,
            executableByteCount: 4_096,
            executableChangeTimeNanoseconds: 1_000,
            architecture: .arm64,
            machOUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555"),
            codeIdentity: nil
        )
    )
    return DebuggerLocalProcessCatalogEvidence(
        fingerprint: fingerprint,
        displayName: displayName,
        parentProcessID: 1,
        savedUserID: realUserID,
        dynamicState: DebuggerLocalProcessDynamicState(
            isSystem: isSystem,
            isTraced: isTraced,
            isExiting: isExiting,
            isZombie: isZombie,
            isTranslated: isTranslated,
            hasPrivilegedIdentityTransition: false,
            targetDisallowsDebugging: targetDisallowsDebugging,
            hasUnknownSecurityPolicy: hasUnknownSecurityPolicy
        )
    )
}

private func makeAuthorizationEvidence(
    processID: Int32,
    executableFileID: UInt64 = 32,
    executableSHA256: String = String(repeating: "a", count: 64),
    isTraced: Bool = false
) throws -> DebuggerLocalProcessAuthorizationEvidence {
    let catalog = try makeCatalogEvidence(
        processID: processID,
        executableFileID: executableFileID,
        isTraced: isTraced
    )
    let identity = try XCTUnwrap(
        DebuggerLocalProcessIdentity(
            processID: processID,
            startTime: catalog.fingerprint.startTime,
            realUserID: catalog.fingerprint.realUserID,
            effectiveUserID: catalog.fingerprint.effectiveUserID,
            canonicalExecutablePath: catalog.fingerprint.canonicalExecutablePath,
            executableDeviceID: catalog.fingerprint.executableDeviceID,
            executableFileID: catalog.fingerprint.executableFileID,
            executableByteCount: catalog.fingerprint.executableByteCount,
            executableSHA256: executableSHA256,
            architecture: catalog.fingerprint.architecture,
            machOUUID: catalog.fingerprint.machOUUID,
            codeIdentity: catalog.fingerprint.codeIdentity
        )
    )
    return DebuggerLocalProcessAuthorizationEvidence(
        catalogEvidence: catalog,
        identity: identity
    )
}

private extension DebuggerLocalProcessCatalogEvidence {
    var instanceKey: DebuggerLocalProcessInstanceKey {
        DebuggerLocalProcessInstanceKey(
            processID: fingerprint.processID,
            startTime: fingerprint.startTime
        )
    }
}
