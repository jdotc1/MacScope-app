import XCTest
@testable import MacScope

final class NoReturnCatalogTests: XCTestCase {
    func testCanonicalNameStripsUnderscoresImportPrefixesAndSuffixes() {
        XCTAssertEqual(NoReturnCatalog.canonicalName(for: "___stack_chk_fail"), "stack_chk_fail")
        XCTAssertEqual(NoReturnCatalog.canonicalName(for: "imp___stubs__abort"), "abort")
        XCTAssertEqual(NoReturnCatalog.canonicalName(for: "j___cxa_throw"), "cxa_throw")
        XCTAssertEqual(NoReturnCatalog.canonicalName(for: "__exit"), "exit")
        XCTAssertEqual(NoReturnCatalog.canonicalName(for: "longjmp@PLT"), "longjmp")
        XCTAssertEqual(NoReturnCatalog.canonicalName(for: "_$ss12_unreachableyySbF"), "$ss12_unreachableyySbF")
    }

    func testHeaderConfirmedCFamilyMatchesMachOSpellings() {
        for symbol in ["_abort", "_exit", "__exit", "__Exit", "_quick_exit", "_err", "_errx",
                       "_verr", "_verrx", "___assert_rtn", "_pthread_exit", "_siglongjmp"] {
            let entry = NoReturnCatalog.entry(for: symbol)
            XCTAssertNotNil(entry, symbol)
            XCTAssertEqual(entry?.provenance, .appleSDKHeader, symbol)
        }
    }

    func testRuntimeFamilies() {
        XCTAssertEqual(NoReturnCatalog.entry(for: "_objc_exception_throw")?.family, .objcRuntime)
        XCTAssertEqual(NoReturnCatalog.entry(for: "___cxa_throw")?.family, .cxxRuntime)
        XCTAssertEqual(NoReturnCatalog.entry(for: "__ZSt9terminatev")?.family, .cxxRuntime)
        XCTAssertEqual(NoReturnCatalog.entry(for: "_dispatch_main")?.family, .dispatchXPC)
        XCTAssertEqual(NoReturnCatalog.entry(for: "_swift_unexpectedError")?.family, .swiftRuntime)
        let fatalError = "_$ss10fatalError_4file4lines5NeverOSSyXK_s12StaticStringVSutF"
        XCTAssertEqual(NoReturnCatalog.entry(for: fatalError)?.family, .swiftStdlib)
        XCTAssertEqual(NoReturnCatalog.entry(for: fatalError)?.provenance, .swiftCoreNeverExport)
    }

    func testExtendedReferenceEntriesCanBeExcluded() {
        XCTAssertEqual(NoReturnCatalog.entry(for: "___stack_chk_fail")?.provenance, .extendedReference)
        XCTAssertTrue(NoReturnCatalog.isNoReturn("___stack_chk_fail"))
        XCTAssertFalse(NoReturnCatalog.isNoReturn("___stack_chk_fail", includingExtendedReference: false))
        XCTAssertTrue(NoReturnCatalog.isNoReturn("_abort", includingExtendedReference: false))
    }

    func testDeliberateExclusionsAndOrdinaryFunctions() {
        for symbol in ["_objc_enumerationMutation", "_abort_with_reason", "_ExitProcess",
                       "_CxxThrowException", "_printf", "_malloc", "_objc_msgSend", "_swift_retain"] {
            XCTAssertFalse(NoReturnCatalog.isNoReturn(symbol), symbol)
        }
    }

    func testCatalogHasUniqueCanonicalNamesAndNoUnderscorePrefixedKeys() {
        let names = NoReturnCatalog.entries.map(\.canonicalName)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertFalse(names.contains { $0.hasPrefix("_") })
        XCTAssertTrue(names.allSatisfy { NoReturnCatalog.canonicalName(for: $0) == $0 })
    }
}
