# App icon

`MacScope/Resources/AppIcon.icon` is an Icon Composer document (Xcode 27 / macOS 27 Liquid Glass
icon). It is the only icon source: `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` resolves to it, and
the system renders every size and appearance (default, dark, clear, tinted) from its layers. There is
no PNG app-icon set; the former `AppIcon.appiconset`, the unused `GeneratedAppIcon` image set and
`Scripts/generate_app_icon.swift` were retired with this design (2026-10-05).

## Design: brace reticle

A scope's crosshair built from pseudocode braces `{ }`, with Lumen's four-point spark at the
center: looking into a binary and recovering its code. Hairline dashed diagonals behind it give the
field a technical-drawing texture. It follows Apple's HIG for app icons: one idea, few filled shapes,
no painted-on highlights or shadows (the system supplies them), and the same features in every
appearance.

Layers, front to back (`icon.json` lists groups front to back):

| Group | Layers | Liquid Glass |
|---|---|---|
| 3 Spark | `3-spark-light.svg`, `3-spark-dark.svg` (dark appearance) | individual, specular, chromatic shadow 60% |
| 2 Reticle | `2-braces.svg`, `2-ticks.svg` (opacity 94%, scale 104%) | combined, refraction 80/70, translucency 35% (dark 12%), chromatic shadow 70% |
| 1 Guides | `1-dashes.svg` (opacity 22%, dark 16%) | glass off, no shadow |

Background: Icon Composer gradient fills, never an image.

| Appearance | Top | Bottom |
|---|---|---|
| Default | `#8B6CF2` | `#4A2CC4` |
| Dark | `#2A2156` | `#100C24` |

Colors are Lumen tokens: the spark is `hue.yellow` (standard `#F1B80F`, Midnight `#FFD321` in dark);
the violet field is Lumen's brand violet. All artwork is outlined vector paths (no strokes or text),
as Icon Composer's guide asks.

## Editing

Open the `.icon` in Icon Composer (Xcode › Open Developer Tool › Icon Composer) and save from there.
Per-appearance values are set with the inspector's scope pop-up (Color / Liquid Glass › Dark). Do not
hand-edit a base key next to its `*-specializations` array: Icon Composer discards the specialization.

Preview any appearance without building:

```bash
"/Applications/Icon Composer.app/Contents/Executables/ictool" MacScope/Resources/AppIcon.icon \
  --export-image --output-file /tmp/icon.png --platform macOS --rendition Dark \
  --width 1024 --height 1024 --scale 1
```

Renditions: `Default`, `Dark`, `ClearLight`, `ClearDark`, `TintedLight`, `TintedDark`. After an icon
change, re-export `docs/brand/app-icon-light.png` and `app-icon-dark.png` (Default and Dark, 256 pt @2x)
for the README.
