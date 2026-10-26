# MacScope Design Contract

This is the living visual and interaction contract for MacScope. It describes
the target workbench and active screen contracts rather than preserving a dated
implementation diary.
Historical decisions remain available in Git and in the frozen wave
specifications and plans.

Product scope is described in [`PARITY_CONTRACT.md`](../PARITY_CONTRACT.md).
The implementation source of truth for visual tokens is
[`AppDesignSystem.swift`](../DesignSystem/AppDesignSystem.swift).

## Character and workflow

MacScope is precise, technical, quiet, dense, and dependable. It should feel
like a native professional Mac editor: information rich without turning every
fact into a card, compact without clipping primary content, and explicit when
evidence is missing.

The visual direction uses a saturated unified command surface, a clearly
selected numbered workspace strip, a softly tinted navigator, a high-contrast
and mostly flat primary canvas, restrained semantic status color, optional
detail panes, and a compact interactive status rail. MacScope must still read
as a reverse-engineering editor, not as a generic dashboard or a literal clone.

The primary workflow is: open a binary, app bundle, framework, dylib, or saved
workspace; inspect and navigate the focused image; switch among Disassembly,
Pseudocode, Graph, and Hex; author supported annotations; inspect details; and
use the local debugger when the target and macOS policy permit it.

Use canonical product terms:

- **Workspace** is the document and may contain multiple binary images.
- **Focused image** is the one image currently driving the interactive editor.
- **Selected location** is an image-qualified address, not a workspace-global
  bare virtual address.
- **Primary image** is a deterministic compatibility owner for headless and
  legacy APIs; it is not a substitute for the focused image in the GUI.

## Window anatomy

The target window is one native composition with four persistent layers and
two independently optional panes:

1. A unified/full-size titlebar command surface shares one saturated brand
   field with the traffic lights. It owns workspace identity, focused-image
   summary, history navigation, Open, Go To, browser access, current analysis
   status, the primary contextual action, and navigator/inspector toggles.
2. Directly below it, one numbered workspace strip owns editor presentation:
   `01 Disassembly`, `02 Pseudocode`, `03 Graph`, and `04 Hex`. This is the sole
   editor-mode selector. Do not introduce a fifth mode or a fake analysis stage
   merely to match the reference app's five-step scientific workflow.
3. The workbench body contains a leading navigator, the central editor, and an
   optional trailing inspector. The navigator and inspector collapse
   independently and return their width to the editor. Do not add the reference
   app's workspace-specific middle source-score column as a persistent MacScope
   pane.
4. A compact bottom status rail owns environment, focused-image, analysis, and
   debugger summaries. The debugger cell is the collapsed debugger deck; an
   active or explicitly opened debugger expands upward from that rail. Never
   stack a second debugger status band above or below it.
5. Settings remain a separate macOS Settings scene.

The top two rows must read as one titlebar composition rather than a native
titlebar stacked above custom chrome. AppKit owns traffic lights, dragging,
resizing, activation, and full screen. Custom content must reserve traffic-light
clearance, preserve a useful draggable region, and never cross workspace text,
another control, or an automatic framework item at any supported width.

The sidebar and editor remain deliberately custom, table-like surfaces because
their dense technical content and readability constraints are not met by a
generic card dashboard. `NavigationSplitView`, `.searchable`, and toolbars must
not inject duplicate navigator toggles, search fields, titles, or commands. If
automatic suppression is unreliable, retain or revise the manual split shell
instead of accepting duplicate chrome. Do not redesign graph layout as an
incidental visual change.

### Unified command surface

The first row follows the reference composition without copying its controls:

- Leading: system traffic lights, one navigator toggle, the MacScope symbol,
  workspace name, and a one-line focused-image/architecture subtitle.
- Middle: a quiet current-context summary such as the focused function or
  selected location. It yields before primary actions and may disappear at the
  compact breakpoint.
- Trailing: a compact, closed-vocabulary analysis-status label with symbol and
  text, one prominent contextual action, Go To, browsers, and the inspector
  toggle. `Open` is the prominent action for an empty workspace; loaded-state
  actions must come from existing product commands rather than inventing a
  perpetual Start button.

Use a saturated violet family derived from `MacScopeBrand` for the unified
surface. The field may vary subtly from leading to trailing regions, but it must
not use an ornamental rainbow or obscure control boundaries. Text and symbols
need semantic active, inactive, disabled, and high-contrast roles. The prominent
action may use the brighter magenta-violet accent seen in the reference only
when it is genuinely the primary action.

### Numbered editor strip

The second row is a shallow, full-width strip with four equal or content-aware
segments. Each segment combines a two-digit index, SF Symbol, and editor-mode
label. The selected segment uses a light raised fill in Light appearance or a
clearly elevated adaptive fill in Dark appearance, plus a thin accent edge. It
must remain identifiable without color through selected state, contrast, and
VoiceOver value. At compact widths, indices disappear before labels; labels may
collapse to symbols only after accessible help and labels are present.

Changing mode preserves the focused image and image-qualified selection. The
strip is presentation navigation, not a pipeline: modes have no succeeded,
failed, or incomplete state.

### Navigator

The navigator uses a softly tinted brand-neutral surface distinct from the
editor. Its fixed hierarchy is:

1. tool-local search at the top;
2. the existing Project, Symbols, Strings, Xrefs, Debug, and Extensions tool
   switcher as a compact icon strip with selected fill and bottom/leading
   accent;
3. one uppercase semantic section header with contextual actions;
4. source-list rows derived from the selected tool; and
5. an optional compact environment or workspace-health summary anchored after
   the navigable content when useful.

Tool switching changes the navigator's dataset; editor-mode switching changes
the center presentation. These controls must never appear to be two versions of
the same navigation. Preserve the current one-line title plus optional one-line
detail contract. Selected rows use a tinted fill and a strong leading accent;
hover, keyboard focus, inactive-window selection, and authored color tags remain
distinct. Status uses symbol plus text, never a green dot alone.

The reference app demonstrates a 300-point navigator, but MacScope's longer
binary and symbol identities require the existing 328–384-point contract and
248-point readable text column. Visual similarity must not override measured
readability.

### Primary editor canvas

The central region is bright, quiet, and predominantly flat. Use typography,
alignment, whitespace, and hairline rules before adding containers. A compact
context heading may use the reference's paired magenta/teal leading rules to
mark the current workbench context, but those rules are one reusable design
primitive and not decoration repeated on every section.

The context heading prioritizes current function or binary, followed by a
one-line focused-image, address-range, or selection summary. The mode name does
not repeat here because the numbered strip already owns it. Disassembly,
pseudocode, graph, and hex content remains edge-aligned and information dense;
never wrap each instruction, line, graph node group, or byte row in a card.

Forms, empty states, import progress, and recovery content use broad flat
sections separated by hairlines, matching the reference's Setup surface. Use a
rounded or elevated panel only for a bounded semantic object that benefits from
containment, such as a blocking issue, compact graph overlay, or inspector
group. Avoid shadow stacks and large empty decorative cards.

### Inspector

The inspector is an optional independent trailing pane. It uses a neutral or
subtly tinted supporting surface, a concise title/summary, and vertically
stacked semantic groups for selection, procedure, data, xrefs, segment, and
analysis detail. Groups may use a light raised surface, but dense key/value
content remains flat within each group.

Showing the inspector must not replace the editor or silently hide the
navigator. At widths where all three panes would violate the editor readability
budget, the inspector remains logically requested but is visually withheld or
presented through an explicit compact alternative. Closing it returns its width
to the editor. Long values remain selectable and preserve their leading
identity.

### Bottom status rail and debugger

The bottom rail is 24–28 points high and contains compact, independently
accessible cells such as `ENGINE`, `IMAGE`, `ANALYSIS`, `DEBUGGER`, and a
bounded count relevant to the current tool. Each cell combines a semantic icon,
uppercase label, and short value. Cells may navigate to or reveal the owning
surface, but they must not become an unrelated second command toolbar.

The rail is the idle debugger presentation. When the debugger expands, the
expanded deck appears immediately above the rail and the `DEBUGGER` cell
continues to summarize its state and owner. When binary A is being debugged
while binary B is focused, both identities remain explicit; no live-program-
counter, breakpoint, or Run-to-Cursor state leaks from A into B.

## Settings and Local AI anatomy

Settings uses a native source-list sidebar because its category count no longer fits a readable
horizontal tab strip. The sidebar is the sole category navigator; the detail pane is the sole owner
of the selected category's controls and scrolling. Do not retain a second tab strip, category
picker, spacer band, or decorative header above the detail content.

`AppSettingsChrome` owns the category and detail widths plus the stable content height. The sidebar
may flex only within its centralized minimum, ideal, and maximum bounds. The detail pane preserves
its minimum width and scrolls vertically when content exceeds the laptop-safe height. Changing
categories must not make the Settings window jump between unrelated heights.

The Local AI category is a native form, not a card dashboard. Its anatomy is:

1. provider endpoint and bounded timeout controls;
2. one explicit Refresh action with an adjacent closed readiness status;
3. one model list that distinguishes language versus embedding and loaded versus unloaded without
   relying on color alone; and
4. exact model-key selection and concise recovery guidance.

Use `AppLocalAISettingsChrome` for form geometry, row height, SF Symbols, and status presentation.
Exact endpoint and model identifiers use the centralized monospaced Settings identifier role and
preserve their leading identity while truncating in the middle or tail as appropriate. Display
names never replace exact keys. Use standard form/list surfaces and separators; add no decorative
cards, glass, gradients, or shadow stacks.

Local AI status combines text, an SF Symbol, and semantic color. Refreshing remains visibly
in-progress without continuous motion when Reduce Motion is enabled. Reduce Transparency uses the
ordinary opaque Settings surface. Increased Contrast retains readable separators and keyboard
focus using the centralized contrast/focus metrics.

## Design-system rules

All new UI must use `AppDesignSystem` roles rather than local visual constants.
The active scale and layout contracts are:

- Spacing: 4, 8, 12, 16, 20, and 24 points.
- Radius: 4 for tight selection/focus chrome, 6 for compact controls, 8 for
  regular surfaces, and 10 for panels.
- Minimum supported window: 1080 points wide.
- Sidebar: 328–384 points, preserving at least a 248-point readable text
  column.
- Editor: preserve at least 560 points of readable width.
- Inspector: present at 1220 points or wider and stay within the centralized
  compact/regular width policy.
- Debugger: compact when idle; an expanded deck must retain at least 360 points
  of editor height and stay within its window-height budget.
- Graph: use `AppGraphChrome` lane, node, edge, overview, and minimap metrics;
  do not introduce independent geometry constants.

Use system body/caption roles in navigation and metadata. Addresses, bytes,
mnemonics, pseudocode, register values, and debugger transcript content use
the appropriate monospaced role. Keep addresses and bytes visually quieter
than the mnemonic/operand scan path.

Use semantic colors, centralized surfaces, and SF Symbols; use system
materials only through the design-system policy. Breakpoint, current program
counter, selection, patch, warning, and error states must remain distinct and
must not rely on color alone. The application does not force an appearance. Do
not fake Liquid Glass with arbitrary blur, gradients, shadows, or opacity
stacks.

The reference-derived palette is hierarchical rather than uniformly purple:

- saturated brand violet: unified command surface and selected mode context;
- brighter magenta-violet: primary action and selected leading accents;
- restrained teal/cyan: navigator headings, secondary context rule, and
  informational identity where it does not compete with selection;
- semantic green, amber, and red: success, attention/disabled, and failure;
- pale adaptive violet-neutral: navigator and supporting-pane backgrounds;
- neutral editor background: dense technical content and forms.

All roles require adaptive Light and Dark definitions. Do not obtain Dark
appearance by placing white content beneath a dark titlebar, and do not make the
entire workbench violet. The reference screenshot is evidence for hierarchy,
not permission to hard-code its Light-only RGB values.

## Interaction and accessibility

- Every primary action has an accessibility label and, where appropriate, a
  keyboard command or discoverable help string.
- Selection, hover, keyboard focus, disabled state, and inactive-window
  selection remain distinguishable in Light and Dark appearances.
- Primary sidebar labels preserve their leading text and use at most one title
  line plus one detail line. Dense metadata belongs in the context bar or
  inspector.
- Inspector key/value rows preserve long paths, symbols, and identifiers
  without collapsing the editor.
- Motion is subtle, state driven, interruptible, and removed when Reduce Motion
  is enabled.
- Reduce Transparency uses the design-system fallback surfaces. Increased
  Contrast uses the centralized stroke and focus-ring widths.
- Keyboard-only navigation must not lose selection or focus as the focused
  image or editor mode changes.
- Empty workspace, import-in-progress, failed import, loaded-but-missing
  analysis, and debugger unavailable states are distinct; missing evidence
  uses unavailable copy rather than a plausible value from another image.
- Navigator, editor mode, inspector visibility, and debugger expansion preserve
  independent focus and selection. Hiding one pane does not reset the state of
  another.
- Status-rail cells and numbered mode segments expose meaningful labels, values,
  selected traits, and help; two-digit indices and color are supplementary.
- The saturated titlebar remains legible when the window is inactive and under
  Increased Contrast. Disabled controls remain visible without resembling
  selected controls.

## WS-17 focused-image acceptance

WS-17 changes identity and ownership, not visual style. The listing,
pseudocode, graph, inspector, command surfaces, breakpoint gutter, and debugger
deck must all present one coherent focused image.

- When two images contain the same virtual address, selecting image B shows
  only B's instruction, symbol, source line, tag, color, breakpoint, xrefs, and
  inspector detail. Image A must not leak into visible or accessibility text.
- A mapped but undecoded B address remains a valid selected location, while
  instruction-only actions and instruction detail remain disabled or absent.
- Graph nodes, edges, names, colors, overview counts, minimap, selection, and
  multi-selection derive from the same one-image graph projection. A stale
  callback does not move visible selection.
- Multi-image summaries name the focused binary wherever a bare address would
  be ambiguous. Existing concise wording remains unchanged for a single-image
  workspace.
- Breakpoint gutters show the focused image's authored breakpoints. A live
  program counter is highlighted only when the visible image owns the active
  debugger target.
- Focusing image B while image A is being debugged does not retarget the live
  session, paint A's program counter in B, replace A's live breakpoint set, or
  enable Run to Cursor against B.
- Inspector, context-bar, graph, command-palette, breakpoint, and debugger
  accessibility summaries follow the same visible owner and use the same
  unavailable posture when exact evidence is absent.

## WS-21 logical breakpoint presentation

WS-21 changes breakpoint authority and lifecycle without redesigning the surrounding debugger deck.
The durable logical specification and the session-scoped runtime binding are visibly distinct.

- Saved breakpoints remain reachable and editable while the debugger is idle, unavailable, running,
  exited, or waiting for an image to load. The compact debugger state exposes a Breakpoints action;
  the sidebar and Debug menu route to the same deck, and returning to Session or Console restores
  the console deck instead of leaving Breakpoints selected.
- The Breakpoints deck uses a native logical-specification list, not address cards. Each parent row
  shows an enable checkbox, exact locator and image scope, textual state, current location count, and
  session hit count. Disclosure shows only positively proven runtime locations and bounded issues.
- Visible aggregate states are `Saved`, `Disabled`, `Pending`, `Bound`, `Multiple locations`, and
  `Error`. Text and symbols carry meaning without color; pending is a normal saved state, not a
  destructive validation error.
- Add/Edit uses one compact native Form for Address, Image Offset, Function, Symbol, and Source
  locators. Behavior uses plain-language `Stop on every matching hit` or `Skip first N matching
  hits`, optional condition, typed log/expression actions, and stop/continue disposition. A valid
  offline save is allowed even when no current runtime location exists.
- One gutter click preserves the discoverable address toggle: it creates or removes an exact
  image-qualified preferred-address specification. The glyph is a derived projection of the logical
  and binding state (`saved`, `disabled`, `pending`, `applying`, `bound`, `multiple`, or `failure`);
  it never becomes a second authoring authority. Shape, text, count badges, help, and VoiceOver all
  carry the state, so color is never the only discriminator.
- Row context menu, Debug menu, Inspector durable section, sidebar count, and gutter all route through
  the same workspace specification operations. Inspector shows durable authored facts only; runtime
  binding detail has one owner in the Breakpoints deck. The Inspector qualifies counts to the exact
  focused image and reports selected-address facts only for exact preferred-address specifications;
  it does not infer function, symbol, source, or image-offset resolution.
- Gutter accessibility includes the action, image-qualified address, saved/binding state, and
  location count. Parent and disclosed rows remain keyboard/VoiceOver reachable. Focus, inactive
  window, Increased Contrast, Reduce Motion, and disabled styling use `AppDesignSystem`.
- Raw LLDB, Python, shell, or multiline debugger command authoring is not presented. Logpoints and
  target-expression capture use the closed typed action model frozen in the WS-21 design.
- Condition, ignore-first, base typed-action, target-expression, and continue-after-actions controls
  are enabled only when both the production debugger capability report and the frozen current-Xcode
  live-proven capability set admit them. Authoring remains available while idle; missing backend
  authority disables creation or mutation of unsupported behavior with an explicit explanation while
  preserving already-saved intent for inspection and explicit deletion.
- The Breakpoints deck, rows, runtime locations, authoring fields, validation, and actions expose
  stable `debugger.logical-breakpoints.*` and `debugger.logical-breakpoint-editor.*` accessibility
  identifiers while retaining meaningful labels and values for VoiceOver.
- Legacy source entries without exact debug-artifact, compilation-unit, file-table, and canonical
  table-path identity remain visible as `Saved, not bindable`; the UI never previews a basename
  guess as a current binding.
- Exact source choices retain their image owner and resolver coordinate. Changing image owner clears
  an incompatible source choice, and submission rejects any cross-image owner/source pairing.
- A catalog-corruption state arms nothing and blocks ordinary save/autosave. The deck offers one
  confirmed `Discard Corrupt Breakpoint Catalog` repair that creates a fresh catalog identity,
  never displays corrupt payload text, and leaves all other workspace analysis intact.
- While a newer active breakpoint catalog is reconciling, Continue, Run to Cursor, and every step
  action are visibly disabled before asynchronous debugger work begins. The gate applies to the
  active image even when another image is focused and clears only after exact stable reducer
  convergence. If unavailable-catalog cleanup fails, Pause and Terminate remain available while all
  resume-capable actions stay quarantined with an explicit explanation.

## WS-22 professional launch and local process attach presentation

WS-22 adds professional local launch and arbitrary eligible same-Mac process attach without adding
a second debugger surface. The existing bottom rail and debugger deck remain the sole owners of
session status and controls. Idle debugger chrome replaces duplicate inline PID fields and the old
inline picker with exactly two actions: `Launch Target…` and `Attach to Process…`.

- `Launch Target…` opens the native launch-profile editor for named profiles targeting either an
  exact workspace image or an explicitly imported file-sealed executable, plus arguments,
  environment overrides, working directory, and bounded standard-I/O policy. Changed imported
  bytes require an explicit reauthorization edit. Launch-only sessions
  may expose Restart and MacScope-owned console input when the current profile and writable pipe are
  valid. Restart always creates a new session identity and visually clears prior runtime authority;
  it is never offered as an implicit detach-and-reattach action.
- `Attach to Process…` opens one native `LocalProcessAttachSheet`, approximately 760–840 points wide
  by 520–600 points high while fitting inside the 1080 × 680 minimum window. Its fixed anatomy is:
  concise local-attach help; one search field and `Eligible`/`All` filter; one Refresh action with a
  last-refreshed or stale label; one dense sortable process table; one selected-process detail
  region; and Cancel/Attach actions. The sheet does not add titlebar, navigator, status-rail, or
  debugger-deck chrome.
- The process table uses native macOS `Table` behavior and flat rows, not cards. Its columns are
  Process, PID, User, Architecture, and Status. Search matches sanitized process name, bounded path,
  displayed user, or numeric PID. Keyboard focus, row selection, hover, and window-inactive
  selection remain visually distinct without reducing technical density.
- Every row exposes an explicit textual eligibility state: `Eligible`, a precise ineligible reason,
  or an unknown/unverified reason. A stale catalog remains readable but is non-attachable and says
  that Refresh is required. Ineligible, unknown, changing, disappeared, or incompletely observed
  processes never present an enabled Attach action. Color and symbols supplement the text but never
  replace it.
- Catalog selection is owned by the complete bounded observation key and discovery generation,
  never by PID, display name, or row position. Refresh preserves selection only when that key is
  unchanged and always invalidates any previously authorized attach identity. The selected row must
  complete the deeper executable/process authorization observation before Attach becomes enabled.
  During that bounded work the details show `Verifying…`; catalog `Eligible` means eligible to enter
  verification, not that attach authority already exists.
  The selected-process details show a bounded canonical path and eligibility explanation;
  unusually long paths preserve their leading identity without displacing actions.
- Attach performs a fresh identity check. While establishing, the exact selected row and progress
  remain visible, catalog mutation is disabled, and the sheet dismisses only after the debugger
  reducer accepts that exact attached session. Identity drift leaves the sheet open, reports that
  the process changed, clears the stale authority, and asks the user to Refresh.
- An admitted session header combines lifecycle state with explicit origin and identity, for example
  `MyApp · PID 4242 · Attached`. Editor focus remains a separate line of identity. If the focused
  image is not a correlated module of the attached process, show a neutral warning without
  retargeting the session, live program counter, breakpoints, or Run to Cursor.
- For an attached session, Detach is the ordinary primary exit action. `Terminate Process…` is a
  visually destructive secondary action and requires a confirmation that names the exact process.
  Attached sessions do not expose Restart or stdin; their unavailable explanations state that
  MacScope does not own how the process was launched or its standard-I/O pipes.
- For a MacScope-launched session, Terminate is the primary terminal action. Restart and bounded
  console input appear only when their exact launch/session authority and the current-Xcode I/O
  capability proof exist. Launched-target detach/leave-running is deferred and is not displayed in
  WS-22. stdout/stderr truncation and closed stdin are visible states rather than silently discarded
  input.
- Detached, terminated, exited, and unknown are distinct visible outcomes. Adapter loss or an
  unproved target disposition disables ordinary transport controls and presents bounded recovery
  such as `Recheck Process`; it never reports that an attached process exited or was killed without
  proof. Any `Forget Session` action is offered only when the underlying safety contract permits it.
- `⌘F` focuses process search, `⌘R` refreshes discovery, arrow keys move table selection,
  Return attaches only the exact current authorized eligible identity, and Escape cancels only
  while no attach is in flight. Stable accessibility identifiers cover sheet, filter, table and rows, selection
  details, Refresh, Attach, session identity, Detach, terminate confirmation, launch profiles,
  Restart, console, and stdin. VoiceOver announces identity, eligibility, stale state, origin, and
  destructive consequences in text.
- All surfaces and states use `AppDesignSystem` semantic roles and remain correct under Light/Dark,
  Increased Contrast, Reduce Transparency, Reduce Motion, keyboard-only operation, and inactive
  windows. No origin, eligibility, progress, selection, or destructive meaning relies on color or
  animation alone.

## DCP-05C native decompiler presentation

- The existing 28-point editor status band is the sole persistent owner of native status and
  Request, Retry, Refresh, and Cancel actions. DCP-05C adds no second toolbar, title band, action
  rail, or decorative header.
- The pseudocode source selector uses a segmented control when horizontal room permits and a compact
  menu at narrow widths. Both variants expose the same `Pseudocode source` label and selected value.
- Native status is rendered from the four independent content, intent, attempt, and notice layers.
  Cached, Truncated, Plain text, Fallback, unavailable, failed, and refresh-with-retained-content
  states remain explicit and do not rely on color or provider diagnostics.
- Native pseudocode uses a read-only selectable AppKit text canvas. Styling comes only from the
  structured token runs and `AppNativePseudocodeTokenStyle`; rendered text is never reparsed.
  Tokens with zero, one, or multiple image-qualified source ranges respectively expose no action,
  direct navigation, or an explicit bounded chooser. Entity details are bounded and nonmutating.
- Comparison is titled `Structural summary` and presents exactly Instructions, Blocks, Edges, and
  Calls. It reports set-based matched/native-only/MacScope-only/uncomparable facts and never treats
  equal aggregate counts as semantic equality.
- Keyboard activation, visible focus, hover, selection, VoiceOver line reading, stable identifiers,
  Increased Contrast, Reduce Transparency, and Reduce Motion are acceptance requirements. Failure
  and accessibility copy comes only from the closed presentation catalog and never includes raw
  provider details, paths, hashes, symbols, authored text, or `String(describing:)` output.
- Installed validation covers complete, truncated, cached, plain-text, fallback, unavailable,
  failed, retry, refresh, cancel, comparison, and selector states at 1080×680 and 1440×840 in Light
  and Dark appearances, including keyboard-only and VoiceOver interaction.

## Visual validation

A major screen or ownership change is accepted only after inspecting the exact
built app, not only a preview or compile result. Exercise at least:

- Light and Dark appearances;
- active and inactive windows;
- standard 1280×780 and supported narrow 1080×680 windows;
- empty, loading, error, loaded, selected, disabled, debugger idle, debugger
  paused, and debugger running states relevant to the change;
- keyboard focus, Increased Contrast, Reduce Transparency, and Reduce Motion;
- the WS-17 two-image colliding-address path in both focus directions; and
- graph selection/multi-selection/minimap plus debugger-owner and breakpoint
  presentation when those surfaces change.

For the reference-derived workbench redesign, installed-app acceptance also
requires:

- full-window Light and Dark screenshots at 1440×840, 1280×780, and 1080×680;
- navigator shown/hidden and inspector shown/hidden independently, with editor
  selection and mode preserved across all four combinations;
- traffic-light clearance, a usable draggable region, and no automatic or
  duplicate navigator toggle, search field, title, or inspector command;
- all four numbered editor modes at every declared breakpoint, with no clipped
  label, overlapping status, or control crossing workspace identity;
- an empty workspace and a loaded workspace proving the prominent top action is
  contextual rather than an always-present imitation of the reference Start
  control;
- a collapsed debugger/status rail and an expanded paused/running debugger
  proving that only one component owns debugger status;
- long workspace, focused-image, function, and symbol names that truncate
  coherently without displacing primary actions;
- a full-window audit that every persistent vertical band has a distinct
  function and that the saturated chrome does not consume unnecessary editor
  height; and
- explicit comparison against the 2026-07-14 reference capture for hierarchy,
  density, semantic status, and pane behavior, without requiring pixel identity
  or importing unrelated product terminology.

Record the built product, configuration, and inspected states in the active
worklog. Do not claim current screenshots or visual proof unless the artifacts
exist and were reviewed from that exact build. If safe app placement or capture
is unavailable, report visual validation as unrun rather than inferring it from
tests.

For the Settings-sidebar and Local AI change, installed-app acceptance additionally requires:

- Light and Dark screenshots at the minimum Settings width and the intended ideal/wide width;
- every category visible without a clipped horizontal selector, duplicate navigation, or an empty
  persistent band;
- a stable window height while switching between the shortest category and the longest category;
- endpoint and unusually long model identifiers that remain distinguishable without overlapping
  status, selection, or refresh controls;
- empty inventory, refreshing, unavailable, incompatible, missing selection, unloaded selection,
  and ready states, with no raw provider payload or private path in visible text;
- full keyboard traversal through the category sidebar, endpoint/timeouts, refresh, and model
  selection with a visible focus ring and no focus loss on refresh;
- VoiceOver labels that announce category, exact model identity, language/embedding kind,
  loaded/unloaded state, selection, readiness, and action outcome without color-dependent wording;
- Increased Contrast, Reduce Transparency, and Reduce Motion inspection, including a static but
  still explicit refreshing presentation under Reduce Motion; and
- screenshots from the exact signed candidate installed in `/Applications/MacScope.app`, with the
  build identity and inspected states recorded in the worklog.

For WS-22 launch and local process attach, installed-app acceptance additionally requires:

- full-window Light and Dark screenshots at 1440 × 840, 1280 × 780, and 1080 × 680 from the
  exact signed candidate, including the attach sheet and expanded debugger deck;
- eligible, ineligible, unknown, stale, refreshing, identity-changed, establishing, attached,
  detaching, detached, permission-denied, and target-disposition-unknown presentations;
- a dense process table with long names and paths, clear selected/focused/disabled/inactive states,
  and no cardified rows, clipped columns, overlapping actions, or sheet overflow at minimum size;
- attached session identity and a focused-image/module mismatch warning that remains legible without
  changing debugger ownership;
- attached Detach as the primary ordinary exit, attached `Terminate Process…` as a confirmed
  destructive secondary action, and no attached Restart or stdin control;
- launched Terminate, launch-only Restart, and bounded console/I/O states only when the current-Xcode
  non-interfering I/O capability proof is accepted; no launched detach/leave-running control;
- keyboard traversal and VoiceOver coverage for search, filter, refresh, table selection, details,
  Attach, Detach, terminate confirmation, launch profiles, Restart, console, and stdin, including
  Increased Contrast, Reduce Transparency, and Reduce Motion states; and
- a complete-window chrome audit proving there remains exactly one titlebar command composition, one
  navigator search owner, one debugger rail/deck owner, and no duplicate PID, attach, session-status,
  navigator, inspector, or search controls.
