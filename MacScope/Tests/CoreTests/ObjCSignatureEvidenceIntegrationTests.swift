import Foundation
import XCTest
@testable import MacScope

@MainActor
final class ObjCSignatureEvidenceIntegrationTests: XCTestCase {
    private let address: UInt64 = 0x1_0000_1000
    private let imageUUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    func testQualifiedDWARFAndExplicitSDKUnknown() throws {
        let store = makeStore(encoding: nil)
        store.retainObjCSignatureDeclarations(debugImport(), in: .primary)
        let candidate = try candidate(in: store)
        XCTAssertTrue(candidate.canAccept)
        XCTAssertEqual(candidate.returnField.type, "void")
        XCTAssertEqual(candidate.returnField.source, .dwarfDeclaration)
        XCTAssertEqual(candidate.parameters.map(\.field.type), ["id"])
        XCTAssertEqual(candidate.parameters.map(\.name), ["value"])
        XCTAssertTrue(candidate.evidence.contains { $0.detail == "SDK declarations: no trusted source" })
        XCTAssertTrue(candidate.evidence.contains { $0.source.contains("artifact " + String(repeating: "a", count: 64)) })
    }

    func testForeignAndUnsealedImportsNeverSupplyDeclarations() throws {
        let store = makeStore(encoding: nil)
        var wrongUUID = debugImport()
        wrongUUID.matchedUUID = UUID().uuidString
        var wrongArchitecture = debugImport()
        wrongArchitecture.matchedSliceArchitecture = "x86_64"
        var unsealed = debugImport()
        unsealed.debugArtifactSeal = nil
        for result in [wrongUUID, wrongArchitecture, unsealed] {
            store.retainObjCSignatureDeclarations(result, in: .primary)
            let candidate = try candidate(in: store)
            XCTAssertNil(candidate.returnField.type)
            XCTAssertNil(candidate.parameters.first?.field.type)
            XCTAssertFalse(candidate.canAccept)
        }
        store.retainObjCSignatureDeclarations(debugImport(), in: .primary)
        store.snapshot.binaries[0].selectedSliceIndex = 2
        XCTAssertNil(try candidate(in: store).returnField.type)
        store.snapshot.binaries[0].selectedSliceIndex = 1
        store.snapshot.binaries[0].metadata.sdkVersion = "26.0"
        XCTAssertNil(try candidate(in: store).returnField.type)
        store.snapshot.binaries[0].metadata.sdkVersion = "27.2"
        replaceOwner(in: store)
        XCTAssertNil(try candidate(in: store).returnField.type)
    }

    func testUserOverrideNeverBecomesDeclarationAndAmbiguousArgumentsStayUnknown() throws {
        let store = makeStore(encoding: nil)
        store.setSignature(address, .init(returnType: "int", args: []))
        XCTAssertNil(try candidate(in: store).returnField.type)
        var result = debugImport()
        result.signatureDeclarations[address]?.parameters[0].isArtificial = false
        store.retainObjCSignatureDeclarations(result, in: .primary)
        let candidate = try candidate(in: store)
        XCTAssertNil(candidate.returnField.type)
        XCTAssertNil(candidate.parameters.first?.field.type)
        XCTAssertFalse(candidate.canAccept)
    }

    func testHypothesisContradictionCannotReplaceDeclaration() throws {
        let store = makeStore(encoding: nil)
        store.retainObjCSignatureDeclarations(debugImport(), in: .primary)
        let proposed = store.objcSignatureCandidates(at: address, in: .primary, hypothesis: .init(
            returnType: "int", parameterTypes: ["id"], parameterNames: ["value"],
            sdkVersion: "27.2", explanation: "Unconfirmed return proposal"
        ))
        let candidate = try XCTUnwrap(proposed.first)
        XCTAssertEqual(candidate.returnField.type, "void")
        XCTAssertEqual(candidate.returnField.source, .dwarfDeclaration)
        XCTAssertFalse(candidate.canAccept)
        XCTAssertTrue(candidate.diagnostics.contains { $0.code == "hypothesis-conflict" })
        XCTAssertTrue(candidate.evidence.contains { $0.kind == "Hypothesis" })
    }

    func testAcceptedSignatureRoundTripsAndUndoRestoresPriorSignature() throws {
        let store = makeStore()
        let prior = FunctionSignatureOverride(returnType: "int", args: [
            .init(index: 0, name: "previous", type: "int")
        ])
        store.setSignature(address, prior)
        store.undoManager.removeAllActions()
        store.beginSignatureEditAtSelection()
        var draft = try XCTUnwrap(store.signatureEditorRequest)
        let candidate = try XCTUnwrap(draft.objcCandidates.first)
        store.applyObjCSignatureCandidate(candidate, to: &draft)
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(address)]?.signature, prior)
        store.commitSignatureEditor(draft)
        let accepted = try XCTUnwrap(store.snapshot.addressOverrides[.primary(address)]?.signature)
        XCTAssertEqual(accepted.returnType, "void")
        XCTAssertEqual(accepted.args.map(\.type), ["id"])
        let encoded = try JSONEncoder().encode(WorkspacePackageAnalysis(snapshot: store.snapshot))
        let decoded = try JSONDecoder().decode(WorkspacePackageAnalysis.self, from: encoded)
        let reopened = decoded.snapshot(binaries: store.snapshot.binaries, hexBytes: store.snapshot.hexBytes)
        XCTAssertEqual(reopened.addressOverrides[.primary(address)]?.signature, accepted)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("objcCandidates"))
        store.undoManager.undo()
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(address)]?.signature, prior)
    }

    func testAcceptedReturnMatchingPreviewStillPersists() throws {
        let store = makeStore()
        store.beginSignatureEditAtSelection()
        var draft = try XCTUnwrap(store.signatureEditorRequest)
        let candidate = try XCTUnwrap(draft.objcCandidates.first)
        draft.baselineReturnType = "void"
        draft.returnType = "void"
        XCTAssertNil(draft.originalReturnType)
        store.applyObjCSignatureCandidate(candidate, to: &draft)
        store.commitSignatureEditor(draft)
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(address)]?.signature?.returnType, "void")
    }

    func testRejectedAndTamperedCandidatesLeaveDraftAndWorkspaceUntouched() throws {
        let store = makeStore(encoding: nil)
        store.beginSignatureEditAtSelection()
        var draft = try XCTUnwrap(store.signatureEditorRequest)
        let originalDraft = draft
        var candidate = try XCTUnwrap(draft.objcCandidates.first)
        XCTAssertFalse(candidate.canAccept)
        store.applyObjCSignatureCandidate(candidate, to: &draft)
        XCTAssertEqual(draft, originalDraft)
        candidate.returnField = .init(type: "void", source: .metadata, note: "fabricated")
        candidate.parameters[0].field = .init(type: "id", source: .metadata, note: "fabricated")
        candidate.diagnostics = []
        XCTAssertTrue(candidate.canAccept)
        store.applyObjCSignatureCandidate(candidate, to: &draft)
        XCTAssertEqual(draft, originalDraft)
        XCTAssertNil(store.snapshot.addressOverrides[.primary(address)]?.signature)
    }

    func testImageSliceAndSourceGenerationChangesRefuseApplyAndSave() throws {
        for change in 0..<4 {
            let store = makeStore()
            store.retainObjCSignatureDeclarations(debugImport(), in: .primary)
            store.beginSignatureEditAtSelection()
            var acceptedDraft = try XCTUnwrap(store.signatureEditorRequest)
            var untouchedDraft = acceptedDraft
            let originalDraft = untouchedDraft
            let candidate = try XCTUnwrap(acceptedDraft.objcCandidates.first)
            store.applyObjCSignatureCandidate(candidate, to: &acceptedDraft)
            switch change {
            case 0: replaceOwner(in: store)
            case 1: store.snapshot.binaries[0].selectedSliceIndex = 2
            case 2: store.retainObjCSignatureDeclarations(debugImport(), in: .primary)
            default:
                var invalid = debugImport()
                invalid.debugArtifactSeal = nil
                store.retainObjCSignatureDeclarations(invalid, in: .primary)
            }
            store.applyObjCSignatureCandidate(candidate, to: &untouchedDraft)
            XCTAssertEqual(untouchedDraft, originalDraft)
            store.commitSignatureEditor(acceptedDraft)
            XCTAssertNil(store.snapshot.addressOverrides[.primary(address)]?.signature)
        }
    }

    func testUnavailableProviderLeavesMetadataCandidateUsable() throws {
        let store = makeStore()
        store.beginSignatureEditAtSelection()
        store.startObjCSignatureInference(coordinator: nil)
        let candidate = try XCTUnwrap(store.signatureEditorRequest?.objcCandidates.first)
        XCTAssertEqual(candidate.hypothesisState, .unavailable)
        XCTAssertTrue(candidate.canAccept)
        XCTAssertNil(store.objcSignatureInferenceTask)
    }

    func testSelectionChangeCancelsPendingInferenceAndLateCompletionCannotPublish() async throws {
        let store = makeStore()
        store.beginSignatureEditAtSelection()
        let coordinator = HeldSignatureInferenceCoordinator()
        store.startObjCSignatureInference(coordinator: coordinator)
        for _ in 0..<100 where !coordinator.started { await Task.yield() }
        XCTAssertTrue(coordinator.started)
        XCTAssertEqual(store.signatureEditorRequest?.objcCandidates.first?.hypothesisState, .pending)
        store.selectedAddress = nil
        XCTAssertNil(store.objcSignatureInferenceTask)
        XCTAssertEqual(store.signatureEditorRequest?.objcCandidates.first?.hypothesisState, .unavailable)
        let candidateID = store.signatureEditorRequest?.objcCandidates.first?.id
        coordinator.finish()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(store.signatureEditorRequest?.objcCandidates.first?.id, candidateID)
        XCTAssertEqual(store.signatureEditorRequest?.objcCandidates.first?.hypothesisState, .unavailable)
    }

    func test349ZeroArityHelperFailureCannotBecomeAnEmptyQualifiedDeclaration() throws {
        for refusal in ["none", "direct", "missing-receiver", "missing-selector"] {
            let store = makeStore(encoding: nil, selector: "object")
            var result = debugImport()
            var declaration = DWARFFunctionDeclaration(
                returnType: "void", parameters: [
                    .init(name: nil, type: "id", isArtificial: true),
                    .init(name: nil, type: "SEL", isArtificial: true)
                ], hasAuthoritativeParameterList: true, isVariadic: false)
            switch refusal {
            case "direct": declaration.isObjectiveCDirect = true
            case "missing-receiver": declaration.parameters[0].isArtificial = false
            case "missing-selector": declaration.parameters[1].isArtificial = false
            default: break
            }
            result.signatureDeclarations[address] = declaration
            XCTAssertEqual(result.signatureDeclarations[address], declaration)
            XCTAssertEqual(declaration.parameters.count, 2)
            XCTAssertTrue(declaration.hasAuthoritativeParameterList)
            XCTAssertFalse(declaration.isVariadic)
            XCTAssertEqual(result.matchedUUID, imageUUID.uuidString)
            XCTAssertEqual(result.matchedSliceArchitecture, "arm64")
            XCTAssertNotNil(result.debugArtifactSeal)
            store.retainObjCSignatureDeclarations(result, in: .primary)
            let candidate = try candidate(in: store)
            XCTAssertEqual(candidate.parameters.count, 0)
            if refusal == "none" {
                let explicit = try XCTUnwrap(declaration.explicitObjectiveCParameters(selectorArity: 0))
                XCTAssertEqual(explicit, [])
                XCTAssertEqual(candidate.returnField.type, "void")
                XCTAssertEqual(candidate.returnField.source, .dwarfDeclaration)
                XCTAssertTrue(candidate.canAccept)
            } else {
                XCTAssertNil(declaration.explicitObjectiveCParameters(selectorArity: 0))
                XCTAssertNil(candidate.returnField.type)
                XCTAssertFalse(candidate.canAccept)
            }
        }
    }

    private func replaceOwner(in store: WorkspaceStore) {
        let old = store.snapshot.binaries[0]
        store.snapshot.binaries[0] = BinaryImage(id: UUID(), name: old.name, path: old.path,
            kind: old.kind, architecture: old.architecture, metadata: old.metadata,
            selectedSliceIndex: old.selectedSliceIndex, slot: old.slot)
    }

    private func candidate(in store: WorkspaceStore) throws -> ObjCSignatureCandidate {
        try XCTUnwrap(store.objcSignatureCandidates(at: address, in: .primary).first)
    }

    private func debugImport() -> DSYMImportResult {
        .init(functions: [], signatureDeclarations: [address: .init(
            returnType: "void", parameters: [
                .init(name: "self", type: "id", isArtificial: true),
                .init(name: "_cmd", type: "SEL", isArtificial: true),
                .init(name: "value", type: "id", isArtificial: false),
            ], hasAuthoritativeParameterList: true, isVariadic: false
        )], matchedUUID: imageUUID.uuidString, dwarfURL: URL(fileURLWithPath: "/tmp/Widget.dSYM"),
              debugArtifactSeal: .init(uuid: imageUUID, selectedMachOSHA256: String(repeating: "a", count: 64), selectedMachOByteCount: 128),
              matchedSliceArchitecture: "arm64")
    }

    private func makeStore(encoding: String? = "v24@0:8@16", selector: String = "setObject:") -> WorkspaceStore {
        var analysis = ImageAnalysis()
        analysis.instructions = [.init(address: address, bytes: "c0 03 5f d6", mnemonic: "ret",
                                       operands: "", hasBreakpoint: false, comment: nil)]
        analysis.functions = [.init(id: UUID(), name: "-[Widget \(selector)]", startAddress: address,
                                   endAddress: address + 4, confidence: 1)]
        analysis.objcClasses = [.init(name: "Widget", superclassName: "NSObject", adoptedProtocols: [],
                                     classMethods: [], instanceMethods: [.init(selector: selector, typeEncoding: encoding,
                                         isClassMethod: false, implementation: address)],
                                     ivars: [], properties: [], address: address + 0x1000)]
        let binary = BinaryImage(id: UUID(), name: "Widget", path: "/tmp/Widget", kind: "Mach-O", architecture: "arm64",
                                 metadata: .init(uuid: imageUUID.uuidString, platformName: "macOS",
                                                 minimumOSVersion: "27.0", sdkVersion: "27.2"), selectedSliceIndex: 1)
        let store = WorkspaceStore(workspaceName: "Signature evidence", snapshot: .init(binaries: [binary],
                                    analysisBySlot: [.primary: analysis]), engine: AnalysisEngine(), autosaveScheduler: nil)
        store.selectInstruction(address)
        return store
    }
}

@MainActor
private final class HeldSignatureInferenceCoordinator: Phase2AssistantInferenceCoordinating {
    var started = false
    private var continuation: CheckedContinuation<Phase2ReadyInferenceExecutionResult, Never>?

    func run(request: Phase2InferenceRequest) async -> Phase2ReadyInferenceExecutionResult {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func finish() {
        continuation?.resume(returning: .busy)
        continuation = nil
    }
}
