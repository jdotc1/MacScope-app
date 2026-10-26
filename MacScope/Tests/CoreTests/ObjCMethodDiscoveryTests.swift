import Foundation
import XCTest
@testable import MacScope

/// Metadata-seeded discovery: an Objective-C method that is never the target of a static call must
/// still be recovered as a function via its IMP in the method metadata. The fixture is linked with
/// `-Wl,-no_function_starts`, so `LC_FUNCTION_STARTS` is absent — the ObjC method seed is the ONLY
/// path by which the un-called `computeValue` can become a discovered function.
final class ObjCMethodDiscoveryTests: XCTestCase {

    func testUncalledObjCMethodIsDiscoveredFromItsImp() throws {
        let url = try RealObjCBinary.build()
        let snapshot = try AnalysisEngine().analyze(url: url)

        let widget = snapshot.objcClasses.first { $0.name == "Widget" }
        let method = widget?.instanceMethods.first { $0.selector == "computeValue" }
        let imp = try XCTUnwrap(method?.implementation, "the computeValue IMP was not recovered")

        XCTAssertTrue(
            snapshot.functions.contains { $0.startAddress == imp },
            "the un-called ObjC method at \(String(imp, radix: 16)) must be discovered from its metadata IMP"
        )
    }
}

/// Compiles a tiny ARM64 Objective-C binary whose `Widget` class declares a method that `main` never
/// sends — and links it WITHOUT `LC_FUNCTION_STARTS`, so the method is reachable only through the
/// ObjC metadata. Skipped if `xcrun clang` / the Foundation SDK is unavailable.
private enum RealObjCBinary {
    static func build() throws -> URL {
        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        guard FileManager.default.isExecutableFile(atPath: xcrun.path) else {
            throw XCTSkip("xcrun unavailable on this host")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-objcdisc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("w.m")
        try """
        #import <Foundation/Foundation.h>
        @interface Widget : NSObject
        - (int)computeValue;
        @end
        @implementation Widget
        - (int)computeValue { return 42 * 7 + 1; }
        @end
        int main(void){ Widget *w = [Widget new]; (void)w; return 0; }
        """.write(to: source, atomically: true, encoding: .utf8)

        let binary = dir.appendingPathComponent("w")
        let process = Process()
        process.executableURL = xcrun
        process.arguments = [
            "clang", "-arch", "arm64", "-fobjc-arc", "-framework", "Foundation",
            "-Wl,-no_function_starts", "-o", binary.path, source.path,
        ]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        let drain = CoreTestPipeDrain(pipe)
        process.waitUntilExit()
        let out = drain.text()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: binary.path) else {
            throw XCTSkip("could not build the Objective-C fixture on this host: \(out)")
        }
        return binary
    }
}
