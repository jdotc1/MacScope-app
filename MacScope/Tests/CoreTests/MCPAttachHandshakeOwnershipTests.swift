import Foundation
import XCTest
@testable import MacScope

/// B6: synthetic operations and a manually advanced deadline; no sockets, timing, or load.
final class MCPAttachHandshakeOwnershipTests: XCTestCase {
    func testEarlyFailureRetiresDeadlineBeforeClose() {
        let resource = Resource()
        let clock = Clock()
        let connection = MCPAttachHandshakeConnection(
            shutdown: { resource.record("shutdown") }, close: { resource.record("close") }
        )
        connection.scheduleDeadline(using: clock.schedule)

        XCTAssertFalse(connection.completeHandshake(succeeded: false))
        XCTAssertEqual(resource.operations, ["close"])
        clock.advance()

        XCTAssertEqual(resource.operations, ["close"], "A retired connection must receive no deadline operation")
    }

    func testRetirementBetweenExpirySelectionAndActionPreventsLateOperation() {
        let resource = Resource()
        let clock = Clock()
        let owner = Owner()
        let connection = MCPAttachHandshakeConnection(
            shutdown: { resource.record("shutdown") }, close: { resource.record("close") },
            deadlineSelected: { owner.connection?.retire() }
        )
        owner.connection = connection
        defer { owner.connection = nil }
        connection.scheduleDeadline(using: clock.schedule)

        clock.advance()

        XCTAssertEqual(resource.operations, ["close"], "Selecting expiry cannot retain permission to act after retirement")
    }

    func testExpiryShutsDownBeforeRetirementAndClosesOnce() {
        let resource = Resource()
        let clock = Clock()
        let connection = MCPAttachHandshakeConnection(
            shutdown: { resource.record("shutdown") }, close: { resource.record("close") }
        )
        connection.scheduleDeadline(using: clock.schedule)

        clock.advance()
        XCTAssertFalse(connection.completeHandshake(succeeded: true))
        connection.retire()

        XCTAssertEqual(resource.operations, ["shutdown", "close"])
    }

    func testSuccessfulHandshakeRetiresDeadlineWithoutClosingTransferredConnection() {
        let resource = Resource()
        let clock = Clock()
        let connection = MCPAttachHandshakeConnection(
            shutdown: { resource.record("shutdown") }, close: { resource.record("close") }
        )
        connection.scheduleDeadline(using: clock.schedule)

        XCTAssertTrue(connection.completeHandshake(succeeded: true))
        clock.advance()

        XCTAssertEqual(resource.operations, [])
    }

    private final class Resource: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        var operations: [String] { lock.withLock { recorded } }
        func record(_ operation: String) { lock.withLock { recorded.append(operation) } }
    }

    private final class Clock {
        private var action: (@Sendable () -> Void)?
        func schedule(_ action: @escaping @Sendable () -> Void) { self.action = action }
        func advance() {
            let pending = action
            action = nil
            pending?()
        }
    }

    private final class Owner: @unchecked Sendable {
        var connection: MCPAttachHandshakeConnection?
    }
}
