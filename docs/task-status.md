# Integration status / 整合状态

Status: completed; compact-picker2.1/build3 installed in all five applications
Updated: 2026-10-27
Owner: main Pi integration session. Shared picker subtask af802355-f7b9-4f2 completed; no delegated writes remain.

## Current follow-up / 当前追加需求

User requested all left-click items visible simultaneously, no scrollbar, tighter spacing. Delivered one shared direct-view picker (no NSScrollView/scrollers),13pt text,24pt rows, adaptive balanced columns. Actual37-voice list shown in two columns (~620×498pt), ten cats in one (~312×330pt). Item identity/actions/thumbnails and immediate gestures retained; placement stays in the visible screen outside the pet.

All five2.1 builds/signatures/self-tests passed. Shared tests cover complete item visibility, nonoverlap, no scroll container, density, negative-coordinate/1280×720 screen placement and original gesture/lifecycle behavior. Main reviewed actual37-voice and10-cat picker screenshots (alpha-composited on light background for review). Evidence: `.local-evidence/compact-menu/`.

Installed all five tested binaries with graceful restart; nine visible pet identities retained (user had added two Nailong windows), non-coordinate preferences/counts/roles/volume/mute/size/scope/reply/motion flags unchanged. A strict pixel-identical geometry check did NOT pass: two previously new Nailong panels restored480→485pt transparent padding under existing2.0 create-versus-restore code; saved sizes/origins unchanged. Live coordinate changes also continued during verification; they were recorded, not overwritten. This follow-up does not claim pixel-identical positions or change unrelated native geometry code. Signed installed hashes/version verified independently in `installed-audit.log`.

All prior installed2.0 hashes matched before replacement. No media edits or publication. Successful-task build cache, old app copies and one-off local installer/snapshot helpers are cleaned after verification; compact-menu logs/screenshots/preferences retained locally.

## Delivered / 已交付

- One source repository, one shared immediate nonmodal picker, five unchanged application entry points/bundle IDs. Legacy sibling source repositories now explicitly point here as historical migration snapshots; they were not deleted or rewritten.
- Immediate left content list, double-click shuffle from that same list, drag-only movement, right configuration only. All five use continuous percent volume, independent mute, size and desktop scope; existing custom settings are preserved. Human autoreply/motion controls remain explicit. Sun/Shaolan disabled reply switches stayed disabled.
- Ten cats selectable in the left list with thumbnails. Selection changes the current window's role and plays the matching audiovisual item; double-click shuffles all ten rather than a one-item current-role pool. Cats and Nailong retain independent 1–3-window management, exact-window closure and persistent settings.
- Ten complete source actions converted to 1,799 transparent 24fps frames, ~148MiB local cat media. Original audio accompanies original actions, not static-image imitation. Happy:344 frames/~14.333s; Oiiai:168/~7s. Fixed canvas prevents bounding-box breathing; actual audio time drives frames, with32MiB cache per active window. Stop/switch/end cancels old animation/audio; muted playback still animates; drag does not restart playback.
- Nailong has one finite audio player per pet; no overlapping or held looping laughter. Its unlicensed inherited webpage spring port was removed, native drag retained.
- Credits, original MIT/NOTICE texts, source-only licensing and private-media separation complete. No upload, remote creation, public release or media-rights clearance.

## Actual verification / 实际验证

1. Final five-target optimized builds, strict ad-hoc signature verification and isolated silent self-tests passed (`.local-evidence/final-build.log`, `.local-evidence/final-self-tests/`). The source is no longer being edited by subagents.
2. Native real-window smoke tests passed (`nailong-final-ui.log`, `cats-final-ui.log`): actual nonmodal selection, menu routing, drag/double discrimination, all-catalog shuffle, slider action, thumbnails, exact-window management, persistence isolation and cleanup.
3. Happy and Oiiai each played their full duration in a real NSPanel using a muted AVAudioPlayer; frames advanced with its clock, playback screenshots were captured, natural completion released timer/cache and restored idle. Full duration/frame/audio checks passed for all ten; main reviewed Happy/Oiiai nine-frame contact sheets and first/middle/last frames for all ten. Automated muted tests are **not** a claim of subjective human listening/quality acceptance.
4. Original applications were verified unchanged since the initial backup before installation. Latest preferences and actual geometry were captured immediately before graceful quit. Five staged signed bundles replaced existing apps and reopened successfully. Installed executable hashes match tested build outputs; signatures and version2.0 verified.
5. Initial installed-window comparison exposed Sun's transparent caption padding reduced20pt by the refactor. Restored its original `size+48` panel geometry, rebuilt/retested/reinstalled only Sun; final frame matches old geometry. This was fixed, not waived.
6. Five normal-mode applications and seven visible pets verified: three humans, one Nailong, three cats (angry/Huh/Oiiai). The initial post-install capture confirmed all six non-Sun centers; after the Sun fix, its center/padding also matched. During verification Huh was subsequently moved in normal use; current persisted and visible coordinates matched, and that newer location was **not** overwritten with the old snapshot. All other saved values, cat roles/counts/sizes/volumes/mutes, and disabled reply settings remained intact.
7. Old Nailong had no durable preferences. Migration seeded its captured count/visible center and known original220pt/35%/all-Spaces defaults; previously transient unsaved volume cannot be independently recovered. Its new persistence works thereafter.
8. Ten-second normal-mode resource sample: Cats (3windows) ~45MiB RSS/0.2% CPU; Nailong~44MiB/0.2%; humans~39–43MiB/0% in this sample. Not a long-term or peak-memory benchmark. See `idle-resource-sample.json`.
9. Public-tree hygiene check passed62 source-candidate files with no private media/binaries/machine paths. This is not legal clearance. Original24GB downloaded cat pack remained untouched.

## Failure history / 修复记录

Animation prep initially caught a float/integer mono-downmix measurement mismatch; fixed the common audio format instead of weakening level thresholds. Oiiai then exposed EOF rounding (167vs168frames); explicit fps EOF handling and at most one tail clone preserve video/audio coverage, verified with actual timestamps/counts. Mask and exported frame chains now agree. Failed stages were cleaned and unsuccessful role conversions did not replace old media.

## Evidence and resource return / 证据与清理

Private evidence retained in ignored `.local-evidence/`: per-target tests, UI logs/screenshots, media contact sheet, pre/post preferences and window captures, installed hashes/signature receipt, resource sample and `cleanup.json`. Private manifests/frames remain in ignored `.local-media/`; these are required rebuild inputs, not disposable cache.

After successful installation checks, removed this task's build products/module cache, temporary staged/old application copies, rollback bundle directory and one-off installer/snapshot scripts. No task process remains running. The actual installed apps remain running intentionally. Legacy source repositories and the original media pack are retained as user originals, not active duplicate implementations.

## Publication boundary / 发布边界

Code is prepared for future review/release, not published. Portraits, recordings, Nailong media and cat assets require independent rights review. Unknown cat authors are explicitly unresolved; credit is not permission. A source-only clone intentionally cannot build until the user supplies suitable private/permitted media; build failures expose missing media instead of downloading/replacing it silently.
