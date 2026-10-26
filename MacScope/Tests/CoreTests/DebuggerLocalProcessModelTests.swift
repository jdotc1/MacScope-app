import Foundation
import XCTest
@testable import MacScope

final class DebuggerLocalProcessModelTests: XCTestCase {
    func testProcessStartIdentityRequiresPositiveSecondsAndBoundedMicroseconds() {
        XCTAssertNil(DebuggerProcessStartIdentity(seconds: 0, microseconds: 0))
        XCTAssertNil(DebuggerProcessStartIdentity(seconds: 1, microseconds: 1_000_000))

        XCTAssertEqual(
            DebuggerProcessStartIdentity(seconds: 1, microseconds: 999_999),
            DebuggerProcessStartIdentity(seconds: 1, microseconds: 999_999)
        )
    }

    func testCompleteProcessIdentityAcceptsArm64AndArm64eEvidence() throws {
        for architecture in [DebuggerLocalProcessArchitecture.arm64, .arm64e] {
            let identity = try XCTUnwrap(makeIdentity(architecture: architecture))

            XCTAssertEqual(identity.processID, 4_242)
            XCTAssertEqual(identity.startTime, startTime())
            XCTAssertEqual(identity.realUserID, 501)
            XCTAssertEqual(identity.effectiveUserID, 501)
            XCTAssertEqual(identity.canonicalExecutablePath, "/Applications/Fixture.app/Contents/MacOS/Fixture")
            XCTAssertEqual(identity.executableDeviceID, 16)
            XCTAssertEqual(identity.executableFileID, 32)
            XCTAssertEqual(identity.executableByteCount, 4_096)
            XCTAssertEqual(identity.executableSHA256, String(repeating: "a", count: 64))
            XCTAssertEqual(identity.architecture, architecture)
            XCTAssertEqual(
                identity.machOUUID,
                UUID(uuidString: "11111111-2222-3333-4444-555555555555")
            )
            XCTAssertEqual(identity.codeIdentity, codeIdentity())
        }
    }

    func testCompleteProcessIdentityRejectsIncompleteOrMalformedAuthority() {
        XCTAssertNil(makeIdentity(processID: 0))
        XCTAssertNil(makeIdentity(canonicalExecutablePath: "relative/Fixture"))
        XCTAssertNil(makeIdentity(canonicalExecutablePath: "/tmp/bad\npath"))
        XCTAssertNil(makeIdentity(canonicalExecutablePath: "/tmp/../Applications/Fixture"))
        XCTAssertNil(makeIdentity(canonicalExecutablePath: "//Applications/Fixture"))
        XCTAssertNil(makeIdentity(canonicalExecutablePath: "/Applications/Fixture/"))
        XCTAssertNil(makeIdentity(executableDeviceID: 0))
        XCTAssertNil(makeIdentity(executableFileID: 0))
        XCTAssertNil(makeIdentity(executableByteCount: 0))
        XCTAssertNil(makeIdentity(executableSHA256: String(repeating: "a", count: 63)))
        XCTAssertNil(makeIdentity(executableSHA256: String(repeating: "A", count: 64)))

        XCTAssertNil(
            DebuggerLocalCodeIdentity(
                signingIdentifier: "bad\nsigning-id",
                teamIdentifier: "TEAM123456",
                codeDirectorySHA256: String(repeating: "b", count: 64),
                isPlatformBinary: false,
                signingFlags: 0
            )
        )
    }

    func testCodeIdentityPreservesPartialEvidenceAndUnknownFacts() throws {
        let unknownPlatform = try XCTUnwrap(
            DebuggerLocalCodeIdentity(
                signingIdentifier: "com.example.fixture",
                teamIdentifier: nil,
                codeDirectorySHA256: nil,
                isPlatformBinary: nil,
                signingFlags: nil
            )
        )
        let knownNonPlatform = try XCTUnwrap(
            DebuggerLocalCodeIdentity(
                signingIdentifier: "com.example.fixture",
                teamIdentifier: nil,
                codeDirectorySHA256: nil,
                isPlatformBinary: false,
                signingFlags: nil
            )
        )

        XCTAssertNotEqual(unknownPlatform, knownNonPlatform)
        XCTAssertNil(
            DebuggerLocalCodeIdentity(
                signingIdentifier: nil,
                teamIdentifier: nil,
                codeDirectorySHA256: nil,
                isPlatformBinary: nil,
                signingFlags: nil
            )
        )
    }

    func testCatalogFingerprintDoesNotContainDiscoveryGeneration() throws {
        let identity = try XCTUnwrap(makeIdentity())
        let fingerprint = try XCTUnwrap(makeFingerprint(identity: identity))
        let first = try XCTUnwrap(
            DebuggerLocalProcessCatalogSelection(
                discoveryGeneration: 7,
                fingerprint: fingerprint
            )
        )
        let refreshed = try XCTUnwrap(
            DebuggerLocalProcessCatalogSelection(
                discoveryGeneration: 8,
                fingerprint: fingerprint
            )
        )

        XCTAssertEqual(first.fingerprint, refreshed.fingerprint)
        XCTAssertNotEqual(first, refreshed)
        XCTAssertNil(
            DebuggerLocalProcessCatalogSelection(
                discoveryGeneration: 0,
                fingerprint: fingerprint
            )
        )
    }

    func testAuthorizationGrantRequiresPositiveGenerationAndExactFingerprintAgreement() throws {
        let identity = try XCTUnwrap(makeIdentity())
        let fingerprint = try XCTUnwrap(makeFingerprint(identity: identity))
        let grant = try XCTUnwrap(
            DebuggerLocalProcessAuthorizationGrant(
                discoveryGeneration: 7,
                fingerprint: fingerprint,
                authorizationFingerprint: fingerprint,
                identity: identity
            )
        )

        XCTAssertEqual(grant.discoveryGeneration, 7)
        XCTAssertEqual(grant.fingerprint, fingerprint)
        XCTAssertEqual(grant.identity, identity)
        XCTAssertNil(
            DebuggerLocalProcessAuthorizationGrant(
                discoveryGeneration: 0,
                fingerprint: fingerprint,
                authorizationFingerprint: fingerprint,
                identity: identity
            )
        )

        let changedExecutable = try XCTUnwrap(makeIdentity(executableFileID: 99))
        XCTAssertNil(
            DebuggerLocalProcessAuthorizationGrant(
                discoveryGeneration: 7,
                fingerprint: fingerprint,
                authorizationFingerprint: try XCTUnwrap(makeFingerprint(identity: changedExecutable)),
                identity: changedExecutable
            )
        )

        let changedTime = try XCTUnwrap(
            makeFingerprint(identity: identity, executableChangeTimeNanoseconds: 123_457)
        )
        XCTAssertNil(
            DebuggerLocalProcessAuthorizationGrant(
                discoveryGeneration: 7,
                fingerprint: fingerprint,
                authorizationFingerprint: changedTime,
                identity: identity
            )
        )
    }

    func testLocalAttachRequestCarriesOnlyTheSelectedCompleteIdentity() throws {
        let identity = try XCTUnwrap(makeIdentity())

        let request = DebuggerLocalAttachRequest(selectedIdentity: identity)

        XCTAssertEqual(request.selectedIdentity, identity)
        XCTAssertEqual(request, DebuggerLocalAttachRequest(selectedIdentity: identity))
        assertSendableAndHashable(DebuggerLocalAttachRequest.self)
    }

    func testEligibilityIsTriStateAndOnlyEligibleIsAttachable() {
        let eligible = DebuggerLocalProcessEligibility.eligible
        let ineligible = DebuggerLocalProcessEligibility.ineligible(.differentUser)
        let unknown = DebuggerLocalProcessEligibility.unknown(.metadataAccessDenied)

        XCTAssertTrue(eligible.isAttachable)
        XCTAssertFalse(ineligible.isAttachable)
        XCTAssertFalse(unknown.isAttachable)
        XCTAssertNotEqual(ineligible, unknown)
        XCTAssertEqual(ineligible.denial, .differentUser)
        XCTAssertEqual(unknown.denial, .metadataAccessDenied)
    }

    func testAttachDenialVocabularyPreservesSecurityAndLifecycleCauses() {
        let denials: Set<DebuggerLocalAttachDenial> = [
            .disappeared,
            .identityChanged,
            .unstableSnapshot,
            .metadataAccessDenied,
            .selfOrOwnedInfrastructure,
            .systemProcess,
            .platformProtected,
            .differentUser,
            .privilegedIdentity,
            .alreadyTraced,
            .exiting,
            .unsupportedArchitecture,
            .translatedArchitecture,
            .targetDisallowsDebugging,
            .developerToolsAuthorizationRequired,
            .authorizationDeniedUnclassified,
            .observedPIDMissing,
            .observedPIDMismatch,
            .postAttachIdentityMismatch,
            .timeout,
            .adapterProtocolFailure,
            .detachUnconfirmed,
            .targetDispositionUnknown,
        ]

        XCTAssertEqual(denials.count, 23)
    }

    func testKernelProcessInstanceKeySeparatesPIDReuseButNotSameStartExec() throws {
        let original = try XCTUnwrap(makeIdentity())
        let reusedPID = try XCTUnwrap(
            makeIdentity(startTime: try XCTUnwrap(
                DebuggerProcessStartIdentity(seconds: 8_765_433, microseconds: 2)
            ))
        )
        let sameInstanceAfterExec = try XCTUnwrap(
            makeIdentity(
                canonicalExecutablePath: "/Applications/Other.app/Contents/MacOS/Other",
                executableFileID: 33,
                executableSHA256: String(repeating: "d", count: 64)
            )
        )

        XCTAssertNotEqual(
            DebuggerLocalProcessInstanceKey(identity: original),
            DebuggerLocalProcessInstanceKey(identity: reusedPID)
        )
        XCTAssertEqual(
            DebuggerLocalProcessInstanceKey(identity: original),
            DebuggerLocalProcessInstanceKey(identity: sameInstanceAfterExec)
        )
        XCTAssertNotEqual(original, sameInstanceAfterExec)
    }

    func testEveryImmutableAuthorityMutationChangesDigestAndBreaksFingerprintAgreement() throws {
        let original = try XCTUnwrap(makeIdentity())
        let fingerprint = try XCTUnwrap(makeFingerprint(identity: original))
        let codeMutations = try [
            XCTUnwrap(makeCodeIdentity(signingIdentifier: "com.example.other")),
            XCTUnwrap(makeCodeIdentity(teamIdentifier: "OTHERTEAM1")),
            XCTUnwrap(makeCodeIdentity(codeDirectorySHA256: String(repeating: "c", count: 64))),
            XCTUnwrap(makeCodeIdentity(isPlatformBinary: true)),
            XCTUnwrap(makeCodeIdentity(signingFlags: 1)),
        ]
        let unknownPlatformAndFlags = try XCTUnwrap(
            makeCodeIdentity(
                teamIdentifier: nil,
                codeDirectorySHA256: nil,
                isPlatformBinary: nil,
                signingFlags: nil
            )
        )
        let knownFalseAndZero = try XCTUnwrap(
            makeCodeIdentity(
                teamIdentifier: nil,
                codeDirectorySHA256: nil,
                isPlatformBinary: false,
                signingFlags: 0
            )
        )
        var mutations = try [
            XCTUnwrap(makeIdentity(processID: 4_243)),
            XCTUnwrap(makeIdentity(startTime: XCTUnwrap(
                DebuggerProcessStartIdentity(seconds: 8_765_433, microseconds: 1)
            ))),
            XCTUnwrap(makeIdentity(realUserID: 502)),
            XCTUnwrap(makeIdentity(effectiveUserID: 502)),
            XCTUnwrap(makeIdentity(canonicalExecutablePath: "/Applications/Other/Fixture")),
            XCTUnwrap(makeIdentity(executableDeviceID: 17)),
            XCTUnwrap(makeIdentity(executableFileID: 33)),
            XCTUnwrap(makeIdentity(executableByteCount: 4_097)),
            XCTUnwrap(makeIdentity(executableSHA256: String(repeating: "d", count: 64))),
            XCTUnwrap(makeIdentity(architecture: .arm64e)),
            XCTUnwrap(makeIdentity(machOUUID: UUID(
                uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            ))),
        ]
        mutations.append(contentsOf: try codeMutations.map { codeIdentity in
            try XCTUnwrap(makeIdentity(codeIdentity: codeIdentity))
        })
        let unknownIdentity = try XCTUnwrap(makeIdentity(codeIdentity: unknownPlatformAndFlags))
        let knownIdentity = try XCTUnwrap(makeIdentity(codeIdentity: knownFalseAndZero))
        XCTAssertNotEqual(unknownIdentity.identityDigest, knownIdentity.identityDigest)
        mutations.append(contentsOf: [unknownIdentity, knownIdentity])

        for (index, mutation) in mutations.enumerated() {
            XCTAssertNotEqual(mutation.identityDigest, original.identityDigest)
            // The complete executable digest is intentionally absent from the lightweight
            // fingerprint; the authorization observer proves it independently in both passes.
            if index != 8 {
                XCTAssertNil(
                    DebuggerLocalProcessAuthorizationGrant(
                        discoveryGeneration: 7,
                        fingerprint: fingerprint,
                        authorizationFingerprint: fingerprint,
                        identity: mutation
                    )
                )
            }
        }
    }

    func testSessionTargetAuthorityDerivesExactLaunchedAndAttachedOrigins() throws {
        let identity = try XCTUnwrap(makeIdentity())
        let launchedIdentity = try XCTUnwrap(makeIdentity(processID: 55))
        let launched = DebuggerLaunchTargetAuthority(identity: launchedIdentity)
        let launchedAuthority = DebuggerSessionTargetAuthority(origin: .launched(launched))
        let attachedAuthority = DebuggerSessionTargetAuthority(origin: .attached(identity))

        XCTAssertEqual(launchedAuthority.processID, 55)
        XCTAssertEqual(launchedAuthority.identityDigest, launchedIdentity.identityDigest)
        XCTAssertEqual(attachedAuthority.processID, identity.processID)
        XCTAssertEqual(attachedAuthority.identityDigest, identity.identityDigest)
        XCTAssertNotEqual(launchedAuthority.origin, attachedAuthority.origin)
    }

    func testSessionEndCapabilitiesSeparateAttachedDetachFromLaunchedTerminate() throws {
        let attachedIdentity = try XCTUnwrap(makeIdentity(processID: 42))
        let launchedIdentity = try XCTUnwrap(makeIdentity(processID: 43))
        let attachedAuthority = DebuggerSessionTargetAuthority(origin: .attached(attachedIdentity))
        let launchedAuthority = DebuggerSessionTargetAuthority(
            origin: .launched(DebuggerLaunchTargetAuthority(identity: launchedIdentity))
        )

        let attachedSnapshot = DebuggerSessionSnapshot(
            processState: .paused(processID: 42, reason: .userRequested),
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Paused.",
            backendState: .connected(processID: 42, adapterName: "Test LLDB"),
            transportTargetAuthority: attachedAuthority
        )
        XCTAssertTrue(attachedSnapshot.canDetachLiveProcess)
        XCTAssertFalse(attachedSnapshot.canTerminateLiveProcess)

        let launchedSnapshot = DebuggerSessionSnapshot(
            processState: .paused(processID: 43, reason: .userRequested),
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Paused.",
            backendState: .connected(processID: 43, adapterName: "Test LLDB"),
            transportTargetAuthority: launchedAuthority
        )
        XCTAssertFalse(launchedSnapshot.canDetachLiveProcess)
        XCTAssertTrue(launchedSnapshot.canTerminateLiveProcess)

        let legacySnapshot = DebuggerSessionSnapshot(
            processState: .paused(processID: 44, reason: .userRequested),
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Paused.",
            backendState: .connected(processID: 44, adapterName: "Legacy LLDB")
        )
        XCTAssertFalse(legacySnapshot.canDetachLiveProcess)
        XCTAssertTrue(legacySnapshot.canTerminateLiveProcess)
    }

    func testTerminalOutcomesRemainDistinct() {
        let outcomes: Set<DebuggerTargetDisposition> = [
            .exited(code: 0),
            .detached,
            .terminated,
            .unknown,
        ]

        XCTAssertEqual(outcomes.count, 4)
    }

    func testNewProcessAuthorityValuesAreSendableAndHashable() {
        assertSendableAndHashable(DebuggerProcessStartIdentity.self)
        assertSendableAndHashable(DebuggerLocalProcessArchitecture.self)
        assertSendableAndHashable(DebuggerLocalCodeIdentity.self)
        assertSendableAndHashable(DebuggerLocalProcessIdentity.self)
        assertSendableAndHashable(DebuggerLocalProcessCatalogFingerprint.self)
        assertSendableAndHashable(DebuggerLocalProcessCatalogSelection.self)
        assertSendableAndHashable(DebuggerLocalProcessAuthorizationGrant.self)
        assertSendableAndHashable(DebuggerLocalProcessEligibility.self)
        assertSendableAndHashable(DebuggerLocalAttachDenial.self)
        assertSendableAndHashable(DebuggerLocalProcessInstanceKey.self)
        assertSendableAndHashable(DebuggerLaunchTargetAuthority.self)
        assertSendableAndHashable(DebuggerSessionTargetOrigin.self)
        assertSendableAndHashable(DebuggerSessionTargetAuthority.self)
        assertSendableAndHashable(DebuggerLocalProcessIdentityDigest.self)
    }

    private func startTime() -> DebuggerProcessStartIdentity {
        DebuggerProcessStartIdentity(seconds: 8_765_432, microseconds: 1)!
    }

    private func codeIdentity() -> DebuggerLocalCodeIdentity {
        makeCodeIdentity()!
    }

    private func makeCodeIdentity(
        signingIdentifier: String? = "com.example.fixture",
        teamIdentifier: String? = "TEAM123456",
        codeDirectorySHA256: String? = String(repeating: "b", count: 64),
        isPlatformBinary: Bool? = false,
        signingFlags: UInt32? = 0
    ) -> DebuggerLocalCodeIdentity? {
        DebuggerLocalCodeIdentity(
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier,
            codeDirectorySHA256: codeDirectorySHA256,
            isPlatformBinary: isPlatformBinary,
            signingFlags: signingFlags
        )
    }

    private func makeIdentity(
        processID: Int32 = 4_242,
        startTime: DebuggerProcessStartIdentity? = nil,
        realUserID: UInt32 = 501,
        effectiveUserID: UInt32 = 501,
        canonicalExecutablePath: String = "/Applications/Fixture.app/Contents/MacOS/Fixture",
        executableDeviceID: UInt64 = 16,
        executableFileID: UInt64 = 32,
        executableByteCount: UInt64 = 4_096,
        executableSHA256: String = String(repeating: "a", count: 64),
        architecture: DebuggerLocalProcessArchitecture = .arm64,
        machOUUID: UUID? = UUID(uuidString: "11111111-2222-3333-4444-555555555555"),
        codeIdentity: DebuggerLocalCodeIdentity? = nil
    ) -> DebuggerLocalProcessIdentity? {
        DebuggerLocalProcessIdentity(
            processID: processID,
            startTime: startTime ?? self.startTime(),
            realUserID: realUserID,
            effectiveUserID: effectiveUserID,
            canonicalExecutablePath: canonicalExecutablePath,
            executableDeviceID: executableDeviceID,
            executableFileID: executableFileID,
            executableByteCount: executableByteCount,
            executableSHA256: executableSHA256,
            architecture: architecture,
            machOUUID: machOUUID,
            codeIdentity: codeIdentity ?? self.codeIdentity()
        )
    }

    private func makeFingerprint(
        identity: DebuggerLocalProcessIdentity,
        executableChangeTimeNanoseconds: UInt64 = 123_456
    ) -> DebuggerLocalProcessCatalogFingerprint? {
        DebuggerLocalProcessCatalogFingerprint(
            processID: identity.processID,
            startTime: identity.startTime,
            realUserID: identity.realUserID,
            effectiveUserID: identity.effectiveUserID,
            canonicalExecutablePath: identity.canonicalExecutablePath,
            executableDeviceID: identity.executableDeviceID,
            executableFileID: identity.executableFileID,
            executableByteCount: identity.executableByteCount,
            executableChangeTimeNanoseconds: executableChangeTimeNanoseconds,
            architecture: identity.architecture,
            machOUUID: identity.machOUUID,
            codeIdentity: identity.codeIdentity
        )
    }

    private func assertSendableAndHashable<T: Sendable & Hashable>(_ type: T.Type) {}
}
