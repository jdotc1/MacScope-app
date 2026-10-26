import XCTest
@testable import MacScope

final class Phase2DebuggerReadOperationTests: XCTestCase {
    func testPlanMintsOneOpaqueUniqueHandlePerClosedOperation() throws {
        let evidence = try makeEvidence()
        var next = 0
        let ids = (1...5).map {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))!
        }
        let plan = try XCTUnwrap(Phase2DebuggerReadOperationPlan(
            evidence: evidence,
            handleIDProvider: {
                defer { next += 1 }
                return ids[next]
            }
        ))

        XCTAssertEqual(plan.handles.map(\.operation), Phase2DebuggerReadOperationID.allCases)
        XCTAssertEqual(plan.handles.map(\.id), ids)
        XCTAssertEqual(Set(plan.handles.map(\.id)).count, 5)
    }

    func testDuplicateOpaqueHandleFailsClosedAtPlanConstruction() throws {
        let evidence = try makeEvidence()
        let duplicate = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        XCTAssertNil(Phase2DebuggerReadOperationPlan(
            evidence: evidence,
            handleIDProvider: { duplicate }
        ))
    }

    func testResolvesSummaryFramesRegistersVariablesAndBoundedMemory() throws {
        let evidence = try makeEvidence()
        let plan = try XCTUnwrap(Phase2DebuggerReadOperationPlan(evidence: evidence))

        for handle in plan.handles {
            let result = plan.resolve(
                .init(handleID: handle.id, operation: handle.operation),
                against: evidence
            )
            XCTAssertEqual(result.operation, handle.operation)
            guard case .value(let payload) = result.outcome else {
                return XCTFail("Expected value for \(handle.operation)")
            }
            XCTAssertEqual(result.provenance?.evidenceDigest, evidence.evidenceDigest)
            XCTAssertEqual(payload.operation, handle.operation)
            switch payload {
            case .summary(let summary):
                XCTAssertEqual(summary.processID, 4242)
                XCTAssertEqual(summary.selectedThreadIndex, 2)
                XCTAssertEqual(summary.selectedFrameIndex, 0)
                XCTAssertEqual(summary.selectedFrameAddress, 0x1000)
            case .frames(let frames):
                XCTAssertEqual(frames.frames.map(\.functionName), ["main", "caller"])
                XCTAssertFalse(frames.wasTruncated)
            case .registers(let registers):
                XCTAssertEqual(registers.registers.map(\.name), ["pc", "sp"])
                XCTAssertFalse(registers.wasTruncated)
            case .variables(let variables):
                guard case .available(let scopes, let wasTruncated) = variables.availability else {
                    return XCTFail("Expected available variable evidence")
                }
                XCTAssertEqual(scopes.map(\.kind), [.arguments, .locals, .statics])
                XCTAssertEqual(scopes.flatMap(\.variables).map(\.name), ["argc", "counter", "cache"])
                XCTAssertFalse(wasTruncated)
            case .memory(let memory):
                XCTAssertEqual(memory.regions.count, 1)
                XCTAssertEqual(memory.regions[0].previewBytes, [0xaa, 0xbb, 0xcc])
                XCTAssertFalse(memory.wasTruncated)
            }
        }
    }

    func testRejectsUnknownMismatchedAndStaleRequestsWithoutPayload() throws {
        let evidence = try makeEvidence()
        let plan = try XCTUnwrap(Phase2DebuggerReadOperationPlan(evidence: evidence))
        let summary = try XCTUnwrap(plan.handles.first { $0.operation == .summary })

        XCTAssertEqual(
            plan.resolve(
                .init(handleID: UUID(), operation: .summary),
                against: evidence
            ).outcome,
            .rejected(.unknownHandle)
        )
        XCTAssertEqual(
            plan.resolve(
                .init(handleID: summary.id, operation: .frames),
                against: evidence
            ).outcome,
            .rejected(.operationMismatch)
        )
        XCTAssertEqual(
            plan.resolve(
                .init(handleID: summary.id, operation: .summary),
                against: nil
            ).outcome,
            .rejected(.staleCoordinate)
        )

        let changedContent = try makeEvidence(statusMessage: "Changed at the same coordinate.")
        XCTAssertEqual(
            plan.resolve(
                .init(handleID: summary.id, operation: .summary),
                against: changedContent
            ).outcome,
            .rejected(.staleEvidence)
        )

        let variablesHandle = try XCTUnwrap(plan.handles.first { $0.operation == .variables })
        let changedVariable = try makeEvidence(variableValue: "99")
        XCTAssertEqual(
            plan.resolve(
                .init(handleID: variablesHandle.id, operation: .variables),
                against: changedVariable
            ).outcome,
            .rejected(.staleEvidence)
        )

        let changed = try makeEvidence(stopRevision: 2)
        XCTAssertEqual(
            plan.resolve(
                .init(handleID: summary.id, operation: .summary),
                against: changed
            ).outcome,
            .rejected(.staleCoordinate)
        )
    }

    func testOperationContractValuesAreSendable() {
        assertSendable(Phase2DebuggerReadOperationPlan.self)
        assertSendable(Phase2DebuggerReadOperationHandle.self)
        assertSendable(Phase2DebuggerReadOperationRequest.self)
        assertSendable(Phase2DebuggerReadOperationResult.self)
        assertSendable(Phase2DebuggerReadOperationPayload.self)
    }

    private func makeEvidence(
        stopRevision: UInt64 = 1,
        statusMessage: String = "Stopped.",
        variableValue: String = "7"
    ) throws -> Phase2DebuggerReadEvidenceSnapshot {
        let stop = DebuggerStopCoordinate(
            session: DebuggerSessionCoordinate(
                epoch: DebuggerSessionEpoch(
                    rawValue: UUID(uuidString: "88888888-2222-3333-4444-555555555555")!
                ),
                lifecycleRevision: DebuggerLifecycleRevision(rawValue: 3)
            ),
            stopRevision: DebuggerStopRevision(rawValue: stopRevision)
        )
        let authority = try targetAuthority()
        let selectedThreadSummary = DebuggerThreadSummary(
            index: 2,
            queueName: "main",
            stopReason: .breakpoint(address: 0x1000),
            isSelected: true,
            topFrameAddress: 0x1000,
            topFrameFunctionName: "main"
        )
        let thread = try XCTUnwrap(DebuggerThreadIdentity(summary: selectedThreadSummary))
        let frame = try XCTUnwrap(DebuggerFrameIdentity(
            thread: thread,
            frameIndex: 0,
            programCounter: 0x1000,
            canonicalFunctionName: "main"
        ))
        let coordinate = try XCTUnwrap(DebuggerInspectionCoordinate(
            stop: stop,
            targetAuthority: authority,
            thread: thread,
            frame: frame
        ))
        func node(
            _ name: String,
            scope: DebuggerVariableScopeKind,
            value: DebuggerVariableValueState
        ) throws -> DebuggerVariableNode {
            let token = try XCTUnwrap(DebuggerVariablePathToken(
                coordinate: coordinate,
                components: [scope.rawValue, name]
            ))
            return try XCTUnwrap(DebuggerVariableNode(
                id: token,
                name: name,
                typeName: "Int",
                value: value,
                childCount: 0
            ))
        }
        let session = DebuggerSessionSnapshot(
            processState: .paused(processID: 4242, reason: .breakpoint(address: 0x1000)),
            breakpoints: [],
            threads: [selectedThreadSummary],
            frames: [
                .init(index: 0, address: 0x1000, functionName: "main"),
                .init(index: 1, address: 0x1010, functionName: "caller"),
            ],
            registers: [
                .init(name: "pc", value: "0x1000", role: "program counter"),
                .init(name: "sp", value: "0x2000", role: "stack pointer"),
            ],
            memoryRegions: [
                .init(
                    address: 0x2000,
                    byteCount: 3,
                    previewBytes: [0xaa, 0xbb, 0xcc],
                    label: "stack"
                ),
            ],
            variableScopes: [
                .init(
                    coordinate: coordinate,
                    scope: .arguments,
                    nodes: [try node("argc", scope: .arguments, value: .value("2"))],
                    wasTruncated: false
                ),
                .init(
                    coordinate: coordinate,
                    scope: .locals,
                    nodes: [try node("counter", scope: .locals, value: .value(variableValue))],
                    wasTruncated: false
                ),
                .init(
                    coordinate: coordinate,
                    scope: .statics,
                    nodes: [try node("cache", scope: .statics, value: .optimizedOut)],
                    wasTruncated: false
                ),
            ],
            statusMessage: statusMessage,
            backendState: .connected(processID: 4242, adapterName: "Fixture LLDB"),
            transportSessionCoordinate: stop.session,
            transportStopCoordinate: stop,
            transportEventSequence: .init(rawValue: 1),
            transportTargetDisposition: .stopped(processID: 4242),
            transportTargetAuthority: authority
        )
        return try XCTUnwrap(Phase2DebuggerReadEvidenceSnapshot(
            session: session,
            coordinate: coordinate
        ))
    }

    private func targetAuthority() throws -> DebuggerSessionTargetAuthority {
        let start = try XCTUnwrap(DebuggerProcessStartIdentity(
            seconds: 1_700_000_000,
            microseconds: 42
        ))
        let identity = try XCTUnwrap(DebuggerLocalProcessIdentity(
            processID: 4242,
            startTime: start,
            realUserID: 501,
            effectiveUserID: 501,
            canonicalExecutablePath: "/Applications/Fixture.app/Contents/MacOS/Fixture",
            executableDeviceID: 10,
            executableFileID: 5_242,
            executableByteCount: 4_096,
            executableSHA256: String(repeating: "a", count: 64),
            architecture: .arm64,
            machOUUID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
            codeIdentity: nil
        ))
        return DebuggerSessionTargetAuthority(origin: .attached(identity))
    }

    private func assertSendable<T: Sendable>(_ type: T.Type) {}
}
