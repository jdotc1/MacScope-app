import XCTest
@testable import MacScope

final class StaticRuleCatalogTests: XCTestCase {
    func testGroundedTargetActionMutationHints() {
        let fact = VerifiedAPICallFact(declaringClass: "NSControl", selector: "setAction:",
                                        isClassMethod: false, typeDeclarationOrigin: "SDK-pinned")
        XCTAssertEqual(StaticAppKitRuleCatalog.hint(for: fact), .actionMutation)
    }

    func testSameSelectorOnUnrelatedClassNeverGetsAppKitHint() {
        let unrelated = VerifiedAPICallFact(declaringClass: "MyUnrelatedType", selector: "setAction:",
                                             isClassMethod: false, typeDeclarationOrigin: "SDK-pinned")
        XCTAssertNil(StaticAppKitRuleCatalog.hint(for: unrelated))
    }

    func testNoTypeProvenanceOrClassMethodRefuses() {
        XCTAssertNil(StaticAppKitRuleCatalog.hint(for: .init(
            declaringClass: "NSControl", selector: "setAction:",
            isClassMethod: false, typeDeclarationOrigin: "")))
        XCTAssertNil(StaticAppKitRuleCatalog.hint(for: .init(
            declaringClass: "NSControl", selector: "setAction:",
            isClassMethod: true, typeDeclarationOrigin: "SDK-pinned")))
    }
}
