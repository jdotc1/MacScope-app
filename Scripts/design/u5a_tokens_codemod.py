"""U5a codemod: legacy MacScope spacing/radius/motion/font/icon/stroke tokens -> Lumen.* (value-preserving).

AppSpacing (4/8/12/16/20/24) -> Lumen.Space s2/s4/s5/s6/s7/s8; AppRadius -> Lumen.Radius;
AppMotion -> Lumen.Motion; DS.Space/Radius/Font/IconSize/Stroke/Motion (typealiases of Lumen's) -> Lumen.*.
Adds `import LumenUI` to every Swift file it changes that lacks it. Usage: u5a_tokens.py <MacScope dir>
"""
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
subs = [
    (r'\bAppSpacing\.xxs\b', 'Lumen.Space.s2'), (r'\bAppSpacing\.xs\b', 'Lumen.Space.s4'),
    (r'\bAppSpacing\.sm\b', 'Lumen.Space.s5'), (r'\bAppSpacing\.md\b', 'Lumen.Space.s6'),
    (r'\bAppSpacing\.lg\b', 'Lumen.Space.s7'), (r'\bAppSpacing\.xl\b', 'Lumen.Space.s8'),
    (r'\bAppSpacing\.sidebarSafeLeading\b', 'Lumen.Space.s8'),
    (r'\bAppRadius\.tight\b', 'Lumen.Radius.xs'), (r'\bAppRadius\.compact\b', 'Lumen.Radius.sm'),
    (r'\bAppRadius\.regular\b', 'Lumen.Radius.md'), (r'\bAppRadius\.panel\b', 'Lumen.Radius.lg'),
    (r'\bAppMotion\.quick\b', 'Lumen.Motion.fastCurve'), (r'\bAppMotion\.regular\b', 'Lumen.Motion.regularCurve'),
    (r'\bAppMotion\.adaptive\(', 'Lumen.Motion.animation('),
    (r'\bDS\.(Space|Radius|Font|IconSize|Stroke|Motion)\.', r'Lumen.\1.'),
]
changed = []
for path in root.rglob('*.swift'):
    rel = path.relative_to(root).as_posix()
    if rel.startswith(('ThirdParty/', 'LocalPackages/')) or '/.build/' in rel:
        continue
    text = path.read_text()
    new = text
    for pattern, repl in subs:
        new = re.sub(pattern, repl, new)
    if new != text:
        if 'Lumen.' in new and not re.search(r'^import LumenUI$', new, re.M):
            m = re.search(r'^import SwiftUI$', new, re.M) or re.search(r'^import \w+$', new, re.M)
            new = new[:m.end()] + '\nimport LumenUI' + new[m.end():] if m else 'import LumenUI\n' + new
        path.write_text(new)
        changed.append(rel)
print(len(changed), 'files changed')
for c in sorted(changed): print(' ', c)
