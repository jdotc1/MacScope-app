# Lumen architecture

Lumen is a design system for macOS apps. It grew out of MacScope's design system, which worked as
a system and not just a skin: every color has a role, themes are data, and a validator proves that
text stays readable. The same machinery serves any app: MacScope (this repository's `MacScope`
executable) is one client. Lumen has its own visual language; an app keeps or brands it through
themes and metrics.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Home | A Swift package, consumed through Swift Package Manager | No app owns it. Each app pins a version and upgrades on its own schedule |
| Platform | macOS only, macOS 14 minimum | `@Observable` needs macOS 14; `Mutex` (macOS 15) is replaced by `OSAllocatedUnfairLock` |
| Language | Swift 6 language mode, strict concurrency | Modern, data-race-safe Swift |
| Name | Lumen; libraries `LumenTokens`, `LumenUI` and `LumenConformance` (test targets only); executables `lumen-theme` and `LumenCatalog` | Neutral, not tied to an app |

## Layers

```
┌──────────────────────────────────────────────────────────────┐
│ App packs (one per app)                                      │
│   MacScopeTheme: syntax, listing, kinds, graph, debugger…    │
│   (each app: its own roles, branded themes, metrics)        │
├──────────────────────────────────────────────────────────────┤
│ LumenUI  (SwiftUI + AppKit)                                  │
│   theme store · palette environment · scales · density       │
│   components · theme gallery / editor / library · snapshots  │
├──────────────────────────────────────────────────────────────┤
│ LumenConformance  (an app's tests only)                      │
│   themes · layout · shortcuts · coverage · workspace window  │
│   truncation · icon scale · overflow · surface steps         │
│   backlight · visible duplicates · narrow sizing             │
├──────────────────────────────────────────────────────────────┤
│ LumenTokens  (plain Swift, no UI)                            │
│   tokens · specs · packs · registry · themes · validator ·   │
│   export (schema, reference, themes JSON)                    │
└──────────────────────────────────────────────────────────────┘
```

`LumenTokens` has no UI dependency. Command-line tools, tests and build scripts can validate
and export themes without AppKit.

## The model

**Token.** A named color role: `bg.canvas`, `fg.secondary`, `syntax.keyword`. `LumenToken` is an
open type, so apps add roles without editing Lumen.

**Spec.** What Lumen knows about a token (`LumenTokenSpec`):

| Field | Meaning |
|---|---|
| `group` | Where it's listed in the theme editor and the token reference |
| `fallback` | `nil` for a semantic role, which every complete theme defines. Otherwise `.token(x)`, or `.composite(x, alpha:, over:)` for the look of a tint resolved to an opaque, checkable color |
| `surface` | The part of the app whose theme supplies it (see Surfaces) |
| `contrast` | What it must reach as a foreground: `.text(on:)` 4.5:1, `.graphic(on:)` 3:1, or any custom minimum and severity |
| `followsSystemAccent` | Whether it follows the macOS accent color when the app turns that on |
| `summary` | One line for the theme editor and the token reference |

**Pack.** A unit of design system (`LumenPack`) holding:
- tokens and surfaces
- whole themes, such as an app's branded variants
- values for its tokens in themes other packs define (`themeValues`)
- rules
- built-in themes to hide from the gallery (`hidesThemes`)
- tokens moved onto one of its surfaces (`surfaceOverrides`)
- legacy theme-file keys and the tokens they now mean (`renamedKeys`), and retired keys that load
  quietly (`retiredKeys`)

Lumen ships `LumenPack.core`, plus optional `LumenPack.code` (syntax, code and diff roles) and
`LumenPack.chart` (chart series); each app adds one pack, or a few.

**Registry.** An app's complete vocabulary (`LumenRegistry(packs: [.core, .myApp])`). It merges
pack values into the built-in themes, flattens their inheritance, and answers spec, theme, group
and surface lookups. It's immutable and `Sendable`.

**Theme.** JSON with up to four palettes: `light`, `dark`, and their Increase Contrast overlays.
It can `inherits` another theme. Resolution order for a token:
1. the theme's own value
2. the spec's fallback, resolved within the same theme (skipped when the theme isn't the default
   and defines none of the fallback's sources, so a partial theme doesn't derive from borrowed values)
3. the registry's default theme
4. black or white

Unknown keys are kept, so one theme file works across apps; each app just flags the keys it
doesn't know.

**Surface.** Every app has `.window`. An app can add surfaces, such as MacScope's code editor or
a document canvas, and let the user pick a different theme for each. A token resolves through
its surface's theme. That keeps text and the fill under it from the same theme, so the validator's
same-theme checks stay true when the themes differ.

**Rules.** The validator runs four things:
- each token's `contrast` requirements
- an opacity check: any token with contrast requirements must be opaque
- each pack's rules: `LumenVisibilityRule`, `LumenDistinctRule`, `LumenContrastPairsRule` (core text
  on another pack's grounds), `LumenLiftRule` (dark grounds step up as they nest), or
  `LumenCustomRule` for anything else
- unknown-key warnings, with a suggested key (prefix, suffix or a near spelling)

Colors are measured in the theme's own color space: a Display P3 theme is checked in P3, not
clamped to sRGB. Translucent grounds (a 10% white selection tint) are measured as they appear, laid
over the ground that holds them: a sidebar row over the sidebar, a raised hover or selection over
the card, a menu highlight over the menu, anything else over the canvas. Where a role changes on a
raised ground (a keycap or selection inside a card), every contrast pair that uses it is checked
again there.
Increase Contrast is checked where a theme has its own palette for it.

The registry checks its packs when it's built: every fallback names a registered token, no fallback
chain loops, theme ids are unique and every built-in theme's parent exists.

The theme editor, the gallery's badges and import all use the same validator.

## What lives where

| Concern | Lumen core | App pack |
|---|---|---|
| Surfaces, text, borders, accent (including the filled accent), status, window chrome including chrome foregrounds, sidebar accent, the activity background and the title bar glow | ✓ | |
| Optional packs: code and syntax (`LumenPack.code`), chart series (`LumenPack.chart`) | ✓ (opt-in) | uses or extends them |
| Built-in themes Lumen, Midnight, Ultraviolet, Contrast | ✓ (the shared roles' values) | adds values for its own roles; may brand and hide |
| Contrast, visibility, distinctness and lift rule types | ✓ | instantiates them for its roles |
| Store, palette environment, density, motion and scales | ✓ (`LumenUI`) | |
| Generic components: badge, pill, tag, count, section header (`LumenSectionHeader`), property row, empty state (`LumenEmptyState` with `Prominence` `.inline`/`.pane`, `LumenEmptyState.inline(_:ink:leading:padding:)`, `.lumenEmptyMessage`), toolbar button (`LumenToolbarIconButtonStyle`), panel icon button (`LumenPanelIconButtonStyle`, `.lumenPanelIcon`, `isOn:` for a toggled-on accent ink), symbol badge (`LumenSymbolBadge`), button styles (`.lumenPrimary`, `.lumenQuiet`, `.lumenTinted`, `.lumenPlain`) | ✓ (`LumenUI`) | |
| Depth (`LumenElevation`): elevation, glow, tile backlight, raised grounds, ambient wash | ✓ (`LumenUI`) | |
| Layout rules: column minimums (`LumenLayout`), never-truncates and fixed-container marks, wrapping text that stays bounded when a split view measures it narrow (`.lumenWrapsWithoutTruncating`), column overflow, icon roles and icon-only hit areas; offscreen snapshots (`LumenSnapshot`, drawn by `LumenSnapshot.Renderer` `.image` or a never-shown `.window`) | ✓ (`LumenUI`) | marks its own columns and labels |
| Conformance (`LumenConformance`): the checks an app runs at each pin bump | ✓ | runs them in its tests |
| Expressive components: icon tiles and the `hue.*` family, native menu labels, keycaps, the command menu with submenus, settings panes, tabs and sidebar; the welcome window and starfield; toolbar identity, activity status and task cluster; inspector header, sections, rows and toggle; hue swatches and picker; popover content, info button; glyphs, custom SF Symbols (or SF Symbol equivalents) that resolve from `lumen.` names anywhere a `systemImage` goes (with the `menu.*`, `panel.*`, `welcome.*`, `inspector.background` roles) | ✓ (`LumenUI`) | its own hues, if it needs categories beyond the ten |
| Lumen Catalog app (`swift run LumenCatalog`) | ✓ | |
| Theme gallery, editor, library (import, export, trash, live reload) | ✓ (`LumenUI`) | |
| Domain roles: listing rows, object kinds, graph edges, debugger, evidence, terminal (`MacScopeTheme`) | | MacScope |
| Domain components: evidence badge, kind badge glyph map | | MacScope (`MacScopeShell`) |
| Domain glyphs beyond Lumen's families | | registered by each app (`LumenGlyph.register`) |
| Command palette (`LumenCommandPalette`): matching, ranking, recents, scopes picked by pill or typed prefix (`LumenPaletteScope`, an Open Quickly), presentation, View menu item | ✓ (`LumenUI`) | the commands and their scopes |
| Workspace pieces: title bar glow, breadcrumb, panel toggles, bottom panel, panel tabs, filter field and chips, log console, sidebar switcher and sections, document tabs, status bar, new-item button and launch menu, dock zone (with the `titlebar.*`, `layoutToggle.on`, `chip.*`, `field.background` roles) and the Ultraviolet theme | ✓ (`LumenUI`, `LumenTokens`) | |
| Workspace window (`LumenWorkspaceWindow`, `LumenTopBarPlacement`): the window frame, unified top bar, panel regions and toggles; split layout (`LumenSplitLayout.swift`) for a window built from `HSplitView` columns | ✓ (`LumenUI`) | the regions' contents |
| Panel bar and sheets (`LumenPanelBar`, `LumenSheet`): pane headers with a status and actions; sheets with a footer status and primary action | ✓ (`LumenUI`) | |
| Mode switcher (`LumenModeSwitcher`: tiles, pill, underline) and address field (`LumenAddressField`) | ✓ (`LumenUI`) | |
| Workspace layout (`LumenWorkspaceLayout.swift`): split editor panes, each with its own tab bar, tabs dragged between panes; stacked sidebar panes that collapse and share their height | ✓ (`LumenUI`) | the editors and pane contents |
| Search (`LumenSearch.swift`): find panel with replace and scope, results grouped by file, highlighted matches, the input palette and Go To Line | ✓ (`LumenUI`) | the search itself; Lumen draws the results |
| Forms (`LumenForms.swift`, plus the settings row badge in `LumenSettings.swift`): number field, sentence rows, dependent groups, checkbox style and grid, inherited picker, settings card, help button, integration row, switch, list editor, master-detail, flow layout | ✓ (`LumenUI`) | its settings |
| Controls (`LumenControls.swift`): tabbed box, radio group, table with its add/remove footer | ✓ (`LumenUI`) | |
| Editors (`LumenEditors.swift`): pull-down button, slider with ticks and field, combo field, key/value editor, rule editor | ✓ (`LumenUI`) | |
| Pickers (`LumenPickers.swift`): color well and grid, swatch strip and menu label, icon picker, wizard step, field list, permissions grid, managed tool row | ✓ (`LumenUI`) | |
| Data views (`LumenDataViews.swift`): notices, outline controls, ref pills, avatars, history rows, comparison header, diff navigator, floating status, minimap | ✓ (`LumenUI`) | its data (commits, diffs, documents) |
| Tools (`LumenTools.swift`): sidebar pane grid, shortcut recorder, completion list, collection with its controls | ✓ (`LumenUI`) | its completions and items |
| Debugger (`LumenDebugger.swift`): stack frames, registers, console, breakpoints, hex dump, command field, watches, variable tree, process list | ✓ (`LumenUI`) | its debugger model |
| Code (`LumenCodePane.swift`, `LumenListing.swift`, `LumenGraph.swift`): code listing, status strip, line-number ruler, listing rows, branch lanes, string rows, graph nodes and edge badges | ✓ (`LumenUI`) | its code and graph |
| Extras (`LumenExtras.swift`): tab overview, checklist tree, commit composer, font picker, code sample, status row, store item card, carousel, detail header | ✓ (`LumenUI`) | |
| Theme miniature | ✓ generic | may supply its own |

## API naming

The labels below are the rule for new components and for any new initializer. An older label that
differs stays until a breaking release, since renaming it breaks callers.

**The second line.** One name per kind of view:
- `subtitle:` the line under a header's title: `LumenInspectorHeader`, `.lumenPopover` content,
  `LumenSheet`, `LumenToolbarIdentity`, `LumenSidebarHeader`.
- `detail:` the second line of a row or an item in a list: `LumenListRow`, `LumenGraphNode`,
  `LumenCollection` items, completions, palette commands, recent projects.
- `summary:` the description on a card or a settings page: `LumenSettingsPane`,
  `LumenSettingsHeader`, settings categories, `LumenItemCard`, `LumenDetailHeader`.
- `message:` the body of a state or a notice, a sentence or two: `LumenEmptyState`,
  `LumenLoadingState`, `LumenErrorState`, `LumenNoticeCard`, `LumenInfoButton`.

**Actions.** One label per role:
- `perform:` the closure a model value runs: `LumenBarAction`, `LumenTaskAction`, `LumenLaunchItem`,
  palette commands, welcome actions. The value describes the action (title, symbol, shortcut) and
  `perform:` comes last, as a trailing closure.
- `action:` the closure of a view whose only job is to be pressed, as SwiftUI's `Button` has it:
  `LumenNewItemButton`, `.newItemButton`. A parameter that takes a whole action value
  (`LumenBarAction`) is named for its place instead (`primary:`, `secondary:`).
  Known exception, kept until a breaking release: a state's link is `actionTitle:`/`action:` on
  `LumenEmptyState` and `.lumenInspectorEmptyState`, where `LumenLoadingState` and `LumenErrorState`
  use `onCancel:`/`onRetry:`. New API gives a state's link a role label.
- `onX:` an event a view reports, named for the event: `onSelect:`, `onOpen:`, `onClose:`,
  `onDismiss:`, `onToggle:`, `onInstall:`, `onActivate:`.

**Default hue.** A `hue:` parameter defaults to `.accent` for the app's own controls and anything
that marks a choice. Items that stand for documents and files default to `.fgSecondary`, so a list of
files stays quiet (document tabs, overview tabs, search files, checklist nodes). Items that stand for
things outside the app default to `.hueBlue` (references, graph nodes, collection items, recent
projects, processes, the info button). A component with its own identity names it: a managed
tool's orange, a notice's graphite. The New button is one of the app's own controls: it
draws the accent (pass `hue:` or `sparkHue:` for another color). Known exception: `LumenItemCard` and
`LumenDetailHeader` default to `.accent` though they stand for store extensions, outside the app;
pass `.hueBlue` to match `LumenCollectionItem` on the same page.

## Versioning

- Semantic versioning. Adding a token or component is a minor version. Renaming or removing a
  token is a major version, and needs an alias period: the old key keeps resolving for a release.
- The theme file format is versioned separately (`schemaVersion`, currently 1). A newer file loads
  as "needs a newer app" instead of failing silently.
- Built-in values can change in minor versions as long as every built-in still passes the validator
  in every registry that a Lumen test exercises.
- Releases are tagged versions (`v0.1.0`) that apps pin, and [CHANGELOG.md](../CHANGELOG.md) lists each
  one's breaking, visual and validator changes, so moving a pin starts from the changelog. Before
  1.0, a minor version may still carry source changes; they're listed under Breaking.

## Guarantees, enforced by tests

- Every built-in theme defines every semantic role and passes the validator with zero issues.
- Foregrounds (any token with contrast requirements, components included) are opaque: the
  validator rejects translucent values in built-in and imported themes (the rejection is tested
  through the MacScope pack), and the theme editor offers no opacity for them.
  A translucent color in a pack's pair rule is measured composited.
- Lumen's shortcuts are distinct and clear of macOS's own; glyph marks keep 3:1 over their tint
  layer in every tile and text color; selection groups stop at their ends (see KEYBOARD.md).
- Every token appears in exactly one group.
- Export describes every registered token.
- An example app pack (tokens, a surface, theme values, a branded theme, a rule) merges without
  touching core values, and its themes pass the validator.
