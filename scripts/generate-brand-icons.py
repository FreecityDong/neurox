#!/usr/bin/env python3
"""Generate iOS, Android and Web icons from the approved opaque brand master.

Uses macOS sips for deterministic resizing; does not redraw or regenerate art.
Run from any directory: python3 scripts/generate-brand-icons.py
"""
import json
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parent.parent
master = root / 'assets/branding/neurox-mark.png'
icons = {}
ios = root / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
for entry in json.loads((ios / 'Contents.json').read_text())['images']:
    points = float(entry['size'].split('x')[0])
    scale = float(entry['scale'].rstrip('x'))
    icons[ios / entry['filename']] = round(points * scale)
for density, size in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]:
    icons[root / f'android/app/src/main/res/mipmap-{density}/ic_launcher.png'] = size
for size in [192, 512]:
    for name in [f'Icon-{size}.png', f'Icon-maskable-{size}.png']:
        icons[root / 'web/icons' / name] = size
icons[root / 'web/favicon.png'] = 32
for path, size in icons.items():
    subprocess.run(['sips', '-z', str(size), str(size), str(master), '--out', str(path)],
                   check=True, stdout=subprocess.DEVNULL)
    print(f'{path.relative_to(root)}: {size}x{size}')
print(f'{len(icons)} icon resources generated from {master.relative_to(root)}')
