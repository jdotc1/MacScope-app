import Foundation
import Security

enum Phase2DurableShellBrokerCapabilityStoreOperation: String, Equatable, Sendable {
    case save
    case load
    case delete
}

enum Phase2DurableShellBrokerCapabilityStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidStoredSecret
    case duplicateCapability
    case randomGenerationFailed(status: OSStatus)
    case securityFailure(operation: Phase2DurableShellBrokerCapabilityStoreOperation, status: OSStatus)

    var description: String {
        switch self {
        case .invalidStoredSecret:
            "Stored ShellBroker capability secret is invalid"
        case .duplicateCapability:
            "ShellBroker capability identifier already belongs to a different secret"
        case .randomGenerationFailed(let status):
            "ShellBroker capability generation failed (status \(status))"
        case .securityFailure(let operation, let status):
            "ShellBroker capability \(operation.rawValue) failed (status \(status))"
        }
    }
}

protocol Phase2DurableShellBrokerSecurityClient: Sendable {
    func add(_ attributes: CFDictionary) -> OSStatus
    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    func update(_ query: CFDictionary, attributesToUpdate: CFDictionary) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

struct Phase2SystemShellBrokerSecurityClient: Phase2DurableShellBrokerSecurityClient {
    func add(_ attributes: CFDictionary) -> OSStatus {
        SecItemAdd(attributes, nil)
    }

    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        SecItemCopyMatching(query, result)
    }

    func update(_ query: CFDictionary, attributesToUpdate: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributesToUpdate)
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        SecItemDelete(query)
    }
}

struct Phase2DurableShellBrokerCapabilityStore: Sendable {
    static let serviceName = "org.macscope.app.phase2.shell-broker.capability"

    private let securityClient: any Phase2DurableShellBrokerSecurityClient

    init(
        securityClient: any Phase2DurableShellBrokerSecurityClient = Phase2SystemShellBrokerSecurityClient()
    ) {
        self.securityClient = securityClient
    }

    func generateSecret() throws -> Phase2DurableShellBrokerCapabilitySecret {
        var bytes = Data(count: Phase2DurableShellBrokerCapabilitySecret.byteCount)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw Phase2DurableShellBrokerCapabilityStoreError.randomGenerationFailed(status: status)
        }
        return try Phase2DurableShellBrokerCapabilitySecret(bytes: bytes)
    }

    func save(_ secret: Phase2DurableShellBrokerCapabilitySecret, for capabilityID: UUID) throws {
        try secret.withKeychainBytes { bytes in
            try save(bytes, for: capabilityID)
        }
    }

    private func save(_ bytes: Data, for capabilityID: UUID) throws {
        var attributes = itemQuery(for: capabilityID)
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecValueData] = bytes

        let status = securityClient.add(attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            guard let existing = try load(for: capabilityID),
                  existing.withKeychainBytes({ Self.constantTimeEqual($0, bytes) })
            else { throw Phase2DurableShellBrokerCapabilityStoreError.duplicateCapability }
        default:
            throw Phase2DurableShellBrokerCapabilityStoreError.securityFailure(
                operation: .save,
                status: status
            )
        }
    }

    func load(for capabilityID: UUID) throws -> Phase2DurableShellBrokerCapabilitySecret? {
        var query = itemQuery(for: capabilityID)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = securityClient.copyMatching(query as CFDictionary, result: &result)
        switch status {
        case errSecSuccess:
            guard let bytes = result as? Data,
                  bytes.count == Phase2DurableShellBrokerCapabilitySecret.byteCount
            else {
                throw Phase2DurableShellBrokerCapabilityStoreError.invalidStoredSecret
            }
            return try Phase2DurableShellBrokerCapabilitySecret(bytes: bytes)
        case errSecItemNotFound:
            return nil
        default:
            throw Phase2DurableShellBrokerCapabilityStoreError.securityFailure(
                operation: .load,
                status: status
            )
        }
    }

    @discardableResult
    func delete(for capabilityID: UUID) throws -> Bool {
        let status = securityClient.delete(itemQuery(for: capabilityID) as CFDictionary)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw Phase2DurableShellBrokerCapabilityStoreError.securityFailure(
                operation: .delete,
                status: status
            )
        }
    }

    private func itemQuery(for capabilityID: UUID) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.serviceName,
            kSecAttrAccount: capabilityID.uuidString,
            kSecAttrSynchronizable: false,
        ]
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}
