# MacScope Nomenclature

The canonical vocabulary for MacScope. When a user-facing string, doc, comment, test name, or
new symbol needs a word for one of these concepts, use the **Canonical term**. This guide is the
tie-breaker; where another doc disagrees on a term, this file wins.

See also: [`../dev/DebuggingPlaybook.md`](../dev/DebuggingPlaybook.md). The
superseded nomenclature-audit narrative remains recoverable from Git history;
this file is the only live terminology authority.

## Principles

1. **User-facing vocabulary comes first.** Menus, labels, messages, and docs read most often, so
   they carry the canonical term. Internal identifiers may retain an older spelling when renaming
   them would break a persisted or public contract — those are listed explicitly below.
2. **Modernize, don't clone.** MacScope targets a comprehensive capability surface on its own
   terms, not a borrowed vocabulary. Where a legacy reverse-engineering term and a modern platform
   term compete, prefer the modern one (Apple/Swift/LLVM/Ghidra usage) — e.g. **Function**, not
   *Procedure*.
3. **Keep platform terms platform-accurate.** Do not rebrand Apple/Swift/Mach-O terminology.
4. **A distinction is not an inconsistency.** Several near-synonyms name genuinely different
   concepts (Symbol vs. Local label; Hex vs. Data; Snapshot vs. Manifest vs. Database). Preserve
   them.
5. **Never rename a persisted or public identifier for cosmetics.** Labels are free to change;
   `.mscope` schema columns, UTIs, CodingKeys, scripting command ids, notification names, and
   bundle identifiers are contracts. See *Retained identifiers*.

## Approved product terms

| Canonical term | Definition | Use in UI? | Use in code? | Deprecated synonyms | Notes |
|---|---|:--:|:--:|---|---|
| **MacScope** | The product. | Yes | Yes | — | Original name since the first commit; never provisional. |
| **macOS binary-analysis workbench** | The product category / one-line descriptor. | Rare | — | macOS Analysis App, binary-analysis app/application | Standardize docs on this phrase. *reverse-engineering workbench* is an acceptable secondary descriptor. |
| **Workspace** | The saved/opened `.mscope` analysis unit the user creates, opens, and saves. | Yes | Yes (`Workspace*`) | Project (for the saved unit) | The file format's own UTI is `…workspace-package`. File menu is "Open Workspace…". |
| **Function** | A function recovered in the binary (start/end, basic blocks, callers/callees). | Yes | Yes (`FunctionSummary`) | Procedure, Routine, Subroutine | UI standardized to *Function*. Internal identifiers named `…Procedure…` are retained for compatibility — see below. |
| **Disassembly** | The linear instruction-listing editor mode. | Yes | Yes | Assembly, Listing | *Listing* survives only in the "Export Listing…" command name. |
| **Pseudocode** | The decompiler's structured output editor mode. | Yes | Yes | Decompilation, Decompiled output, Pseudo-code | *Decompiler* names the engine/Settings category, not the output. |
| **Graph** | The control-flow-graph editor mode. | Yes | Yes | CFG (in prose only) | — |
| **Hex** | The raw-bytes editor mode. | Yes | Yes | — | Distinct from *Data* and *Bytes* (below). |
| **Data** | A type/shape annotation applied to bytes (inspector section, "Make Data"). | Yes | Yes | — | Not a synonym for Hex — it is the *interpretation* of bytes. |
| **Bytes** | The raw material being viewed/edited ("Patch Bytes", "Search Bytes"). | Yes | Yes | — | Distinct slot; do not merge with Hex or Data. |
| **Symbol** | An imported/exported/defined symbol from the binary (immutable after analysis). | Yes | Yes (`SymbolSummary`) | — | Distinct from *Local label*. |
| **Local label** | A user-authored, **function-scoped** name at an address. | Yes | Yes (`local_label`) | — | Distinct from a global symbol rename and from an immutable Symbol. |
| **Cross-reference** / **Xref** | A reference edge to/from an address. | Yes | Yes (`XRef`) | Cross reference | Both spellings canonical: *Xrefs* for the compact tab, *Cross-References* for the formal inspector panel. |
| **Workspace snapshot** | The volatile, in-memory analysis result (not persisted). | No | Yes (`WorkspaceSnapshot`) | — | One of three distinct persistence layers. |
| **Analysis engine** | The engine that produces a snapshot from a loaded binary. | No | Yes (`AnalysisEngine`) | — | — |
| **Binary** | The Mach-O/ELF/PE input under analysis. | Yes ("Open Binary…") | Yes (`LoadedBinary`) | — | — |

## Platform and domain terms (keep unchanged)

Do **not** rebrand these. When used as implementation concepts they must stay platform-accurate.

- **Apple / Swift / SwiftUI / AppKit:** `DocumentGroup`, `Scene`, `Command`, `Inspector`,
  `Sidebar`, `View`, `Binding`, `Observable`, `Task`, `MainActor`, `URL`, `FileDocument`,
  `UTType`, `NSWindow`, `NSDocumentController`.
- **Binary-format domain:** Mach-O, dylib, framework, segment, section, symbol table,
  relocation, chained fixups, DWARF, dSYM, Objective-C, Swift metadata, arm64 / arm64e,
  disassembly, decompiler, basic block, control-flow graph.

## Retained identifiers (user-facing term differs — do NOT rename)

These keep an older spelling because they are persisted on disk, part of a public API, or a
signing/routing contract. The user-facing vocabulary above still applies to any *label* near them.

| Identifier | Layer | User-facing term | Why it is retained |
|---|---|---|---|
| `mark_as_procedure` | SQLite column, `.mscope` schema **v24** | Function | Persisted in every saved workspace; renaming needs a schema migration. |
| `AddressOverride.markAsProcedure` | `Codable` CodingKey | Function | Serialized into `.mscope/manifest.json`. |
| `WorkspaceCommand.markAsProcedure`, `.nextProcedure`, `.previousProcedure`, `.topOfProcedure`, `.selectProcedure`, `.truncateProcedure` | Command-routing enum | Function | Case names drive menu→store routing and notification mapping. |
| `Notification.Name("MacScope*Procedure")`, `MacScopeOpenProject` | AppKit routing | Function / Workspace | Menu items post these; listeners match the exact string. |
| `ProcedureRange` | Navigation helper type | Function | Internal; not persisted, but widely referenced. |
| `make-procedure` command + `isProcedure` argument | Scripting / MCP API | Function | Public command surface; scripts and bindings call it by name. |
| `"procedures"` | Golden-differential capability key | Function | Compared against the reference oracle JSON schema. |
| `WorkspaceTool.project` (raw value `"Project"`) | Persisted `selected_tool` | *Project* (a distinct concept) | Names the **structural-overview sidebar tab**, not the saved unit. Its raw value is persisted. |
| `.openProject` keybinding case | Keybinding id | Workspace | Routing id; the keybinding's *display* label is "Open Workspace". |
| `.mscope` + UTI `org.macscope.workspace-package` | File format / OS association | Workspace | Renaming orphans every saved document. |
| `org.macscope.app*` bundle identifiers | Code signing / XPC | — | Signing identity + plugin XPC endpoint. See the audit's deferred-review note on the `machscope`/`macscope` spelling split. |

## Ambiguous — deferred for human review

Recorded here so they are not silently "fixed"; each needs a human decision (and, where noted, a
migration) before any change.

- **Bundle-id spelling split.** Bundle identifiers are `org.macscope.app` (with an "h"); UTIs are
  `org.macscope` (no "h"). Signing/identity-critical — do not rename without a signing-aware
  migration. The historical rationale remains in Git.
- **The "Project" sidebar tab.** With the saved unit now uniformly called *Workspace*, the
  structural-overview tab labelled "Project" (persisted `WorkspaceTool.project`) may read as
  overloaded. Renaming its label is cheap; renaming the persisted raw value needs a `selected_tool`
  migration. Deferred.
- **Mark vs. Make verb.** "Make Data" vs. "Mark as Function"/"Mark as Undefined" use two verbs for
  address annotation. Pick one verb in a future UX pass.
- **"Set Local Label…" vs. "Rename Symbol".** These are *different* operations (a function-scoped
  label vs. a global symbol rename), kept distinct on purpose — not merged.

## Retained by design (not a nomenclature defect)

- The behavioral **golden differential** validates against external reference oracles (an
  open-source disassembler, Ghidra, and a reference disassembler). Refer to the non-Ghidra oracle
  generically as **"reference"** (`reference.json`, `reference_golden_export.py`) — never by a
  product name.
