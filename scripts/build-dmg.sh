#!/bin/zsh
# 打 macOS 的 dmg（Release，arm64 + x86_64）。app 是 ad-hoc 签名，没有公证：
# 从网上下载后第一次打开会被 Gatekeeper 拦，要到「系统设置 → 隐私与安全性」点「仍要打开」
# （macOS 15 起右键「打开」不能再绕过），或者 xattr -dr com.apple.quarantine。
#
#   scripts/build-dmg.sh [版本号] [构建号]     # 例：scripts/build-dmg.sh 0.2.0 42
#
# 不给版本号就用 App/Sources/Peerdeck/Resources/Info.plist 里的。
# 本地想快一点、只编本机架构：TC_UNIVERSAL=0 scripts/build-dmg.sh
# dmg 输出到 $TC_BUILD_DIR/dist（默认 ~/Library/Caches/transclient-build/dist）。最后一行输出 dmg 的路径。
set -euo pipefail

ROOT=${0:A:h:h}
BUILD_DIR=${TC_BUILD_DIR:-$HOME/Library/Caches/transclient-build}
export TC_BUILD_DIR=$BUILD_DIR
export TC_UNIVERSAL=${TC_UNIVERSAL:-1}
[[ -n ${1:-} ]] && export TC_VERSION=$1
[[ -n ${2:-} ]] && export TC_BUILD_NUMBER=$2
DIST=$BUILD_DIR/dist

APP=$(zsh "$ROOT/App/scripts/build-mac.sh" release | tail -1)
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$DIST"
OUT=$DIST/Peerdeck-$VERSION.dmg
rm -f "$OUT"
hdiutil create -volname "Peerdeck $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT" >&2
echo "$OUT"
