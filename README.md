# Desktop Pets

**English** · [简体中文](README.zh-CN.md)

Five native macOS desktop-pet apps, one shared interaction model. Each app keeps its own entry point, identity and saved settings.

## Contents

- [Interaction](#interaction)
- [Apps](#apps)
- [Build](#build)
- [Repository layout](#repository-layout)
- [License and credits](#license-and-credits)
- [Local installation](#local-installation)

## Interaction

| Gesture | Behavior |
|---|---|
| Left click | Wait 0.3 seconds, then open the native menu if no second click arrives. |
| Choose an item | Play once. Choosing a cat switches the current window to that cat and plays its animation and sound. |
| Double click | Cats replay their current media; human pets and Nailong shuffle a voice clip. |
| Drag | Move only, without triggering playback. |
| Right click | Open settings: volume, mute, size, desktop scope, pet-specific options, recovery and close. |

Both buttons use the same shared native `NSMenu` presenter—no custom popup, painted rows or gray button blocks. Menus use native compact sizing. If a display is too short for the whole list, AppKit handles overflow; there is no imitation multicolumn menu.

A second press within **0.3 seconds** cancels the pending menu; its release plays once, without a menu flash. Dragging, right-clicking and window or lifecycle changes cancel pending work. This setting does not change the system mouse preferences. No global button sampling or native-menu input handoff is used.

Each pet plays one clip at a time. Stop cancels pending replies. Mute preserves the configured volume, and muted cats still animate. Settings persist; tests are silent and isolated from normal preferences.

**Cross-cat shuffle is an explicit action in the left menu**, not the cat's double-click behavior.

Human pets can independently select whose speech they answer. By default, they answer manual playback only. Optional chaining is limited to **two rounds**, not two total messages when multiple peers respond. The master switch controls receiving and answering; manual playback can still be announced to other opted-in listeners. Changing source filters cancels pending replies.

Reply timing follows the original authors' scheduling: compensate for the reply's leading silence and overlap the preceding clip's tail by **0.3 seconds**. SunPet and GoodThingPet use **0.2 seconds at hop 1**; the minimum scheduling delay is 0.02 seconds. There is no added random pause or end buffer. This intentionally overlaps speech; independent responding pets are not globally serialized.

## Apps

| Build target | App | Content |
|---|---|---|
| `sun` | SunPet | 28 original clips; optional autoreplies and device-motion input. |
| `shaolan` | ShaolanPet | 37 clips; full manual shuffle and optional short replies. |
| `goodthing` | GoodThingPet | 11 clips and an explicit autoreply switch. |
| `nailong` | NailongPet | Six clips and 1–3 independent pets; no overlapping or held looping laughter. |
| `cats` | Cat Meme Pets | Ten cat memes, each a complete audiovisual item; 1–3 windows. |

Cats preserve the original actions—including Happy's dance and Oiiai's rotation—as transparent, fixed-canvas frames driven by the audio player's actual time. Each active window has a **32 MiB frame-cache limit**. Playback end or stop restores the idle picture and releases animation work.

Playback metadata labels are not displayed below cats; genuine playback errors remain visible. The apps require no webpage, camera, microphone, Accessibility permission or external network service.

## Build

Requires **Apple Silicon, macOS 14 or later, and Xcode Command Line Tools**. Runtime code uses Swift, AppKit and AVFoundation; SunPet also retains its IOKit/Network motion helper. No additional package-manager runtime framework is required.

Supply permitted media under the ignored `.local-media/` directory first; see [the media guide](docs/MEDIA.md). **A public clone contains no third-party media and cannot build without the required assets.** Missing media causes an explicit failure, not an automatic download or generated substitute.

```sh
./build.sh cats       # or sun / shaolan / goodthing / nailong
./build.sh all
```

Outputs are `build/<app>.app`, signed ad hoc and strictly verified, followed by isolated silent self-tests. The build script does not install or launch normal-mode apps.

Native window and animation smoke tests use the actual application filenames:

```sh
"build/奶龙桌宠.app/Contents/MacOS/NailongPet" --ui-smoke-test
"build/猫梗桌宠.app/Contents/MacOS/CatMemePets" --ui-smoke-test --screenshot "$PWD/build/cats-ui.png"
python3 scripts/check-public-tree.py
```

Animation preparation uses existing FFmpeg, FFprobe and Pillow installations. These are offline preparation tools, not application runtime dependencies.

## Repository layout

- `Shared/`: the native-menu presenter shared by all five apps for both mouse buttons.
- `Shared/Human/`: shared bridge/protocol and reply configuration for the three human pets; tiny target-specific stop-test adapters remain.
- `Shared/Native/`: shared drag discrimination and shuffle logic for Cats and Nailong.
- `Apps/Human/targets/`: pinned SunPet, ShaolanPet and FengGe sources, upstream notices and local adaptations.
- `Apps/Cats/`, `Apps/Nailong/`: native apps and isolated tests.
- `scripts/`: local media preparation and public-source hygiene checks.
- `Licenses/`, `CREDITS.md`: attribution and permission boundaries.
- `.local-media/`, `.local-config/`, `.local-evidence/`, `build/`: ignored local resources, not public artifacts.

Verification and installation records are maintained in [the task ledger](docs/task-status.md). Existing bundle identities are retained so settings can migrate without resets. Earlier sibling repositories are historical snapshots, not parallel active implementations.

## License and credits

Source code is published under the [MIT license](LICENSE), with original upstream notices retained. See [CREDITS.md](CREDITS.md) for authors, repositories and pinned revisions.

Original SunPet, ShaolanPet and FengGe MIT notices are preserved. Dragon-frog is credited for the Nailong media and original toy; its unlicensed assets are **not relicensed**, and the old web spring port is absent from this source. Cat authors remain unresolved where the supplied pack lacks provenance.

**Credit is not a redistribution license.** This repository publishes source code only, not local media packs or prebuilt applications containing them. Do not upload media, original download packs or local evidence without reviewing the applicable rights. The public-tree checker is a hygiene check, not legal clearance.

## Local installation

Quit the corresponding pet before replacing its verified app bundle. Keep its bundle ID and preferences. The five apps have separate preference domains; do not delete other pets or weaken system signing or security settings to install them.

Application entry points remain in `/Applications`. Do not run old and new executables simultaneously. Closing one window in a multi-pet app is different from quitting that app's entire group.

To uninstall, quit and remove only the intended app. Rebuildable `build/` outputs can be cleaned after validation; original downloads and required local media are not disposable caches.
