#!/bin/bash
# 一键构建：./build-online.sh          → 构建到暂存路径 ../.staging/维基在线.app 并校验
#           ./build-online.sh install  → 构建后把旧版备份到 App/backups/，再替换 ../维基在线.app
#   - release 编译 SwiftUI App 与预翻译 worker
#   - 把 libzim 及其依赖（xapian / icu / zstd / xz）拷进 Contents/Frameworks 并改写 install name
#   - ad-hoc 签名，最后校验 .app 不再引用 /opt/homebrew
set -euo pipefail
export LC_ALL=en_US.UTF-8

cd "$(dirname "$0")"
ROOT="$(pwd)"
OUT_DIR="$(cd .. && pwd)"
FINAL="$OUT_DIR/维基在线.app"
mkdir -p "$OUT_DIR/.staging"
APP="$OUT_DIR/.staging/维基在线.app"
CONTENTS="$APP/Contents"
FW="$CONTENTS/Frameworks"

# 图标：如果放了 Resources/AppIcon-source.png（正方形，建议 1024×1024），自动重新生成 AppIcon.icns
if [ -f Resources/AppIcon-source.png ]; then
  if [ ! -f Resources/AppIcon.icns ] || [ Resources/AppIcon-source.png -nt Resources/AppIcon.icns ]; then
    echo "▸ 生成图标（AppIcon-source.png → AppIcon.icns）…"
    if swiftc -O scripts/makeicon.swift -o /tmp/wiki-makeicon 2>/dev/null \
       && /tmp/wiki-makeicon Resources/AppIcon-source.png /tmp/AppIcon.iconset >/dev/null \
       && iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns; then
      echo "  图标已更新"
    else
      echo "  ⚠︎ 图标生成失败，沿用现有 AppIcon.icns"
    fi
  fi
fi

echo "▸ 编译（release）…"
swift build -c release --product WikiOnline 2>&1 | grep -vE "^\[|^Compiling|^Write|^Emitting|^Building|^Linking|^Applying" || true
BIN="$(swift build -c release --show-bin-path)"
test -x "$BIN/WikiOnline" || { echo "✗ 编译失败"; exit 1; }

echo "▸ 组装 $APP"
rm -rf "$APP.tmp"
mkdir -p "$APP.tmp/Contents/MacOS" "$APP.tmp/Contents/Resources/zh-Hans.lproj" "$APP.tmp/Contents/Frameworks"
cp "$BIN/WikiOnline" "$APP.tmp/Contents/MacOS/WikiOnline"
cp Resources/online-reader.css "$APP.tmp/Contents/Resources/reader.css"
cp Resources/online-reader.js "$APP.tmp/Contents/Resources/reader.js"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP.tmp/Contents/Resources/"; fi
printf '"CFBundleDisplayName" = "维基在线";\n"CFBundleName" = "维基在线";\n' > "$APP.tmp/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"
cat > "$APP.tmp/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>WikiOnline</string>
  <key>CFBundleIdentifier</key><string>local.wikionline.reader</string>
  <key>CFBundleName</key><string>维基在线</string>
  <key>CFBundleDisplayName</key><string>维基在线</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
  <key>CFBundleLocalizations</key><array><string>zh-Hans</string></array>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.reference</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

echo "▸ 打包依赖库…"
# 递归收集 /opt/homebrew 依赖，拷贝并改写为 @rpath
queue=("$APP.tmp/Contents/MacOS/WikiOnline")
[ -f "$APP.tmp/Contents/MacOS/wikipretranslate" ] && queue+=("$APP.tmp/Contents/MacOS/wikipretranslate")
declare -a done_libs=()
is_done() { local x; for x in "${done_libs[@]:-}"; do [ "$x" = "$1" ] && return 0; done; return 1; }
while [ ${#queue[@]} -gt 0 ]; do
  f="${queue[0]}"; queue=("${queue[@]:1}")
  chmod u+w "$f"
  for dep in $(otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -E '^/opt/homebrew/|^@rpath/|^@loader_path/' || true); do
    name="$(basename "$dep")"
    # @loader_path/xxx：到 Homebrew 的 lib 目录里找原件（例如 ICU 的 libicudata）
    if [[ "$dep" == @loader_path/* ]] && [ ! -f "$APP.tmp/Contents/Frameworks/$name" ]; then
      src="$(ls /opt/homebrew/opt/*/lib/"$name" 2>/dev/null | head -1 || true)"
      if [ -n "$src" ]; then
        cp "$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$src")" "$APP.tmp/Contents/Frameworks/$name"
        chmod u+w "$APP.tmp/Contents/Frameworks/$name"
        install_name_tool -id "@rpath/$name" "$APP.tmp/Contents/Frameworks/$name" 2>/dev/null
        done_libs+=("$name")
        queue+=("$APP.tmp/Contents/Frameworks/$name")
      else
        echo "  ✗ 找不到 $dep"; exit 1
      fi
    fi
    if [[ "$dep" == /opt/homebrew/* ]]; then
      if ! is_done "$name"; then
        real="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$dep")"
        cp "$real" "$APP.tmp/Contents/Frameworks/$name"
        chmod u+w "$APP.tmp/Contents/Frameworks/$name"
        install_name_tool -id "@rpath/$name" "$APP.tmp/Contents/Frameworks/$name" 2>/dev/null
        install_name_tool -add_rpath "@loader_path" "$APP.tmp/Contents/Frameworks/$name" 2>/dev/null || true
        done_libs+=("$name")
        queue+=("$APP.tmp/Contents/Frameworks/$name")
      fi
      install_name_tool -change "$dep" "@rpath/$name" "$f" 2>/dev/null
    fi
  done
done
for exe in "$APP.tmp/Contents/MacOS/"*; do
  otool -l "$exe" | grep -q "@executable_path/../Frameworks" || install_name_tool -add_rpath "@executable_path/../Frameworks" "$exe"
done

echo "▸ 校验不再依赖 Homebrew…"
bad=0
for f in "$APP.tmp/Contents/MacOS/"* "$APP.tmp/Contents/Frameworks/"*; do
  if otool -L "$f" | tail -n +2 | grep -q "/opt/homebrew"; then echo "  ✗ $f 仍引用 /opt/homebrew"; otool -L "$f" | grep /opt/homebrew; bad=1; fi
done
[ $bad -eq 0 ] || exit 1

echo "▸ ad-hoc 签名…"
for f in "$APP.tmp/Contents/Frameworks/"*.dylib; do codesign --force --sign - --timestamp=none "$f" >/dev/null 2>&1; done
[ -f "$APP.tmp/Contents/MacOS/wikipretranslate" ] && codesign --force --sign - --timestamp=none "$APP.tmp/Contents/MacOS/wikipretranslate" >/dev/null 2>&1
codesign --force --sign - --timestamp=none "$APP.tmp" >/dev/null
codesign --verify --strict "$APP.tmp" && echo "  签名校验通过"

rm -rf "$APP"
mv "$APP.tmp" "$APP"
du -sh "$APP" | awk '{print "✓ 暂存构建完成：" $2 "（" $1 "）"}'

if [ "${1:-}" = "install" ]; then
  mkdir -p "$ROOT/backups"
  if [ -d "$FINAL" ]; then
    BK="$ROOT/backups/维基在线-$(date +%Y%m%d-%H%M%S).app"
    mv "$FINAL" "$BK"
    echo "  旧版已备份：$BK"
  fi
  mv "$APP" "$FINAL"
  echo "✓ 已安装：$FINAL"
fi
