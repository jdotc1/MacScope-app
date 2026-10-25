#!/usr/bin/env python3
"""Compose README illustrations from accepted goldens; requires Pillow.

Run from any directory. Does not render or re-record golden tests.
"""
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
GOLDENS = ROOT / 'Tests/LumenUITests/Goldens'
OUTPUT = ROOT / 'Docs/images'
LIGHT = 'standard-light'
DARK = 'midnight-dark'

# Each entry is an ordered horizontal composition; retain source pixels and aspect ratios.
IMAGES = {
    'settings-window': [('settings-rich', LIGHT), ('settings-rich', DARK)],
    'catalog-menus': [('command-menu', LIGHT)],
    'catalog-tiles': [('icon-tiles', LIGHT)],
    'welcome-window': [('welcome', LIGHT), ('welcome', DARK)],
    'catalog-toolbar': [('toolbar', LIGHT), ('unified-top-bar', LIGHT)],
    'catalog-inspector': [('inspector', LIGHT), ('popovers', LIGHT)],
    'catalog-midnight': [('showcase', DARK)],
    'split-workspace': [('workspace-splits', 'ultraviolet-dark')],
    'workspace': [('workspace', 'ultraviolet-dark')],
    'workspace-light': [('workspace', LIGHT)],
    'command-palette-workspace': [('command-palette', 'ultraviolet-dark')],
    'glyphs': [('glyphs', LIGHT), ('glyphs', DARK)],
}


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for name, sources in IMAGES.items():
        images = []
        for subject, appearance in sources:
            with Image.open(GOLDENS / f'{subject}@{appearance}.png') as source:
                images.append(source.convert('RGBA'))
        canvas = Image.new('RGBA', (sum(i.width for i in images), max(i.height for i in images)), (0, 0, 0, 0))
        x = 0
        for source in images:
            canvas.alpha_composite(source, (x, 0))
            x += source.width
        canvas.save(OUTPUT / f'{name}.png', optimize=True)
        print(f'{name}.png: {canvas.width} × {canvas.height}')


if __name__ == '__main__':
    main()
