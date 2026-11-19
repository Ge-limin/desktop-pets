# Local media / 本机素材

Code and media have separate permissions. See [credits](../CREDITS.md). The public clone contains only the three separately permitted [Nailong jacket sprites](../Apps/Nailong/Assets/JacketSkin/) as media; it contains **no other portraits, voice clips, cat videos, or packaged applications**.

代码与素材权限分开。公开仓库仅包含三张获准发布的奶龙羽绒服皮肤，不包含其他真人照片、录音、猫视频或带媒体安装包；没有其余素材时构建会明确失败，不自动联网下载或生成冒充素材。

## Layout / 布局

Supply personally permitted media under the ignored `.local-media/` directory:

```text
.local-media/
  sun/          # original SunPet Contents/Resources layout
  shaolan/      # original ShaolanPet Contents/Resources layout
  goodthing/    # original GoodThingPet Contents/Resources layout
  nailong/      # 图片/*.png + 音效/*.wav
  cats/
    <role-id>/
      metadata.json
      face.png
      Clips/original.m4a
      Animation/00000.png ...
```

The three human targets retain their upstream `clips.json` layouts and require their corresponding exact media, not a shared generic sound folder. Nailong filenames and schemas are defined in its source. The Cat target loads its role directories dynamically; the bundled self-tests validate the original ten-role catalog, not arbitrary replacement catalogs. Those IDs are `angry-cat`, `bababoy-cat`, `banana-cat`, `giggle-cat`, `happy-cat`, `huh-cat`, `oiiai-cat`, `orange-question-cat`, `question-cat`, and `sad-cat`.

For Nailong, provide the six original WAV files and the local image directory as before. `build.sh nailong` replaces only the closed, open, and laugh images with the published jacket skin. The other local files are not published.

三个真人目标沿用各自上游资源结构，不能混用同名素材。猫角色按目录动态加载，但随仓自测验收的是上述固定10角色及真人28/37/11段、奶龙6段素材，并非任意替换素材集。自行提供素材前核实授权；公开仓库能下载不等于可重发素材。

## Cat metadata / 猫元数据

```json
{
  "id": "example-cat",
  "name": "Example cat",
  "image": "face.png",
  "clips": [{
    "id": "original",
    "label": "Original clip",
    "file": "Clips/original.m4a",
    "animation": {
      "directory": "Animation",
      "fps": 24,
      "frameCount": 72,
      "width": 240,
      "height": 320,
      "duration": 3.0
    }
  }]
}
```

These numbers are a schema example, **not bundled media**. Animation frames are zero-based, fixed-canvas RGBA PNGs; all frames use the same crop, scale, and padding. Runtime must use the audio player's actual time, not a separate advancing frame clock. Private manifests may include original local file paths, SHA-256 and processing records; do not publish those manifests unreviewed.

示例只解释schema，没有占位媒体混入实际应用。音画同源同起点，完整标志动作不能被固定几秒硬切；每帧尺寸/裁切一致，按实际音频播放时钟取帧。

## Preparing a user's cat pack / 处理用户猫包

For an existing private role catalog whose metadata identifies the permitted local source clips:

```sh
python3 scripts/prepare-cat-animations.py \
  --source-root "/path/to/your/cat-pack" \
  --media-root .local-media/cats --cats happy-cat oiiai-cat
```

The preparation tool uses already installed FFmpeg/FFprobe and Pillow (offline build-time tools, not app runtime dependencies), does not install anything, and never writes the source pack. It produces a full-alpha union-cropped animation, complete aligned audio, provenance, and private contact-sheet verification. Review the result before processing the rest. It does not crawl a 24GB pack or infer rights from filenames.

准备工具只读原包，不自动安装依赖、不把整个素材包复制进仓库；真实选择名单由操作者确认。图声权利、音轨中可能包含的音乐/配音、人物肖像与商标都需要单独判断。

## Release rule / 发布规则

Before publishing, run `python3 scripts/check-public-tree.py`. The check allows only the three reviewed jacket PNGs as media and rejects other media/binary/archive files, private folders accidentally staged, and machine-specific paths. It cannot prove legal authorization. Do not upload `.local-media/`, `.local-config/`, `.local-evidence/`, `build/`, or the user's download pack. The published skin notice does not grant a license to redistribute other media or a prebuilt app.
