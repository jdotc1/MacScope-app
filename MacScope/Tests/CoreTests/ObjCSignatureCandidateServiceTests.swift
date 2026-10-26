import Foundation
import ObjectiveC.runtime
import XCTest
@testable import MacScope

final class ObjCSignatureCandidateServiceTests: XCTestCase {
    private let address = UInt64(0x1_0000_1000)
    private let binaryID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func context(
        selector: String = "setObject:",
        encoding: String? = "v24@0:8@16"
    ) -> ObjCSignatureCandidate.Context {
        .init(
            target: .primary(address),
            ownerBinaryID: binaryID,
            architecture: "arm64",
            imageUUID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            imageSDKVersion: "27.2",
            methodSelector: selector,
            methodIsClassMethod: false,
            methodTypeEncoding: encoding
        )
    }

    func testCompleteMetadataCandidateIsAcceptableAndRemainsMetadataBacked() {
        let candidate = makeCandidate(
            selector: "setObject:",
            encoding: "v24@0:8@16"
        )

        XCTAssertTrue(candidate.canAccept)
        XCTAssertEqual(candidate.returnField.type, "void")
        XCTAssertEqual(candidate.returnField.source, .metadata)
        XCTAssertEqual(candidate.parameters.map(\.field.type), ["id"])
        XCTAssertEqual(candidate.parameters.map(\.field.source), [.metadata])
    }

    func testCompilerBuiltObjectiveCFixtureProducesAnAcceptableKnownDeclaration() throws {
        let fixtureClass = try XCTUnwrap(NSClassFromString("MSSignatureCandidateFixture"))
        let method = try XCTUnwrap(class_getInstanceMethod(
            fixtureClass,
            NSSelectorFromString("lookupIndex:error:")
        ))
        let encoding = String(cString: try XCTUnwrap(method_getTypeEncoding(method)))
        let candidate = makeCandidate(
            selector: "lookupIndex:error:",
            encoding: encoding
        )

        XCTAssertTrue(candidate.canAccept, candidate.diagnostics.map(\.message).joined(separator: "\n"))
        // Method encodings preserve object identity as id, without the declared class name.
        XCTAssertEqual(candidate.returnField.type, "id")
        XCTAssertEqual(candidate.parameters.count, 2)
        XCTAssertTrue(candidate.parameters.allSatisfy { $0.field.source == .metadata })
    }

    func testLocalHypothesisFillsOnlyUnknownFieldsAndKeepsItsSourceVisible() {
        let candidate = makeCandidate(
            selector: "lookup:",
            encoding: nil,
            hypothesis: ObjCSignatureHypothesis(
                returnType: "NSString *",
                parameterTypes: ["NSInteger"],
                parameterNames: ["index"],
                sdkVersion: "27.2",
                explanation: "Bounded local proposal"
            )
        )

        XCTAssertTrue(candidate.canAccept)
        XCTAssertEqual(candidate.returnField.source, .mtplxHypothesis)
        XCTAssertEqual(candidate.parameters.first?.field.source, .mtplxHypothesis)
        XCTAssertEqual(candidate.parameters.first?.name, "index")
        XCTAssertTrue(candidate.diagnostics.contains { $0.code == "metadata-absent" })
    }

    func testSelectorArityAndMissingTypeRejectBeforeAcceptance() {
        let candidate = makeCandidate(
            selector: "replace:with:",
            encoding: nil,
            hypothesis: ObjCSignatureHypothesis(
                returnType: "void",
                parameterTypes: ["id"],
                parameterNames: ["value"],
                sdkVersion: "27.2",
                explanation: "Incomplete proposal"
            )
        )

        XCTAssertFalse(candidate.canAccept)
        XCTAssertTrue(candidate.diagnostics.contains { $0.code == "hypothesis-arity" })
        XCTAssertTrue(candidate.diagnostics.contains { $0.code == "missing-parameter" })
    }

    func testSDKVersionMismatchRejectsDeclarationAndHypothesis() {
        let declaration = ObjCSignatureDeclaration(
            source: .sdk,
            selector: "lookup:",
            returnType: "NSString *",
            parameterTypes: ["NSInteger"],
            parameterNames: ["index"],
            sdkVersion: "26.0"
        )
        let candidate = makeCandidate(
            selector: "lookup:",
            encoding: nil,
            declaration: declaration,
            hypothesis: nil
        )

        XCTAssertFalse(candidate.canAccept)
        XCTAssertTrue(candidate.diagnostics.contains { $0.code == "declaration-sdk-version" })
    }

    func testMetadataContradictionAndABIWidthRejectDeterministically() {
        let candidate = makeCandidate(
            selector: "setObject:",
            encoding: "v24@0:8@16",
            hypothesis: ObjCSignatureHypothesis(
                returnType: "void",
                parameterTypes: ["NSString *"],
                parameterNames: ["object"],
                sdkVersion: "27.2",
                explanation: "Contradictory proposal"
            ),
            observations: [
                ObjCSignatureObservation(
                    position: .parameter(0),
                    type: nil,
                    widthBits: 32,
                    source: "call-site register use"
                ),
            ]
        )

        XCTAssertFalse(candidate.canAccept)
        XCTAssertTrue(candidate.diagnostics.contains { $0.code == "hypothesis-conflict" })
        XCTAssertTrue(candidate.diagnostics.contains { $0.code == "abi-width" })
    }

    func testUnknownNominalTypeIsNotSilentlyAdmitted() {
        let candidate = makeCandidate(
            selector: "lookup:",
            encoding: nil,
            hypothesis: ObjCSignatureHypothesis(
                returnType: "InventedController *",
                parameterTypes: ["NSInteger"],
                parameterNames: ["index"],
                sdkVersion: "27.2",
                explanation: "Unknown nominal"
            )
        )

        XCTAssertFalse(candidate.canAccept)
        XCTAssertTrue(candidate.diagnostics.contains { $0.code == "unknown-nominal" })
    }

    func testChangedImageIdentityMakesCandidateStale() {
        let candidate = makeCandidate(selector: "setObject:", encoding: "v24@0:8@16")
        var replacement = context()
        replacement.ownerBinaryID = UUID()

        XCTAssertEqual(
            ObjCSignatureCandidateService.validateCurrentContext(candidate, current: replacement)?.code,
            "stale-context"
        )
    }

    @MainActor
    func testApplyingCandidateOnlyEditsDraftAndSaveUsesUndoableSignaturePath() throws {
        var analysis = ImageAnalysis()
        analysis.instructions = [InstructionRow(
            address: address,
            bytes: "c0 03 5f d6",
            mnemonic: "ret",
            operands: "",
            hasBreakpoint: false,
            comment: nil
        )]
        analysis.functions = [FunctionSummary(
            id: UUID(),
            name: "-[Widget setObject:]",
            startAddress: address,
            endAddress: address + 4,
            confidence: 1
        )]
        analysis.objcClasses = [ObjCClass(
            name: "Widget",
            superclassName: "NSObject",
            adoptedProtocols: [],
            classMethods: [],
            instanceMethods: [ObjCMethod(
                selector: "setObject:",
                typeEncoding: "v24@0:8@16",
                isClassMethod: false,
                implementation: address
            )],
            ivars: [],
            properties: [],
            address: 0x1_0000_2000
        )]
        let binary = BinaryImage(
            id: binaryID,
            name: "Widget",
            path: "/tmp/Widget",
            kind: "Mach-O",
            architecture: "arm64",
            metadata: BinaryMetadataSummary(
                uuid: context().imageUUID,
                platformName: "macOS",
                minimumOSVersion: "27.0",
                sdkVersion: "27.2"
            )
        )
        let store = WorkspaceStore(
            workspaceName: "ObjC candidates",
            snapshot: WorkspaceSnapshot(binaries: [binary], analysisBySlot: [.primary: analysis]),
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )
        store.selectInstruction(address)
        store.beginSignatureEditAtSelection()
        var draft = try XCTUnwrap(store.signatureEditorRequest)
        let candidate = try XCTUnwrap(draft.objcCandidates.first)

        store.applyObjCSignatureCandidate(candidate, to: &draft)
        XCTAssertNil(store.snapshot.addressOverrides[.primary(address)]?.signature)
        XCTAssertEqual(draft.returnType, "void")
        XCTAssertEqual(draft.args.map(\.type), ["id"])

        store.commitSignatureEditor(draft)
        XCTAssertNotNil(store.snapshot.addressOverrides[.primary(address)]?.signature)
        store.undoManager.undo()
        XCTAssertNil(store.snapshot.addressOverrides[.primary(address)]?.signature)
    }

    private func makeCandidate(
        selector: String,
        encoding: String?,
        declaration: ObjCSignatureDeclaration? = nil,
        hypothesis: ObjCSignatureHypothesis? = nil,
        observations: [ObjCSignatureObservation] = []
    ) -> ObjCSignatureCandidate {
        ObjCSignatureCandidateService.makeCandidate(.init(
            context: context(selector: selector, encoding: encoding),
            method: ObjCMethod(
                selector: selector,
                typeEncoding: encoding,
                isClassMethod: false,
                implementation: address
            ),
            knownNominalTypes: ["NSObject", "NSString"],
            declaration: declaration,
            hypothesis: hypothesis,
            observations: observations
        ))
    }
}
