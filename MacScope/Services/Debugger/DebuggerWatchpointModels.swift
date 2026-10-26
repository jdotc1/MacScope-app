import Foundation

enum DebuggerWatchpointAccess: String, CaseIterable, Codable, Hashable, Sendable {
    case read
    case write
    case readWrite = "rw"
}

struct DebuggerWatchpoint: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let address: UInt64
    let size: Int
    let access: DebuggerWatchpointAccess
    let isEnabled: Bool
    let backendID: Int
}

enum DebuggerWatchpointRequest: Hashable, Sendable {
    case upsert(id: UUID, address: UInt64, size: Int, access: DebuggerWatchpointAccess, isEnabled: Bool)
    case remove(id: UUID)
    case setEnabled(id: UUID, isEnabled: Bool)
    case refresh

    func validate() throws {
        if case .upsert(_, let address, let size, _, _) = self {
            try Self.validate(address: address, size: size)
        }
    }

    static func validate(address: UInt64, size: Int) throws {
        guard [1, 2, 4, 8].contains(size) else { throw DebuggerWatchpointError.invalidSize }
        guard address % UInt64(size) == 0 else { throw DebuggerWatchpointError.misalignedAddress }
        guard !address.addingReportingOverflow(UInt64(size - 1)).overflow else {
            throw DebuggerWatchpointError.addressOverflow
        }
    }
}

struct DebuggerWatchpointUpdate: Codable, Hashable, Sendable {
    let watchpoints: [DebuggerWatchpoint]
    let error: String?
}

enum DebuggerWatchpointError: Error, Equatable, LocalizedError, Sendable {
    case invalidSize
    case misalignedAddress
    case addressOverflow
    case invalidProcess
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidSize: "Watchpoint size must be 1, 2, 4, or 8 bytes."
        case .misalignedAddress: "Watchpoint address must be aligned to its size."
        case .addressOverflow: "Watchpoint range exceeds the address space."
        case .invalidProcess: "A stopped debugger process is required."
        case .invalidResponse: "LLDB returned an invalid watchpoint response."
        }
    }
}
