# Private cat animation preparation

The cats play their complete selected source actions, not a still image or an arbitrary short audio excerpt. User-owned source and derived media are private, ignored local assets; the code license does **not** grant rights to these images or sounds. Do not commit, publish, or redistribute them without permission.

## Run in two stages

Development-only prerequisites: Python 3.9+, Pillow, `ffmpeg`, and `ffprobe` on PATH. No dependency is added to the desktop app. The selected ten-role metadata must already exist under the media root. The script reads and hashes only those selected source files; it does not scan or copy the source collection. `--source-root` is strictly read-only.

```sh
# Run from this repository. Supply your own private source-pack location.
export CAT_SOURCE_ROOT='/path/to/private/source-pack'
python3 scripts/prepare-cat-animations.py \
  --source-root "$CAT_SOURCE_ROOT" --media-root .local-media/cats \
  --cats happy-cat oiiai-cat
```

Review both `Verification/contact-sheet.png` files before expanding to the remaining eight. The sheets show nine points across the **whole** animation, including first, middle, and last, composited on a checkerboard so transparency and pose changes are visible. Automated checks are not a substitute for this visual review or listening.

```sh
python3 scripts/prepare-cat-animations.py \
  --source-root "$CAT_SOURCE_ROOT" --media-root .local-media/cats \
  --cats huh-cat banana-cat sad-cat question-cat giggle-cat \
         bababoy-cat angry-cat orange-question-cat
```

Omit `--cats` to rebuild all ten. Run only one preparation job at a time and avoid app playback/build asset copying while a role is exchanged. Use the main session's long-running process manager rather than an untracked background shell. All FFmpeg operations use two decoder/encoder/filter threads; roles are processed sequentially.

## Complete source and synchronized output

The selected source durations are approximately 14.333 / 9.566 / 6.989 / 3.800 / 9.899 / 12.766 / 2.972 / 2.833 / 6.800 / 4.800 seconds for Happy / Huh / Oiiai / banana / sad / question / giggle / bababoy / angry / orange-question. The script probes the actual files and uses their complete timelines. It rejects unexpected sources longer than 15.1 seconds, large A/V discrepancies, or nonzero stream offsets instead of silently substituting a different clip.

1. Verify the selected source SHA256 against its private metadata.
2. Downscale to at most 720 pixels on the longest side **before** chroma keying. Apply FFmpeg `colorkey` and `despill`, resample at 24 fps, and stream each alpha plane through a union-bounding-box calculation. Every output-timeline frame is included; this is not a sparse sample. The alpha threshold is zero, preserving every nontransparent pixel. Only one small mask is resident at a time.
3. Decode the source again and export RGBA PNG frames with one fixed union crop, eight pixels of transparent padding, and a longest side at most 320 pixels. There are no per-frame crops, 4K intermediate images, or full-library decoded caches. `fps=24:eof_action=pass` preserves the final fractional video frame; one additional clone is available **after** FPS conversion to cover a short source audio tail. The result is limited to `ceil(full source duration * 24)` frames, never an arbitrary shorter segment. Metadata records EOF behavior, additional audio-tail frames, and video-tail coverage. No action is removed to reduce frame count.
4. Encode the complete original soundtrack from time zero as mono 48 kHz / 96 kbps AAC. Measure loudness **after** downmix, attenuate toward -22 dB mean with -6 dB pre-encode peak headroom, never amplify, and verify the decoded AAC. No fades remove the beginning or ending. A short, explicitly recorded silent tail only fills an existing source audio/video end discrepancy (less than 0.1 seconds); it is not synthesized speech or music. Encoder padding and 24 fps quantization are measured.
5. Replace the idle face with an actual animation frame at approximately one second, keeping its exact canvas and scale. Consumers must not auto-crop this face or animation thumbnails: transparent margins define the animation coordinates.
6. Fully decode every PNG, enforce zero-based contiguous filenames, matching dimensions and RGBA mode, transparency, nonempty foreground, and more than one distinct frame. Fully decode AAC via `volumedetect`, require peak at most -3 dB and mean at most -21 dB, and require audio versus animation duration difference at most one 24 fps frame (with 1 ms container-duration precision tolerance).
7. Generate the private contact sheet, update private metadata, and atomically exchange the single completed role directory. A failed conversion/check leaves that role's previous media untouched. Earlier successfully committed roles remain available. Directory exchange uses macOS `renamex_np` or Linux `renameat2`; unsupported platforms fail safely rather than use a non-atomic delete-and-move.

## Runtime manifest contract

Each role has `metadata.json`, `face.png`, `Clips/original.m4a`, and `Animation/00000.png` onward. Existing clip labels and role identities are preserved. The animation directory is relative to the **role** directory; it is not relative to `Clips/`.

```json
{
  "animation": {
    "directory": "Animation",
    "fps": 24,
    "frameCount": 168,
    "width": 256,
    "height": 320,
    "duration": 7.0
  }
}
```

This is a schema example, not a claimed dimension for a particular role. Duration is `frameCount / fps`; actual AAC duration is stored separately as clip `duration`. Use the actual audio player's clock and clamp `floor(currentTime * fps)` to the last valid frame. Muting must not stop the animation clock. Stop/end/role change restores the same-canvas idle image. Decode a bounded frame cache, not the full library on startup.

Private metadata records the exact source absolute/relative paths and SHA256, actual source audio/video/full durations, full-source timecodes, padding, FFmpeg filter parameters, fixed bbox/canvas, output SHA256 for sound and idle, measured decoded levels/durations, and automated checks. `imageProcessing` is replaced along with the image; it must not retain the previous still-image crop record. `visualReview` and `humanListening` default to false: preparation does not pretend a human has reviewed or listened.

## Privacy, portability, cleanup

No private absolute source paths belong in this document or tracked files. Precise paths live only in ignored role manifests. To relocate existing metadata, preserve the source-root directory basename on the first preparation, or supply `sourceRelativePath` in private metadata; subsequent preparations resolve that relative path under `--source-root`. Sources outside the specified root are rejected.

Scratch data exists only under `.local-media/.animation-work/` (or the corresponding sibling of a custom media root). Normally it contains one role staging directory and a small diagnostic log. Each role's old media is removed only after a successful atomic exchange. Successful and failed normal exits remove their own scratch, then remove the work directory only if empty. An externally killed process can leave a uniquely named scratch directory; verify that no preparation process owns it before removing that specific directory. Never delete the original source pack. Final contact sheets are small, private verification artifacts retained beside each role, not public documentation attachments.

## Current verification state

The script's syntax and CLI have been checked. Actual media conversion, full decode results, and visual contact-sheet review are recorded in each local role's manifest; existence of this document is not proof that preparation or app integration succeeded. Runtime playback/build/installation acceptance belongs to the integration owner.
