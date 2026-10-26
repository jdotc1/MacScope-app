import XCTest
@testable import MacScope

/// Focused integration selectors for the app-owned bounded call-site read.
@MainActor
final class Phase2FunctionCallSitesTests: XCTestCase {
    func testReadUsesSelectedImageRawCallKindAndSourceCitations() throws {
        let rows = [
            xref(0x1008, UInt64.max),
            xref(0x1004, 0x3000),
            xref(0x1004, 0x3000),
            xref(0x1000, 0x4000, kind: XRefKind.data),
            xref(0x1200, 0x5000),
        ]
        let store = try makeStore(siblingXRefs: rows)
        let read = try prepared(in: store)
        XCTAssertEqual(read.authorization.canonicalDescriptor.effects, [.a1])
        XCTAssertEqual(Set(read.authorization.request.precondition.dependencies.map(\.facet)),
                       Set(Phase2ReadOperationID.functionCallSiteFacets))
        let execution = store.executePhase2Read(read)
        XCTAssertEqual(execution.disposition, .accepted)
        XCTAssertNotNil(execution.acceptedEvidence)
        XCTAssertEqual(execution.candidate.data.callSiteField("matchingReferenceCount"), .unsignedInteger(3))
        XCTAssertEqual(execution.candidate.data.callSiteField("uniqueCallPairCount"), .unsignedInteger(2))
        XCTAssertEqual(execution.candidate.data.callSiteField("duplicateReferenceCount"), .unsignedInteger(1))
        let items = try rowsOf(execution.candidate)
        XCTAssertEqual(items.count, 2)
        let first = try XCTUnwrap(items.first)
        let second = try XCTUnwrap(items.dropFirst().first)
        XCTAssertEqual(first.callSiteField("rawTargetAddress"), .unsignedInteger(0x3000))
        XCTAssertEqual(second.callSiteField("rawTargetAddress"), .unsignedInteger(UInt64.max))
        let image = try XCTUnwrap(read.authorization.request.precondition.image)
        XCTAssertEqual(image.slot, siblingSlot)
        for citation in execution.candidate.citations {
            switch citation.target {
            case .functionRange(let range): XCTAssertEqual(range.image, image)
            case .staticLocation(let location):
                XCTAssertEqual(location.image, image)
                XCTAssertTrue((0x1000..<0x1200).contains(location.address))
            default: XCTFail("Only the authorized function and its source sites may be cited")
            }
        }
        // The out-of-range raw target must not become a navigable target citation.
        XCTAssertFalse(execution.candidate.citations.contains {
            if case .staticLocation(let location) = $0.target { return location.address == UInt64.max }
            return false
        })
    }

    func testXRefOnlyFingerprintChangeRejectsDelayedRead() throws {
        let store = try makeStore(siblingXRefs: [xref(0x1004, 0x3000)])
        let delayed = try prepared(in: store)
        var snapshot = store.snapshot
        var analysis = try XCTUnwrap(snapshot.analysis(in: siblingSlot))
        let binary = try XCTUnwrap(snapshot.binary(in: siblingSlot))
        analysis.xrefs = [xref(0x1004, 0x4000)]
        analysis.analysisInputFingerprint = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)
        snapshot.replaceAnalysis(analysis, in: siblingSlot)
        store.snapshot = snapshot

        let result = store.executePhase2Read(delayed)
        XCTAssertEqual(result.disposition, .stale)
        XCTAssertNil(result.acceptedEvidence)
        let current = try prepared(in: store)
        let before = try XCTUnwrap(delayed.authorization.request.precondition.dependencies.first { $0.facet == .xrefsAndCFG })
        let after = try XCTUnwrap(current.authorization.request.precondition.dependencies.first { $0.facet == .xrefsAndCFG })
        XCTAssertNotNil(before.requiredFingerprintSHA256)
        XCTAssertNotEqual(before.requiredFingerprintSHA256, after.requiredFingerprintSHA256)
    }

    func testExactEncodedEnvelopeTrimsPrefixAndPreservesCounts() throws {
        let rows = (0..<64).map { xref(0x1000 + UInt64($0 * 4), 0x4000 + UInt64($0 * 4)) }
        let store = try makeStore(siblingXRefs: rows)
        let limits = readLimits(encodedResultBytes: 12_000, pageItems: 64)
        let execution = store.executePhase2Read(try prepared(in: store, limits: limits))
        XCTAssertEqual(execution.disposition, .accepted)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(execution.candidate).count, limits.encodedResultBytes)
        XCTAssertTrue(execution.candidate.fits(within: limits))
        let retained = try rowsOf(execution.candidate).count
        XCTAssertGreaterThan(retained, 0)
        XCTAssertLessThan(retained, 64)
        XCTAssertEqual(execution.candidate.data.callSiteField("uniqueCallPairCount"), .unsignedInteger(64))
        XCTAssertEqual(execution.candidate.data.callSiteField("omittedUniqueCallPairCount"), .unsignedInteger(UInt64(64 - retained)))
        XCTAssertEqual(execution.candidate.data.callSiteField("truncatedByItemLimit"), .boolean(false))
        XCTAssertEqual(execution.candidate.data.callSiteField("truncatedByEnvelopeLimit"), .boolean(true))
    }

    func testRawInputCapRefusesInsteadOfReturningAnEmptyAnswer() throws {
        // One bounded capacity case, not a binary/corpus sweep. Avoid irrelevant
        // fingerprint hashing: refusal must happen before xref projection.
        let rows = Array(repeating: xref(0x1004, 0x3000, kind: XRefKind.data),
                         count: Phase2FunctionCallSitesProjector.maximumInputReferences + 1)
        let store = try makeStore(siblingXRefs: rows, fingerprint: false)
        guard case .rejected(.limitExceeded) = store.preparePhase2Read(
            operation: .functionCallSites, proposingPrincipal: .app
        ) else { return XCTFail("Raw all-kind capacity must refuse before filtering") }
    }

    func testMissingFacetAndUnregisteredExternalProposalAreRejected() throws {
        XCTAssertFalse(Phase2ReadOperationID.allProviderVisible.contains(.functionCallSites))
        let store = try makeStore(siblingXRefs: [xref(0x1004, 0x3000)])
        let original = try prepared(in: store).authorization.request
        let precondition = original.precondition
        let request = Phase2ReadRequest(
            requestID: UUID(), invocationID: UUID(), sequence: 1, proposingPrincipal: .app,
            descriptor: original.descriptor, subject: original.subject,
            precondition: .init(
                workspace: precondition.workspace, workspaceRevision: precondition.workspaceRevision,
                strictWholeWorkspace: precondition.strictWholeWorkspace, image: precondition.image,
                dependencies: precondition.dependencies.filter { $0.facet != .xrefsAndCFG }
            ), limits: original.limits
        )
        XCTAssertEqual(TypedReadRegistry().authorize(request, authorizingPrincipal: .app), .rejected(.unauthorized))
        for principal in [Phase2Principal.cli, .mcp] {
            guard case .rejected(.unauthorized) = store.preparePhase2Read(
                operation: .functionCallSites, proposingPrincipal: principal
            ) else { return XCTFail("This patch does not extend the external operation catalog") }
        }
    }

    func testTooSmallEnvelopeStillUsesExistingLimitRejection() throws {
        let store = try makeStore(siblingXRefs: [xref(0x1004, 0x3000)])
        let execution = store.executePhase2Read(try prepared(
            in: store, limits: readLimits(encodedResultBytes: 1, pageItems: 1)
        ))
        XCTAssertEqual(execution.disposition, .limitExceeded)
        XCTAssertNil(execution.acceptedEvidence)
    }

    func testPairsKeepDistinctTargetsAndHalfOpenSourceBoundaries() throws {
        let store = try makeStore(siblingXRefs: [
            xref(0x0ffc, 0x2000), xref(0x1000, 0x4000),
            xref(0x1000, 0x3000), xref(0x1000, 0x3000),
            xref(0x11fc, 0x5000), xref(0x1200, 0x6000),
        ])
        let execution = store.executePhase2Read(try prepared(in: store))
        XCTAssertEqual(execution.disposition, .accepted)
        let rows = try rowsOf(execution.candidate)
        XCTAssertEqual(rows.map { $0.callSiteField("rawTargetAddress") },
                       [.unsignedInteger(0x3000), .unsignedInteger(0x4000), .unsignedInteger(0x5000)])
        XCTAssertEqual(execution.candidate.data.callSiteField("matchingReferenceCount"), .unsignedInteger(4))
        XCTAssertEqual(execution.candidate.data.callSiteField("duplicateReferenceCount"), .unsignedInteger(1))
        // Two pairs at one source share its citation; raw targets add no authority.
        XCTAssertEqual(execution.candidate.citations.count, 3)
    }

    func testCancelledInvocationRejectsLateCallSiteProjection() throws {
        let store = try makeStore(siblingXRefs: [xref(0x1004, 0x3000)])
        let read = try prepared(in: store)
        let invocationID = read.authorization.request.invocationID
        XCTAssertEqual(store.cancelPhase2Read(invocationID: invocationID).disposition, .cancelled)
        let late = store.executePhase2Read(read)
        XCTAssertEqual(late.disposition, .duplicate)
        XCTAssertNil(late.acceptedEvidence)
        XCTAssertEqual(store.cancelPhase2Read(invocationID: invocationID).disposition, .cancelled)
    }

    func testMismatchedFunctionSubjectCannotProjectCallSites() throws {
        let store = try makeStore(siblingXRefs: [xref(0x1004, 0x3000)])
        let read = try prepared(in: store)
        guard case .functionRange(let range) = read.authorization.request.subject else {
            return XCTFail("Expected the exact selected function")
        }
        let analysis = try XCTUnwrap(store.snapshot.analysis(in: siblingSlot))
        let primaryImage = try XCTUnwrap(store.phase2ReadLedger.imageIdentity(in: .primary, snapshot: store.snapshot))
        for mismatchedRange in [
            Phase2ReadFunctionRange(image: range.image, start: range.start, endExclusive: range.endExclusive + 4),
            Phase2ReadFunctionRange(image: primaryImage, start: range.start, endExclusive: range.endExclusive),
        ] {
            let mismatched = Phase2FunctionCallSitesProjector.project(
                range: mismatchedRange, analysis: analysis, authorization: read.authorization
            )
            XCTAssertEqual(mismatched.data, .unavailable(.unresolvedOwner))
        }
    }

    private var siblingSlot: ImageSlot { .init(rawValue: 1) }

    private func prepared(in store: WorkspaceStore, limits: Phase2ReadLimits = .maximum) throws -> Phase2PreparedRead {
        guard case .prepared(let read) = store.preparePhase2Read(
            operation: .functionCallSites, proposingPrincipal: .app, limits: limits
        ) else { throw CallSiteTestError.preparationFailed }
        return read
    }

    private func makeStore(siblingXRefs: [XRef], fingerprint: Bool = true) throws -> WorkspaceStore {
        let primary = binary(slot: .primary)
        let sibling = binary(slot: siblingSlot)
        let primaryAnalysis = try analysis(binary: primary, xrefs: [xref(0x1004, 0x2000)], fingerprint: fingerprint)
        let siblingAnalysis = try analysis(binary: sibling, xrefs: siblingXRefs, fingerprint: fingerprint)
        let store = WorkspaceStore(
            workspaceName: "Call site projection", snapshot: .init(
                binaries: [primary, sibling],
                analysisBySlot: [.primary: primaryAnalysis, siblingSlot: siblingAnalysis]
            ), engine: AnalysisEngine(), autosaveScheduler: nil
        )
        // selectAddress intentionally accepts only the already-focused image.
        // Establish the sibling owner before selecting its colliding virtual address.
        store.focusImage(siblingSlot)
        XCTAssertEqual(store.focusedImageSlot, siblingSlot)
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: siblingSlot, address: 0x1004)))
        return store
    }

    private func binary(slot: ImageSlot) -> BinaryImage {
        BinaryImage(id: UUID(), name: "fixture-\(slot.rawValue)", path: "/ignored/callsites-\(slot.rawValue)",
                    kind: "Mach-O", architecture: "arm64", selectedSliceIndex: 0, slot: slot)
    }

    private func analysis(binary: BinaryImage, xrefs: [XRef], fingerprint: Bool) throws -> ImageAnalysis {
        var analysis = ImageAnalysis()
        analysis.functions = [.init(id: UUID(), name: "selected", startAddress: 0x1000,
                                    endAddress: 0x1200, confidence: 1)]
        analysis.instructions = [.init(address: 0x1004, bytes: "00 00 00 00", mnemonic: "bl",
                                       operands: "", hasBreakpoint: false, comment: nil)]
        analysis.sections = [.init(id: UUID(), name: "__text", address: 0x1000, size: 0x200,
                                   fileOffset: 0, isExecutable: true)]
        analysis.imageBytes = Data(repeating: 0, count: 0x200)
        analysis.xrefs = xrefs
        if fingerprint {
            analysis.analysisInputFingerprint = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)
        }
        return analysis
    }

    private func xref(_ from: UInt64, _ to: UInt64, kind: String = XRefKind.call) -> XRef {
        .init(id: UUID(), from: from, to: to, kind: kind)
    }

    private func readLimits(encodedResultBytes: Int, pageItems: Int) -> Phase2ReadLimits {
        .init(encodedRequestBytes: 65_536, encodedResultBytes: encodedResultBytes,
              structuralNesting: 12, objectMembers: 64, arrayItems: 1_024,
              stringBytes: 65_536, pageItems: pageItems)
    }

    private func rowsOf(_ candidate: Phase2ReadEvidenceCandidate) throws -> [Phase2ReadFactValue] {
        guard case .list(let items) = candidate.data.callSiteField("items") else {
            throw CallSiteTestError.missingItems
        }
        return items
    }
}

private enum CallSiteTestError: Error { case preparationFailed, missingItems }

private extension Phase2ReadCandidateData {
    func callSiteField(_ name: String) -> Phase2ReadFactValue? {
        guard case .value(let value) = self else { return nil }
        return value.callSiteField(name)
    }
}

private extension Phase2ReadFactValue {
    func callSiteField(_ name: String) -> Phase2ReadFactValue? {
        guard case .object(let fields) = self else { return nil }
        return fields.first { $0.name == name }?.value
    }
}
