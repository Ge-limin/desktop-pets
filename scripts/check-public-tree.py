#!/usr/bin/env python3
"""Check the source candidate, not ignored private media. Does not stage or publish."""
from pathlib import Path
import subprocess,sys
root=Path(__file__).resolve().parent.parent
raw=subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','-z'],cwd=root)
paths=sorted(set(p for p in raw.decode().split('\0') if p))
media={'.png','.jpg','.jpeg','.gif','.webp','.wav','.mp3','.m4a','.mp4','.mov','.aiff','.icns','.heic','.psd','.zip','.dmg'}
published_skin={
 'Apps/Nailong/Assets/JacketSkin/closed.png',
 'Apps/Nailong/Assets/JacketSkin/open.png',
 'Apps/Nailong/Assets/JacketSkin/laugh.png',
}
errors=[]
for rel in paths:
 p=root/rel
 if not p.is_file(): continue
 if rel.split('/')[0] in {'.local-media','.local-config','.local-evidence','build'}:errors.append(f'Private path staged: {rel}')
 if p.suffix.lower() in media and rel not in published_skin:errors.append(f'Media/archive in source candidate: {rel}')
 if rel in published_skin:
  if p.read_bytes()[:8] != b'\x89PNG\r\n\x1a\n':errors.append(f'Invalid published skin PNG: {rel}')
  continue
 try: text=p.read_text()
 except UnicodeDecodeError:
  errors.append(f'Unreviewed binary: {rel}');continue
 if ('/'+'Users/') in text or ('/var/'+'folders/') in text:errors.append(f'Machine-specific absolute path in {rel}')
for required in ['LICENSE','CREDITS.md','Licenses/ShaolanPet-MIT.txt','Licenses/Nailong-Jacket-Skin-Notice.txt',*published_skin]:
 if not (root/required).is_file():errors.append('Missing credit/license: '+required)
if errors:
 print('\n'.join(errors));sys.exit(1)
print(f'PASS: {len(paths)} publication-candidate files; only three reviewed jacket sprites are included as media. This is NOT a legal clearance or publication.')
