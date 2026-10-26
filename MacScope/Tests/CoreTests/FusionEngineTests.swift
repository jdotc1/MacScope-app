import Foundation
import XCTest
import MacScopeAnalysisCore
@testable import MacScope

final class FusionEngineTests: XCTestCase {
    private typealias FusionTestMethodOwner = MacScopeAnalysisCore.AppKitObjCMethodOwnerKind

    private let sha = String(repeating: "b", count: 64)
    private let image = AppKitImageKey(imageID: "slot-1", imageGeneration: "image-1",
                                       bundleGeneration: "bundle-1")

    private func document(destination: String = "DocumentController", selector: String = "saveDocument:",
                          kind: String = "action") -> NibDecodedDocument {
        let resource = AppKitResourceIdentity(bundleID: "com.example.fixture", bundleGeneration: "bundle-1",
                                              relativePath: "Base.lproj/MainMenu.nib", contentSHA256: sha)
        return .init(resource: resource, donorRevision: NibKitRevision.reviewed,
                     archiveFormatVersion: 11, coderVersion: 1,
                     outlets: [.init(kind: "outlet", name: "button", source: "DocumentController",
                                     destination: "NSButton")],
                     actions: [.init(kind: kind, name: selector, source: "NSButton",
                                     destination: destination)], runtimeAttributes: [],
                     customClasses: [], navigation: [])
    }

    private func fusionMethodFact(image key: AppKitImageKey? = nil, className: String = "DocumentController",
                        selector: String = "saveDocument:", isClass: Bool = false,
                        owner: FusionTestMethodOwner = .classDefinition, imp: UInt64? = 0x100001000) -> ObjCMethodFact {
        ObjCMethodFact(image: key ?? image, ownerClass: className, selector: selector,
                       isClassMethod: isClass, ownerKind: owner, implementationVMAddress: imp)
    }

    func testExactUniqueInstanceMethodIsStaticCorroborationOnly() {
        let claims = AppKitFusionEngine().reconcile(document: document(), methodFacts: [fusionMethodFact()],
                                                     allowedImageKeys: [image])
        XCTAssertEqual(claims.count, 2)
        XCTAssertEqual(claims[0].status, .observed) // outlet, not a call
        XCTAssertEqual(claims[1].kind, "action")
        XCTAssertEqual(claims[1].status, .corroboratedStatic)
        XCTAssertEqual(claims[1].candidateImplementation?.vmAddress, 0x100001000)
        XCTAssertFalse(claims[1].runtimeDispatchProven)
        XCTAssertEqual(claims[1].evidenceOrigins.count, 2)
    }

    func testResourceAttributeValueAndEventLabelSurviveProjection() {
        let resource = AppKitResourceIdentity(bundleID: "com.example.fixture",
                                              bundleGeneration: "bundle-1",
                                              relativePath: "MainMenu.nib", contentSHA256: sha)
        let doc = NibDecodedDocument(
            resource: resource, donorRevision: NibKitRevision.reviewed,
            archiveFormatVersion: 11, coderVersion: 1, outlets: [],
            actions: [.init(kind: "action", name: "saveDocument:", source: "NSButton",
                            destination: "DocumentController", event: "primaryActionTriggered")],
            runtimeAttributes: [.init(object: "NSButton", keyPath: "identifier", value: "save-button")],
            customClasses: [], navigation: [])
        let claims = AppKitFusionEngine().reconcile(document: doc,
                                                     methodFacts: [fusionMethodFact()], allowedImageKeys: [image])
        XCTAssertEqual(claims[0].eventLabel, "primaryActionTriggered")
        XCTAssertEqual(claims[1].status, .observed)
        XCTAssertEqual(claims[1].observedValue, "save-button")
    }

    func testBindingInActionsArrayNeverResolvesToMethod() {
        let claims = AppKitFusionEngine().reconcile(document: document(kind: "binding"),
                                                     methodFacts: [fusionMethodFact()], allowedImageKeys: [image])
        XCTAssertEqual(claims[1].kind, "connector.binding")
        XCTAssertEqual(claims[1].status, .observed)
        XCTAssertNil(claims[1].candidateImplementation)
    }

    func testNilProxyAndResponderChainAreNotConcreteTargets() {
        for destination in ["File's Owner(proxy)", "First Responder", "NSApplication", "UIPlaceholder"] {
            let claims = AppKitFusionEngine().reconcile(document: document(destination: destination),
                                                         methodFacts: [fusionMethodFact(className: destination)],
                                                         allowedImageKeys: [image])
            XCTAssertEqual(claims[1].status, .unresolved, destination)
            XCTAssertEqual(claims[1].refusalReason, "dynamic-or-proxy-target", destination)
        }
    }

    func testSameClassAndSelectorFromDifferentImagesIsAmbiguous() {
        let second = AppKitImageKey(imageID: "plugin", imageGeneration: "image-2",
                                    bundleGeneration: "bundle-1")
        let claims = AppKitFusionEngine().reconcile(document: document(),
                              methodFacts: [fusionMethodFact(), fusionMethodFact(image: second, imp: 0x200001000)],
                              allowedImageKeys: [image, second])
        XCTAssertEqual(claims[1].status, .unresolved)
        XCTAssertEqual(claims[1].candidateCount, 2)
        XCTAssertNil(claims[1].candidateImplementation)
    }

    func testCategoryCollisionRemainsAmbiguous() {
        let claims = AppKitFusionEngine().reconcile(document: document(),
                      methodFacts: [fusionMethodFact(), fusionMethodFact(owner: .categoryDefinition, imp: 0x100002000)],
                      allowedImageKeys: [image])
        XCTAssertEqual(claims[1].refusalReason, "ambiguous-method-owner-or-image")
    }

    func testClassMethodIsNotIBActionImplementation() {
        let claims = AppKitFusionEngine().reconcile(document: document(),
                                                     methodFacts: [fusionMethodFact(isClass: true)],
                                                     allowedImageKeys: [image])
        XCTAssertEqual(claims[1].refusalReason, "no-exact-instance-method")
    }

    func testMissingIMPIsCandidateWithoutAddress() {
        let claims = AppKitFusionEngine().reconcile(document: document(),
                                                     methodFacts: [fusionMethodFact(imp: nil)],
                                                     allowedImageKeys: [image])
        XCTAssertEqual(claims[1].status, .candidate)
        XCTAssertNil(claims[1].candidateImplementation)
    }

    func testOldBundleGenerationDoesNotJoinFreshBinaryMethod() {
        let fresh = AppKitImageKey(imageID: "slot-1", imageGeneration: "fresh-image",
                                   bundleGeneration: "bundle-2")
        let claims = AppKitFusionEngine().reconcile(document: document(),
                                                     methodFacts: [fusionMethodFact(image: fresh)],
                                                     allowedImageKeys: [fresh])
        XCTAssertEqual(claims[1].refusalReason, "no-matching-image-generation")
        XCTAssertNil(claims[1].candidateImplementation)
    }

    func testCaseDifferenceAndEmptySelectorRefuse() {
        let mismatch = AppKitFusionEngine().reconcile(document: document(selector: "savedocument:"),
                                                       methodFacts: [fusionMethodFact()], allowedImageKeys: [image])
        XCTAssertEqual(mismatch[1].status, .unresolved)
        let empty = AppKitFusionEngine().reconcile(document: document(selector: ""),
                                                    methodFacts: [fusionMethodFact()], allowedImageKeys: [image])
        XCTAssertEqual(empty[1].refusalReason, "missing-or-invalid-selector")
    }

    func testDeterministicJSONAndClaimID() throws {
        let engine = AppKitFusionEngine()
        let first = engine.reconcile(document: document(), methodFacts: [fusionMethodFact()],
                                      allowedImageKeys: [image])
        let second = engine.reconcile(document: document(), methodFacts: [fusionMethodFact()],
                                       allowedImageKeys: [image])
        XCTAssertEqual(first.map(\.claimID), second.map(\.claimID))
        XCTAssertEqual(try AppKitDeterministicCodec.claimsJSON(first),
                       try AppKitDeterministicCodec.claimsJSON(Array(second.reversed())))
    }

    func testCategoryOnlySaveRemainsUnresolved() {
        let result = AppKitFusionEngine().evaluate(document: document(selector: "save:"),
            methodFacts: [fusionMethodFact(selector: "save:", owner: .categoryDefinition)], allowedImageKeys: [image])
        guard case .claims(let claims) = result else { return XCTFail("expected claims") }
        XCTAssertEqual(claims[1].status, .unresolved)
        XCTAssertEqual(claims[1].refusalReason, "category-owned-method")
        XCTAssertEqual(claims[1].candidateCount, 1)
        XCTAssertNil(claims[1].candidateImplementation)
    }

    func testClassSaveStillCorroboratesAndCategoryCollisionRefuses() {
        let engine = AppKitFusionEngine()
        let doc = document(selector: "save:")
        let cls = fusionMethodFact(selector: "save:")
        guard case .claims(let unique) = engine.evaluate(document: doc, methodFacts: [cls],
            allowedImageKeys: [image]) else { return XCTFail("expected class claims") }
        XCTAssertEqual(unique[1].status, .corroboratedStatic)
        guard case .claims(let collision) = engine.evaluate(document: doc,
            methodFacts: [cls, fusionMethodFact(selector: "save:", owner: .categoryDefinition)],
            allowedImageKeys: [image]) else { return XCTFail("expected ambiguous claims") }
        XCTAssertEqual(collision[1].status, .unresolved)
        XCTAssertEqual(collision[1].refusalReason, "ambiguous-method-owner-or-image")
        XCTAssertEqual(collision[1].candidateCount, 2)
        XCTAssertNil(collision[1].candidateImplementation)
    }

    func testMethodFactCapReturnsTypedRefusal() {
        let result = AppKitFusionEngine().evaluate(document: document(),
            methodFacts: Array(repeating: fusionMethodFact(), count: 65_537), allowedImageKeys: [image])
        guard case .refused(let refusal) = result else { return XCTFail("expected cap refusal") }
        XCTAssertEqual(refusal.reason, .tooManyRecords)
        XCTAssertTrue(refusal.detail.contains("65,536"))
    }

    func testWrongDonorRevisionReturnsTypedRefusal() {
        let doc = NibDecodedDocument(resource: document().resource, donorRevision: "unknown",
            archiveFormatVersion: 1, coderVersion: 1, outlets: [], actions: [],
            runtimeAttributes: [], customClasses: [], navigation: [])
        guard case .refused(let refusal) = AppKitFusionEngine().evaluate(document: doc,
            methodFacts: [], allowedImageKeys: [image]) else { return XCTFail("expected donor refusal") }
        XCTAssertEqual(refusal.reason, .unsupportedDonorRevision)
    }

    func testDocumentRecordCapReturnsTypedRefusal() {
        let doc = NibDecodedDocument(resource: document().resource, donorRevision: NibKitRevision.reviewed,
            archiveFormatVersion: 1, coderVersion: 1,
            outlets: Array(repeating: document().outlets[0], count: 65_537), actions: [],
            runtimeAttributes: [], customClasses: [], navigation: [])
        guard case .refused(let refusal) = AppKitFusionEngine().evaluate(document: doc,
            methodFacts: [], allowedImageKeys: [image]) else { return XCTFail("expected record refusal") }
        XCTAssertEqual(refusal.reason, .tooManyRecords)
        XCTAssertTrue(refusal.detail.contains("65,536"))
    }

    func testCompactFirstResponderLabelsRemainDynamicDespiteMatchingClass() {
        for name in ["FirstResponder", "NSFirstResponder", "fIrStReSpOnDeR"] {
            guard case .claims(let claims) = AppKitFusionEngine().evaluate(
                document: document(destination: name), methodFacts: [fusionMethodFact(className: name)],
                allowedImageKeys: [image]) else { return XCTFail("expected unresolved claims") }
            XCTAssertEqual(claims[1].status, .unresolved)
            XCTAssertEqual(claims[1].refusalReason, "dynamic-or-proxy-target")
            XCTAssertNil(claims[1].candidateImplementation)
        }
    }

}
