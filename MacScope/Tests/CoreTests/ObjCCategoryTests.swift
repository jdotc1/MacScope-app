import Foundation
import XCTest
@testable import MacScope

/// Recovering Objective-C categories from `__objc_catlist`. Categories on a class defined in the SAME
/// image are merged into the class at link time, so `__objc_catlist` carries categories on EXTERNAL
/// classes — extending a system class like NSString — which is the interesting reverse-engineering
/// case. `category_t.cls` is null but BOUND to `_OBJC_CLASS_$_NSString`, resolved the same way an
/// external superclass is. Real-binary oracle: a tiny clang ObjC binary with a category.
final class ObjCCategoryTests: XCTestCase {

    func testRecoversCategoryOnExternalClass() throws {
        let url = try RealCategoryBinary.build()
        let snapshot = try AnalysisEngine().analyze(url: url)

        let category = snapshot.objcCategories.first { $0.name == "MacScope" }
        let cat = try XCTUnwrap(category, "category 'MacScope' on NSString must be recovered from __objc_catlist")
        XCTAssertEqual(cat.className, "NSString", "the category's target class comes from the _OBJC_CLASS_$_ bind")
        XCTAssertTrue(cat.instanceMethods.contains { $0.selector == "msTag" },
                      "the category's instance method must be recovered")

        // The header export must emit `@interface NSString (MacScope)`.
        let header = ObjectiveCHeaderRenderer.render(classes: snapshot.objcClasses, categories: snapshot.objcCategories)
        XCTAssertTrue(header.contains("@interface NSString (MacScope)"),
                      "the rendered header must declare the category. Got:\n\(header)")
    }
}

/// Compiles a tiny arm64 ObjC binary that adds a category to the external class NSString. Skipped if
/// xcrun / the Foundation SDK is unavailable.
private enum RealCategoryBinary {
    static func build() throws -> URL {
        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        guard FileManager.default.isExecutableFile(atPath: xcrun.path) else {
            throw XCTSkip("xcrun unavailable on this host")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-objccat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("c.m")
        try """
        #import <Foundation/Foundation.h>
        @interface NSString (MacScope)
        - (int)msTag;
        @end
        @implementation NSString (MacScope)
        - (int)msTag { return 7; }
        @end
        int main(void){ return 0; }
        """.write(to: source, atomically: true, encoding: .utf8)

        let binary = dir.appendingPathComponent("c")
        let process = Process()
        process.executableURL = xcrun
        process.arguments = ["clang", "-arch", "arm64", "-fobjc-arc", "-framework", "Foundation",
                             "-o", binary.path, source.path]
        let pipe = Pipe(); process.standardError = pipe; process.standardOutput = pipe
        try process.run()
        let drain = CoreTestPipeDrain(pipe)
        process.waitUntilExit()
        let output = drain.text()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: binary.path) else {
            throw XCTSkip("could not build the ObjC category fixture: " + output)
        }
        return binary
    }
}
