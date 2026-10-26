import Foundation
import XCTest
@testable import MacScope

final class NibKitDecoderTests: XCTestCase {
    private let sha = String(repeating: "a", count: 64)

    private func scope(_ label: String = "MainMenu.nib") -> NibKitDecodeInput {
        .init(admittedResources: [
            label: AppKitResourceIdentity(bundleID: "com.example.fixture",
                                          bundleGeneration: "bundle-v1",
                                          relativePath: "Base.lproj/" + label,
                                          contentSHA256: sha)
        ], donorRevision: NibKitRevision.reviewed, helperExitCode: 0)
    }

    private let base = #"""
    {
      "file":"MainMenu.nib", "formatVersion":11, "coderVersion":1,
      "outlets":[{"kind":"outlet","name":"saveButton","source":"DocumentController","destination":"NSButton"}],
      "actions":[
        {"kind":"action","name":"saveDocument:","source":"NSButton","destination":"DocumentController"},
        {"kind":"binding","name":"value","source":"NSButton","destination":"DocumentController"}
      ],
      "runtimeAttrs":[], "classes":[], "navigation":[]
    }
    """#

    func testSingleObjectAcceptsAndPreservesBindingInActionsArray() throws {
        let parsed = NibKitDecoder().decode(Data(base.utf8), input: scope())
        XCTAssertTrue(parsed.complete)
        XCTAssertEqual(parsed.documents.count, 1)
        XCTAssertEqual(parsed.documents[0].actions.count, 2)
        XCTAssertEqual(parsed.documents[0].actions[1].kind, "binding")
        XCTAssertEqual(parsed.documents[0].resource.relativePath, "Base.lproj/MainMenu.nib")
        XCTAssertTrue(parsed.refusals.isEmpty)
    }

    func testArrayOfSingleDocumentIsAlsoAccepted() throws {
        let parsed = NibKitDecoder().decode(Data("[\(base)]".utf8), input: scope())
        XCTAssertTrue(parsed.complete)
        XCTAssertEqual(parsed.documents.count, 1)
    }

    func testDuplicateDocumentLabelsDoNotDoubleCount() {
        let parsed = NibKitDecoder().decode(Data("[\(base),\(base)]".utf8), input: scope())
        XCTAssertFalse(parsed.complete)
        XCTAssertTrue(parsed.documents.isEmpty)
        XCTAssertTrue(parsed.refusals.contains(where: { $0.reason == .duplicateDocument }))
    }

    func testMixedValidAndCorruptDocumentsAreNotPartiallyAdmitted() {
        let bad = #"{"file":"Bad.nib","error":"unexpected end"}"#
        let raw = Data("[\(base),\(bad)]".utf8)
        let expected = ["MainMenu.nib": scope().admittedResources["MainMenu.nib"]!,
                        "Bad.nib": AppKitResourceIdentity(bundleID: "com.example.fixture",
                                       bundleGeneration: "bundle-v1", relativePath: "Bad.nib",
                                       contentSHA256: sha)]
        let context = NibKitDecodeInput(admittedResources: expected,
                                        donorRevision: NibKitRevision.reviewed, helperExitCode: 1)
        let parsed = NibKitDecoder().decode(raw, input: context)
        XCTAssertFalse(parsed.complete)
        XCTAssertTrue(parsed.documents.isEmpty)
        XCTAssertEqual(parsed.refusals.filter { $0.reason == .donorDocumentError }.count, 1)
    }

    func testErrorRowAndNonzeroExitFailClosed() {
        let json = #"{"file":"MainMenu.nib","error":"untrusted source text"}"#
        let baseInput = scope()
        let context = NibKitDecodeInput(admittedResources: baseInput.admittedResources,
                                        donorRevision: NibKitRevision.reviewed,
                                        helperExitCode: 1)
        let parsed = NibKitDecoder().decode(Data(json.utf8), input: context)
        XCTAssertFalse(parsed.complete)
        XCTAssertTrue(parsed.documents.isEmpty)
        XCTAssertTrue(parsed.refusals.contains(where: { $0.reason == .donorDocumentError }))
        XCTAssertTrue(parsed.refusals.contains(where: { $0.reason == .donorExitNonzero }))
        XCTAssertFalse(parsed.refusals.map(\.detail).joined().contains("untrusted source text"))
    }

    func testWrongDonorRevisionIsRejectedBeforeParsing() {
        let input = NibKitDecodeInput(admittedResources: scope().admittedResources,
                                      donorRevision: "unknown-revision", helperExitCode: 0)
        let parsed = NibKitDecoder().decode(Data(base.utf8), input: input)
        XCTAssertFalse(parsed.complete)
        XCTAssertEqual(parsed.refusals.first?.reason, .unsupportedDonorRevision)
    }

    func testMissingRequiredAllCommandFieldsIsRejected() {
        let json = #"{"file":"MainMenu.nib","formatVersion":11,"coderVersion":1,"actions":[]}"#
        let parsed = NibKitDecoder().decode(Data(json.utf8), input: scope())
        XCTAssertFalse(parsed.complete)
        XCTAssertEqual(parsed.refusals.first?.reason, .missingRequiredFields)
    }

    func testOutputLimitRefusesBeforeJSONDecode() {
        let limits = NibKitDecodeLimits(maxOutputBytes: 10)
        let parsed = NibKitDecoder(limits: limits).decode(Data(base.utf8), input: scope())
        XCTAssertFalse(parsed.complete)
        XCTAssertEqual(parsed.refusals.first?.reason, .outputTooLarge)
    }

    func testMalformedAndUnadmittedDocumentFailClosed() {
        let malformed = NibKitDecoder().decode(Data("{".utf8), input: scope())
        XCTAssertEqual(malformed.refusals.first?.reason, .corruptJSON)
        let alien = base.replacingOccurrences(of: "MainMenu.nib", with: "Other.nib")
        let unadmitted = NibKitDecoder().decode(Data(alien.utf8), input: scope())
        XCTAssertFalse(unadmitted.complete)
        XCTAssertTrue(unadmitted.documents.isEmpty)
        XCTAssertTrue(unadmitted.refusals.contains(where: { $0.reason == .unexpectedDocument }))
    }

    func testBadResourcePathAndWrongDigestRefused() {
        let bad = AppKitResourceIdentity(bundleID: "com.example.fixture", bundleGeneration: "g1",
                                         relativePath: "../private/MainMenu.nib", contentSHA256: "abc")
        let input = NibKitDecodeInput(admittedResources: ["MainMenu.nib": bad],
                                      donorRevision: NibKitRevision.reviewed, helperExitCode: 0)
        let parsed = NibKitDecoder().decode(Data(base.utf8), input: input)
        XCTAssertEqual(parsed.refusals.first?.reason, .invalidResourceIdentity)
    }

    func testUpstreamUnknownFieldsDoNotCauseSilentSemanticPromotion() {
        let future = base.replacingOccurrences(of: "\"coderVersion\":1,",
                                                with: "\"coderVersion\":1,\"confirmedRuntimeDispatch\":true,")
        let parsed = NibKitDecoder().decode(Data(future.utf8), input: scope())
        XCTAssertTrue(parsed.complete)
        let image = AppKitImageKey(imageID: "main", imageGeneration: "g1", bundleGeneration: "bundle-v1")
        let fact = ObjCMethodFact(image: image, ownerClass: "DocumentController", selector: "saveDocument:",
                                  isClassMethod: false, implementationVMAddress: 0x100001000)
        let claims = AppKitFusionEngine().reconcile(document: parsed.documents[0], methodFacts: [fact],
                                                    allowedImageKeys: [image])
        XCTAssertTrue(claims.allSatisfy { !$0.runtimeDispatchProven })
    }
}
