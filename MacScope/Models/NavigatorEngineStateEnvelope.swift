import Foundation

/// One image slot's persisted navigator-engine store inside the workspace manifest
/// (`WorkspacePackageManifest.navigatorState`).
///
/// `state` is the canonical JSON of a contract v1 `NavigatorEngineState` record, kept as a string so
/// the manifest's typed key-structure check never descends into contract records (whose optional
/// keys are the contract's business, not the manifest codec's). `generation` is the generation the
/// state was last landed under; `staleGeneration` carries the stale marks the v1 record has no
/// field for.
struct NavigatorEngineStateEnvelope: Codable, Equatable, Sendable {
    static let currentSchema = 1
    /// Per-slot cap on the canonical state text. The whole manifest is capped at
    /// `MacScopeDocumentPackage.maximumManifestBytes`; one slot never takes more than a quarter of it.
    static let maximumStateBytes = 16 * 1_024 * 1_024

    enum Failure: Error, Equatable, Sendable {
        case unsupportedSchema(Int)
        case stateTooLarge(Int)
        case undecodableState(String)
        case invalidState([String])
        case invalidStaleMark(String)
    }

    var schema: Int
    var state: String
    var generation: NavigatorGeneration?
    var staleGeneration: [String]?

    init(schema: Int = NavigatorEngineStateEnvelope.currentSchema, state: String,
         generation: NavigatorGeneration? = nil, staleGeneration: [String]? = nil) {
        self.schema = schema
        self.state = state
        self.generation = generation
        self.staleGeneration = staleGeneration
    }

    /// Captures `store` for persistence. Stale marks are written only when there are any, so a store
    /// without fencing history encodes exactly like a plain v1 state.
    init(store: NavigatorContractStore, generation: NavigatorGeneration?) throws {
        let text = try NavigatorJSONCanonical.encode(store.state().json)
        let stale = Array(store.staleGeneration).uniqueSortedByScalars()
        self.init(state: text, generation: generation, staleGeneration: stale.isEmpty ? nil : stale)
    }

    /// Schema and size checks that need no parse.
    func validateShape() throws {
        guard schema == Self.currentSchema else { throw Failure.unsupportedSchema(schema) }
        let bytes = state.utf8.count
        guard bytes <= Self.maximumStateBytes else { throw Failure.stateTooLarge(bytes) }
        for id in staleGeneration ?? [] where !NavigatorContractValidator.isFactID(id) {
            throw Failure.invalidStaleMark(id)
        }
    }

    /// Parses and validates the contract record. Validation `reasons` refuse it; canonical-ref
    /// `warnings` (refs written before the canonical grammar) are returned, never fatal.
    func decodedState() throws -> (state: NavigatorEngineState, warnings: [String]) {
        try validateShape()
        let json: NavigatorJSONValue
        do {
            json = try NavigatorJSONParser.parse(state)
        } catch {
            throw Failure.undecodableState("\(error)")
        }
        let report = NavigatorContractValidator.validate(json)
        guard report.reasons.isEmpty else { throw Failure.invalidState(report.reasons) }
        do {
            return (try NavigatorEngineState(json: json), report.warnings)
        } catch let error as NavigatorContractError {
            throw Failure.invalidState(error.reasons)
        }
    }
}
