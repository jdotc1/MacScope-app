import XCTest
@testable import MacScope

final class Phase2ReadKernelTests: XCTestCase {
    func testRegistryInventoryIsExactAndVersioned() {
        XCTAssertEqual(TypedReadRegistry.schemaVersion, .v1)
        XCTAssertEqual(TypedReadRegistry.descriptors, [
            descriptor(.reaResultsList, effects: [.a1]),
            descriptor(.reaResultsGet, effects: [.a1]),
            descriptor(.workspaceSummary, effects: [.a1]),
            descriptor(.selectionExplain, effects: [.a1]),
            descriptor(.functionReview, effects: [.a1, .a2]),
            descriptor(.functionCallSites, effects: [.a1]),
            descriptor(.applicationGraphSummary, effects: [.a1]),
            descriptor(.decompilerNativeResult, effects: [.a1]),
            descriptor(.decompilerMacScopeResult, effects: [.a1]),
            descriptor(.decompilerCompare, effects: [.a1]),
        ])
        XCTAssertEqual(Phase2ReadOperationID.allKnown, Set(TypedReadRegistry.descriptors.map(\.id)))
    }

    func testOnlyAppMayAuthorizeValidModelProposal() {
        let registry = TypedReadRegistry()
        let request = makeRequest()
        XCTAssertEqual(registry.authorize(request, authorizingPrincipal: .app), .authorized(authorization(for: request)))
        for principal in [Phase2Principal.human, .model, .aiWorker, .analysisWorker, .mcp, .cli] {
            XCTAssertEqual(registry.authorize(request, authorizingPrincipal: principal), .rejected(.unauthorized))
        }
    }

    func testUnknownOperationOrVersionIsUnsupported() {
        let registry = TypedReadRegistry()
        XCTAssertEqual(registry.authorize(makeRequest(descriptor: descriptor(.init(rawValue: "unknown"), effects: [.a1])), authorizingPrincipal: .app), .rejected(.unsupported))
        XCTAssertEqual(registry.authorize(makeRequest(descriptor: .init(registryVersion: .init(rawValue: 2), id: .workspaceSummary, operationVersion: .v1, effects: [.a1])), authorizingPrincipal: .app), .rejected(.unsupported))
        XCTAssertEqual(registry.authorize(makeRequest(descriptor: .init(registryVersion: .v1, id: .workspaceSummary, operationVersion: .init(rawValue: 2), effects: [.a1])), authorizingPrincipal: .app), .rejected(.unsupported))
    }

    func testEffectEscalationIsUnauthorized() {
        let request = makeRequest(descriptor: descriptor(.workspaceSummary, effects: [.a1, .a3]))
        XCTAssertFalse(request.isValid)
        XCTAssertEqual(TypedReadRegistry().authorize(request, authorizingPrincipal: .app), .rejected(.unauthorized))
    }

    func testRegistryAuthorizesOnlyTheExactOperationSubjectPair() {
        let fixture = Fixture()
        let location = Phase2ReadStaticLocation(
            image: fixture.image,
            domain: .imageVirtualAddress,
            address: 0x1000
        )
        let function = Phase2ReadFunctionRange(
            image: fixture.image,
            start: 0x1000,
            endExclusive: 0x1010
        )
        let registry = TypedReadRegistry()

        let valid: [(Phase2ReadOperationDescriptor, Phase2ReadSubject)] = [
            (descriptor(.workspaceSummary, effects: [.a1]), .workspace(fixture.workspace)),
            (descriptor(.selectionExplain, effects: [.a1]), .staticLocation(location)),
            (descriptor(.functionReview, effects: [.a1, .a2]), .functionRange(function)),
            (descriptor(.applicationGraphSummary, effects: [.a1]), .workspace(fixture.workspace)),
            (descriptor(.decompilerNativeResult, effects: [.a1]), .functionRange(function)),
            (descriptor(.decompilerMacScopeResult, effects: [.a1]), .functionRange(function)),
            (descriptor(.decompilerCompare, effects: [.a1]), .functionRange(function)),
        ]
        for (operation, subject) in valid {
            guard case .authorized = registry.authorize(
                makeRequest(descriptor: operation, subject: subject),
                authorizingPrincipal: .app
            ) else {
                return XCTFail("Expected canonical operation-subject pair to authorize")
            }
        }

        let invalid: [(Phase2ReadOperationDescriptor, Phase2ReadSubject)] = [
            (descriptor(.workspaceSummary, effects: [.a1]), .staticLocation(location)),
            (descriptor(.selectionExplain, effects: [.a1]), .functionRange(function)),
            (descriptor(.functionReview, effects: [.a1, .a2]), .workspace(fixture.workspace)),
            (descriptor(.applicationGraphSummary, effects: [.a1]), .staticLocation(location)),
            (descriptor(.decompilerNativeResult, effects: [.a1]), .workspace(fixture.workspace)),
            (descriptor(.decompilerMacScopeResult, effects: [.a1]), .staticLocation(location)),
            (descriptor(.decompilerCompare, effects: [.a1]), .workspace(fixture.workspace)),
        ]
        for (operation, subject) in invalid {
            XCTAssertEqual(
                registry.authorize(
                    makeRequest(descriptor: operation, subject: subject),
                    authorizingPrincipal: .app
                ),
                .rejected(.unauthorized)
            )
        }
    }

    func testLimitsAcceptInclusiveMaximumAndRejectEveryInvalidExtreme() {
        XCTAssertTrue(Phase2ReadLimits.maximum.isValid)
        for invalid in [0, -1, Int.min, Int.max] {
            XCTAssertFalse(limits(encodedRequestBytes: invalid).isValid)
            XCTAssertFalse(limits(encodedResultBytes: invalid).isValid)
            XCTAssertFalse(limits(structuralNesting: invalid).isValid)
            XCTAssertFalse(limits(objectMembers: invalid).isValid)
            XCTAssertFalse(limits(arrayItems: invalid).isValid)
            XCTAssertFalse(limits(stringBytes: invalid).isValid)
            XCTAssertFalse(limits(pageItems: invalid).isValid)
        }
        XCTAssertEqual(TypedReadRegistry().authorize(makeRequest(limits: limits(pageItems: 257)), authorizingPrincipal: .app), .rejected(.limitExceeded))
    }

    func testExactOwnerAndDeclaredFacetsAreCurrent() {
        let fixture = Fixture()
        XCTAssertTrue(fixture.precondition.compared(to: fixture.current).isCurrent)
    }

    func testSameVASiblingAndReplacementOwnersNeverCrossBind() {
        let fixture = Fixture()
        let sibling = fixture.image(slot: 1, binary: 3, generation: 1)
        XCTAssertNotEqual(
            Phase2ReadStaticLocation(image: fixture.image, domain: .imageVirtualAddress, address: 0x1000),
            Phase2ReadStaticLocation(image: sibling, domain: .imageVirtualAddress, address: 0x1000)
        )
        for replacement in [sibling, fixture.image(slot: 0, binary: 4, generation: 2)] {
            let comparison = fixture.precondition.compared(to: fixture.current(image: replacement))
            XCTAssertFalse(comparison.isOwnerCurrent)
            XCTAssertFalse(comparison.isCurrent)
        }
    }

    func testLegacyDeclaredFacetRevisionChangeIsStale() {
        let fixture = Fixture()
        XCTAssertTrue(fixture.precondition.compared(to: fixture.current(symbolRevision: 8)).isStale)
    }

    func testFacetFingerprintChangeIsStaleEvenWhenRevisionMatches() {
        let oldDigest = String(repeating: "a", count: 64)
        let newDigest = String(repeating: "b", count: 64)
        let fixture = Fixture(requiredFacetFingerprint: oldDigest)
        let changedFingerprint = fixture.current(
            currentFacetFingerprint: newDigest
        )
        let comparison = fixture.precondition.compared(to: changedFingerprint)

        XCTAssertTrue(comparison.isOwnerCurrent)
        XCTAssertTrue(comparison.isStale)
        XCTAssertTrue(comparison.mismatches.contains(
            .facetFingerprintMismatch(
                dependency: fixture.precondition.dependencies[0],
                actual: newDigest
            )
        ))
    }

    func testUnrelatedOverallFingerprintChangeIsCurrentWhenDeclaredFacetFingerprintMatches() {
        let facetDigest = String(repeating: "c", count: 64)
        let fixture = Fixture(fingerprint: String(repeating: "a", count: 64), requiredFacetFingerprint: facetDigest)
        let changedOverall = fixture.current(image: fixture.image(
            analysis: fixture.image.analysisRevision + 1,
            fingerprint: String(repeating: "b", count: 64)
        ), currentFacetFingerprint: facetDigest)

        XCTAssertTrue(fixture.precondition.compared(to: changedOverall).isCurrent)
    }

    func testNonStrictFreshnessIgnoresWorkspaceAndUnrelatedFacetChanges() {
        let fixture = Fixture()
        let changed = fixture.current(workspaceRevision: 999, extraFacetRevision: 999)
        XCTAssertTrue(fixture.precondition.compared(to: changed).isCurrent)
    }

    func testStrictWorkspaceCutRejectsWorkspaceRevisionChange() {
        let fixture = Fixture(strict: true)
        XCTAssertTrue(fixture.precondition.compared(to: fixture.current(workspaceRevision: 12)).isStale)
    }

    func testCancelledInvocationRejectsLateCandidateAndPreservesFirstTerminal() {
        let fixture = Fixture()
        var acceptor = Phase2EvidenceAcceptor()
        let invocation = id(20)
        XCTAssertEqual(acceptor.cancel(invocationID: invocation, sequence: 1).disposition, .cancelled)
        let late = fixture.candidate(invocation: invocation, sequence: 2)
        XCTAssertEqual(acceptor.evaluate(late, authorization: fixture.authorization(for: late), against: fixture.current).disposition, .duplicate)
        XCTAssertEqual(acceptor.terminalOutcome(for: invocation)?.disposition, .cancelled)
        XCTAssertEqual(acceptor.terminalCount, 1)
    }

    func testAcceptedInvocationRejectsDuplicateAndPreservesFirstEvidence() {
        let fixture = Fixture()
        var acceptor = Phase2EvidenceAcceptor()
        let invocation = id(21)
        let first = fixture.candidate(evidence: id(22), invocation: invocation, sequence: 1)
        XCTAssertEqual(acceptor.evaluate(
            first,
            authorization: fixture.authorization(for: first),
            against: fixture.current,
            acceptingEvidenceID: id(24)
        ).disposition, .accepted)
        let duplicate = fixture.candidate(evidence: id(23), invocation: invocation, sequence: 2)
        XCTAssertEqual(acceptor.evaluate(duplicate, authorization: fixture.authorization(for: duplicate), against: fixture.current).disposition, .duplicate)
        XCTAssertEqual(acceptor.terminalOutcome(for: invocation)?.evidenceIDs, [id(24)])
    }

    func testEvidenceFailsClosedForCancellationStalenessOwnerAndPrincipal() {
        let fixture = Fixture()
        let cases: [(Phase2ReadEvidenceCandidate, Phase2ReadCurrentState, Phase2ReadDisposition)] = [
            (fixture.candidate(cancelled: true), fixture.current, .cancelled),
            (fixture.candidate(precondition: Fixture(strict: true).precondition), fixture.current(workspaceRevision: 12), .stale),
            (fixture.candidate(), fixture.current(image: fixture.image(slot: 0, binary: 9, generation: 2)), .ownerMismatch),
            (fixture.candidate(principal: .model), fixture.current, .unauthorized),
            (fixture.candidate(operation: .init(rawValue: "unknown")), fixture.current, .unsupported),
        ]
        for (candidate, state, expected) in cases {
            var acceptor = Phase2EvidenceAcceptor()
            XCTAssertEqual(acceptor.evaluate(candidate, authorization: fixture.authorization(for: candidate), against: state).disposition, expected)
        }
    }

    func testConflictPreservesEveryContradictoryClaim() {
        let fixture = Fixture()
        let claims = [
            Phase2ReadConflictClaim(claimID: id(30), producingPrincipal: .app, value: .text("left"), citations: [fixture.citation], contentDigest: "left"),
            Phase2ReadConflictClaim(claimID: id(31), producingPrincipal: .analysisWorker, value: .text("right"), citations: [fixture.citation], contentDigest: "right"),
        ]
        let conflict = Phase2ReadConflict(conflictID: id(32), claims: claims)
        var acceptor = Phase2EvidenceAcceptor()
        let candidate = fixture.candidate(data: .conflict(conflict))
        let outcome = acceptor.evaluate(candidate, authorization: fixture.authorization(for: candidate), against: fixture.current)
        XCTAssertEqual(outcome.disposition, .conflict)
        XCTAssertEqual(outcome.conflicts, [conflict])
        XCTAssertEqual(outcome.conflicts.first?.claims, claims)
    }

    func testSelectionCitationCannotEscapeAuthorizedStaticLocation() {
        let fixture = Fixture()
        let location = Phase2ReadStaticLocation(
            image: fixture.image,
            domain: .imageVirtualAddress,
            address: 0x1000
        )
        let request = makeRequest(
            descriptor: descriptor(.selectionExplain, effects: [.a1]),
            subject: .staticLocation(location)
        )
        guard case let .authorized(authorization) = TypedReadRegistry().authorize(
            request,
            authorizingPrincipal: .app
        ) else {
            return XCTFail("Expected selection read authorization")
        }

        let exactCitation = Phase2ReadCitation(
            id: id(70),
            target: .staticLocation(location),
            dependencies: fixture.precondition.dependencies
        )
        let exact = fixture.candidate(
            invocation: request.invocationID,
            operation: .selectionExplain,
            citations: [exactCitation]
        )
        var exactAcceptor = Phase2EvidenceAcceptor()
        XCTAssertEqual(
            exactAcceptor.evaluate(exact, authorization: authorization, against: fixture.current).disposition,
            .accepted
        )

        let escapedCitation = Phase2ReadCitation(
            id: id(71),
            target: .staticLocation(.init(
                image: fixture.image,
                domain: .imageVirtualAddress,
                address: 0x1004
            )),
            dependencies: fixture.precondition.dependencies
        )
        let escaped = fixture.candidate(
            evidence: id(72),
            invocation: request.invocationID,
            operation: .selectionExplain,
            citations: [escapedCitation]
        )
        var escapedAcceptor = Phase2EvidenceAcceptor()
        XCTAssertEqual(
            escapedAcceptor.evaluate(escaped, authorization: authorization, against: fixture.current).disposition,
            .unauthorized
        )
    }
}

private func id(_ byte: UInt8) -> UUID {
    UUID(uuid: (byte, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, byte))
}

private func descriptor(_ id: Phase2ReadOperationID, effects: Set<Phase2EffectClass>) -> Phase2ReadOperationDescriptor {
    .init(registryVersion: .v1, id: id, operationVersion: .v1, effects: effects)
}

private func limits(
    encodedRequestBytes: Int = 65_536, encodedResultBytes: Int = 1_048_576,
    structuralNesting: Int = 12, objectMembers: Int = 64, arrayItems: Int = 1_024,
    stringBytes: Int = 65_536, pageItems: Int = 256
) -> Phase2ReadLimits {
    .init(encodedRequestBytes: encodedRequestBytes, encodedResultBytes: encodedResultBytes,
          structuralNesting: structuralNesting, objectMembers: objectMembers,
          arrayItems: arrayItems, stringBytes: stringBytes, pageItems: pageItems)
}

private func makeRequest(
    descriptor: Phase2ReadOperationDescriptor = descriptor(.workspaceSummary, effects: [.a1]),
    subject: Phase2ReadSubject? = nil,
    limits: Phase2ReadLimits = .maximum
) -> Phase2ReadRequest {
    let fixture = Fixture()
    return .init(requestID: id(40), invocationID: id(41), sequence: 1, proposingPrincipal: .model,
                 descriptor: descriptor, subject: subject ?? .workspace(fixture.workspace),
                 precondition: fixture.precondition, limits: limits)
}

private func authorization(for request: Phase2ReadRequest) -> Phase2ReadAuthorization {
    .init(request: request, canonicalDescriptor: descriptor(request.descriptor.id, effects: request.descriptor.effects),
          authorizingPrincipal: .app, approvedLimits: request.limits)
}

private struct Fixture {
    let document = Phase2ReadDocumentIdentity(instanceID: id(1))
    let workspace: Phase2ReadWorkspaceIdentity
    let image: Phase2ReadImageIdentity
    let precondition: Phase2ReadPrecondition
    let current: Phase2ReadCurrentState

    init(
        strict: Bool = false,
        fingerprint: String? = nil,
        requiredFacetFingerprint: String? = nil
    ) {
        workspace = .init(document: document, instanceID: id(2))
        image = .init(
            owner: .init(
                slot: .primary,
                binaryID: id(3),
                architecture: "arm64",
                sliceIndex: 0,
                ownerGeneration: 1
            ),
            analysisRevision: 7,
            analysisFingerprintSHA256: fingerprint
        )
        let dependency = Phase2ReadFacetDependency(
            scope: .image(image.owner),
            facet: .symbols,
            requiredRevision: 7,
            requiredFingerprintSHA256: requiredFacetFingerprint
        )
        precondition = .init(workspace: workspace, workspaceRevision: 11, strictWholeWorkspace: strict, image: image, dependencies: [dependency])
        current = .init(workspace: workspace, workspaceRevision: 11, image: image,
                        facetRevisions: [.init(
                            scope: .image(image.owner),
                            facet: .symbols,
                            revision: 7,
                            fingerprintSHA256: requiredFacetFingerprint
                        )])
    }

    func image(
        slot: Int = 0,
        binary: UInt8 = 3,
        generation: UInt64 = 1,
        analysis: UInt64 = 7,
        fingerprint: String? = nil
    ) -> Phase2ReadImageIdentity {
        .init(
            owner: .init(
                slot: .init(rawValue: slot),
                binaryID: id(binary),
                architecture: "arm64",
                sliceIndex: 0,
                ownerGeneration: generation
            ),
            analysisRevision: analysis,
            analysisFingerprintSHA256: fingerprint
        )
    }

    func current(
        workspaceRevision: UInt64 = 11,
        image: Phase2ReadImageIdentity? = nil,
        symbolRevision: UInt64 = 7,
        extraFacetRevision: UInt64? = nil,
        currentFacetFingerprint: String? = nil
    ) -> Phase2ReadCurrentState {
        let actualImage = image ?? self.image
        var facets = [Phase2ReadFacetRevision(
            scope: .image(actualImage.owner),
            facet: .symbols,
            revision: symbolRevision,
            fingerprintSHA256: currentFacetFingerprint ?? precondition.dependencies[0].requiredFingerprintSHA256
        )]
        if let extraFacetRevision { facets.append(.init(scope: .image(actualImage.owner), facet: .pseudocode, revision: extraFacetRevision)) }
        return .init(workspace: workspace, workspaceRevision: workspaceRevision, image: actualImage, facetRevisions: facets)
    }

    var citation: Phase2ReadCitation {
        .init(id: id(50), target: .image(image), dependencies: precondition.dependencies)
    }

    func authorization(for candidate: Phase2ReadEvidenceCandidate) -> Phase2ReadAuthorization {
        let canonical = descriptor(.workspaceSummary, effects: [.a1])
        let request = Phase2ReadRequest(
            requestID: id(62), invocationID: candidate.invocationID, sequence: candidate.sequence,
            proposingPrincipal: .model, descriptor: canonical, subject: .workspace(workspace),
            precondition: candidate.precondition, limits: .maximum
        )
        return .init(request: request, canonicalDescriptor: canonical,
                     authorizingPrincipal: .app, approvedLimits: .maximum)
    }

    func candidate(
        evidence: UUID = id(60), invocation: UUID = id(61), sequence: UInt64 = 1,
        principal: Phase2Principal = .app, precondition: Phase2ReadPrecondition? = nil,
        operation: Phase2ReadOperationID = .workspaceSummary,
        data: Phase2ReadCandidateData = .value(.text("fact")),
        citations: [Phase2ReadCitation]? = nil,
        cancelled: Bool = false
    ) -> Phase2ReadEvidenceCandidate {
        .init(candidateID: evidence, invocationID: invocation, sequence: sequence,
              registryVersion: .v1, operationID: operation, operationVersion: .v1,
              producingPrincipal: principal, precondition: precondition ?? self.precondition,
              citations: citations ?? [citation], data: data, cancelled: cancelled)
    }
}
