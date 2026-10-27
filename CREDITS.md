# Credits / 致谢与来源

This repository consolidates local native desktop-pet adaptations. It is not an official product of the people, characters, or projects depicted. Credit does **not** grant media redistribution rights.

本仓库整合本机原生桌宠改造，不代表相关人物、角色或上游作者的官方产品。**保留署名不等于取得照片、声音、视频或角色的授权。**

## Native code / 原生代码

| Project / 项目 | Author / 原作者 | Source revision / 复用版本 | Contribution / 复用内容 |
|---|---|---|---|
| [SunPet](https://github.com/Ganzhe2028/SunPet) | Ganzhe2028 | `9b68d0911552d8c880a46ca72980d3f9af9743ee` | Native panel, original voice-player/companion protocol and optional motion input / 原生窗口、语音播放、接话协议及机身摇晃 |
| [ShaolanPet](https://github.com/Ganzhe2028/ShaolanPet) | Ganzhe2028 | `7ce7e2b1ed49c4da66d19d5aac419794af0d32db` | Native desktop base, controls, audio ownership and build/test approach / 原生桌宠底座、控制、音频生命周期、构建自检 |
| [FengGe-Desktop-Pet](https://github.com/Ganzhe2028/FengGe-Desktop-Pet) | Ganzhe2028; upstream notice credits [yuhanfu513-ops](https://github.com/yuhanfu513-ops/FengGe-Desktop-Pet) | `d3336debfafc37963ec5612cb27793e250228b9b` | FengGe native pet and companion behavior / 峰哥桌宠及接话 |

Original MIT texts, copyright notices and upstream NOTICE files are retained in `Apps/Human/targets/*/Upstream/` and `Licenses/`. The SunPet pin is the audited Bridge-aware source used for local adaptation, not a claim that the official release binary was built byte-for-byte from it.

上游 MIT 原文、版权声明与 NOTICE 原样保留。整合版新增共享即时选择器、统一操作、设置恢复和猫音画播放；不抹除原作者署名。SunPet 使用与功能相符的已审阅源码，不冒称官方二进制与该源码逐字节对应。

## Media and inspiration / 素材与玩法来源

- [Dragon-frog](https://github.com/VIPmrgj/Dragon-frog), **VIPmrgj**, revision `1ab13408da6a40d757189c23831c15f8a2324a5f`: original Nailong web toy and image/audio selection. No LICENSE was found in the reviewed revision. Its PNG/WAV assets are **local-only**, not covered by this repository's code license. The old web spring/drag-physics port is not included in the unified published-code candidate. / 奶龙网页玩具及图声选材来源；所审版本未声明许可证，素材仅本机使用，旧网页弹簧移植不纳入可公开代码候选。
- **孙宇晨、邵艾伦、峰哥及各原录音/照片权利人**: portraits and original speech used in local media packs; code MIT does not license their likenesses or recordings. Upstream media notices are retained. / 真人头像与录音独立归原权利人。
- **Cat meme creators and original image/audio/video rightsholders**: the user-provided meme pack is not an authorship or license certificate. Exact selected local-file hashes/time ranges/processing are in private per-role manifests. Original author information is not consistently present in that pack; unknown authors are explicitly unresolved, not attributed to the downloader or this project. / 猫梗原作者与图声视频权利人：用户提供的集合不构成授权或作者证明。无法从包中核实的作者明确待确认，不把下载者或本项目署为原作者。
- Historical local prototypes used **林芷伊kiwi** (Bilibili UID `16993069`, `BV1Lz7Yz2EUd`) and **超级无敌大开门** (`BV1Kvq2BiEqT`). Those media were replaced at the user's request and are **not shipped in the current cat pack**. This acknowledgement records prototype history, not a redistribution grant. / 早期原型参考记录；当前猫包已不含这些素材。

## Publication boundary / 开源边界

The repository publishes source code under its retained licenses. `.local-media/`, `.local-config/`, `.local-evidence/` and `build/` are ignored and must not be uploaded or included in public binaries. Use your own permitted assets; check both source and media permissions before any release. Source publication does not establish media rights clearance or authorize a media-containing binary release.

公开内容是源代码与合法许可文件，不是本机有媒体的安装包。未完成作者/权限核验的素材不能因附上credit就公开。源码开源不代表完成素材授权核验，也不代表可以分发含素材的安装包。
