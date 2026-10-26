"""U5b codemod: MacScope's color helpers -> Lumen palette lookups (value-preserving).

Each AppSemanticColor / MacScopeSurface / MacScopeBrand member is one token lookup (DS.color(.token),
optionally with .opacity(x)); call sites become `Color.lumen(.token)` with the same opacity.
DS.color( -> Color.lumen(, .ds( -> .lumen(, DS.nsColor( -> Lumen.nsColor(. DS.editorColor stays
(MacScope's editor-surface resolution). The three enums are then deleted.
Usage: u5b_colors_codemod.py <MacScope dir>
"""
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
ds_file = root / 'DesignSystem' / 'AppDesignSystem.swift'
src = ds_file.read_text()
enums = ['AppSemanticColor', 'MacScopeSurface', 'MacScopeBrand']
defs = {}
for e in enums:
    body = re.search(r'^enum ' + e + r' \{\n(.*?)^\}\n', src, re.S | re.M).group(1)
    for name, expr in re.findall(r'static var (\w+): Color \{ (.+?) \}\n', body):
        defs[(e, name)] = expr.strip()
def resolve(e, name, depth=0):
    expr = defs[(e, name)]
    if re.fullmatch(r'\w+', expr):          # alias to another member of the same enum
        return resolve(e, expr, depth + 1)
    return expr
mapping = {}
for (e, name) in defs:
    expr = resolve(e, name)
    expr = expr.replace('DS.color(', 'Color.lumen(')
    mapping[f'{e}.{name}'] = expr
# Delete the three enums (with their doc comments).
for e in enums:
    src = re.sub(r'(?:^///[^\n]*\n)*^enum ' + e + r' \{\n.*?^\}\n\n?', '', src, flags=re.S | re.M)
ds_file.write_text(src)
generic = [(r'\bDS\.color\(', 'Color.lumen('), (r'(?<![\w.])\.ds\(', '.lumen('), (r'\bDS\.nsColor\(', 'Lumen.nsColor(')]
changed = []
for path in root.rglob('*.swift'):
    rel = path.relative_to(root).as_posix()
    if rel.startswith(('ThirdParty/', 'LocalPackages/')):
        continue
    text = path.read_text(); new = text
    for key in sorted(mapping, key=len, reverse=True):
        new = re.sub(r'\b' + re.escape(key) + r'\b', mapping[key], new)
    for pattern, repl in generic:
        new = re.sub(pattern, repl, new)
    if new != text:
        if ('Color.lumen(' in new or '.lumen(' in new or 'Lumen.' in new) and not re.search(r'^import LumenUI$', new, re.M):
            m = re.search(r'^import SwiftUI$', new, re.M) or re.search(r'^import \w+$', new, re.M)
            new = new[:m.end()] + '\nimport LumenUI' + new[m.end():] if m else 'import LumenUI\n' + new
        path.write_text(new); changed.append(rel)
print(len(mapping), 'helpers mapped;', len(changed), 'files changed')
for k in sorted(mapping): print(f'  {k} -> {mapping[k]}')
