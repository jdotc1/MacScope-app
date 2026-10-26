import XCTest
@testable import MacScope

final class BinarySearchScopeTests: XCTestCase {
    func testSystemImageExclusion() {
        var scope = BinarySearchScope()
        scope.excludesSystemImages = true
        XCTAssertFalse(scope.includes(slot: .primary, path: "/usr/lib/libobjc.A.dylib"))
        XCTAssertFalse(scope.includes(slot: .primary, path: "/System/Library/Frameworks/AppKit.framework/AppKit"))
        XCTAssertTrue(scope.includes(slot: .primary, path: "/Applications/Mail.app/Contents/MacOS/Mail"))
        XCTAssertTrue(BinarySearchScope.everything.includes(slot: .primary, path: "/usr/lib/libobjc.A.dylib"))
    }

    func testStoredFiltersRoundTripAndFallBackSafely() {
        var scope = BinarySearchScope()
        scope.images = .focused
        scope.kinds = [.string, .symbol]
        scope.excludesSystemImages = true
        XCTAssertEqual(BinarySearchScope(encoded: scope.encoded), scope)
        XCTAssertEqual(BinarySearchScope(encoded: "garbage"), .everything)
        XCTAssertEqual(BinarySearchScope(encoded: "all;;0").kinds, Set(BinarySearchResult.Kind.allCases))
    }
}
