#!/usr/bin/env python3
"""Lumen's custom SF Symbols as variable templates (Ultralight-S, Regular-S, Black-S).

Built from Apple's own symbol geometry where possible (exported with the SF Symbols app's
`sfsymbols export`), and otherwise drawn on Apple's stem model: a stroke centred on a fixed
centreline, 2.2 / 7.47 / 14.16 units thick at Ultralight / Regular / Black, measured from
`circle`. Every path has the same commands in all three weights, so the system interpolates.
"""
import math, re, sys, os
sys.path.insert(0, os.path.dirname(__file__))
from svgsym import groups, bbox, curve_bbox

WEIGHTS = ("Ultralight-S", "Regular-S", "Black-S")
STEM = {"Ultralight-S": 2.2, "Regular-S": 7.47, "Black-S": 14.16}
BASE = "square.grid.2x2.svg"


def f(v): return f"{v:.4f}".rstrip("0").rstrip(".")


# ---- path builders (y up is negative, as in the templates) ----

def arc(cx, cy, r, a0, a1, segs, start=True):
    """Cubic arc from angle a0 to a1 (radians, standard math orientation, y flipped)."""
    out = []
    step = (a1 - a0) / segs
    k = 4 / 3 * math.tan(step / 4)
    def pt(a): return (cx + r * math.cos(a), cy - r * math.sin(a))
    def tan(a): return (-math.sin(a), -math.cos(a))
    p = pt(a0)
    if start: out.append(f"M{f(p[0])} {f(p[1])}")
    for i in range(segs):
        b0, b1 = a0 + i * step, a0 + (i + 1) * step
        p0, p1 = pt(b0), pt(b1)
        t0, t1 = tan(b0), tan(b1)
        c0 = (p0[0] + k * r * t0[0], p0[1] + k * r * t0[1])
        c1 = (p1[0] - k * r * t1[0], p1[1] - k * r * t1[1])
        out.append(f"C{f(c0[0])} {f(c0[1])} {f(c1[0])} {f(c1[1])} {f(p1[0])} {f(p1[1])}")
    return out


def circle(cx, cy, r, ccw=True):
    a0, a1 = (0, 2 * math.pi) if ccw else (0, -2 * math.pi)
    return "".join(arc(cx, cy, r, a0, a1, 4)) + "Z"


def ring(cx, cy, r, t):
    """A circular outline: outer contour one way, inner the other."""
    return circle(cx, cy, r + t / 2, True) + circle(cx, cy, r - t / 2, False)


def segments_to_d(start, segs):
    out = [f"M{f(start[0])} {f(start[1])}"]
    for sg in segs:
        if len(sg) == 1: out.append(f"L{f(sg[0][0])} {f(sg[0][1])}")
        else: out.append("C" + " ".join(f"{f(x)} {f(y)}" for x, y in sg))
    return "".join(out) + "Z"


def reverse(start, segs):
    """The same closed outline traced the other way."""
    pts = [start] + [sg[-1] for sg in segs]
    rsegs = []
    for i in range(len(segs) - 1, -1, -1):
        sg = segs[i]; frm = pts[i]
        rsegs.append([frm] if len(sg) == 1 else [sg[1], sg[0], frm])
    return pts[-1], rsegs


def rrect(x0, y0, x1, y1, rad, ccw=True):
    """Rounded rectangle (y0 is the top, smaller y), corners as quarter-circle cubics."""
    rad = min(rad, (x1 - x0) / 2, (y1 - y0) / 2)
    k = 0.5523 * rad
    start = (x1, y0 + rad)
    segs = [
        [(x1, y0 + rad - k), (x1 - rad + k, y0), (x1 - rad, y0)], [(x0 + rad, y0)],
        [(x0 + rad - k, y0), (x0, y0 + rad - k), (x0, y0 + rad)], [(x0, y1 - rad)],
        [(x0, y1 - rad + k), (x0 + rad - k, y1), (x0 + rad, y1)], [(x1 - rad, y1)],
        [(x1 - rad + k, y1), (x1, y1 - rad + k), (x1, y1 - rad)], [(x1, y0 + rad)],
    ]
    if not ccw: start, segs = reverse(start, segs)
    return segments_to_d(start, segs)


def pill_ring(x0, y0, x1, y1, t):
    """A capsule outline on Apple's stem model."""
    h = t / 2
    return rrect(x0 - h, y0 - h, x1 + h, y1 + h, (y1 - y0) / 2 + h, True) + rrect(x0 + h, y0 + h, x1 - h, y1 - h, (y1 - y0) / 2 - h, False)


def polygon_rounded(points, rad):
    """A filled polygon with rounded corners (quadratic-equivalent cubics), counterclockwise."""
    n = len(points)
    out = []
    for i in range(n):
        p0, p1, p2 = points[i - 1], points[i], points[(i + 1) % n]
        def toward(a, b, d):
            dx, dy = b[0] - a[0], b[1] - a[1]; L = math.hypot(dx, dy); return (a[0] + dx / L * d, a[1] + dy / L * d)
        a = toward(p1, p0, rad); b = toward(p1, p2, rad)
        c0 = (a[0] + (p1[0] - a[0]) * 0.55, a[1] + (p1[1] - a[1]) * 0.55)
        c1 = (b[0] + (p1[0] - b[0]) * 0.55, b[1] + (p1[1] - b[1]) * 0.55)
        out.append(("M" if i == 0 else "L") + f"{f(a[0])} {f(a[1])}")
        out.append(f"C{f(c0[0])} {f(c0[1])} {f(c1[0])} {f(c1[1])} {f(b[0])} {f(b[1])}")
    return "".join(out) + "Z"


def subpaths(d): return ["M" + p for p in d.split("M") if p.strip()]


def ellipse(cx, cy, a, b, ccw=True):
    """An ellipse as four cubics (a circle scaled), counterclockwise unless `ccw` is false."""
    d = circle(0, 0, 1, ccw)
    nums = re.findall(r"-?\d*\.?\d+(?:e-?\d+)?", d)
    cmds = re.findall(r"[MCZ]", d)
    vals = iter(float(v) for v in nums)
    out = []
    for c in cmds:
        if c == "Z": out.append("Z"); continue
        n = 1 if c == "M" else 3
        pts = [(cx + a * next(vals), cy + b * next(vals)) for _ in range(n)]
        out.append(c + " ".join(f"{f(x)} {f(y)}" for x, y in pts))
    return "".join(out)


def ellipse_ring(box, t):
    """An elliptical outline whose outer edge is `box`, drawn inward at stem `t`."""
    x0, y0, x1, y1 = box
    cx, cy, a, b = (x0 + x1) / 2, (y0 + y1) / 2, (x1 - x0) / 2, (y1 - y0) / 2
    return ellipse(cx, cy, a, b, True) + ellipse(cx, cy, a - t, b - t, False)


def dome(x0, x1, ytop, ybot, fdx, fdy, k1, k2, ccw=True):
    """A person's shoulders, on Apple's construction (person.svg): a flat base with rounded feet
    rising to a single crown. `fdx`/`fdy` size the feet; `k1`/`k2` shape the shoulder curve."""
    cx = (x0 + x1) / 2
    ys = ybot - fdy
    start = (x0 + fdx, ybot)
    segs = [
        [(x1 - fdx, ybot)],
        [(x1 - fdx + fdx * 0.68, ybot), (x1, ybot - fdy * 0.31), (x1, ys)],
        [(x1, ys - k1 * (ys - ytop)), (cx + k2 * (x1 - cx), ytop), (cx, ytop)],
        [(cx - k2 * (x1 - cx), ytop), (x0, ys - k1 * (ys - ytop)), (x0, ys)],
        [(x0, ybot - fdy * 0.31), (x0 + fdx * 0.32, ybot), start],
    ]
    if not ccw: start, segs = reverse(start, segs)
    return segments_to_d(start, segs)


def apple_dome(path_d):
    """The dome parameters of an Apple person body contour (M L C C C C Z)."""
    n = [float(v) for v in re.findall(r"-?\d*\.?\d+(?:e-?\d+)?", path_d)]
    x0, y0, x1, y1 = curve_bbox(path_d)
    fdx = n[0] - x0
    fdy = n[1] - n[9]
    return x0, x1, y0, n[1], fdx, fdy


def arc_segs(c, r, a0, a1, segs):
    """Cubic segments of a circular arc from angle a0 to a1 (math orientation on flipped y)."""
    d = "".join(arc(c[0], c[1], r, a0, a1, segs))
    v = [float(x) for x in re.findall(r"-?\d*\.?\d+(?:e-?\d+)?", d)]
    start = (v[0], v[1]); out = []
    for i in range(segs):
        q = v[2 + 6 * i: 8 + 6 * i]
        out.append([(q[0], q[1]), (q[2], q[3]), (q[4], q[5])])
    return start, out


def ang(c, p): return math.atan2(-(p[1] - c[1]), p[0] - c[0])


def sweep(a_from, a_to, through):
    """The signed sweep from a_from to a_to that passes `through` (`None`: the shorter way)."""
    pos = (a_to - a_from) % (2 * math.pi)
    if through is None: return pos if pos <= math.pi else pos - 2 * math.pi   # the shorter way
    t = (through - a_from) % (2 * math.pi)
    return pos if t <= pos else pos - 2 * math.pi


def meet(c0, r0, c1, r1):
    """The two intersections of two circles."""
    dx, dy = c1[0] - c0[0], c1[1] - c0[1]; d = math.hypot(dx, dy)
    a = (r0 * r0 - r1 * r1 + d * d) / (2 * d); h = math.sqrt(max(r0 * r0 - a * a, 0))
    mx, my = c0[0] + a * dx / d, c0[1] + a * dy / d
    return (mx + h * dy / d, my - h * dx / d), (mx - h * dy / d, my + h * dx / d)


def region(pieces):
    """A closed region from arcs [(centre, r, from_point, to_point, through_angle, segs)], made
    counterclockwise like the other contours."""
    start = None; segs = []
    for c, r, p, q, through, n in pieces:
        a0 = ang(c, p); a1 = a0 + sweep(a0, ang(c, q), through)
        st, sg = arc_segs(c, r, a0, a1, n)
        if start is None: start = st
        segs += sg
    pts = [start] + [sg[-1] for sg in segs]
    area = sum(pts[i][0] * pts[i + 1][1] - pts[i + 1][0] * pts[i][1] for i in range(len(pts) - 1))
    if area > 0: start, segs = reverse(start, segs)
    return segments_to_d(start, segs)


# ---- the symbols ----

def grid_cells(w):
    """Apple's square.grid.2x2 cell boxes at weight w (outer edges), bottom-right first, and the
    corner radius of its outer contour."""
    cells = groups(os.path.join(HERE, "square.grid.2x2.svg"))[1][w][2]
    boxes = [curve_bbox(subpaths(d)[0]) for _, d in cells]
    radius = {"Ultralight-S": 5.13, "Regular-S": 7.81, "Black-S": 12.79}[w]
    return boxes, radius


def cell_ring(box, rad, t):
    x0, y0, x1, y1 = box
    return rrect(x0, y0, x1, y1, rad, True) + rrect(x0 + t, y0 + t, x1 - t, y1 - t, max(rad - t, 0) + 1.2, False)


def patched_bytes(w):
    """Apple's square.grid.2x2 cells re-stroked on the stem model, the bottom-right one filled:
    three cells, one patched."""
    t = STEM[w]; boxes, rad = grid_cells(w)
    return [rrect(*boxes[0], rad)] + [cell_ring(b, rad, t) for b in boxes[1:]]


def patched_bytes_fill(w):
    """Filled cells, the patched one marked as Apple's square.inset.filled: a rim, a gap, a core."""
    t = STEM[w]; boxes, rad = grid_cells(w)
    x0, y0, x1, y1 = boxes[0]
    rim = t * 0.55; gap = 1.2 + t * 0.25
    patched = cell_ring(boxes[0], rad, rim) + rrect(x0 + rim + gap, y0 + rim + gap, x1 - rim - gap, y1 - rim - gap,
                                                     max(rad - rim - gap, 0) + 1.0)
    return [patched] + [rrect(*b, rad) for b in boxes[1:]]


# Color mix: three discs on a triangle, inside the cap height (top at Apple's -71, base at 0).
MIX_R = 20.4
MIX = [(46.0, -47.5), (32.7, -24.5), (59.3, -24.5)]


def color_mix(w):
    """Three overlapping rings, as Lumen's color mix."""
    t = STEM[w]
    return [ring(x, y, MIX_R, t) for x, y in MIX]


def color_mix_fill(w):
    """Three discs, the front one (bottom left) whole and each one behind it cut back by a gap,
    as Apple's filled multi-person symbols separate their figures."""
    t = STEM[w]; R = MIX_R + t / 2; g = 1.4 + t * 0.28
    a, b, c = MIX
    front = circle(b[0], b[1], R)
    # C less B's disc grown by the gap.
    p1, p2 = meet(c, R, b, R + g)
    right = region([(c, R, p1, p2, ang(b, c), 4), (b, R + g, p2, p1, ang(b, c), 2)])
    # A less both grown discs: its top arc, then down C's grown edge to the cusp, up B's to the start.
    qa = [q for q in meet(a, R, b, R + g) if math.hypot(q[0] - c[0], q[1] - c[1]) > R + g][0]
    qb = [q for q in meet(a, R, c, R + g) if math.hypot(q[0] - b[0], q[1] - b[1]) > R + g][0]
    cusp = min(meet(b, R + g, c, R + g), key=lambda q: q[1])
    assert math.hypot(cusp[0] - a[0], cusp[1] - a[1]) < R, "the cusp must fall inside the top disc"
    top = region([(a, R, qa, qb, math.pi / 2, 4), (c, R + g, qb, cusp, None, 1), (b, R + g, cusp, qa, None, 1)])
    return [front, right, top]


def token(w):
    """A design token: a capsule with a dot and a value line, the line at the stem."""
    t = STEM[w]
    pill = pill_ring(12, -59, 96, -11, t)
    dot = circle(33, -35, 5 + t * 0.45)
    line = rrect(48, -35 - t / 2, 76, -35 + t / 2, t / 2)
    return [pill, dot, line]


def token_fill(w):
    """The capsule filled, its dot and value line cut out of it."""
    t = STEM[w]; h = t / 2
    pill = rrect(12 - h, -59 - h, 96 + h, -11 + h, 24 + h, True)
    dot = circle(33, -35, 5 + t * 0.45, False)
    line = rrect(48, -35 - t / 2, 76, -35 + t / 2, t / 2, False)
    return [pill + dot + line]


def breakpoint_fill(w):
    """A breakpoint tag filled, for tiles: exactly the outline's outer silhouette."""
    t = STEM[w]
    centre = offset_polygon([(8, -62), (68, -62), (94, -35), (68, -8), (8, -8)], -3.735)
    return [polygon_rounded(offset_polygon(centre, t / 2), 8 + t / 2)]


def offset_polygon(pts, d):
    """Each edge moved outward by d (inward when negative), corners mitred."""
    area = sum(pts[i][0] * pts[(i + 1) % len(pts)][1] - pts[(i + 1) % len(pts)][0] * pts[i][1] for i in range(len(pts)))
    sign = 1 if area > 0 else -1
    lines = []
    for i in range(len(pts)):
        (x0, y0), (x1, y1) = pts[i], pts[(i + 1) % len(pts)]
        dx, dy = x1 - x0, y1 - y0; L = math.hypot(dx, dy)
        nx, ny = dy / L * sign, -dx / L * sign
        lines.append(((x0 + nx * d, y0 + ny * d), (dx, dy)))
    out = []
    for i in range(len(lines)):
        (p, r), (q, s2) = lines[i - 1], lines[i]
        den = r[0] * s2[1] - r[1] * s2[0]
        t = ((q[0] - p[0]) * s2[1] - (q[1] - p[1]) * s2[0]) / den
        out.append((p[0] + t * r[0], p[1] + t * r[1]))
    return out


def breakpoint(w):
    """The breakpoint tag as an outline on Apple's stem model, for use beside text."""
    t = STEM[w]
    centre = offset_polygon([(8, -62), (68, -62), (94, -35), (68, -8), (8, -8)], -3.735)
    outer = offset_polygon(centre, t / 2); inner = offset_polygon(centre, -t / 2)
    return [polygon_rounded(outer, 8 + t / 2) + polygon_rounded(list(reversed(inner)), max(8 - t / 2, 1.5))]


def person_parts(seed, w):
    """Apple's person (or person.fill) at weight w: its head's outer box and body's dome."""
    d = groups(os.path.join(HERE, seed))[1][w][2][0][1]
    parts = subpaths(d)
    body = parts[0]
    head = parts[2] if len(parts) == 4 else parts[1]
    return curve_bbox(head), apple_dome(body)


def redaction_bar(head, h):
    x0, y0, x1, y1 = head
    cx, cy, r = (x0 + x1) / 2, (y0 + y1) / 2, (x1 - x0) / 2
    mid = cy - r * 0.04
    return rrect(cx - r * 1.38, mid - h / 2, cx + r * 1.38, mid + h / 2, h / 2), mid


def anonymize(w):
    """Apple's person, re-stroked on the stem model (head and shoulders drawn inward from Apple's
    outer edges), with a solid redaction bar across the eyes."""
    t = STEM[w]
    head, (x0, x1, ytop, ybot, fdx, fdy) = person_parts("person.svg", w)
    body = dome(x0, x1, ytop, ybot, fdx, fdy, 0.407, 0.623, True) + \
        dome(x0 + t, x1 - t, ytop + t, ybot - t, max(fdx - t, 0.8), max(fdy - t, 0.7), 0.33, 0.648, False)
    person = body + ellipse_ring(head, t)
    bar, _ = redaction_bar(head, 6.5 + t * 0.8)
    return [person, bar]


def anonymize_fill(w):
    """Apple's person.fill with the redaction bar across the eyes, cut free of the head by a gap."""
    t = STEM[w]
    head, (x0, x1, ytop, ybot, fdx, fdy) = person_parts("person.fill.svg", w)
    body = dome(x0, x1, ytop, ybot, fdx, fdy, 0.407, 0.623, True)
    bh = 6 + t * 0.5; g = 1.2 + t * 0.25
    bar, mid = redaction_bar(head, bh)
    hx0, hy0, hx1, hy1 = head
    cx, cy, a, b = (hx0 + hx1) / 2, (hy0 + hy1) / 2, (hx1 - hx0) / 2, (hy1 - hy0) / 2
    def cap(y, upper):
        s_ = (cy - y) / b if upper else (y - cy) / b
        th = math.asin(max(min(s_, 1), -1))
        a0, a1 = (th, math.pi - th) if upper else (math.pi + th, 2 * math.pi - th)
        d = "".join(arc(0, 0, 1, a0, a1, 3))
        v = [float(x) for x in re.findall(r"-?\d*\.?\d+(?:e-?\d+)?", d)]
        pts = [(cx + a * v[i], cy + b * v[i + 1]) for i in range(0, len(v), 2)]
        start = pts[0]; segs = [pts[1 + 3 * i: 4 + 3 * i] for i in range(3)] + [[start]]
        area = sum(p[0] * q[1] - q[0] * p[1] for p, q in zip([start] + [sg[-1] for sg in segs], [sg[-1] for sg in segs]))
        if area > 0: start, segs = reverse(start, segs)
        return segments_to_d(start, segs)
    head_top = cap(mid - bh / 2 - g, True)
    head_bottom = cap(mid + bh / 2 + g, False)
    return [body + head_top + head_bottom, bar]


HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "seeds")
SYMBOLS = {"lumen.patchedBytes": patched_bytes, "lumen.colorMix": color_mix, "lumen.token": token,
           "lumen.breakpoint": breakpoint, "lumen.breakpoint.fill": breakpoint_fill, "lumen.anonymize": anonymize}
# Filled forms for tiles: `LumenGlyph.customFillSymbols` lists the ones tiles
# use. Color mix has none: filled, its discs merge into one shape at small sizes (`color_mix_fill`
# is kept for reference).
FILL_SYMBOLS = {"lumen.token.fill": token_fill,
                "lumen.patchedBytes.fill": patched_bytes_fill, "lumen.anonymize.fill": anonymize_fill}
SYMBOLS.update(FILL_SYMBOLS)


def write_template(name, builder, out_dir):
    src = open(os.path.join(HERE, BASE)).read()
    _, base_groups, base_margins = groups(os.path.join(HERE, BASE))
    paths = {w: builder(w) for w in WEIGHTS}
    n = len(paths["Regular-S"])
    # Every weight needs the same paths with the same commands, or interpolation fails.
    for w in WEIGHTS:
        assert len(paths[w]) == n, (name, w)
        for i in range(n):
            a = re.findall(r"[MLCZ]", paths["Regular-S"][i]); b = re.findall(r"[MLCZ]", paths[w][i])
            assert a == b, f"{name} path {i}: {w} differs from Regular"
    style = "\n".join([".defaults {-sfsymbols-draw-reverses-motion-groups:false}", ""] +
                      [f".monochrome-{i} {{-sfsymbols-motion-group:{i}}}" for i in range(n)] + [""] +
                      [f".multicolor-{i}:tintColor {{-sfsymbols-motion-group:{i}}}" for i in range(n)] + [""] +
                      [f".hierarchical-{i}:primary {{-sfsymbols-motion-group:{i}}}" for i in range(n)] + ["",
                      ".SFSymbolsPreviewWireframe {fill:none;opacity:1.0;stroke:black;stroke-width:0.5}", ""])
    src = re.sub(r"<style>.*?</style>", "<style>" + style + "</style>", src, flags=re.S)
    src = src.replace(">Generated from symbol<", f">{name}<")
    body = []
    for w in WEIGHTS:
        left = base_groups[w][0]
        xs = [curve_bbox(d)[2] for d in paths[w]]
        ls = min(curve_bbox(d)[0] for d in paths[w])
        right = left + max(xs) + ls
        src = re.sub(r'(id="left-margin-%s"[^>]*x1=")[\d.\-]+("[^>]*x2=")[\d.\-]+' % w, r"\g<1>%s\g<2>%s" % (f(left), f(left)), src)
        src = re.sub(r'(id="right-margin-%s"[^>]*x1=")[\d.\-]+("[^>]*x2=")[\d.\-]+' % w, r"\g<1>%s\g<2>%s" % (f(right), f(right)), src)
        lines = [f'  <g id="{w}" transform="matrix(1 0 0 1 {f(left)} 696)">']
        for i, d in enumerate(paths[w]):
            lines.append(f'   <path class="monochrome-{i} multicolor-{i}:tintColor hierarchical-{i}:primary SFSymbolsPreviewWireframe" d="{d}"/>')
        lines.append("  </g>")
        body.append("\n".join(lines))
    src = re.sub(r'<g id="Symbols">.*?</svg>', '<g id="Symbols">\n' + "\n".join(body) + "\n </g>\n</svg>", src, flags=re.S)
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, f"{name}.symbolset")
    os.makedirs(path, exist_ok=True)
    open(os.path.join(path, f"{name}.svg"), "w").write(src)
    open(os.path.join(path, "Contents.json"), "w").write(
        '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  },\n  "symbols" : [\n    {\n      "filename" : "%s.svg",\n      "idiom" : "universal"\n    }\n  ]\n}\n' % name)
    return path


if __name__ == "__main__":
    # Usage: Design/symbols/gen.py Sources/LumenUI/Resources/Symbols.xcassets
    # then validate: xcrun actool <catalog> --compile /tmp/x --platform macosx --minimum-deployment-target 14.0
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    open(os.path.join(out, "Contents.json"), "w").write('{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n')
    for name, builder in SYMBOLS.items():
        print("wrote", write_template(name, builder, out))
