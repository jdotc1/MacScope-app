import XCTest

@testable import MacScope

final class NativeDecompilerExactFunctionResolverTests: XCTestCase {
    func testResolvesOneHalfOpenFunctionContainingSelection() throws {
        let function = makeFunction(start: 10, end: 20)
        XCTAssertEqual(resolve(10, [function]), function)
        XCTAssertEqual(resolve(19, [function]), function)
        XCTAssertNil(resolve(20, [function]))
    }

    func testResolvesOneZeroWidthFunctionOnlyAtItsExactStart() throws {
        let function = makeFunction(start: 42, end: 42)
        XCTAssertEqual(resolve(42, [function]), function)
        XCTAssertNil(resolve(41, [function]))
    }

    func testZeroMatchesAbstainsWithoutNearestPrecedingFallback() throws {
        XCTAssertNil(resolve(25, [makeFunction(start: 10, end: 20)]))
    }

    func testMultipleMatchesAbstain() throws {
        XCTAssertNil(resolve(15, [
            makeFunction(start: 10, end: 20),
            makeFunction(start: 15, end: 25),
        ]))
        XCTAssertNil(resolve(42, [
            makeFunction(start: 42, end: 42),
            makeFunction(start: 42, end: 42),
        ]))
    }

    func testMovementWithinSameFunctionCanonicalizesToOneTarget() throws {
        let function = makeFunction(start: UInt64.max - 4, end: UInt64.max)
        XCTAssertEqual(resolve(UInt64.max - 4, [function])?.id, function.id)
        XCTAssertEqual(resolve(UInt64.max - 1, [function])?.id, function.id)
        XCTAssertNil(resolve(UInt64.max, [function]))
    }

    func testInvertedFunctionRangeAbstainsEvenAtItsStart() throws {
        let function = makeFunction(start: 42, end: 41)
        XCTAssertNil(resolve(42, [function]))
    }

    func testFunctionIDResolutionRequiresOneExactIdentity() throws {
        let functionID = UUID()
        let function = makeFunction(id: functionID, start: 10, end: 20)
        XCTAssertEqual(
            NativeDecompilerExactFunctionResolver.resolve(
                functionID: functionID,
                functions: [function]
            ),
            function
        )
        XCTAssertNil(
            NativeDecompilerExactFunctionResolver.resolve(
                functionID: functionID,
                functions: [
                    function,
                    makeFunction(id: functionID, start: 30, end: 40),
                ]
            )
        )
    }

    private func resolve(_ address: UInt64, _ functions: [FunctionSummary]) -> FunctionSummary? {
        NativeDecompilerExactFunctionResolver.resolve(
            selectedAddress: address,
            functions: functions
        )
    }

    private func makeFunction(
        id: UUID = UUID(),
        start: UInt64,
        end: UInt64
    ) -> FunctionSummary {
        FunctionSummary(
            id: id, name: "f", startAddress: start, endAddress: end, confidence: 1
        )
    }
}
