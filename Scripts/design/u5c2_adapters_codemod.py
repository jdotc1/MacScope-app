"""U5c-2 codemod: thin DS component adapters -> the Lumen components they wrapped.

Each adapter's body was a single Lumen component call; call sites become that call (argument
order per Lumen's initializer). Usage: u5c2_adapters_codemod.py <MacScope dir>
"""
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])

def skip_string(text, i):
    """text[i] is the opening '"'; return the index just past the closing quote. Handles escapes and
    `\\( ... )` interpolations that contain their own strings."""
    i += 1
    while True:
        c = text[i]
        if c == '\\':
            if text[i + 1] == '(':
                depth, i = 1, i + 2
                while depth:
                    d = text[i]
                    if d == '"': i = skip_string(text, i); continue
                    if d == '(': depth += 1
                    elif d == ')': depth -= 1
                    i += 1
                continue
            i += 2; continue
        if c == '"': return i + 1
        i += 1

def split_call(text, start):
    """Return (args, end) for the call whose '(' is at text[start]; args split at depth-1 commas."""
    assert text[start] == '('
    depth, i, args, cur = 0, start, [], ''
    while True:
        c = text[i]
        if c == '"':
            j = skip_string(text, i); cur += text[i:j]; i = j; continue
        if c in '([{':
            depth += 1
            if depth > 1: cur += c
        elif c in ')]}':
            depth -= 1
            if depth == 0:
                args.append(cur); return [a.strip() for a in args if a.strip()], i + 1
            cur += c
        elif c == ',' and depth == 1:
            args.append(cur); cur = ''
        else:
            if depth >= 1: cur += c
        i += 1

def rewrite(text, name, build):
    out, pos = [], 0
    for m in re.finditer(r'\b' + name + r'\(', text):
        if m.start() < pos: continue
        if m.start() > 0 and text[m.start() - 1] == '"': continue   # a source-text assertion, not a call
        args, end = split_call(text, m.end() - 1)
        out.append(text[pos:m.start()]); out.append(build(args)); pos = end
    out.append(text[pos:]); return ''.join(out)

def label(a): return a.split(':', 1)[0].strip() if re.match(r'^\w+\s*:', a) else None
def drop_label(a, l): return re.sub(r'^' + l + r'\s*:\s*', '', a, count=1)
def insert_after(args, after, extra):
    i = next(k for k, a in enumerate(args) if label(a) == after)
    return args[:i + 1] + [extra] + args[i + 1:]

builders = {
    'DSPillSwitcher': lambda a: 'LumenModeSwitcher(' + ', '.join(insert_after(a, 'options', 'style: .pill')) + ')',
    'DSToolbarGroup': lambda a: 'LumenToolbarGroup(' + ', '.join(a) + ')',
    'DSSettingsPane': lambda a: 'LumenSettingsPane(' + ', '.join([drop_label(a[0], 'title')] + a[1:] + ['style: .rich']) + ')',
    'DSStatsCard': lambda a: 'LumenStatsCard(' + drop_label(a[0], 'stats') + ')',
    'DSSidebarHeader': lambda a: 'LumenSidebarHeader(' + ', '.join([drop_label(a[0], 'title')] + a[1:]) + ')',
    'DSSidebarCountSectionHeader': lambda a: 'LumenSidebarCountSection(' + ', '.join([drop_label(a[0], 'title')] + a[1:]) + ') { EmptyView() }',
    'DSSidebarSwitcher': lambda a: 'LumenSidebarSwitcher(' + ', '.join(insert_after(a, 'items', 'shortcuts: false') + ['style: .tiles']) + ')',
    'DSAddressField': lambda a: 'LumenAddressField(' + ', '.join(a) + ')',
    'DSConsoleTranscript': lambda a: 'LumenConsole(' + ', '.join(a) + ')',
    'DSBadge': lambda a: 'LumenBadge(' + ', '.join([drop_label(a[0], 'text')] + a[1:]) + ')',
    'DSKindTag': lambda a: 'LumenTag(' + ', '.join([drop_label(a[0], 'text')] + a[1:]) + ')',
}
changed = []
for path in root.rglob('*.swift'):
    rel = path.relative_to(root).as_posix()
    if rel.startswith(('ThirdParty/', 'LocalPackages/', 'DesignSystem/')): continue
    text = path.read_text(); new = text
    for name, build in builders.items():
        new = rewrite(new, name, build)
    new = re.sub(r'\bDSBadge\.Tone\b', 'LumenBadge.Tone', new)
    new = new.replace('source.contains("DSPillSwitcher(")', 'source.contains("LumenModeSwitcher(")')
    if new != text:
        for module in ('LumenUI', 'LumenTokens'):
            if not re.search(r'^import ' + module + r'$', new, re.M):
                m = re.search(r'^import SwiftUI$', new, re.M) or re.search(r'^import \w+$', new, re.M)
                new = new[:m.end()] + '\nimport ' + module + new[m.end():]
        path.write_text(new); changed.append(rel)
print(len(changed), 'files changed'); [print(' ', c) for c in sorted(changed)]
