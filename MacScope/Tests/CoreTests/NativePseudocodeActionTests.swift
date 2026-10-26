import AppKit
import SwiftUI
import XCTest
@testable import MacScope

@MainActor
final class NativePseudocodeActionTests: XCTestCase {
    func testLeavingEditorRejectsRetainedMenuAndRangeChoice() throws {
        try assertHiddenSurfaceRejectsActions(selectedTool: .reconstruction, source: .native)
    }

    func testLeavingNativeForCompareRejectsRetainedMenuAndRangeChoice() throws {
        try assertHiddenSurfaceRejectsActions(selectedTool: .project, source: .compare)
    }

    func testActionVisibilityUsesTheActualWorkspaceEditorDestination() {
        for tool in WorkspaceTool.allCases {
            XCTAssertEqual(
                NativePseudocodeActionScope.isVisible(
                    selectedTool: tool, editorMode: .pseudocode, source: .native, isImporting: false
                ),
                WorkspaceRootView.centralDestination(for: tool) == .editor
            )
        }
        for source in [PseudocodeSource.macScope, .compare] {
            XCTAssertFalse(NativePseudocodeActionScope.isVisible(
                selectedTool: .project, editorMode: .pseudocode, source: source, isImporting: false
            ))
        }
        XCTAssertFalse(NativePseudocodeActionScope.isVisible(
            selectedTool: .project, editorMode: .disassembly, source: .native, isImporting: false
        ))
        XCTAssertFalse(NativePseudocodeActionScope.isVisible(
            selectedTool: .project, editorMode: .pseudocode, source: .native, isImporting: true
        ))
    }

    func testKeyboardSourceDispatchPreservesTokenAndImageQualifiedRange() throws {
        let fixture = NativeActionFixture()
        let model = fixture.publish()
        let scope = try fixture.scope(model)
        var navigations: [ImageAddress] = []
        let router = NativePseudocodeActionRouter(
            currentScope: { try? fixture.scope(model) },
            navigate: { navigations.append($0); return true }
        )
        let textView = NativePseudocodeTextView.makeTextView(document: scope.document, contrast: .standard)
        textView.onSourceAction = { router.source($0, captured: scope.identity) }
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        textView.keyDown(with: try returnKey())

        XCTAssertEqual(navigations, [ImageAddress(slot: fixture.coordinate.imageSlot, address: 0x1000)])
        XCTAssertNil(router.sheet)
    }

    func testMultipleRangesRequireExplicitChoiceAndUseChosenAddress() throws {
        let fixture = NativeActionFixture(multipleRanges: true)
        let model = fixture.publish()
        let scope = try fixture.scope(model)
        var navigations: [ImageAddress] = []
        let router = NativePseudocodeActionRouter(
            currentScope: { try? fixture.scope(model) },
            navigate: { navigations.append($0); return true }
        )
        router.source(try sourceRequest(scope), captured: scope.identity)
        let sheet = try XCTUnwrap(router.sheet)
        XCTAssertTrue(navigations.isEmpty, "Opening a chooser must not select its first range")
        router.choose(fixture.ranges[1], sheetID: sheet.id)
        XCTAssertEqual(navigations, [ImageAddress(slot: fixture.coordinate.imageSlot, address: 0x1008)])
        XCTAssertNil(router.sheet)
    }

    func testChooserRejectsSameCoordinateCachedResultRepublication() throws {
        let fixture = NativeActionFixture(multipleRanges: true)
        let model = fixture.publish()
        let original = try fixture.scope(model)
        var navigations: [ImageAddress] = []
        let router = NativePseudocodeActionRouter(
            currentScope: { try? fixture.scope(model) },
            navigate: { navigations.append($0); return true }
        )
        router.source(try sourceRequest(original), captured: original.identity)
        let sheet = try XCTUnwrap(router.sheet)
        fixture.republish(model, generation: 2)
        let replacement = try fixture.scope(model)
        XCTAssertEqual(original.result, replacement.result)
        XCTAssertNotEqual(original.identity, replacement.identity)
        router.choose(fixture.ranges[1], sheetID: sheet.id)
        XCTAssertTrue(navigations.isEmpty)
        XCTAssertNil(router.sheet)
    }

    func testMenuRetainsOriginalCallbackWhenTextViewReceivesReplacementCallback() throws {
        let fixture = NativeActionFixture()
        let model = fixture.publish()
        let original = try fixture.scope(model)
        var navigations: [ImageAddress] = []
        let router = NativePseudocodeActionRouter(
            currentScope: { try? fixture.scope(model) },
            navigate: { navigations.append($0); return true }
        )
        let textView = NativePseudocodeTextView.makeTextView(document: original.document, contrast: .standard)
        var originalCalls = 0
        var replacementCalls = 0
        textView.onSourceAction = {
            originalCalls += 1
            router.source($0, captured: original.identity)
        }
        let interaction = try XCTUnwrap(NativePseudocodeInteractionProjection.project(
            document: original.document, scalarOffset: 1,
            isHovered: true, isFocused: false, isSelected: false
        ))
        let menu = textView.actionMenu(for: interaction)

        fixture.republish(model, generation: 2)
        let replacement = try fixture.scope(model)
        textView.onSourceAction = {
            replacementCalls += 1
            router.source($0, captured: replacement.identity)
        }
        menu.performActionForItem(at: 0)
        XCTAssertEqual(originalCalls, 1)
        XCTAssertEqual(replacementCalls, 0)
        XCTAssertTrue(navigations.isEmpty, "The old menu cannot acquire the new publication's authority")

        textView.setSelectedRange(NSRange(location: 1, length: 0))
        textView.keyDown(with: try returnKey())
        XCTAssertEqual(replacementCalls, 1)
        XCTAssertEqual(navigations.count, 1)
    }

    func testWorkspaceAndWindowOwnerChangesInvalidateIdenticalTokenCoordinates() throws {
        let fixture = NativeActionFixture()
        let model = fixture.publish()
        let original = try fixture.scope(model)
        let request = try sourceRequest(original)
        let otherWorkspace = try fixture.scope(model, workspaceID: UUID())
        XCTAssertNil(otherWorkspace.sourceRanges(for: request, captured: original.identity))

        fixture.republish(model, generation: 1, ownerToken: UUID())
        let otherOwner = try fixture.scope(model)
        XCTAssertEqual(otherOwner.result, original.result)
        XCTAssertNil(otherOwner.sourceRanges(for: request, captured: original.identity))
    }

    func testImageArtifactFunctionAndAnalysisMismatchCannotFormActionScope() throws {
        let fixture = NativeActionFixture()
        let model = fixture.publish()
        let coordinate = fixture.coordinate
        let expected = fixture.expected
        let alternatives: [DecompilerPresentationIdentity] = [
            .init(imageSlot: .primary, ownerBinaryID: expected.ownerBinaryID, artifactUUID: expected.artifactUUID,
                  functionID: expected.functionID, analysisInputFingerprintSHA256: expected.analysisInputFingerprintSHA256),
            .init(imageSlot: expected.imageSlot, ownerBinaryID: UUID(), artifactUUID: expected.artifactUUID,
                  functionID: expected.functionID, analysisInputFingerprintSHA256: expected.analysisInputFingerprintSHA256),
            .init(imageSlot: expected.imageSlot, ownerBinaryID: expected.ownerBinaryID, artifactUUID: UUID(),
                  functionID: expected.functionID, analysisInputFingerprintSHA256: expected.analysisInputFingerprintSHA256),
            .init(imageSlot: expected.imageSlot, ownerBinaryID: expected.ownerBinaryID, artifactUUID: expected.artifactUUID,
                  functionID: UUID().uuidString, analysisInputFingerprintSHA256: expected.analysisInputFingerprintSHA256),
            .init(imageSlot: expected.imageSlot, ownerBinaryID: expected.ownerBinaryID, artifactUUID: expected.artifactUUID,
                  functionID: expected.functionID, analysisInputFingerprintSHA256: String(repeating: "f", count: 64)),
        ]
        for changed in alternatives {
            XCTAssertNil(NativePseudocodeActionScope(
                workspaceID: fixture.workspaceID, publication: model.readyPublicationIdentity,
                state: model.state, expected: changed
            ))
        }
        XCTAssertTrue(model.begin(ownerToken: fixture.ownerToken, generation: 2, coordinate: coordinate))
        XCTAssertNil(model.readyPublicationIdentity)
        XCTAssertNil(NativePseudocodeActionScope(
            workspaceID: fixture.workspaceID, publication: nil, state: model.state, expected: expected
        ))
    }

    func testForgedTokenRangeImageAndRequestIdentityAreRejected() throws {
        let fixture = NativeActionFixture()
        let model = fixture.publish()
        let scope = try fixture.scope(model)
        let request = try sourceRequest(scope)
        XCTAssertNil(scope.sourceRanges(
            for: .init(tokenID: "different-token", action: request.action), captured: scope.identity
        ))
        for range in [
            NativeDecompilerWireSourceRange(imageID: fixture.coordinate.imageID, startAddress: .init(0x1008), endAddressExclusive: .init(0x100c)),
            NativeDecompilerWireSourceRange(imageID: "other-image", startAddress: .init(0x1000), endAddressExclusive: .init(0x1004)),
        ] {
            XCTAssertNil(scope.sourceRanges(
                for: .init(tokenID: request.tokenID, action: .navigate(range)), captured: scope.identity
            ))
        }
        let publication = scope.identity.publication
        let otherRequest = NativePseudocodeActionIdentity(
            workspaceID: fixture.workspaceID,
            publication: .init(ownerToken: publication.ownerToken, generation: publication.generation,
                               coordinate: publication.coordinate, requestID: UUID())
        )
        XCTAssertNil(scope.sourceRanges(for: request, captured: otherRequest))
    }

    func testEntityInspectionUsesExactRecordAndNeverNavigatesStorageOffsets() throws {
        let fixture = NativeActionFixture()
        let model = fixture.publish()
        let scope = try fixture.scope(model)
        let details = NativePseudocodeInteractionProjection.entityDetails(for: scope.document.tokenRuns[0])
        XCTAssertEqual(details.count, 8)
        for detail in details {
            let inspection = try XCTUnwrap(scope.inspection(for: detail, captured: scope.identity))
            XCTAssertEqual(inspection.fields.first?.label, "Entity ID")
            XCTAssertEqual(inspection.fields.first?.value, detail.entityID)
        }
        let detail = try XCTUnwrap(details.first { $0.kind == .varnode })
        let router = NativePseudocodeActionRouter(
            currentScope: { try? fixture.scope(model) },
            navigate: { _ in XCTFail("Storage offsets are not navigation targets"); return false }
        )
        router.entity(detail, captured: scope.identity)
        guard case let .entity(inspection) = router.sheet?.content else {
            return XCTFail("Expected a structured entity inspector")
        }
        XCTAssertTrue(inspection.fields.contains { $0.label == "Storage offset" && $0.value == "0x1000" })
        XCTAssertTrue(inspection.fields.contains { $0.label == "Register" && $0.value == "x0" })
        let forged = NativePseudocodeEntityDetail(
            tokenID: detail.tokenID, entityID: "another-varnode", kind: detail.kind, value: detail.value
        )
        XCTAssertNil(scope.inspection(for: forged, captured: scope.identity))
        fixture.republish(model, generation: 2)
        router.reconcile()
        XCTAssertNil(router.sheet)
    }

    func testOptionReturnInspectsTokenEvenWhenItAlsoHasSourceRanges() throws {
        let fixture = NativeActionFixture()
        let model = fixture.publish()
        let scope = try fixture.scope(model)
        let textView = NativePseudocodeTextView.makeTextView(document: scope.document, contrast: .standard)
        var detail: NativePseudocodeEntityDetail?
        textView.onSourceAction = { _ in XCTFail("Option-Return should inspect") }
        textView.onEntityDetail = { detail = $0 }
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        textView.keyDown(with: try returnKey(modifiers: .option))
        XCTAssertEqual(detail?.tokenID, "token.value")
        XCTAssertEqual(detail?.entityID, "block.entry")
    }

    func testDegradedDocumentHasNoActionScopeAndDetailValuesAreBounded() {
        let fixture = NativeActionFixture(tokenText: "not-visible")
        let model = fixture.publish()
        XCTAssertNil(NativePseudocodeActionScope(
            workspaceID: fixture.workspaceID, publication: model.readyPublicationIdentity,
            state: model.state, expected: fixture.expected
        ))
        let field = NativePseudocodeEntityInspection.Field(label: "Name", value: String(repeating: "\u{1F9EA}", count: 1_000))
        XCTAssertEqual(field.value.unicodeScalars.count, 513)
        XCTAssertTrue(field.value.hasSuffix("…"))
    }

    private func assertHiddenSurfaceRejectsActions(
        selectedTool: WorkspaceTool,
        source: PseudocodeSource
    ) throws {
        let fixture = NativeActionFixture(multipleRanges: true)
        let model = fixture.publish()
        let scope = try fixture.scope(model)
        let store = WorkspaceStore(
            workspaceName: "Native action visibility",
            snapshot: WorkspaceSnapshot(binaries: [], analysisBySlot: [:]),
            engine: AnalysisEngine(), autosaveScheduler: nil
        )
        store.selectedTool = .project
        store.editorMode = .pseudocode
        let sourceSelection = PseudocodeSourceSelectionModel(source: .native)
        var navigations: [ImageAddress] = []
        let router = NativePseudocodeActionRouter(currentScope: {
            // Exercise the production visibility predicate with the actual mutable store/selection
            // values; returning nil is a consequence of that shared predicate, not a test stub.
            guard NativePseudocodeActionScope.isVisible(
                selectedTool: store.selectedTool,
                editorMode: store.editorMode,
                source: sourceSelection.source,
                isImporting: store.isImporting
            ) else { return nil }
            return try? fixture.scope(model)
        }, navigate: { navigations.append($0); return true })
        let textView = NativePseudocodeTextView.makeTextView(document: scope.document, contrast: .standard)
        textView.onSourceAction = { router.source($0, captured: scope.identity) }
        textView.onEntityDetail = { router.entity($0, captured: scope.identity) }
        let interaction = try XCTUnwrap(NativePseudocodeInteractionProjection.project(
            document: scope.document, scalarOffset: 1,
            isHovered: true, isFocused: false, isSelected: false
        ))
        let menu = textView.actionMenu(for: interaction)
        router.source(try sourceRequest(scope), captured: scope.identity)
        let pendingChoice = try XCTUnwrap(router.sheet)

        store.selectedTool = selectedTool
        sourceSelection.select(source)
        // Deliberately do not call reconcile: invocation-time checks must work before SwiftUI
        // processes onChange/onDisappear, including for callbacks retained by an unmounted view.
        router.choose(fixture.ranges[1], sheetID: pendingChoice.id)
        XCTAssertNil(router.sheet)
        menu.performActionForItem(at: 0)
        XCTAssertNil(router.sheet, "A hidden source action must not reopen its chooser")
        menu.performActionForItem(at: 1)
        XCTAssertNil(router.sheet, "A hidden entity action must not open an inspector")
        XCTAssertTrue(navigations.isEmpty)
        XCTAssertEqual(model.readyPublicationIdentity, scope.identity.publication)
    }

    private func sourceRequest(_ scope: NativePseudocodeActionScope) throws -> NativePseudocodeSourceRequest {
        let run = try XCTUnwrap(scope.document.tokenRuns.first)
        return .init(tokenID: run.tokenID, action: try XCTUnwrap(NativePseudocodeInteractionProjection.sourceAction(for: run)))
    }

    private func returnKey(modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))
    }
}

@MainActor
private struct NativeActionFixture {
    let workspaceID = UUID()
    let ownerToken = UUID()
    let requestID = UUID()
    let coordinate = NativeDecompilerPresentationCoordinate(
        imageSlot: ImageSlot(rawValue: 7),
        ownerBinaryID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        artifactUUID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        imageID: "image.fixture", functionID: "function.fixture",
        requestSHA256: String(repeating: "a", count: 64),
        analysisInputFingerprintSHA256: String(repeating: "b", count: 64)
    )
    var multipleRanges = false
    var tokenText = "value"

    var expected: DecompilerPresentationIdentity {
        .init(imageSlot: coordinate.imageSlot, ownerBinaryID: coordinate.ownerBinaryID,
              artifactUUID: coordinate.artifactUUID, functionID: coordinate.functionID,
              analysisInputFingerprintSHA256: coordinate.analysisInputFingerprintSHA256)
    }

    var ranges: [NativeDecompilerWireSourceRange] {
        let first = NativeDecompilerWireSourceRange(imageID: coordinate.imageID, startAddress: .init(0x1000), endAddressExclusive: .init(0x1004))
        return multipleRanges
            ? [first, .init(imageID: coordinate.imageID, startAddress: .init(0x1008), endAddressExclusive: .init(0x100c))]
            : [first]
    }

    func publish() -> NativeDecompilerPresentationModel {
        let model = NativeDecompilerPresentationModel()
        republish(model, generation: 1)
        return model
    }

    func republish(_ model: NativeDecompilerPresentationModel, generation: UInt64, ownerToken: UUID? = nil) {
        let owner = ownerToken ?? self.ownerToken
        model.activate(ownerToken: owner)
        XCTAssertTrue(model.begin(ownerToken: owner, generation: generation, coordinate: coordinate))
        XCTAssertTrue(model.publishReady(ownerToken: owner, generation: generation, coordinate: coordinate, success: success))
    }

    func scope(_ model: NativeDecompilerPresentationModel, workspaceID: UUID? = nil) throws -> NativePseudocodeActionScope {
        try XCTUnwrap(NativePseudocodeActionScope(
            workspaceID: workspaceID ?? self.workspaceID,
            publication: model.readyPublicationIdentity, state: model.state, expected: expected
        ))
    }

    var success: NativeDecompilerWireSuccess {
        .init(
            availability: .init(
                available: true, reasonCode: "available",
                runtimeIdentity: .init(
                    backendID: "native-decompiler", engineVersion: "12.1.2", engineRevision: "engine",
                    wrapperVersion: "3", wrapperRevision: "wrapper",
                    packageManifestSHA256: String(repeating: "c", count: 64),
                    packageTreeSHA256: String(repeating: "d", count: 64),
                    languageID: "AARCH64:LE:64:AppleSilicon", compilerSpecID: "default",
                    targetProfileID: "apple-aarch64-pac-visible-clobber-v1",
                    contextProfileSHA256: String(repeating: "e", count: 64)
                ),
                capabilities: .init(
                    nativeDecompilerHeritage: true, completeRegisterSSA: false, memorySSA: false,
                    recoveredVariables: true, recoveredTypes: true, structuredControlFlow: true,
                    tokenizedPseudocode: true, imageQualifiedSourceRanges: true
                )
            ),
            result: .init(
                requestID: requestID, requestSHA256: coordinate.requestSHA256,
                image: .init(imageID: coordinate.imageID, uuid: coordinate.artifactUUID, preferredLoadAddress: .init(0x1000)),
                function: .init(functionID: coordinate.functionID, name: "fixture", entryAddress: .init(0x1000), endAddressExclusive: .init(0x1010)),
                addressSpaces: [],
                types: [.init(id: "type.i32", kind: .integer, name: "int32_t", byteSize: .init(4),
                              isSigned: true, pointeeTypeID: nil, fields: [], confidence: .high,
                              provenance: "native", returnTypeID: nil, parameterTypeIDs: [])],
                instructions: [.init(id: "instruction.entry", address: .init(0x1000), bytes: Data([0xc0, 0x03, 0x5f, 0xd6]),
                                     mnemonic: "ret", body: "", operationIDs: ["operation.return"], sourceRanges: ranges)],
                varnodes: [.init(id: "varnode.x0", addressSpaceID: "register", offset: .init(0x1000),
                                 sizeBytes: 8, role: .register, typeID: "type.i32", registerName: "x0")],
                operations: [.init(id: "operation.return", blockID: "block.entry", sequence: .init(0), opcode: .return,
                                   outputVarnodeID: nil, inputVarnodeIDs: [], directTargetAddress: nil, sourceRanges: ranges)],
                blocks: [.init(id: "block.entry", startAddress: .init(0x1000), endAddressExclusive: .init(0x1010),
                               operationIDs: ["operation.return"], predecessorEdgeIDs: [], successorEdgeIDs: [], terminatorKind: .return)],
                edges: [], ssaValues: [], ssaBindings: [], phis: [], memoryVersions: [], memoryPhis: [], memoryEffects: [],
                variables: [.init(id: "variable.value", name: "value", role: .local, typeID: "type.i32", storageVarnodeIDs: ["varnode.x0"],
                                  liveRanges: ranges, confidence: .high, provenance: "native")],
                calls: [.init(id: "call.fixture", operationID: "operation.return", kind: .indirect, targetAddress: nil, targetSymbol: nil,
                              prototypeTypeID: nil, argumentVariableIDs: [], resultVariableID: nil, sourceRanges: ranges)],
                regions: [.init(id: "region.root", kind: .root, parentRegionID: nil, childRegionIDs: [], blockIDs: ["block.entry"],
                                conditionOperationID: nil, sourceRanges: ranges)],
                tokens: [.init(id: "token.value", text: tokenText, kind: .identifier, line: 1, column: 1, sourceRanges: ranges,
                               entityReferences: [.init(kind: .block, id: "block.entry"), .init(kind: .call, id: "call.fixture"),
                                                  .init(kind: .instruction, id: "instruction.entry"), .init(kind: .operation, id: "operation.return"),
                                                  .init(kind: .region, id: "region.root"), .init(kind: .type, id: "type.i32"),
                                                  .init(kind: .variable, id: "variable.value"), .init(kind: .varnode, id: "varnode.x0")])],
                pseudocodeDocument: .init(text: "value", language: "c", isComplete: true, isTruncated: false), warnings: []
            )
        )
    }
}
