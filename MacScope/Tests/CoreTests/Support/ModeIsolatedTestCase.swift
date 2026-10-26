import Foundation


#if canImport(XCTest) && (canImport(MacScope) || canImport(RenderAll)) && !NATIVE_DECOMPILER_XPC_CLIENT_FOCUSED_MAIN
import XCTest
import MacScopeTestSupport
#if canImport(MacScope)
@testable import MacScope
#if canImport(MacScopeAnalysisCore)
import MacScopeAnalysisCore
#endif
#elseif canImport(RenderAll)
@testable import RenderAll
#endif

/// All test cases in each importing test module resolve this local alias. The
/// immutable baseline is installed before XCTest schedules the test body;
/// async/detached work does not depend on inheriting an invocation task-local.
class ModeIsolatedTestCase: PlatformXCTestCase {
    override func invokeTest() {
        let environment = ProcessInfo.processInfo.environment
        let installed = MacIRConfiguration.installTestBaseline(.init(
            ssa: environment["MACSCOPE_SSA_LIFTER"] == "1",
            explicitCFG: environment["MACSCOPE_EXPLICIT_CFG"] == "1",
            returnContract: environment["MACSCOPE_RETURN_CONTRACT_TABLE"] == "1"))
        guard installed else {
            XCTFail("A different immutable test mode baseline was already installed")
            return
        }
        #if canImport(MacScope)
        DSThemeStore.installNonpersistingTestSharedStore()
        #endif
        super.invokeTest()
    }
}

typealias XCTestCase = ModeIsolatedTestCase
#endif
