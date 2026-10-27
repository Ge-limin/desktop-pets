#!/bin/bash
# Source-only workspace; media is user-supplied and git-ignored. No installation.
set -euo pipefail
cd "$(dirname "$0")"
case "${1:-all}" in
  all) targets=(sun shaolan goodthing nailong cats) ;;
  sun|shaolan|goodthing|nailong|cats) targets=("$1") ;;
  *) echo 'Usage: ./build.sh [all|sun|shaolan|goodthing|nailong|cats]' >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || exit 2
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'Apple Silicon macOS required' >&2; exit 1; }
for target in "${targets[@]}"; do
  media=".local-media/$target"
  [[ -d "$media" ]] || { echo "Missing local media: $media (see docs/MEDIA.md)" >&2; exit 1; }
  frameworks=(-framework AppKit -framework AVFoundation)
  case "$target" in
    sun) dir=Apps/Human/targets/sun; name=SunPet; executable=SunPet; bundleID=com.ganzhe2028.sunpet; frameworks+=(-framework IOKit -framework Network) ;;
    shaolan) dir=Apps/Human/targets/shaolan; name=薄肌桌宠; executable=ShaolanPet; bundleID=local.shaolan.desktop-pet ;;
    goodthing) dir=Apps/Human/targets/goodthing; name=好事桌宠; executable=GoodThingPet; bundleID=local.goodthing.desktop-pet ;;
    nailong) dir=Apps/Nailong; name=奶龙桌宠; executable=NailongPet; bundleID=local.nailong.desktop-pet ;;
    cats) dir=Apps/Cats; name=猫梗桌宠; executable=CatMemePets; bundleID=local.cat-meme.desktop-pets ;;
  esac
  app="build/$name.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" build/module-cache build/logs
  echo "Building $target"
  swiftc -O -module-cache-path "$PWD/build/module-cache" -target arm64-apple-macosx14.0 "${frameworks[@]}" "$dir"/Sources/*.swift Shared/ImmediateVoicePicker.swift -o "$app/Contents/MacOS/$executable"
  ditto "$media" "$app/Contents/Resources"
  # License files are plain files, not role directories interpreted by Cats' loader.
  cp Licenses/ShaolanPet-MIT.txt "$app/Contents/Resources/LICENSE-ShaolanPet.txt"
  cp CREDITS.md "$app/Contents/Resources/CREDITS.md"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$executable</string>
<key>CFBundleIdentifier</key><string>$bundleID</string>
<key>CFBundleName</key><string>$name</string>
<key>CFBundleDisplayName</key><string>$name</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.1</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
  if [[ -f "$dir/Info.plist" ]]; then
    # Preserve original app identities/icons, update version to identify the local build.
    cp "$dir/Info.plist" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 2.1' "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 3' "$app/Contents/Info.plist"
    for license in "$dir/Upstream/LICENSE" "$dir/Upstream/LICENSE-SunPet" "$dir/Upstream/NOTICE.md"; do
      [[ ! -f "$license" ]] || cp "$license" "$app/Contents/Resources/$(basename "$license")"
    done
  fi
  plutil -lint "$app/Contents/Info.plist"
  codesign --force --sign - "$app"
  codesign --verify --deep --strict "$app"
  "$app/Contents/MacOS/$executable" --self-test 2>&1 | tee "build/logs/$target-self-test.log"
  echo "PASS build/self-test: $app"
done
