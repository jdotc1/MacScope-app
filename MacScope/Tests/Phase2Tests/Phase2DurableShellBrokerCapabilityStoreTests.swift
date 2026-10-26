import Foundation
import Security
import XCTest
@testable import MacScope

final class Phase2DurableShellBrokerCapabilityStoreTests: XCTestCase {
    func testSaveAddsExactLocalOnlyGenericPasswordItem() throws {
        let client = RecordingCapabilitySecurityClient()
        let store = Phase2DurableShellBrokerCapabilityStore(securityClient: client)
        let capabilityID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let bytes = Data((0..<32).map(UInt8.init))
        let secret = try Phase2DurableShellBrokerCapabilitySecret(bytes: bytes)

        try store.save(secret, for: capabilityID)

        XCTAssertEqual(client.addQueries.count, 1)
        let query = client.addQueries[0]
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(
            query[kSecAttrService as String] as? String,
            Phase2DurableShellBrokerCapabilityStore.serviceName
        )
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, capabilityID.uuidString)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(
            query[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        XCTAssertEqual(query[kSecValueData as String] as? Data, bytes)
    }

    func testSaveRejectsConflictingDuplicateWithoutReplacingExistingSecret() throws {
        let client = RecordingCapabilitySecurityClient()
        client.addStatus = errSecDuplicateItem
        client.copyStatus = errSecSuccess
        client.copyResult = Data(repeating: 0x3C, count: 32) as CFData
        let store = Phase2DurableShellBrokerCapabilityStore(securityClient: client)
        let capabilityID = UUID()
        let bytes = Data(repeating: 0xA5, count: 32)

        XCTAssertThrowsError(try store.save(try .init(bytes: bytes), for: capabilityID)) { error in
            XCTAssertEqual(error as? Phase2DurableShellBrokerCapabilityStoreError, .duplicateCapability)
        }

        XCTAssertEqual(client.copyQueries.count, 1)
        XCTAssertTrue(client.updateQueries.isEmpty)
        XCTAssertTrue(client.updateAttributes.isEmpty)
    }

    func testSaveTreatsIdenticalDuplicateAsIdempotentWithoutUpdate() throws {
        let client = RecordingCapabilitySecurityClient()
        let bytes = Data(repeating: 0xA5, count: 32)
        client.addStatus = errSecDuplicateItem
        client.copyStatus = errSecSuccess
        client.copyResult = bytes as CFData
        let store = Phase2DurableShellBrokerCapabilityStore(securityClient: client)

        try store.save(try .init(bytes: bytes), for: UUID())

        XCTAssertEqual(client.copyQueries.count, 1)
        XCTAssertTrue(client.updateQueries.isEmpty)
    }

    func testLoadReturnsExactThirtyTwoByteSecret() throws {
        let client = RecordingCapabilitySecurityClient()
        let bytes = Data(repeating: 0x6C, count: 32)
        client.copyStatus = errSecSuccess
        client.copyResult = bytes as CFData
        let store = Phase2DurableShellBrokerCapabilityStore(securityClient: client)

        let loaded = try store.load(for: UUID())

        XCTAssertEqual(loaded, try Phase2DurableShellBrokerCapabilitySecret(bytes: bytes))
        XCTAssertEqual(client.copyQueries.count, 1)
        XCTAssertEqual(client.copyQueries[0][kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(client.copyQueries[0][kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
        XCTAssertEqual(client.copyQueries[0][kSecAttrSynchronizable as String] as? Bool, false)
    }

    func testLoadReturnsNilWhenCapabilityIsAbsent() throws {
        let client = RecordingCapabilitySecurityClient()
        client.copyStatus = errSecItemNotFound
        let store = Phase2DurableShellBrokerCapabilityStore(securityClient: client)

        XCTAssertNil(try store.load(for: UUID()))
    }

    func testDeleteReportsWhetherLocalCapabilityExisted() throws {
        let client = RecordingCapabilitySecurityClient()
        client.deleteStatuses = [errSecSuccess, errSecItemNotFound]
        let store = Phase2DurableShellBrokerCapabilityStore(securityClient: client)

        XCTAssertTrue(try store.delete(for: UUID()))
        XCTAssertFalse(try store.delete(for: UUID()))
        XCTAssertTrue(client.deleteQueries.allSatisfy {
            $0[kSecAttrSynchronizable as String] as? Bool == false
        })
    }

    func testSecretRejectsEveryNonThirtyTwoByteValue() {
        XCTAssertThrowsError(try Phase2DurableShellBrokerCapabilitySecret(bytes: Data(repeating: 1, count: 31))) {
            XCTAssertEqual(
                $0 as? Phase2DurableShellBrokerCapabilitySecretError,
                .invalidByteCount(actual: 31)
            )
        }
        XCTAssertThrowsError(try Phase2DurableShellBrokerCapabilitySecret(bytes: Data(repeating: 1, count: 33)))
    }

    func testCorruptStoredValueFailsWithoutIncludingSecretMaterial() {
        let client = RecordingCapabilitySecurityClient()
        client.copyStatus = errSecSuccess
        client.copyResult = Data([0xDE, 0xAD, 0xBE, 0xEF]) as CFData
        let store = Phase2DurableShellBrokerCapabilityStore(securityClient: client)

        XCTAssertThrowsError(try store.load(for: UUID())) { error in
            XCTAssertEqual(error as? Phase2DurableShellBrokerCapabilityStoreError, .invalidStoredSecret)
            XCTAssertFalse(String(describing: error).localizedCaseInsensitiveContains("deadbeef"))
        }
    }

    func testSecretAndErrorsHaveRedactedDescriptions() throws {
        let secret = try Phase2DurableShellBrokerCapabilitySecret(bytes: Data(repeating: 0x7A, count: 32))
        let error = Phase2DurableShellBrokerCapabilityStoreError.securityFailure(
            operation: .save,
            status: errSecAuthFailed
        )

        XCTAssertEqual(String(describing: secret), "<redacted ShellBroker capability secret>")
        XCTAssertFalse(String(describing: secret).contains("7A"))
        XCTAssertEqual(String(describing: error), "ShellBroker capability save failed (status -25293)")
    }

    func testUnexpectedSecurityStatusIsTypedByOperation() throws {
        let client = RecordingCapabilitySecurityClient()
        client.addStatus = errSecInteractionNotAllowed
        let store = Phase2DurableShellBrokerCapabilityStore(securityClient: client)

        XCTAssertThrowsError(
            try store.save(
                Phase2DurableShellBrokerCapabilitySecret(bytes: Data(repeating: 1, count: 32)),
                for: UUID()
            )
        ) { error in
            XCTAssertEqual(
                error as? Phase2DurableShellBrokerCapabilityStoreError,
                .securityFailure(operation: .save, status: errSecInteractionNotAllowed)
            )
        }
    }
}

private final class RecordingCapabilitySecurityClient: Phase2DurableShellBrokerSecurityClient, @unchecked Sendable {
    var addStatus: OSStatus = errSecSuccess
    var copyStatus: OSStatus = errSecItemNotFound
    var copyResult: CFTypeRef?
    var updateStatus: OSStatus = errSecItemNotFound
    var deleteStatuses: [OSStatus] = []
    private(set) var addQueries: [[String: Any]] = []
    private(set) var copyQueries: [[String: Any]] = []
    private(set) var updateQueries: [[String: Any]] = []
    private(set) var updateAttributes: [[String: Any]] = []
    private(set) var deleteQueries: [[String: Any]] = []

    func add(_ attributes: CFDictionary) -> OSStatus {
        addQueries.append(attributes as NSDictionary as! [String: Any])
        return addStatus
    }

    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        copyQueries.append(query as NSDictionary as! [String: Any])
        result?.pointee = copyResult
        return copyStatus
    }

    func update(_ query: CFDictionary, attributesToUpdate: CFDictionary) -> OSStatus {
        updateQueries.append(query as NSDictionary as! [String: Any])
        updateAttributes.append(attributesToUpdate as NSDictionary as! [String: Any])
        return updateStatus
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        deleteQueries.append(query as NSDictionary as! [String: Any])
        return deleteStatuses.isEmpty ? errSecItemNotFound : deleteStatuses.removeFirst()
    }
}
