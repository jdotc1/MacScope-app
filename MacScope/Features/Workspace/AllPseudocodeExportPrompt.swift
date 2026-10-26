import Foundation

/// What File › Export All Pseudocode says before it runs. With the Native or Compare source
/// selected it asks which provider to export: Native writes every function through the native
/// decompiler plus a per-function report, and lists functions it refuses rather than filling them
/// with MacScope output; MacScope exports MacScope pseudocode as before.
struct AllPseudocodeExportPrompt: Equatable {
    var title: String
    var message: String
    /// First (default) button: whole-image native export.
    var nativeTitle: String
    var macScopeTitle: String

    /// Nil when the MacScope source is selected: the export runs without asking.
    static func prompt(for source: PseudocodeSource) -> AllPseudocodeExportPrompt? {
        guard source != .macScope else { return nil }
        let compareNote = source == .compare
            ? " Compare covers one selected function at a time; use File › Export Pseudocode for that." : ""
        return AllPseudocodeExportPrompt(
            title: "Export All Functions",
            message: "Native export decompiles every function with the native decompiler and writes a "
                + "report beside the text listing each function's status. Functions it can't decompile "
                + "are listed, not filled in with MacScope pseudocode.\(compareNote)",
            nativeTitle: "Export Native Pseudocode",
            macScopeTitle: "Export MacScope Pseudocode"
        )
    }
}
