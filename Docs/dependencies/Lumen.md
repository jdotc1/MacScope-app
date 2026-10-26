# First-party Lumen package

- Owner: MacScope contributors; first-party private package, explicitly authorized2026-10-03.
- Canonical repository: https://github.com/jdotc1/Lumen.git
- Immutable commit: 9a8b6e0efd22881afc3c48f307b05afb15669dea (v0.56.2)
- Integration: Git submodule ThirdParty/Lumen; local Swift package in project.yml.
- Products: LumenTokens, LumenUI and LumenConformance (U5g; linked by the app so hosted CoreTests share one copy), app and CoreTests only; no worker targets.
- External license/notice obligations: not applicable to this owner-authored first-party adoption.
- Local package modifications: none. MacScope-specific roles, validation and compatibility stay in MacScope.

## Materialization and qualification

Explicit preparation uses `Scripts/dependencies/materialize_lumen_submodule.py`
with `--source-root` and the verified `--seed-repository Lumen`.
The pin is the committed gitlink: a pin bump changes only the gitlink, this
file and `FIRST_PARTY_COMPONENTS.json`. The script validates the tracked gitlink
and .gitmodules URL and imports exact objects offline. A physically clean
checkout at another published Lumen commit (one the seed also has) is moved to
the pin; dirty, index-flagged or unpublished content is preserved and rejected.
Xcode/SwiftPM state the Lumen .gitignore excludes (`.swiftpm/`, `.build/`) is
regenerable, not content: when it is the only difference it is removed first.
Build stations run this through `Scripts/station.sh sync` (on `claim`, and from
`Scripts/dev_loop.sh` before each build) whenever the checkout differs from the
gitlink, because `git switch` never moves the submodule. Ordinary
bootstrap, build, test and source export never acquire sources over the network.

The sealer exports canonical package blobs. Source metadata retains the pinned
commit object, tree and canonical URL, reconstructs the package tree, then
reconstructs the parent tree with that gitlink. A Git-less qualified source can
therefore build the local package without Git, the original checkout or network.
The package's source minimum is macOS14 and Swift tools6.1; the MacScope product
continues to require macOS27 arm64 with Xcode27 and Swift6 language mode.

## Compatibility and rollback

2026-10-19: Pin v0.56.2 `9a8b6e0efd22881afc3c48f307b05afb15669dea`; adds the pre-macOS-27 Catalog native split, quiet-button minimum hit width, fixed-width hex cells, settled conformance rendering, and optional upstream test performance-budget scaling. No MacScope source changes.

2026-10-17: Pin v0.56.1 `01cbc9fc202a6e9540ed6596168c77b8711f2bdb`; release approved by the maintainer, matching the local v0.56.1 tag. Includes the hidden-sidebar backlight conformance fix.

2026-10-17: D22 lifted by the maintainer; v0.56.0 d61f689, MacScope parity complete per Lumen's outcome matrix.

2026-10-12 (build round 2, U0): the pin advances from v0.2.1
`52b3be1e63b698da4bce6864a4d2a7a9c55e527f` to v0.28.0
`a1f50835c10f6da5f475989dfbccbbe43ded93b0` (tree
`1f734dd7f5bbc1ee112c5499634ffa8171309859`). MacScope's registry now includes
Lumen's code pack as `LumenPack.codeForMacScope`: the nine shared `syntax.*`
roles (keyword, type, function, variable, string, number, comment, operator,
punctuation) are registered by the code pack, MacScope's themes keep their
values, every code-pack role draws on the editor surface, and MacScope keeps the
checks it had for those roles (text on the canvas, punctuation on every listing
row ground, its pseudocode distinct rule) in place of the code pack's
current-line contrast and kinds-of-code distinctness. Core themes stay hidden
(`hidesThemes`). Midnight's accent-vs-danger warning (Lumen 0.6.0) is a named
legacy exception in the pack and theme-editor tests. UI swaps from
`Docs/adoption/MacScope-parity.md` are separate work (U1-U5). Rollback reverts
the pin-bump commits.

2026-10-13 (D22 exception, Tier 2h RED): v0.42.2 `c9a9d0d84ea30e2484977ec131208799a411c8df` (tree `d8608cc05bd6e61c4f7ac2255d0519f51c9b871a`; 0.42.1 plus Lumen's rulings on MacScope's three reports: hidden regions don't report, scale-to-fit within `minimumScaleFactor` isn't truncation, text within two characters of the 8-character floor shows in full). Fixes the Types inspector
clipping: a LumenTable never grows past its container and column minimums yield when there is no room
(Lumen's LumenTableFitsItsContainerTests). Carries 0.42.0: elevation, field style, glows and backlit
tiles, Midnight violet, amber warning tint, 28 pt sidebar section tiles , density rows,
and LumenTableText's 8-character floor. #458's stopgap minimums (60 pt) return to the rule's 72 pt.

2026-10-13 (U10-7): v0.41.1 `7acb81ff9524a2707947bb7c7b6c77180de4faea` (tree `497aabf26848cfc33dc00dcc04b0c59d966156e7`). `lumen.*` symbols draw as outlines beside
text (LumenSymbol, badges, rows) and filled in LumenIconTile (`.symbolVariant(.fill)`, plus
`lumen.breakpoint.fill`); tiles are unchanged, kind badges return to a consistent outline row. No
API change.

2026-10-12 (U10-1b): v0.41.0 `5805205e1fc71b6a092606a0b71edf44ec135b63` (tree `9294e5f95ab72cbb1aa72ef41f5d43f45ae08916`). Every `lumen.*` glyph draws as an SF
Symbol in `LumenSymbol` and `LumenIconTile`: five custom symbols (patchedBytes, colorMix, token,
breakpoint, anonymize) from LumenUI's new asset catalog, shipped as the `Lumen_LumenUI.bundle`
resource bundle the app embeds, and SF equivalents for the rest (axialSlice →
circle.and.line.horizontal.fill). No API change; goldens showing these glyphs move slightly.

2026-10-12 (U10-1, D17): v0.40.0 `e49a778b4f6a8209bd40b46e32687d275e8d0669` (tree `797972fa9b9bb7c91918e6f7d9fbe8aa1628ce60`), for the reviewed
four visual issues. Icon tiles are redrawn from SF Symbols at 64% of the tile (light: hue gradient with
a white symbol; dark: slate tile with the symbol in its hue; soft rim, no shadows), sidebar switcher
tiles and inspector section tiles are 28 pt, mode tiles full color, and glyphs under 24 pt draw no
tint layer. New: `LumenTableColumn` `.minWidth`/`.priority`/`.header`, table-wide widths with tail
truncation and help tags, rows as separate AX elements, the browse-only `LumenSheet(..., done:)`,
tile metrics on `LumenMetrics.Layout`, and the `iconScale` and `surfaceSteps` conformance checks.
MacScope goldens move with the tiles; re-recorded only where the pin changed them, after Lumen's review.

2026-10-12 (round 3, U8-3, second bump): v0.39.4 `8ead598182958309d7b61b8e215054139cf56e84` (tree `a4d6bd5b1908ca27eb9e225cdb2025aecef53682`). `LumenPopUp` is
never narrower than its widest option (`width:` becomes a minimum), and `LumenRuleEditor` sizes its
comparison pop-ups to the widest operator, so "doesn't contain" is no longer cut short (found by
MacScope's rule-editor truncation check). Lumen's editors golden moved and was reviewed there.

2026-10-12 (round 3, U8-3): the pin advances from v0.39.2 to v0.39.3 `4eb6600191288dd5f220a6e4850e89356428c698` (tree
`19c82625c402c9a6d1dccdd77dddb32c1de31779`). Lumen marks its remaining one-line primary labels `.lumenNeverTruncates` (badges,
section headers, tabbed-box tabs, table headers, pop-up titles, command palette and detail headers,
master-list items, the font picker's family); `LumenSheet` titles stay unmarked because they wrap.
No visual change.

2026-10-12 (round 3, U8-1, after the reviewed screenshot of the installed U8-0): the pin advances from
v0.39.1 to v0.39.2 `a4b0e1ea37b37a7592d492a77e514d97da5302ac` (tree `60cee1c9459906e74b2d7943887e9c5e1becc911`). The top bar becomes a real row (an
AppKit split view ignored the SwiftUI safe-area inset and drew the tool rail and headers under it),
`LumenConformance.workspaceWindow` also checks that no region starts under the bar, and 0.39.2 adds
`.columnWidths(sidebar:inspector:)`, `.panelShortcuts(_:)`, `.lumenNeverTruncates` and
`LumenConformance.truncation(sizes:of:)`.

2026-10-12 (round 3, U8-0, after the maintainer review of the 17:06 install): the pin advances from v0.38.2
to v0.39.1 `ea49c2aaf7d6c9a197457c6e5b02010eb4daede1` (tree `b5f362f101d45e7fb52e4de90b404b2549a0d336`); 0.39.1 adds `LumenWorkspaceWindow.bottomPanelToggle(_:)` for a bottom panel the content draws
itself (MacScope's deck stays in the editor surface). 0.39 adds `LumenWorkspaceWindow`
(top bar pinned in the top safe area, every region clipped, left/bottom/right panel toggles with
⌃⌘S/⇧⌘Y/⌥⌘I, the `.falling` ambient wash), `LumenConformance.workspaceWindow` (the top bar must
not move or change height across 8 panel combinations at 900×560 and 1440×900), a readable
`LumenModeSwitcher` in a top bar (layout priority, 22 pt tiles, labels when there is room), the
restored `LumenEmptyHero` starfield lean and surge, and the public `.lumenRendersOffscreen(_:)`.
MacScope adopts the window in the same change (`WorkspaceRootView`).

2026-10-12 (round 3, after U6b): the pin advances from v0.38.1 to v0.38.2
`7312b73d254211abce23e0974d1659986d4036e2` (tree `9bdfda4e17a789c0801a93c09c4c78fbb3f1a3b9`). This also repairs main: #359 (a heavy-gate
script change) had accidentally committed the gitlink back to v0.37.0 while these records still
named v0.38.1. 0.38.2 comes from the Lumen session's live check of MacScope: `LumenTextField` is
added; `LumenThemeGallery`'s editor-theme choice becomes a Lumen pop-up and `LumenCodeFontPicker`
uses a Lumen pop-up and number field (visual, no MacScope code change).

2026-10-12 (round 3, U5e): the pin advances from v0.37.1 to v0.38.1
`7a56c3265c60555965cb32d36ee94926c2764b7b` (tree `682a53e13d9206f71fb8cf9e416ab658404b0106`). 0.38 is the polish release: fields, pop-ups and
pull-downs are 22 pt with `border.default`, cards are solid `bg.elevated` with `border.subtle`,
and custom menu labels render live as drawn. 0.38.1 adds `LumenPack.retiredKeys`: MacScope's
pack retires `graph.edge.*` and `welcome.accent` (U5e) so theme files that still carry them load
without warnings. Goldens that move with 0.38 were reviewed by the Lumen session separately from
U5e's own before re-recording.

2026-10-12 (round 3, U5d-2): the pin advances from v0.37.0 to v0.37.1
`ba1e0ab096a208dbba6619c81ba297a45663ce5b` (tree `589900f06bc487751221a25a8a1efdd476190f41`). Visual: `LumenThemeMiniature`
draws a short code strip in the theme's syntax colors, with the current line and
selection, when the registry includes `.code` (MacScope's does). The
`theme-miniatures` golden changes; it was re-recorded after the Lumen session's review.

2026-10-12 (round 3, UF-3): the pin advances from v0.34.3 to v0.37.0
`567d9130b37ffc55628bd06ce5e291c8b0e78419` (tree `481cb8e4e2b04c7dc01a768ab98cd3b4b1bdf10f`). Additive only, with
no Breaking or Visual entries in 0.35-0.37; the new components (rule editor,
table, permissions grid and others) are post-U5 candidates. U5 starts from this
release.

2026-10-12 (round 3, UF-1): the pin advances from v0.34.2 to v0.34.3
`2fb0a6054c246ad25868ca16f13cc52f721bc1eb` (tree `f1bf64f6a88b157a7c9290903cfd2335e5f76e1c`). Additive only:
identifiers, help and spoken status on `LumenStatusStrip` (jdotc1/Lumen#4),
identifiers on `LumenSheet`'s Cancel and primary buttons, and a read-only
`LumenConsole(lines:prompt:)`, so MacScope's composed strip, sheet buttons and
console use the Lumen components directly.

2026-10-12 (round 3, U1b): the pin advances from v0.34.1 to v0.34.2
`2a161077db73bd1c9f9c2fed79ee597ba0af716b` (tree `a91ee8fefce35f370919e14b0dcef5b9d58cd27a`). Additive only:
accessibility identifiers on `LumenSidebarItem`, `LumenBarAction` and
`LumenEmptyHero` (jdotc1/Lumen#3) and `LumenEmptyHero(primaryIsDefault:)`, so
the navigator tool rail and the empty workspace use the Lumen components
directly while keeping MacScope's UI-test identifiers.

2026-10-12 (round 3): the pin advances from v0.28.0 to v0.34.1
`3ebe41498b80ea0125d5878aa12a51056767d288` (tree `5284575fccc5f71b0f80aeeb298bd0d92c979b29`). Lumen fixed the empty-state action
layout in 0.34.1: since 0.4 the `.lumenPlain` action's 24 pt minimum hit area
added height, moving the link 4.5 pt down and re-centring the stack, which made
`DSSnapshotTests` differ on `empty-state-action` in all five themes (3.0-3.4%
of pixels). The hit area now overhangs instead of adding height, so the
existing goldens stand and were not re-recorded. 0.29-0.34 are additive.

Earlier history:

The owner explicitly authorized the 2026-10-05 lazy command-palette correction
and pin update. This advances the first-party package from
`d26ebb3f698f4d7a7ab9b83456cdac635e85bcf0` to
`52b3be1e63b698da4bce6864a4d2a7a9c55e527f`, whose canonical tree is
`22006857a8f892a172e159ec57334cfe52f2bfb0`. Normal palette results use
`LazyVStack`; offscreen snapshots retain eager layout. Stable command-row IDs,
selection, scroll targeting, focus and accessibility paths are retained.
No app/worker authority or external dependency is added.

Isolated Lumen package validation passed all 6 command-palette tests, including
native offscreen 500-row lazy/eager materialization and filtered selection checks,
and the existing command-palette golden test without re-recording. MacScope
source-bound build and installed interaction acceptance remain separate gates;
the package results do not claim those gates passed.

Offline preparation moves a physically clean checkout of a published Lumen
commit to the committed pin (2026-10-12: the previous-pin constant and its
`--upgrade-approved-previous-pin` flag were removed). Rollback reverts this isolated pin-update commit and returns the
gitlink, authorization, first-party inventory and materializer to their previous
revision. Preserve preferences and theme files; no settings cleanup is required.

MacScope preserves its110 token roles, existing theme IDs, editor/window theme
isolation and themes directory. All core themes, including Ultraviolet, remain
hidden from MacScope's gallery and available for inheritance. Legacy settings
migrate once without replacing already-set Lumen preferences. MacScope keeps
final-v5 contrast/opacity protections and runs the pinned package's additional
core readability checks. The generic package receives no app
analysis, shell, network, persistence or worker authority.

Phase 2A advances only the dependency pin from
`58cee5e8fdbf069e28ff87999fc910a57ed599d4`. Its upstream changes include a
24 × 24 pt property-row copy-button hit area, SF-symbol rendering through
`LumenSymbol`, and additional core contrast checks, including disabled text and
toolbar buttons at 2:1. New core roles use their fallbacks; none of MacScope's
110 token values change. This tranche does not adopt glyph, menu, command-palette
or workspace-layout features. Native compatibility tests and affected snapshots
must establish the result before acceptance; snapshots are reviewed before any
re-recording.

Phase 2A rollback reverts its isolated commit, restoring the gitlink, materializer,
first-party inventory and documented pins to the prior revision. Preserve user
preferences and theme files when rematerializing the prior exact pin.

Rollback reverts the isolated adoption commits and returns to v5 DS sources.
Retain old and migrated preferences and all user theme files; no destructive
settings cleanup is part of adoption. Existing v5 Release artifacts remain
available as a recovery point. Acceptance evidence will be recorded after
source-bound tests, Release and affected installed-window checks, not inferred
from the package's older extraction parity report.
