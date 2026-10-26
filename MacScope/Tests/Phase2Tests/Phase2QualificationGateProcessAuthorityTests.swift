import Darwin
import XCTest
@testable import MacScope

@MainActor
final class Phase2QualificationGateProcessAuthorityTests: XCTestCase {
    func testEstablishedSocketCensusRequiresCompleteReadableDescriptors() throws {
        typealias Census = Phase2QualificationGateLibprocProviderDiscoverer.SocketCensus
        let endpoint = try MacScope.Phase2LoopbackEndpoint(validating: "http://127.0.0.1:1234")
        let receipt = try Phase2InferenceProviderConnectionReceipt(
            localAddress: "127.0.0.1", localPort: 54_321,
            remoteAddress: "127.0.0.1", remotePort: 1_234
        )
        for providerSide in [false, true] {
            let match = GateSocketReads.socket(clientPort: 54_321, providerSide: providerSide)
            let nonmatch = socket_fdinfo()
            // Each near miss differs from `match` in exactly one classified field.
            func nearMiss(_ change: (inout socket_fdinfo) -> Void) -> socket_fdinfo {
                var value = match
                change(&value)
                return value
            }
            let otherEndpointPort = Int32(UInt16(1_235).bigEndian)
            let cases: [(String, [Int32: [socket_fdinfo?]], GateSocketReads.EnumerationFault,
                         GateSocketReads.EnumerationChange, Census)] = [
                ("empty", [:], .none, .none, .absent),
                ("readable nonmatch", [1: [nonmatch]], .none, .none, .absent),
                ("one match", [1: [match], 2: [nonmatch]], .none, .none,
                 .bound(.init(descriptor: 1, receipt: receipt))),
                ("duplicate matching descriptors", [1: [match], 2: [match]], .none, .none, .ambiguous),
                ("unreadable alone", [1: [nil]], .none, .none, .unavailable),
                ("match and unreadable", [1: [match], 2: [nil]], .none, .none, .unavailable),
                ("zero EPERM sizing", [:], .sizing(0, EPERM), .none, .unavailable),
                ("zero ESRCH read", [:], .reading(0, ESRCH), .none, .unavailable),
                ("negative sizing", [:], .sizing(-1, 0), .none, .unavailable),
                ("negative read", [:], .reading(-1, 0), .none, .unavailable),
                ("unstable enumeration", [1: [match]], .none, .alternating, .unavailable),
                ("descriptor opened during census", [1: [match]], .none, .afterInitialScan, .unavailable),
                ("closing connection", [1: [nearMiss {
                    $0.psi.soi_proto.pri_tcp.tcpsi_state = TSI_S_FIN_WAIT_1
                }]], .none, .none, .absent),
                ("other endpoint port", [1: [nearMiss {
                    if providerSide {
                        $0.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport = otherEndpointPort
                    } else {
                        $0.psi.soi_proto.pri_tcp.tcpsi_ini.insi_fport = otherEndpointPort
                    }
                }]], .none, .none, .absent),
                ("IPv6 family for IPv4 endpoint", [1: [nearMiss {
                    $0.psi.soi_family = AF_INET6
                }]], .none, .none, .absent),
                ("non-loopback peer address", [1: [nearMiss {
                    _ = inet_pton(AF_INET, "10.0.0.1", &$0.psi.soi_proto.pri_tcp.tcpsi_ini.insi_faddr.ina_46.i46a_addr4)
                }]], .none, .none, .absent),
                ("non-TCP socket kind", [1: [nearMiss {
                    $0.psi.soi_kind = Int32(SOCKINFO_IN)
                }]], .none, .none, .absent),
                ("datagram socket type", [1: [nearMiss {
                    $0.psi.soi_type = SOCK_DGRAM
                }]], .none, .none, .absent),
                ("non-TCP protocol", [1: [nearMiss {
                    $0.psi.soi_protocol = IPPROTO_UDP
                }]], .none, .none, .absent),
            ]
            for (name, sockets, fails, change, expected) in cases {
                let reads = GateSocketReads(sockets: [200: sockets],
                                            enumerationFault: fails, enumerationChange: change)
                XCTAssertEqual(reads.discoverer.establishedSocketCensus(
                    processID: 200, endpoint: endpoint,
                    providerReceipt: providerSide ? receipt : nil
                ), expected, "\(name), provider side: \(providerSide)")
            }
        }
        // The production descriptor reader must surface libproc's zero-plus-errno failure
        // (ESRCH for a process identifier that cannot exist) as unavailable, never absence.
        XCTAssertEqual(
            Phase2QualificationGateLibprocProviderDiscoverer().establishedSocketCensus(
                processID: Int32.max, endpoint: endpoint
            ),
            .unavailable,
            "production libproc reader, nonexistent process"
        )
    }

    func testEstablishedConnectionPreservesOriginalCaptureAcrossRevalidation() throws {
        let fixture = try GateProcessFixture()
        let endpoint = try MacScope.Phase2LoopbackEndpoint(validating: "http://127.0.0.1:1234")
        let clientA = GateSocketReads.socket(clientPort: 54_321)
        let clientB = GateSocketReads.socket(clientPort: 54_322)
        let peerA = GateSocketReads.socket(clientPort: 54_321, providerSide: true)
        let peerB = GateSocketReads.socket(clientPort: 54_322, providerSide: true)
        let baseline = GateSocketReads(sockets: [200: [1: [clientA]], 300: [2: [peerA]]])
        guard case .bound(let original) = baseline.discoverer.establishedConnection(
            client: fixture.worker, provider: fixture.provider, endpoint: endpoint,
            processObserver: fixture.observer
        ) else { return XCTFail("Complete exact fixture must bind before mutations.") }

        enum Outcome { case bound, unavailable, absent }
        // Rows name the exact observation, so a check that fails open into a different
        // non-bound case (for example unavailable becoming absent) cannot pass unnoticed.
        let cases: [(String, [socket_fdinfo?], [socket_fdinfo?], Int32, Int?, Bool, Outcome)] = [
            ("unchanged", [clientA], [peerA], 2, nil, true, .bound),
            ("client changes between scans", [clientA, clientB], [peerA], 2, nil, true, .unavailable),
            ("new unique pair cannot replace original", [clientB], [peerB], 2, nil, true, .unavailable),
            // A bound client whose provider owns no matching peer is unattributable, not absent.
            ("peer mismatch", [clientA], [peerB], 2, nil, true, .unavailable),
            ("peer unreadable", [clientA], [nil], 2, nil, true, .unavailable),
            ("peer changes between scans", [clientA], [peerA, peerB], 2, nil, true, .unavailable),
            ("client changes after peer scans", [clientA, clientA, clientB], [peerA], 2, nil, true, .unavailable),
            ("provider descriptor replaced with same tuple", [clientA], [peerA], 3, nil, true, .unavailable),
            ("process identity changed initially", [clientA], [peerA], 2, 1, true, .unavailable),
            ("process identity changed after census", [clientA], [peerA], 2, 3, true, .unavailable),
            ("uncaptured client changes between scans", [clientA, clientB], [peerA], 2, nil, false, .unavailable),
        ]
        for (name, clients, peers, peerDescriptor, changeAt, preservesOriginal, expected) in cases {
            let reads = GateSocketReads(sockets: [200: [1: clients], 300: [peerDescriptor: peers]])
            let observer = GateProcessObserver(observations: [
                200: fixture.worker, 300: fixture.provider,
            ], replacement: fixture.changedProvider, replacementAtCall: changeAt)
            let result = reads.discoverer.establishedConnection(
                client: fixture.worker, provider: fixture.provider, endpoint: endpoint,
                processObserver: observer, preserving: preservesOriginal ? original : nil
            )
            switch (result, expected) {
            case (.bound(let capture), .bound):
                XCTAssertEqual(capture.clientSocket, original.clientSocket, name)
                XCTAssertEqual(capture.providerSocket, original.providerSocket, name)
            case (.unavailable, .unavailable), (.absent, .absent):
                break
            default:
                XCTFail("\(name): expected \(expected), observed \(result)")
            }
        }
        // A separate request is allowed to capture B; continuity is not global state.
        let independent = GateSocketReads(sockets: [200: [1: [clientB]], 300: [2: [peerB]]])
        XCTAssertTrue(independent.discoverer.processesOwnEstablishedConnection(
            worker: fixture.worker, provider: fixture.provider, endpoint: endpoint,
            processObserver: fixture.observer
        ))
    }

    func testCanonicalPlanAllowsAtMostSeventyFourPhaseReceipts() {
        XCTAssertEqual(Phase2QualificationGateProcessAuthority.maximumPhaseReceiptCount, 74)
    }

    func testExactPhaseReceiptsBindRolesAndFinishOneConcreteSampler() async throws {
        let fixture = try GateProcessFixture()
        let authority = fixture.authority()
        let run = try await gateCompletedExecution(prepared: fixture.prepared)
        XCTAssertEqual(run.requestCount, 74)
        XCTAssertEqual(run.execution.dispatchEvidence?.phaseRequests.count, 74)
        let phaseRequests = try XCTUnwrap(run.execution.dispatchEvidence?.phaseRequests)

        XCTAssertNil(try authority.residentSetSampler.sample())
        XCTAssertEqual(
            authority.residentSetSampler.scopeIdentity.availability,
            .unavailable
        )

        for index in 0..<run.requestCount {
            XCTAssertTrue(try acceptExactPhaseAuthority(
                authority,
                fixture: fixture,
                record: phaseRequests[index],
                connectionIdentity: gateUUID(10_000 + index)
            ))
            if index == 0 {
                let sampler = try XCTUnwrap(authority.boundSampler)
                XCTAssertEqual(
                    authority.residentSetSampler.scopeIdentity,
                    sampler.scopeIdentity
                )
                let sample = try XCTUnwrap(try sampler.sample())
                XCTAssertEqual(sample.appBytes, 1_000)
                XCTAssertEqual(sample.aiWorkerBytes, 2_000)
                XCTAssertEqual(sample.providerBytes, 3_000)
            }
        }

        _ = try authority.finishRuntimeProvenance(for: run.execution)
        XCTAssertNotNil(authority.boundSampler)
        XCTAssertNotNil(try authority.residentSetSampler.sample())
        XCTAssertFalse(authority.acceptWorkerProcessReceipt(try fixture.receipt()))
        XCTAssertThrowsError(try authority.finishRuntimeProvenance(for: run.execution))
    }

    func testReceiptConnectionMayChangeButEveryAuthorityFieldMustRemainExact() throws {
        let fixture = try GateProcessFixture()
        let baseline = try fixture.receipt(connectionIdentity: gateUUID(20_000))
        let mutations: [(Phase2InferenceWorkerProcessReceipt) throws
            -> Phase2InferenceWorkerProcessReceipt] = [
            { value in try fixture.copy(value, processIdentifier: 201) },
            { value in try fixture.copy(value, providerGeneration: 2) },
            { value in try fixture.copy(value, profileID: gateUUID(999)) },
            { value in try fixture.copy(value, configurationGeneration: 4) },
            { value in try fixture.copy(value, protocolManifestDigest: gateDigest("d")) },
        ]

        let changingConnection = fixture.authority()
        XCTAssertTrue(changingConnection.acceptWorkerProcessReceipt(baseline))
        XCTAssertTrue(changingConnection.acceptWorkerProcessReceipt(
            try fixture.receipt(connectionIdentity: gateUUID(20_001))
        ))

        for mutation in mutations {
            let authority = fixture.authority()
            XCTAssertTrue(authority.acceptWorkerProcessReceipt(baseline))
            XCTAssertFalse(authority.acceptWorkerProcessReceipt(try mutation(baseline)))
            XCTAssertNil(authority.boundSampler)
        }
    }

    func testProviderDispatchAndMetricsReceiptsAreExactAndSingleUse() throws {
        let fixture = try GateProcessFixture()
        let requestID = gateUUID(20_100)

        let duplicateDispatch = fixture.authority()
        let dispatchWorker = try fixture.receipt(connectionIdentity: gateUUID(20_101))
        XCTAssertTrue(duplicateDispatch.acceptWorkerProcessReceipt(dispatchWorker))
        XCTAssertTrue(duplicateDispatch.acceptProviderDispatchReceipt(
            .init(requestID: requestID),
            workerReceipt: dispatchWorker
        ))
        XCTAssertFalse(duplicateDispatch.acceptProviderDispatchReceipt(
            .init(requestID: requestID),
            workerReceipt: dispatchWorker
        ))
        XCTAssertNil(duplicateDispatch.boundSampler)

        let wrongTuple = fixture.authority()
        let tupleWorker = try fixture.receipt(connectionIdentity: gateUUID(20_102))
        XCTAssertTrue(wrongTuple.acceptWorkerProcessReceipt(tupleWorker))
        XCTAssertTrue(wrongTuple.acceptProviderDispatchReceipt(
            .init(requestID: gateUUID(20_103)),
            workerReceipt: tupleWorker
        ))
        XCTAssertFalse(wrongTuple.acceptProviderConnectionReceipt(
            try .init(
                localAddress: "127.0.0.1",
                localPort: 54_322,
                remoteAddress: "127.0.0.1",
                remotePort: 1_234
            ),
            workerReceipt: tupleWorker
        ))
        XCTAssertNil(wrongTuple.boundSampler)
    }

    func testProviderConnectionReceiptRejectsNonLoopbackOrInvalidPorts() {
        XCTAssertThrowsError(try Phase2InferenceProviderConnectionReceipt(
            localAddress: "192.0.2.1",
            localPort: 54_321,
            remoteAddress: "127.0.0.1",
            remotePort: 1_234
        ))
        XCTAssertThrowsError(try Phase2InferenceProviderConnectionReceipt(
            localAddress: "127.0.0.1",
            localPort: 0,
            remoteAddress: "127.0.0.1",
            remotePort: 1_234
        ))
    }

    func testInitialConcreteProviderGenerationZeroIsAcceptedAndRemainsStable() throws {
        let fixture = try GateProcessFixture()
        let authority = fixture.authority()
        let first = try fixture.copy(try fixture.receipt(), providerGeneration: 0)
        let second = try fixture.copy(
            try fixture.receipt(connectionIdentity: gateUUID(20_010)),
            providerGeneration: 0
        )

        XCTAssertTrue(authority.acceptWorkerProcessReceipt(first))
        XCTAssertTrue(authority.acceptWorkerProcessReceipt(second))
        XCTAssertNotNil(authority.boundSampler)
    }

    func testWorkerValidatorReceivesEachConnectionBoundReceiptAndFinalRevalidation() async throws {
        let fixture = try GateProcessFixture()
        let validator = GateWorkerProcessValidator()
        let authority = fixture.authority(workerProcessValidator: validator)
        let run = try await gateCompletedExecution(prepared: fixture.prepared)
        let phaseRequests = try XCTUnwrap(run.execution.dispatchEvidence?.phaseRequests)
        var receipts: [Phase2InferenceWorkerProcessReceipt] = []

        for index in 0..<run.requestCount {
            let receipt = try fixture.receipt(
                connectionIdentity: gateUUID(25_000 + index)
            )
            receipts.append(receipt)
            XCTAssertTrue(try acceptExactPhaseAuthority(
                authority,
                fixture: fixture,
                record: phaseRequests[index],
                receipt: receipt
            ))
        }
        _ = try authority.finishRuntimeProvenance(for: run.execution)

        let receiptRevalidations = zip(receipts, phaseRequests).flatMap { receipt, record in
            Array(
                repeating: receipt,
                count: gateRequiresProviderConnection(record) ? 3 : 2
            )
        }
        XCTAssertEqual(
            validator.receipts,
            receiptRevalidations + [try XCTUnwrap(receipts.last)]
        )
        XCTAssertEqual(
            validator.observations,
            Array(repeating: fixture.worker, count: receiptRevalidations.count + 1)
        )
    }

    func testWorkerValidatorUnavailableOrRejectingFailsClosed() throws {
        let fixture = try GateProcessFixture()
        let unavailable = fixture.authority(workerProcessValidator: nil)
        XCTAssertFalse(unavailable.acceptWorkerProcessReceipt(try fixture.receipt()))
        XCTAssertNil(unavailable.boundSampler)

        let rejectingValidator = GateWorkerProcessValidator(acceptedCallCount: 0)
        let rejected = fixture.authority(workerProcessValidator: rejectingValidator)
        XCTAssertFalse(rejected.acceptWorkerProcessReceipt(try fixture.receipt()))
        XCTAssertNil(rejected.boundSampler)
        XCTAssertEqual(rejectingValidator.receipts.count, 1)
    }

    func testMissingOrThrowingProcessObservationFailsClosed() throws {
        let fixture = try GateProcessFixture()
        let observers: [any Phase2QualificationProcessObserving] = [
            GateUnavailableProcessObserver(behavior: .missing),
            GateUnavailableProcessObserver(behavior: .throwing),
        ]

        for observer in observers {
            let authority = fixture.authority(processObserver: observer)
            XCTAssertFalse(authority.acceptWorkerProcessReceipt(try fixture.receipt()))
            XCTAssertNil(authority.boundSampler)
            XCTAssertNil(try authority.residentSetSampler.sample())
        }
    }

    func testWorkerValidatorRejectionDuringRevalidationPermanentlyFailsAuthority() throws {
        let fixture = try GateProcessFixture()
        let validator = GateWorkerProcessValidator(acceptedCallCount: 1)
        let authority = fixture.authority(workerProcessValidator: validator)

        XCTAssertTrue(authority.acceptWorkerProcessReceipt(
            try fixture.receipt(connectionIdentity: gateUUID(26_000))
        ))
        XCTAssertFalse(authority.acceptWorkerProcessReceipt(
            try fixture.receipt(connectionIdentity: gateUUID(26_001))
        ))
        XCTAssertNil(authority.boundSampler)
        XCTAssertFalse(authority.acceptWorkerProcessReceipt(
            try fixture.receipt(connectionIdentity: gateUUID(26_002))
        ))
        XCTAssertEqual(validator.receipts.map(\.connectionIdentity), [
            gateUUID(26_000),
            gateUUID(26_001),
        ])
    }

    func testIncompleteOrOverflowReceiptDenominatorFailsClosed() async throws {
        let fixture = try GateProcessFixture()
        let run = try await gateCompletedExecution(prepared: fixture.prepared)
        let incomplete = fixture.authority()
        XCTAssertTrue(incomplete.acceptWorkerProcessReceipt(try fixture.receipt()))
        XCTAssertThrowsError(try incomplete.finishRuntimeProvenance(for: run.execution))

        let overflow = fixture.authority()
        for index in 0..<run.requestCount {
            XCTAssertTrue(overflow.acceptWorkerProcessReceipt(
                try fixture.receipt(connectionIdentity: gateUUID(30_000 + index))
            ))
        }
        XCTAssertFalse(overflow.acceptWorkerProcessReceipt(
            try fixture.receipt(connectionIdentity: gateUUID(40_000))
        ))
        XCTAssertNil(overflow.boundSampler)
        XCTAssertThrowsError(try overflow.finishRuntimeProvenance(for: run.execution))
    }

    func testEarlySelectionFailureBindsExactSeventyThreeReceiptDenominator() async throws {
        let fixture = try GateProcessFixture()
        let failedKey = Phase2LiveQualificationTrialKey(
            probeID: "live.performance.standard-turn",
            trial: 1
        )
        let run = try await gateCompletedExecution(
            prepared: fixture.prepared,
            failedSelectionKey: failedKey
        )
        XCTAssertEqual(run.requestCount, 73)
        XCTAssertEqual(run.execution.dispatchEvidence?.phaseRequests.count, 73)
        let phaseRequests = try XCTUnwrap(run.execution.dispatchEvidence?.phaseRequests)

        let exact = fixture.authority()
        for index in 0..<run.requestCount {
            XCTAssertTrue(try acceptExactPhaseAuthority(
                exact,
                fixture: fixture,
                record: phaseRequests[index],
                connectionIdentity: gateUUID(40_000 + index)
            ))
        }
        XCTAssertNoThrow(try exact.finishRuntimeProvenance(for: run.execution))

        let missing = fixture.authority()
        for index in 0..<(run.requestCount - 1) {
            XCTAssertTrue(missing.acceptWorkerProcessReceipt(
                try fixture.receipt(connectionIdentity: gateUUID(50_000 + index))
            ))
        }
        XCTAssertThrowsError(try missing.finishRuntimeProvenance(for: run.execution))

        let extra = fixture.authority()
        for index in 0...run.requestCount {
            XCTAssertTrue(extra.acceptWorkerProcessReceipt(
                try fixture.receipt(connectionIdentity: gateUUID(60_000 + index))
            ))
        }
        XCTAssertThrowsError(try extra.finishRuntimeProvenance(for: run.execution))
    }

    func testRuntimeProvenanceIsDerivedOnlyAfterExactDenominatorAndIsSingleUse() async throws {
        let fixture = try GateProcessFixture()
        let authority = fixture.authority()
        let run = try await gateCompletedExecution(prepared: fixture.prepared)
        let phaseRequests = try XCTUnwrap(run.execution.dispatchEvidence?.phaseRequests)
        for index in 0..<run.requestCount {
            XCTAssertTrue(try acceptExactPhaseAuthority(
                authority,
                fixture: fixture,
                record: phaseRequests[index],
                connectionIdentity: gateUUID(50_000 + index)
            ))
        }

        let provenance = try authority.finishRuntimeProvenance(for: run.execution)

        XCTAssertEqual(provenance.endpointProfileID, fixture.prepared.runtimeBinding.endpointProfileID)
        XCTAssertEqual(provenance.endpointGeneration, 3)
        XCTAssertEqual(provenance.providerRevision, 11)
        XCTAssertEqual(provenance.workerManifestDigest, fixture.manifestDigest)
        XCTAssertEqual(provenance.measurementScopeIdentity.availability, .available)
        XCTAssertEqual(provenance.startedAtEpochMilliseconds, 1_000)
        XCTAssertEqual(provenance.endedAtEpochMilliseconds, 2_000)
        XCTAssertThrowsError(try authority.finishRuntimeProvenance(for: run.execution))
    }

    func testAppWorkerProviderRoleSwapOrEnvironmentDigestMismatchFailsClosed() throws {
        let fixture = try GateProcessFixture()
        let swapped = fixture.authority(appProcessID: fixture.worker.processID)
        XCTAssertFalse(swapped.acceptWorkerProcessReceipt(try fixture.receipt()))
        XCTAssertNil(swapped.boundSampler)

        let wrongApp = try GateProcessFixture(appExecutableDigest: gateDigest("d"))
        XCTAssertFalse(wrongApp.authority().acceptWorkerProcessReceipt(try wrongApp.receipt()))

        let wrongWorker = try GateProcessFixture(workerExecutableDigest: gateDigest("d"))
        XCTAssertFalse(
            wrongWorker.authority().acceptWorkerProcessReceipt(try wrongWorker.receipt())
        )
    }

    func testProviderAmbiguityRaceOrPreparedRuntimeMismatchFailsClosed() throws {
        let fixture = try GateProcessFixture()
        for discovery in [
            GateProviderDiscoveryResult.none,
            .ambiguous,
            .changed(fixture.changedProvider),
        ] {
            let authority = fixture.authority(discoveryResult: discovery)
            XCTAssertFalse(authority.acceptWorkerProcessReceipt(try fixture.receipt()))
            XCTAssertNil(authority.boundSampler)
        }

        let wrongStart = try GateProcessFixture(providerStartByteDelta: 1)
        XCTAssertFalse(wrongStart.authority().acceptWorkerProcessReceipt(try wrongStart.receipt()))

        let wrongBuild = try GateProcessFixture(providerExecutableDigest: gateDigest("d"))
        XCTAssertFalse(wrongBuild.authority().acceptWorkerProcessReceipt(try wrongBuild.receipt()))
    }

    func testLowRSSSamplerCannotBeInjectedIntoProductionAuthority() throws {
        let source = try String(
            contentsOf: TestSourceRoot.fileURL(#filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(
                    path: "Services/Phase2/QualificationGate/Phase2QualificationGateProcessAuthority.swift"
                ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            "Phase2QualificationProcessScopeSampler(\n                appProcessID:"
        ))
        XCTAssertTrue(source.contains("proc_pidfdinfo("))
        XCTAssertTrue(source.contains("PROC_PIDFDSOCKETINFO"))
        XCTAssertFalse(source.contains("lsof"))
        XCTAssertFalse(source.contains("Process()"))
        XCTAssertFalse(source.contains("/bin/"))
        XCTAssertFalse(source.contains(
            "init(\n        prepared: Phase2PreparedLiveQualification,\n        residentSetSampler:"
        ))
    }

    func testDispatchDenominatorHasNoCallerSuppliedCountInitializer() throws {
        let macScope = TestSourceRoot.fileURL(#filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: macScope.appending(
                path: "Services/Phase2/Phase2LiveQualificationRunner.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("fileprivate init(\n        phaseRequests:"))
        XCTAssertTrue(source.contains("activeDispatchedPhaseRequests.append(.init("))
        XCTAssertFalse(source.contains("phaseReceiptCount:"))
    }
}

@MainActor
private func acceptExactPhaseAuthority(
    _ authority: Phase2QualificationGateProcessAuthority,
    fixture: GateProcessFixture,
    record: Phase2LiveQualificationDispatchedPhaseRequest,
    connectionIdentity: UUID
) throws -> Bool {
    try acceptExactPhaseAuthority(
        authority,
        fixture: fixture,
        record: record,
        receipt: fixture.receipt(connectionIdentity: connectionIdentity)
    )
}

@MainActor
private func acceptExactPhaseAuthority(
    _ authority: Phase2QualificationGateProcessAuthority,
    fixture: GateProcessFixture,
    record: Phase2LiveQualificationDispatchedPhaseRequest,
    receipt: Phase2InferenceWorkerProcessReceipt
) throws -> Bool {
    guard authority.acceptWorkerProcessReceipt(receipt),
          authority.acceptProviderDispatchReceipt(
            .init(requestID: record.requestID),
            workerReceipt: receipt
          )
    else { return false }
    if gateRequiresProviderConnection(record) {
        return authority.acceptProviderConnectionReceipt(
            fixture.providerConnectionReceipt(),
            workerReceipt: receipt
        )
    }
    return true
}

private func gateRequiresProviderConnection(
    _ record: Phase2LiveQualificationDispatchedPhaseRequest
) -> Bool {
    let policy = Phase2ProductionQualificationPolicy.standard
    guard let plan = try? Phase2LiveQualificationPlan(
        policy: policy.policy,
        catalog: policy.liveScenarioCatalog,
        fixtures: policy.liveScenarioCatalog.productionFixtures()
    ), let scheduled = plan.scheduledTrials.first(where: {
        $0.fixture.key == record.trialKey
    }) else { return false }
    return scheduled.scenario.phaseFlow != .cancellation
}

@MainActor
private func gateCompletedExecution(
    prepared: Phase2PreparedLiveQualification,
    failedSelectionKey: Phase2LiveQualificationTrialKey? = nil
) async throws -> (execution: Phase2LiveQualificationExecution, requestCount: Int) {
    let standard = Phase2ProductionQualificationPolicy.standard
    let catalog = standard.liveScenarioCatalog
    let coordinator = GateDispatchRecordingCoordinator(
        lease: prepared.runtimeBinding.readyLease
    )
    let runner = Phase2LiveQualificationRunner(
        coordinator: coordinator,
        runtimeValidator: GateAlwaysCurrentRuntimeValidator(),
        scorer: GateDispatchScorer(failedSelectionKey: failedSelectionKey)
    )
    let execution = await runner.run(
        plan: try .init(
            policy: standard.policy,
            catalog: catalog,
            fixtures: catalog.productionFixtures()
        ),
        runtimeBinding: prepared.runtimeBinding
    )
    guard execution.terminationStatus == .completed,
          let dispatchEvidence = execution.dispatchEvidence
    else { throw GateDispatchFixtureError.invalidExecution }
    return (
        .init(
            terminationStatus: execution.terminationStatus,
            observations: execution.observations,
            admittedAttemptKeys: execution.admittedAttemptKeys,
            measurementSamples: execution.measurementSamples,
            firstAdmissionEpochMilliseconds: 1_000,
            terminalEpochMilliseconds: 2_000,
            dispatchEvidence: dispatchEvidence
        ),
        coordinator.requestCount
    )
}

private enum GateDispatchFixtureError: Error {
    case invalidExecution
}

@MainActor
private final class GateDispatchRecordingCoordinator: Phase2LiveQualificationCoordinating {
    private let lease: Phase2ReadyInferenceLease
    private(set) var requestCount = 0

    init(lease: Phase2ReadyInferenceLease) {
        self.lease = lease
    }

    func run(request: Phase2InferenceRequest) async -> Phase2ReadyInferenceExecutionResult {
        requestCount += 1
        return .finished(
            lease: lease,
            outcome: .init(
                disposition: .completed,
                previewDeltas: [],
                toolProposals: [],
                finalCandidate: nil,
                providerUsage: nil,
                violation: nil,
                acceptedEventCount: 0,
                cumulativeEventBytes: 0
            )
        )
    }
}

@MainActor
private final class GateAlwaysCurrentRuntimeValidator:
    Phase2LiveQualificationRuntimeValidating
{
    func isCurrent(_ binding: Phase2LiveQualificationRuntimeBinding) -> Bool {
        _ = binding
        return true
    }
}

@MainActor
private final class GateDispatchScorer: Phase2LiveQualificationScoring {
    private let failedSelectionKey: Phase2LiveQualificationTrialKey?

    init(failedSelectionKey: Phase2LiveQualificationTrialKey?) {
        self.failedSelectionKey = failedSelectionKey
    }

    func classifySelection(
        _ outcome: Phase2InferenceOutcome,
        fixture: Phase2LiveQualificationTrialFixture
    ) -> Phase2LiveQualificationSelectionClassification {
        _ = outcome
        if fixture.key == failedSelectionKey {
            return .failed(try! .failed(
                reason: .selectionMismatch,
                evidenceDigest: gateDigest("0")
            ))
        }
        return .accepted(evidenceDigest: gateDigest("1"))
    }

    func classifyFinalization(
        _ outcome: Phase2InferenceOutcome,
        fixture: Phase2LiveQualificationTrialFixture,
        selectionEvidenceDigest: String?
    ) -> Phase2LiveQualificationClassification {
        _ = outcome
        _ = fixture
        _ = selectionEvidenceDigest
        return try! .passed(evidenceDigest: gateDigest("2"))
    }
}

@MainActor
private struct GateProcessFixture {
    let app: Phase2QualificationProcessObservation
    let worker: Phase2QualificationProcessObservation
    let provider: Phase2QualificationProcessObservation
    let changedProvider: Phase2QualificationProcessObservation
    let observer: GateProcessObserver
    let prepared: Phase2PreparedLiveQualification
    let manifestDigest: String

    init(
        appExecutableDigest: String = gateDigest("a"),
        workerExecutableDigest: String = gateDigest("b"),
        providerExecutableDigest: String = gateDigest("c"),
        providerStartByteDelta: UInt64 = 0
    ) throws {
        app = gateProcess(100, parent: 1, start: 10, sha: gateDigest("a"), rss: 1_000)
        worker = gateProcess(200, parent: 100, start: 20, sha: gateDigest("b"), rss: 2_000)
        provider = gateProcess(300, parent: 1, start: 30, sha: gateDigest("c"), rss: 3_000)
        changedProvider = gateProcess(
            300,
            parent: 1,
            start: 31,
            sha: gateDigest("c"),
            rss: 3_000
        )
        observer = GateProcessObserver(observations: [
            app.processID: app,
            worker.processID: worker,
            provider.processID: provider,
        ])

        let standard = Phase2ProductionQualificationPolicy.standard
        let manifest = Phase2ModelProtocolManifest.productionGroundedReadOnly
        manifestDigest = Phase2ModelProfileCanonicalizer().protocolManifestDigest(for: manifest)
        let environment = try gateEnvironment(
            appDigest: appExecutableDigest,
            workerDigest: workerExecutableDigest
        )
        let runtime = try gateRuntimeBinding(
            provider: provider,
            providerExecutableDigest: providerExecutableDigest,
            providerStartByteDelta: providerStartByteDelta
        )
        let profile = try Phase2ModelProfile(
            version: 2,
            provider: runtime.provider,
            artifact: try .init(
                modelKey: runtime.modelKey,
                source: runtime.artifactObservation.source,
                type: .language,
                format: .mlx,
                quantizationName: "8bit",
                bitsPerWeight: 8,
                backingDigest: runtime.artifactObservation.backingDigest
            ),
            loadedConfiguration: runtime.loadedConfiguration,
            context: try .init(
                id: "phase2-standard-32k",
                version: 1,
                maximumInputTokens: 32_768,
                reservedOutputTokens: 4_096,
                maximumEvidenceBytes: 2_000_000,
                compactionThresholdTokens: 24_000
            ),
            generation: try .init(
                id: "phase2-grounded-generation",
                version: 2,
                temperature: 0,
                topP: 1,
                seed: nil,
                stopSequences: [],
                reasoningOutputPolicy: .discard
            ),
            hardwareTier: try .init(id: "apple-m1-max-64gb", version: 1),
            workflow: .groundedReadOnly,
            authorityCeiling: .groundedReadOnly,
            toolCallMode: .requiredReadOnly,
            structuredOutputMode: .jsonSchema,
            protocolManifest: manifest
        )
        prepared = .init(
            profile: profile,
            runtimeBinding: runtime,
            evidenceBinding: .init(
                productionDefinition: standard.definitionIdentity,
                readToolRegistry: manifest.readToolRegistry,
                qualificationPolicy: standard.policyIdentity,
                protocolProbeCatalog: standard.protocolProbeCatalogIdentity,
                liveCorpus: standard.liveScenarioCatalog.identity,
                environment: try environment.contentIdentity(),
                qualificationEnvironment: environment
            )
        )
    }

    @MainActor
    func authority(
        appProcessID: Int32? = nil,
        discoveryResult: GateProviderDiscoveryResult = .exact,
        processObserver: (any Phase2QualificationProcessObserving)? = nil,
        workerProcessValidator: (any Phase2QualificationGateWorkerProcessValidating)? =
            GateWorkerProcessValidator()
    ) -> Phase2QualificationGateProcessAuthority {
        .makeForTesting(
            prepared: prepared,
            appProcessID: appProcessID ?? app.processID,
            processObserver: processObserver ?? observer,
            providerDiscoverer: GateProviderDiscoverer(
                exact: provider,
                result: discoveryResult
            ),
            workerProcessValidator: workerProcessValidator
        )
    }

    func receipt(
        connectionIdentity: UUID = gateUUID(5_000)
    ) throws -> Phase2InferenceWorkerProcessReceipt {
        try .init(
            processIdentifier: worker.processID,
            providerGeneration: 1,
            connectionIdentity: connectionIdentity,
            profileID: prepared.runtimeBinding.endpointProfileID,
            configurationGeneration: prepared.runtimeBinding.endpointGeneration,
            protocolManifestDigest: manifestDigest
        )
    }

    func providerConnectionReceipt() -> Phase2InferenceProviderConnectionReceipt {
        try! .init(
            localAddress: "127.0.0.1",
            localPort: 54_321,
            remoteAddress: "127.0.0.1",
            remotePort: 1_234
        )
    }

    func copy(
        _ receipt: Phase2InferenceWorkerProcessReceipt,
        processIdentifier: Int32? = nil,
        providerGeneration: UInt64? = nil,
        profileID: UUID? = nil,
        configurationGeneration: UInt64? = nil,
        protocolManifestDigest: String? = nil
    ) throws -> Phase2InferenceWorkerProcessReceipt {
        try .init(
            processIdentifier: processIdentifier ?? receipt.processIdentifier,
            providerGeneration: providerGeneration ?? receipt.providerGeneration,
            connectionIdentity: receipt.connectionIdentity,
            profileID: profileID ?? receipt.profileID,
            configurationGeneration: configurationGeneration
                ?? receipt.configurationGeneration,
            protocolManifestDigest: protocolManifestDigest ?? receipt.protocolManifestDigest
        )
    }
}

@MainActor
private final class GateWorkerProcessValidator:
    Phase2QualificationGateWorkerProcessValidating
{
    private let acceptedCallCount: Int?
    private(set) var receipts: [Phase2InferenceWorkerProcessReceipt] = []
    private(set) var observations: [Phase2QualificationProcessObservation] = []

    init(acceptedCallCount: Int? = nil) {
        self.acceptedCallCount = acceptedCallCount
    }

    func validateWorkerProcess(
        receipt: Phase2InferenceWorkerProcessReceipt,
        observation: Phase2QualificationProcessObservation
    ) -> Bool {
        receipts.append(receipt)
        observations.append(observation)
        return acceptedCallCount.map { receipts.count <= $0 } ?? true
    }
}

/// Inject only descriptor mechanics; classification and both census passes stay production code.
private final class GateSocketReads: @unchecked Sendable {
    enum EnumerationFault: Sendable {
        case none
        case sizing(Int32, Int32)
        case reading(Int32, Int32)
    }
    private let lock = NSLock()
    private let sockets: [Int32: [Int32: [socket_fdinfo?]]]
    /// When an extra descriptor appears: never, on every second enumeration (so the initial
    /// pair disagrees), or only after the initial pair (so only the final re-enumeration sees it).
    enum EnumerationChange: Sendable {
        case none
        case alternating
        case afterInitialScan
    }
    private let enumerationFault: EnumerationFault
    private let enumerationChange: EnumerationChange
    private var enumerationCount = 0
    private var socketCounts: [String: Int] = [:]

    init(sockets: [Int32: [Int32: [socket_fdinfo?]]],
         enumerationFault: EnumerationFault = .none, enumerationChange: EnumerationChange = .none) {
        self.sockets = sockets
        self.enumerationFault = enumerationFault
        self.enumerationChange = enumerationChange
    }

    var discoverer: Phase2QualificationGateLibprocProviderDiscoverer {
        .init(descriptorRead: { [self] in descriptors($0, $1, $2) },
              socketRead: { [self] in socket($0, $1) })
    }

    private func descriptors(_ pid: Int32, _ buffer: UnsafeMutableRawPointer?, _ byteCapacity: Int32)
        -> Phase2QualificationGateLibprocProviderDiscoverer.DescriptorReadResult {
        lock.withLock {
            if buffer == nil {
                if case .sizing(let count, let error) = enumerationFault {
                    return .init(byteCount: count, errorCode: error)
                }
                return .init(byteCount: Int32((sockets[pid]?.count ?? 0) * MemoryLayout<proc_fdinfo>.size), errorCode: 0)
            }
            if case .reading(let count, let error) = enumerationFault {
                return .init(byteCount: count, errorCode: error)
            }
            enumerationCount += 1
            var values = (sockets[pid] ?? [:]).keys.sorted().map { fd in
                var value = proc_fdinfo()
                value.proc_fd = fd
                value.proc_fdtype = UInt32(PROX_FDTYPE_SOCKET)
                return value
            }
            let descriptorAppears: Bool
            switch enumerationChange {
            case .none: descriptorAppears = false
            case .alternating: descriptorAppears = enumerationCount.isMultiple(of: 2)
            case .afterInitialScan: descriptorAppears = enumerationCount > 2
            }
            if descriptorAppears {
                var extra = proc_fdinfo()
                extra.proc_fd = 99
                values.append(extra)
            }
            let count = values.count * MemoryLayout<proc_fdinfo>.size
            guard count <= Int(byteCapacity), let buffer else {
                return .init(byteCount: 0, errorCode: ENOMEM)
            }
            for (index, value) in values.enumerated() {
                buffer.storeBytes(of: value, toByteOffset: index * MemoryLayout<proc_fdinfo>.size,
                                  as: proc_fdinfo.self)
            }
            return .init(byteCount: Int32(count), errorCode: 0)
        }
    }

    private func socket(_ pid: Int32, _ fd: Int32) -> socket_fdinfo? {
        lock.withLock {
            guard let sequence = sockets[pid]?[fd], !sequence.isEmpty else { return nil }
            let key = "\(pid):\(fd)"
            let index = socketCounts[key, default: 0]
            socketCounts[key] = index + 1
            return sequence[min(index, sequence.count - 1)]
        }
    }

    static func socket(clientPort: UInt16, providerSide: Bool = false) -> socket_fdinfo {
        var value = socket_fdinfo()
        value.psi.soi_kind = Int32(SOCKINFO_TCP)
        value.psi.soi_type = SOCK_STREAM
        value.psi.soi_protocol = IPPROTO_TCP
        value.psi.soi_family = AF_INET
        value.psi.soi_proto.pri_tcp.tcpsi_state = TSI_S_ESTABLISHED
        value.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport = Int32((providerSide ? 1_234 : clientPort).bigEndian)
        value.psi.soi_proto.pri_tcp.tcpsi_ini.insi_fport = Int32((providerSide ? clientPort : 1_234).bigEndian)
        var loopback = in_addr()
        _ = inet_pton(AF_INET, "127.0.0.1", &loopback)
        value.psi.soi_proto.pri_tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4 = loopback
        value.psi.soi_proto.pri_tcp.tcpsi_ini.insi_faddr.ina_46.i46a_addr4 = loopback
        return value
    }
}

private enum GateProviderDiscoveryResult {
    case exact
    case none
    case ambiguous
    case changed(Phase2QualificationProcessObservation)
}

private struct GateProviderDiscoverer: Phase2QualificationGateProviderProcessDiscovering {
    let exact: Phase2QualificationProcessObservation
    let result: GateProviderDiscoveryResult

    func uniqueListenerProcess(
        endpoint: MacScope.Phase2LoopbackEndpoint,
        processObserver: any Phase2QualificationProcessObserving
    ) -> Phase2QualificationProcessObservation? {
        switch result {
        case .exact: exact
        case .none, .ambiguous: nil
        case .changed(let value): value
        }
    }

    func processOwnsEstablishedConnection(
        _ process: Phase2QualificationProcessObservation,
        receipt: Phase2InferenceProviderConnectionReceipt,
        endpoint: MacScope.Phase2LoopbackEndpoint,
        processObserver: any Phase2QualificationProcessObserving
    ) -> Bool {
        _ = processObserver
        guard case .exact = result else { return false }
        return process.hasSameIdentity(as: exact)
            && receipt.localAddress == "127.0.0.1"
            && receipt.localPort == 54_321
            && receipt.remoteAddress == "127.0.0.1"
            && receipt.remotePort == endpoint.port
    }

    func processesOwnEstablishedConnection(
        worker: Phase2QualificationProcessObservation,
        provider: Phase2QualificationProcessObservation,
        endpoint: MacScope.Phase2LoopbackEndpoint,
        processObserver: any Phase2QualificationProcessObserving
    ) -> Bool {
        _ = worker
        _ = endpoint
        _ = processObserver
        guard case .exact = result else { return false }
        return provider.hasSameIdentity(as: exact)
    }
}

private final class GateProcessObserver:
    Phase2QualificationProcessObserving,
    @unchecked Sendable
{
    private let observations: [Int32: Phase2QualificationProcessObservation]
    private let lock = NSLock()
    private var observationCounts: [Int32: Int] = [:]
    private let replacement: Phase2QualificationProcessObservation?
    private let replacementAtCall: Int?

    init(observations: [Int32: Phase2QualificationProcessObservation],
         replacement: Phase2QualificationProcessObservation? = nil,
         replacementAtCall: Int? = nil) {
        self.observations = observations
        self.replacement = replacement
        self.replacementAtCall = replacementAtCall
    }

    func observation(processID: Int32) throws -> Phase2QualificationProcessObservation? {
        lock.withLock {
            observationCounts[processID, default: 0] += 1
            if let replacement, replacement.processID == processID,
               let replacementAtCall, observationCounts[processID, default: 0] >= replacementAtCall {
                return replacement
            }
            return observations[processID]
        }
    }

    func childProcessIDs(of processID: Int32) throws -> [Int32]? { [] }
}

private final class GateUnavailableProcessObserver:
    Phase2QualificationProcessObserving,
    @unchecked Sendable
{
    enum Behavior {
        case missing
        case throwing
    }

    private let behavior: Behavior

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func observation(processID: Int32) throws -> Phase2QualificationProcessObservation? {
        _ = processID
        switch behavior {
        case .missing: return nil
        case .throwing: throw GateUnavailableProcessObservationError.unavailable
        }
    }

    func childProcessIDs(of processID: Int32) throws -> [Int32]? {
        _ = processID
        return nil
    }
}

private enum GateUnavailableProcessObservationError: Error {
    case unavailable
}

@MainActor
private func gateRuntimeBinding(
    provider: Phase2QualificationProcessObservation,
    providerExecutableDigest: String,
    providerStartByteDelta: UInt64
) throws -> Phase2LiveQualificationRuntimeBinding {
    let lease = Phase2ReadyInferenceLease(
        providerRevision: 11,
        configuration: try .init(
            profileID: gateUUID(9_000),
            generation: 3,
            endpointOrigin: "http://127.0.0.1:1234",
            model: "publisher/exact-model@q4",
            maximumTokens: 2_048,
            requestTimeoutMilliseconds: 4_000,
            resourceTimeoutMilliseconds: 60_000
        ),
        observedModelInventorySHA256: String(repeating: "a", count: 64)
    )
    var start = provider
    if providerStartByteDelta != 0 {
        start = gateProcess(
            provider.processID,
            parent: provider.parentProcessID,
            start: provider.startIdentity.seconds + providerStartByteDelta,
            sha: provider.executableIdentity.sha256,
            rss: provider.residentBytes
        )
    }
    let executable = Phase2QualificationProcessObservation(
        processID: provider.processID,
        parentProcessID: provider.parentProcessID,
        startIdentity: provider.startIdentity,
        executableIdentity: .init(
            deviceID: provider.executableIdentity.deviceID,
            fileID: provider.executableIdentity.fileID,
            sha256: providerExecutableDigest
        ),
        residentBytes: provider.residentBytes
    )
    return .init(
        endpointProfileID: lease.configuration.profileID,
        endpointGeneration: lease.configuration.generation,
        providerRevision: lease.providerRevision,
        readyLease: lease,
        modelKey: lease.configuration.model,
        loadedInstanceID: "instance-exact-1",
        loadedConfiguration: .init(
            effectiveContextLength: 32_768,
            evaluationBatchSize: 512,
            parallelPredictions: 1,
            flashAttention: true,
            expertCount: 8,
            offloadsKVCacheToGPU: true
        ),
        provider: try .init(
            family: "local-provider",
            build: "0.4.19+2",
            apiCompatibility: "openai-v1",
            endpointTransport: .loopbackHTTP
        ),
        providerRuntimeIdentity: try .init(
            endpoint: gateComponent("phase2.r1.provider-endpoint.v1", "1"),
            processStart: try Phase2QualificationGateProcessAuthority
                .providerProcessStartIdentity(start),
            executableBuild: try Phase2QualificationGateProcessAuthority
                .providerExecutableBuildIdentity(executable),
            apiProbe: gateComponent("phase2.r1.provider-api-probe.v1", "4")
        ),
        advertisedMaximumContextLength: 32_768,
        artifactObservation: .init(
            source: "provider-catalog",
            backingDigest: try .sha256(gateDigest("5")),
            modelRevision: Phase2ProductionQualificationPolicy.standard.modelRevision.identity
        )
    )
}

@MainActor
private func gateEnvironment(
    appDigest: String,
    workerDigest: String
) throws -> Phase2QualificationEnvironmentV2 {
    try .init(
        bundleShortVersion: "2.0",
        bundleVersion: "100",
        macScopeCommit: String(repeating: "1", count: 40),
        appExecutableDigest: appDigest,
        workerExecutableDigest: workerDigest,
        signingRequirementDigest: gateDigest("8"),
        xcodeVersion: "27.0",
        xcodeBuild: "27A1",
        swiftCompilerVersion: "6.3",
        sdkVersion: "27.0",
        sdkBuild: "27A1",
        operatingSystemVersion: "27.0",
        operatingSystemBuild: "27A1",
        architecture: "arm64",
        hardwareModel: "MacBookPro18,2",
        processorFamily: "Apple M1 Max",
        physicalMemoryBytes: 64 * 1_024 * 1_024 * 1_024,
        physicalCoreCount: 10,
        logicalCoreCount: 10,
        performanceCoreCount: 8,
        efficiencyCoreCount: 2
    )
}

private func gateProcess(
    _ processID: Int32,
    parent: Int32,
    start: UInt64,
    sha: String,
    rss: UInt64
) -> Phase2QualificationProcessObservation {
    .init(
        processID: processID,
        parentProcessID: parent,
        startIdentity: .init(seconds: start, microseconds: 1),
        executableIdentity: .init(
            deviceID: UInt64(processID) + 1,
            fileID: UInt64(processID) + 2,
            sha256: sha
        ),
        residentBytes: rss
    )
}

private func gateComponent(
    _ id: String,
    _ character: Character
) -> Phase2ProtocolComponentIdentity {
    try! .init(id: id, version: 1, sha256: gateDigest(character))
}

private func gateUUID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", value))!
}

private func gateDigest(_ character: Character) -> String {
    String(repeating: String(character), count: 64)
}
