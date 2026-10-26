import Foundation
import XCTest
@testable import MacScope

final class SlotReturnAuthorityTests: XCTestCase {
    private typealias Operation = (String, String)
    private let target: UInt64 = 0x1000
    private let installer: UInt64 = 0x2000
    private let caller: UInt64 = 0x3000

    private var header: String {
        """
        struct Slots { void (*first)(void); void (*second)(void); };
        void install(struct Slots *slots);
        """
    }

    private var targetBody: [Operation] {
        [("ldr", "x8, [x0]"), ("str", "x8, [x1]"), ("ret", "")]
    }

    private var installBody: [Operation] {
        [("mov", "x8, #0x1000"), ("str", "x8, [x0]"), ("ret", "")]
    }

    private func rows(_ start: UInt64, _ operations: [Operation]) -> [InstructionRow] {
        operations.enumerated().map { index, operation in
            InstructionRow(address: start + UInt64(index * 4), bytes: "", mnemonic: operation.0,
                           operands: operation.1, hasBreakpoint: false, comment: nil)
        }
    }

    private func snapshot(header declarations: String? = nil, install operations: [Operation]? = nil,
                          target body: [Operation]? = nil, caller calls: [Operation] = []) -> WorkspaceSnapshot {
        let parsed = CTypeHeaderParser.parse(declarations ?? header)
        var analysis = ImageAnalysis()
        let bodies: [(UInt64, String, [Operation])] = [
            (target, "callback", body ?? targetBody),
            (installer, "install", operations ?? installBody)
        ] + (calls.isEmpty ? [] : [(caller, "caller", calls)])
        for (start, name, instructions) in bodies {
            analysis.functions.append(FunctionSummary(id: UUID(), name: name, startAddress: start,
                endAddress: start + UInt64(instructions.count * 4), confidence: 1))
            analysis.instructions += rows(start, instructions)
        }
        var value = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        value.insertImage(binary: BinaryImage(id: UUID(), name: "slot-return-fixture", path: "/tmp/slot-return-fixture",
            kind: "executable", architecture: "arm64", slot: .primary), analysis: analysis)
        value.typeDefinitions = parsed.types
        for prototype in parsed.prototypes {
            if let function = analysis.functions.first(where: { $0.name == prototype.name }) {
                value.importedPrototypes[.primary(function.startAddress)] = prototype.signature
            }
        }
        return value
    }

    @discardableResult
    private func warm(_ value: WorkspaceSnapshot, file: StaticString = #filePath,
                      line: UInt = #line) -> [MacIRFunction] {
        var functions: [MacIRFunction] = []
        XCTAssertNotNil(value.imageWideIndirectCalls(in: .primary, compute: true,
            inspectFunctions: { functions = $0 }), file: file, line: line)
        return functions
    }

    private func render(_ value: WorkspaceSnapshot, at address: UInt64 = 0x1000) -> String {
        PseudocodeView.document(for: value.pseudocodeRenderInput(selectedAddress: address, in: .primary),
                                options: .default).text
    }

    private func authority(_ value: WorkspaceSnapshot) -> FunctionSignatureOverride? {
        value.pseudocodeRenderInput(selectedAddress: target, in: .primary).signatureOverrides[target]
    }

    // A slot declaration describes the caller's ABI, never the stored target's
    // own declaration. Retain the old scenarios as refusal regressions.
    private func assertNoSlotAuthority(_ value: WorkspaceSnapshot, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(authority(value), file: file, line: line)
        let text = render(value)
        XCTAssertTrue(text.contains("unresolved_return_contract"), text, file: file, line: line)
    }

    func testTypedParameterSlotDoesNotEstablishOwnReturnOrParameters() {
        let value = snapshot()
        let before = render(value)
        XCTAssertTrue(before.contains("return unresolved_return_contract;"), before)
        XCTAssertNil(authority(value))
        warm(value)
        assertNoSlotAuthority(value)
        let after = render(value)
        let declarationParameters = #"callback\(([^\n]*)\)"#
        let beforeRange = before.range(of: declarationParameters, options: .regularExpression)
        let afterRange = after.range(of: declarationParameters, options: .regularExpression)
        XCTAssertNotNil(beforeRange, before)
        XCTAssertNotNil(afterRange, after)
        if let beforeRange, let afterRange {
            XCTAssertEqual(String(before[beforeRange]), String(after[afterRange]))
        }
        XCTAssertNil(value.functionSignatureOverrides(in: .primary)[target])
        XCTAssertNil(value.authoredCallSignaturesByTarget(in: .primary)["callback"])
    }

    func testRegisteredAllocationSlotDoesNotEstablishOwnReturn() {
        let value = snapshot(header: """
            struct PublicSlots { void (*start)(void); };
            struct Controller { struct PublicSlots pub; long private_state; };
            struct Owner { struct Controller *controller; };
            void install(struct Owner *owner);
            """, install: [
                ("mov", "x19, x0"), ("bl", "0x4000"), ("str", "x0, [x19]"),
                ("mov", "x8, #0x1000"), ("str", "x8, [x0]"), ("ret", "")
            ])
        warm(value)
        assertNoSlotAuthority(value)
    }

    func testNestedTypedPointerStoreDoesNotEstablishOwnReturn() {
        let value = snapshot(header: """
            struct Slots { void (*first)(void); };
            struct Owner { long pad; struct Slots *slots; };
            void install(struct Owner *owner);
            """, install: [
                ("ldr", "x9, [x0, #8]"), ("mov", "x8, #0x1000"),
                ("b", "0x200c"), ("str", "x8, [x9]"), ("ret", "")
            ])
        warm(value)
        assertNoSlotAuthority(value)
    }

    func testConflictingSlotReturnTypesRefuseAuthority() {
        let value = snapshot(header: """
            struct Slots { void (*first)(void); int (*second)(void); };
            void install(struct Slots *slots);
            """, install: [
                ("mov", "x8, #0x1000"), ("str", "x8, [x0]"),
                ("str", "x8, [x0, #8]"), ("ret", "")
            ])
        let before = render(value)
        warm(value)
        XCTAssertNil(authority(value))
        XCTAssertEqual(render(value), before)
    }

    func testUntypedLiteralStoreVetoesTypedStore() {
        let value = snapshot(install: [
            ("mov", "x8, #0x1000"), ("str", "x8, [x0]"),
            ("str", "x8, [x1]"), ("ret", "")
        ])
        let before = render(value)
        warm(value)
        XCTAssertNil(authority(value))
        XCTAssertEqual(render(value), before)
    }

    func testEscapingLiteralCallArgumentVetoesTypedStore() {
        let value = snapshot(install: [
            ("mov", "x8, #0x1000"), ("str", "x8, [x0]"),
            ("mov", "x0, x8"), ("bl", "0x4000"), ("mov", "x0, #0"), ("ret", "")
        ])
        let before = render(value)
        warm(value)
        XCTAssertNil(authority(value))
        XCTAssertEqual(render(value), before)
    }

    func testAuthoredAndImportedTargetSignaturesKeepPrecedence() {
        for authored in [false, true] {
            var value = snapshot(header: header + "\nlong callback(long *input, long *output);")
            if authored {
                value.importedPrototypes.removeValue(forKey: .primary(target))
                value.addressOverrides[.primary(target)] = AddressOverride(signature:
                    FunctionSignatureOverride(returnType: "uint64_t", args: [
                        ArgOverride(index: 0, name: "input", type: "uint64_t *"),
                        ArgOverride(index: 1, name: "output", type: "uint64_t *")
                    ]))
            }
            let before = render(value)
            let signature = authority(value)
            warm(value)
            XCTAssertEqual(authority(value), signature)
            XCTAssertEqual(render(value), before)
        }
    }

    func testPositiveCallerReturnWidthVetoesVoidAuthority() {
        let value = snapshot(caller: [
            ("bl", "0x1000"), ("ldr", "x9, [x0]"), ("mov", "x0, #0"), ("ret", "")
        ])
        warm(value)
        XCTAssertNil(authority(value))
        let text = render(value)
        XCTAssertTrue(text.contains("return arg0;"), text)
        XCTAssertFalse(text.contains("return;"), text)
    }

    func testAgreeingNonVoidSlotsDoNotDeclareTarget() {
        let value = snapshot(header: """
            struct Slots { long (*first)(void); long (*second)(void); };
            void install(struct Slots *slots);
            """, install: [
                ("mov", "x8, #0x1000"), ("str", "x8, [x0]"),
                ("str", "x8, [x0, #8]"), ("ret", "")
            ], target: [("mov", "x0, #7"), ("ret", "")])
        let before = render(value)
        let functions = warm(value)
        let report = MacIRSlotReturnAuthority.collect(functions: functions, types: value.typeDefinitions,
            signatures: value.functionSignatureOverrides(in: .primary), callerReturns: [:])
        XCTAssertNil(report.returnTypes[target])
        XCTAssertNil(authority(value))
        XCTAssertEqual(render(value), before)
        XCTAssertTrue(before.contains("return "), before)
        XCTAssertFalse(before.contains("return;"), before)
        XCTAssertTrue(before.contains("unresolved_return_contract"), before)
    }

    func testSlotOnlyStoreDoesNotRemoveDirectCallResult() {
        for ssa in [false, true] {
            MacIRConfiguration.$ssaOverride.withValue(ssa) {
                MacIRConfiguration.$explicitCFGOverride.withValue(ssa) {
                    // The second call consumes X0 before its later overwrite.
                    // A killed result permits legacy dead-result elision and
                    // cannot distinguish that projection from a void contract.
                    let value = snapshot(caller: [
                        ("stp", "x29, x30, [sp, #-16]!"),
                        ("bl", "0x1000"), ("bl", "0x2000"),
                        ("mov", "x0, #0"),
                        ("ldp", "x29, x30, [sp], #16"), ("ret", "")
                    ])
                    let functions = warm(value)
                    XCTAssertEqual(functions.first { $0.startAddress == caller }?.ssaEnabled, ssa)
                    let input = value.pseudocodeRenderInput(selectedAddress: caller, in: .primary)
                    XCTAssertNil(input.signatureOverrides[target])
                    XCTAssertNil(input.authoredCallSignaturesByTarget["callback"])
                    XCTAssertNil(input.directCallVoidResultTargets["callback"])
                    XCTAssertNil(input.directCallVoidResultTargets["0x1000"])
                    // The new consumer may supply independent caller-use evidence;
                    // unresolved-own-return is no longer the fixture invariant.
                    // Slot-only evidence must still never erase this live result.
                    let after = render(value, at: caller)
                    XCTAssertTrue(after.contains("x0_1 = callback(); // call"), after)
                    XCTAssertTrue(after.contains("install(x0_1)"), after)
                }
            }
        }
    }

    func testInstalledHeaderVoidReturnOnlyProjectionControl() throws {
        for ssa in [false, true] {
            try MacIRConfiguration.$ssaOverride.withValue(ssa) {
                try MacIRConfiguration.$explicitCFGOverride.withValue(ssa) {
                    let value = snapshot(header: header + "\nvoid callback(void);", caller: [
                        ("stp", "x29, x30, [sp, #-16]!"),
                        ("bl", "0x1000"), ("bl", "0x2000"),
                        ("mov", "x0, #0"),
                        ("ldp", "x29, x30, [sp], #16"), ("ret", "")
                    ])
                    let prototype = try XCTUnwrap(value.importedPrototypes[.primary(target)])
                    let declaredReturn = try XCTUnwrap(prototype.returnType)
                    XCTAssertEqual(declaredReturn, "void")
                    warm(value)
                    var input = value.pseudocodeRenderInput(selectedAddress: caller, in: .primary)
                    XCTAssertEqual(input.signatureOverrides[target], prototype)
                    XCTAssertEqual(input.authoredCallSignaturesByTarget["callback"], prototype)
                    // Header-derived return-only projection control, NOT end-to-end
                    // scalar header-import parity. That separate lowering gap is
                    // documented: a full authored entry blocks this existing API.
                    input.authoredCallSignaturesByTarget.removeValue(forKey: "callback")
                    let returnOnly = FunctionSignatureOverride(returnType: declaredReturn)
                    input.directCallVoidResultTargets["callback"] = returnOnly
                    input.directCallVoidResultTargets["0x1000"] = returnOnly
                    XCTAssertEqual(input.signatureOverrides[target], prototype)
                    let function = PseudocodePrinter().buildFunction(functionName: input.functionName,
                        startAddress: input.startAddress, signatureOverrides: input.signatureOverrides,
                        authoredCallSignaturesByTarget: input.authoredCallSignaturesByTarget,
                        directCallVoidResultTargets: input.directCallVoidResultTargets,
                        types: input.types, explicitCFGEnabled: ssa, ssaEnabled: ssa,
                        instructions: input.instructions)
                    XCTAssertEqual(function.ssaEnabled, ssa)
                    let call = try XCTUnwrap(function.instructions.first { $0.source.address == 0x3004 })
                    guard case let .call(_, result) = call.operation else { return XCTFail("Missing callback call") }
                    XCTAssertNil(result, "Independent void projection must not invent an X0 result")
                    let text = PseudocodeView.document(for: input, options: .default).text
                    XCTAssertTrue(text.contains("callback(); // call"), text)
                    XCTAssertFalse(text.contains("= callback("), text)
                    // The following call may have an unavailable argument. Do not
                    // turn the void callback's clobbered X0 into a returned value.
                    XCTAssertFalse(text.contains("install(x0_1)"), text)
                }
            }
        }
    }

    func testSlotOnlyStorePreservesUnknownCallReturn() {
        let value = snapshot(target: [("bl", "0x4000"), ("ret", "")])
        let beforeInput = value.pseudocodeRenderInput(selectedAddress: target, in: .primary)
        let before = render(value)
        XCTAssertTrue(before.contains("return unresolved_return_contract;"), before)
        let built = warm(value)
        assertNoSlotAuthority(value)
        let after = render(value)
        XCTAssertEqual(after, before)
        let afterInput = value.pseudocodeRenderInput(selectedAddress: target, in: .primary)
        XCTAssertEqual(beforeInput.authoredCallSignaturesByTarget, afterInput.authoredCallSignaturesByTarget)
        let afterFunction = PseudocodePrinter().buildFunction(functionName: "callback", startAddress: target,
            signatureOverrides: afterInput.signatureOverrides, instructions: afterInput.instructions)
        let calls: (MacIRFunction) -> [MacIROperation] = { function in
            function.instructions.compactMap { instruction in
                if case .call = instruction.operation { return instruction.operation }
                return nil
            }
        }
        if let original = built.first(where: { $0.startAddress == target }) {
            XCTAssertEqual(calls(original), calls(afterFunction))
        } else { XCTFail("Missing callback IR") }
        XCTAssertTrue(after.split(separator: "\n").contains { $0.contains(" = ") && $0.contains("// call") }, after)
        XCTAssertFalse(after.split(separator: "\n").contains { $0.contains("return ") && $0.contains("// call") }, after)
    }

    func testTrailingUnionDoesNotMakeSlotOwnAuthority() {
        let value = snapshot(header: """
            struct Slots { void (*first)(void); union { long integer; void *pointer; } trailing; };
            void install(struct Slots *slots);
            """)
        warm(value)
        assertNoSlotAuthority(value)
    }

    func testMissingHeaderCallbackMetadataRefusesAuthority() {
        var value = snapshot()
        for typeIndex in value.typeDefinitions.indices {
            for fieldIndex in value.typeDefinitions[typeIndex].fields.indices {
                value.typeDefinitions[typeIndex].fields[fieldIndex].functionPointerSignatureV1 = nil
            }
        }
        let before = render(value)
        warm(value)
        XCTAssertNil(authority(value))
        XCTAssertEqual(render(value), before)
    }

    func testNarrowAndFullWidthPairStoresBothRefuseOwnAuthority() {
        let narrow = snapshot(install: [("mov", "x8, #0x1000"), ("str", "w8, [x0]"), ("ret", "")])
        warm(narrow)
        XCTAssertNil(authority(narrow))
        let pair = snapshot(install: [
            ("mov", "x8, #0x1000"), ("mov", "x9, #0x1000"),
            ("stp", "x8, x9, [x0]"), ("ret", "")
        ])
        warm(pair)
        assertNoSlotAuthority(pair)
    }

    func testRedefinedAllocationCarrierDoesNotInheritOwnerFieldType() {
        let value = snapshot(header: """
            struct Slots { void (*first)(void); };
            struct Owner { struct Slots *slots; };
            void install(struct Owner *owner, void *untyped);
            """, install: [
                ("mov", "x19, x0"), ("bl", "0x4000"), ("str", "x0, [x19]"),
                ("mov", "x0, x20"), ("mov", "x8, #0x1000"), ("str", "x8, [x0]"), ("ret", "")
            ])
        warm(value)
        XCTAssertNil(authority(value))
    }
    func testAmbiguousRegistrationInvalidatesDerivedObjectType() {
        let value = snapshot(header: """
            struct Slots { void (*run)(void); };
            struct A { struct Slots *slots; };
            struct B { long unrelated; };
            struct Owner { struct A *a; struct B *b; };
            void install(struct Owner *owner);
            """, install: [
                ("mov", "x19, x0"), ("bl", "0x4000"), ("mov", "x20, x0"),
                ("str", "x20, [x19]"), ("bl", "0x4000"), ("str", "x0, [x20]"),
                ("str", "x20, [x19, #8]"), ("mov", "x8, #0x1000"),
                ("str", "x8, [x0]"), ("mov", "x0, #0"), ("ret", "")
            ])
        warm(value)
        XCTAssertNil(authority(value))
    }

    func testNonDeclarationLayoutInPrecedingNestedMemberRefusesAuthority() {
        var value = snapshot(header: """
            struct Prefix { long padding; };
            struct Slots { struct Prefix prefix; void (*run)(void); };
            void install(struct Slots *slots);
            """, install: [("mov", "x8, #0x1000"), ("str", "x8, [x0, #8]"), ("ret", "")])
        for index in value.typeDefinitions.indices where value.typeDefinitions[index].name == "Prefix" {
            value.typeDefinitions[index].fields[0].byteOffset = 16
        }
        warm(value)
        XCTAssertNil(authority(value))
    }

    func testNonzeroNestedSlotOffsetRequiresExactChildAlignment() {
        var value = snapshot(header: """
            struct Tail { long padding; };
            struct Child { void (*run)(void); struct Tail tail; };
            struct Slots { long preceding; struct Child child; };
            void install(struct Slots *slots);
            """, install: [("mov", "x8, #0x1000"), ("str", "x8, [x0, #8]"), ("ret", "")])
        for index in value.typeDefinitions.indices where value.typeDefinitions[index].name == "Tail" {
            value.typeDefinitions[index].fields[0].byteOffset = 16
        }
        warm(value)
        XCTAssertNil(authority(value))
    }

    func testAlignmentTypeDependencyRequiresDeclarationLayout() {
        var value = snapshot(header: """
            struct Alignment { long padding; };
            struct Slots { void (*run)(void); };
            void install(struct Slots *slots);
            """)
        for index in value.typeDefinitions.indices {
            if value.typeDefinitions[index].name == "Alignment" {
                value.typeDefinitions[index].fields[0].byteOffset = 16
            } else if value.typeDefinitions[index].name == "Slots" {
                value.typeDefinitions[index].fields[0].minimumAlignmentType = "Alignment"
            }
        }
        warm(value)
        XCTAssertNil(authority(value))
    }

    func testLoadedFunctionPointerCarrierIsNotAnObjectPointer() {
        let value = snapshot(header: """
            struct Slots { void (*run)(void); };
            struct Owner { struct Slots *(*factory)(void); };
            void install(struct Owner *owner);
            """, install: [("ldr", "x9, [x0]"), ("mov", "x8, #0x1000"),
                           ("str", "x8, [x9]"), ("ret", "")])
        warm(value)
        XCTAssertNil(authority(value))
    }

    func testIndirectAllocationSlotStillRefusesOwnAuthority() {
        let value = snapshot(header: """
            typedef enum { MODE_FIRST, MODE_SECOND } Mode;
            struct Memory { void *(*allocate)(void *, int, long); };
            struct PublicSlots { void (*start)(void); };
            struct Controller { struct PublicSlots pub; long private_state; };
            struct Owner { struct Memory *mem; Mode mode; char padding[508]; struct Controller *controller; };
            void install(struct Owner *owner);
            """, install: [
                ("mov", "x19, x0"), ("ldr", "x8, [x0]"), ("ldr", "x8, [x8]"),
                ("mov", "w1, #1"), ("mov", "w2, #0xd0"), ("blr", "x8"),
                ("movi", "v0.2d, #0"), ("stp", "q0, q0, [x0]"),
                ("stp", "q0, q0, [x0, #0x20]"), ("str", "x0, [x19, #0x208]"),
                ("adrp", "x8, 0x1000"), ("add", "x8, x8, #0"),
                ("str", "x8, [x0]"), ("ret", "")
            ])
        warm(value)
        assertNoSlotAuthority(value)
    }

    func testAllocationRegisteredIntoConflictingOwnerFieldsAfterEnumRefuses() {
        let value = snapshot(header: """
            typedef enum { MODE_FIRST, MODE_SECOND } Mode;
            struct VoidSlots { void (*run)(void); };
            struct ValueSlots { long (*run)(void); };
            struct Owner { Mode mode; struct VoidSlots *first; struct ValueSlots *second; };
            void install(struct Owner *owner);
            """, install: [
                ("mov", "x19, x0"), ("blr", "x8"), ("str", "x0, [x19, #8]"),
                ("str", "x0, [x19, #16]"), ("mov", "x8, #0x1000"),
                ("str", "x8, [x0]"), ("ret", "")
            ])
        let before = render(value)
        warm(value)
        XCTAssertNil(authority(value))
        XCTAssertEqual(render(value), before)
    }

    func testAllocationMergedAcrossBranchDoesNotAcquireOwnerType() {
        let value = snapshot(header: """
            typedef enum { MODE_FIRST, MODE_SECOND } Mode;
            struct Slots { void (*run)(void); };
            struct Owner { Mode mode; struct Slots *slots; };
            void install(struct Owner *owner, int choose);
            """, install: [
                ("mov", "x19, x0"), ("cbz", "w1, 0x2014"),
                ("blr", "x8"), ("mov", "x20, x0"), ("b", "0x201c"),
                ("blr", "x9"), ("mov", "x20, x0"), ("str", "x20, [x19, #8]"),
                ("mov", "x8, #0x1000"), ("str", "x8, [x20]"), ("ret", "")
            ])
        let before = render(value)
        warm(value)
        XCTAssertNil(authority(value))
        XCTAssertEqual(render(value), before)
    }

    func testSlotBeforeRegistrationOfDifferentAllocationDoesNotAcquireType() {
        let value = snapshot(header: """
            typedef enum { MODE_FIRST, MODE_SECOND } Mode;
            struct Slots { void (*run)(void); };
            struct Owner { Mode mode; struct Slots *slots; };
            void install(struct Owner *owner);
            """, install: [
                ("mov", "x19, x0"), ("blr", "x8"), ("mov", "x9, #0x1000"),
                ("str", "x9, [x0]"), ("blr", "x8"), ("str", "x0, [x19, #8]"), ("ret", "")
            ])
        let before = render(value)
        warm(value)
        XCTAssertNil(authority(value))
        XCTAssertEqual(render(value), before)
    }

    func testAllocationStoredIntoUntypedOwnerFieldDoesNotAcquireType() {
        let value = snapshot(header: """
            typedef enum { MODE_FIRST, MODE_SECOND } Mode;
            struct Owner { Mode mode; void *slots; };
            void install(struct Owner *owner);
            """, install: [
                ("mov", "x19, x0"), ("blr", "x8"), ("str", "x0, [x19, #8]"),
                ("mov", "x8, #0x1000"), ("str", "x8, [x0]"), ("ret", "")
            ])
        let before = render(value)
        warm(value)
        XCTAssertNil(authority(value))
        XCTAssertEqual(render(value), before)
    }

    func testIncompleteOrExplicitLayoutEnumPrefixStillRefusesRegistration() {
        for explicitLayout in [false, true] {
            var value = snapshot(header: """
                typedef enum { MODE_FIRST, MODE_SECOND } Mode;
                struct Slots { void (*run)(void); };
                struct Owner { Mode mode; struct Slots *slots; };
                void install(struct Owner *owner);
                """, install: [
                    ("mov", "x19, x0"), ("blr", "x8"), ("str", "x0, [x19, #8]"),
                    ("mov", "x8, #0x1000"), ("str", "x8, [x0]"), ("ret", "")
                ])
            for index in value.typeDefinitions.indices where value.typeDefinitions[index].name == "Mode" {
                if explicitLayout {
                    value.typeDefinitions[index].fields[0].byteOffset = 16
                } else {
                    value.typeDefinitions[index].enumValuesIncomplete = true
                }
            }
            warm(value)
            XCTAssertNil(authority(value))
        }
    }


    func testSlotSignatureDoesNotSeedInstallerRoot() {
        let value = snapshot(header: """
            struct S { void (*method)(void); };
            struct Roots { void (*install)(struct S *); };
            void caller(struct Roots *roots);
            """, caller: [
                ("mov", "x8, #0x2000"), ("str", "x8, [x0]"), ("ret", "")
            ])
        let before = render(value, at: installer)
        let functions = warm(value)
        assertNoSlotAuthority(value)
        let after = render(value, at: installer)
        let pattern = #"install\(([^\n]*)\)"#
        let beforeRange = before.range(of: pattern, options: .regularExpression)
        let afterRange = after.range(of: pattern, options: .regularExpression)
        XCTAssertNotNil(beforeRange, before)
        XCTAssertNotNil(afterRange, after)
        if let beforeRange, let afterRange {
            XCTAssertEqual(String(before[beforeRange]), String(after[afterRange]))
            XCTAssertTrue(String(after[afterRange]).contains("int64_t"), after)
        }
        let report = MacIRSlotReturnAuthority.collect(functions: functions, types: value.typeDefinitions,
            signatures: value.functionSignatureOverrides(in: .primary), callerReturns: [:])
        let roots = report.parameterRoots.filter { $0.functionStart == installer }
        XCTAssertEqual(roots.count, 0)
        XCTAssertNil(value.authoredCallSignaturesByTarget(in: .primary)["install"])
    }

    func testSlotParameterRootRefusesConflictingParameterTypes() {
        let value = snapshot(header: """
            struct S { void (*method)(void); };
            struct Roots { void (*install)(struct S *); void (*other)(struct Other *); };
            struct Other { long value; };
            void caller(struct Roots *roots);
            """, caller: [
                ("mov", "x8, #0x2000"), ("str", "x8, [x0]"),
                ("str", "x8, [x0, #8]"), ("ret", "")
            ])
        let functions = warm(value)
        XCTAssertNil(authority(value))
        let report = MacIRSlotReturnAuthority.collect(functions: functions, types: value.typeDefinitions,
            signatures: value.functionSignatureOverrides(in: .primary), callerReturns: [:])
        XCTAssertFalse(report.parameterRoots.contains { $0.functionStart == installer })
        XCTAssertNil(report.returnTypes[target])
    }

    func testSlotParameterRootRefusesUntypedAddressStore() {
        let value = snapshot(header: """
            struct S { void (*method)(void); };
            struct Roots { void (*install)(struct S *); };
            void caller(struct Roots *roots);
            """, caller: [
                ("mov", "x8, #0x2000"), ("str", "x8, [x0]"),
                ("str", "x8, [x1]"), ("ret", "")
            ])
        let functions = warm(value)
        XCTAssertNil(authority(value))
        let report = MacIRSlotReturnAuthority.collect(functions: functions, types: value.typeDefinitions,
            signatures: value.functionSignatureOverrides(in: .primary), callerReturns: [:])
        XCTAssertFalse(report.parameterRoots.contains { $0.functionStart == installer })
        XCTAssertNil(report.returnTypes[target])
    }

    func testSlotParameterRootRefusesAddressPassedAsData() {
        let value = snapshot(header: """
            struct S { void (*method)(void); };
            struct Roots { void (*install)(struct S *); };
            void caller(struct Roots *roots);
            """, caller: [
                ("mov", "x8, #0x2000"), ("str", "x8, [x0]"),
                ("mov", "x0, x8"), ("bl", "0x9000"), ("ret", "")
            ])
        let functions = warm(value)
        XCTAssertNil(authority(value))
        let report = MacIRSlotReturnAuthority.collect(functions: functions, types: value.typeDefinitions,
            signatures: value.functionSignatureOverrides(in: .primary), callerReturns: [:])
        XCTAssertFalse(report.parameterRoots.contains { $0.functionStart == installer })
        XCTAssertNil(report.returnTypes[target])
    }

    func testSlotParameterRootRefusesStaticParameterDisagreement() {
        let value = snapshot(header: """
            struct S { void (*method)(void); };
            struct Roots { void (*install)(struct S *); };
            void caller(struct Roots *roots);
            struct Other { long value; };
            void install(struct Other *other);
            """, caller: [
                ("mov", "x8, #0x2000"), ("str", "x8, [x0]"),
                ("ret", "")
            ])
        let functions = warm(value)
        XCTAssertNil(authority(value))
        let report = MacIRSlotReturnAuthority.collect(functions: functions, types: value.typeDefinitions,
            signatures: value.functionSignatureOverrides(in: .primary), callerReturns: [:])
        XCTAssertFalse(report.parameterRoots.contains { $0.functionStart == installer })
        XCTAssertNil(report.returnTypes[target])
    }

    func testSlotParameterRootRefusesUnknownSlotParameters() {
        let value = snapshot(header: """
            struct S { void (*method)(void); };
            struct Roots { void (*install)(struct S *); void (*unknown)(); };
            void caller(struct Roots *roots);
            """, caller: [
                ("mov", "x8, #0x2000"), ("str", "x8, [x0]"),
                ("str", "x8, [x0, #8]"), ("ret", "")
            ])
        let functions = warm(value)
        XCTAssertNil(authority(value))
        let report = MacIRSlotReturnAuthority.collect(functions: functions, types: value.typeDefinitions,
            signatures: value.functionSignatureOverrides(in: .primary), callerReturns: [:])
        XCTAssertFalse(report.parameterRoots.contains { $0.functionStart == installer })
        XCTAssertNil(report.returnTypes[target])
    }

    func testSlotParameterAgreementNeverCreatesOwnRoots() {
        let value = snapshot(header: """
            struct S { void (*method)(void); };
            struct Roots { void (*first)(struct S *); long (*second)(struct S *); };
            void caller(struct Roots *roots);
            """, caller: [
                ("mov", "x8, #0x2000"), ("str", "x8, [x0]"),
                ("str", "x8, [x0, #8]"), ("ret", "")
            ])
        let functions = warm(value)
        assertNoSlotAuthority(value)
        let report = MacIRSlotReturnAuthority.collect(functions: functions, types: value.typeDefinitions,
            signatures: [:], callerReturns: [installer: .x0])
        XCTAssertNil(report.returnTypes[installer])
        XCTAssertNil(report.returnTypes[target])
        XCTAssertFalse(report.parameterRoots.contains { $0.functionStart == installer })
        XCTAssertTrue(report.entries.first { $0.target == installer }?.vetoReasons
            .contains("conflicting slot return types") == true)
        XCTAssertTrue(report.entries.first { $0.target == installer }?.vetoReasons
            .contains("positive caller return evidence conflicts with void") == true)
    }

    func testSlotParameterRootsDoNotPropagateThroughTwoLevels() {
        let parsed = CTypeHeaderParser.parse("""
            struct Leaf { void (*method)(void); };
            struct Middle { void (*install)(struct Leaf *); };
            struct Root { void (*install)(struct Middle *); };
            void bootstrap(struct Root *root);
            """)
        let bodies: [(UInt64, String, [Operation])] = [
            (0x1000, "leaf", targetBody),
            (0x2000, "second", [("mov", "x8, #0x1000"), ("str", "x8, [x0]"), ("ret", "")]),
            (0x3000, "first", [("mov", "x8, #0x2000"), ("str", "x8, [x0]"), ("ret", "")]),
            (0x4000, "bootstrap", [("mov", "x8, #0x3000"), ("str", "x8, [x0]"), ("ret", "")])
        ]
        var analysis = ImageAnalysis()
        for (start, name, operations) in bodies {
            analysis.functions.append(FunctionSummary(id: UUID(), name: name, startAddress: start,
                endAddress: start + UInt64(operations.count * 4), confidence: 1))
            analysis.instructions += rows(start, operations)
        }
        var value = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        value.insertImage(binary: BinaryImage(id: UUID(), name: "slot-root-chain", path: "/tmp/slot-root-chain",
            kind: "executable", architecture: "arm64", slot: .primary), analysis: analysis)
        value.typeDefinitions = parsed.types
        value.importedPrototypes[.primary(0x4000)] = parsed.prototypes.first { $0.name == "bootstrap" }?.signature
        let functions = warm(value)
        assertNoSlotAuthority(value)
        let report = MacIRSlotReturnAuthority.collect(functions: Array(functions.reversed()), types: value.typeDefinitions,
            signatures: value.functionSignatureOverrides(in: .primary), callerReturns: [:])
        XCTAssertEqual(report.parameterRoots.count, 0)
        XCTAssertNil(report.returnTypes[0x1000])
    }
}

extension SlotReturnAuthorityTests {
    private typealias LiteralRow = (String, String, String)

    // Literal instruction inputs, not decoder receipts. Every case exercises
    // both real lifters and both return-table flag settings independently.
    private func withLiteralModes(_ check: (Bool) throws -> Void) rethrows {
        for ssa in [false, true] {
            for contracts in [false, true] {
                try MacIRConfiguration.$ssaOverride.withValue(ssa) {
                    try MacIRConfiguration.$explicitCFGOverride.withValue(ssa) {
                        try MacIRConfiguration.$returnContractOverride.withValue(contracts) { try check(ssa) }
                    }
                }
            }
        }
    }

    private func literalFixture(_ declarations: String, install: [LiteralRow],
                                bootstrap: [LiteralRow]? = nil,
                                body: [LiteralRow] = [("e0 00 80 d2", "mov", "x0, #7"),
                                                     ("c0 03 5f d6", "ret", "")],
                                ssa: Bool) -> (MacIRSlotReturnAuthority.Report, MacIRFunction, [UInt64: FunctionSignatureOverride]) {
        let parsed = CTypeHeaderParser.parse(declarations)
        var bodies: [(UInt64, String, [LiteralRow])] = [(0x1000, "callback", body), (0x2000, "install", install)]
        if let bootstrap { bodies.append((0x3000, "bootstrap", bootstrap)) }
        var signatures: [UInt64: FunctionSignatureOverride] = [:]
        for (start, name, _) in bodies {
            signatures[start] = parsed.prototypes.first { $0.name == name }?.signature
        }
        let functions = bodies.map { start, name, rows in
            PseudocodePrinter().buildFunction(functionName: name, startAddress: start,
                signatureOverrides: signatures, types: parsed.types,
                explicitCFGEnabled: ssa, ssaEnabled: ssa,
                instructions: rows.enumerated().map { index, row in
                    InstructionRow(address: start + UInt64(index * 4), bytes: row.0,
                        mnemonic: row.1, operands: row.2, hasBreakpoint: false, comment: nil)
                })
        }
        for function in functions { XCTAssertEqual(function.ssaEnabled, ssa) }
        let report = MacIRSlotReturnAuthority.collect(functions: functions, types: parsed.types,
            signatures: signatures, callerReturns: [:])
        return (report, functions[0], signatures)
    }

    private var literalInstall: [LiteralRow] {
        [("08 80 ff 10", "adr", "x8, 0x1000"), ("08 00 00 f9", "str", "x8, [x0]"),
         ("c0 03 5f d6", "ret", "")]
    }

    func testLiteralTypedVoidSlotCannotDeclareCastedIntegerTarget() throws {
        try withLiteralModes { ssa in
            let (report, function, _) = literalFixture("""
                struct Slots { void (*method)(void); };
                void install(struct Slots *slots);
                """, install: literalInstall, ssa: ssa)
            let entry = try XCTUnwrap(report.entries.first { $0.target == 0x1000 })
            XCTAssertEqual(entry.stores.count, 1)
            XCTAssertEqual(entry.stores.first?.returnType, "void") // typed base/store actually found
            XCTAssertNil(entry.admittedType)
            XCTAssertEqual(report.returnTypes.count, 0)
            XCTAssertEqual(report.parameterRoots.count, 0)
            XCTAssertEqual(function.returnValue, .unknown("unresolved_return_contract"))
            XCTAssertTrue(entry.vetoReasons.contains("slot observations do not establish own declaration"))
        }
    }

    func testLiteralTypedValueSlotCannotDeclareCastedVoidTarget() throws {
        try withLiteralModes { ssa in
            // A void function may leave x0=7. The slot's int prototype is not its declaration.
            let (report, function, _) = literalFixture("""
                struct Slots { int (*method)(void); };
                void install(struct Slots *slots);
                """, install: literalInstall, ssa: ssa)
            let entry = try XCTUnwrap(report.entries.first { $0.target == 0x1000 })
            XCTAssertEqual(entry.stores.count, 1)
            XCTAssertEqual(entry.stores.first?.returnType, "int32_t")
            XCTAssertNil(entry.admittedType)
            XCTAssertEqual(report.returnTypes.count, 0)
            XCTAssertEqual(function.returnValue, .unknown("unresolved_return_contract"))
        }
    }

    func testLiteralConflictingSecondInstallKeepsRefusalAndDiagnostic() throws {
        try withLiteralModes { ssa in
            let install = Array(literalInstall.dropLast()) + [
                ("08 04 00 f9", "str", "x8, [x0, #8]"), ("c0 03 5f d6", "ret", "")]
            let (report, function, _) = literalFixture("""
                struct Slots { void (*first)(void); int (*second)(void); };
                void install(struct Slots *slots);
                """, install: install, ssa: ssa)
            let entry = try XCTUnwrap(report.entries.first { $0.target == 0x1000 })
            XCTAssertEqual(entry.stores.count, 2)
            XCTAssertTrue(entry.vetoReasons.contains("conflicting slot return types"))
            XCTAssertNil(entry.admittedType)
            XCTAssertEqual(function.returnValue, .unknown("unresolved_return_contract"))
        }
    }

    func testLiteralUnslottedStoreKeepsRefusalAndDiagnostic() throws {
        try withLiteralModes { ssa in
            let install = Array(literalInstall.dropLast()) + [
                ("28 00 00 f9", "str", "x8, [x1]"), ("c0 03 5f d6", "ret", "")]
            let (report, function, _) = literalFixture("""
                struct Slots { void (*method)(void); };
                void install(struct Slots *slots);
                """, install: install, ssa: ssa)
            let entry = try XCTUnwrap(report.entries.first { $0.target == 0x1000 })
            XCTAssertEqual(entry.stores.count, 2)
            XCTAssertTrue(entry.stores.contains { $0.reason != nil })
            XCTAssertNil(entry.admittedType)
            XCTAssertEqual(function.returnValue, .unknown("unresolved_return_contract"))
        }
    }

    func testLiteralIndependentVoidDeclarationSurvivesConflictingSlot() {
        withLiteralModes { ssa in
            let (report, function, signatures) = literalFixture("""
                struct Slots { int (*method)(void); };
                void install(struct Slots *slots);
                void callback(void);
                """, install: literalInstall, ssa: ssa)
            XCTAssertEqual(signatures[0x1000]?.returnType, "void")
            XCTAssertNil(function.returnValue)
            XCTAssertEqual(report.returnTypes.count, 0)
            XCTAssertEqual(report.parameterRoots.count, 0)
        }
    }

    func testLiteralIndependentValueDeclarationSurvivesConflictingSlots() {
        withLiteralModes { ssa in
            let install = Array(literalInstall.dropLast()) + [
                ("08 04 00 f9", "str", "x8, [x0, #8]"), ("c0 03 5f d6", "ret", "")]
            let (report, function, signatures) = literalFixture("""
                struct Slots { void (*first)(void); int (*second)(void); };
                void install(struct Slots *slots);
                uint64_t callback(void);
                """, install: install, ssa: ssa)
            XCTAssertEqual(signatures[0x1000]?.returnType, "uint64_t")
            XCTAssertNotNil(function.returnValue)
            XCTAssertNotEqual(function.returnValue, .unknown("unresolved_return_contract"))
            XCTAssertEqual(report.returnTypes.count, 0)
            XCTAssertEqual(report.parameterRoots.count, 0)
        }
    }

    func testLiteralTypedSlotParameterNeverSeedsInstallerRoot() {
        withLiteralModes { ssa in
            let (report, function, signatures) = literalFixture("""
                struct Slots { void (*method)(void); };
                struct Roots { void (*installer)(struct Slots *); };
                void bootstrap(struct Roots *roots);
                """, install: literalInstall, bootstrap: [
                    ("08 80 ff 10", "adr", "x8, 0x2000"),
                    ("08 00 00 f9", "str", "x8, [x0]"), ("c0 03 5f d6", "ret", "")], ssa: ssa)
            XCTAssertNil(signatures[0x2000])
            XCTAssertEqual(report.entries.first { $0.target == 0x2000 }?.stores.count, 1)
            XCTAssertEqual(report.parameterRoots.count, 0)
            XCTAssertEqual(report.returnTypes.count, 0)
            XCTAssertEqual(function.returnValue, .unknown("unresolved_return_contract"))
        }
    }

    func testLiteralAgreeingTwoSlotsNeverSeedInstallerRoot() {
        withLiteralModes { ssa in
            let (report, function, signatures) = literalFixture("""
                struct Slots { void (*method)(void); };
                struct Roots { void (*first)(struct Slots *); void (*second)(struct Slots *); };
                void bootstrap(struct Roots *roots);
                """, install: literalInstall, bootstrap: [
                    ("08 80 ff 10", "adr", "x8, 0x2000"),
                    ("08 00 00 f9", "str", "x8, [x0]"),
                    ("08 04 00 f9", "str", "x8, [x0, #8]"), ("c0 03 5f d6", "ret", "")], ssa: ssa)
            XCTAssertNil(signatures[0x2000])
            XCTAssertEqual(report.entries.first { $0.target == 0x2000 }?.stores.count, 2)
            XCTAssertEqual(report.parameterRoots.count, 0)
            XCTAssertEqual(report.returnTypes.count, 0)
            XCTAssertEqual(function.returnValue, .unknown("unresolved_return_contract"))
        }
    }

    func testLiteralReversedConflictingSlotsKeepBothObservations() throws {
        try withLiteralModes { ssa in
            let install = Array(literalInstall.dropLast()) + [
                ("08 04 00 f9", "str", "x8, [x0, #8]"), ("c0 03 5f d6", "ret", "")]
            let (report, function, _) = literalFixture("""
                struct Slots { int (*first)(void); void (*second)(void); };
                void install(struct Slots *slots);
                """, install: install, ssa: ssa)
            let entry = try XCTUnwrap(report.entries.first { $0.target == 0x1000 })
            XCTAssertEqual(entry.stores.count, 2)
            XCTAssertTrue(entry.vetoReasons.contains("conflicting slot return types"))
            XCTAssertNil(entry.admittedType)
            XCTAssertEqual(function.returnValue, .unknown("unresolved_return_contract"))
        }
    }

    func testLiteralAddressPassedAsArgumentKeepsEscapeDiagnostic() throws {
        try withLiteralModes { ssa in
            let (report, function, _) = literalFixture("""
                struct Slots { void (*method)(void); };
                void install(struct Slots *slots);
                """, install: [
                    ("fd 7b bf a9", "stp", "x29, x30, [sp, #-16]!"),
                    ("08 00 82 d2", "mov", "x8, #0x1000"),
                    ("08 00 00 f9", "str", "x8, [x0]"),
                    ("e0 03 08 aa", "mov", "x0, x8"),
                    ("fc 07 00 94", "bl", "0x4000"),
                    ("fd 7b c1 a8", "ldp", "x29, x30, [sp], #16"),
                    ("c0 03 5f d6", "ret", "")], ssa: ssa)
            let entry = try XCTUnwrap(report.entries.first { $0.target == 0x1000 })
            XCTAssertTrue(entry.stores.contains { $0.address == 0x2008 && $0.returnType == "void" })
            XCTAssertTrue(entry.vetoReasons.contains("address escape outside a typed callback store"))
            XCTAssertNil(entry.admittedType)
            XCTAssertEqual(report.returnTypes.count, 0)
            XCTAssertEqual(function.returnValue, .unknown("unresolved_return_contract"))
        }
    }
}
