import XCTest
@testable import MacScope

final class RuntimeSignatureSeedsTests: XCTestCase {
    func testSwiftRuntimeSignatureResolvesThroughStandardCatalog() throws {
        let signature = try XCTUnwrap(CallSignatureCatalog.standard.signature(for: "_swift_allocObject"))
        XCTAssertEqual(signature.returnType, "void *")
        XCTAssertEqual(signature.parameters.map(\.register), ["x0", "x1", "x2"])
        XCTAssertEqual(signature.parameters.map(\.type), ["const void *", "size_t", "size_t"])
        XCTAssertEqual(signature.source, "known-import")
    }

    func testRuntimeSeedsNeverShadowSeedsOrCorpus() {
        let earlier = Set(CallSignatureCatalog.seeds.map(\.canonicalName))
            .union(CallSignatureCorpus.all.map(\.canonicalName))
        let names = RuntimeSignatureSeeds.all.map(\.canonicalName)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(earlier.isDisjoint(with: names))
        // The migrated seed keeps winning.
        XCTAssertEqual(CallSignatureCatalog.standard.signature(for: "_swift_retain")?.returnType, "void *")
    }

    func testSwiftRuntimeEntriesAreSwiftNamedAndSDKSized() {
        let names = RuntimeSignatureSeeds.swiftRuntime.map(\.canonicalName)
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("swift_") })
        XCTAssertEqual(names.count, 160)
        XCTAssertFalse(RuntimeSignatureSeeds.swiftRuntime.contains { $0.isVariadic })
    }

    func testObjCRegisterHelpersBindTheNamedRegister() throws {
        let retain = try XCTUnwrap(RuntimeSignatureSeeds.objcRegisterHelper(for: "_objc_retain_x19"))
        XCTAssertEqual(retain.operation, .retain)
        XCTAssertEqual(retain.objectRegister, "x19")
        XCTAssertEqual(retain.returnType, "id")
        let release = try XCTUnwrap(RuntimeSignatureSeeds.objcRegisterHelper(for: "objc_release_x8"))
        XCTAssertEqual(release.operation, .release)
        XCTAssertEqual(release.objectRegister, "x8")
        XCTAssertEqual(release.returnType, "void")
    }

    func testOnlyX0HelpersAreOrdinaryCatalogSignatures() throws {
        // xN (N > 0) must never be bound as an ordinary x0-argument call.
        XCTAssertNil(CallSignatureCatalog.standard.signature(for: "_objc_retain_x19"))
        XCTAssertNil(CallSignatureCatalog.standard.signature(for: "_objc_release_x1"))
        let x0 = try XCTUnwrap(CallSignatureCatalog.standard.signature(for: "_objc_retain_x0"))
        XCTAssertEqual(x0.parameters.map(\.register), ["x0"])
    }

    func testHelperRegisterSetMatchesLibobjcExports() {
        XCTAssertEqual(RuntimeSignatureSeeds.objcHelperRegisters, Array(0...15) + Array(19...28))
        XCTAssertEqual(RuntimeSignatureSeeds.objcRegisterHelpers.count, 52)
        for missing in ["_objc_retain_x16", "_objc_retain_x17", "_objc_retain_x18", "_objc_release_x29"] {
            XCTAssertNil(RuntimeSignatureSeeds.objcRegisterHelper(for: missing), missing)
        }
        XCTAssertNil(RuntimeSignatureSeeds.objcRegisterHelper(for: "_objc_retain"))
    }
}
