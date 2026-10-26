#!/usr/bin/env python3
"""Hard-coded styling audit for MacScope (read-only).

Usage: python3 Scripts/design/style_audit.py <MacScope source root> [--json out.json]

Used by Scripts/design/style_ratchet.py, which fails when hard-coded styling grows.

Scans every *.swift file under the root except Tests/, LocalPackages/ and ThirdParty/.
Lines marked `// ds-allow: <reason>` (or the line above) and files marked
`// ds-allow-file: <reason>` are reported as allowed rather than hard-coded.
Comments and string-literal contents are blanked (offsets preserved) before matching,
so commented-out code and user-facing strings never count. Tests/ is scanned separately
only for design-token reference counts.
"""
from __future__ import annotations

import bisect
import collections
import json
import os
import re
import sys

EXCLUDED_TOP = {"Tests", "LocalPackages", "ThirdParty"}

HUES = r"(?:red|blue|green|orange|yellow|purple|pink|gray|grey|cyan|mint|teal|indigo|brown|black|white)"
SYSTEM_HUES = r"(?:Red|Blue|Green|Orange|Yellow|Purple|Pink|Gray|Teal|Indigo|Mint|Cyan|Brown)"
NUM = r"-?\d+(?:\.\d+)?"
NUM_TOKEN = re.compile(r"(?<![\w.])-?\d+(?:\.\d+)?(?![\w.])")
DESIGN_TOKEN = re.compile(
    r"\b(?:App[A-Z]\w*|MacScope(?:Brand|Surface)|SyntaxPalette|\w+Chrome|ListingFontPreference)\b"
)

# ---------------------------------------------------------------------------
# Lexing: blank comments and string contents, preserving offsets and newlines.
# ---------------------------------------------------------------------------

def clean_source(src: str) -> str:
    out = list(src)
    n = len(src)
    i = 0
    mode = "code"
    kind = '"'
    hashes = 0
    bdepth = 0
    frames: list[list] = []  # interpolation frames: [paren_depth, kind, hashes]

    def blank(a: int, b: int) -> None:
        for k in range(a, min(b, n)):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        c = src[i]
        if mode == "code":
            if c == "/" and src.startswith("//", i):
                mode = "line"
                continue
            if c == "/" and src.startswith("/*", i):
                mode = "block"
                bdepth = 1
                blank(i, i + 2)
                i += 2
                continue
            if c in '#"':
                m = re.match(r'(#*)("""|")', src[i : i + 12])
                if m:
                    hashes = len(m.group(1))
                    kind = m.group(2)
                    i += len(m.group(0))
                    mode = "str"
                    continue
            if frames:
                if c == "(":
                    frames[-1][0] += 1
                elif c == ")":
                    frames[-1][0] -= 1
                    if frames[-1][0] == 0:
                        _, kind, hashes = frames.pop()
                        mode = "str"
                        i += 1
                        continue
            i += 1
            continue
        if mode == "line":
            if c == "\n":
                mode = "code"
            else:
                out[i] = " "
            i += 1
            continue
        if mode == "block":
            if src.startswith("/*", i):
                bdepth += 1
                blank(i, i + 2)
                i += 2
                continue
            if src.startswith("*/", i):
                bdepth -= 1
                blank(i, i + 2)
                i += 2
                if bdepth == 0:
                    mode = "code"
                continue
            if c != "\n":
                out[i] = " "
            i += 1
            continue
        # string mode
        close = kind + "#" * hashes
        if src.startswith(close, i):
            i += len(close)
            mode = "code"
            continue
        esc = "\\" + "#" * hashes
        if src.startswith(esc, i):
            j = i + len(esc)
            if j < n and src[j] == "(":
                blank(i, j)
                frames.append([1, kind, hashes])
                mode = "code"
                i = j + 1
                continue
            blank(i, j + 1)
            i = j + 1
            continue
        if kind == '"' and c == "\n":  # unterminated single-line string: recover
            mode = "code"
            i += 1
            continue
        if c != "\n":
            out[i] = " "
        i += 1
    return "".join(out)


def matching_paren(text: str, open_idx: int) -> int:
    depth = 0
    for k in range(open_idx, len(text)):
        ch = text[k]
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
            if depth == 0:
                return k
    return -1


def split_top_level(args: str) -> list[str]:
    parts, depth, cur = [], 0, []
    for ch in args:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    parts.append("".join(cur))
    return [p.strip() for p in parts]


def numeric_literals(expr: str) -> list[str]:
    return NUM_TOKEN.findall(expr)


# ---------------------------------------------------------------------------
# Detectors. Each yields (offset, subkind, value) tuples.
# ---------------------------------------------------------------------------

RE_SWIFTUI_RGB = re.compile(r"(?<![\w])Color\(\s*(red|white|hue|\.sRGB|\.sRGBLinear|\.displayP3)\s*[:,]")
RE_APPKIT_RGB = re.compile(
    r"(?<![\w])(NSColor\(\s*(?:calibratedRed|red|srgbRed|deviceRed|displayP3Red|calibratedWhite|white|deviceWhite|"
    r"genericGamma22White|calibratedHue|hue|deviceHue|deviceCyan)|CGColor\(\s*(?:red|srgbRed|gray|genericGrayGamma2_2Gray))\s*:"
)
RE_CG_CONTEXT = re.compile(r"\bset(?:Fill|Stroke)Color\(\s*(gray|red)\s*:")
RE_CUSTOM_RGB = re.compile(r"(?<![\w])((?!NS|CG|UI)[A-Z]\w*Color)\(\s*red:\s*" + NUM)
RE_HEX = re.compile(r"(?<![\w])(?:Color|NSColor)\(\s*hex\b|\b(?:light|dark|rgb|hex|color)\s*:\s*0x[0-9A-Fa-f]{6}\b")
RE_COLOR_HUE = re.compile(r"(?<![\w])Color\.(" + HUES + r")\b")
RE_DOT_HUE = re.compile(r"(?<![\w.)\]])\.(" + HUES + r")\b")
RE_NSCOLOR_HUE = re.compile(r"(?<![\w])NSColor\.(" + HUES + r"|darkGray|lightGray|magenta)\b")
RE_SYSTEM_HUE = re.compile(r"(?<![\w])(?:NSColor)?\.(system" + SYSTEM_HUES + r")\b")
RE_APPKIT_SEMANTIC = re.compile(r"(?:nsColor:\s*|NSColor)\.(\w+Color)\b")
RE_OPACITY = re.compile(r"\.opacity\(")
RE_ALPHA = re.compile(r"withAlphaComponent\(\s*(" + NUM + r")|\balpha:\s*(0?\.\d+|0)\b")

TOKEN_RECEIVER = re.compile(r"(?:AppSemanticColor|MacScopeBrand|MacScopeSurface|SyntaxPalette|AppInteractionChrome)\.\w+(?:\([^()]*\))?\s*$")
COLOR_RECEIVER = re.compile(
    r"(?:(?<![\w])Color\.\w+|NSColor\.\w+|(?<![\w])\.(?:" + HUES + r"|primary|secondary|tertiary|quaternary|quinary|accentColor|tint)|"
    r"(?<![\w])(?:Color|NSColor)\([^()]*(?:\([^()]*\))?[^()]*\)|\w*[cC]olor\w*|\bforeground|\bfill|\bstroke|\btint)\s*$"
)

def constructor_args(text: str, start: int) -> str:
    open_idx = text.find("(", start)
    close = matching_paren(text, open_idx)
    return text[open_idx + 1 : close] if close > 0 else ""


def is_data_driven(args: str) -> bool:
    """True when colour components come from variables (terminal palette, user recolor)."""
    body = re.sub(r"\b\w+\s*:", " ", args)          # drop argument labels
    body = re.sub(r"\.(sRGB|sRGBLinear|displayP3)\b", " ", body)
    body = re.sub(r"\b(CGFloat|Double|Float)\b", " ", body)
    return bool(re.search(r"[A-Za-z_]", body))


def detect_colors(text: str):
    for m in RE_SWIFTUI_RGB.finditer(text):
        dd = is_data_driven(constructor_args(text, m.start()))
        yield m.start(), ("data_driven_rgb" if dd else "swiftui_rgb"), m.group(1)
    for m in RE_APPKIT_RGB.finditer(text):
        dd = is_data_driven(constructor_args(text, m.start()))
        yield m.start(), ("data_driven_rgb" if dd else "appkit_cg_rgb"), m.group(1).split("(")[0]
    for m in RE_CG_CONTEXT.finditer(text):
        dd = is_data_driven(constructor_args(text, m.start()))
        yield m.start(), ("data_driven_rgb" if dd else "cg_context_rgb"), m.group(1)
    for m in RE_CUSTOM_RGB.finditer(text):
        if m.group(1) not in {"Color"}:
            yield m.start(), "custom_struct_rgb", m.group(1)
    for m in RE_APPKIT_SEMANTIC.finditer(text):
        yield m.start(), "appkit_semantic_direct", m.group(1)
    for m in RE_HEX.finditer(text):
        yield m.start(), "hex", m.group(0)
    for m in RE_COLOR_HUE.finditer(text):
        yield m.start(), "named_hue", "Color." + m.group(1)
    for m in RE_DOT_HUE.finditer(text):
        line_start = text.rfind("\n", 0, m.start()) + 1
        before = text[line_start : m.start()]
        if re.search(r"\bcase\s*$", before) or re.search(r"\bcase\s+[^:]*$", before) and ":" not in before:
            continue  # enum pattern (`case .red:`) not a color use
        if re.search(r"(==|!=)\s*$", before):
            continue
        yield m.start(), "named_hue", "." + m.group(1)
    for m in RE_NSCOLOR_HUE.finditer(text):
        yield m.start(), "named_hue", "NSColor." + m.group(1)
    for m in RE_SYSTEM_HUE.finditer(text):
        yield m.start(), "system_hue", m.group(1)
    for m in RE_ALPHA.finditer(text):
        yield m.start(), "alpha_literal", m.group(0)


def detect_opacity(text: str):
    """Classify `.opacity(<literal>)` by receiver: color literal, design token, or view."""
    for m in RE_OPACITY.finditer(text):
        open_idx = m.end() - 1
        close = matching_paren(text, open_idx)
        if close < 0:
            continue
        args = text[open_idx + 1 : close]
        lits = numeric_literals(args)
        if not lits:
            continue
        line_start = text.rfind("\n", 0, m.start()) + 1
        before = text[line_start : m.start()]
        callee = ""
        if before.rstrip().endswith(")"):
            end = len(before.rstrip()) - 1
            depth = 0
            for k in range(end, -1, -1):
                if before[k] == ")":
                    depth += 1
                elif before[k] == "(":
                    depth -= 1
                    if depth == 0:
                        cm = re.search(r"([\w.]+)\s*$", before[:k])
                        callee = cm.group(1) if cm else ""
                        break
        if not before.strip():
            recv = "view"
        elif callee and re.search(r"(?:AppSemanticColor|MacScopeBrand|MacScopeSurface|SyntaxPalette|AppInteractionChrome)\.", callee):
            recv = "token"
        elif callee and re.search(r"(?:^|\.)(?:Color|NSColor)$|[cC]olor|[Ff]ill|[Tt]int|[Ff]oreground", callee):
            recv = "color"
        elif TOKEN_RECEIVER.search(before):
            recv = "token"
        elif COLOR_RECEIVER.search(before):
            recv = "color"
        else:
            recv = "view"
        yield m.start(), recv, ",".join(lits)


RE_SYSTEM_SIZE = re.compile(r"\.system\(\s*size:\s*([^,)]+)")
RE_NSFONT_SIZE = re.compile(r"(?:NSFont)?\.(systemFont|boldSystemFont|monospacedSystemFont|monospacedDigitSystemFont|labelFont|messageFont|menuFont|toolTipsFont|userFixedPitchFont|userFont|titleBarFont|paletteFont|controlContentFont)\(\s*ofSize:\s*([^,)]+)|NSFont\(\s*name:[^,]+,\s*size:\s*([^,)]+)")
RE_CTFONT = re.compile(r"CTFontCreateWithName\(")
RE_CUSTOM_FONT = re.compile(r"\.custom\([^,]+,\s*(?:size|fixedSize|relativeTo)?:?\s*([^,)]+)")
RE_MONO_APPKIT = re.compile(r"\bmonospaced(?:Digit)?SystemFont\(")
RE_MONO_SWIFTUI = re.compile(r"design:\s*\.monospaced\b|\.monospaced\(\)|\.monospacedDigit\(\)")
RE_TEXTSTYLE = re.compile(
    r"\.font\(\s*(?:Font)?\.(largeTitle|title3|title2|title|headline|subheadline|body|callout|footnote|caption2|caption|system\(\s*\.\w+)\b"
)
RE_FONT_TOKEN = re.compile(r"\.font\(\s*AppTypography\.")

def detect_fonts(text: str):
    for m in RE_SYSTEM_SIZE.finditer(text):
        arg = m.group(1).strip()
        if numeric_literals(arg) and not DESIGN_TOKEN.search(arg):
            yield m.start(), "swiftui_literal_size", arg
        else:
            yield m.start(), "swiftui_computed_size", arg
    for m in RE_NSFONT_SIZE.finditer(text):
        arg = (m.group(2) or m.group(3) or "").strip()
        if m.group(2) is not None:
            arg = read_expr(text, m.start(2))
        if re.fullmatch(NUM, arg):
            yield m.start(), "appkit_literal_size", arg
        else:
            yield m.start(), "appkit_computed_size", arg
    for m in RE_CTFONT.finditer(text):
        args = split_top_level(constructor_args(text, m.start()))
        size = args[1] if len(args) > 1 else ""
        yield m.start(), ("coretext_literal_size" if re.fullmatch(NUM, size) else "coretext_computed_size"), size
    for m in RE_MONO_APPKIT.finditer(text):
        yield m.start(), "monospaced_appkit", m.group(0)
    for m in RE_MONO_SWIFTUI.finditer(text):
        yield m.start(), "monospaced_swiftui", m.group(0)
    for m in RE_TEXTSTYLE.finditer(text):
        open_idx = text.find("(", m.start())
        close = matching_paren(text, open_idx)
        expr = re.sub(r"\s+", "", text[open_idx + 1 : close]) if close > 0 else m.group(1)
        yield m.start(), "textstyle_direct", expr
    for m in RE_FONT_TOKEN.finditer(text):
        yield m.start(), "typography_token", "AppTypography"


RE_PADDING = re.compile(r"\.padding\(")
RE_EDGEINSETS = re.compile(r"(?<![\w])(?:NS)?EdgeInsets\(\s*top:")

def classify_expr(expr: str) -> str:
    has_num = bool([v for v in numeric_literals(expr)])
    has_tok = bool(DESIGN_TOKEN.search(expr))
    if has_num and has_tok:
        return "mixed"
    if has_num:
        return "literal"
    if has_tok:
        return "token"
    return "other"


def detect_padding(text: str):
    for m in RE_PADDING.finditer(text):
        open_idx = m.end() - 1
        close = matching_paren(text, open_idx)
        if close < 0:
            continue
        args = split_top_level(text[open_idx + 1 : close])
        args = [a for a in args if a]
        if not args:
            yield m.start(), "default", ""
            continue
        value = args[-1]
        if len(args) == 1 and re.fullmatch(r"\.?[\w.\[\], ]*", value) and not numeric_literals(value) and value.startswith((".", "[")):
            yield m.start(), "default", value  # edges only, system default amount
            continue
        cls = classify_expr(value)
        yield m.start(), cls, value
    for m in RE_EDGEINSETS.finditer(text):
        close = matching_paren(text, text.find("(", m.start()))
        args = text[text.find("(", m.start()) + 1 : close]
        yield m.start(), classify_expr(args), "EdgeInsets(" + " ".join(args.split()) + ")"


RE_SPACING_ARG = re.compile(
    r"(?<![\w.])(spacing|horizontalSpacing|verticalSpacing|rowSpacing|columnSpacing|interitemSpacing|itemSpacing)\s*:\s*"
)
RE_LINESPACING = re.compile(r"\.lineSpacing\(")
RE_SPACER_MIN = re.compile(r"Spacer\(\s*minLength:\s*")

def read_expr(text: str, start: int) -> str:
    depth = 0
    k = start
    while k < len(text):
        ch = text[k]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            if depth == 0:
                break
            depth -= 1
        elif (ch == "," or ch == "\n") and depth == 0:
            break
        k += 1
    return text[start:k].strip()


def detect_spacing(text: str):
    for m in RE_SPACING_ARG.finditer(text):
        expr = read_expr(text, m.end())
        if re.match(r"(CGFloat|Double|Int|Float)\b", expr):
            continue  # parameter declaration, not a call-site value
        cls = classify_expr(expr)
        yield m.start(), ("stack_" + cls), expr
    for m in RE_LINESPACING.finditer(text):
        close = matching_paren(text, m.end() - 1)
        expr = text[m.end() : close].strip()
        yield m.start(), ("stack_" + classify_expr(expr)), "lineSpacing(" + expr + ")"
    for m in RE_SPACER_MIN.finditer(text):
        expr = read_expr(text, m.end())
        yield m.start(), ("spacer_" + classify_expr(expr)), expr


RE_FRAME = re.compile(r"\.frame\(")
FRAME_LABELS = {"width", "height", "minWidth", "idealWidth", "maxWidth", "minHeight", "idealHeight", "maxHeight"}

def detect_frames(text: str):
    for m in RE_FRAME.finditer(text):
        open_idx = m.end() - 1
        close = matching_paren(text, open_idx)
        if close < 0:
            continue
        lit_dims, tok_dims = [], 0
        for arg in split_top_level(text[open_idx + 1 : close]):
            if ":" not in arg:
                continue
            label, expr = arg.split(":", 1)
            label = label.strip()
            expr = expr.strip()
            if label not in FRAME_LABELS or ".infinity" in expr or expr == "nil":
                continue
            cls = classify_expr(expr)
            if cls in ("literal", "mixed"):
                lit_dims.append(f"{label}: {expr}")
            elif cls == "token":
                tok_dims += 1
        if lit_dims:
            yield m.start(), "literal", "; ".join(lit_dims)
        elif tok_dims:
            yield m.start(), "token", ""
        else:
            yield m.start(), "other", ""


RE_RADIUS = re.compile(
    r"(?<![\w])(cornerRadius|topLeadingRadius|topTrailingRadius|bottomLeadingRadius|bottomTrailingRadius|xRadius|yRadius)\s*(:|=)\s*"
    r"|\.cornerRadius\(\s*"
)

def detect_radius(text: str):
    for m in RE_RADIUS.finditer(text):
        expr = read_expr(text, m.end())
        if re.match(r"(CGFloat|Double)\b", expr):
            continue
        cls = classify_expr(expr)
        line_start = text.rfind("\n", 0, m.start()) + 1
        before = text[line_start : m.start()]
        sub = "rounded_rect" if re.search(r"RoundedRectangle\(\s*$", before) else "other_shape"
        yield m.start(), f"{cls}:{sub}", expr


RE_LINEWIDTH = re.compile(r"(?<![\w])lineWidth\s*(:|=)\s*")
RE_SHADOW = re.compile(r"\.shadow\(")
RE_OFFSET = re.compile(r"\.offset\(\s*(x|y)\s*:")

def detect_geometry(text: str):
    for m in RE_LINEWIDTH.finditer(text):
        expr = read_expr(text, m.end())
        if re.match(r"(CGFloat|Double)\b", expr):
            continue
        yield m.start(), "lineWidth_" + classify_expr(expr), expr
    for m in RE_SHADOW.finditer(text):
        close = matching_paren(text, m.end() - 1)
        expr = text[m.end() : close]
        yield m.start(), "shadow_" + classify_expr(expr), " ".join(expr.split())
    for m in RE_OFFSET.finditer(text):
        close = matching_paren(text, text.find("(", m.start()))
        expr = text[text.find("(", m.start()) + 1 : close]
        yield m.start(), "offset_" + classify_expr(expr), " ".join(expr.split())


RE_MATERIAL = re.compile(r"(?<![\w])(?:Material)?\.(ultraThinMaterial|thinMaterial|regularMaterial|thickMaterial|ultraThickMaterial)\b")
RE_BAR = re.compile(r"(?:\b(?:background|fill|backgroundStyle|toolbarBackground|containerBackground)\(\s*|Material)\.bar\b")
RE_GLASS = re.compile(r"\bglassEffect\w*\b|\bGlassEffectContainer\b|\bNSGlassEffectView\b|buttonStyle\(\s*\.glass\w*|(?<![\w])\.glass(?:Prominent)?\b")
RE_VFX = re.compile(r"\bNSVisualEffectView\b|\.blendingMode\s*=|\.material\s*=")

def detect_materials(text: str):
    for m in RE_MATERIAL.finditer(text):
        yield m.start(), "swiftui_material", m.group(1)
    for m in RE_BAR.finditer(text):
        yield m.start(), "swiftui_material", "bar"
    for m in RE_GLASS.finditer(text):
        yield m.start(), "glass", m.group(0)
    for m in RE_VFX.finditer(text):
        yield m.start(), "appkit_visual_effect", m.group(0)


CATEGORIES = {
    "color": detect_colors,
    "opacity": detect_opacity,
    "font": detect_fonts,
    "padding": detect_padding,
    "spacing": detect_spacing,
    "frame": detect_frames,
    "radius": detect_radius,
    "geometry": detect_geometry,
    "material": detect_materials,
}

# Which (category, subkind) pairs count as a hard-coded literal for scoring.
def all_zero(value: str) -> bool:
    lits = numeric_literals(value or "")
    return bool(lits) and all(float(v) == 0 for v in lits)


def is_hardcoded(cat: str, sub: str, value: str = "") -> bool:
    if cat in ("padding", "spacing", "radius", "frame") and all_zero(value):
        return False  # zero spacing/collapsed geometry is reported, not scored as styling debt
    if cat == "color":
        return sub in {"swiftui_rgb", "appkit_cg_rgb", "cg_context_rgb", "custom_struct_rgb", "hex", "named_hue", "system_hue", "alpha_literal"}
    if cat == "opacity":
        return sub in {"color", "token"}
    if cat == "font":
        return sub in {"swiftui_literal_size", "appkit_literal_size", "coretext_literal_size"}
    if cat == "padding":
        return sub in {"literal", "mixed"}
    if cat == "spacing":
        return sub in {"stack_literal", "stack_mixed", "spacer_literal", "spacer_mixed"}
    if cat == "frame":
        return sub == "literal"
    if cat == "radius":
        return sub.startswith(("literal", "mixed"))
    if cat == "material":
        return True
    return False


# ---------------------------------------------------------------------------
# Token-usage census.
# ---------------------------------------------------------------------------

RE_TOKEN_DECL = re.compile(r"^\s*(?:(?:public|internal|private|fileprivate)\s+)?(enum|struct)\s+((?:App|MacScope)[A-Z]\w*|SyntaxPalette|\w+Chrome|WorkspacePaneMetrics)\b", re.M)
RE_MEMBER_DECL = re.compile(r"^\s*(?:(public|internal|private|fileprivate)\s+)?static\s+(?:let|var|func)\s+(\w+)", re.M)


def group_of(rel: str) -> str:
    parts = rel.split("/")
    if parts[0] == "Features" and len(parts) > 2:
        return "Features/" + parts[1]
    if len(parts) == 1:
        return "(root)"
    return parts[0]


def iter_swift(root: str, include_tests: bool = False):
    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = os.path.relpath(dirpath, root)
        top = rel_dir.split(os.sep)[0]
        if rel_dir != "." and top in EXCLUDED_TOP and not (include_tests and top == "Tests"):
            dirnames[:] = []
            continue
        dirnames[:] = [d for d in dirnames if not d.startswith(".") and not d.endswith((".xcodeproj", ".xcworkspace"))]
        for f in filenames:
            if f.endswith(".swift"):
                yield os.path.relpath(os.path.join(dirpath, f), root)


def main() -> None:
    root = sys.argv[1]
    json_out = sys.argv[sys.argv.index("--json") + 1] if "--json" in sys.argv else None
    hits = []  # dicts
    files_meta = {}
    token_decls: dict[str, dict] = {}
    cleaned_by_file: dict[str, str] = {}

    for rel in sorted(iter_swift(root)):
        src = open(os.path.join(root, rel), encoding="utf-8", errors="replace").read()
        text = clean_source(src)
        cleaned_by_file[rel] = text
        lines = src.split("\n")
        nl = [i for i, ch in enumerate(src) if ch == "\n"]
        is_ui = bool(re.search(r"^\s*import\s+(SwiftUI|AppKit)\b", src, re.M))
        # Reviewed exceptions: `// ds-allow-file: <reason>` exempts a file (e.g. a fixed print
        # palette); `// ds-allow: <reason>` on a line or the line above exempts that line. A
        # marker without a reason does not count (the reason must be on the marker's own line).
        # Allowed hits stay in the JSON, flagged.
        file_allowed = bool(re.search(r"//[ \t]*ds-allow-file:[ \t]*\S", src))

        def line_allowed(ln: int) -> bool:
            # Same line: a trailing marker. Line above: only a standalone comment line, so one
            # line's trailing marker never exempts the next line.
            if re.search(r"//[ \t]*ds-allow:[ \t]*\S", lines[ln - 1]):
                return True
            return ln >= 2 and bool(re.match(r"\s*//[ \t]*ds-allow:[ \t]*\S", lines[ln - 2]))

        files_meta[rel] = {"group": group_of(rel), "ui": is_ui, "loc": len(lines)}
        for cat, fn in CATEGORIES.items():
            for off, sub, val in fn(text):
                ln = bisect.bisect_left(nl, off) + 1
                allowed = file_allowed or line_allowed(ln)
                hits.append({
                    "file": rel, "group": group_of(rel), "line": ln, "cat": cat, "sub": sub,
                    "value": val.strip() if isinstance(val, str) else val,
                    "code": lines[ln - 1].strip()[:160],
                    "hard": (not allowed) and is_hardcoded(cat, sub, val if isinstance(val, str) else ""),
                    "allowed": allowed,
                    "zero": cat in ("padding", "spacing", "radius", "frame") and all_zero(val if isinstance(val, str) else ""),
                })
        for m in RE_TOKEN_DECL.finditer(text):
            name = m.group(2)
            # members declared in this type body
            brace = text.find("{", m.end())
            end = matching_brace(text, brace)
            body = text[brace:end]
            members = []
            depth = 0
            for line in body.split("\n"):
                if depth == 1:
                    mm = RE_MEMBER_DECL.match(line)
                    if mm and mm.group(1) not in ("private", "fileprivate"):
                        members.append(mm.group(2))
                    cm = re.match(r"^\s*case\s+(\w+)", line)
                    if cm:
                        members.append("case:" + cm.group(1))
                depth += line.count("{") - line.count("}")
            token_decls[name] = {"file": rel, "line": bisect.bisect_left(nl, m.start(2)) + 1, "kind": m.group(1), "declared_members": members, "_body": body}

    # Token references in scope + Tests.
    test_files = [r for r in iter_swift(root, include_tests=True) if r.split("/")[0] == "Tests"]
    test_text = {r: clean_source(open(os.path.join(root, r), encoding="utf-8", errors="replace").read()) for r in test_files}
    token_usage = {}
    for name, decl in token_decls.items():
        pat = re.compile(r"(?<![\w.])" + re.escape(name) + r"\b(?:\.(\w+))?")
        decl_pat = re.compile(r"\b(?:enum|struct|extension)\s+" + re.escape(name) + r"\b")
        stats = {"design_system_refs": 0, "app_refs": 0, "app_files": set(), "test_refs": 0, "test_files": set(),
                 "members": collections.Counter(), "groups": collections.Counter(), "self_refs": 0}
        for rel, text in cleaned_by_file.items():
            for m in pat.finditer(text):
                ls = text.rfind("\n", 0, m.start()) + 1
                if decl_pat.search(text[ls : m.end() + 1]):
                    continue
                in_ds = rel.startswith("DesignSystem/")
                if in_ds:
                    stats["design_system_refs"] += 1
                else:
                    stats["app_refs"] += 1
                    stats["app_files"].add(rel)
                    stats["groups"][group_of(rel)] += 1
                if m.group(1):
                    stats["members"][m.group(1)] += 1
        test_members = collections.Counter()
        for rel, text in test_text.items():
            for m in pat.finditer(text):
                stats["test_refs"] += 1
                stats["test_files"].add(rel)
                if m.group(1):
                    test_members[m.group(1)] += 1
        stats["app_files"] = len(stats["app_files"])
        stats["test_files"] = len(stats["test_files"])
        # Unqualified self-references inside the declaring body (e.g. `rowIconWidth` in AppSidebarChrome funcs)
        stats["unused_members"] = [mbr for mbr in decl["declared_members"] if not mbr.startswith("case:") and stats["members"][mbr] == 0 and test_members[mbr] == 0]
        stats["test_only_members"] = [mbr for mbr in decl["declared_members"] if not mbr.startswith("case:") and stats["members"][mbr] == 0 and test_members[mbr] > 0]
        body = decl["_body"]
        stats["internal_only_members"] = [mbr for mbr in stats["unused_members"] if len(re.findall(r"(?<![\w.])" + re.escape(mbr) + r"\b", body)) > 1]
        stats["unused_members"] = [mbr for mbr in stats["unused_members"] if mbr not in stats["internal_only_members"]]
        stats["members"] = dict(stats["members"].most_common())
        stats["groups"] = dict(stats["groups"].most_common())
        token_usage[name] = {**{k: v for k, v in decl.items() if not k.startswith("_")}, **stats}

    # View-modifier / component adoption.
    component_patterns = {
        ".workbenchSurface(": r"\.workbenchSurface\(",
        ".compactControlBackground(": r"\.compactControlBackground\(",
        ".workbenchPaneBackground(": r"\.workbenchPaneBackground\(",
        ".workbenchFocusRing(": r"\.workbenchFocusRing\(",
        ".sidebarSingleLineText(": r"\.sidebarSingleLineText\(",
        "Color.adaptive(": r"Color\.adaptive\(",
        "StatusPill(": r"(?<![\w])StatusPill\(",
        "MetricPill(": r"(?<![\w])MetricPill\(",
        "CompactMetadataPill(": r"(?<![\w])CompactMetadataPill\(",
        "ToolbarInlineMetric(": r"(?<![\w])ToolbarInlineMetric\(",
        "ToolbarStatusLabel(": r"(?<![\w])ToolbarStatusLabel\(",
        "InspectorSection(": r"(?<![\w])InspectorSection\(",
        "WorkbenchPanel": r"(?<![\w])WorkbenchPanel\b(?!<)",
        "ToolDockButton(": r"(?<![\w])ToolDockButton\(",
        "IssueBanner(": r"(?<![\w])IssueBanner\(",
        "LoadingStateView(": r"(?<![\w])LoadingStateView\(",
        "EmptyStateView(": r"(?<![\w])EmptyStateView\(",
        "ErrorStateView(": r"(?<![\w])ErrorStateView\(",
    }
    components = {}
    for label, p in component_patterns.items():
        rp = re.compile(p)
        app = sum(len(rp.findall(t)) for r, t in cleaned_by_file.items() if not r.startswith("DesignSystem/"))
        ds = sum(len(rp.findall(t)) for r, t in cleaned_by_file.items() if r.startswith("DesignSystem/"))
        tests = sum(len(rp.findall(t)) for t in test_text.values())
        components[label] = {"app": app, "design_system": ds, "tests": tests}

    result = {"root": root, "files": files_meta, "hits": hits, "token_usage": token_usage, "components": components}
    if json_out:
        with open(json_out, "w") as fh:
            json.dump(result, fh, indent=1, default=list)
    print(f"files={len(files_meta)} hits={len(hits)} hard={sum(h['hard'] for h in hits)} tokens={len(token_usage)}")


def matching_brace(text: str, open_idx: int) -> int:
    depth = 0
    for k in range(open_idx, len(text)):
        if text[k] == "{":
            depth += 1
        elif text[k] == "}":
            depth -= 1
            if depth == 0:
                return k
    return len(text)


if __name__ == "__main__":
    main()
