#!/bin/zsh
# 构建 Peerdeck.app。构建产物放在项目外（默认 ~/Library/Caches/transclient-build）。
#
#   App/scripts/build-mac.sh            # release
#   App/scripts/build-mac.sh debug
#
# 可选环境变量：
#   TC_VERSION=0.2.0      覆盖 CFBundleShortVersionString（默认用 Resources/Info.plist 里的）
#   TC_BUILD_NUMBER=42    覆盖 CFBundleVersion
#   TC_UNIVERSAL=1        同时编 arm64 和 x86_64（发布用；本地默认只编本机架构）
#
# 输出 .app 路径。签名是 ad-hoc：每次重新构建签名都会变，读 Keychain 时系统可能会再问一次。
set -euo pipefail

CONFIG=${1:-release}
HERE=${0:A:h}
APP_DIR=${HERE:h}
BUILD_DIR=${TC_BUILD_DIR:-$HOME/Library/Caches/transclient-build}
SCRATCH=$BUILD_DIR/spm-app

ARCHS=()
[[ ${TC_UNIVERSAL:-} == 1 ]] && ARCHS=(--arch arm64 --arch x86_64)
swift build -c "$CONFIG" --package-path "$APP_DIR" --scratch-path "$SCRATCH" $ARCHS --product Peerdeck >&2
BIN=$(swift build -c "$CONFIG" --package-path "$APP_DIR" --scratch-path "$SCRATCH" $ARCHS --show-bin-path)/Peerdeck

OUT=$BUILD_DIR/Peerdeck.app
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/Peerdeck"
cp "$APP_DIR/Sources/Peerdeck/Resources/Info.plist" "$OUT/Contents/Info.plist"
[[ -n ${TC_VERSION:-} ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $TC_VERSION" "$OUT/Contents/Info.plist"
[[ -n ${TC_BUILD_NUMBER:-} ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $TC_BUILD_NUMBER" "$OUT/Contents/Info.plist"
# 本地化：英文是源语言（键本身），编译出 zh-Hans.lproj（以及英文单复数用的 en.lproj）；
# en.lproj 至少要有个空目录，系统才知道 app 支持英文
for c in "$APP_DIR"/Sources/Peerdeck/Resources/*.xcstrings; do
  xcrun xcstringstool compile "$c" --output-directory "$OUT/Contents/Resources" >&2
done
mkdir -p "$OUT/Contents/Resources/en.lproj"
# 图标：Icon Composer 的 .icon（和 iOS 共用），编译成 Assets.car（macOS 26 的分层图标）+ AppIcon.icns（旧系统用）
xcrun actool "$APP_DIR/AppIcon.icon" --compile "$OUT/Contents/Resources" --platform macosx \
  --minimum-deployment-target 15.0 --app-icon AppIcon \
  --output-partial-info-plist "$BUILD_DIR/actool-partial.plist" >/dev/null 2>&1
codesign --force --sign - "$OUT" >&2
echo "$OUT"
