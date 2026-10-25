# Changelog

## 0.1.0 — Initial public release

- **MacScope** (`swift run MacScope`): MacScope's interface on synthetic data. The workspace window
  has a navigator, editor modes (Disassembly, Pseudocode, Graph, Hex, Welcome), an inspector and a
  debugger panel, plus an Appearance settings window. It is a design implementation only: no binary
  loading, decompiler, debugger backend, AI, plugins or networking, and nothing persisted beyond
  theme preferences.
- **MacScopeTheme**: MacScope's color pack (domain roles, three built-in themes and rules) on top of
  Lumen's core.
- **MacScopeShell**: the workspace window, built from public Lumen API.
- **LumenTokens**: tokens, packs, registry, themes, validator and export. Plain Swift, no UI.
- **LumenUI**: theme store, palette environment, metrics, density, components, the theme gallery,
  editor and library, and custom SF Symbols.
- **LumenConformance**: design-rule checks for an app's test targets.
- **lumen-theme**: command-line theme validation and reference export.
- **LumenCatalog** (`swift run LumenCatalog`): every component in working windows, menus, inspectors
  and a MacScope workspace window.
- Requires macOS 14+ and a Swift 6.1+ toolchain. Apple frameworks only.
