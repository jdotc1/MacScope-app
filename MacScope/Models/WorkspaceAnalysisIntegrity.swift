import Foundation

/// HS-2: the analyzer/schema version stamped into every saved `.mscope` manifest. Bump `current`
/// and add a `features` row whenever a saved workspace starts depending on analysis an older build
/// cannot produce or read. An older build refuses a newer workspace and names what it lacks from the
/// stamp's own feature list (it cannot know future features by itself).
struct WorkspaceAnalyzerStamp: Codable, Equatable, Sendable {
    struct Feature: Codable, Equatable, Sendable {
        var version: Int
        var name: String
    }

    static let currentVersion = 1
    static let features: [Feature] = [
        Feature(version: 1, name: "analyzer-version stamp and load-time analysis repair"),
    ]
    static var current: WorkspaceAnalyzerStamp {
        WorkspaceAnalyzerStamp(version: currentVersion, features: features)
    }

    var version: Int
    var features: [Feature]

    /// Names of the features this build lacks, newest last; empty when this build can read it.
    func featuresMissing(fromBuildVersion buildVersion: Int = currentVersion) -> [String] {
        guard version > buildVersion else { return [] }
        let missing = features.filter { $0.version > buildVersion }.map(\.name)
        return missing.isEmpty ? ["analyzer version \(version)"] : missing
    }
}

/// HS-1: what load-time validation removed from one image's persisted analysis.
struct WorkspaceAnalysisRepair: Equatable, Sendable {
    var slot: ImageSlot
    var imageName: String
    var functionsOutsideImage = 0
    var duplicateFunctions = 0
    var overlappingFunctions = 0
    var danglingCallXRefs = 0
    var danglingJumpTables = 0
    var danglingBasicBlocks = 0
    var danglingControlFlowEdges = 0

    var isEmpty: Bool { items.isEmpty }

    var items: [String] {
        var result: [String] = []
        func add(_ count: Int, _ what: String) {
            if count > 0 { result.append("\(count) \(what)") }
        }
        add(functionsOutsideImage, "procedure(s) outside the image")
        add(duplicateFunctions, "duplicate procedure(s)")
        add(overlappingFunctions, "overlapping procedure(s)")
        add(danglingCallXRefs, "call reference(s) not at a saved instruction")
        add(danglingJumpTables, "jump table(s) not at a saved instruction")
        add(danglingBasicBlocks, "basic block(s) of removed procedures")
        add(danglingControlFlowEdges, "control-flow edge(s) not from a saved instruction")
        return result
    }
}

enum WorkspaceAnalysisIntegrity {
    /// One user-facing line listing every repair across images.
    static func message(for repairs: [WorkspaceAnalysisRepair]) -> String? {
        let nonEmpty = repairs.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return nil }
        let parts = nonEmpty.map { "\($0.imageName): \($0.items.joined(separator: ", "))" }
        return "The saved analysis was inconsistent and was repaired on open. Removed "
            + parts.joined(separator: "; ")
            + ". The affected image analysis is being rebuilt."
    }

    /// Validates and repairs every image of a just-opened snapshot. Returns only non-empty repairs.
    static func repair(_ snapshot: inout WorkspaceSnapshot) -> [WorkspaceAnalysisRepair] {
        var repairs: [WorkspaceAnalysisRepair] = []
        for binary in snapshot.binaries {
            guard var analysis = snapshot.analysis(in: binary.slot) else { continue }
            let ranges = binary.preferredSegmentLayout.map(imageRanges(from:))
            var repair = WorkspaceAnalysisRepair(slot: binary.slot, imageName: binary.name)
            Self.repair(&analysis, imageRanges: ranges, into: &repair)
            if !repair.isEmpty {
                snapshot.replaceAnalysis(analysis, in: binary.slot)
                repairs.append(repair)
            }
        }
        return repairs
    }

    /// Mapped VM ranges of the image's segments (excluding the empty `__PAGEZERO` reservation).
    static func imageRanges(from layout: MachOPreferredSegmentLayout) -> [Range<UInt64>] {
        layout.records.compactMap { record in
            guard record.name != "__PAGEZERO", record.preferredVMSize > 0 else { return nil }
            let (end, overflow) = record.preferredVMStart.addingReportingOverflow(record.preferredVMSize)
            return overflow ? nil : record.preferredVMStart..<end
        }
    }

    /// Pure repair of one image analysis. `imageRanges == nil` skips the image-bounds check (no
    /// reconstructed segment layout, e.g. non-Mach-O images).
    static func repair(_ analysis: inout ImageAnalysis, imageRanges: [Range<UInt64>]?,
                       into repair: inout WorkspaceAnalysisRepair) {
        // Procedures: inside the image, unique start, no overlap (end is exclusive).
        var kept: [FunctionSummary] = []
        var seenStarts = Set<UInt64>()
        for function in analysis.functions.sorted(by: { ($0.startAddress, $0.endAddress) < ($1.startAddress, $1.endAddress) }) {
            if let imageRanges, !contains(function, in: imageRanges) {
                repair.functionsOutsideImage += 1
                continue
            }
            if !seenStarts.insert(function.startAddress).inserted {
                repair.duplicateFunctions += 1
                continue
            }
            if let previous = kept.last, function.startAddress < previous.endAddress {
                repair.overlappingFunctions += 1
                continue
            }
            kept.append(function)
        }
        if kept.count != analysis.functions.count {
            let keptIDs = Set(kept.map(\.id))
            // Keep the persisted order for survivors.
            analysis.functions = analysis.functions.filter { keptIDs.contains($0.id) }
            let before = analysis.basicBlocks.count
            analysis.basicBlocks = analysis.basicBlocks.filter { keptIDs.contains($0.functionID) }
            repair.danglingBasicBlocks += before - analysis.basicBlocks.count
        }

        // Derived data must agree with the persisted instructions.
        let instructionAddresses = Set(analysis.instructions.map(\.address))
        guard !instructionAddresses.isEmpty else { return }
        let xrefsBefore = analysis.xrefs.count
        analysis.xrefs.removeAll { $0.kind == XRefKind.call && !instructionAddresses.contains($0.from) }
        repair.danglingCallXRefs += xrefsBefore - analysis.xrefs.count

        let tablesBefore = analysis.jumpTables.count
        analysis.jumpTables = analysis.jumpTables.filter { instructionAddresses.contains($0.key) }
        repair.danglingJumpTables += tablesBefore - analysis.jumpTables.count

        let edgesBefore = analysis.controlFlowEdges.count
        // Branch/call targets may legitimately leave the decoded text (stubs, other images); the
        // edge's source must still be a saved instruction.
        analysis.controlFlowEdges.removeAll { !instructionAddresses.contains($0.from) }
        repair.danglingControlFlowEdges += edgesBefore - analysis.controlFlowEdges.count
    }

    private static func contains(_ function: FunctionSummary, in ranges: [Range<UInt64>]) -> Bool {
        guard function.endAddress >= function.startAddress else { return false }
        return ranges.contains { range in
            range.contains(function.startAddress) && function.endAddress <= range.upperBound
        }
    }
}
