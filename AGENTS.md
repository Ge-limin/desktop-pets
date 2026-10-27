# Desktop Pets integration

Unified native AppKit desktop-pet source. Preserve upstream credits/licenses; user-owned media is private/local, never tracked or redistributed without permission. No new runtime dependencies.

## Ownership for current task
- Main Pi owns integration, root build/docs/licenses and installation. Current delegated write scopes are recorded only in docs/task-status.md; do not assume old roles are active.
- Shared code has one writer at a time. Target-specific sources retain only genuinely different behavior or small adapters.
- Media is read-only unless the current task explicitly changes it; original downloaded pack strictly read-only.
- No one edits /Applications or starts normal GUI apps except the integration owner. Legacy source repositories remain read-only snapshots until installation is accepted.

## Contract
- Compile each app with its Sources/*.swift plus Shared/*.swift; human targets additionally Shared/Human/*.swift, Cats/Nailong additionally Shared/Native/*.swift. No copied active implementations of shared menu/bridge/reply configuration/native gesture/shuffle helpers. Freeze input before builds.
- Private runtime assets: .local-media/<target>. Build output: build/<app>.app. Keep existing bundle IDs for settings.
- Left AND right use actual NSMenu via the same shared native presenter. No custom popup panel or custom-drawn menu rows/material; do not call imitation native. Left release waits the shared fixed0.3s interval before opening with random/stop and all content items; second down cancels that pending single, second release plays once without flashing a menu. Drag/right/lifecycle/owner changes cancel pending work. No CG button sampling, fake input or native-tracking double handoff. Use compact native metrics; verify full visibility on current display and disclose native overflow on smaller displays. Human/Nailong: voices. Cats: all installed cats; choosing a cat replaces the current role and plays immediately.
- Double within the shared0.3s interval (also enforced against the pending click timestamp, not just the system clickCount): Cats play/restart CURRENT cat's media, never switch role; explicit left random still shuffles the cat catalog. Human/Nailong choose a random voice using shuffle bag. Drag only moves. Right: configuration only (no duplicate voice/random/role-picking entries).
- Human autoreply: independently selectable incoming peers; default manual-hop0 only, opt-in chain depth <=2 rounds (not global message-count budget). Master controls receipt/answer, not normal manual announcements. Preserve existing master switches/peer defaults; empty list means none; filter changes cancel queued replies. Tests must never post real live-app notifications.
- Single pet owns one playback at a time, new playback replaces old; stop clears pending/autoreply. Mute preserves configured volume. Preserve previous settings; add missing persistence without reset. Normal mode single instance, tests isolated and silent.
- Cat animation contract: each clip may require animation {directory:'Animation', fps:24, frameCount:N, width:W, height:H, duration:S}; frames zero-based 00000.png etc. PNG RGBA frames share fixed canvas/crop. Clock from actual AVAudioPlayer.currentTime; stop/end/change restores idle face; muted playback still animates. Bounded cache, no whole-library frame decode at startup.
- Animation implementation and preparation must agree on manifest before full conversion. No fabricated audio, no webpage wrappers. Cats show no playback provenance/clip-label caption (e.g. 原片音轨); actual errors must remain visible.
- Build/test via main process tool; source freeze before requesting build, never mutate compiler inputs during a build. Readiness is not validation. Keep logs bounded and state precise.
- No git push, remote repo creation, release, public artifacts or legal permission assumptions. Only code/open-source licensed dependencies may be staged; raw/derived media, private paths and local evidence excluded.
