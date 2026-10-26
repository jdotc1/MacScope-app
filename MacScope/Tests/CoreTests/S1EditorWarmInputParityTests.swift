import Foundation
import XCTest
@testable import MacScope

/// Exercises the real Editor entry, not a replacement printer or extracted helper.
/// Linux cannot claim these tests execute when the actual AppKit closure is absent.
@MainActor
final class S1EditorWarmInputParityTests: XCTestCase {
    private func analyze(_ bodies: [UInt64: (String, [UInt32])], exported: Set<String>) throws -> WorkspaceSnapshot {
        let bytes = S1RecoveryMachOFixture.make(bodies: bodies, exported: exported)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("s1-editor-\(UUID().uuidString).dylib")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = try AnalysisEngine().analyze(url: url)
        XCTAssertEqual(snapshot.analysis(in: .primary)?.imageBytes, bytes)
        return snapshot
    }

    func testWarmHeaderSlotInputMatchesActualExportEntry() throws {
        var snapshot = try analyze([0x1000: ("dispatch", [0xf9400008, 0xd63f0100, 0xd65f03c0])], exported: ["dispatch"])
        let prepared = HeaderImportCore.prepare(
            source: "struct Ops { void (*run)(struct Ops *ops); }; void dispatch(struct Ops *ops);",
            typeDefinitions: snapshot.typeDefinitions,
            exports: snapshot.analysis(in: .primary)?.exports ?? [],
            functions: snapshot.analysis(in: .primary)?.functions ?? [],
            importedPrototypes: snapshot.importedPrototypes, slot: .primary)
        snapshot.typeDefinitions = prepared.types
        snapshot.importedPrototypes = prepared.prototypes
        snapshot.recordHeaderImportEvidence(prepared.headerLayoutDefinitions)
        XCTAssertNotNil(snapshot.imageWideIndirectCalls(in: .primary, compute: true))
        let input = snapshot.pseudocodeRenderInput(selectedAddress: 0x1000, in: .primary)
        XCTAssertFalse(input.slotCallContracts.isEmpty, "The test must supply real proven warm contracts")
        let exported = DocumentExportService().pseudocodeText(for: input, options: .default)
        XCTAssertEqual(PseudocodeView.document(for: input, options: .default).text, exported)
        var refused = input
        refused.slotCallContracts = [:]
        XCTAssertNotEqual(DocumentExportService().pseudocodeText(for: refused, options: .default), exported,
                          "Equality must be sensitive to the omitted slot-contract input")
    }

    func testWarmCallerReturnInputMatchesExportAndColdEditorDoesNotWarm() throws {
        let snapshot = try analyze([
            0x1000: ("caller", [0xa9bf7bfd, 0x94000004, 0xd2800000, 0xa8c17bfd, 0xd65f03c0]),
            0x1014: ("leaf", [0xf9400008, 0xf9000028, 0xd65f03c0])
        ], exported: [])
        let cold = snapshot.pseudocodeRenderInput(selectedAddress: 0x1014, in: .primary)
        XCTAssertNil(cold.callerReturnType)
        XCTAssertNil(snapshot.imageWideIndirectCalls(in: .primary, compute: false))
        _ = PseudocodeView.document(for: cold, options: .default)
        XCTAssertNil(snapshot.imageWideIndirectCalls(in: .primary, compute: false),
                     "The Editor must not initiate synchronous image-wide warming")
        XCTAssertNotNil(snapshot.imageWideIndirectCalls(in: .primary, compute: true))
        let warm = snapshot.pseudocodeRenderInput(selectedAddress: 0x1014, in: .primary)
        XCTAssertEqual(warm.callerReturnType, "void")
        let exported = DocumentExportService().pseudocodeText(for: warm, options: .default)
        XCTAssertEqual(PseudocodeView.document(for: warm, options: .default).text, exported)
        XCTAssertNotEqual(DocumentExportService().pseudocodeText(for: cold, options: .default), exported,
                          "Equality must be sensitive to the omitted return-only input")
    }

    func testWarmSlotOnlyTargetKeepsResultInEditorAndExport() throws {
        for ssa in [false, true] {
            try MacIRConfiguration.$ssaOverride.withValue(ssa) {
                try MacIRConfiguration.$explicitCFGOverride.withValue(ssa) {
                    // BL callback at 0x300c feeds BL install at 0x3010.
                    // The later MOV X0,#0 cannot kill that already consumed result.
                    var snapshot = try analyze([
                        0x1000: ("callback", [0xf9400008, 0xf9000028, 0xd65f03c0]),
                        0x2000: ("install", [0xd2820008, 0xf9000008, 0xd65f03c0]),
                        0x3000: ("caller", [0xa9bf7bfd, 0xd28000e0, 0xd2800121,
                            0x97fff7fd, 0x97fffbfc, 0xd2800000, 0xa8c17bfd, 0xd65f03c0])
                    ], exported: ["install"])
                    let prepared = HeaderImportCore.prepare(
                        source: "struct Slots { void (*run)(void); }; void install(struct Slots *slots);",
                        typeDefinitions: snapshot.typeDefinitions,
                        exports: snapshot.analysis(in: .primary)?.exports ?? [],
                        functions: snapshot.analysis(in: .primary)?.functions ?? [],
                        importedPrototypes: snapshot.importedPrototypes, slot: .primary)
                    snapshot.typeDefinitions = prepared.types
                    snapshot.importedPrototypes = prepared.prototypes
                    snapshot.recordHeaderImportEvidence(prepared.headerLayoutDefinitions)
                    var functions: [MacIRFunction] = []
                    XCTAssertNotNil(snapshot.imageWideIndirectCalls(in: .primary, compute: true,
                        inspectFunctions: { functions = $0 }))
                    XCTAssertEqual(functions.first { $0.startAddress == 0x3000 }?.ssaEnabled, ssa)
                    let input = snapshot.pseudocodeRenderInput(selectedAddress: 0x3000, in: .primary)
                    XCTAssertNil(input.directCallVoidResultTargets["0x1000"])
                    let exported = DocumentExportService().pseudocodeText(for: input, options: .default)
                    XCTAssertEqual(PseudocodeView.document(for: input, options: .default).text, exported)
                    let callee = try XCTUnwrap(snapshot.functions.first { $0.startAddress == 0x1000 }?.name)
                    let installer = try XCTUnwrap(snapshot.functions.first { $0.startAddress == 0x2000 }?.name)
                    XCTAssertTrue(exported.contains("x0_2 = \(callee)(x0_1, x1_1); // call"), exported)
                    XCTAssertTrue(exported.contains("\(installer)(x0_2)"), exported)
                    let callbackInput = snapshot.pseudocodeRenderInput(selectedAddress: 0x1000, in: .primary)
                    XCTAssertNil(callbackInput.signatureOverrides[0x1000])
                }
            }
        }
    }

    func testWarmInstalledHeaderVoidReturnOnlyProjectionControl() throws {
        for ssa in [false, true] {
            try MacIRConfiguration.$ssaOverride.withValue(ssa) {
                try MacIRConfiguration.$explicitCFGOverride.withValue(ssa) {
                    var snapshot = try analyze([
                        0x1000: ("callback", [0xf9400008, 0xf9000028, 0xd65f03c0]),
                        0x2000: ("install", [0xd2820008, 0xf9000008, 0xd65f03c0]),
                        0x3000: ("caller", [0xa9bf7bfd, 0xd28000e0, 0xd2800121,
                            0x97fff7fd, 0x97fffbfc, 0xd2800000, 0xa8c17bfd, 0xd65f03c0])
                    ], exported: ["install", "callback"])
                    let prepared = HeaderImportCore.prepare(
                        source: """
                            struct Slots { void (*run)(void); };
                            void install(struct Slots *slots);
                            void callback(long *input, long *output);
                            """,
                        typeDefinitions: snapshot.typeDefinitions,
                        exports: snapshot.analysis(in: .primary)?.exports ?? [],
                        functions: snapshot.analysis(in: .primary)?.functions ?? [],
                        importedPrototypes: snapshot.importedPrototypes, slot: .primary)
                    snapshot.typeDefinitions = prepared.types
                    snapshot.importedPrototypes = prepared.prototypes
                    snapshot.recordHeaderImportEvidence(prepared.headerLayoutDefinitions)
                    let prototype = try XCTUnwrap(prepared.prototypes[.primary(0x1000)])
                    let declaredReturn = try XCTUnwrap(prototype.returnType)
                    XCTAssertEqual(declaredReturn, "void")
                    XCTAssertNotNil(snapshot.imageWideIndirectCalls(in: .primary, compute: true))
                    var input = snapshot.pseudocodeRenderInput(selectedAddress: 0x3000, in: .primary)
                    let callee = try XCTUnwrap(snapshot.functions.first { $0.startAddress == 0x1000 }?.name)
                    let installer = try XCTUnwrap(snapshot.functions.first { $0.startAddress == 0x2000 }?.name)
                    XCTAssertEqual(input.signatureOverrides[0x1000], prototype)
                    XCTAssertEqual(input.authoredCallSignaturesByTarget[callee], prototype)
                    // Header-derived return-only projection control, NOT end-to-end
                    // scalar header-import parity. The imported declaration stays
                    // intact; only the mutually exclusive full-call map entry is omitted.
                    input.authoredCallSignaturesByTarget.removeValue(forKey: callee)
                    let returnOnly = FunctionSignatureOverride(returnType: declaredReturn)
                    input.directCallVoidResultTargets[callee] = returnOnly
                    input.directCallVoidResultTargets["0x1000"] = returnOnly
                    XCTAssertEqual(input.signatureOverrides[0x1000], prototype)
                    let function = PseudocodePrinter().buildFunction(functionName: input.functionName,
                        startAddress: input.startAddress, signatureOverrides: input.signatureOverrides,
                        authoredCallSignaturesByTarget: input.authoredCallSignaturesByTarget,
                        directCallVoidResultTargets: input.directCallVoidResultTargets,
                        types: input.types, explicitCFGEnabled: ssa, ssaEnabled: ssa,
                        instructions: input.instructions)
                    XCTAssertEqual(function.ssaEnabled, ssa)
                    let call = try XCTUnwrap(function.instructions.first { $0.source.address == 0x300c })
                    guard case let .call(_, result) = call.operation else { return XCTFail("Missing callback call") }
                    XCTAssertNil(result, "Independent void projection must not invent an X0 result")
                    let exported = DocumentExportService().pseudocodeText(for: input, options: .default)
                    XCTAssertEqual(PseudocodeView.document(for: input, options: .default).text, exported)
                    XCTAssertTrue(exported.contains("\(callee)(x0_1, x1_1); // call"), exported)
                    XCTAssertFalse(exported.contains("= \(callee)("), exported)
                    XCTAssertFalse(exported.contains("\(installer)(x0_2)"), exported)
                }
            }
        }
    }
}
