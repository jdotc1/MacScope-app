import Foundation

extension WorkspaceStore {
    /// Opening an old workspace preserves its original coordinates. Only this explicit
    /// command opts a retained bare COFF object into the stable section-address layout.
    var canReanalyzeFocusedCOFFObject: Bool {
        guard !isImporting, !isReanalyzing,
              binaryOpenState == nil || binaryOpenState?.phase.isTerminal == true,
              let binary = snapshot.binary(in: focusedImageSlot),
              binary.kind == "COFF object",
              (binary.metadata.coffSectionLayoutVersion ?? 0) == 0,
              let analysis = snapshot.analysis(in: focusedImageSlot),
              !analysis.imageBytes.isEmpty else { return false }
        return true
    }

    func reanalyzeFocusedCOFFObject() {
        guard canReanalyzeFocusedCOFFObject else { return }
        let slot = focusedImageSlot
        guard reanalyzeHonoringOverrides(in: slot, coffSectionLayoutVersion: 1) else { return }
        // The normal reanalysis path preserves the authoring layer. Old addresses are never
        // guessed onto the new layout; their annotations may remain unresolved afterward.
        markDocumentMutated()
        lastIssue = "COFF object reanalysis started with stable section addresses. Existing annotations and overrides are preserved; annotations at old addresses may remain unresolved."
    }
}
