#!/bin/zsh
# 打一个不签名的 iOS ipa（Release，arm64，含分享扩展）。装到设备前要用自己的工具重签。
#
#   scripts/build-ipa.sh [版本号] [构建号]     # 例：scripts/build-ipa.sh 0.2.0 42
#
# 不给版本号就用 iOS/project.yml 里的 MARKETING_VERSION。
# 构建产物放在项目外：$TC_BUILD_DIR（默认 ~/Library/Caches/transclient-build），ipa 输出到 $TC_BUILD_DIR/dist。
# 最后一行输出 ipa 的路径。
set -euo pipefail

ROOT=${0:A:h:h}
BUILD_DIR=${TC_BUILD_DIR:-$HOME/Library/Caches/transclient-build}
VERSION=${1:-}
BUILD_NUMBER=${2:-}
DD=$BUILD_DIR/ios-release-dd
DIST=$BUILD_DIR/dist

command -v xcodegen >/dev/null || { echo "缺 xcodegen：brew install xcodegen" >&2; exit 1; }
(cd "$ROOT/iOS" && xcodegen --quiet) >&2

overrides=()
[[ -n $VERSION ]] && overrides+=(MARKETING_VERSION=$VERSION)
[[ -n $BUILD_NUMBER ]] && overrides+=(CURRENT_PROJECT_VERSION=$BUILD_NUMBER)

xcodebuild -project "$ROOT/iOS/Peerdeck.xcodeproj" -scheme Peerdeck -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  $overrides build >&2

APP=$DD/Build/Products/Release-iphoneos/Peerdeck.app
[[ -d $APP ]] || { echo "没找到 $APP" >&2; exit 1; }
[[ -z $VERSION ]] && VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Info.plist")

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload" "$DIST"
cp -R "$APP" "$STAGE/Payload/"
OUT=$DIST/Peerdeck-$VERSION-unsigned.ipa
rm -f "$OUT"
(cd "$STAGE" && zip -qry "$OUT" Payload)
echo "$OUT"
