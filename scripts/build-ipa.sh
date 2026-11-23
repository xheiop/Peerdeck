#!/bin/zsh
# 打 iOS 安装包（Release，arm64，含分享扩展），同一份构建出两个文件：
#   Peerdeck-<版本>-unsigned.ipa   不签名，给 AltStore / SideStore / Sideloadly 这类工具用自己的证书重签
#   Peerdeck-<版本>.tipa           ad-hoc 签名并带上 entitlements，给 TrollStore 装
#
#   scripts/build-ipa.sh [版本号] [构建号]     # 例：scripts/build-ipa.sh 0.2.0 42
#
# 不给版本号就用 iOS/project.yml 里的 MARKETING_VERSION。
# 构建产物放在项目外：$TC_BUILD_DIR（默认 ~/Library/Caches/transclient-build），安装包输出到 $TC_BUILD_DIR/dist。
# 最后两行依次输出 tipa 和 ipa 的路径。
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

# ---- TrollStore 用的 tipa ----
# 未签名的 ipa 里没有 entitlements。TrollStore 装它时只给主程序补一套默认的（钥匙串组 TROLLTROLL.*），分享扩展什么都没有，
# 两边没有共用的钥匙串组和 App Group，扩展就读不到 app 存的服务器。这里照 iOS/project.yml 里的组签上，改了那边要一起改。
# TROLLTROLL 是 TrollStore 自己用的假 Team ID。app 额外留着 TROLLTROLL.* 这个组，才读得到旧版本存的配置（启动时会挪进共享组）。
# AltStore 这类工具重签时按自己的描述文件处理 entitlements，所以给它们的 ipa 保持不签名。
TEAM=TROLLTROLL
SHARED_KEYCHAIN=$TEAM.dev.peerdeck.shared
APP_GROUP=group.dev.peerdeck
TAPP=$STAGE/tipa/Payload/Peerdeck.app
mkdir -p "$STAGE/tipa/Payload"
cp -R "$APP" "$STAGE/tipa/Payload/"
APPEX=$TAPP/PlugIns/PeerdeckShare.appex
[[ -d $APPEX ]] || { echo "没找到 $APPEX" >&2; exit 1; }

# entitlements <输出文件> <bundle id> <钥匙串组…>：第一个钥匙串组是默认组
entitlements() {
  local out=$1 id=$2 groups= g; shift 2
  for g; do groups+="<string>$g</string>"; done
  cat > "$out" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key><string>$TEAM.$id</string>
	<key>com.apple.developer.team-identifier</key><string>$TEAM</string>
	<key>com.apple.security.application-groups</key><array><string>$APP_GROUP</string></array>
	<key>keychain-access-groups</key><array>$groups</array>
</dict>
</plist>
PLIST
  plutil -lint -s "$out" >&2
}
bundle_id() { /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$1/Info.plist" }

entitlements "$STAGE/share.entitlements" "$(bundle_id "$APPEX")" "$SHARED_KEYCHAIN"
entitlements "$STAGE/app.entitlements" "$(bundle_id "$TAPP")" "$SHARED_KEYCHAIN" "$TEAM.*"
# 先签扩展再签 app：app 的签名会封住 PlugIns 里已经签好的扩展
codesign --force --sign - --timestamp=none --entitlements "$STAGE/share.entitlements" "$APPEX" >&2
codesign --force --sign - --timestamp=none --entitlements "$STAGE/app.entitlements" "$TAPP" >&2
TIPA=$DIST/Peerdeck-$VERSION.tipa
rm -f "$TIPA"
(cd "$STAGE/tipa" && zip -qry "$TIPA" Payload)

echo "$TIPA"
echo "$OUT"
