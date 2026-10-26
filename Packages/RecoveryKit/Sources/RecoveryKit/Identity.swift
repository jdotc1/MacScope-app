import Foundation

public enum ImageKey {
    public static func validate(_ value: String) throws {
        guard value.utf8.count == 64, value.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) }) else {
            throw RecoveryError.invalid("image key must be lowercase SHA-256 hex")
        }
    }
}

public struct VMAddress: Codable, Hashable, Sendable {
    public let image: String
    public let value: UInt64
    public init(image: String, value: UInt64) throws {
        try ImageKey.validate(image)
        self.image = image
        self.value = value
    }
    private enum CodingKeys: String, CodingKey { case image, value }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(image: c.decode(String.self, forKey: .image),
                      value: c.decode(UInt64.self, forKey: .value))
    }
    public func adding(_ delta: Int64) throws -> VMAddress {
        let result: UInt64
        let overflow: Bool
        if delta >= 0 { (result, overflow) = value.addingReportingOverflow(UInt64(delta)) }
        else {
            // magnitude handles Int64.min without signed negation overflow.
            (result, overflow) = value.subtractingReportingOverflow(delta.magnitude)
        }
        guard !overflow else { throw RecoveryError.invalid("VM address overflow/underflow") }
        return try VMAddress(image: image, value: result)
    }
    public func relative(_ delta: Int32, nullable: Bool) throws -> VMAddress? {
        if nullable && delta == 0 { return nil }
        return try adding(Int64(delta))
    }
    public func requireSameImage(_ other: VMAddress) throws {
        guard image == other.image else { throw RecoveryError.invalid("cross-image address comparison") }
    }
}

public struct Coverage: Codable, Equatable, Sendable {
    public let population: Int
    public let resolved: Int
    public let unresolved: Int
    public let excluded: Int
    public init(population: Int, resolved: Int, unresolved: Int, excluded: Int = 0) throws {
        guard population >= 0, resolved >= 0, unresolved >= 0, excluded >= 0,
              resolved <= population, unresolved <= population - resolved,
              excluded == population - resolved - unresolved else {
            throw RecoveryError.invalid("coverage does not partition population")
        }
        self.population = population
        self.resolved = resolved
        self.unresolved = unresolved
        self.excluded = excluded
    }
    public var fraction: Double? {
        population == excluded ? nil : Double(resolved) / Double(population - excluded)
    }
    private enum CodingKeys: String, CodingKey { case population, resolved, unresolved, excluded }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(population: c.decode(Int.self, forKey: .population),
                      resolved: c.decode(Int.self, forKey: .resolved),
                      unresolved: c.decode(Int.self, forKey: .unresolved),
                      excluded: c.decodeIfPresent(Int.self, forKey: .excluded) ?? 0)
    }
}
