import Foundation
import XCTest
@testable import MacScope

final class Phase2DurableShellBrokerIdentityTests: XCTestCase {
    func testPublicIdentityRoundTripsWithoutCapabilitySecret() throws {
        let fixture = try makeFixture()

        let encoded = try JSONEncoder().encode(fixture.identity)
        let decoded = try JSONDecoder().decode(Phase2DurableShellBrokerIdentity.self, from: encoded)

        XCTAssertEqual(decoded, fixture.identity)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(fixture.secretMarker))
        XCTAssertEqual(decoded.capabilityVerifierSHA256.count, 32)
    }

    func testExactCapabilityAuthenticatesBeforeExpiry() throws {
        let fixture = try makeFixture()

        let result = Phase2DurableShellBrokerAuthenticator.validate(
            fixture.secret.authenticationRequest(for: fixture.identity),
            identity: fixture.identity,
            now: Date(timeIntervalSince1970: 1_050)
        )

        XCTAssertTrue(result.isAuthenticated)
        XCTAssertEqual(result.issues, [])
    }

    func testAuthenticationRejectsWrongSecretAndExpiredCapability() throws {
        let fixture = try makeFixture()
        let wrongSecret = try Phase2DurableShellBrokerCapabilitySecret(bytes: Data(repeating: 0x7f, count: 32))

        let wrongSecretResult = Phase2DurableShellBrokerAuthenticator.validate(
            wrongSecret.authenticationRequest(for: fixture.identity),
            identity: fixture.identity,
            now: Date(timeIntervalSince1970: 1_050)
        )
        let expiredResult = Phase2DurableShellBrokerAuthenticator.validate(
            fixture.secret.authenticationRequest(for: fixture.identity),
            identity: fixture.identity,
            now: fixture.identity.expiresAt
        )

        XCTAssertEqual(wrongSecretResult.issues, [.capabilityVerifierMismatch])
        XCTAssertEqual(expiredResult.issues, [.expired])
    }

    func testVerifierBindsBrokerSessionCapabilityAndExactProcessStartIdentity() throws {
        let fixture = try makeFixture()
        let reusedPIDIdentity = Phase2DurableShellBrokerProcessIdentity(
            processIdentifier: fixture.identity.processIdentity.processIdentifier,
            processStartTimeUnixNanoseconds: fixture.identity.processIdentity.processStartTimeUnixNanoseconds + 1,
            executablePath: fixture.identity.processIdentity.executablePath,
            processGroupIdentifier: fixture.identity.processIdentity.processGroupIdentifier
        )
        let altered = Phase2DurableShellBrokerIdentity(
            launchRequest: fixture.identity.launchRequest,
            processIdentity: reusedPIDIdentity,
            createdAt: fixture.identity.createdAt,
            expiresAt: fixture.identity.expiresAt,
            nextTranscriptSequence: fixture.identity.nextTranscriptSequence,
            capabilityVerifierSHA256: fixture.identity.capabilityVerifierSHA256
        )

        let result = Phase2DurableShellBrokerAuthenticator.validate(
            fixture.secret.authenticationRequest(for: altered),
            identity: altered,
            now: Date(timeIntervalSince1970: 1_050)
        )

        XCTAssertEqual(result.issues, [.capabilityVerifierMismatch])
    }

    func testSecretRequiresExactlyThirtyTwoBytes() {
        XCTAssertThrowsError(try Phase2DurableShellBrokerCapabilitySecret(bytes: Data(repeating: 1, count: 31))) {
            XCTAssertEqual($0 as? Phase2DurableShellBrokerCapabilitySecretError, .invalidByteCount(actual: 31))
        }
        XCTAssertNoThrow(try Phase2DurableShellBrokerCapabilitySecret(bytes: Data(repeating: 1, count: 32)))
        XCTAssertThrowsError(try Phase2DurableShellBrokerCapabilitySecret(bytes: Data(repeating: 1, count: 33))) {
            XCTAssertEqual($0 as? Phase2DurableShellBrokerCapabilitySecretError, .invalidByteCount(actual: 33))
        }
    }

    func testLaunchRequestRejectsNULInWorkingDirectory() throws {
        let fixture = try makeFixture()
        let launch = fixture.identity.launchRequest
        let invalid = Phase2DurableShellBrokerLaunchRequest(
            brokerIncarnationID: launch.brokerIncarnationID,
            sessionID: launch.sessionID,
            capabilityID: launch.capabilityID,
            requestID: launch.requestID,
            executablePath: launch.executablePath,
            arguments: launch.arguments,
            workingDirectoryPath: "/tmp\0/redirected",
            createdAt: launch.createdAt,
            expiresAt: launch.expiresAt
        )

        XCTAssertFalse(invalid.isStructurallyValid)
    }

    private func makeFixture() throws -> (
        identity: Phase2DurableShellBrokerIdentity,
        secret: Phase2DurableShellBrokerCapabilitySecret,
        secretMarker: String
    ) {
        let secretMarker = "0123456789abcdef0123456789abcdef"
        let secret = try Phase2DurableShellBrokerCapabilitySecret(bytes: Data(secretMarker.utf8))
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let expiresAt = Date(timeIntervalSince1970: 2_000)
        let launch = Phase2DurableShellBrokerLaunchRequest(
            brokerIncarnationID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            sessionID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            capabilityID: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
            requestID: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!,
            executablePath: "/bin/zsh",
            arguments: ["-l"],
            workingDirectoryPath: "/tmp",
            createdAt: createdAt,
            expiresAt: expiresAt
        )
        let process = Phase2DurableShellBrokerProcessIdentity(
            processIdentifier: 4_321,
            processStartTimeUnixNanoseconds: 1_234_567_890,
            executablePath: "/bin/zsh",
            processGroupIdentifier: 4_321
        )
        let identity = Phase2DurableShellBrokerIdentity(
            launchRequest: launch,
            processIdentity: process,
            createdAt: createdAt,
            expiresAt: expiresAt,
            nextTranscriptSequence: 7,
            capabilityVerifierSHA256: secret.verifier(launchRequest: launch, processIdentity: process)
        )
        return (identity, secret, secretMarker)
    }
}
