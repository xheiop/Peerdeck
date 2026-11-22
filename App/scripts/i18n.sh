#!/bin/zsh
# 更新界面文案的本地化：带 -emit-localized-strings 编译一遍，把提取到的字符串同步进
# Sources/Peerdeck/Resources/*.xcstrings，再写入 scripts/i18n_zh.py 里的中文译文。
# 源语言是英文：代码里写英文原文。加了新文案、跑完提示「缺中文译文」时，去 i18n_zh.py 补上再跑一次。
#
#   App/scripts/i18n.sh
set -euo pipefail
HERE=${0:A:h}
APP_DIR=${HERE:h}
BUILD_DIR=${TC_BUILD_DIR:-$HOME/Library/Caches/transclient-build}
OUT=$BUILD_DIR/stringsdata
RES=$APP_DIR/Sources/Peerdeck/Resources

# 每次全量编译，避免增量编译漏掉没改过的文件
rm -rf "${OUT:?}" "${BUILD_DIR:?}/spm-app-strings"
mkdir -p "$OUT"
swift build -c debug --package-path "$APP_DIR" --scratch-path "$BUILD_DIR/spm-app-strings" \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT" >&2
# iOS（M2）的界面文案：用 xcodebuild 编一遍 iOS 工程（project.yml 里开了 SWIFT_EMIT_LOC_STRINGS），收集它的 .stringsdata。
# 两边共用同一份 Localizable.xcstrings；文件名加前缀，避免和 mac 的同名文件互相覆盖
IOS_DIR=${APP_DIR:h}/iOS
if [[ -f "$IOS_DIR/project.yml" ]] && command -v xcodegen >/dev/null; then
  (cd "$IOS_DIR" && xcodegen --quiet) >&2
  IOS_DD=$BUILD_DIR/ios-strings-dd
  rm -rf "${IOS_DD:?}"
  xcodebuild -project "$IOS_DIR/Peerdeck.xcodeproj" -scheme Peerdeck -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$IOS_DD" -quiet build >&2
  find "$IOS_DD/Build/Intermediates.noindex" -name '*.stringsdata' | while read -r f; do
    cp "$f" "$OUT/ios-$(basename "${f:h:h:h:h}")-$(basename "$f")"
  done
else
  echo "（没有 xcodegen 或 iOS 工程，跳过 iOS 文案）" >&2
fi

# 每个字符串表一个 catalog（Localizable，以及按语境区分译法的 Groups 等）
for t in $(python3 -c 'import sys,os; sys.path.insert(0,sys.argv[1]); from i18n_zh import TABLES; print(" ".join(["Localizable",*TABLES]))' "$HERE"); do
  [[ -f "$RES/$t.xcstrings" ]] || echo '{"sourceLanguage":"en","strings":{},"version":"1.0"}' > "$RES/$t.xcstrings"
done
xcrun xcstringstool sync "$RES"/*.xcstrings --stringsdata "$OUT"/*.stringsdata
for c in "$RES"/*.xcstrings; do python3 "$HERE/i18n.py" "$c"; done
