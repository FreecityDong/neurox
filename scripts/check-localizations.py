#!/usr/bin/env python3
"""Check literal localization keys and placeholder parity without changing sources."""
import ast,json,re
from pathlib import Path
root=Path(__file__).resolve().parent.parent
messages=json.loads((root/'lib/l10n/messages_en.json').read_text())
missing=[];count=0
for file in (root/'lib').rglob('*.dart'):
    for match in re.finditer(r'''\btr\(\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')''',file.read_text()):
        raw=match[1]
        key=json.loads(raw) if raw.startswith('"') else ast.literal_eval(raw)
        count+=1
        if key not in messages:missing.append(f'{file.relative_to(root)}: {key}')
for source,translated in messages.items():
    if sorted(re.findall(r'\{p\d+\}',source)) != sorted(re.findall(r'\{p\d+\}',translated)):
        missing.append('Placeholder mismatch: '+source)
if missing:raise SystemExit('\n'.join(missing))
print(f'{len(messages)} bilingual entries; {count} literal call sites covered; placeholders match.')
