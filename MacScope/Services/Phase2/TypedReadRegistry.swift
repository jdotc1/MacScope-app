import Foundation

/// The closed, app-owned inventory of provider-neutral Phase 2 read operations.
///
/// The registry exposes only the frozen v1 inventory and returns an app-issued
/// authorization binding one exact request to its canonical descriptor.
struct TypedReadRegistry: Sendable {
    /// The bounded subset admitted by the existing CLI/MCP adapters. This does
    /// not expand the provider-neutral registry or confer authorizing authority.
    enum ExternalOperation: String, CaseIterable, Sendable {
        case workspaceSummary = "workspace.summary"
        case applicationGraphSummary = "application.graph.summary"
        case functionReview = "function.review"

        var operationID: Phase2ReadOperationID { .init(rawValue: rawValue) }
    }

    static let schemaVersion = Phase2ReadRegistryVersion.v1

    static let descriptors: [Phase2ReadOperationDescriptor] = [
        .init(registryVersion: .v1, id: .reaResultsList, operationVersion: .v1, effects: [.a1]),
        .init(registryVersion: .v1, id: .reaResultsGet, operationVersion: .v1, effects: [.a1]),
        Phase2ReadOperationDescriptor(
            registryVersion: .v1,
            id: .workspaceSummary,
            operationVersion: .v1,
            effects: [.a1]
        ),
        Phase2ReadOperationDescriptor(
            registryVersion: .v1,
            id: .selectionExplain,
            operationVersion: .v1,
            effects: [.a1]
        ),
        Phase2ReadOperationDescriptor(
            registryVersion: .v1,
            id: .functionReview,
            operationVersion: .v1,
            effects: [.a1, .a2]
        ),
        Phase2ReadOperationDescriptor(
            registryVersion: .v1,
            id: .functionCallSites,
            operationVersion: .v1,
            effects: [.a1]
        ),
        Phase2ReadOperationDescriptor(
            registryVersion: .v1,
            id: .applicationGraphSummary,
            operationVersion: .v1,
            effects: [.a1]
        ),
        Phase2ReadOperationDescriptor(
            registryVersion: .v1,
            id: .decompilerNativeResult,
            operationVersion: .v1,
            effects: [.a1]
        ),
        Phase2ReadOperationDescriptor(
            registryVersion: .v1,
            id: .decompilerMacScopeResult,
            operationVersion: .v1,
            effects: [.a1]
        ),
        Phase2ReadOperationDescriptor(
            registryVersion: .v1,
            id: .decompilerCompare,
            operationVersion: .v1,
            effects: [.a1]
        ),
    ]

    func descriptor(for id: Phase2ReadOperationID) -> Phase2ReadOperationDescriptor? {
        Self.descriptors.first { $0.id == id }
    }

    /// Returns the app's authorization decision for a proposed typed read.
    ///
    func authorize(
        _ request: Phase2ReadRequest,
        authorizingPrincipal: Phase2Principal
    ) -> Phase2ReadAuthorizationDecision {
        guard authorizingPrincipal == .app else {
            return .rejected(.unauthorized)
        }

        guard request.descriptor.registryVersion == Self.schemaVersion,
              request.descriptor.operationVersion == .v1,
              let canonicalDescriptor = descriptor(for: request.descriptor.id)
        else {
            return .rejected(.unsupported)
        }

        guard request.descriptor == canonicalDescriptor else {
            return .rejected(.unauthorized)
        }

        guard request.limits.isValid else {
            return .rejected(.limitExceeded)
        }

        let isBoundedExternalProposal = (request.proposingPrincipal == .cli
                || request.proposingPrincipal == .mcp)
            && ExternalOperation(rawValue: request.descriptor.id.rawValue) != nil
        guard isBoundedExternalProposal
                || request.proposingPrincipal == .model
                || request.proposingPrincipal == .app
                || request.proposingPrincipal == .human,
              request.proposingPrincipal.validationIssues.isEmpty
        else {
            return .rejected(.unauthorized)
        }

        guard request.isValid else {
            return .rejected(.unauthorized)
        }

        guard let encoded = try? JSONEncoder().encode(request),
              encoded.count <= request.limits.encodedRequestBytes
        else {
            return .rejected(.limitExceeded)
        }

        let authorization = Phase2ReadAuthorization(
            request: request,
            canonicalDescriptor: canonicalDescriptor,
            authorizingPrincipal: authorizingPrincipal,
            approvedLimits: request.limits
        )
        guard authorization.isValid else {
            return .rejected(.unauthorized)
        }
        return .authorized(authorization)
    }
}
