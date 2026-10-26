"""U5c codemod: MacScope's DS typealiases of Lumen types -> the Lumen types themselves.

For every top-level `typealias DSName = LumenName` in DesignSystem/, call sites become `LumenName`
and the alias line is deleted. Pure renames (the alias *is* the Lumen type), so behavior is
unchanged. Files that now name Lumen types get `import LumenTokens` and `import LumenUI`.
Usage: u5c_typealias_codemod.py <MacScope dir>
"""
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
alias_re = re.compile(r'^typealias (DS\w+) = (Lumen\w+)\s*$', re.M)
aliases = {}
for path in (root / 'DesignSystem').rglob('*.swift'):
    for name, target in alias_re.findall(path.read_text()):
        aliases[name] = target
changed = []
for path in root.rglob('*.swift'):
    rel = path.relative_to(root).as_posix()
    if rel.startswith(('ThirdParty/', 'LocalPackages/')):
        continue
    text = path.read_text()
    new = re.sub(r'^(?:///[^\n]*\n)*typealias DS\w+ = Lumen\w+\s*\n', '', text, flags=re.M)
    for name in sorted(aliases, key=len, reverse=True):
        new = re.sub(r'\b' + name + r'\b', aliases[name], new)
    if new != text:
        for module in ('LumenUI', 'LumenTokens'):
            if re.search(r'\bLumen\w+', new) and not re.search(r'^import ' + module + r'$', new, re.M):
                m = re.search(r'^import SwiftUI$', new, re.M) or re.search(r'^import \w+$', new, re.M)
                new = new[:m.end()] + '\nimport ' + module + new[m.end():] if m else f'import {module}\n' + new
        path.write_text(new); changed.append(rel)
print(len(aliases), 'aliases;', len(changed), 'files changed')
