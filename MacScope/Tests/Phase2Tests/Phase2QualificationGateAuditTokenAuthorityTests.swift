import Darwin
import Foundation
import Security
import XCTest
@testable import MacScope

final class Phase2QualificationGateAuditTokenAuthorityTests: XCTestCase {
    func testCapturePreservesAllOpaqueTokenBytesAndUsesTokenBoundPath() throws {
        let backend = Backend()
        let authority = Phase2QualificationGateAuditTokenAuthority(backend: backend)
        let capture = try authority.capture(processID: 123).get()
        XCTAssertEqual(capture.processID, 123)
        XCTAssertEqual(capture.tokenBytes, backend.token)
        XCTAssertEqual(capture.canonicalExecutablePath, "/bin/ls")
        XCTAssertEqual(backend.pathTokens, [backend.token, backend.token])
        XCTAssertEqual(backend.readCount, 3)
        XCTAssertEqual(backend.released, [42])
    }

    func testInvalidPIDAndDeniedTaskNameNeverAttemptTokenOrPIDFallback() {
        let backend = Backend()
        let authority = Phase2QualificationGateAuditTokenAuthority(backend: backend)
        for pid in [-1, 0, 1] as [Int32] {
            assertFailure(authority.capture(processID: pid), .invalidProcessID)
        }
        XCTAssertEqual(backend.acquired, [])
        backend.acquireFailure = true
        assertFailure(authority.capture(processID: 123), .taskNameUnavailable)
        XCTAssertEqual(backend.readCount, 0)
        XCTAssertEqual(backend.released, [])
    }

    func testNullAndDeadTaskRightsAreUnavailable() {
        for port in [mach_port_t(MACH_PORT_NULL), mach_port_t.max] {
            let backend = Backend()
            backend.port = port
            assertFailure(Phase2QualificationGateAuditTokenAuthority(backend: backend)
                .capture(processID: 123), .taskNameUnavailable)
            XCTAssertEqual(backend.readCount, 0)
            XCTAssertEqual(backend.released, [])
        }
    }

    func testShortOversizedAndUnreadableTokensFailAndReleaseRight() {
        for count in [0, MemoryLayout<audit_token_t>.size - 1,
                      MemoryLayout<audit_token_t>.size + 1] {
            let backend = Backend()
            backend.tokens = [Data(repeating: 7, count: count)]
            assertFailure(Phase2QualificationGateAuditTokenAuthority(backend: backend)
                .capture(processID: 123), .tokenSizeInvalid)
            XCTAssertEqual(backend.released, [42])
        }
        let backend = Backend()
        backend.tokenFailure = true
        assertFailure(Phase2QualificationGateAuditTokenAuthority(backend: backend)
            .capture(processID: 123), .tokenUnavailable)
        XCTAssertEqual(backend.released, [42])
    }

    func testWrongTokenPIDFailsAndReleasesRight() {
        let backend = Backend()
        backend.tokenPID = 124
        assertFailure(Phase2QualificationGateAuditTokenAuthority(backend: backend)
            .capture(processID: 123), .tokenProcessMismatch)
        XCTAssertEqual(backend.pathTokens, [])
        XCTAssertEqual(backend.released, [42])
    }

    func testEveryTokenByteIsComparedIncludingFinalReadAfterSecondPath() {
        for changedIndex in 0..<MemoryLayout<audit_token_t>.size {
            for readIndex in [1, 2] {
                let backend = Backend()
                var changed = backend.token
                changed[changedIndex] ^= 1
                backend.tokens = [backend.token, backend.token, backend.token]
                backend.tokens[readIndex] = changed
                assertFailure(Phase2QualificationGateAuditTokenAuthority(backend: backend)
                    .capture(processID: 123), .identityChanged)
                XCTAssertEqual(backend.released, [42])
            }
        }
    }

    func testMissingNoncanonicalAndChangedPathsFailClosed() {
        for path in ["relative", "/bin/../bin/ls", "/bin/ls\0extra"] {
            let backend = Backend()
            backend.paths = [path]
            assertFailure(Phase2QualificationGateAuditTokenAuthority(backend: backend)
                .capture(processID: 123), .pathUnavailable)
            XCTAssertEqual(backend.released, [42])
        }
        let missing = Backend()
        missing.pathFailure = true
        assertFailure(Phase2QualificationGateAuditTokenAuthority(backend: missing)
            .capture(processID: 123), .pathUnavailable)
        XCTAssertEqual(missing.released, [42])
        let changed = Backend()
        changed.paths = ["/bin/ls", "/bin/cat"]
        assertFailure(Phase2QualificationGateAuditTokenAuthority(backend: changed)
            .capture(processID: 123), .identityChanged)
    }

    func testReleaseFailureCannotProduceSuccessfulCapture() {
        let backend = Backend()
        backend.releaseSucceeds = false
        assertFailure(Phase2QualificationGateAuditTokenAuthority(backend: backend)
            .capture(processID: 123), .portReleaseFailed)
        XCTAssertEqual(backend.released, [42])
    }

    func testDynamicValidationBindsExactTokenAndRechecksAfterwards() throws {
        let backend = Backend()
        let authority = Phase2QualificationGateAuditTokenAuthority(backend: backend)
        let expected = try authority.capture(processID: 123).get()
        let result = try authority.validate(expected, requirement: requirement()).get()
        XCTAssertEqual(result, expected)
        XCTAssertEqual(backend.validatedTokens, [expected.tokenBytes])
        XCTAssertEqual(backend.released.count, 3)
    }

    func testDynamicSignatureFailureDoesNotDowngrade() throws {
        let backend = Backend()
        let authority = Phase2QualificationGateAuditTokenAuthority(backend: backend)
        let expected = try authority.capture(processID: 123).get()
        backend.signatureSucceeds = false
        assertFailure(authority.validate(expected, requirement: try requirement()), .signatureUnavailable)
        XCTAssertEqual(backend.validatedTokens.count, 1)
        XCTAssertEqual(backend.released.count, 2)
    }

    func testDriftBeforeOrAfterDynamicValidationFails() throws {
        for afterValidation in [false, true] {
            let backend = Backend()
            let authority = Phase2QualificationGateAuditTokenAuthority(backend: backend)
            let expected = try authority.capture(processID: 123).get()
            if afterValidation { backend.changeOnValidation = true }
            else { backend.token[0] ^= 1 }
            assertFailure(authority.validate(expected, requirement: try requirement()), .identityChanged)
            XCTAssertEqual(backend.validatedTokens.count, afterValidation ? 1 : 0)
        }
    }

    private func assertFailure(_ result: Result<Phase2QualificationGateAuditTokenCapture,
        Phase2QualificationGateAuditTokenFailure>, _ expected: Phase2QualificationGateAuditTokenFailure,
        file: StaticString = #filePath, line: UInt = #line) {
        switch result {
        case .success: XCTFail("Unexpected authority", file: file, line: line)
        case .failure(let actual): XCTAssertEqual(actual, expected, file: file, line: line)
        }
    }

    private func requirement() throws -> SecRequirement {
        var value: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString("anchor apple" as CFString,
            SecCSFlags(), &value), errSecSuccess)
        return try XCTUnwrap(value)
    }

    private final class Backend: Phase2QualificationGateAuditTokenBackend {
        // Opaque fixture bytes; no assumptions about audit_token_t field positions.
        var token = Data(repeating: 7, count: MemoryLayout<audit_token_t>.size)
        var tokens: [Data] = []
        var paths: [String] = []
        var tokenPID: Int32 = 123
        var port: mach_port_t = 42
        var acquireFailure = false
        var tokenFailure = false
        var pathFailure = false
        var signatureSucceeds = true
        var releaseSucceeds = true
        var changeOnValidation = false
        var acquired: [Int32] = []
        var released: [mach_port_t] = []
        var pathTokens: [Data] = []
        var validatedTokens: [Data] = []
        var readCount = 0

        func acquireTaskName(processID: Int32) throws -> mach_port_t {
            acquired.append(processID)
            if acquireFailure { throw Phase2QualificationGateAuditTokenFailure.taskNameUnavailable }
            return port
        }
        func readToken(port: mach_port_t) throws -> Data {
            readCount += 1
            if tokenFailure { throw Phase2QualificationGateAuditTokenFailure.tokenUnavailable }
            return tokens.isEmpty ? token : tokens.removeFirst()
        }
        func processID(token: Data) throws -> Int32 { tokenPID }
        func executablePath(token: Data) throws -> String {
            pathTokens.append(token)
            if pathFailure { throw Phase2QualificationGateAuditTokenFailure.pathUnavailable }
            return paths.isEmpty ? "/bin/ls" : paths.removeFirst()
        }
        func validateDynamicCode(token: Data, requirement: SecRequirement) -> Bool {
            validatedTokens.append(token)
            if changeOnValidation { self.token[0] ^= 1 }
            return signatureSucceeds
        }
        func releaseTaskName(port: mach_port_t) -> Bool {
            released.append(port)
            return releaseSucceeds
        }
    }
}
