import Foundation

public enum ValidationStage: String, Codable, CaseIterable, Sendable {
    case parse, typecheck, compile, abi, metadata, differential, boundedEquivalence, symbolicEquivalence
}
public enum ValidationOutcome: String, Codable, Sendable { case pass, fail, notRun, unknown, budgetExceeded }
public struct ValidationRecord: Codable, Sendable {
    public let stage: ValidationStage
    public let outcome: ValidationOutcome
    public let passed: Int
    public let population: Int
    public let scope: String
}
public struct CandidateValidation: Sendable {
    public private(set) var records: [ValidationStage: ValidationRecord] = [:]
    public init() {}
    public mutating func record(_ stage: ValidationStage, outcome: ValidationOutcome, passed: Int,
                                population: Int, scope: String = "") throws {
        guard passed >= 0, population >= 0, passed <= population else { throw RecoveryError.invalid("validation count") }
        guard outcome != .pass || (population > 0 && passed == population) else { throw RecoveryError.invalid("vacuous passing validation") }
        guard records[stage] == nil else { throw RecoveryError.invalid("duplicate validation stage") }
        records[stage] = ValidationRecord(stage: stage, outcome: outcome, passed: passed, population: population, scope: scope)
    }
    public var behaviorValidated: Bool {
        [ValidationStage.differential, .boundedEquivalence, .symbolicEquivalence].contains { records[$0]?.outcome == .pass }
    }
    public var summary: String {
        if records.values.contains(where: { $0.outcome == .fail }) { return "rejected" }
        if behaviorValidated { return "behavior_checked_within_stated_scope" }
        if records[.compile]?.outcome == .pass { return "compiled_only" }
        if records[.typecheck]?.outcome == .pass { return "typechecked_only" }
        if records[.parse]?.outcome == .pass { return "parsed_only" }
        return "unvalidated"
    }
}
