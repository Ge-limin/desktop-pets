#!/usr/bin/env python3
"""Check the source candidate, not ignored private media. Does not stage or publish."""
from pathlib import Path
import subprocess,sys
root=Path(__file__).resolve().parent.parent
raw=subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','-z'],cwd=root)
paths=sorted(set(p for p in raw.decode().split('\0') if p))
media={'.png','.jpg','.jpeg','.gif','.webp','.wav','.mp3','.m4a','.mp4','.mov','.aiff','.icns','.heic','.psd','.zip','.dmg'}
errors=[]
for rel in paths:
 p=root/rel
 if not p.is_file(): continue
 if rel.split('/')[0] in {'.local-media','.local-config','.local-evidence','build'}:errors.append(f'Private path staged: {rel}')
 if p.suffix.lower() in media:errors.append(f'Media/archive in source candidate: {rel}')
 try: text=p.read_text()
 except UnicodeDecodeError:
  errors.append(f'Unreviewed binary: {rel}');continue
 if ('/'+'Users/') in text or ('/var/'+'folders/') in text:errors.append(f'Machine-specific absolute path in {rel}')
for required in ['LICENSE','CREDITS.md','Licenses/ShaolanPet-MIT.txt']:
 if not (root/required).is_file():errors.append('Missing credit/license: '+required)
if errors:
 print('\n'.join(errors));sys.exit(1)
print(f'PASS: {len(paths)} source-candidate files; no private media/binaries/machine paths. This is NOT a legal clearance or publication.')
