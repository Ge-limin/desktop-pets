# Desktop Pets / 统一桌宠

One native interaction model for five local macOS pet apps. 一个仓库、一个共享快捷面板、五个保留原入口的本机桌宠应用。

## Interaction / 操作

| Gesture / 操作 | Behavior / 行为 |
|---|---|
| Left click / 单击 | Immediately open the nonmodal content panel: random, stop and available items / 立即打开非阻塞内容面板：随机、停止、可选内容 |
| Choose an item / 选一项 | Play once; for cats, replace the current window's cat and play its animation + sound / 播放一次；猫梗立即换成所选猫并播放动作＋声音 |
| Double click / 双击 | Shuffle one item from that same panel / 从同一个内容列表洗牌选一个播放 |
| Drag / 拖动 | Move only, without triggering playback / 只移动，不触发播放 |
| Right click / 右键 | Configuration only: volume, mute, size, Spaces, per-pet options, recover and close / 只配置：音量、静音、大小、显示范围、角色选项、恢复与关闭 |

The compact picker shows all items at once without scrolling (24pt rows, adaptive columns for long lists). 紧凑列表无滚动条，24pt行高；长列表自动分列，所有选项同时可见。

The panel may briefly appear on the first click of a double-click; single-click is never delayed to conceal that. Same-pet playback is exclusive. Stop clears queued replies/playback. Mute keeps the saved volume; muted cats still animate. Positions and settings persist in normal use. Tests are silent and preference-isolated.

双击的第一下允许列表短暂出现，不用半秒等待掩盖；同一只不叠音，停止会取消等待播放。静音不丢音量，猫静音仍有动作。正常模式保存设置，测试不污染用户偏好。

## Targets / 应用

| Build target | App | Content |
|---|---|---|
| `sun` | SunPet / 太对了 | 28 original voice clips; optional autoreply and motion input / 28原声、可选自动接话与机身摇晃 |
| `shaolan` | 薄肌桌宠 | 37 clips, full manual shuffle, optional short autoreplies / 37原声、全量手动随机、可选短句接话 |
| `goodthing` | 好事桌宠 | 11 clips, explicit autoreply switch / 11原声、明确自动接话开关 |
| `nailong` | 奶龙桌宠 | Six clips, 1–3 independent pets; no overlapping/held laughter / 6原声、1–3只；不再叠音或长按循环 |
| `cats` | 猫梗桌宠 | Ten local cat memes; one role = one full audiovisual item; 1–3 windows / 10猫梗，一个角色就是一个完整音画项，最多3窗 |

Cats preserve source actions (including Happy's dance and Oiiai's rotation) as transparent fixed-canvas frames, timed by actual audio playback. A 32MiB frame cache per active window bounds decoded memory. Playback end/stop restores the idle picture and releases animation work. No webpage, camera, microphone, accessibility permission or runtime network service.

猫保留原片动作而非静态图晃动，以实际声音进度同步透明帧；每活动窗口32MiB帧缓存上限。结束/停止恢复待机，不空转动画。无网页、摄像头/麦克风/辅助功能权限或运行时网络服务。

## Build / 构建

Apple Silicon macOS14+, system Xcode Command Line Tools. Native runtime uses Swift/AppKit/AVFoundation (Sun also uses its existing IOKit/Network helper). No new package-manager/runtime framework.

```sh
./build.sh cats       # or sun / shaolan / goodthing / nailong
./build.sh all
```

User media must first be supplied under ignored `.local-media/`; see [MEDIA.md](docs/MEDIA.md). A clean public clone intentionally contains no third-party media, and builds fail explicitly when it is absent. Animation preparation requires existing FFmpeg/FFprobe/Pillow, not additional app runtime dependencies.

Outputs are `build/<app>.app`, signed ad hoc and strictly verified, followed by isolated silent self-tests. The script never installs or starts normal-mode apps. Native window/animation smoke tests:

```sh
"build/奶龙桌宠.app/Contents/MacOS/NailongPet" --ui-smoke-test
"build/猫梗桌宠.app/Contents/MacOS/CatMemePets" --ui-smoke-test --screenshot "$PWD/build/cats-ui.png"
python3 scripts/check-public-tree.py
```

## Repository / 目录

- `Shared/`: one canonical immediate, nonmodal voice/content picker compiled by all five targets.
- `Apps/Human/targets/`: pinned Sun/Shaolan/FengGe source, original upstream notices and local adaptations.
- `Apps/Cats/`, `Apps/Nailong/`: native apps and isolated tests.
- `scripts/`: local media preparation and public-source hygiene checks.
- `Licenses/`, `CREDITS.md`: full attribution and permission boundaries.
- `.local-media/`, `.local-config/`, `.local-evidence/`, `build/`: ignored, local-only; never publish unreviewed.

Actual verification/install status is maintained only in [docs/task-status.md](docs/task-status.md). Existing app bundle identities are retained so saved settings can migrate without resetting user choices. Previous sibling repositories are historical snapshots, not parallel active implementations.

## Credit and future open source / 署名与开源

Read [CREDITS.md](CREDITS.md) and [LICENSE](LICENSE). Original SunPet/ShaolanPet/FengGe MIT notices are preserved. Dragon-frog is credited for the Nailong media and original toy; its unlicensed assets are **not** relicensed, and its old spring port is removed from this source candidate. Cat media authors remain unresolved where the user's pack lacks provenance.

**Credit is not a redistribution license.** Public code and prebuilt applications containing third-party media are different deliverables. Do not include private media, original download packs or local evidence in a public push/release. `check-public-tree.py` is a hygiene check, not legal clearance. No remote repository or public release is created by this task.

## Local install / 本机安装

Quit the corresponding running pet before replacing its verified app bundle. Keep the same bundle ID and preserve its preferences. These five apps use separate preference domains; never delete other pets or disable system signing/security settings to install. Closing one native multi-pet window is distinct from quitting that app's whole group.

本机现有应用入口保留在 `/Applications`。不要并行运行旧可执行文件和新包，不擅自清用户偏好；卸载时先退出并仅移除目标App。可重建 `build/` 在构建/验证结束后清理，原下载包和必要素材不是缓存。
