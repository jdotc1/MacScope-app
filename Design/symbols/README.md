# Lumen's custom SF Symbols

`gen.py` writes LumenUI's custom symbols (`Sources/LumenUI/Resources/Symbols.xcassets`) as SF Symbols
variable templates: Ultralight-S, Regular-S and Black-S, which the system interpolates into every
weight. They're built from Apple's own symbol geometry where possible (the seed templates in
`seeds/`, exported with `"/Applications/SF Symbols.app/Contents/Executables/sfsymbols" export
<name> --format svg`), and otherwise drawn on Apple's stem model: a stroke centred on a fixed
centreline, 2.2 / 7.47 / 14.16 units thick, measured from `circle`. Every outline symbol uses that
one stem: the Apple-derived ones keep Apple's outer edges and draw inward at the stem. The script refuses to write a
symbol whose paths differ in commands between weights, since those can't interpolate.

| Symbol | Built from |
|---|---|
| `lumen.patchedBytes` | `square.grid.2x2`'s cells, re-stroked at the stem, the bottom-right one filled |
| `lumen.colorMix` | three rings on Apple's stem model |
| `lumen.token` | a capsule ring, a dot and a value line on Apple's stem model |
| `lumen.breakpoint` | an arrow-tipped breakpoint tag, as an outline on Apple's stem model |
| `lumen.breakpoint.fill` | the same tag filled, for tiles (`.symbolVariant(.fill)` picks it) |
| `lumen.token.fill`, `lumen.patchedBytes.fill`, `lumen.anonymize.fill` | filled forms for tiles: the capsule with its dot and line cut out, the patched cell as `square.inset.filled`, `person.fill` with the bar cut free of the head. Color mix has no filled form; it stays an outline on tiles because its filled discs merge at 16–20 pt (`color_mix_fill` in gen.py is kept for reference only) |
| `lumen.anonymize` | `person`'s outer edges, re-stroked at the stem, with a redaction bar across the eyes |

Regenerate, then validate with Apple's asset compiler:

```bash
python3 Design/symbols/gen.py Sources/LumenUI/Resources/Symbols.xcassets
```
