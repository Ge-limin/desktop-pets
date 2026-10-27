# Desktop Pets integration

Unified native AppKit desktop-pet source. Preserve upstream credits/licenses; user-owned media is private/local, never tracked or redistributed without permission. No new runtime dependencies.

## Ownership for current task
- Integration: Pi main session; root build/docs/licenses/scripts and Shared/ImmediateVoicePicker.swift.
- Human agent: Apps/Human/** only; roots .local-media/{sun,shaolan,goodthing} read-only.
- Native agent: Apps/{Cats,Nailong}/** only; .local-media/{cats,nailong} read-only.
- Animation media agent: scripts/prepare-cat-animations.py, docs/animation-media.md and .local-media/cats/** only; original Downloads pack strictly read-only.
- No one edits /Applications or starts normal GUI apps except the integration owner. Legacy source repositories remain read-only snapshots until installation is accepted.

## Contract
- Compile each app with its Sources/*.swift plus Shared/ImmediateVoicePicker.swift; shared input is frozen during parallel target work. Signal a required shared change before editing.
- Private runtime assets: .local-media/<target>. Build output: build/<app>.app. Keep existing bundle IDs for settings.
- Left: immediate nonmodal content list with random/stop. Human/Nailong: voices. Cats: all installed cats; choosing a cat replaces the current role and plays immediately.
- Double: choose once at random from that same left-click content catalog, using shuffle bag; drag only moves. Right: configuration only (no duplicate voice/random/role-picking entries).
- Single pet owns one playback at a time, new playback replaces old; stop clears pending/autoreply. Mute preserves configured volume. Preserve previous settings; add missing persistence without reset. Normal mode single instance, tests isolated and silent.
- Cat animation contract: each clip may require animation {directory:'Animation', fps:24, frameCount:N, width:W, height:H, duration:S}; frames zero-based 00000.png etc. PNG RGBA frames share fixed canvas/crop. Clock from actual AVAudioPlayer.currentTime; stop/end/change restores idle face; muted playback still animates. Bounded cache, no whole-library frame decode at startup.
- Animation implementation and preparation must agree on manifest before full conversion. No fabricated audio, no webpage wrappers.
- Build/test via main process tool; source freeze before requesting build, never mutate compiler inputs during a build. Readiness is not validation. Keep logs bounded and state precise.
- No git push, remote repo creation, release, public artifacts or legal permission assumptions. Only code/open-source licensed dependencies may be staged; raw/derived media, private paths and local evidence excluded.
