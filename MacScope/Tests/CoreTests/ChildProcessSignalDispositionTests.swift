import Darwin
import MacScopeChildProcessC
import XCTest

final class ChildProcessSignalDispositionTests: XCTestCase {
    func testReadSIGCHLDDispositionSucceeds() {
        var disposition = Darwin.sigaction()
        let status = MacScopeReadSignalDisposition(SIGCHLD, &disposition)
        XCTAssertEqual(status, 0)
    }

    func testInvalidSignalPreservesSystemFailure() {
        var disposition = Darwin.sigaction()
        let status = MacScopeReadSignalDisposition(-1, &disposition)
        let reportedError = errno
        XCTAssertEqual(status, -1)
        XCTAssertEqual(reportedError, EINVAL)
    }
}
