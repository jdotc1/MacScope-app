import Foundation

/// Closed source capability registry. Recognizing an identifier never enables execution.
/// Existing schema and protocol versions describe the scalar profile exclusively; adding a
/// profile requires a new capability rather than interpreting old bytes with new semantics.
enum ReconstructionSourceProfile: String, CaseIterable, Sendable {
    case scalarU32V1 = "arm64-c-u32-saturating-increment-v1"
    case adler32RecordV1 = "arm64-c-adler32-combine-record-v1"

    enum Failure: Error, Equatable, Sendable { case unsupportedProfile, disabledProfile, unsupportedVersion }

    static func enabled(_ identifier: String) throws -> Self {
        guard let profile = Self(rawValue: identifier) else { throw Failure.unsupportedProfile }
        guard profile == .scalarU32V1 else { throw Failure.disabledProfile }
        return profile
    }

    /// Call only after authenticating an existing source operation/record. Historical source
    /// jobs predate the optional intent field; absence there means scalar, never ordinary-job
    /// source activation. A present identifier must pass the same closed enabled dispatch.
    static func retainedSourceProfile(_ identifier: String?) throws -> Self {
        try enabled(identifier ?? Self.scalarU32V1.rawValue)
    }

    static func admits(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        return (try? enabled(identifier)) != nil
    }

    func requirePayloadVersion(_ version: Int) throws {
        _ = try Self.enabled(rawValue)
        guard version == 1 else { throw Failure.unsupportedVersion }
    }

    func scalarInputs() throws -> [UInt32] {
        _ = try Self.enabled(rawValue)
        var values: [UInt32] = [0, 1, 41, UInt32.max - 1, UInt32.max]
        var state: UInt32 = 0x4d534331
        for _ in 0..<32 {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            if !values.contains(state) { values.append(state) }
        }
        return values
    }

    /// Schema 1 has no profile field. Its absence is an explicit scalar-only wire contract.
    static func executionProfile(schemaVersion: Int) -> Self? {
        switch schemaVersion {
        case 1: .scalarU32V1
        default: nil
        }
    }

    static func inferenceProfile(protocolVersion: Int) -> Self? {
        switch protocolVersion {
        case 10: .scalarU32V1
        default: nil
        }
    }
}
