import Foundation

/// Thread-safe, ABA-safe publication authority for one current analysis generation.
///
/// A permit captures both the semantic authority and an internal epoch. Replacing or retiring the
/// authority advances that epoch, so an old task cannot publish even if the same UUID tuple is
/// later activated again. The callback form performs the final check and publication while the
/// fence is locked; retirement therefore cannot interleave between acceptance and assignment.
final class AnalysisDiagnosticsPublicationFence: @unchecked Sendable {
    struct Permit: @unchecked Sendable {
        fileprivate let fence: AnalysisDiagnosticsPublicationFence
        let authority: AnalysisDiagnostic.Authority
        fileprivate let epoch: UInt64

        var isCurrent: Bool {
            fence.accepts(self)
        }

        fileprivate func admitted(_ diagnostics: [AnalysisDiagnostic]) -> [AnalysisDiagnostic] {
            fence.admitted(diagnostics, using: self)
        }

        fileprivate func publish(
            _ diagnostics: [AnalysisDiagnostic],
            _ publication: ([AnalysisDiagnostic]) -> Void
        ) -> Bool {
            fence.publish(diagnostics, using: self, publication)
        }
    }

    private let lock = NSLock()
    private var epoch: UInt64 = 1
    private var currentAuthority: AnalysisDiagnostic.Authority?
    private var isExhausted = false

    init(authority: AnalysisDiagnostic.Authority) {
        currentAuthority = authority
    }

    func permit(for authority: AnalysisDiagnostic.Authority) -> Permit? {
        lock.lock()
        defer { lock.unlock() }
        guard !isExhausted, currentAuthority == authority else { return nil }
        return Permit(fence: self, authority: authority, epoch: epoch)
    }

    /// Installs a new run/document/image or a strictly newer generation in the same run.
    /// Same-run generation rollback is rejected rather than reviving stale work.
    func replaceCurrentAuthority(
        with authority: AnalysisDiagnostic.Authority
    ) -> Permit? {
        lock.lock()
        defer { lock.unlock() }
        guard !isExhausted else { return nil }
        if let currentAuthority,
           Self.isSameRun(currentAuthority, authority),
           authority.analysisGeneration <= currentAuthority.analysisGeneration {
            return nil
        }
        guard advanceEpochLocked() else { return nil }
        currentAuthority = authority
        return Permit(fence: self, authority: authority, epoch: epoch)
    }

    /// Retires only the exact current authority. A stale task cannot retire its successor.
    @discardableResult
    func retire(_ authority: AnalysisDiagnostic.Authority) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isExhausted, currentAuthority == authority else { return false }
        guard advanceEpochLocked() else { return false }
        currentAuthority = nil
        return true
    }

    private func accepts(_ permit: Permit) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return acceptsLocked(permit)
    }

    private func admitted(
        _ diagnostics: [AnalysisDiagnostic],
        using permit: Permit
    ) -> [AnalysisDiagnostic] {
        lock.lock()
        defer { lock.unlock() }
        guard acceptsLocked(permit),
              diagnostics.count <= AnalysisDiagnosticsCollector.maximumDiagnosticCount,
              diagnostics.allSatisfy({ $0.isCurrent(for: permit.authority) }) else {
            return []
        }
        return diagnostics
    }

    private func publish(
        _ diagnostics: [AnalysisDiagnostic],
        using permit: Permit,
        _ publication: ([AnalysisDiagnostic]) -> Void
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !Task.isCancelled,
              acceptsLocked(permit),
              diagnostics.count <= AnalysisDiagnosticsCollector.maximumDiagnosticCount,
              diagnostics.allSatisfy({ $0.isCurrent(for: permit.authority) }) else {
            return false
        }
        publication(diagnostics)
        return true
    }

    private func acceptsLocked(_ permit: Permit) -> Bool {
        !isExhausted
            && permit.fence === self
            && permit.epoch == epoch
            && permit.authority == currentAuthority
    }

    private func advanceEpochLocked() -> Bool {
        let (next, overflow) = epoch.addingReportingOverflow(1)
        guard !overflow else {
            currentAuthority = nil
            isExhausted = true
            return false
        }
        epoch = next
        return true
    }

    private static func isSameRun(
        _ lhs: AnalysisDiagnostic.Authority,
        _ rhs: AnalysisDiagnostic.Authority
    ) -> Bool {
        lhs.imageID == rhs.imageID
            && lhs.documentID == rhs.documentID
            && lhs.sessionID == rhs.sessionID
            && lhs.runID == rhs.runID
    }
}

/// Derives bounded analysis-level diagnostics from already-computed, image-local products.
/// It retains no state, binary bytes, paths, prompts, or third-party diagnostic text.
struct AnalysisDiagnosticsCollector: Sendable {
    static let maximumDiagnosticCount = 256
    private static let maximumInputRecordCount = 1_000_000
    private static let cancellationStride = 64

    /// The neutral inputs the collector reasons over. Authority is optional for the existing
    /// image-local engine seam, whose enclosing ImageAnalysis and store already own identity.
    /// Any result intended for independent publication must carry both authority and its permit.
    struct Input {
        var instructions: [InstructionRow]
        var controlFlowEdges: [ControlFlowEdge]
        var xrefs: [XRef]
        var sections: [SectionSummary]
        var loaderTruncations: [LoaderTruncation]
        var parserDisagreements: [ParserCrossCheckDisagreement]
        var parserCrossCheckSkip: ParserCrossCheckSkip?
        var loaderFindings: [LoaderFinding]
        var authority: AnalysisDiagnostic.Authority?
        var publicationPermit: AnalysisDiagnosticsPublicationFence.Permit?

        init(
            instructions: [InstructionRow],
            controlFlowEdges: [ControlFlowEdge],
            xrefs: [XRef],
            sections: [SectionSummary],
            loaderTruncations: [LoaderTruncation] = [],
            parserDisagreements: [ParserCrossCheckDisagreement] = [],
            parserCrossCheckSkip: ParserCrossCheckSkip? = nil,
            loaderFindings: [LoaderFinding] = [],
            authority: AnalysisDiagnostic.Authority? = nil,
            publicationPermit: AnalysisDiagnosticsPublicationFence.Permit? = nil
        ) {
            self.instructions = instructions
            self.controlFlowEdges = controlFlowEdges
            self.xrefs = xrefs
            self.sections = sections
            self.loaderTruncations = loaderTruncations
            self.parserDisagreements = parserDisagreements
            self.parserCrossCheckSkip = parserCrossCheckSkip
            self.loaderFindings = loaderFindings
            self.authority = authority
            self.publicationPermit = publicationPermit
        }
    }

    /// Loader text is deliberately accepted for source compatibility and immediately discarded.
    /// Only the typed failure and numeric anchor can enter an AnalysisDiagnostic.
    struct LoaderTruncation: Hashable, Sendable {
        var address: UInt64

        init(address: UInt64, message _: String) {
            self.address = address
        }
    }

    private static let resolvableEdgeKinds: Set<String> = [
        "branch", "switch", "fallthrough",
    ]
    private static let acceptedXRefKinds: Set<String> = [
        XRefKind.call, XRefKind.string, XRefKind.selref, XRefKind.classref, XRefKind.data,
    ]
    private static let linkageSectionNames: Set<String> = [
        "__stubs", "__auth_stubs", "__objc_stubs", "__symbol_stub", "__symbol_stub1",
        "__got", "__auth_got", "__la_symbol_ptr", "__nl_symbol_ptr",
        ".plt", ".plt.got", ".got", ".got.plt",
    ]
    private static let zeroUUID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!

    func collect(_ input: Input) -> [AnalysisDiagnostic] {
        guard Self.inputCountsAreBounded(input),
              !Self.mustAbort(input) else {
            return []
        }

        let sectionRanges = input.sections.compactMap(Self.validatedRange)
        let executableRanges = input.sections
            .filter(\.isExecutable)
            .compactMap(Self.validatedRange)
        let linkageRanges = input.sections
            .filter { Self.isLinkageSection($0.name) }
            .compactMap(Self.validatedRange)

        var instructionStarts = Set<UInt64>()
        instructionStarts.reserveCapacity(min(
            input.instructions.count,
            Self.maximumDiagnosticCount * 4
        ))
        for (index, row) in input.instructions.enumerated() {
            guard !Self.mustAbort(input, at: index) else { return [] }
            guard Self.isValidAddress(row.address) else { continue }
            instructionStarts.insert(row.address)
        }

        var bounded = BoundedAccumulator(limit: Self.maximumDiagnosticCount)
        var validation = AnalysisDiagnostic.ImageValidationContext()

        // A branch-like edge is actionable only when its source is an actual decoded row and its
        // target is a valid coordinate not decoded in this same image.
        for (index, edge) in input.controlFlowEdges.enumerated() {
            guard !Self.mustAbort(input, at: index) else { return [] }
            guard edge.id != Self.zeroUUID,
                  Self.resolvableEdgeKinds.contains(edge.kind),
                  instructionStarts.contains(edge.from),
                  Self.isValidAddress(edge.to),
                  !instructionStarts.contains(edge.to),
                  !linkageRanges.contains(where: { $0.contains(edge.to) }),
                  let source = AnalysisDiagnostic.SourceCoordinate(address: edge.from),
                  let diagnostic = validation.validated(
                      severity: .error,
                      address: edge.to,
                      kind: .unresolvedBranchTarget,
                      message: "Branch from \(edge.from.hexAddress) targets \(edge.to.hexAddress), which was not decoded as an instruction.",
                      provenance: .controlFlow,
                      authority: input.authority,
                      sourceCoordinate: source
                  ) else {
                continue
            }
            bounded.insert(diagnostic)
        }

        // Placeholder text is used only as a closed classifier and is never retained.
        for (index, row) in input.instructions.enumerated() {
            guard !Self.mustAbort(input, at: index) else { return [] }
            guard Self.isUndecodedPlaceholder(row),
                  executableRanges.contains(where: { $0.contains(row.address) }),
                  let source = AnalysisDiagnostic.SourceCoordinate(address: row.address),
                  let diagnostic = validation.validated(
                      severity: .error,
                      address: row.address,
                      kind: .undecodedInstruction,
                      message: "An instruction inside executable code could not be decoded.",
                      provenance: .decoder,
                      authority: input.authority,
                      sourceCoordinate: source
                  ) else {
                continue
            }
            bounded.insert(diagnostic)
        }

        // Xrefs must carry a recognized closed kind and originate at either a decoded row or a
        // mapped address. This rejects cross-document debris without requiring every data xref to
        // originate in executable code.
        for (index, xref) in input.xrefs.enumerated() {
            guard !Self.mustAbort(input, at: index) else { return [] }
            let sourceIsLocal = instructionStarts.contains(xref.from)
                || sectionRanges.contains(where: { $0.contains(xref.from) })
            guard xref.id != Self.zeroUUID,
                  Self.acceptedXRefKinds.contains(xref.kind),
                  Self.isValidAddress(xref.from),
                  Self.isValidAddress(xref.to),
                  sourceIsLocal,
                  !sectionRanges.contains(where: { $0.contains(xref.to) }),
                  let source = AnalysisDiagnostic.SourceCoordinate(address: xref.from),
                  let diagnostic = validation.validated(
                      severity: .warning,
                      address: xref.to,
                      kind: .xrefTargetOutsideSections,
                      message: "Reference from \(xref.from.hexAddress) points at \(xref.to.hexAddress), which is outside every mapped section.",
                      provenance: .crossReference,
                      authority: input.authority,
                      sourceCoordinate: source
                  ) else {
                continue
            }
            bounded.insert(diagnostic)
        }

        // Loader messages are third-party/parser payloads. Classify them without retaining text.
        for (index, truncation) in input.loaderTruncations.enumerated() {
            guard !Self.mustAbort(input, at: index) else { return [] }
            guard Self.isValidAddress(truncation.address),
                  let source = AnalysisDiagnostic.SourceCoordinate(address: truncation.address),
                  let diagnostic = validation.validated(
                      severity: .warning,
                      address: truncation.address,
                      kind: .loaderTruncation,
                      message: "The loader reported a truncated or over-read structure.",
                      provenance: .loader,
                      authority: input.authority,
                      sourceCoordinate: source
                  ) else {
                continue
            }
            bounded.insert(diagnostic)
        }

        // Parser cross-check rows carry only app-owned text built from enum vocabulary.
        for (index, disagreement) in input.parserDisagreements.enumerated() {
            guard !Self.mustAbort(input, at: index) else { return [] }
            guard Self.isValidAddress(disagreement.address),
                  let source = AnalysisDiagnostic.SourceCoordinate(address: disagreement.address),
                  let diagnostic = validation.validated(
                      severity: .warning,
                      address: disagreement.address,
                      kind: .parserCrossCheckDisagreement,
                      message: disagreement.message,
                      provenance: .parserCrossCheck,
                      authority: input.authority,
                      sourceCoordinate: source
                  ) else {
                continue
            }
            bounded.insert(diagnostic)
        }

        // A skipped cross-check is one app-owned row, never an analysis failure.
        if let skip = input.parserCrossCheckSkip,
           Self.isValidAddress(skip.address),
           let source = AnalysisDiagnostic.SourceCoordinate(address: skip.address),
           let diagnostic = validation.validated(
               severity: .warning,
               address: skip.address,
               kind: .parserCrossCheckSkipped,
               message: skip.message,
               provenance: .parserCrossCheck,
               authority: input.authority,
               sourceCoordinate: source
           ) {
            bounded.insert(diagnostic)
        }

        // Typed loader findings carry app-owned text built from enum vocabulary and numbers.
        for (index, finding) in input.loaderFindings.enumerated() {
            guard !Self.mustAbort(input, at: index) else { return [] }
            let kind: AnalysisDiagnostic.Kind = switch finding.category {
            case .unsupportedFixup: .unsupportedLoaderStructure
            case .objcMetadataUnavailable: .objcMetadataUnavailable
            case .functionStartsDisagreement: .functionStartsDisagreement
            case .metadataParseIssue: .metadataParseIssue
            }
            guard Self.isValidAddress(finding.address),
                  let source = AnalysisDiagnostic.SourceCoordinate(address: finding.address),
                  let diagnostic = validation.validated(
                      severity: .warning,
                      address: finding.address,
                      kind: kind,
                      message: finding.message,
                      provenance: .loader,
                      authority: input.authority,
                      sourceCoordinate: source
                  ) else {
                continue
            }
            bounded.insert(diagnostic)
        }

        guard !Self.mustAbort(input) else { return [] }
        let diagnostics = bounded.sortedValues()
        if let permit = input.publicationPermit {
            return permit.admitted(diagnostics)
        }
        return diagnostics
    }

    /// Safe publication path. A current empty batch is still published so it can clear older rows;
    /// stale, cross-document, cancelled, or retired work never invokes the callback.
    @discardableResult
    func collect(
        _ input: Input,
        publish publication: ([AnalysisDiagnostic]) -> Void
    ) -> Bool {
        guard let authority = input.authority,
              let permit = input.publicationPermit,
              permit.authority == authority else {
            return false
        }
        let diagnostics = collect(input)
        guard !Task.isCancelled else { return false }
        return permit.publish(diagnostics, publication)
    }

    private static func inputCountsAreBounded(_ input: Input) -> Bool {
        input.instructions.count <= maximumInputRecordCount
            && input.controlFlowEdges.count <= maximumInputRecordCount
            && input.xrefs.count <= maximumInputRecordCount
            && input.sections.count <= maximumInputRecordCount
            && input.loaderTruncations.count <= maximumInputRecordCount
            && input.parserDisagreements.count <= maximumInputRecordCount
            && input.loaderFindings.count <= maximumInputRecordCount
    }

    private static func mustAbort(_ input: Input, at index: Int? = nil) -> Bool {
        if let index, !index.isMultiple(of: cancellationStride) {
            return false
        }
        guard !Task.isCancelled else { return true }
        if let permit = input.publicationPermit {
            return input.authority != permit.authority || !permit.isCurrent
        }
        return false
    }

    private static func validatedRange(_ section: SectionSummary) -> Range<UInt64>? {
        guard section.size > 0 else { return nil }
        let end = section.address.addingReportingOverflow(section.size)
        guard !end.overflow, end.partialValue > section.address else { return nil }
        return section.address..<end.partialValue
    }

    private static func isValidAddress(_ address: UInt64) -> Bool {
        address != UInt64.max
    }

    private static func isUndecodedPlaceholder(_ row: InstructionRow) -> Bool {
        row.mnemonic == "unknown" || row.mnemonic == ".byte"
    }

    private static func isLinkageSection(_ name: String) -> Bool {
        guard name.utf8.count <= 64,
              !name.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return false
        }
        let component = name
            .split(separator: ",", omittingEmptySubsequences: false)
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return linkageSectionNames.contains(component)
    }

    private static func precedes(
        _ lhs: AnalysisDiagnostic,
        _ rhs: AnalysisDiagnostic
    ) -> Bool {
        if lhs.severity.sortRank != rhs.severity.sortRank {
            return lhs.severity.sortRank < rhs.severity.sortRank
        }
        if lhs.address != rhs.address { return lhs.address < rhs.address }
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        if lhs.provenance.rawValue != rhs.provenance.rawValue {
            return lhs.provenance.rawValue < rhs.provenance.rawValue
        }
        let lhsSource = lhs.sourceCoordinate?.address ?? UInt64.max
        let rhsSource = rhs.sourceCoordinate?.address ?? UInt64.max
        if lhsSource != rhsSource { return lhsSource < rhsSource }
        return lhs.id < rhs.id
    }

    private struct BoundedAccumulator {
        let limit: Int
        // Max-heap: the worst admitted row is at zero. Rejected rows cost one comparison,
        // replacing a row costs log(limit); the old scan compared every retained row.
        private var values: [AnalysisDiagnostic] = []
        private var identities = Set<String>()

        init(limit: Int) {
            self.limit = limit
            values.reserveCapacity(limit)
            identities.reserveCapacity(limit)
        }

        mutating func insert(_ diagnostic: AnalysisDiagnostic) {
            // All callers just passed the image validation context; do not validate again.
            guard limit > 0 else { return }
            let id = diagnostic.id
            guard !identities.contains(id) else { return }
            if values.count < limit {
                values.append(diagnostic)
                identities.insert(id)
                var child = values.count - 1
                while child > 0 {
                    let parent = (child - 1) / 2
                    guard AnalysisDiagnosticsCollector.precedes(values[parent], values[child]) else { break }
                    values.swapAt(parent, child)
                    child = parent
                }
                return
            }
            guard AnalysisDiagnosticsCollector.precedes(diagnostic, values[0]) else { return }
            identities.remove(values[0].id)
            values[0] = diagnostic
            identities.insert(id)
            var parent = 0
            while parent * 2 + 1 < values.count {
                var worst = parent * 2 + 1
                let right = worst + 1
                if right < values.count && AnalysisDiagnosticsCollector.precedes(values[worst], values[right]) {
                    worst = right
                }
                guard AnalysisDiagnosticsCollector.precedes(values[parent], values[worst]) else { break }
                values.swapAt(parent, worst)
                parent = worst
            }
        }

        func sortedValues() -> [AnalysisDiagnostic] {
            values.sorted(by: AnalysisDiagnosticsCollector.precedes)
        }
    }
}
