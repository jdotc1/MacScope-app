# MacScope Design Brief

## Product character

Precise, calm, technical, dense, and trustworthy.

## Primary workflow and window anatomy

MacScope is a keyboard-first reverse-engineering workbench. A source navigator selects an image
or analysis surface, the central editor presents disassembly, pseudocode, graphs, hex, and terminal
content, and a contextual inspector explains the focused artifact. Toolbars carry window-scoped
actions; secondary authoring actions remain in menus and context menus. The navigator and
inspector are native, independently resizable supporting columns that preserve a readable editor.

## Visual system

- Typography uses the roles in `AppTypography`, with monospaced technical data and restrained
  system text for chrome.
- The editor-mode selector uses 24-point unlit tiles, 13-point labels, and 32-point control
  height. Selection uses a quiet fill and text weight; keyboard focus adds a short underline, never a rectangular outline.
- The active menu bar retains a subtle warm red gradient fading into its existing dark ground.
  This is independent of individual icon backlights; inactive and increased-contrast chrome stay flat.
- Spacing and radii use `AppSpacing` and `AppRadius`; editor rows remain compact and aligned to
  stable columns.
- Design system v4 consolidates component radii at 4/6/8/10/14 points and themed components
  around `DSPill`, `DSBadge`, and `DSPropertyRow`. Legacy radius names forward to the shared
  scale. Color/token implementation authority is `DesignSystem/DSBuiltInThemes.swift` and
  the generated reference in `docs/design/tokens/`, not the historical external token sketch.
- Settings owns native theme import, export/share, safe user-theme removal, live reload and
  explicit load problems. Imported theme files must not overwrite unrelated user data.
- Color is semantic, with the brand accent reserved for selection, focus, and high-authority
  actions. Light, dark, increased-contrast, and inactive-window states must remain legible.
- Materials are system-provided and restrained. Liquid Glass is used only where native window
  chrome supplies it, never as decorative content treatment.
- Interface icons use SF Symbols. The application icon remains an Icon Composer source workflow.
- Dense utility decks adapt without compressing labels into fragments: primary actions remain
  visible, secondary actions use named menus, and narrow layouts move editors into native
  popovers with truthful field widths.

## Primary components and states

NavigationSplitView, toolbars, disassembly and data listings, contextual inspector, sheets,
popovers, terminal, debugger controls, and Settings cover empty, populated, loading, partial,
error, disabled, active, inactive, narrow, and wide states.

The custom 46-point workspace command bar paints its existing themed background through the
native top safe-area inset, producing one continuous surface behind the system traffic lights.
Only background coverage extends: control layout, reserved traffic-light clearance, drag regions,
native window buttons, and the lower content divider keep their existing bounds. Installed visual
regression checks must inspect active and inactive windows in light and dark appearances for an
unintended gray band above the command bar, then verify native close/minimize/zoom and background
dragging. Existing titlebar palette and toolbar layout tests remain the focused native checks;
offscreen toolbar rendering alone does not prove coverage of a real window's native top inset.

## Accessibility requirements

- Every interactive control has a stable identifier, concise label, truthful state, and keyboard
  path. Breakpoint and instruction-row actions remain independent accessibility elements.
- Dense visual rows expose one bounded semantic leaf rather than cascading labels through every
  rendered text fragment. When SwiftUI proxy synthesis is unstable, a childless AppKit
  accessibility leaf may own label, identifier, help, selected state, and press action while the
  visual SwiftUI subtree is accessibility-hidden.
- Accessibility traversal must be finite, crash-free, free of binary contents and private paths,
  and verified against populated as well as empty states.
- Reduced transparency, increased contrast, VoiceOver, full keyboard access, and light/dark mode
  are first-class requirements; visual-only affordances never carry unique meaning.
