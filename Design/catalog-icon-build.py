#!/usr/bin/env python3
"""Lumen Catalog icon concepts as Icon Composer documents (.icon = icon.json + SVG layers).

Flat vector layers only: the system adds Liquid Glass (specular, refraction, translucency,
shadows). Colors are Lumen hues: the standard family for light, Midnight's brighter hues for dark.
Backgrounds are icon.json fills, never images.
"""
import json, os, shutil, sys

STD = dict(violet="#7B5CE6", indigo="#4E5BD8", blue="#2D7FF0", teal="#14A2A6", green="#25A854",
           yellow="#F1B80F", orange="#E47518", red="#EB4848", pink="#E5487F", graphite="#8C8E99")
MID = dict(violet="#A06BFF", indigo="#6F72FF", blue="#3AA2FF", teal="#00CFD1", green="#3FD86B",
           yellow="#FFD321", orange="#FF9A3C", red="#FF4D6D", pink="#FF5CA8", graphite="#7C84A3")


def srgb(hexstr, a=1.0):
    h = hexstr.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},{a:.5f}"


def grad(top, bottom):
    return {"linear-gradient": [srgb(top), srgb(bottom)],
            "orientation": {"start": {"x": 0.5, "y": 0.0}, "stop": {"x": 0.5, "y": 1.0}}}


def svg(body):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
            + body + "</svg>")


def spark_path(cx, cy, r, waist=0.16):
    """A four-pointed spark (the Catalog's sparkles mark) with concave sides."""
    w = r * waist
    return (f"M{cx},{cy - r} C{cx + w},{cy - w} {cx + w},{cy - w} {cx + r},{cy} "
            f"C{cx + w},{cy + w} {cx + w},{cy + w} {cx},{cy + r} "
            f"C{cx - w},{cy + w} {cx - w},{cy + w} {cx - r},{cy} "
            f"C{cx - w},{cy - w} {cx - w},{cy - w} {cx},{cy - r} Z")


def layer(name, image=None, light=None, dark=None, glass=True, opacity=None, **kw):
    d = {"glass": glass, "name": name}
    if image:
        d["image-name"] = image
    else:
        d["image-name-specializations"] = [{"value": light}, {"appearance": "dark", "value": dark}]
    if opacity is not None:
        d["opacity"] = opacity
    d.update(kw)
    return d


def group(name, layers, shadow=0.5, shadow_kind="layer-color", translucency=None, dark_translucency=None,
          lighting="individual", specular=True):
    g = {"layers": layers, "name": name, "lighting": lighting, "specular": specular,
         "shadow": {"kind": shadow_kind, "opacity": shadow}}
    if translucency is None:
        g["translucency"] = {"enabled": False, "value": 0.5}
    elif dark_translucency is None:
        g["translucency"] = {"enabled": True, "value": translucency}
    else:
        g["translucency-specializations"] = [{"value": {"enabled": True, "value": translucency}},
                                             {"appearance": "dark", "value": {"enabled": True, "value": dark_translucency}}]
    return g


def write_icon(path, fill_light, fill_dark, groups, assets):
    if os.path.exists(path):
        shutil.rmtree(path)
    os.makedirs(f"{path}/Assets")
    for name, body in assets.items():
        with open(f"{path}/Assets/{name}", "w") as f:
            f.write(svg(body))
    doc = {"fill-specializations": [{"value": fill_light}, {"appearance": "dark", "value": fill_dark}],
           "groups": groups, "supported-platforms": {"squares": ["macOS"]}}
    with open(f"{path}/icon.json", "w") as f:
        json.dump(doc, f, indent=2)


def two(name, body_fn, light_color, dark_color):
    """Light and dark SVG assets from one shape with a color placeholder."""
    return {f"{name}-light.svg": body_fn(light_color), f"{name}-dark.svg": body_fn(dark_color)}


# A. Spark Glass: the current mark rebuilt as glass. A large spark in front, two small ones behind.
def concept_spark(out):
    big = lambda c: f'<path d="{spark_path(560, 580, 300)}" fill="{c}"/>'
    small = lambda c: (f'<path d="{spark_path(330, 340, 118)}" fill="{c}"/>'
                       f'<path d="{spark_path(470, 210, 76)}" fill="{c}"/>')
    assets = {**two("2-big", big, "#FFFFFF", "#E9DEFF"), **two("1-small", small, "#FFFFFF", MID["violet"])}
    groups = [
        group("2 Spark", [layer("Spark", light="2-big-light.svg", dark="2-big-dark.svg")], shadow=0.55),
        group("1 Sparkles", [layer("Sparkles", light="1-small-light.svg", dark="1-small-dark.svg", opacity=0.9)],
              shadow=0.35, translucency=0.3, dark_translucency=0.15),
    ]
    write_icon(out, grad("#9479F5", "#5233CF"), grad("#2A2156", "#100C24"), groups, assets)


# B. Swatch Fan: three color cards fanned like a swatch book, a spark on the front card.
def card(color, angle, cx=512, cy=600):
    return (f'<g transform="rotate({angle} {cx} {cy + 180})">'
            f'<rect x="{cx - 170}" y="{cy - 290}" width="340" height="480" rx="64" fill="{color}"/></g>')


def concept_swatches(out):
    assets = {}
    for name, hue, angle in (("1-back", "teal", -22), ("2-mid", "pink", -2)):
        assets.update(two(name, lambda c, a=angle: card(c, a), STD[hue], MID[hue]))
    front = lambda c: card(c, 18) + f'<path d="{spark_path(600, 470, 92)}" fill="#FFFFFF" transform="rotate(18 512 780)"/>'
    assets.update(two("3-front", front, STD["violet"], MID["violet"]))
    groups = [
        group("3 Front", [layer("Front", light="3-front-light.svg", dark="3-front-dark.svg")], shadow=0.55),
        group("2 Middle", [layer("Middle", light="2-mid-light.svg", dark="2-mid-dark.svg")], shadow=0.45),
        group("1 Back", [layer("Back", light="1-back-light.svg", dark="1-back-dark.svg")], shadow=0.35),
    ]
    write_icon(out, grad("#F4F2FB", "#DCD7EE"), grad("#1F1B33", "#0C0A17"), groups, assets)


# C. Tile Grid: four component tiles in Lumen hues, the violet one carrying the spark.
def tile(x, y, color, size=300):
    return f'<rect x="{x}" y="{y}" width="{size}" height="{size}" rx="76" fill="{color}"/>'


def concept_tiles(out):
    pos = {"violet": (190, 190), "pink": (534, 190), "teal": (190, 534), "yellow": (534, 534)}
    assets = {}
    for hue in ("pink", "teal", "yellow"):
        assets.update(two(f"1-{hue}", lambda c, h=hue: tile(*pos[h], c), STD[hue], MID[hue]))
    hero = lambda c: tile(*pos["violet"], c) + f'<path d="{spark_path(340, 340, 96)}" fill="#FFFFFF"/>'
    assets.update(two("2-hero", hero, STD["violet"], MID["violet"]))
    groups = [
        group("2 Hero", [layer("Hero", light="2-hero-light.svg", dark="2-hero-dark.svg")], shadow=0.55),
        group("1 Tiles", [layer(h.title(), light=f"1-{h}-light.svg", dark=f"1-{h}-dark.svg") for h in ("pink", "teal", "yellow")],
              shadow=0.4, lighting="combined"),
    ]
    write_icon(out, grad("#F4F2FB", "#DCD7EE"), grad("#1F1B33", "#0C0A17"), groups, assets)


# D. Lens: a clear glass loupe over a strip of color swatches, the Lumen lens idea.
def concept_lens(out):
    stripes = lambda cs: "".join(f'<rect x="{150 + i * 150}" y="300" width="124" height="424" rx="56" fill="{c}"/>'
                                 for i, c in enumerate(cs))
    hues = ("violet", "blue", "teal", "yellow", "pink")
    assets = {"1-swatches-light.svg": stripes([STD[h] for h in hues]),
              "1-swatches-dark.svg": stripes([MID[h] for h in hues]),
              "2-lens.svg": '<circle cx="560" cy="470" r="230" fill="#FFFFFF"/>',
              "3-handle.svg": '<rect x="700" y="640" width="110" height="300" rx="55" fill="#FFFFFF" transform="rotate(-45 755 790)"/>'}
    groups = [
        group("3 Handle", [layer("Handle", "3-handle.svg")], shadow=0.5),
        group("2 Lens", [layer("Lens", "2-lens.svg", opacity=0.55)], shadow=0.35, translucency=0.6, dark_translucency=0.5),
        group("1 Swatches", [layer("Swatches", light="1-swatches-light.svg", dark="1-swatches-dark.svg")], shadow=0.3),
    ]
    write_icon(out, grad("#F4F2FB", "#DCD7EE"), grad("#1F1B33", "#0C0A17"), groups, assets)


CONCEPTS = {"A-SparkGlass": concept_spark, "B-SwatchFan": concept_swatches, "C-TileGrid": concept_tiles,
            "D-Lens": concept_lens}



# Variant of C: the spark becomes its own top glass group so it floats over the violet tile.
def concept_tiles_r2(out, *, tile_translucency=None, dark_tile_translucency=None, bg=("#F4F2FB", "#DCD7EE"),
                     bg_dark=("#1F1B33", "#0C0A17"), hero_scale=1.0, spark_r=96, size=300, gap=44):
    o = (1024 - (2 * size + gap)) // 2
    pos = {"violet": (o, o), "pink": (o + size + gap, o), "teal": (o, o + size + gap), "yellow": (o + size + gap, o + size + gap)}
    cx, cy = o + size // 2, o + size // 2
    assets = {}
    for hue in ("pink", "teal", "yellow"):
        assets.update(two(f"1-{hue}", lambda c, h=hue: tile(*pos[h], c, size), STD[hue], MID[hue]))
    assets.update(two("2-hero", lambda c: tile(*pos["violet"], c, size), STD["violet"], MID["violet"]))
    assets["3-spark.svg"] = f'<path d="{spark_path(cx, cy, spark_r)}" fill="#FFFFFF"/>'
    hero_pos = {"position": {"scale": hero_scale, "translation-in-points": [0, 0]}} if hero_scale != 1.0 else {}
    groups = [
        group("3 Spark", [layer("Spark", "3-spark.svg", **hero_pos)], shadow=0.5),
        group("2 Hero", [layer("Hero", light="2-hero-light.svg", dark="2-hero-dark.svg", **hero_pos)], shadow=0.55),
        group("1 Tiles", [layer(h.title(), light=f"1-{h}-light.svg", dark=f"1-{h}-dark.svg") for h in ("pink", "teal", "yellow")],
              shadow=0.4, lighting="combined", translucency=tile_translucency, dark_translucency=dark_tile_translucency),
    ]
    write_icon(out, grad(*bg), grad(*bg_dark), groups, assets)


VARIANTS = {
    "C2-FloatingSpark": dict(),
    "C3-GlassTiles": dict(tile_translucency=0.35, dark_tile_translucency=0.2),
    "C4-VioletGround": dict(bg=("#EEEAFD", "#CFC6F4"), bg_dark=("#2A2156", "#100C24"), tile_translucency=0.25,
                            dark_tile_translucency=0.15),
}
CONCEPTS.update({n: (lambda out, kw=kw: concept_tiles_r2(out, **kw)) for n, kw in VARIANTS.items()})


if __name__ == "__main__":
    os.makedirs("concepts", exist_ok=True)
    for n in sys.argv[1:] or list(CONCEPTS):
        CONCEPTS[n](f"concepts/{n}.icon")
        print("built", n)
