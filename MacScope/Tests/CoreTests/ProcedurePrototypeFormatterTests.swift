import Foundation
import Dispatch
import Darwin
import Synchronization
import XCTest
@testable import MacScope

final class ProcedurePrototypeFormatterTests: XCTestCase {
    func testRecoveryRendersOnDedicatedLargeStackThread() async throws {
        let request = try XCTUnwrap(ProcedureSignatureRecoveryRequest(
            slot: .primary,
            functions: [function(name: "probe", startAddress: 0x1000, endAddress: 0x1004)],
            instructions: [instruction(0x1000, "ret")],
            selectedAddress: 0x1000,
            addressOverrides: [:]
        ))
        let stackSize = Mutex<Int>(0)
        _ = await ProcedureSignatureRecoveryWorker.recover(request) { _ in
            stackSize.withLock { $0 = pthread_get_stacksize_np(pthread_self()) }
            return nil
        }
        XCTAssertGreaterThanOrEqual(stackSize.withLock { $0 }, 8 * 1_024 * 1_024)
    }

    func testRecoveryRequestIsSlotAwareBoundedAndExcludesDataOverrides() throws {
        let selectedFunction = function(
            name: "probe",
            startAddress: 0x1000,
            endAddress: 0x1010
        )
        let otherFunction = function(
            name: "other",
            startAddress: 0x2000,
            endAddress: 0x2010
        )
        let rows = [
            instruction(0x0ffc, "nop"),
            instruction(0x1000, "add", "x0, x0, #0x1"),
            instruction(0x1004, "mov", "x1, x1"),
            instruction(0x1008, "ret"),
            instruction(0x2000, "ret"),
        ]

        let request = try XCTUnwrap(
            ProcedureSignatureRecoveryRequest(
                slot: ImageSlot(rawValue: 7),
                functions: [selectedFunction, otherFunction],
                instructions: rows,
                selectedAddress: 0x1004,
                addressOverrides: [0x1004: AddressOverride(isData: true)]
            )
        )

        XCTAssertEqual(request.slot, ImageSlot(rawValue: 7))
        XCTAssertEqual(request.functionStartAddress, 0x1000)
        XCTAssertEqual(request.instructions.map(\.address), [0x1000, 0x1008])
        let otherSlotRequest = try XCTUnwrap(
            ProcedureSignatureRecoveryRequest(
                slot: ImageSlot(rawValue: 8),
                functions: [selectedFunction, otherFunction],
                instructions: rows,
                selectedAddress: 0x1004,
                addressOverrides: [0x1004: AddressOverride(isData: true)]
            )
        )
        XCTAssertNotEqual(
            request,
            otherSlotRequest,
            "the focused image slot must participate in the task and stale-result key"
        )
    }

    func testCancellingRecoveryParentCancelsDetachedWorker() async throws {
        let selectedFunction = function(
            name: "probe",
            startAddress: 0x1000,
            endAddress: 0x1004
        )
        let request = try XCTUnwrap(
            ProcedureSignatureRecoveryRequest(
                slot: .primary,
                functions: [selectedFunction],
                instructions: [instruction(0x1000, "ret")],
                selectedAddress: 0x1000,
                addressOverrides: [:]
            )
        )
        let started = DispatchSemaphore(value: 0)
        let cancelled = DispatchSemaphore(value: 0)
        let parent = Task {
            await ProcedureSignatureRecoveryWorker.recover(request) { _ in
                started.signal()
                while !Task.isCancelled {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                cancelled.signal()
                return nil
            }
        }

        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        parent.cancel()
        XCTAssertEqual(cancelled.wait(timeout: .now() + 1), .success)
        _ = await parent.value
    }

    func testRecoveredContextFlowsThroughReadingWithoutOverridingAuthoredAuthority() throws {
        let selectedFunction = function(
            name: "probe",
            startAddress: 0x1000,
            endAddress: 0x1010
        )
        let rows = [
            instruction(0x1000, "add", "x0, x0, #0x1"),
            instruction(0x1004, "ret"),
        ]
        let request = try XCTUnwrap(
            ProcedureSignatureRecoveryRequest(
                slot: .primary,
                functions: [selectedFunction],
                instructions: rows,
                selectedAddress: 0x1000,
                addressOverrides: [:]
            )
        )
        let recovered = try XCTUnwrap(request.recoverSignature())

        XCTAssertEqual(
            reading(
                function: selectedFunction,
                instructions: rows,
                recovered: recovered
            ).signatureText,
            "int64_t probe(int64_t arg0)"
        )
        XCTAssertEqual(
            reading(
                function: selectedFunction,
                instructions: rows,
                signatureOverride: FunctionSignatureOverride(returnType: "BOOL"),
                recovered: recovered
            ).signatureText,
            "BOOL probe(int64_t arg0)"
        )
        XCTAssertEqual(
            reading(
                function: selectedFunction,
                instructions: rows,
                signatureOverride: FunctionSignatureOverride(isNoReturn: true),
                recovered: recovered
            ).signatureText,
            "noreturn int64_t probe(int64_t arg0)"
        )
        XCTAssertEqual(
            reading(
                function: selectedFunction,
                instructions: rows,
                signatureOverride: .authoritative(args: []),
                recovered: recovered
            ).signatureText,
            "int64_t probe(void)"
        )
        XCTAssertEqual(
            reading(
                function: selectedFunction,
                instructions: rows,
                signatureOverride: FunctionSignatureOverride(
                    quarantinedLegacyArgs: [
                        LegacyArgOverride(
                            originalIndex: 3,
                            originalOrder: 0,
                            name: "ambiguous",
                            type: "double"
                        )
                    ]
                ),
                recovered: recovered
            ).signatureText,
            "int64_t probe(int64_t arg0)"
        )
    }

    func testExplicitEmptyParameterListRendersVoid() {
        let signature = FunctionSignatureOverride.authoritative(
            returnType: "int",
            args: []
        )

        XCTAssertEqual(
            ProcedurePrototypeFormatter.text(
                name: "probe",
                override: signature,
                recovered: nil
            ),
            "int probe(void)"
        )
    }

    func testAuthoritativeRowsRenderInArrayOrderWithVariadicTail() {
        let signature = FunctionSignatureOverride.authoritative(
            returnType: "size_t",
            args: [
                ArgOverride(rowToken: "first", name: "ratio", type: "double"),
                ArgOverride(rowToken: "second", name: "buffer", type: "void *"),
            ],
            variadicState: .variadic
        )

        XCTAssertEqual(
            ProcedurePrototypeFormatter.text(
                name: "consume",
                override: signature,
                recovered: nil
            ),
            "size_t consume(double ratio, void * buffer, ...)"
        )
    }

    func testUnspecifiedParameterListUsesRecoveredRows() {
        let recovered = FunctionSignatureOverride.authoritative(
            returnType: "int64_t",
            args: [ArgOverride(rowToken: "recovered", name: "value", type: "uint32_t")]
        )
        let returnOnlyOverride = FunctionSignatureOverride(returnType: "BOOL")

        XCTAssertEqual(
            ProcedurePrototypeFormatter.text(
                name: "accept",
                override: returnOnlyOverride,
                recovered: recovered
            ),
            "BOOL accept(uint32_t value)"
        )
    }

    func testUnspecifiedParameterListWithoutRecoveryContextOmitsPrototype() {
        let returnOnlyOverride = FunctionSignatureOverride(returnType: "BOOL")

        XCTAssertNil(
            ProcedurePrototypeFormatter.text(
                name: "accept",
                override: returnOnlyOverride,
                recovered: nil
            )
        )
    }

    func testQuarantineAloneDoesNotFabricatePrototype() {
        let quarantined = FunctionSignatureOverride(
            quarantinedLegacyArgs: [
                LegacyArgOverride(
                    originalIndex: 4,
                    originalOrder: 0,
                    name: "mystery",
                    type: "double"
                )
            ]
        )

        XCTAssertNil(
            ProcedurePrototypeFormatter.text(
                name: "legacy",
                override: quarantined,
                recovered: nil
            )
        )
    }

    private func reading(
        function: FunctionSummary,
        instructions: [InstructionRow],
        signatureOverride: FunctionSignatureOverride? = nil,
        recovered: FunctionSignatureOverride
    ) -> ProcedureInspectorReading {
        let overrides = signatureOverride.map { [function.startAddress: AddressOverride(signature: $0)] } ?? [:]
        return ProcedureInspectorReading(
            functions: [function],
            basicBlocks: [],
            callEdges: [],
            instructions: instructions,
            selectedAddress: function.startAddress,
            addressOverrides: overrides,
            recoveredSignatures: [function.startAddress: recovered]
        )
    }

    private func function(
        name: String,
        startAddress: UInt64,
        endAddress: UInt64
    ) -> FunctionSummary {
        FunctionSummary(
            id: UUID(),
            name: name,
            startAddress: startAddress,
            endAddress: endAddress,
            confidence: 1
        )
    }

    private func instruction(
        _ address: UInt64,
        _ mnemonic: String,
        _ operands: String = ""
    ) -> InstructionRow {
        InstructionRow(
            address: address,
            bytes: "",
            mnemonic: mnemonic,
            operands: operands,
            hasBreakpoint: false,
            comment: nil
        )
    }
}
