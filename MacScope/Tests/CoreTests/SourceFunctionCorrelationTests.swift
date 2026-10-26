import Foundation
import XCTest
@testable import MacScope

final class SourceFunctionCorrelationTests: XCTestCase {
    /// The retained, owner-authorized pilot is an external input; this test never builds,
    /// downloads or rehashes its source. Native analysis is the new behavior under test.
    @MainActor
    func testRealSpecimenPositiveNegativesAndFreshSaveReopen() throws {
        guard let path = ProcessInfo.processInfo.environment["MACSCOPE_SOURCE_CORRELATION_SPECIMEN_ROOT"] else {
            throw XCTSkip("Explicit local source correlation specimen root is required")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let engine = AnalysisEngine()
        var snapshot = try engine.analyze(url: root.appendingPathComponent("yes329"))
        let targetSnapshot = try engine.analyze(url: root.appendingPathComponent("yes329-stripped"))
        let reference = try XCTUnwrap(snapshot.binaries.first)
        var target = try XCTUnwrap(targetSnapshot.binaries.first)
        let targetSlot = ImageSlot(rawValue: 7)
        target.slot = targetSlot
        var landingAnalysis = try XCTUnwrap(targetSnapshot.analysis(in: targetSnapshot.primarySlot))
        // Match loadAdditionalBinary: engine IDs are primary-slot scoped until restamped.
        AnalysisStableIdentity.restamp(&landingAnalysis, to: targetSlot)
        snapshot.insertImage(binary: target, analysis: landingAnalysis)
        let revision = try XCTUnwrap(SourceRevisionIdentity("298787009e5432c5e4c378a077f98267077e3495"))
        let checkout = try XCTUnwrap(AcceptedLocalSourceCheckout(
            localRootPath: root.path, recordedSourceRoot: root.path, revision: revision
        ))
        let targetCheckout = try XCTUnwrap(AcceptedLocalSourceCheckout(
            localRootPath: root.path, recordedSourceRoot: root.path, revision: revision
        ))
        let store = WorkspaceStore(workspaceName: "Source correlation witness", snapshot: snapshot,
                                   engine: engine, autosaveScheduler: nil)
        let debug = try DSYMImportService().importDebugSymbols(
            at: root.appendingPathComponent("yes329.dSYM"), expectedUUID: reference.metadata.uuid
        )
        let main = try XCTUnwrap(debug.functions.first { $0.name == "main" })
        // Install only the importer-owned debug evidence. The stripped target gets no line rows.
        store.snapshot.mutateAnalysis(in: reference.slot) { $0.sourceLines = debug.sourceLines }
        store.retainSourceDebugImport(debug, in: reference.slot)
        try store.acceptSourceCheckout(checkout, buildRevision: revision, expectedBinary: reference,
                                       expectedInstallationID: store.documentInstallationID, address: main.address)
        try store.acceptSourceCheckout(targetCheckout, buildRevision: revision, expectedBinary: target,
                                       expectedInstallationID: store.documentInstallationID, address: main.address)
        let beforeProposal = store.snapshot.sourceLinkState
        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: beforeProposal) as? [String: Any])
        legacyObject["version"] = 1
        let legacyState = try SourceLinkWorkspaceState.decode(JSONSerialization.data(withJSONObject: legacyObject))
        XCTAssertEqual(legacyState.version, 1)
        XCTAssertEqual(try SourceLinkWorkspaceState.decode(legacyState.encoded()).version, 2)
        let proposals = try store.sourceFunctionCandidates(from: reference.slot, to: targetSlot,
                                                            targetRevision: revision)
        if proposals.isEmpty {
            try writeRefusal(store: store, reference: reference, target: target, root: root,
                             revision: revision, debugArchitecture: debug.matchedSliceArchitecture)
        }
        let positive = try XCTUnwrap(proposals.first { $0.targetAddress == main.address },
                                    "Real stripped entry must match its pinned-source reference")
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(positive.referenceLink.qualification, .exactDebugSymbols)
        XCTAssertEqual(positive.referenceLink.line, 56)
        XCTAssertEqual(positive.referenceLink.image?.architecture, "arm64e")
        XCTAssertEqual(positive.targetImage.architecture, "arm64e")
        XCTAssertEqual(store.snapshot.sourceLinkState, beforeProposal, "Proposals cannot mutate persistence")
        let referenceAnalysis = try XCTUnwrap(store.snapshot.analysis(in: reference.slot))
        let targetAnalysis = try XCTUnwrap(store.snapshot.analysis(in: targetSlot))
        let state = try SourceLinkWorkspaceState.decode(store.snapshot.sourceLinkState)
        let binding = try XCTUnwrap(state.binding(for: reference))
        func matches(_ other: WorkspaceSnapshot, revision targetRevision: SourceRevisionIdentity? = nil) throws -> [SourceFunctionCorrelation] {
            try SourceFunctionCorrelationMatcher.candidates(
                reference: reference, referenceAnalysis: referenceAnalysis, referenceBinding: binding,
                target: try XCTUnwrap(other.binaries.first),
                targetAnalysis: try XCTUnwrap(other.analysis(in: other.primarySlot)), targetRevision: targetRevision ?? revision
            )
        }
        let otherRevision = try XCTUnwrap(SourceRevisionIdentity("shell_cmds-336.40.1"))
        XCTAssertTrue(try matches(targetSnapshot, revision: otherRevision).isEmpty, "Wrong revision")
        let installed = try engine.analyze(url: URL(fileURLWithPath: "/usr/bin/yes"), requestedSliceIndex: 1)
        XCTAssertTrue(try matches(installed).isEmpty, "Actual changed entry must fail even if revision is misdeclared")
        let tee = try engine.analyze(url: URL(fileURLWithPath: "/usr/bin/tee"), requestedSliceIndex: 1)
        XCTAssertTrue(try matches(tee).isEmpty, "Shared library calls do not qualify a source function")
        let x86 = try engine.analyze(url: URL(fileURLWithPath: "/usr/bin/yes"), requestedSliceIndex: 0)
        XCTAssertTrue(try matches(x86).isEmpty, "Wrong fat slice")
        XCTAssertEqual(store.snapshot.sourceLinkState, beforeProposal)

        // Distinct analysis mutation: normalized immediates still collide, semantic constants do not.
        var changed = targetAnalysis
        let instructionIndex = try XCTUnwrap(changed.instructions.firstIndex {
            $0.address >= positive.targetAddress && $0.mnemonic.hasPrefix("mov") && $0.operands.contains("#")
        })
        let immediate = try NSRegularExpression(pattern: "#(?:0x[0-9a-fA-F]+|[0-9]+)")
        let operands = changed.instructions[instructionIndex].operands
        let immediateMatch = try XCTUnwrap(immediate.firstMatch(in: operands,
            range: NSRange(operands.startIndex..., in: operands)))
        let immediateRange = try XCTUnwrap(Range(immediateMatch.range, in: operands))
        changed.instructions[instructionIndex].operands.replaceSubrange(immediateRange, with: "#123456")
        XCTAssertTrue(try SourceFunctionCorrelationMatcher.candidates(
            reference: reference, referenceAnalysis: referenceAnalysis, referenceBinding: binding,
            target: target, targetAnalysis: changed, targetRevision: revision
        ).isEmpty, "Masked-body equality cannot hide a semantic constant change")

        var partialReference = referenceAnalysis
        var partialTarget = targetAnalysis
        let removedAddress = changed.instructions[instructionIndex].address
        partialReference.instructions.removeAll { $0.address == removedAddress }
        partialTarget.instructions.removeAll { $0.address == removedAddress }
        XCTAssertTrue(try SourceFunctionCorrelationMatcher.candidates(
            reference: reference, referenceAnalysis: partialReference, referenceBinding: binding,
            target: target, targetAnalysis: partialTarget, targetRevision: revision
        ).isEmpty, "Identical incomplete bodies must not qualify")

        // Duplicate the real body into two independent target ranges; shared names cannot disambiguate.
        let function = try XCTUnwrap(targetAnalysis.functions.first { $0.startAddress == main.address })
        let delta: UInt64 = 0x10000
        var ambiguous = ImageAnalysis()
        ambiguous.functions = [function, FunctionSummary(id: UUID(), name: "main",
            startAddress: function.startAddress + delta, endAddress: function.endAddress + delta, confidence: 1)]
        let body = targetAnalysis.instructions.filter {
            function.startAddress <= $0.address && $0.address < function.endAddress
        }
        ambiguous.instructions = body + body.map { row in
            var copy = row; copy.address += delta; return copy
        }
        XCTAssertTrue(try SourceFunctionCorrelationMatcher.candidates(
            reference: reference, referenceAnalysis: referenceAnalysis, referenceBinding: binding,
            target: target, targetAnalysis: ambiguous, targetRevision: revision
        ).isEmpty, "Ambiguous duplicate bodies must abstain")
        var oversized = targetAnalysis
        oversized.functions = Array(repeating: function, count: SourceFunctionCorrelationMatcher.maximumFunctions + 1)
        XCTAssertThrowsError(try SourceFunctionCorrelationMatcher.candidates(
            reference: reference, referenceAnalysis: referenceAnalysis, referenceBinding: binding,
            target: target, targetAnalysis: oversized, targetRevision: revision
        )) { error in
            guard case .some(.inputLimit) = error as? SourceFunctionCorrelationError else {
                return XCTFail("Oversized input must fail at the correlation bound")
            }
        }

        XCTAssertThrowsError(try store.acceptSourceFunctionCandidate(positive, expectedInstallationID: UUID()))
        let targetIndex = try XCTUnwrap(store.snapshot.binaries.firstIndex { $0.slot == targetSlot })
        var replacedTarget = target
        replacedTarget.selectedSliceIndex = 99
        store.snapshot.binaries[targetIndex] = replacedTarget
        XCTAssertThrowsError(try store.acceptSourceFunctionCandidate(positive,
            expectedInstallationID: store.documentInstallationID), "A rendered proposal cannot follow a different slice")
        store.snapshot.binaries[targetIndex] = target
        let referenceIndex = try XCTUnwrap(store.snapshot.binaries.firstIndex { $0.slot == reference.slot })
        var replacedReference = reference
        replacedReference.metadata.uuid = UUID().uuidString
        store.snapshot.binaries[referenceIndex] = replacedReference
        XCTAssertThrowsError(try store.acceptSourceFunctionCandidate(positive,
            expectedInstallationID: store.documentInstallationID), "A rendered proposal cannot follow a replaced reference")
        store.snapshot.binaries[referenceIndex] = reference
        XCTAssertEqual(store.snapshot.sourceLinkState, beforeProposal)
        try store.acceptSourceFunctionCandidate(positive, expectedInstallationID: store.documentInstallationID)
        let accepted = try XCTUnwrap(store.sourceLinks(at: main.address, in: targetSlot).first {
            if case .some(.functionCorrelation) = $0.evidence { return true }; return false
        })
        XCTAssertEqual(accepted.qualification, .versionQualifiedCandidate)
        let targetOpen = try store.sourceOpenTarget(accepted, origin: .compareImagesNew(slot: targetSlot))
        XCTAssertEqual(targetOpen.fileURL, root.appendingPathComponent("source/yes.c"))
        try store.retainOpenedSourceLink(accepted, origin: .compareImagesNew(slot: targetSlot))
        var wrongVersion = try XCTUnwrap(JSONSerialization.jsonObject(with: store.snapshot.sourceLinkState) as? [String: Any])
        wrongVersion["version"] = 1
        XCTAssertThrowsError(try SourceLinkWorkspaceState.decode(JSONSerialization.data(withJSONObject: wrongVersion)))
        XCTAssertEqual(store.snapshot.addressOverrides, snapshot.addressOverrides, "Correlation must not rename or retype")
        XCTAssertEqual(store.snapshot.analysis(in: targetSlot)?.sourceLines, [])

        let output = root.appendingPathComponent("native-acceptance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let databaseURL = output.appendingPathComponent("workspace.sqlite")
        let workspaceID = try save(store, to: databaseURL)
        // The save helper releases its database; these are fresh database and store objects.
        let reopened = try WorkspaceDatabase(path: databaseURL.path)
        try reopened.applySchema()
        let loaded = try XCTUnwrap(reopened.loadWorkspaceState(workspaceID: workspaceID))
        let freshStore = WorkspaceStore(workspaceName: "Reopened source correlation", snapshot: loaded.snapshot,
                                        engine: engine, autosaveScheduler: nil)
        let fresh = try XCTUnwrap(freshStore.sourceLinks(at: main.address, in: targetSlot).first {
            if case .some(.functionCorrelation) = $0.evidence { return true }; return false
        })
        XCTAssertEqual(fresh, accepted)
        XCTAssertEqual(try freshStore.sourceOpenTarget(fresh, origin: .compareImagesNew(slot: targetSlot)).fileURL,
                       targetOpen.fileURL)
        let package = output.appendingPathComponent("SourceCorrelation.mscope")
        _ = try reopened.writePackage(workspaceID: workspaceID, documentID: store.documentID, to: package)
        // Import into a DB already owning these binary IDs: exercise real nested owner remapping once.
        let imported = try reopened.importPackage(from: package)
        XCTAssertNotEqual(imported.snapshot.binaries.map(\.id), store.snapshot.binaries.map(\.id))
        let importedStore = WorkspaceStore(workspaceName: "Imported source correlation", snapshot: imported.snapshot,
                                           engine: engine, autosaveScheduler: nil)
        let importedLink = try XCTUnwrap(importedStore.sourceLinks(at: main.address, in: targetSlot).first {
            if case .some(.functionCorrelation) = $0.evidence { return true }; return false
        })
        XCTAssertEqual(try importedStore.sourceOpenTarget(importedLink, origin: .compareImagesNew(slot: targetSlot)).fileURL,
                       targetOpen.fileURL)
        XCTAssertThrowsError(try importedStore.sourceOpenTarget(accepted, origin: .compareImagesNew(slot: targetSlot)))
        importedStore.snapshot.mutateAnalysis(in: targetSlot) { $0.instructions = changed.instructions }
        XCTAssertThrowsError(try importedStore.sourceOpenTarget(importedLink, origin: .compareImagesNew(slot: targetSlot)))
        guard (testRun?.failureCount ?? 1) == 0 else { return }
        let report: [String: Any] = ["sourceCommit": revision.value, "positiveAddress": main.address,
            "automatedPositive": true, "negativeControls": ["wrongRevision", "changedSystemEntry", "sharedImports", "fatSlice", "semanticConstant", "incompleteBodies", "duplicateBodies", "inputBound", "staleInstallation", "staleTargetSlice", "staleReference", "staleAnalysis"],
            "freshDatabaseReopen": true, "packageImportRemap": true, "output": output.path]
        let receipt = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try receipt.write(to: output.appendingPathComponent("result.json"))
        print("SOURCE_CORRELATION_RECEIPT \(output.path)")
    }

    private struct Refusal: Codable {
        let referenceDisplayArchitecture: String
        let targetDisplayArchitecture: String
        let debugArchitecture: String?
        let anchors: [SourceEvidenceLink]
        let referenceFingerprints: [FunctionVersionFingerprint]
        let targetFingerprints: [FunctionVersionFingerprint]
        let referenceInstructions: [InstructionRow]
        let targetInstructions: [InstructionRow]
    }

    @MainActor
    private func writeRefusal(store: WorkspaceStore, reference: BinaryImage, target: BinaryImage,
                              root: URL, revision: SourceRevisionIdentity, debugArchitecture: String?) throws {
        let state = try SourceLinkWorkspaceState.decode(store.snapshot.sourceLinkState)
        let binding = try XCTUnwrap(state.binding(for: reference))
        let lhs = try XCTUnwrap(store.snapshot.analysis(in: reference.slot))
        let rhs = try XCTUnwrap(store.snapshot.analysis(in: target.slot))
        let index = SourceCandidateIndex(binary: reference, sourceRevision: revision,
            debugContext: debugArchitecture.map { .init(architecture: $0, sourceRevision: revision) },
            sourceLines: lhs.sourceLines, acceptedCheckouts: [binding.checkout])
        let output = Refusal(referenceDisplayArchitecture: reference.architecture,
            targetDisplayArchitecture: target.architecture, debugArchitecture: debugArchitecture,
            anchors: lhs.functions.flatMap { index.links(functionAddress: $0.startAddress) },
            referenceFingerprints: FunctionVersionFingerprintAdapter.fingerprints(from: lhs),
            targetFingerprints: FunctionVersionFingerprintAdapter.fingerprints(from: rhs),
            referenceInstructions: Array(lhs.instructions.prefix(2_048)),
            targetInstructions: Array(rhs.instructions.prefix(2_048)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = root.appendingPathComponent("refusal-\(UUID().uuidString).json")
        try encoder.encode(output).write(to: url)
        print("SOURCE_CORRELATION_REFUSAL_RECEIPT \(url.path)")
    }

    @MainActor
    private func save(_ store: WorkspaceStore, to url: URL) throws -> Int64 {
        let database = try WorkspaceDatabase(path: url.path)
        try database.applySchema()
        return try XCTUnwrap(store.saveWorkspace(to: database).workspace.id)
    }
}
