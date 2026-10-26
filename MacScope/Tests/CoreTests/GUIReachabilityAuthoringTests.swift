import XCTest
@testable import MacScope

/// Reachability tests for the W5-B GUI-reachability wave: the previously scripting-only
/// authoring ops (Make Data, Import C Header, Rename Register, Set Local Label, plus
/// Mark as Procedure via the typed router) now have GUI entry points. These assert the
/// WIRING — that the menu/context `begin…` presenters open the right sheet and that the
/// sheet's commit mutates the store — rather than re-testing the underlying setters, which
/// have their own behavior tests. A sheet that opens but commits nothing, or a `begin…`
/// that mutates nothing, would slip through unit tests of the setters alone; these catch it.
@MainActor
final class GUIReachabilityAuthoringTests: XCTestCase {

    /// A store with one function [0x1000, 0x2000) and three decoded instructions, so the
    /// register-rename enclosing-function lookup and selection-keyed ops have data.
    private func makeStore() -> WorkspaceStore {
        let snapshot = WorkspaceSnapshot(
            binaries: [],
            functions: [
                FunctionSummary(id: UUID(), name: "f", startAddress: 0x1000, endAddress: 0x2000, confidence: 1)
            ],
            instructions: [0x1000, 0x1004, 0x1008].map {
                InstructionRow(address: $0, bytes: "1f 20 03 d5", mnemonic: "nop",
                               operands: "", hasBreakpoint: false, comment: nil)
            },
            xrefs: [],
            hexBytes: Data()
        )
        return WorkspaceStore(workspaceName: "Authoring", snapshot: snapshot, engine: AnalysisEngine())
    }

    // MARK: - Distinct notification entry points (no collisions, all observed)

    /// The four sheet-presenting authoring commands + Mark as Procedure each have a distinct
    /// notification name. A collision (or an accidental reuse) would route a command to the
    /// wrong handler; this pins them apart.
    func testAuthoringNotificationNamesAreDistinct() {
        let names: [Notification.Name] = [
            .macScopeMarkAsProcedure,
            .macScopeMakeData,
            .macScopeImportCHeader,
            .macScopeRenameRegister,
            .macScopeSetLocalLabel
        ]
        XCTAssertEqual(Set(names).count, names.count, "Authoring notification names must be unique")
    }

    // MARK: - Set Local Label

    func testBeginLocalLabelOpensSheetAndCommitMutates() throws {
        let store = makeStore()
        store.selectInstruction(0x1004)
        XCTAssertNil(store.overrideEditorRequest)

        store.beginLocalLabelEditAtSelection()
        let request = try XCTUnwrap(store.overrideEditorRequest)
        XCTAssertEqual(request.kind, .localLabel)
        XCTAssertEqual(request.address, 0x1004)

        store.commitOverrideEditor("loop_top")
        XCTAssertNil(store.overrideEditorRequest, "Commit dismisses the sheet")
        XCTAssertEqual(store.snapshot.localLabel(at: 0x1004), "loop_top")
        XCTAssertEqual(
            store.selectedImageAddress,
            ImageAddress(slot: .primary, address: 0x1004),
            "A valid binary-less primary fixture retains its qualified selection after authoring"
        )

        // Re-open + commit empty clears it (the documented clear path).
        store.beginLocalLabelEditAtSelection()
        store.commitOverrideEditor("")
        XCTAssertNil(store.snapshot.localLabel(at: 0x1004))
    }

    func testBeginLocalLabelWithoutSelectionSurfacesHintAndOpensNoSheet() {
        let store = makeStore()
        store.selectedAddress = nil
        store.lastIssue = nil
        store.beginLocalLabelEditAtSelection()
        XCTAssertNil(store.overrideEditorRequest)
        XCTAssertNotNil(store.lastIssue)
    }

    // MARK: - Rename Register

    func testBeginRegisterRenameKeysToEnclosingProcedureAndCommits() throws {
        let store = makeStore()
        store.selectInstruction(0x1008) // inside f [0x1000, 0x2000)
        XCTAssertNil(store.registerRenameRequest)

        // Context-menu path: register pre-filled.
        store.beginRegisterRenameAtSelection(register: "X19")
        let request = try XCTUnwrap(store.registerRenameRequest)
        XCTAssertEqual(request.procedureStart, 0x1000, "Rename keys to the procedure START, not the selection")
        XCTAssertEqual(request.register, "x19", "Register is normalized to lowercase")

        // Commit goes through the store setter, keyed at the procedure start.
        store.renameRegister(procedureStart: 0x1000, register: "x19", name: "counter")
        XCTAssertEqual(store.snapshot.registerNameOverrides(forProcedureAt: 0x1000)["x19"], "counter")
    }

    func testBeginRegisterRenameMenuPathLeavesRegisterEditable() {
        let store = makeStore()
        store.selectInstruction(0x1004)
        store.beginRegisterRenameAtSelection() // menu path: no register
        XCTAssertEqual(store.registerRenameRequest?.register, "")
        XCTAssertEqual(store.registerRenameRequest?.procedureStart, 0x1000)
    }

    func testBeginRegisterRenameOutsideProcedureSurfacesHint() {
        let store = makeStore()
        store.selectedAddress = nil
        store.lastIssue = nil
        store.beginRegisterRenameAtSelection(register: "x0")
        XCTAssertNil(store.registerRenameRequest)
        XCTAssertNotNil(store.lastIssue)
    }

    // MARK: - Make Data (array / string / alignment)

    func testMakeArrayShapeCommitMutates() {
        let store = makeStore()
        store.selectInstruction(0x1000)
        store.beginMakeDataAtSelection()
        var request = try! XCTUnwrap(store.dataShapeEditorRequest)
        request.shape = .array
        request.elementType = "int32_t"
        request.countText = "8"
        XCTAssertTrue(store.commitDataShapeEditor(request))
        XCTAssertNil(store.dataShapeEditorRequest, "Successful commit dismisses the sheet")

        let shape = try! XCTUnwrap(store.snapshot.dataShape(at: 0x1000))
        XCTAssertEqual(shape.kind, .array)
        XCTAssertEqual(shape.elementType, "int32_t")
        XCTAssertEqual(shape.elementCount, 8)
        XCTAssertTrue(store.snapshot.isData(at: 0x1000), "A shaped address is data")
    }

    func testMakeStringFixedLengthCommitMutates() {
        let store = makeStore()
        store.selectInstruction(0x1004)
        var request = DataShapeEditorRequest(address: 0x1004)
        request.shape = .string
        request.isNullTerminated = false
        request.stringLengthText = "12"
        XCTAssertTrue(store.commitDataShapeEditor(request))
        let shape = try! XCTUnwrap(store.snapshot.dataShape(at: 0x1004))
        XCTAssertEqual(shape.kind, .string)
        XCTAssertFalse(shape.isNullTerminated)
        XCTAssertEqual(shape.stringLength, 12)
    }

    func testMakeAlignmentCommitMutates() {
        let store = makeStore()
        store.selectInstruction(0x1008)
        var request = DataShapeEditorRequest(address: 0x1008)
        request.shape = .alignment
        request.boundaryText = "16"
        XCTAssertTrue(store.commitDataShapeEditor(request))
        let shape = try! XCTUnwrap(store.snapshot.dataShape(at: 0x1008))
        XCTAssertEqual(shape.kind, .alignment)
        XCTAssertEqual(shape.alignment, 16)
    }

    func testMakeDataRejectsInvalidNumericEntryAndKeepsSheetOpen() {
        let store = makeStore()
        store.selectInstruction(0x1000)
        var request = DataShapeEditorRequest(address: 0x1000)
        request.shape = .array
        request.countText = "0" // invalid: must be > 0
        store.lastIssue = nil
        XCTAssertFalse(store.commitDataShapeEditor(request))
        XCTAssertNotNil(store.lastIssue, "Invalid entry surfaces an inline reason")
        XCTAssertNil(store.snapshot.dataShape(at: 0x1000), "No garbage shape applied")
    }

    func testMakeStringRejectsOverlongLength() {
        let store = makeStore()
        store.selectInstruction(0x1000)
        var request = DataShapeEditorRequest(address: 0x1000)
        request.shape = .string
        request.isNullTerminated = false
        request.stringLengthText = String(DataShapeOverride.maxStringLength + 1)
        store.lastIssue = nil
        XCTAssertFalse(store.commitDataShapeEditor(request))
        XCTAssertNotNil(store.lastIssue)
        XCTAssertNil(store.snapshot.dataShape(at: 0x1000))
    }

    func testMakeAlignmentRejectsNonBoundary() {
        let store = makeStore()
        store.selectInstruction(0x1000)
        var request = DataShapeEditorRequest(address: 0x1000)
        request.shape = .alignment
        request.boundaryText = "1" // must be > 1
        store.lastIssue = nil
        XCTAssertFalse(store.commitDataShapeEditor(request))
        XCTAssertNotNil(store.lastIssue)
        XCTAssertNil(store.snapshot.dataShape(at: 0x1000))
    }

    func testMakeAlignmentRejectsNonPowerOfTwo() {
        let store = makeStore()
        store.selectInstruction(0x1000)
        for bad in ["3", "5", "6", "7", "12"] {
            var request = DataShapeEditorRequest(address: 0x1000)
            request.shape = .alignment
            request.boundaryText = bad
            store.lastIssue = nil
            XCTAssertFalse(store.commitDataShapeEditor(request), "boundary \(bad) is not a power of two and must be rejected")
            XCTAssertNotNil(store.lastIssue)
            XCTAssertNil(store.snapshot.dataShape(at: 0x1000), "no shape applied for boundary \(bad)")
        }
        var ok = DataShapeEditorRequest(address: 0x1000)
        ok.shape = .alignment
        ok.boundaryText = "8"
        XCTAssertTrue(store.commitDataShapeEditor(ok))
        XCTAssertEqual(store.snapshot.dataShape(at: 0x1000)?.alignment, 8)
    }

    // MARK: - Notification routing (the actual wiring, not just the begin… methods)

    func testRouteAuthoringCommandMapsEachNotificationToTheRightSheet() {
        // Exercises WorkspaceStore.routeAuthoringCommand — the notification→action switch the
        // AuthoringCommandHandlers modifier forwards to. A WRONG name→action mapping (the bug a
        // direct begin… call cannot catch) fails here.
        let store = makeStore()
        store.selectInstruction(0x1004)

        XCTAssertTrue(store.routeAuthoringCommand(.macScopeMakeData))
        XCTAssertNotNil(store.dataShapeEditorRequest, ".macScopeMakeData must open the Make Data sheet")

        XCTAssertTrue(store.routeAuthoringCommand(.macScopeImportCHeader))
        XCTAssertNotNil(store.cHeaderImportRequest, ".macScopeImportCHeader must open the C-header sheet")

        store.selectInstruction(0x1004)
        XCTAssertTrue(store.routeAuthoringCommand(.macScopeRenameRegister, object: "x19"))
        XCTAssertEqual(store.registerRenameRequest?.register, "x19",
                       ".macScopeRenameRegister must open the rename sheet with the passed register")

        XCTAssertTrue(store.routeAuthoringCommand(.macScopeSetLocalLabel))
        XCTAssertEqual(store.overrideEditorRequest?.kind, .localLabel,
                       ".macScopeSetLocalLabel must open a local-label override sheet")
    }

    func testRouteAuthoringCommandIgnoresUnrelatedNotifications() {
        let store = makeStore()
        XCTAssertFalse(store.routeAuthoringCommand(.macScopeNextCode),
                       "a non-authoring notification must not be handled by the authoring router")
    }

    func testRegisterScannerIgnoresRegistersThatAppearOnlyInComments() {
        // A pseudocode line's `// …` annotation can mention registers that are not live operands;
        // offering a rename for them would be misleading.
        XCTAssertEqual(
            PseudocodeRegisterScanner.registers(in: "x0 = fn(x1); // void fn(int64_t x19, int64_t x20)"),
            ["x0", "x1"],
            "registers in the // comment (x19, x20) must not be offered for rename"
        )
    }

    func testBeginMakeDataWithoutSelectionSurfacesHint() {
        let store = makeStore()
        store.selectedAddress = nil
        store.lastIssue = nil
        store.beginMakeDataAtSelection()
        XCTAssertNil(store.dataShapeEditorRequest)
        XCTAssertNotNil(store.lastIssue)
    }

    func testBeginMakeDataPreseedsFromExistingShape() throws {
        let store = makeStore()
        store.selectInstruction(0x1000)
        store.makeArray(0x1000, elementType: "int16_t", count: 4)
        XCTAssertEqual(
            store.selectedImageAddress,
            ImageAddress(slot: .primary, address: 0x1000),
            "Structural authoring must not discard a still-valid binary-less primary selection"
        )
        XCTAssertEqual(
            store.snapshot.dataShape(at: 0x1000, in: .primary),
            DataShapeOverride(kind: .array, elementType: "int16_t", elementCount: 4)
        )
        store.beginMakeDataAtSelection()
        let request = try XCTUnwrap(store.dataShapeEditorRequest)
        XCTAssertEqual(request.shape, .array)
        XCTAssertEqual(request.elementType, "int16_t")
        XCTAssertEqual(request.countText, "4")
    }

    // MARK: - Import C Header

    func testImportCHeaderAddsTypesAndReportsSummary() {
        let store = makeStore()
        store.beginCHeaderImport()
        XCTAssertNotNil(store.cHeaderImportRequest)
        XCTAssertNil(store.cHeaderImportSummary)

        store.commitCHeaderImport("struct Point { int x; int y; };")
        let summary = try! XCTUnwrap(store.cHeaderImportSummary)
        XCTAssertTrue(summary.addedNames.contains("Point"))
        XCTAssertTrue(store.snapshot.typeDefinitions.contains { $0.name == "Point" })

        // The sheet stays open after a commit so the user sees the result.
        XCTAssertNotNil(store.cHeaderImportRequest)
        store.cancelCHeaderImport()
        XCTAssertNil(store.cHeaderImportRequest)
        XCTAssertNil(store.cHeaderImportSummary)
    }

    func testImportCHeaderSkipsDuplicateWithDiagnostic() {
        let store = makeStore()
        store.beginCHeaderImport()
        store.commitCHeaderImport("struct Dup { int a; };")
        XCTAssertEqual(store.snapshot.typeDefinitions.filter { $0.name == "Dup" }.count, 1)
        // Re-import the same name: skipped (not overwritten), with a diagnostic.
        store.commitCHeaderImport("struct Dup { long b; };")
        let summary = try! XCTUnwrap(store.cHeaderImportSummary)
        XCTAssertFalse(summary.addedNames.contains("Dup"))
        XCTAssertFalse(summary.diagnostics.isEmpty)
        XCTAssertEqual(store.snapshot.typeDefinitions.filter { $0.name == "Dup" }.count, 1)
    }

    // MARK: - Pseudocode register extraction (context-menu source)

    func testRegisterExtractionFindsWholeWordRegisters() {
        let regs = PseudocodeRegisterScanner.registers(in: "x0 = x19 + w2; // extract not x300")
        XCTAssertEqual(regs, ["x0", "x19", "w2"])
    }

    func testRegisterExtractionDeduplicatesPreservingOrder() {
        let regs = PseudocodeRegisterScanner.registers(in: "x19 = x19 + x1")
        XCTAssertEqual(regs, ["x19", "x1"])
    }

    func testRegisterExtractionIgnoresOutOfRangeAndSubstrings() {
        XCTAssertTrue(PseudocodeRegisterScanner.registers(in: "x31 x99 extractor wx0").isEmpty)
    }
}
