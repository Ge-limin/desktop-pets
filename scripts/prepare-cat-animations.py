#!/usr/bin/env python3
"""Prepare private full-length cat animations. Requires ffmpeg, ffprobe, Pillow."""
import argparse
import ctypes
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw

FPS = 24
BASE = ['ffmpeg', '-hide_banner', '-nostdin', '-y', '-threads', '2',
        '-filter_threads', '2', '-filter_complex_threads', '2']


def run(args):
    p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode:
        raise RuntimeError(p.stderr.decode(errors='replace')[-6000:])
    return p


def probe(path):
    return json.loads(run(['ffprobe', '-v', 'error', '-show_streams',
                           '-show_format', '-of', 'json', str(path)]).stdout)


def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def levels(path, filters=''):
    p = run(BASE + ['-i', str(path), '-vn', '-af',
                   (filters + ',' if filters else '') + 'volumedetect',
                   '-f', 'null', '-'])
    text = p.stderr.decode()
    result = {k: float(re.search(k + r':\s*([-\d.]+) dB', text).group(1))
              for k in ('mean_volume', 'max_volume')}
    return result


def resolve_source(metadata, root):
    # Existing manifests are private; relocation uses a stored relative path or
    # the original common source-pack directory name, never a hardcoded machine.
    if metadata.get('sourceRelativePath'):
        path = root / metadata['sourceRelativePath']
    else:
        old = Path(metadata['sourcePath'])
        if old.is_relative_to(root):
            path = old
        else:
            parts = old.parts
            if root.name not in parts:
                raise ValueError('Relocation needs sourceRelativePath or the same source-root basename')
            path = root.joinpath(*parts[parts.index(root.name) + 1:])
    path = path.resolve(strict=True)
    if not path.is_relative_to(root):
        raise ValueError('Source escaped source root')
    return path


def mask_union(source, vf, width, height, scratch):
    # Stream one alpha plane at a time; no 4K or intermediate frame collection.
    count, bbox = 0, None
    with open(scratch / 'mask.log', 'wb') as log:
        p = subprocess.Popen(BASE + ['-v', 'error', '-i', str(source), '-an',
            '-vf', vf + ',alphaextract', '-pix_fmt', 'gray', '-threads', '2',
            '-fps_mode', 'passthrough', '-f', 'rawvideo', 'pipe:1'], stdout=subprocess.PIPE, stderr=log)
        try:
            size = width * height
            while True:
                data = bytearray()
                while len(data) < size:
                    chunk = p.stdout.read(size - len(data))
                    if not chunk:
                        break
                    data.extend(chunk)
                if not data:
                    break
                if len(data) != size:
                    raise RuntimeError('Incomplete alpha plane')
                b = Image.frombytes('L', (width, height), bytes(data)).getbbox()
                if b:
                    bbox = b if bbox is None else (min(bbox[0], b[0]), min(bbox[1], b[1]),
                                                    max(bbox[2], b[2]), max(bbox[3], b[3]))
                count += 1
            if p.wait():
                raise RuntimeError((scratch / 'mask.log').read_text()[-6000:])
        finally:
            p.stdout.close()
            if p.poll() is None:
                p.kill()
                p.wait()
    if not bbox:
        raise RuntimeError('No foreground in full animation')
    return bbox, count


def exchange(stage, target):
    """Atomic replacement, preserving the old role if conversion/checks fail."""
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == 'darwin':
        fn = libc.renamex_np
        fn.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        result = fn(os.fsencode(stage), os.fsencode(target), 2)  # RENAME_SWAP
    elif sys.platform.startswith('linux') and hasattr(libc, 'renameat2'):
        fn = libc.renameat2
        fn.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        result = fn(-100, os.fsencode(stage), -100, os.fsencode(target), 2)
    else:
        raise RuntimeError('Atomic directory exchange unavailable; old role untouched')
    if result:
        raise OSError(ctypes.get_errno(), 'Atomic role exchange failed')


def validate_frames(directory, count, size):
    files = sorted(directory.glob('*.png'))
    if [p.name for p in files] != [f'{i:05d}.png' for i in range(count)]:
        raise RuntimeError('Frame names/count mismatch')
    transparent, empty, hashes = 0, 0, set()
    for path in files:
        with Image.open(path) as im:
            im.load()
            if im.mode != 'RGBA' or im.size != size:
                raise RuntimeError(f'Invalid RGBA canvas: {path.name}')
            alpha = im.getchannel('A')
            lo, hi = alpha.getextrema()
            if lo == 0:
                transparent += 1
            if hi == 0:
                empty += 1
            hashes.add(hashlib.sha256(im.tobytes()).hexdigest())
    if empty or transparent != count or len(hashes) < 2:
        raise RuntimeError(f'Invalid animation: empty={empty}, transparent={transparent}, unique={len(hashes)}')
    return {'allFramesDecoded': True, 'rgbaFixedCanvas': True,
            'transparentFrames': transparent, 'emptyFrames': empty, 'uniqueFrames': len(hashes)}


def contact_sheet(stage, count, size):
    indices = sorted(set(round(i * (count - 1) / 8) for i in range(9)))
    w, h = size
    sheet = Image.new('RGB', (3 * (w + 16), 3 * (h + 36)), '#444444')
    draw = ImageDraw.Draw(sheet)
    for n, index in enumerate(indices):
        x, y = (n % 3) * (w + 16) + 8, (n // 3) * (h + 36) + 8
        for yy in range(0, h, 12):
            for xx in range(0, w, 12):
                color = '#bbbbbb' if ((xx // 12 + yy // 12) % 2) else '#eeeeee'
                draw.rectangle((x + xx, y + yy, x + min(w - 1, xx + 11), y + min(h - 1, yy + 11)), fill=color)
        with Image.open(stage / 'Animation' / f'{index:05d}.png') as im:
            sheet.paste(im, (x, y), im)
        draw.text((x, y + h + 3), f'{index:05d}  {index / FPS:.3f}s', fill='white')
    (stage / 'Verification').mkdir(exist_ok=True)
    sheet.save(stage / 'Verification' / 'contact-sheet.png')


def prepare(target, root, work, max_side):
    metadata = json.loads((target / 'metadata.json').read_text())
    if len(metadata['clips']) != 1:
        raise ValueError('This full-source recipe expects one original clip per cat')
    source = resolve_source(metadata, root)
    digest = sha(source)
    if digest != metadata['sourceSHA256']:
        raise RuntimeError('Source SHA256 mismatch; old media untouched')
    info = probe(source)
    video = next(s for s in info['streams'] if s['codec_type'] == 'video')
    audio = next(s for s in info['streams'] if s['codec_type'] == 'audio')
    if any(abs(float(s.get('start_time', 0))) > .001 for s in (video, audio)):
        raise ValueError('Nonzero source offsets need an explicit synchronization recipe')
    vd, ad = float(video['duration']), float(audio['duration'])
    duration = max(vd, ad, float(info['format']['duration']))
    if duration > 15.1 or duration <= 0 or abs(vd - ad) > .1:
        raise ValueError('Not an approved short full-source clip / unexpected A/V gap')
    count = math.ceil(duration * FPS - 1e-6)
    video_frame_count = math.ceil(vd * FPS - 1e-6)
    if count > video_frame_count + 1:
        raise ValueError('Audio tail requires more than one additional video frame')
    ratio = min(1, 720 / max(video['width'], video['height']))
    sw, sh = round(video['width'] * ratio), round(video['height'] * ratio)
    key = f'scale={sw}:{sh}:flags=lanczos,setsar=1,format=rgba,colorkey=0x00ff00:0.28:0.08,despill=type=green:mix=0.5,format=rgba'
    # fps defaults to rounding EOF down on some sources (Oiiai: 167 rather
    # than 168). Pass the final fractional frame, then pad at the OUTPUT rate.
    # Padding before fps did not survive that EOF handling on this FFmpeg.
    # A single extra held frame covers a source audio tail; trim only surplus
    # padding beyond ceil(full source duration * FPS), never source action.
    vf = (f'setpts=PTS-STARTPTS,{key},fps={FPS}:eof_action=pass,'
          f'tpad=stop_mode=clone:stop=1,trim=end_frame={count}')
    with tempfile.TemporaryDirectory(prefix=target.name + '-', dir=work) as tmp:
        scratch = Path(tmp)
        stage = scratch / 'role'
        shutil.copytree(target, stage)
        for name in ('Animation', 'Verification'):
            if (stage / name).exists():
                shutil.rmtree(stage / name)
        (stage / 'Animation').mkdir()
        print(f'{target.name}: full mask pass ({duration:.6f}s)', flush=True)
        bbox, mask_count = mask_union(source, vf, sw, sh, scratch)
        if mask_count != count:
            raise RuntimeError(f'Mask count {mask_count} != {count}')
        x, y, right, bottom = bbox
        cw, ch = right - x, bottom - y
        padding = 8
        scale = min(1, max_side / max(cw + padding * 2, ch + padding * 2))
        ow, oh = max(1, round((cw + padding * 2) * scale)), max(1, round((ch + padding * 2) * scale))
        final_vf = vf + f',crop={cw}:{ch}:{x}:{y}:exact=1,pad=iw+16:ih+16:8:8:color=black@0,scale={ow}:{oh}:flags=lanczos,format=rgba'
        print(f'{target.name}: {count} frames, fixed {ow}x{oh}, union={bbox}', flush=True)
        run(BASE + ['-v', 'error', '-i', str(source), '-an', '-vf', final_vf,
                    '-fps_mode', 'passthrough', '-c:v', 'png', '-pix_fmt', 'rgba',
                    '-threads', '2', '-start_number', '0', str(stage / 'Animation' / '%05d.png')])
        frame_checks = validate_frames(stage / 'Animation', count, (ow, oh))
        clip = metadata['clips'][0]
        relative_audio = Path(clip['file'])
        if relative_audio.is_absolute() or '..' in relative_audio.parts:
            raise ValueError('Unsafe clip audio path')
        dest = stage / relative_audio
        dest.parent.mkdir(parents=True, exist_ok=True)
        # Fix the rematrix format before measuring AND encoding. Otherwise
        # volumedetect negotiates s16 but volume negotiates float: FFmpeg's
        # integer downmix is normalized differently (+3 dB discrepancy).
        mono = 'aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=mono'
        before = levels(source, mono)
        gain = min(0, -22 - before['mean_volume'], -6 - before['max_volume'])
        af = f'asetpts=PTS-STARTPTS,{mono},volume={gain:.3f}dB,apad=whole_dur={duration:.9f},atrim=duration={duration:.9f}'
        run(BASE + ['-v', 'error', '-i', str(source), '-vn', '-af', af,
                    '-c:a', 'aac', '-b:a', '96k', '-ar', '48000', '-ac', '1',
                    '-threads', '2', '-movflags', '+faststart', str(dest)])
        # volumedetect decodes the entire AAC file, not just container metadata.
        after = levels(dest)
        audio_duration = float(probe(dest)['format']['duration'])
        delta = abs(audio_duration - count / FPS)
        if delta > 1 / FPS + .001 or after['max_volume'] > -3 or after['mean_volume'] > -21:
            raise RuntimeError(f'Audio verification failed: duration delta={delta}, levels={after}')
        representative = min(count - 1, FPS)
        shutil.copyfile(stage / 'Animation' / f'{representative:05d}.png', stage / metadata['image'])
        metadata.update(sourcePath=str(source), sourceRelativePath=str(source.relative_to(root)), sourceSHA256=digest,
                        imageTimecode=representative / FPS)
        metadata['imageProcessing'] = {
            'filter': final_vf, 'alphaCropThreshold': 0, 'cropBox': list(bbox),
            'padding': padding, 'outputSize': [ow, oh], 'fixedAnimationCanvas': True,
            'animationFrame': representative, 'sha256': sha(stage / metadata['image'])}
        clip.update(sourcePath=str(source), sourceSHA256=digest,
                    sourceTimecodes={'start': 0.0, 'end': duration},
                    timecodes={'start': 0.0, 'end': audio_duration}, duration=audio_duration,
                    gainDB=round(gain, 3), sha256=sha(dest))
        clip['animation'] = {'directory': 'Animation', 'fps': FPS, 'frameCount': count,
                             'width': ow, 'height': oh, 'duration': count / FPS}
        clip['processing'] = {
            'codec': 'aac', 'bitrate': '96k', 'sampleRate': 48000, 'channels': 1,
            'targetMeanDB': -22, 'peakCeilingDB': -6, 'audioFilter': af,
            'sourceAudioDuration': ad, 'sourceVideoDuration': vd, 'sourceDuration': duration,
            'sourceAudioTimecodes': {'start': 0.0, 'end': ad},
            'sourceVideoTimecodes': {'start': 0.0, 'end': vd},
            'tailSilencePaddingSeconds': max(0, duration - ad),
            'fpsEOFAction': 'pass', 'postFPSCloneFrameCapacity': 1,
            'additionalAudioTailFrames': max(0, count - video_frame_count),
            'videoTailCoverageSeconds': max(0, count / FPS - vd),
            'videoFilter': final_vf, 'unionAlphaBBox': list(bbox),
            'alphaThreshold': 0, 'maskSize': [sw, sh], 'maskFrameCount': mask_count,
            'fullSource': True, 'threads': 2}
        clip['verification'] = dict(frame_checks, fullDecode=True, nonZero=True,
            sourceLevels=before, outputLevels=after, audioDuration=audio_duration,
            animationDuration=count / FPS, durationDifferenceSeconds=delta,
            contactSheet='Verification/contact-sheet.png', visualReview=False, humanListening=False)
        contact_sheet(stage, count, (ow, oh))
        (stage / 'metadata.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n')
        exchange(stage, target)
        print(f'{target.name}: committed; AAC={audio_duration:.6f}s, animation={count / FPS:.6f}s, delta={delta:.6f}s', flush=True)
        # stage now holds the previous role, deleted with only this task's scratch.


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source-root', type=Path, required=True)
    p.add_argument('--media-root', type=Path, required=True)
    p.add_argument('--cats', nargs='+', help='Role directory IDs; default all existing roles')
    p.add_argument('--max-side', type=int, default=320)
    args = p.parse_args()
    root, media = args.source_root.resolve(strict=True), args.media_root.resolve(strict=True)
    if media.is_relative_to(root) or root.is_relative_to(media):
        p.error('Source and media roots must be separate trees')
    if not 128 <= args.max_side <= 320:
        p.error('--max-side must be 128..320')
    ids = args.cats or sorted(x.parent.name for x in media.glob('*/metadata.json'))
    if not ids or any(not re.fullmatch(r'[a-z0-9][a-z0-9-]*', x) for x in ids):
        p.error('Expected existing safe role IDs')
    work = media.parent / '.animation-work'
    work.mkdir(exist_ok=True)
    try:
        for name in ids:
            target = (media / name).resolve(strict=True)
            if target.parent != media:
                raise ValueError('Role escaped media root')
            prepare(target, root, work, args.max_side)
    finally:
        try:
            work.rmdir()  # never remove another invocation's work
        except OSError:
            pass


if __name__ == '__main__':
    main()
