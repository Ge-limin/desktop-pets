# Native interaction / persistence

Only native AppKit gestures and a plain drag discriminator remain. The old
web-page spring deformation and its numeric parameters were removed entirely.
Dragon-frog is a source of original inspiration and private media, not a code
license. PNG/WAV must stay in ignored local media and are not redistributable
merely because they are credited. Native panel/audio patterns retain ShaolanPet
MIT attribution in source; integration owns the repository license inventory.

Normal-mode preference key: `nailongPets.preferences.v1` (Data containing JSON),
version 1, pets 1–3: x/y, height, volume, muted, allSpaces. Missing state defaults
to 35%; existing state is validated and preserved, never silently reset.
Integration may seed captured legacy geometry into this schema before normal
launch. Tests use a nil backing store and cannot read/write normal preferences.

One finite AVAudioPlayer per window; laughter plays its file once. Any playback
replaces the previous track. Drag/hold do not start/stop sound. Idle/laugh/open
are the supplied PNG expressions, not fabricated animation. The 20Hz shared
poll only performs mouse alpha hit-testing; unchanged idle views do not redraw.
