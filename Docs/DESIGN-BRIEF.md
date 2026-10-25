# MacScope Design Brief

This brief describes MacScope's visual system as implemented in this repository on synthetic data.
Its colors are in `Sources/MacScopeTheme`; the generated token reference is in
[Docs/reference](reference).

## Product character

Precise, calm, technical, dense, and trustworthy.

## Primary workflow and window anatomy

MacScope is a keyboard-first workbench for inspecting compiled code. A source navigator selects an
item, the central editor presents disassembly, pseudocode, graphs and hex (plus a Welcome page), and
a contextual inspector explains the focused item. A debugger panel sits under the editor. Toolbars
carry window-scoped actions; secondary actions remain in menus and context menus. The navigator and
inspector are native, independently resizable supporting columns that preserve a readable editor.

## Visual system

- Typography uses the roles in `LumenMetrics`, with monospaced technical data and restrained system
  text for chrome.
- The editor-mode selector uses 24-point unlit tiles, 13-point labels, and 32-point control
  height. Selection uses a quiet fill and text weight; keyboard focus adds a short underline, never
  a rectangular outline.
- The active menu bar retains a subtle warm red gradient fading into its existing dark ground. This
  is independent of individual icon backlights; inactive and increased-contrast chrome stay flat.
- Spacing and radii use the shared scales in `LumenMetrics` (spacing `s0`...`s11`; radii
  4/6/8/10/14 points). Editor rows remain compact and aligned to stable columns.
- Themed components share one set of shapes: pills, badges and property rows.
- Color is semantic, with the brand accent reserved for selection, focus, and high-authority
  actions. Light, dark, increased-contrast, and inactive-window states must remain legible.
- Themes are data. The Appearance settings window imports, exports and removes user themes, and
  reports load problems. Imported theme files are validated before use.
- Materials are system-provided and restrained. Liquid Glass is used only where native window
  chrome supplies it, never as decorative content treatment.
- Interface icons use SF Symbols, plus Lumen's custom symbols where SF Symbols has none. The
  application icon is described in [brand/APP-ICON.md](brand/APP-ICON.md).
- Dense utility decks adapt without compressing labels into fragments: primary actions remain
  visible, secondary actions use named menus, and narrow layouts move editors into native popovers
  with truthful field widths.

## Primary components and states

NavigationSplitView, toolbars, disassembly and data listings, contextual inspector, sheets,
popovers, the debugger panel, and Settings cover empty, populated, loading, partial, error,
disabled, active, inactive, narrow, and wide states.

The workspace command bar paints its themed background through the native top safe-area inset,
producing one continuous surface behind the system traffic lights. Only background coverage extends:
control layout, reserved traffic-light clearance, drag regions, native window buttons, and the lower
content divider keep their bounds. Offscreen rendering alone does not prove coverage of a real
window's native top inset, so `LumenConformance.workspaceWindow` checks a real window.

## Accessibility requirements

- Every interactive control has a stable identifier, concise label, truthful state, and keyboard
  path. Breakpoint and instruction-row actions remain independent accessibility elements.
- Dense visual rows expose one bounded semantic leaf rather than cascading labels through every
  rendered text fragment.
- Accessibility traversal must be finite and verified against populated as well as empty states.
- Reduced transparency, increased contrast, VoiceOver, full keyboard access, and light/dark mode
  are first-class requirements; visual-only affordances never carry unique meaning. Keyboard and
  pointer behavior is documented in [KEYBOARD.md](KEYBOARD.md).
