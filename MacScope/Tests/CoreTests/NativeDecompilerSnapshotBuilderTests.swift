import Foundation
import XCTest
@testable import MacScope

final class NativeDecompilerSnapshotBuilderTests: XCTestCase {
    private let slot = ImageSlot(rawValue: 7)
    private let binaryID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let imageUUID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    private let functionID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
    private let requestID = UUID(uuidString: "40000000-0000-0000-0000-000000000004")!

    @MainActor
    func testPreservedOrphanAndLiveLocalShareOffsetWithoutPoisoningRequest() throws {
        let edits = [
            "-24:-16": StackLocalOverride(name: "wide_saved", typeName: "uint64_t"),
            "-24:-20": StackLocalOverride(name: "narrow_live", typeName: "uint32_t"),
        ]
        let address = ImageAddress(slot: slot, address: 0x1000)
        // Exercise the persisted representation before constructing the native request.
        let persisted = try JSONDecoder().decode(AddressOverride.self,
            from: JSONEncoder().encode(AddressOverride(stackLocals: edits)))
        XCTAssertEqual(persisted.stackLocals, edits)

        func snapshot(wide: Bool) throws -> WorkspaceSnapshot {
            // sub sp,#32; str/ldr at sp+8; add sp,#32; ret.
            let words: [UInt32] = [0xd10083ff, wide ? 0xf90007e0 : 0xb9000be0,
                                   wide ? 0xf94007e1 : 0xb9400be1, 0x910083ff, 0xd65f03c0]
            var result = try makeFixture(functionEnd: 0x1014, instructionWords: words).snapshot
            result.addressOverrides[address] = persisted
            return result
        }
        func assertProjection(_ snapshot: WorkspaceSnapshot, name: String, width: UInt32,
                              file: StaticString = #filePath, line: UInt = #line) throws {
            let projection = try build(snapshot)
            XCTAssertEqual(projection.authoredInputs.localNames.map(\.name), [name], file: file, line: line)
            XCTAssertEqual(projection.authoredInputs.localNames.map(\.byteSize), [width], file: file, line: line)
            XCTAssertNoThrow(try requestProjection(projection), file: file, line: line)
            XCTAssertEqual(snapshot.stackLocalOverrides(forProcedureAt: 0x1000, in: slot), edits,
                           "projection preserves both authored records", file: file, line: line)
        }

        let narrow = try snapshot(wide: false)
        try assertProjection(narrow, name: "narrow_live", width: 4)
        // Reanalysis changes only the recovered storage; the same persisted edits survive.
        try assertProjection(snapshot(wide: true), name: "wide_saved", width: 8)
        try assertProjection(snapshot(wide: false), name: "narrow_live", width: 4)

        let store = WorkspaceStore(workspaceName: "local-reconciliation", snapshot: narrow,
                                   engine: AnalysisEngine(), autosaveScheduler: nil)
        let listed = try WorkspaceScriptingAPI(store: store).execute("stack-locals", arguments: .object([
            "address": .hex(0x1000),
        ]))
        XCTAssertEqual(listed["edits"]?["-24:-16"]?["orphan"], .bool(true))
        XCTAssertEqual(listed["edits"]?["-24:-20"]?["orphan"], .bool(false))
        // Explicit rebind: move the orphan's authored name to the currently live range,
        // then clear the old range through the normal undoable authoring entry point.
        store.editStackLocal(procedureStart: 0x1000, in: slot, entryRange: -24 ..< -20,
                             name: "wide_saved", typeName: "uint32_t")
        store.editStackLocal(procedureStart: 0x1000, in: slot, entryRange: -24 ..< -16,
                             name: "", typeName: "")
        let rebound = try build(store.snapshot)
        XCTAssertEqual(rebound.authoredInputs.localNames.map(\.name), ["wide_saved"])
        XCTAssertEqual(rebound.authoredInputs.localNames.map(\.byteSize), [4])
        XCTAssertNoThrow(try requestProjection(rebound))
        XCTAssertEqual(store.snapshot.stackLocalOverrides(forProcedureAt: 0x1000, in: slot).count, 1)
        store.editStackLocal(procedureStart: 0x1000, in: slot, entryRange: -24 ..< -20,
                             name: "", typeName: "")
        let cleared = try build(store.snapshot)
        XCTAssertTrue(cleared.authoredInputs.localNames.isEmpty)
        XCTAssertNoThrow(try requestProjection(cleared))
        XCTAssertTrue(store.snapshot.stackLocalOverrides(forProcedureAt: 0x1000, in: slot).isEmpty)
    }

    func testD09CaptureReusesOneVerificationAndRetiresOnRevisionChange() async throws {
        let owner = UUID()
        let revision = UUID()
        let store = NativeDecompilerValidatedImageStore()
        let fence = NativeDecompilerAdmissionFence()
        let admission = try XCTUnwrap(fence.advance())
        let snapshot = try makeFixture(byteCount: 128).snapshot
        let first = try await store.capture(
            owner: owner, revision: revision, snapshot: snapshot, imageSlot: slot,
            admissionToken: admission
        )
        let second = try await store.capture(
            owner: owner, revision: revision, snapshot: snapshot, imageSlot: slot,
            admissionToken: admission
        )
        XCTAssertEqual(first.fingerprint, second.fingerprint)
        let firstValidationCount = await store.validationCount()
        XCTAssertEqual(firstValidationCount, 1)

        let initial = try NativeDecompilerSnapshotBuilder.build(
            from: snapshot, validatedImage: second, functionID: functionID, budgets: budgets
        )
        var authored = snapshot
        authored.addressOverrides[ImageAddress(slot: slot, address: 0x1000)] = .init(
            customName: "authored_name"
        )
        let changedRequest = try NativeDecompilerSnapshotBuilder.build(
            from: authored, validatedImage: second, functionID: functionID, budgets: budgets
        )
        XCTAssertNotEqual(
            try requestProjection(initial).requestSHA256,
            try requestProjection(changedRequest).requestSHA256
        )

        let replacement = try makeFixture(byteCount: 132).snapshot
        let third = try await store.capture(
            owner: owner, revision: UUID(), snapshot: replacement, imageSlot: slot,
            admissionToken: admission
        )
        XCTAssertNotEqual(third.fingerprint, first.fingerprint)
        let secondValidationCount = await store.validationCount()
        XCTAssertEqual(secondValidationCount, 2)
        _ = fence.advance()
        await store.retire(owner: owner)
        let retiredCount = await store.captureCount()
        XCTAssertEqual(retiredCount, 0)
        do {
            _ = try await store.capture(
                owner: owner, revision: UUID(), snapshot: replacement, imageSlot: slot,
                admissionToken: admission
            )
            XCTFail("a superseded projection must not repopulate storage")
        } catch is CancellationError {}
    }

    func testMapsActualDecoderLookaheadWithoutReferencesOrWideningFunction() throws {
        let snapshot = try makeFixture(byteCount: 128).snapshot
        let projection = try build(snapshot)
        XCTAssertEqual(projection.function.entryAddress.value, 0x1000)
        XCTAssertEqual(projection.function.endAddressExclusive.value, 0x1008)
        XCTAssertEqual(projection.memoryRegions.map { $0.startAddress.value }, [0x1000, 0x1008])
        XCTAssertEqual(projection.memoryRegions.map { $0.rawBytes.count }, [8, 64])
        XCTAssertEqual(projection.memoryRegions[1].rawBytes, Data((8..<72).map { UInt8($0) }))
        XCTAssertEqual(projection.memoryRegions[1].rawBytes, projection.memoryRegions[1].effectiveBytes)
        XCTAssertEqual(projection.memoryRegions[1].permissions, .readExecute)
        XCTAssertEqual(projection.authoredInputs, .empty)
        XCTAssertTrue(snapshot.analysis(in: slot)?.xrefs.isEmpty == true)
    }

    func testSelectedPatchChangesRequestAndUndoRestoresRawIdentity() throws {
        let original = try makeFixture(byteCount: 128).snapshot
        let baseline = try build(original)
        let baselineRequest = try requestProjection(baseline)
        var edited = original
        edited.addressOverrides[ImageAddress(slot: slot, address: 0x1004)] = .init(patch: .arm64NOP)
        let projected = try build(edited)
        XCTAssertEqual(projected.memoryRegions[0].rawBytes, baseline.memoryRegions[0].rawBytes)
        XCTAssertNotEqual(projected.memoryRegions[0].effectiveBytes, baseline.memoryRegions[0].effectiveBytes)
        XCTAssertEqual(projected.memoryRegions[0].appliedPatchIDs, ["patch000001"])
        XCTAssertNotEqual(try requestProjection(projected).requestSHA256, baselineRequest.requestSHA256)
        let codec = NativeDecompilerWireCodec()
        let request = try requestProjection(projected).makeRequestEnvelope(requestID: requestID)
        XCTAssertEqual(try codec.decodeRequest(codec.encodeRequest(request, matching: requestID),
                                               matching: requestID), request)
        edited.addressOverrides.removeValue(forKey: ImageAddress(slot: slot, address: 0x1004))
        XCTAssertEqual(try requestProjection(build(edited)), baselineRequest)
    }

    func testPatchedDirectBranchAdmitsOnlyCodeInsideSelectedFunction() throws {
        let original = try makeFixture(byteCount: 128, functionEnd: 0x1010).snapshot
        let baseline = try requestProjection(build(original))
        var edited = original
        // At 0x1004, ARM64 B +8 reaches 0x100c inside the selected
        // function's verified executable extent.
        edited.addressOverrides[ImageAddress(slot: slot, address: 0x1004)] = .init(
            patch: BytePatch(bytes: [0x02, 0x00, 0x00, 0x14])
        )
        let selected = try build(edited)
        XCTAssertEqual(selected.function.endAddressExclusive.value, 0x1010)
        XCTAssertNotEqual(try requestProjection(selected).requestSHA256, baseline.requestSHA256)
        XCTAssertEqual(selected.memoryRegions[0].appliedPatchIDs, ["patch000001"])

        // B +12 reaches 0x1010, outside the v3 selected-function contract.
        edited.addressOverrides[ImageAddress(slot: slot, address: 0x1004)] = .init(
            patch: BytePatch(bytes: [0x03, 0x00, 0x00, 0x14])
        )
        assertProjectionError(.patchedControlFlowLeavesFunction) { try build(edited) }
        edited.addressOverrides.removeValue(forKey: ImageAddress(slot: slot, address: 0x1004))
        // Even an in-range conditional target is insufficient when its
        // fall-through exits the selected interval.
        edited.addressOverrides[ImageAddress(slot: slot, address: 0x100c)] = .init(
            patch: BytePatch(bytes: [0x00, 0x00, 0x00, 0x54])
        )
        assertProjectionError(.patchedControlFlowLeavesFunction) { try build(edited) }
        edited.addressOverrides.removeValue(forKey: ImageAddress(slot: slot, address: 0x100c))
        XCTAssertEqual(try requestProjection(build(edited)), baseline)
    }

    func testSelectedScalarBuildIgnoresUnrelatedUnsupportedCatalogType() throws {
        var snapshot = try makeFixture(byteCount: 128).snapshot
        snapshot.addressOverrides[ImageAddress(slot: slot, address: 0x1000)] = .init(
            signature: .init(returnType: "uint32_t")
        )
        let baseline = try build(snapshot)
        snapshot.typeDefinitions = [TypeDefinition(
            kind: .typedef,
            name: "VectorAlias",
            fields: [FieldDef(name: "VectorAlias", type: "uint8_t")],
            vectorByteSize: 16
        )]
        let selected = try build(snapshot)
        XCTAssertEqual(selected.authoredInputs, baseline.authoredInputs)
        XCTAssertEqual(selected.authoredInputs.typeDefinitions, [])

        snapshot.addressOverrides[ImageAddress(slot: slot, address: 0x1000)] = .init(
            signature: .init(returnType: "VectorAlias")
        )
        assertProjectionError(.invalidProjectedRequest) { try build(snapshot) }
    }

    func testUnmappedAuthoredSignatureIsOmittedBeforeTypeParsing() throws {
        var snapshot = try makeFixture(byteCount: 128).snapshot
        snapshot.mutateAnalysis(in: slot) { analysis in
            analysis.functions.append(.init(
                id: UUID(uuidString: "60000000-0000-0000-0000-000000000006")!,
                name: "unmapped", startAddress: 0x2000, endAddress: 0x2008,
                confidence: 1
            ))
        }
        try refreshFingerprint(in: &snapshot)
        snapshot.addressOverrides[ImageAddress(slot: slot, address: 0x2000)] = .init(
            signature: .init(returnType: "!")
        )
        let projection = try build(snapshot)
        XCTAssertTrue(projection.authoredInputs.signatures.isEmpty)
        XCTAssertEqual(projection.contextOmissions.omittedSignatureCount, 1)
        XCTAssertEqual(projection.contextOmissions.count(for: .unmapped), 1)
    }

    func testWritableAppliedTypeIsOmittedBeforeUnsupportedTypeAdmission() throws {
        var snapshot = try makeFixture(byteCount: 160, segments: [
            segment("__TEXT", vmStart: 0x1000, vmSize: 128, fileOffset: 0, fileSize: 128),
            segment("__DATA", vmStart: 0x2_00000, vmSize: 32,
                    fileOffset: 128, fileSize: 32, protections: 3),
        ]).snapshot
        snapshot.typeDefinitions = [TypeDefinition(
            kind: .typedef, name: "VectorAlias",
            fields: [FieldDef(name: "VectorAlias", type: "uint8_t")],
            vectorByteSize: 16
        )]
        snapshot.addressOverrides[ImageAddress(slot: slot, address: 0x2_00000)] = .init(
            appliedTypeName: "VectorAlias"
        )
        let omitted = try build(snapshot)
        XCTAssertTrue(omitted.authoredInputs.appliedTypes.isEmpty)
        XCTAssertTrue(omitted.authoredInputs.typeDefinitions.isEmpty)
        XCTAssertEqual(omitted.contextOmissions.omittedAppliedTypeCount, 1)
        XCTAssertGreaterThanOrEqual(omitted.contextOmissions.count(for: .writable), 1)

        var readable = try makeContextFixture()
        readable.typeDefinitions = snapshot.typeDefinitions
        readable.addressOverrides[ImageAddress(slot: slot, address: 0x1018)] = .init(
            appliedTypeName: "VectorAlias"
        )
        assertProjectionError(.invalidProjectedRequest) { try build(readable) }
    }

    func testDecoderLookaheadStopsAtFileBackedExecutableSegmentAndAllowsMissingTail() throws {
        let records = [segment("__TEXT", vmStart: 0x1000, vmSize: 16, fileOffset: 0, fileSize: 12),
            segment("__DATA", vmStart: 0x1010, vmSize: 16, fileOffset: 16, fileSize: 16, protections: 1)]
        let projection = try build(try makeFixture(byteCount: 32, segments: records).snapshot)
        XCTAssertEqual(projection.memoryRegions.map { $0.startAddress.value }, [0x1000, 0x1008])
        XCTAssertEqual(projection.memoryRegions.map { $0.rawBytes.count }, [8, 4])
        let noTail = try build(try makeFixture(byteCount: 8).snapshot)
        XCTAssertEqual(noTail.memoryRegions.count, 1)
        XCTAssertEqual(noTail.function.endAddressExclusive.value, 0x1008)
    }

    func testDecoderLookaheadMaterializesPatchedBytesButRejectsUnauthoritativeBytes() throws {
        var patched = try makeFixture(byteCount: 128).snapshot
        patched.addressOverrides[ImageAddress(slot: slot, address: 0x100c)] = .init(patch: .arm64NOP)
        let patchedProjection = try build(patched)
        XCTAssertNotEqual(patchedProjection.memoryRegions[1].rawBytes, patchedProjection.memoryRegions[1].effectiveBytes)
        XCTAssertEqual(patchedProjection.memoryRegions[1].appliedPatchIDs, ["patch000001"])
        patched.addressOverrides = [ImageAddress(slot: slot, address: 0x1048): .init(patch: .arm64NOP)]
        XCTAssertNoThrow(try build(patched))
        let relocation = RelocationSummary(id: UUID(), address: 0x100c, sectionName: "__TEXT",
            typeCode: 0, typeName: nil, symbolName: nil, symbolIndex: nil, addend: nil, widthInBytes: 4)
        assertProjectionError(.intersectingRelocation) {
            try build(try makeFixture(byteCount: 128, relocations: [relocation]).snapshot)
        }
        var unavailable = try makeFixture(byteCount: 128).snapshot
        unavailable.mutateAnalysis(in: slot) { $0.identityEffectiveByteRanges.removeAll() }
        try refreshFingerprint(in: &unavailable)
        assertProjectionError(.effectiveLoadImageAuthorityUnavailable) { try build(unavailable) }
        var changed = try makeFixture(byteCount: 128).snapshot
        changed.mutateAnalysis(in: slot) { $0.imageBytes[16] ^= 0xff }
        assertProjectionError(.selectedSliceMismatch) { try build(changed) }
    }

    func testAddsCalleeAndTableContextWithoutWideningSelectedFunctionIdentity() throws {
        var snapshot = try makeContextFixture()
        snapshot.addressOverrides[ImageAddress(slot: slot, address: 0x1008)] = .init(
            customName: "authored_callee", signature: .init(returnType: "uint32_t")
        )
        // Unrelated authored functions are ranked last but still supplied while budget remains.
        snapshot.addressOverrides[ImageAddress(slot: slot, address: 0x1010)] = .init(
            signature: .init(noReturnState: .noReturn)
        )
        let projection = try build(snapshot)
        XCTAssertEqual(projection.function.entryAddress.value, 0x1000)
        XCTAssertEqual(projection.function.endAddressExclusive.value, 0x1008)
        XCTAssertEqual(projection.memoryRegions.map { $0.startAddress.value }, [0x1000, 0x1008, 0x1018])
        XCTAssertEqual(projection.memoryRegions.map { $0.rawBytes.count }, [8, 16, 8])
        XCTAssertEqual(projection.memoryRegions.map(\.permissions), [.readExecute, .readExecute, .read])
        XCTAssertEqual(projection.authoredInputs.names.map(\.name), ["authored_callee"])
        XCTAssertEqual(projection.authoredInputs.signatures.map { $0.functionAddress.value }, [0x1008, 0x1010])
        XCTAssertTrue(projection.memoryRegions.allSatisfy { $0.rawBytes == $0.effectiveBytes && $0.appliedPatchIDs.isEmpty })
        XCTAssertEqual(projection.contextOmissions, .empty)
        let envelope = try requestProjection(projection).makeRequestEnvelope(requestID: requestID)
        let codec = NativeDecompilerWireCodec()
        let bytes = try codec.encodeRequest(envelope, matching: requestID)
        XCTAssertEqual(try codec.decodeRequest(bytes, matching: requestID), envelope)
    }

    func testContextMaterializesPatchedDataAndOmitsRelocatedAndUnattestedSubjects() throws {
        let baseline = try makeContextFixture()
        var patched = baseline
        patched.addressOverrides[ImageAddress(slot: slot, address: 0x101c)] = .init(patch: .arm64NOP)
        let patchedProjection = try build(patched)
        XCTAssertEqual(patchedProjection.memoryRegions.map { $0.startAddress.value }, [0x1000, 0x1008, 0x1018])
        XCTAssertEqual(patchedProjection.memoryRegions.last?.appliedPatchIDs, ["patch000001"])
        XCTAssertNotEqual(patchedProjection.memoryRegions.last?.rawBytes,
                          patchedProjection.memoryRegions.last?.effectiveBytes)
        XCTAssertEqual(patchedProjection.contextOmissions.count(for: .patchIntersection), 0)

        var relocated = baseline
        var analysis = try XCTUnwrap(relocated.analysis(in: slot))
        analysis.relocations = [RelocationSummary(id: UUID(), address: 0x101c, sectionName: "__const",
            typeCode: 0, typeName: nil, symbolName: nil, symbolIndex: nil, addend: nil, widthInBytes: 4)]
        relocated.analysisBySlot[slot] = analysis
        try refreshFingerprint(in: &relocated)
        let relocatedProjection = try build(relocated)
        XCTAssertEqual(relocatedProjection.memoryRegions.map { $0.startAddress.value }, [0x1000, 0x1008])
        XCTAssertEqual(relocatedProjection.contextOmissions.count(for: .relocationIntersection), 1)

        var unattested = baseline
        analysis = try XCTUnwrap(unattested.analysis(in: slot))
        analysis.identityEffectiveByteRanges.removeAll { !$0.isExecutable }
        unattested.analysisBySlot[slot] = analysis
        try refreshFingerprint(in: &unattested)
        unattested.addressOverrides[ImageAddress(slot: slot, address: 0x1018)] = .init(customName: "unattested_data")
        let unattestedProjection = try build(unattested)
        XCTAssertTrue(unattestedProjection.authoredInputs.names.isEmpty)
        XCTAssertEqual(unattestedProjection.memoryRegions.map { $0.startAddress.value }, [0x1000, 0x1008])
        XCTAssertEqual(unattestedProjection.contextOmissions.count(for: .unattested), 2)
        XCTAssertEqual(unattestedProjection.contextOmissions.omittedNameCount, 1)
        XCTAssertEqual(unattestedProjection.contextOmissions.entries.map(\.subjectKind), [.authoredData, .derivedData])
    }

    func testDataNameGetsReadonlyContextAndSiblingImageInputsDoNotCross() throws {
        var snapshot = try makeContextFixture()
        snapshot.addressOverrides[ImageAddress(slot: slot, address: 0x1018)] = .init(customName: "local_data")
        snapshot.addressOverrides[ImageAddress(slot: .primary, address: 0x1018)] = .init(customName: "sibling_data")
        let projection = try build(snapshot)
        XCTAssertEqual(projection.authoredInputs.names.map(\.name), ["local_data"])
        XCTAssertEqual(projection.authoredInputs.names.first?.subjectKind, .data)
        XCTAssertEqual(projection.memoryRegions.last?.permissions, .read)
        // A data name inside another function's code cannot be hosted; it is omitted, not fatal.
        var unsupported = snapshot
        unsupported.addressOverrides[ImageAddress(slot: slot, address: 0x100c)] = .init(customName: "data_inside_code")
        let omitted = try build(unsupported)
        XCTAssertEqual(omitted.authoredInputs.names.map(\.name), ["local_data"])
        XCTAssertEqual(omitted.contextOmissions.count(for: .unmapped), 1)
        XCTAssertEqual(omitted.contextOmissions.entries.first?.startAddress, 0x100c)
        // The same subject inside the selected function's own bytes still rejects the request.
        var selectedConflict = snapshot
        selectedConflict.addressOverrides[ImageAddress(slot: slot, address: 0x1004)] = .init(customName: "data_inside_selected")
        assertProjectionError(.effectiveLoadImageAuthorityUnavailable) { try build(selectedConflict) }
    }

    func testOversizedAuthoredSubjectIsOmittedWholeForBudgetNeverTruncated() throws {
        var snapshot = try makeFixture(byteCount: 1_048_588).snapshot
        var analysis = try XCTUnwrap(snapshot.analysis(in: slot))
        analysis.functions.append(.init(id: UUID(), name: "large_callee", startAddress: 0x1008,
                                        endAddress: 0x10100c, confidence: 1))
        snapshot.analysisBySlot[slot] = analysis
        try refreshFingerprint(in: &snapshot)
        snapshot.addressOverrides[ImageAddress(slot: slot, address: 0x1008)] = .init(signature: .init(returnType: "int"))
        let projection = try build(snapshot)
        XCTAssertTrue(projection.authoredInputs.signatures.isEmpty)
        // Only the selected function and its decoder lookahead; no partial callee bytes.
        XCTAssertEqual(projection.memoryRegions.map { $0.startAddress.value }, [0x1000, 0x1008])
        XCTAssertEqual(projection.memoryRegions.map { $0.rawBytes.count }, [8, 64])
        XCTAssertEqual(projection.contextOmissions.count(for: .budget), 1)
        XCTAssertEqual(projection.contextOmissions.omittedSignatureCount, 1)
        XCTAssertEqual(projection.contextOmissions.entries.first?.endAddressExclusive, 0x10100c)
    }

    func testUnrelatedLargeAuthoredFunctionNoLongerExhaustsBudgetForSmallSelectedFunction() throws {
        var snapshot = try makeFixture(byteCount: 0x102000).snapshot
        var analysis = try XCTUnwrap(snapshot.analysis(in: slot))
        analysis.functions += [
            .init(id: UUID(), name: "callee", startAddress: 0x1008, endAddress: 0x1010, confidence: 1),
            .init(id: UUID(), name: "unrelated_large", startAddress: 0x2000, endAddress: 0x102000, confidence: 1),
        ]
        analysis.xrefs = [.init(id: UUID(), from: 0x1000, to: 0x1008, kind: XRefKind.call)]
        snapshot.analysisBySlot[slot] = analysis
        try refreshFingerprint(in: &snapshot)
        snapshot.addressOverrides[ImageAddress(slot: slot, address: 0x1008)] = .init(signature: .init(returnType: "int"))
        snapshot.addressOverrides[ImageAddress(slot: slot, address: 0x2000)] = .init(signature: .init(returnType: "int"))

        let projection = try build(snapshot)
        XCTAssertEqual(projection.function.endAddressExclusive.value, 0x1008)
        XCTAssertEqual(projection.authoredInputs.signatures.map { $0.functionAddress.value }, [0x1008])
        XCTAssertEqual(projection.memoryRegions.map { $0.startAddress.value }, [0x1000, 0x1008])
        let omissions = projection.contextOmissions
        XCTAssertEqual(omissions.totalCount, 1)
        XCTAssertEqual(omissions.count(for: .budget), 1)
        XCTAssertEqual(omissions.omittedSignatureCount, 1)
        XCTAssertEqual(omissions.entries, [.init(subjectKind: .authoredFunction, startAddress: 0x2000,
            endAddressExclusive: 0x102000, reason: .budget, relevanceDistance: nil)])
    }

    func testDirectCalleeIsKeptBeforeLowerAddressedUnrelatedAuthoredSubject() throws {
        // Either subject fits alone; both together exceed the 1 MiB context budget. Address
        // order would admit the unrelated subject first; relevance order admits the callee.
        var snapshot = try makeFixture(byteCount: 0x180000).snapshot
        var analysis = try XCTUnwrap(snapshot.analysis(in: slot))
        analysis.functions += [
            .init(id: UUID(), name: "unrelated", startAddress: 0x1010, endAddress: 0x81010, confidence: 1),
            .init(id: UUID(), name: "callee", startAddress: 0x100000, endAddress: 0x180000, confidence: 1),
        ]
        analysis.xrefs = [.init(id: UUID(), from: 0x1004, to: 0x100000, kind: XRefKind.call)]
        snapshot.analysisBySlot[slot] = analysis
        try refreshFingerprint(in: &snapshot)
        snapshot.addressOverrides[ImageAddress(slot: slot, address: 0x1010)] = .init(signature: .init(returnType: "int"))
        snapshot.addressOverrides[ImageAddress(slot: slot, address: 0x100000)] = .init(signature: .init(returnType: "int"))

        let projection = try build(snapshot)
        XCTAssertEqual(projection.authoredInputs.signatures.map { $0.functionAddress.value }, [0x100000])
        XCTAssertEqual(projection.memoryRegions.map { $0.startAddress.value }, [0x1000, 0x1008, 0x100000])
        XCTAssertEqual(projection.memoryRegions.map { $0.rawBytes.count }, [8, 64, 0x80000])
        XCTAssertEqual(projection.contextOmissions.entries, [.init(subjectKind: .authoredFunction,
            startAddress: 0x1010, endAddressExclusive: 0x81010, reason: .budget, relevanceDistance: nil)])

        // Deterministic: an identical workspace yields identical regions, inputs, manifest and digest.
        let again = try build(snapshot)
        XCTAssertEqual(again, projection)
        XCTAssertEqual(try requestProjection(again).requestSHA256, try requestProjection(projection).requestSHA256)
        XCTAssertEqual(again.contextOmissions.identitySHA256, projection.contextOmissions.identitySHA256)
    }

    func testWritableDataRegionIsOmittedWithReasonWhileRequestIsAdmitted() throws {
        var snapshot = try makeContextFixture(dataProtections: 3)
        snapshot.addressOverrides[ImageAddress(slot: slot, address: 0x1018)] = .init(customName: "writable_global")
        let projection = try build(snapshot)
        XCTAssertEqual(projection.function.entryAddress.value, 0x1000)
        XCTAssertTrue(projection.authoredInputs.names.isEmpty)
        XCTAssertFalse(projection.memoryRegions.contains { $0.startAddress.value >= 0x1018 })
        XCTAssertTrue(projection.memoryRegions.allSatisfy { $0.permissions == .readExecute })
        let omissions = projection.contextOmissions
        XCTAssertEqual(omissions.count(for: .writable), 2)
        XCTAssertEqual(omissions.omittedNameCount, 1)
        XCTAssertEqual(omissions.entries.map(\.subjectKind), [.authoredData, .derivedData])
        XCTAssertEqual(omissions.entries.map(\.relevanceDistance), [1, 1])
        XCTAssertNoThrow(try requestProjection(projection).makeRequestEnvelope(requestID: requestID))
    }

    func testSelectedFunctionMaterializesPatchButRejectsRelocation() throws {
        var patched = try makeContextFixture(dataProtections: 3)
        patched.addressOverrides[ImageAddress(slot: slot, address: 0x1004)] = .init(patch: .arm64NOP)
        let patchedProjection = try build(patched)
        XCTAssertEqual(patchedProjection.memoryRegions[0].appliedPatchIDs, ["patch000001"])
        XCTAssertNotEqual(patchedProjection.memoryRegions[0].rawBytes,
                          patchedProjection.memoryRegions[0].effectiveBytes)

        var relocated = try makeContextFixture(dataProtections: 3)
        var analysis = try XCTUnwrap(relocated.analysis(in: slot))
        analysis.relocations = [RelocationSummary(id: UUID(), address: 0x1000, sectionName: "__text",
            typeCode: 0, typeName: nil, symbolName: nil, symbolIndex: nil, addend: nil, widthInBytes: 4)]
        relocated.analysisBySlot[slot] = analysis
        try refreshFingerprint(in: &relocated)
        assertProjectionError(.intersectingRelocation) { try build(relocated) }
    }

    func testContextOmissionManifestChangesRequestAndCacheIdentity() throws {
        let complete = try build(try makeContextFixture())
        var relocated = try makeContextFixture()
        relocated.mutateAnalysis(in: slot) { analysis in
            analysis.relocations = [RelocationSummary(id: UUID(), address: 0x101c,
                sectionName: "__const", typeCode: 0, typeName: nil, symbolName: nil,
                symbolIndex: nil, addend: nil, widthInBytes: 4)]
        }
        try refreshFingerprint(in: &relocated)
        let omitted = try build(relocated)
        XCTAssertTrue(complete.contextOmissions.isEmpty)
        XCTAssertFalse(omitted.contextOmissions.isEmpty)
        XCTAssertNotEqual(complete.contextOmissions.identitySHA256, omitted.contextOmissions.identitySHA256)
        XCTAssertNotEqual(try requestProjection(complete), try requestProjection(omitted))

        // Even with byte-identical wire content, a different omission set is a different request.
        let relabeled = NativeDecompilerSnapshotProjection(
            coordinate: complete.coordinate, target: complete.target, image: complete.image,
            function: complete.function, memoryRegions: complete.memoryRegions,
            symbols: complete.symbols, authoredInputs: complete.authoredInputs,
            contextOmissions: omitted.contextOmissions
        )
        let completeRequest = try requestProjection(complete)
        let relabeledRequest = try requestProjection(relabeled)
        XCTAssertEqual(completeRequest.requestSHA256, relabeledRequest.requestSHA256)
        XCTAssertNotEqual(completeRequest.contextOmissionSHA256, relabeledRequest.contextOmissionSHA256)
        XCTAssertNotEqual(completeRequest, relabeledRequest)
        XCTAssertEqual(try NativeDecompilerSubmission(snapshot: relabeled).projection.contextOmissions,
                       omitted.contextOmissions)
    }

    func testAppliedReadonlyObjectKeepsExactExtentAndOmitsWritableAuthority() throws {
        var snapshot = try makeContextFixture()
        snapshot.typeDefinitions = [.init(kind: .struct, name: "Scalar",
            fields: [.init(name: "value", type: "uint64_t")])]
        snapshot.addressOverrides[ImageAddress(slot: slot, address: 0x1018)] = .init(
            customName: "typed_table", appliedTypeName: "Scalar")
        let projection = try build(snapshot)
        XCTAssertEqual(projection.authoredInputs.appliedTypes.count, 1)
        XCTAssertEqual(projection.authoredInputs.appliedTypes.first?.byteCount.value, 8)
        XCTAssertEqual(projection.memoryRegions.last?.startAddress.value, 0x1018)
        XCTAssertEqual(projection.memoryRegions.last?.rawBytes.count, 8)
        XCTAssertEqual(projection.memoryRegions.last?.permissions, .read)

        var writable = try makeContextFixture(dataProtections: 3)
        writable.typeDefinitions = snapshot.typeDefinitions
        writable.addressOverrides = snapshot.addressOverrides
        let omitted = try build(writable)
        XCTAssertTrue(omitted.authoredInputs.appliedTypes.isEmpty)
        XCTAssertTrue(omitted.authoredInputs.names.isEmpty)
        XCTAssertTrue(omitted.authoredInputs.typeDefinitions.isEmpty)
        XCTAssertEqual(omitted.contextOmissions.omittedAppliedTypeCount, 1)
        XCTAssertEqual(omitted.contextOmissions.count(for: .writable), 3)
    }

    func testBuildsImmutableRawArm64ProjectionAndDeterministicEnvelope() throws {
        var fixture = try makeFixture()
        let first = try build(fixture.snapshot)
        let second = try build(fixture.snapshot)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.coordinate.imageSlot, slot)
        XCTAssertEqual(first.coordinate.ownerBinaryID, binaryID)
        XCTAssertEqual(
            first.coordinate.analysisInputFingerprintSHA256,
            fixture.snapshot.analysis(in: slot)?.analysisInputFingerprint?.overallSHA256
        )
        XCTAssertEqual(first.target.languageID, "AARCH64:LE:64:AppleSilicon")
        XCTAssertEqual(first.target.compilerSpecID, "default")
        XCTAssertEqual(first.image.imageID, binaryID.uuidString.lowercased())
        XCTAssertEqual(first.image.uuid, imageUUID)
        XCTAssertEqual(first.image.preferredLoadAddress.value, 0x1000)
        XCTAssertEqual(first.function.functionID, functionID.uuidString.lowercased())
        XCTAssertEqual(first.function.entryAddress.value, 0x1000)
        XCTAssertEqual(first.function.endAddressExclusive.value, 0x1008)
        XCTAssertEqual(first.memoryRegions.count, 2)
        XCTAssertEqual(first.memoryRegions[0].name, "__TEXT")
        XCTAssertEqual(first.memoryRegions[0].startAddress.value, 0x1000)
        XCTAssertEqual(first.memoryRegions[0].permissions, .readExecute)
        let expectedFunctionBytes = Data((0 ..< 8).map { UInt8($0) })
        XCTAssertEqual(first.memoryRegions[0].rawBytes, expectedFunctionBytes)
        XCTAssertEqual(first.memoryRegions[0].effectiveBytes, expectedFunctionBytes)
        XCTAssertEqual(first.memoryRegions[0].appliedPatchIDs, [])
        XCTAssertEqual(first.authoredInputs, .empty)
        XCTAssertEqual(first.symbols.map(\.name), ["_entry", "_mystery"])
        XCTAssertEqual(first.symbols.map(\.kind), [.function, .unknown])
        let firstRequestProjection = try requestProjection(first)
        XCTAssertEqual(firstRequestProjection.requestSHA256.count, 64)
        XCTAssertTrue(firstRequestProjection.requestSHA256.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        })

        let firstEnvelope = firstRequestProjection.makeRequestEnvelope(requestID: requestID)
        let secondEnvelope = firstRequestProjection.makeRequestEnvelope(requestID: requestID)
        let alternateEnvelope = firstRequestProjection.makeRequestEnvelope(requestID: UUID())
        XCTAssertEqual(firstEnvelope, secondEnvelope)
        XCTAssertEqual(firstEnvelope.requestID, requestID)
        XCTAssertEqual(firstEnvelope.body.requestID, requestID)
        XCTAssertEqual(firstEnvelope.body.requestSHA256, firstRequestProjection.requestSHA256)
        XCTAssertEqual(alternateEnvelope.body.requestSHA256, firstRequestProjection.requestSHA256)
        XCTAssertFalse(String(reflecting: first).contains("/must/not/cross"))
        XCTAssertFalse(String(reflecting: first).contains("/also/must/not/cross"))

        let codec = NativeDecompilerWireCodec()
        let firstEncoding = try codec.encodeRequest(firstEnvelope, matching: requestID)
        let secondEncoding = try codec.encodeRequest(secondEnvelope, matching: requestID)
        XCTAssertEqual(firstEncoding, secondEncoding)
        XCTAssertEqual(try codec.decodeRequest(firstEncoding, matching: requestID), firstEnvelope)

        var analysis = try XCTUnwrap(fixture.snapshot.analysis(in: slot))
        analysis.imageBytes = Data(repeating: 0xFF, count: analysis.imageBytes.count)
        fixture.snapshot.analysisBySlot[slot] = analysis
        XCTAssertEqual(first.memoryRegions[0].rawBytes, expectedFunctionBytes)
        XCTAssertEqual(firstRequestProjection.makeRequestEnvelope(requestID: requestID), firstEnvelope)
    }

    func testCanonicalDigestIsOrderIndependentAndSensitiveToProjectedFields() throws {
        let fixture = try makeFixture()
        let baseline = try build(fixture.snapshot)

        var reordered = fixture.snapshot
        var reorderedAnalysis = try XCTUnwrap(reordered.analysis(in: slot))
        reorderedAnalysis.symbols.reverse()
        reordered.analysisBySlot[slot] = reorderedAnalysis
        XCTAssertEqual(
            try requestProjection(build(reordered)).requestSHA256,
            try requestProjection(baseline).requestSHA256
        )

        var changedBytes = fixture.snapshot
        var changedAnalysis = try XCTUnwrap(changedBytes.analysis(in: slot))
        changedAnalysis.imageBytes[0] ^= 0xFF
        changedBytes.analysisBySlot[slot] = changedAnalysis
        try refreshArtifactAndFingerprint(in: &changedBytes)
        XCTAssertNotEqual(
            try requestProjection(build(changedBytes)).requestSHA256,
            try requestProjection(baseline).requestSHA256
        )
    }

    func testRejectsWrongSlotOwnerAndFunctionCoordinates() throws {
        let fixture = try makeFixture()
        assertProjectionError(.binaryNotFound) {
            try NativeDecompilerSnapshotBuilder.build(
                from: fixture.snapshot,
                imageSlot: ImageSlot(rawValue: 99),
                functionID: functionID,
                budgets: budgets
            )
        }

        var wrongOwner = fixture.snapshot
        var analysis = try XCTUnwrap(wrongOwner.analysis(in: slot))
        analysis.analysisInputFingerprint?.binaryID = UUID()
        wrongOwner.analysisBySlot[slot] = analysis
        assertProjectionError(.analysisCoordinateMismatch) { try build(wrongOwner) }

        var noAnalysis = fixture.snapshot
        noAnalysis.analysisBySlot = [:]
        assertProjectionError(.analysisNotFound) { try build(noAnalysis) }

        var duplicateOwner = fixture.snapshot
        duplicateOwner.binaries.append(duplicateOwner.binaries[0])
        assertProjectionError(.binaryNotFound) { try build(duplicateOwner) }

        assertProjectionError(.functionNotFound) {
            try NativeDecompilerSnapshotBuilder.build(
                from: fixture.snapshot,
                imageSlot: slot,
                functionID: UUID(),
                budgets: budgets
            )
        }

        var duplicateFunction = fixture.snapshot
        var duplicateAnalysis = try XCTUnwrap(duplicateFunction.analysis(in: slot))
        duplicateAnalysis.functions.append(duplicateAnalysis.functions[0])
        duplicateFunction.analysisBySlot[slot] = duplicateAnalysis
        try refreshFingerprint(in: &duplicateFunction)
        assertProjectionError(.functionNotFound) { try build(duplicateFunction) }
    }

    func testRejectsCurrentFunctionDriftFromStoredCompleteFingerprint() throws {
        let fixture = try makeFixture()

        var renamed = fixture.snapshot
        var renamedAnalysis = try XCTUnwrap(renamed.analysis(in: slot))
        renamedAnalysis.functions[0].name = "entry_after_stale_analysis"
        renamed.analysisBySlot[slot] = renamedAnalysis
        assertProjectionError(.analysisFingerprintMismatch) { try build(renamed) }

        var resized = fixture.snapshot
        var resizedAnalysis = try XCTUnwrap(resized.analysis(in: slot))
        resizedAnalysis.functions[0].endAddress = 0x100C
        resized.analysisBySlot[slot] = resizedAnalysis
        assertProjectionError(.analysisFingerprintMismatch) { try build(resized) }
    }

    func testRejectsTamperedStoredFacetAndOverallFingerprintDigests() throws {
        let fixture = try makeFixture()

        var facetTampered = fixture.snapshot
        var facetAnalysis = try XCTUnwrap(facetTampered.analysis(in: slot))
        var facetFingerprint = try XCTUnwrap(facetAnalysis.analysisInputFingerprint)
        let functionFacetIndex = try XCTUnwrap(
            facetFingerprint.facets.firstIndex { $0.kind == .functions }
        )
        facetFingerprint.facets[functionFacetIndex].sha256 = String(repeating: "1", count: 64)
        facetAnalysis.analysisInputFingerprint = facetFingerprint
        facetTampered.analysisBySlot[slot] = facetAnalysis
        assertProjectionError(.analysisFingerprintMismatch) { try build(facetTampered) }

        var overallTampered = fixture.snapshot
        var overallAnalysis = try XCTUnwrap(overallTampered.analysis(in: slot))
        overallAnalysis.analysisInputFingerprint?.overallSHA256 = String(repeating: "f", count: 64)
        overallTampered.analysisBySlot[slot] = overallAnalysis
        assertProjectionError(.analysisFingerprintMismatch) { try build(overallTampered) }
    }

    func testRejectsUnverifiedMissingIdentityUUIDLayoutAndFingerprint() throws {
        let fixture = try makeFixture()

        var unverified = fixture.snapshot
        unverified.binaries[0].artifactIntegrityState = .unavailable
        assertProjectionError(.unverifiedArtifact) { try build(unverified) }

        var noIdentity = fixture.snapshot
        noIdentity.binaries[0].artifactIdentity = nil
        assertProjectionError(.missingArtifactIdentity) { try build(noIdentity) }

        var noUUID = try makeFixture(uuid: nil).snapshot
        assertProjectionError(.missingArtifactUUID) { try build(noUUID) }
        noUUID.binaries[0].artifactIdentity = nil

        let zeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        assertProjectionError(.missingArtifactUUID) {
            try build(try makeFixture(uuid: zeroUUID).snapshot)
        }

        var noLayout = fixture.snapshot
        noLayout.binaries[0].preferredSegmentLayout = nil
        assertProjectionError(.missingSegmentLayout) { try build(noLayout) }

        var noFingerprint = fixture.snapshot
        var analysis = try XCTUnwrap(noFingerprint.analysis(in: slot))
        analysis.analysisInputFingerprint = nil
        noFingerprint.analysisBySlot[slot] = analysis
        assertProjectionError(.missingAnalysisFingerprint) { try build(noFingerprint) }
    }

    func testProjectsAcceptedArm64AndArm64eArtifactProfiles() throws {
        let arm64WithCapabilities = try build(
            try makeFixture(cpuSubtype: Int32(bitPattern: 0x8000_0000)).snapshot
        )
        XCTAssertEqual(arm64WithCapabilities.target.normalizedVariant, .arm64)
        XCTAssertEqual(arm64WithCapabilities.target.rawCPUSubtype, "80000000")
        XCTAssertEqual(arm64WithCapabilities.target.recognizedCapabilityBits, "80000000")
        XCTAssertNil(arm64WithCapabilities.target.pointerAuthABIVersion)

        let arm64e = try build(try makeFixture(cpuSubtype: 2).snapshot)
        XCTAssertEqual(arm64e.target.normalizedVariant, .arm64e)
        XCTAssertEqual(arm64e.target.rawCPUSubtype, "00000002")
        XCTAssertEqual(arm64e.target.recognizedCapabilityBits, "00000000")
        XCTAssertNil(arm64e.target.pointerAuthABIVersion)

        let arm64eV0 = try build(
            try makeFixture(cpuSubtype: Int32(bitPattern: 0x8000_0002)).snapshot
        )
        XCTAssertEqual(arm64eV0.target.normalizedVariant, .arm64e)
        XCTAssertEqual(arm64eV0.target.rawCPUSubtype, "80000002")
        XCTAssertEqual(arm64eV0.target.recognizedCapabilityBits, "80000000")
        XCTAssertEqual(arm64eV0.target.pointerAuthABIVersion, 0)
    }

    func testRejectsUnsupportedArm64SubtypeAndNonArm64Artifacts() throws {
        assertProjectionError(.unsupportedArchitecture) {
            try build(try makeFixture(cpuSubtype: 3).snapshot)
        }
        assertProjectionError(.unsupportedArchitecture) {
            try build(try makeFixture(cpuType: MachOConstants.cpuTypeX86_64, cpuSubtype: 3).snapshot)
        }
    }

    func testPreferredLoadAddressIsTheHeaderSegmentBaseForAVimLikeLayout() throws {
        // /usr/bin/vim arm64e (otool -l): __DATA zero-fill pushes __LINKEDIT's
        // vmaddr - fileoff to 0x100010000 while every other segment gives 0x100000000.
        let vimLike = [
            segment("__PAGEZERO", vmStart: 0, vmSize: 0x1_0000_0000, fileOffset: 0, fileSize: 0,
                protections: 0),
            segment("__TEXT", vmStart: 0x1_0000_0000, vmSize: 0x26_c000, fileOffset: 0,
                fileSize: 0x26_c000),
            segment("__DATA_CONST", vmStart: 0x1_0026_c000, vmSize: 0x1_4000, fileOffset: 0x26_c000,
                fileSize: 0x1_4000, protections: 3),
            segment("__DATA", vmStart: 0x1_0028_0000, vmSize: 0x3_8000, fileOffset: 0x28_0000,
                fileSize: 0x2_8000, protections: 3),
            segment("__LINKEDIT", vmStart: 0x1_002b_8000, vmSize: 0x1_0000, fileOffset: 0x2a_8000,
                fileSize: 0x1_0000, protections: 1),
        ]
        let verified = try NativeDecompilerSnapshotBuilder.verifyLayout(
            vimLike, selectedSliceByteCount: 0x2b_8000
        )
        XCTAssertEqual(
            try NativeDecompilerSnapshotBuilder.derivePreferredLoadAddress(from: verified),
            0x1_0000_0000
        )

        // The same relation through the whole projection: a header segment plus a data
        // segment whose vmaddr - fileoff differs (formerly refused as ambiguous).
        let differingDataRelation = [
            segment("__TEXT", vmStart: 0x1000, vmSize: 4, fileOffset: 0, fileSize: 4),
            segment("__DATA", vmStart: 0x2000, vmSize: 4, fileOffset: 4, fileSize: 4, protections: 3),
        ]
        let projection = try build(try makeFixture(
            byteCount: 8, segments: differingDataRelation, functionEnd: 0x1004
        ).snapshot)
        XCTAssertEqual(projection.image.preferredLoadAddress.value, 0x1000)
        XCTAssertEqual(projection.memoryRegions.first?.startAddress.value, 0x1000)
        XCTAssertNoThrow(try requestProjection(projection))
    }

    func testPreferredLoadAddressFailsClosedWithoutAHeaderSegmentOrOnBadRelations() throws {
        // No mapped, file-backed segment maps slice offset 0 (the Mach-O header).
        let noHeader = try NativeDecompilerSnapshotBuilder.verifyLayout([
            segment("__TEXT", vmStart: 0x1000, vmSize: 16, fileOffset: 16, fileSize: 16),
        ], selectedSliceByteCount: 32)
        XCTAssertThrowsError(try NativeDecompilerSnapshotBuilder.derivePreferredLoadAddress(from: noHeader)) {
            XCTAssertEqual($0 as? NativeDecompilerSnapshotProjectionError, .missingHeaderMappingSegment)
        }
        // A zero-fill-only segment at file offset 0 (__PAGEZERO style) maps no header bytes.
        let zeroFillOnly = try NativeDecompilerSnapshotBuilder.verifyLayout([
            segment("__PAGEZERO", vmStart: 0, vmSize: 0x1000, fileOffset: 0, fileSize: 0, protections: 0),
            segment("__TEXT", vmStart: 0x1010, vmSize: 16, fileOffset: 16, fileSize: 16),
        ], selectedSliceByteCount: 32)
        XCTAssertThrowsError(try NativeDecompilerSnapshotBuilder.derivePreferredLoadAddress(from: zeroFillOnly)) {
            XCTAssertEqual($0 as? NativeDecompilerSnapshotProjectionError, .missingHeaderMappingSegment)
        }
        assertProjectionError(.missingHeaderMappingSegment) {
            try build(try makeFixture(byteCount: 32, segments: [
                segment("__TEXT", vmStart: 0x1000, vmSize: 16, fileOffset: 16, fileSize: 16),
            ]).snapshot)
        }
        // A mapped file-backed segment whose vmaddr lies below its file offset (a negative
        // relation) is still malformed, even when the header segment is sound.
        let negative = try NativeDecompilerSnapshotBuilder.verifyLayout([
            segment("__TEXT", vmStart: 0x1000, vmSize: 16, fileOffset: 0, fileSize: 16),
            segment("__DATA", vmStart: 0x8, vmSize: 8, fileOffset: 16, fileSize: 8, protections: 3),
        ], selectedSliceByteCount: 32)
        XCTAssertThrowsError(try NativeDecompilerSnapshotBuilder.derivePreferredLoadAddress(from: negative)) {
            XCTAssertEqual($0 as? NativeDecompilerSnapshotProjectionError, .invalidSegmentLayout)
        }
        // An overflowing header segment never reaches base derivation (the persisted layout
        // model rejects it too, so only the builder's own verification is exercised here).
        XCTAssertThrowsError(try NativeDecompilerSnapshotBuilder.verifyLayout([
            segment("__TEXT", vmStart: UInt64.max - 7, vmSize: 16, fileOffset: 0, fileSize: 16),
        ], selectedSliceByteCount: 32)) {
            XCTAssertEqual($0 as? NativeDecompilerSnapshotProjectionError, .invalidSegmentLayout)
        }
    }

    /// One real system image, one function: the parser's own layout for /usr/bin/vim's
    /// arm64e slice (whose __LINKEDIT vmaddr - fileoff differs from the header segment's)
    /// must project. Parse-only; no analysis, decode or sweep of the image.
    func testProjectsRealVimArm64eSliceWhoseLinkeditRelationDiffers() throws {
        let url = URL(fileURLWithPath: "/usr/bin/vim")
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw XCTSkip("/usr/bin/vim is not present on this host")
        }
        let sliceIndex = 1
        let loaded = try MachOBinaryLoader(requestedSliceIndex: sliceIndex).load(at: url)
        guard loaded.cpuType == MachOConstants.cpuTypeARM64,
              let subtype = loaded.cpuSubtype, subtype & 0x00FF_FFFF == 2
        else {
            throw XCTSkip("/usr/bin/vim slice \(sliceIndex) is not arm64e on this host")
        }
        let functionStart: UInt64 = 0x1_0000_0af8
        guard loaded.functionStarts.contains(functionStart),
              let functionEnd = loaded.functionStarts.filter({ $0 > functionStart }).min()
        else {
            throw XCTSkip("0x100000af8 is not a function start in this host's vim")
        }
        let layout = try XCTUnwrap(loaded.preferredSegmentLayout)
        let header = try XCTUnwrap(layout.records.first {
            $0.preferredVMSize > 0 && $0.fileSize > 0 && $0.sliceRelativeFileOffset == 0
        })
        let relations = Set(layout.records.filter { $0.preferredVMSize > 0 && $0.fileSize > 0 }
            .map { $0.preferredVMStart - $0.sliceRelativeFileOffset })
        XCTAssertGreaterThan(relations.count, 1, "vim's layout no longer exercises the defect")

        let sliceStart = Int(loaded.sliceOffset)
        let sliceEnd = loaded.sliceSize.map { sliceStart + Int($0) } ?? loaded.bytes.count
        let binary = BinaryImage(
            id: binaryID, name: loaded.name, path: loaded.path, kind: loaded.fileTypeName,
            architecture: loaded.architectureDisplayName, selectedSliceIndex: sliceIndex,
            artifactIdentity: loaded.artifactIdentity,
            preferredSegmentLayout: loaded.preferredSegmentLayout,
            artifactIntegrityState: loaded.artifactIntegrityState,
            resolvedExecutablePath: loaded.resolvedExecutablePath, slot: slot
        )
        let function = FunctionSummary(
            id: functionID, name: "vim_0x100000af8",
            startAddress: functionStart, endAddress: functionEnd, confidence: 1
        )
        var analysis = ImageAnalysis(
            functions: [function],
            identityEffectiveByteRanges: loaded.identityEffectiveByteRanges,
            imageBytes: loaded.bytes.subdata(in: sliceStart ..< sliceEnd)
        )
        analysis.analysisInputFingerprint = try AnalysisFingerprintBuilder.fingerprint(
            binary: binary, analysis: analysis
        )
        let projection = try build(WorkspaceSnapshot(binaries: [binary], analysisBySlot: [slot: analysis]))
        XCTAssertEqual(projection.image.preferredLoadAddress.value, header.preferredVMStart)
        XCTAssertEqual(projection.image.preferredLoadAddress.value, 0x1_0000_0000)
        XCTAssertEqual(projection.function.entryAddress.value, functionStart)
        XCTAssertEqual(projection.target.normalizedVariant, .arm64e)
        XCTAssertEqual(projection.memoryRegions.first?.startAddress.value, functionStart)
        XCTAssertNoThrow(try requestProjection(projection))
    }

    func testRejectsOverlappingLayouts() throws {

        let overlapping = [
            segment("__TEXT", vmStart: 0x1000, vmSize: 8, fileOffset: 0, fileSize: 8),
            segment("__DATA", vmStart: 0x1004, vmSize: 8, fileOffset: 8, fileSize: 4, protections: 3),
        ]
        assertProjectionError(.overlappingSegmentLayout) {
            try build(try makeFixture(byteCount: 12, segments: overlapping).snapshot)
        }

        let fileSpanOnlyOverlap = [
            segment("__T0", vmStart: 0x1000, vmSize: 4, fileOffset: 0, fileSize: 4),
            segment("__T1", vmStart: 0x2000, vmSize: 4, fileOffset: 2, fileSize: 4),
        ]
        assertProjectionError(.overlappingSegmentLayout) {
            try build(try makeFixture(
                byteCount: 6,
                segments: fileSpanOnlyOverlap,
                functionEnd: 0x1004
            ).snapshot)
        }
    }

    func testAdmitsFileOnlyZeroVMSegmentWithoutProjectingVirtualBytes() throws {
        // Go-style __DWARF: file bytes, vmsize 0. It is readable here and even carries a
        // fixture attestation plus a data xref at its vmaddr, so only the mapped-segment
        // rule can keep its file bytes out of the native virtual regions.
        let records = [
            segment("__TEXT", vmStart: 0x1000, vmSize: 16, fileOffset: 0, fileSize: 16),
            segment("__DWARF", vmStart: 0x2000, vmSize: 0, fileOffset: 16, fileSize: 16, protections: 1),
        ]
        var snapshot = try makeFixture(byteCount: 32, segments: records).snapshot
        var analysis = try XCTUnwrap(snapshot.analysis(in: slot))
        analysis.xrefs = [.init(id: UUID(), from: 0x1000, to: 0x2000, kind: XRefKind.data)]
        snapshot.analysisBySlot[slot] = analysis
        try refreshFingerprint(in: &snapshot)

        let projection = try build(snapshot)
        XCTAssertEqual(projection.image.preferredLoadAddress.value, 0x1000)
        XCTAssertEqual(projection.memoryRegions.map(\.name), ["__TEXT", "__TEXT"])
        XCTAssertEqual(projection.memoryRegions.map { $0.startAddress.value }, [0x1000, 0x1008])
        XCTAssertEqual(projection.memoryRegions.map { $0.rawBytes.count }, [8, 8])
        XCTAssertEqual(projection.memoryRegions[0].rawBytes, Data((0 ..< 8).map { UInt8($0) }))
        XCTAssertFalse(projection.memoryRegions.contains { $0.startAddress.value >= 0x2000 })
        XCTAssertNoThrow(try requestProjection(projection))
        // File evidence is preserved, not discarded: the loader layout still carries it.
        XCTAssertEqual(snapshot.binary(in: slot)?.preferredSegmentLayout?.records, records)
    }

    func testFileOnlyZeroVMSegmentNeverBecomesOrContradictsPreferredBase() throws {
        // The file-only record has the lowest file offset and address. It maps nothing, so
        // it cannot stand in for the header segment: with no mapped segment at slice offset
        // 0 the image has no preferred base and the projection is refused.
        let lowerFileOnly = [
            segment("__DWARF", vmStart: 0x800, vmSize: 0, fileOffset: 0, fileSize: 16, protections: 0),
            segment("__TEXT", vmStart: 0x1000, vmSize: 16, fileOffset: 16, fileSize: 16),
        ]
        assertProjectionError(.missingHeaderMappingSegment) {
            try build(try makeFixture(byteCount: 32, segments: lowerFileOnly).snapshot)
        }

        // A file-only vmaddr inside a mapped segment is neither a virtual overlap nor a
        // region split, and a vmaddr below its file offset cannot fail base derivation.
        let insideMapped = [
            segment("__TEXT", vmStart: 0x1000, vmSize: 16, fileOffset: 0, fileSize: 16),
            segment("__DWARF", vmStart: 0x1004, vmSize: 0, fileOffset: 16, fileSize: 16, protections: 0),
        ]
        let inside = try build(try makeFixture(byteCount: 32, segments: insideMapped).snapshot)
        XCTAssertEqual(inside.image.preferredLoadAddress.value, 0x1000)
        XCTAssertEqual(inside.memoryRegions.map { $0.startAddress.value }, [0x1000, 0x1008])
        let belowFileOffset = [
            segment("__TEXT", vmStart: 0x1000, vmSize: 16, fileOffset: 0, fileSize: 16),
            segment("__DWARF", vmStart: 0x8, vmSize: 0, fileOffset: 16, fileSize: 16, protections: 0),
        ]
        let below = try build(try makeFixture(byteCount: 32, segments: belowFileOffset).snapshot)
        XCTAssertEqual(below.image.preferredLoadAddress.value, 0x1000)
        XCTAssertEqual(below.memoryRegions.map(\.name), ["__TEXT", "__TEXT"])
    }

    func testRejectsMalformedGeometryDespiteFileOnlyAdmission() throws {
        // Mapped record whose file bytes exceed its VM size remains malformed.
        let fileBeyondVM = [
            segment("__TEXT", vmStart: 0x1000, vmSize: 8, fileOffset: 0, fileSize: 16),
        ]
        assertProjectionError(.invalidSegmentLayout) {
            try build(try makeFixture(byteCount: 32, segments: fileBeyondVM).snapshot)
        }
        // A record with neither VM nor file bytes is not a file-only record.
        let empty = [
            segment("__TEXT", vmStart: 0x1000, vmSize: 16, fileOffset: 0, fileSize: 16),
            segment("__EMPTY", vmStart: 0x2000, vmSize: 0, fileOffset: 16, fileSize: 0, protections: 0),
        ]
        assertProjectionError(.invalidSegmentLayout) {
            try build(try makeFixture(byteCount: 32, segments: empty).snapshot)
        }
        // File-only bytes stay subject to file-span overlap and slice bounds.
        let fileOverlap = [
            segment("__TEXT", vmStart: 0x1000, vmSize: 16, fileOffset: 0, fileSize: 16),
            segment("__DWARF", vmStart: 0x2000, vmSize: 0, fileOffset: 8, fileSize: 16, protections: 0),
        ]
        assertProjectionError(.overlappingSegmentLayout) {
            try build(try makeFixture(byteCount: 32, segments: fileOverlap).snapshot)
        }
        let fileBeyondSlice = [
            segment("__TEXT", vmStart: 0x1000, vmSize: 16, fileOffset: 0, fileSize: 16),
            segment("__DWARF", vmStart: 0x2000, vmSize: 0, fileOffset: 16, fileSize: 32, protections: 0),
        ]
        assertProjectionError(.invalidSegmentLayout) {
            try build(try makeFixture(
                byteCount: 32,
                segments: fileBeyondSlice,
                layoutValidationByteCount: 48
            ).snapshot)
        }
        // Mapped segments still may not overlap in virtual memory.
        let mappedOverlap = [
            segment("__TEXT", vmStart: 0x1000, vmSize: 16, fileOffset: 0, fileSize: 16),
            segment("__DATA", vmStart: 0x1008, vmSize: 16, fileOffset: 16, fileSize: 16, protections: 3),
            segment("__DWARF", vmStart: 0x1000, vmSize: 0, fileOffset: 32, fileSize: 8, protections: 0),
        ]
        assertProjectionError(.overlappingSegmentLayout) {
            try build(try makeFixture(byteCount: 40, segments: mappedOverlap).snapshot)
        }
    }

    func testRejectsEmptyMismatchedAndOutOfRangeSelectedSliceEvidence() throws {
        let fixture = try makeFixture()

        var empty = fixture.snapshot
        var emptyAnalysis = try XCTUnwrap(empty.analysis(in: slot))
        emptyAnalysis.imageBytes = Data()
        empty.analysisBySlot[slot] = emptyAnalysis
        assertProjectionError(.emptySelectedSlice) { try build(empty) }

        var staleFingerprint = fixture.snapshot
        var staleAnalysis = try XCTUnwrap(staleFingerprint.analysis(in: slot))
        staleAnalysis.analysisInputFingerprint?.imageByteCount += 1
        staleFingerprint.analysisBySlot[slot] = staleAnalysis
        assertProjectionError(.selectedSliceMismatch) { try build(staleFingerprint) }

        var badArtifactHash = fixture.snapshot
        badArtifactHash.binaries[0].artifactIdentity = try MachOSliceArtifactIdentity(
            uuid: imageUUID,
            rawCPUType: MachOConstants.cpuTypeARM64,
            rawCPUSubtype: 0,
            selectedSliceSHA256: String(repeating: "0", count: 64),
            selectedSliceByteCount: 32
        )
        try refreshFingerprint(in: &badArtifactHash)
        assertProjectionError(.selectedSliceMismatch) { try build(badArtifactHash) }

        let outOfRange = [
            segment("__TEXT", vmStart: 0x1000, vmSize: 8, fileOffset: 30, fileSize: 4),
        ]
        var outOfRangeFixture = try makeFixture(
            byteCount: 32,
            segments: outOfRange,
            functionEnd: 0x1004,
            layoutValidationByteCount: 64
        )
        try refreshFingerprint(in: &outOfRangeFixture.snapshot)
        assertProjectionError(.invalidSegmentLayout) { try build(outOfRangeFixture.snapshot) }
    }

    func testRejectsInvalidUnalignedAndOverBudgetFunctionRanges() throws {
        var invalid = try makeFixture().snapshot
        var analysis = try XCTUnwrap(invalid.analysis(in: slot))
        analysis.functions[0].endAddress = analysis.functions[0].startAddress
        invalid.analysisBySlot[slot] = analysis
        try refreshFingerprint(in: &invalid)
        assertProjectionError(.invalidFunctionRange) { try build(invalid) }

        var unaligned = try makeFixture().snapshot
        analysis = try XCTUnwrap(unaligned.analysis(in: slot))
        analysis.functions[0].startAddress += 1
        unaligned.analysisBySlot[slot] = analysis
        try refreshFingerprint(in: &unaligned)
        assertProjectionError(.invalidFunctionRange) { try build(unaligned) }

        let smallBudget = NativeDecompilerWireAnalysisBudgets(
            maxCodeBytes: 4,
            maxInstructions: 1,
            maxOperations: 1,
            maxOutputBytes: 1,
            maxWallTimeMilliseconds: .init(1)
        )
        assertProjectionError(.invalidBudgets) {
            try NativeDecompilerSnapshotBuilder.build(
                from: try makeFixture().snapshot,
                imageSlot: slot,
                functionID: functionID,
                budgets: smallBudget
            )
        }
    }

    func testMaterializesSelectedPatchAndRejectsPatchRangeOverflow() throws {
        var patched = try makeFixture().snapshot
        patched.addressOverrides[ImageAddress(slot: slot, address: 0x1004)] = AddressOverride(
            patch: .arm64NOP
        )
        let projection = try build(patched)
        XCTAssertEqual(projection.memoryRegions[0].appliedPatchIDs, ["patch000001"])
        XCTAssertNotEqual(projection.memoryRegions[0].rawBytes, projection.memoryRegions[0].effectiveBytes)

        var overflow = try makeFixture().snapshot
        overflow.addressOverrides[ImageAddress(slot: slot, address: UInt64.max - 1)] = AddressOverride(
            patch: .arm64NOP
        )
        assertProjectionError(.invalidPatchRange) { try build(overflow) }
    }

    func testRejectsIntersectingRelocationEvidenceButAllowsAdjacentRelocations() throws {
        let intersecting = RelocationSummary(
            id: UUID(),
            address: 0x1004,
            sectionName: "__TEXT,__text",
            typeCode: 2,
            typeName: "ARM64_RELOC_BRANCH26",
            symbolName: "_callee",
            symbolIndex: 1,
            addend: nil,
            isPCRelative: true,
            widthInBytes: 4
        )
        assertProjectionError(.intersectingRelocation) {
            try build(try makeFixture(relocations: [intersecting]).snapshot)
        }

        var adjacent = intersecting
        adjacent.address = 0x1020 // outside both the exact function and its actual mapped lookahead
        XCTAssertNoThrow(try build(try makeFixture(relocations: [adjacent]).snapshot))

        var unknownWidth = intersecting
        unknownWidth.widthInBytes = 0
        assertProjectionError(.intersectingRelocation) {
            try build(try makeFixture(relocations: [unknownWidth]).snapshot)
        }

        var overflowing = intersecting
        overflowing.address = UInt64.max - 1
        overflowing.widthInBytes = 4
        assertProjectionError(.invalidRelocationRange) {
            try build(try makeFixture(relocations: [overflowing]).snapshot)
        }
    }

    func testRequiresExactLoaderIssuedEffectiveByteIdentityAuthority() throws {
        var missing = try makeFixture().snapshot
        var missingAnalysis = try XCTUnwrap(missing.analysis(in: slot))
        missingAnalysis.identityEffectiveByteRanges = []
        missingAnalysis.analysisInputFingerprint = try AnalysisFingerprintBuilder.fingerprint(
            binary: try XCTUnwrap(missing.binaries.first),
            analysis: missingAnalysis
        )
        missing.analysisBySlot[slot] = missingAnalysis
        assertProjectionError(.effectiveLoadImageAuthorityUnavailable) { try build(missing) }

        var forged = try makeFixture().snapshot
        var analysis = try XCTUnwrap(forged.analysis(in: slot))
        let authority = try XCTUnwrap(analysis.identityEffectiveByteRanges.first)
        analysis.identityEffectiveByteRanges = [try IdentityEffectiveByteRangeAttestation(
            artifactIdentity: authority.artifactIdentity,
            segmentName: authority.segmentName,
            startAddress: authority.startAddress,
            endAddressExclusive: authority.endAddressExclusive,
            sliceRelativeFileOffset: authority.sliceRelativeFileOffset,
            byteCount: authority.byteCount,
            initialProtections: authority.initialProtections,
            rawBytesSHA256: String(repeating: "0", count: 64)
        )]
        analysis.analysisInputFingerprint = try AnalysisFingerprintBuilder.fingerprint(
            binary: try XCTUnwrap(forged.binaries.first),
            analysis: analysis
        )
        forged.analysisBySlot[slot] = analysis
        assertProjectionError(.invalidEffectiveLoadImageAttestation) { try build(forged) }
    }

    func testRejectsCoverageGapZeroFillAndNonReadableExecutableMemory() throws {
        let gap = [
            segment("__T0", vmStart: 0x1000, vmSize: 4, fileOffset: 0, fileSize: 4),
            segment("__T1", vmStart: 0x1008, vmSize: 4, fileOffset: 8, fileSize: 4),
        ]
        assertProjectionError(.invalidFunctionCoverage) {
            try build(try makeFixture(byteCount: 12, segments: gap, functionEnd: 0x100C).snapshot)
        }

        let zeroFill = [
            segment("__TEXT", vmStart: 0x1000, vmSize: 8, fileOffset: 0, fileSize: 4),
        ]
        assertProjectionError(.invalidFunctionCoverage) {
            try build(try makeFixture(byteCount: 4, segments: zeroFill).snapshot)
        }

        for protections in [Int32(1), Int32(4), Int32(3), Int32(7)] {
            let wrongPermissions = [
                segment(
                    "__TEXT",
                    vmStart: 0x1000,
                    vmSize: 8,
                    fileOffset: 0,
                    fileSize: 8,
                    protections: protections
                ),
            ]
            assertProjectionError(.invalidFunctionCoverage) {
                try build(try makeFixture(byteCount: 8, segments: wrongPermissions).snapshot)
            }
        }
    }

    func testRejectsRegionCountTransportCeiling() throws {
        let count = 257
        let records = (0 ..< count).map { index in
            segment(
                "t\(index)",
                vmStart: 0x1000 + UInt64(index * 4),
                vmSize: 4,
                fileOffset: UInt64(index * 4),
                fileSize: 4
            )
        }
        let fixture = try makeFixture(
            byteCount: count * 4,
            segments: records,
            functionEnd: 0x1000 + UInt64(count * 4)
        )
        assertProjectionError(.tooManyMemoryRegions) { try build(fixture.snapshot) }
    }

    func testRejectsSymbolCountTransportCeilingAfterDeterministicDedupe() throws {
        let symbols = (0 ... 100_000).map { index in
            SymbolSummary(
                id: UUID(),
                name: "display-\(index)",
                address: 0x1000 + UInt64(index),
                kind: "loader-private",
                libraryName: nil,
                rawLinkageName: "_symbol_\(index)"
            )
        }
        let fixture = try makeFixture(symbols: symbols)
        assertProjectionError(.tooManySymbols) { try build(fixture.snapshot) }
    }

    func testRejectsEncodedRequestBeyondThirtyTwoMiB() throws {
        // Binary property lists may intern equal Data objects. Raw and effective views are
        // intentionally identical in this native projection, so use the full code budget:
        // the payload plus its required envelope metadata must cross the 32 MiB wire ceiling.
        let byteCount = NativeDecompilerWireCodec.maximumRequestBytes
        let fixture = try makeFixture(
            byteCount: byteCount,
            functionEnd: 0x1000 + UInt64(byteCount)
        )
        assertProjectionError(.functionExceedsBudget) { try build(fixture.snapshot) }
    }

    func testRejectsInvalidBudgetsBeforeReadingWorkspaceEvidence() {
        let invalid = NativeDecompilerWireAnalysisBudgets(
            maxCodeBytes: 0,
            maxInstructions: 0,
            maxOperations: 0,
            maxOutputBytes: 0,
            maxWallTimeMilliseconds: .init(0)
        )
        assertProjectionError(.invalidBudgets) {
            try NativeDecompilerSnapshotBuilder.build(
                from: WorkspaceSnapshot(binaries: [], analysisBySlot: [:]),
                imageSlot: slot,
                functionID: functionID,
                budgets: invalid
            )
        }
    }
}

private extension NativeDecompilerSnapshotBuilderTests {
    struct Fixture {
        var snapshot: WorkspaceSnapshot
    }

    var budgets: NativeDecompilerWireAnalysisBudgets {
        NativeDecompilerProductBudgetProfile.v1.wireValue
    }

    func build(_ snapshot: WorkspaceSnapshot) throws -> NativeDecompilerSnapshotProjection {
        try NativeDecompilerSnapshotBuilder.build(
            from: snapshot,
            imageSlot: slot,
            functionID: functionID,
            budgets: budgets
        )
    }

    func requestProjection(
        _ snapshot: NativeDecompilerSnapshotProjection
    ) throws -> NativeDecompilerRequestProjection {
        try NativeDecompilerRequestProjection(snapshotProjection: snapshot)
    }

    func makeFixture(
        byteCount: Int = 32,
        segments: [MachOPreferredSegmentLayout.Record]? = nil,
        functionEnd: UInt64 = 0x1008,
        symbols: [SymbolSummary]? = nil,
        relocations: [RelocationSummary] = [],
        uuid: UUID? = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
        cpuType: Int32 = MachOConstants.cpuTypeARM64,
        cpuSubtype: Int32 = 0,
        layoutValidationByteCount: UInt64? = nil,
        instructionWords: [UInt32]? = nil
    ) throws -> Fixture {
        let bytes = instructionWords.map { words in
            Data(words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } })
        } ?? Data((0 ..< byteCount).map { UInt8(truncatingIfNeeded: $0) })
        let artifact = try MachOSliceArtifactIdentity(
            uuid: uuid,
            rawCPUType: cpuType,
            rawCPUSubtype: cpuSubtype,
            selectedSliceSHA256: AnalysisFingerprintBuilder.sha256Hex(bytes),
            selectedSliceByteCount: UInt64(bytes.count)
        )
        let records = segments ?? [
            segment(
                "__TEXT",
                vmStart: 0x1000,
                vmSize: UInt64(bytes.count),
                fileOffset: 0,
                fileSize: UInt64(bytes.count)
            ),
        ]
        let layout = try MachOPreferredSegmentLayout(
            records: records,
            selectedSliceByteCount: layoutValidationByteCount ?? UInt64(bytes.count)
        )
        let binary = BinaryImage(
            id: binaryID,
            name: "fixture",
            path: "/must/not/cross/the/projection",
            kind: "Mach-O 64-bit",
            architecture: "arm64",
            artifactIdentity: artifact,
            preferredSegmentLayout: layout,
            artifactIntegrityState: .verified,
            resolvedExecutablePath: "/also/must/not/cross",
            slot: slot
        )
        let function = FunctionSummary(
            id: functionID,
            name: "entry",
            startAddress: 0x1000,
            endAddress: functionEnd,
            confidence: 1
        )
        var analysis = ImageAnalysis(
            functions: [function],
            symbols: symbols ?? [
                SymbolSummary(
                    id: UUID(uuidString: "50000000-0000-0000-0000-000000000005")!,
                    name: "display-entry",
                    address: 0x1000,
                    kind: "export",
                    libraryName: nil,
                    rawLinkageName: "_entry"
                ),
                SymbolSummary(
                    id: UUID(uuidString: "50000000-0000-0000-0000-000000000006")!,
                    name: "duplicate-display-entry",
                    address: 0x1000,
                    kind: "export",
                    libraryName: nil,
                    rawLinkageName: "_entry"
                ),
                SymbolSummary(
                    id: UUID(uuidString: "50000000-0000-0000-0000-000000000007")!,
                    name: "display-only",
                    address: 0x1004,
                    kind: "local",
                    libraryName: nil,
                    rawLinkageName: nil
                ),
                SymbolSummary(
                    id: UUID(uuidString: "50000000-0000-0000-0000-000000000008")!,
                    name: "empty-raw",
                    address: 0x1004,
                    kind: "local",
                    libraryName: nil,
                    rawLinkageName: ""
                ),
                SymbolSummary(
                    id: UUID(uuidString: "50000000-0000-0000-0000-000000000009")!,
                    name: "mystery",
                    address: 0x1004,
                    kind: "loader-private",
                    libraryName: nil,
                    rawLinkageName: "_mystery"
                ),
            ],
            instructions: instructionWords == nil ? [] : ARM64Decoder().decode(bytes, baseAddress: 0x1000)
                .map { InstructionRow(decoded: $0) },
            relocations: relocations,
            identityEffectiveByteRanges: try makeIdentityEffectiveByteRanges(
                artifact: artifact,
                records: records,
                bytes: bytes
            ),
            imageBytes: bytes
        )
        analysis.analysisInputFingerprint = try AnalysisFingerprintBuilder.fingerprint(
            binary: binary,
            analysis: analysis
        )
        return Fixture(snapshot: WorkspaceSnapshot(
            binaries: [binary],
            analysisBySlot: [slot: analysis]
        ))
    }

    func segment(
        _ name: String,
        vmStart: UInt64,
        vmSize: UInt64,
        fileOffset: UInt64,
        fileSize: UInt64,
        protections: Int32 = 5
    ) -> MachOPreferredSegmentLayout.Record {
        MachOPreferredSegmentLayout.Record(
            name: name,
            preferredVMStart: vmStart,
            preferredVMSize: vmSize,
            sliceRelativeFileOffset: fileOffset,
            fileSize: fileSize,
            initialProtections: protections
        )
    }

    func refreshFingerprint(in snapshot: inout WorkspaceSnapshot) throws {
        let binary = try XCTUnwrap(snapshot.binary(in: slot))
        var analysis = try XCTUnwrap(snapshot.analysis(in: slot))
        analysis.analysisInputFingerprint = try AnalysisFingerprintBuilder.fingerprint(
            binary: binary,
            analysis: analysis
        )
        snapshot.analysisBySlot[slot] = analysis
    }

    func refreshArtifactAndFingerprint(in snapshot: inout WorkspaceSnapshot) throws {
        var binary = try XCTUnwrap(snapshot.binary(in: slot))
        var analysis = try XCTUnwrap(snapshot.analysis(in: slot))
        let artifact = try MachOSliceArtifactIdentity(
            uuid: imageUUID,
            rawCPUType: MachOConstants.cpuTypeARM64,
            rawCPUSubtype: 0,
            selectedSliceSHA256: AnalysisFingerprintBuilder.sha256Hex(analysis.imageBytes),
            selectedSliceByteCount: UInt64(analysis.imageBytes.count)
        )
        binary.artifactIdentity = artifact
        analysis.identityEffectiveByteRanges = try makeIdentityEffectiveByteRanges(
            artifact: artifact,
            records: try XCTUnwrap(binary.preferredSegmentLayout).records,
            bytes: analysis.imageBytes
        )
        snapshot.binaries[0] = binary
        analysis.analysisInputFingerprint = try AnalysisFingerprintBuilder.fingerprint(
            binary: binary,
            analysis: analysis
        )
        snapshot.analysisBySlot[slot] = analysis
    }

    func makeIdentityEffectiveByteRanges(
        artifact: MachOSliceArtifactIdentity,
        records: [MachOPreferredSegmentLayout.Record],
        bytes: Data
    ) throws -> [IdentityEffectiveByteRangeAttestation] {
        try records.compactMap { record in
            guard record.fileSize > 0,
                  record.initialProtections & 1 != 0,
                  record.initialProtections & 2 == 0 else {
                return nil
            }
            let end = record.sliceRelativeFileOffset.addingReportingOverflow(record.fileSize)
            let virtualEnd = record.preferredVMStart.addingReportingOverflow(record.fileSize)
            guard !end.overflow,
                  !virtualEnd.overflow,
                  end.partialValue <= UInt64(bytes.count),
                  let lower = Int(exactly: record.sliceRelativeFileOffset),
                  let upper = Int(exactly: end.partialValue) else {
                return nil
            }
            return try IdentityEffectiveByteRangeAttestation(
                artifactIdentity: artifact,
                segmentName: record.name,
                startAddress: record.preferredVMStart,
                endAddressExclusive: virtualEnd.partialValue,
                sliceRelativeFileOffset: record.sliceRelativeFileOffset,
                byteCount: record.fileSize,
                initialProtections: record.initialProtections,
                rawBytesSHA256: AnalysisFingerprintBuilder.sha256Hex(
                    bytes.subdata(in: lower..<upper)
                )
            )
        }
    }

    func makeContextFixture(dataProtections: Int32 = 1) throws -> WorkspaceSnapshot {
        var snapshot = try makeFixture(segments: [
            segment("__TEXT", vmStart: 0x1000, vmSize: 24, fileOffset: 0, fileSize: 24),
            segment("__CONST", vmStart: 0x1018, vmSize: 8, fileOffset: 24, fileSize: 8, protections: dataProtections),
        ]).snapshot
        var analysis = try XCTUnwrap(snapshot.analysis(in: slot))
        analysis.functions += [
            .init(id: UUID(), name: "callee", startAddress: 0x1008, endAddress: 0x1010, confidence: 1),
            .init(id: UUID(), name: "unrelated", startAddress: 0x1010, endAddress: 0x1018, confidence: 1),
        ]
        analysis.xrefs = [
            .init(id: UUID(), from: 0x1000, to: 0x1008, kind: XRefKind.call),
            .init(id: UUID(), from: 0x1004, to: 0x1018, kind: XRefKind.data),
        ]
        snapshot.analysisBySlot[slot] = analysis
        try refreshFingerprint(in: &snapshot)
        return snapshot
    }

    func assertProjectionError(
        _ expected: NativeDecompilerSnapshotProjectionError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> NativeDecompilerSnapshotProjection
    ) {
        do {
            _ = try operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as NativeDecompilerSnapshotProjectionError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}
