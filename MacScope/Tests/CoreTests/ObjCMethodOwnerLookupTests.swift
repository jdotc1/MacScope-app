import Foundation
import XCTest
@testable import MacScope

@MainActor
final class ObjCMethodOwnerLookupTests: XCTestCase {
    private let address: UInt64 = 0x1_0000_1000

    func testSameSelectorAtDifferentIMPsKeepsEachClassOwner() throws {
        let store = makeStore(classes: [objcClass("First"), objcClass("Second", imp: address + 4)])
        for (name, imp) in [("First", address), ("Second", address + 4)] {
            guard case .unique(let match) = store.objcMethod(at: imp, in: .primary) else {
                return XCTFail("Expected a unique class owner")
            }
            XCTAssertEqual(match.owner, owner(name))
            XCTAssertEqual(match.method, method(imp: imp))
            XCTAssertEqual(store.objcSignatureCandidateContext(at: imp, in: .primary)?.methodOwner, owner(name))
        }
    }

    func testSharedIMPAcrossClassesRefusesAndListsBothOwners() throws {
        let store = makeStore(classes: [objcClass("First"), objcClass("Second")])
        let matches = try ambiguousMatches(in: store)
        XCTAssertEqual(matches.map(\.owner), [owner("First"), owner("Second")])
        XCTAssertEqual(matches.map(\.displayName), ["-[First setObject:]", "-[Second setObject:]"])
        store.beginSignatureEditAtSelection()
        XCTAssertTrue(try XCTUnwrap(store.signatureEditorRequest).objcCandidates.isEmpty)
        let evidence = try XCTUnwrap(store.objcMethod(at: address, in: .primary).ambiguityEvidence)
        XCTAssertEqual(evidence.kind, "Unknown")
        XCTAssertEqual(evidence.source, "Objective-C metadata")
        XCTAssertEqual(evidence.detail,
                       "Ambiguous method owner: -[First setObject:], -[Second setObject:]. No signature candidate is available.")
    }

    func testCategoryDuplicatingClassIMPIsAmbiguous() throws {
        let store = makeStore(classes: [objcClass("Widget")], categories: [category()])
        let matches = try ambiguousMatches(in: store)
        XCTAssertEqual(matches.map(\.owner), [owner("Widget"), categoryOwner()])
        XCTAssertEqual(matches.map(\.displayName), ["-[Widget setObject:]", "-[Widget(Extras) setObject:]"])
    }

    func testClassAndInstanceSidesSharingIMPAreAmbiguous() throws {
        var widget = objcClass("Widget")
        widget.classMethods = [method(isClassMethod: true)]
        let store = makeStore(classes: [widget])
        let matches = try ambiguousMatches(in: store)
        XCTAssertEqual(matches.map(\.owner), [owner("Widget", isClassMethod: true), owner("Widget")])
        XCTAssertEqual(matches.map(\.displayName), ["+[Widget setObject:]", "-[Widget setObject:]"])
    }

    func testProtocolDeclarationsNeverOwnAnIMP() throws {
        let declaration = ObjCProtocol(name: "Declaration", address: address + 0x2000,
            adoptedProtocols: [], requiredMethods: [method()], optionalMethods: [method(isClassMethod: true)], properties: [])
        let store = makeStore(classes: [], protocols: [declaration])
        XCTAssertEqual(store.objcMethod(at: address, in: .primary), .none)
        XCTAssertNil(store.objcSignatureCandidateContext(at: address, in: .primary))
        XCTAssertTrue(store.objcSignatureCandidates(at: address, in: .primary).isEmpty)
        XCTAssertNil(store.objcMethod(at: address, in: .primary).ambiguityEvidence)
        store.snapshot.analysisBySlot[.primary]?.objcClasses = [objcClass("Widget")]
        guard case .unique(let match) = store.objcMethod(at: address, in: .primary) else {
            return XCTFail("Protocol declarations must not compete with implementations")
        }
        XCTAssertEqual(match.owner, owner("Widget"))
    }

    func testUniqueCategoryRetainsBaseNameAndClassSide() throws {
        let store = makeStore(classes: [], categories: [category(isClassMethod: true)])
        guard case .unique(let match) = store.objcMethod(at: address, in: .primary) else {
            return XCTFail("Expected a unique category owner")
        }
        XCTAssertEqual(match.owner, categoryOwner(isClassMethod: true))
        XCTAssertEqual(match.displayName, "+[Widget(Extras) setObject:]")
        XCTAssertTrue(match.method.isClassMethod)
        let candidate = try XCTUnwrap(store.objcSignatureCandidates(at: address, in: .primary).first)
        XCTAssertEqual(candidate.context.methodOwner, match.owner)
        XCTAssertTrue(candidate.isClassMethod)
        XCTAssertTrue(candidate.canAccept)
    }

    func testUniqueMethodPreservesCandidateFieldsAndEvidence() throws {
        let store = makeStore(classes: [objcClass("Widget")])
        let candidate = try XCTUnwrap(store.objcSignatureCandidates(at: address, in: .primary).first)
        XCTAssertEqual(candidate.context.methodOwner, owner("Widget"))
        XCTAssertEqual(candidate.displayName, "-setObject:")
        XCTAssertEqual(candidate.returnField.type, "void")
        XCTAssertEqual(candidate.returnField.source, .metadata)
        XCTAssertEqual(candidate.parameters.map(\.field.type), ["id"])
        XCTAssertEqual(candidate.parameters.map(\.field.source), [.metadata])
        XCTAssertEqual(candidate.parameters.map(\.name), ["arg0"])
        XCTAssertTrue(candidate.diagnostics.isEmpty)
        XCTAssertTrue(candidate.canAccept)
        XCTAssertEqual(candidate.evidence, [
            .init(id: "sdk", kind: "Declaration", source: "SDK", detail: "SDK declarations: no trusted source"),
            .init(id: "dwarf", kind: "Declaration", source: "DWARF", detail: "No qualified declaration for this image and slice"),
            .init(id: "calls", kind: "Observation", source: "Structured MacIR", detail: "No matching call-site evidence in the bounded caller set"),
        ])
        XCTAssertNil(ObjCSignatureCandidateService.validateCurrentContext(candidate, current: candidate.context))
    }

    func testChangedOwnerRefusesApplyAndPreviouslyAppliedSave() throws {
        let replacements: [(classes: [ObjCClass], categories: [ObjCCategory])] = [
            ([objcClass("Replacement")], []),
            ([], [category()]),
            ([], [category(name: "Other")]),
            ([], [category(className: "OtherBase")]),
        ]
        for replacement in replacements {
            let store = makeStore(classes: [objcClass("Widget")])
            store.beginSignatureEditAtSelection()
            let original = try XCTUnwrap(store.signatureEditorRequest)
            var draft = original
            var acceptedDraft = original
            let candidate = try XCTUnwrap(original.objcCandidates.first)
            store.applyObjCSignatureCandidate(candidate, to: &acceptedDraft)
            XCTAssertEqual(acceptedDraft.appliedObjCCandidateContext, candidate.context)
            store.snapshot.analysisBySlot[.primary]?.objcClasses = replacement.classes
            store.snapshot.analysisBySlot[.primary]?.objcCategories = replacement.categories
            let current = try XCTUnwrap(store.objcSignatureCandidateContext(at: address, in: .primary))
            var expected = candidate.context
            expected.methodOwner = current.methodOwner
            XCTAssertEqual(ObjCSignatureCandidateService.validateCurrentContext(candidate, current: expected)?.code, "stale-context",
                           "Owner changes alone must invalidate a candidate, even without a new analysis generation")
            expected.analysisGeneration = current.analysisGeneration
            XCTAssertEqual(current, expected)
            XCTAssertNotEqual(current.methodOwner, candidate.context.methodOwner)
            XCTAssertEqual(ObjCSignatureCandidateService.validateCurrentContext(candidate, current: current)?.code, "stale-context")
            store.applyObjCSignatureCandidate(candidate, to: &draft)
            XCTAssertEqual(draft, original)
            store.commitSignatureEditor(acceptedDraft)
            XCTAssertNil(store.snapshot.addressOverrides[.primary(address)]?.signature)
        }
    }

    func testCategoryNameAndBaseChangesInvalidateContext() throws {
        let store = makeStore(classes: [], categories: [category()])
        let candidate = try XCTUnwrap(store.objcSignatureCandidates(at: address, in: .primary).first)
        for replacement in [category(name: "Other"), category(className: "OtherBase")] {
            store.snapshot.analysisBySlot[.primary]?.objcCategories = [replacement]
            let current = try XCTUnwrap(store.objcSignatureCandidateContext(at: address, in: .primary))
            XCTAssertNotEqual(current.methodOwner, candidate.context.methodOwner)
            XCTAssertEqual(ObjCSignatureCandidateService.validateCurrentContext(candidate, current: current)?.code, "stale-context")
        }
    }

    func testOldSnapshotDecodesAndOwnerlessCandidateRequiresRequalification() throws {
        let source = makeStore(classes: [objcClass("Widget")])
        // The package format predates method ownership; candidate contexts are never persisted.
        let encoded = try JSONEncoder().encode(WorkspacePackageAnalysis(snapshot: source.snapshot))
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("methodOwner"))
        XCTAssertFalse(text.contains("objcCandidates"))
        let decoded = try JSONDecoder().decode(WorkspacePackageAnalysis.self, from: encoded)
        let snapshot = decoded.snapshot(binaries: source.snapshot.binaries, hexBytes: source.snapshot.hexBytes)
        XCTAssertEqual(snapshot.functions, source.snapshot.functions)
        let store = WorkspaceStore(workspaceName: "Reopened", snapshot: snapshot,
                                   engine: AnalysisEngine(), autosaveScheduler: nil)
        store.selectInstruction(address)
        XCTAssertNil(store.objcSignatureCandidateContext(at: address, in: .primary))
        XCTAssertTrue(store.objcSignatureCandidates(at: address, in: .primary).isEmpty)
        // Reopening does not persist Objective-C analysis; fresh container metadata qualifies it.
        store.snapshot.analysisBySlot[.primary]?.objcClasses = [objcClass("Widget")]
        store.beginSignatureEditAtSelection()
        var draft = try XCTUnwrap(store.signatureEditorRequest)
        let qualified = try XCTUnwrap(draft.objcCandidates.first)
        var legacy = qualified
        legacy.context.methodOwner = nil
        XCTAssertEqual(ObjCSignatureCandidateService.validateCurrentContext(legacy, current: legacy.context)?.code, "stale-context")
        // Admit the legacy proposal to the presentation to exercise the owner fence itself.
        store.signatureEditorRequest?.objcCandidates = [legacy]
        draft.objcCandidates = [legacy]
        let original = draft
        store.applyObjCSignatureCandidate(legacy, to: &draft)
        XCTAssertEqual(draft, original)
        XCTAssertNil(store.snapshot.addressOverrides[.primary(address)]?.signature)
        let recomputed = try XCTUnwrap(store.objcSignatureCandidates(at: address, in: .primary).first)
        XCTAssertEqual(recomputed.context.methodOwner, owner("Widget"))
        store.signatureEditorRequest?.objcCandidates = [recomputed]
        store.applyObjCSignatureCandidate(recomputed, to: &draft)
        XCTAssertEqual(draft.appliedObjCCandidateContext, recomputed.context)
        XCTAssertEqual(draft.returnType, "void")
        XCTAssertEqual(draft.args.map(\.type), ["id"])
    }

    func testRepeatedIdenticalTupleRemainsUnique() throws {
        var widget = objcClass("Widget")
        widget.instanceMethods.append(method())
        let store = makeStore(classes: [widget, widget])
        guard case .unique(let match) = store.objcMethod(at: address, in: .primary) else {
            return XCTFail("Repeated records of one tuple must not invent an owner")
        }
        XCTAssertEqual(match.owner, owner("Widget"))
        XCTAssertEqual(match.method, method())
    }

    func testDifferentSelectorsSharingAnOwnerAndIMPRemainAmbiguous() throws {
        var widget = objcClass("Widget")
        var second = method()
        second.selector = "setValue:"
        widget.instanceMethods.append(second)
        let store = makeStore(classes: [widget])
        let matches = try ambiguousMatches(in: store)
        XCTAssertEqual(matches.map(\.displayName), ["-[Widget setObject:]", "-[Widget setValue:]"])
    }

    private func ambiguousMatches(in store: WorkspaceStore) throws -> [ObjCMethodOwnerLookup.Match] {
        guard case .ambiguous(let matches) = store.objcMethod(at: address, in: .primary) else {
            XCTFail("Expected ambiguous owners")
            return []
        }
        XCTAssertNil(store.objcSignatureCandidateContext(at: address, in: .primary))
        XCTAssertTrue(store.objcSignatureCandidates(at: address, in: .primary).isEmpty)
        return matches
    }

    private func owner(_ name: String, isClassMethod: Bool = false) -> ObjCMethodOwner {
        .init(container: .objcClass(name: name), isClassMethod: isClassMethod)
    }

    private func categoryOwner(isClassMethod: Bool = false) -> ObjCMethodOwner {
        .init(container: .category(name: "Extras", className: "Widget"), isClassMethod: isClassMethod)
    }

    private func method(imp: UInt64? = nil, isClassMethod: Bool = false) -> ObjCMethod {
        .init(selector: "setObject:", typeEncoding: "v24@0:8@16",
              isClassMethod: isClassMethod, implementation: imp ?? address)
    }

    private func objcClass(_ name: String, imp: UInt64? = nil) -> ObjCClass {
        .init(name: name, superclassName: "NSObject", adoptedProtocols: [],
              classMethods: [], instanceMethods: [method(imp: imp)], ivars: [], properties: [])
    }

    private func category(name: String = "Extras", className: String = "Widget", isClassMethod: Bool = false) -> ObjCCategory {
        .init(name: name, className: className,
              classMethods: isClassMethod ? [method(isClassMethod: true)] : [],
              instanceMethods: isClassMethod ? [] : [method()], adoptedProtocols: [], properties: [])
    }

    private func makeStore(
        classes: [ObjCClass], categories: [ObjCCategory] = [], protocols: [ObjCProtocol] = []
    ) -> WorkspaceStore {
        var analysis = ImageAnalysis()
        analysis.instructions = [.init(address: address, bytes: "c0 03 5f d6", mnemonic: "ret",
                                       operands: "", hasBreakpoint: false, comment: nil)]
        // This display name is deliberately not an ownership source.
        analysis.functions = [.init(id: UUID(), name: "unrelated_display_name", startAddress: address,
                                   endAddress: address + 8, confidence: 1)]
        analysis.objcClasses = classes
        analysis.objcCategories = categories
        analysis.objcProtocols = protocols
        let binary = BinaryImage(id: UUID(), name: "Widget", path: "/tmp/Widget", kind: "Mach-O", architecture: "arm64",
                                 metadata: .init(uuid: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", platformName: "macOS",
                                                 minimumOSVersion: "27.0", sdkVersion: "27.2"))
        let store = WorkspaceStore(workspaceName: "Method owners", snapshot: .init(binaries: [binary],
                                    analysisBySlot: [.primary: analysis]), engine: AnalysisEngine(), autosaveScheduler: nil)
        store.selectInstruction(address)
        return store
    }
}
