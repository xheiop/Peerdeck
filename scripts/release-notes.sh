#!/bin/zsh
# 从 CHANGELOG.md 里取出某个版本的那一节，用作 GitHub Release 的说明。
#
#   scripts/release-notes.sh 0.2.0
#
# 版本标题的格式是 `## [0.2.0] - 2026-12-01`。找不到这个版本，或者这一节是空的，就以非零退出：
# 发版前必须先写 changelog。
set -euo pipefail

VERSION=${1:?用法：scripts/release-notes.sh <版本号>}
FILE=${0:A:h:h}/CHANGELOG.md

NOTES=$(awk -v v="$VERSION" '
  /^## \[/ { if (found) exit; if (index($0, "## [" v "]") == 1) { found = 1; next } }
  /^\[[^]]+\]: / { if (found) exit }
  found { print }
' "$FILE")

# 去掉首尾空行
NOTES=$(print -r -- "$NOTES" | sed -e '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')
if [[ -z ${NOTES//[[:space:]]/} ]]; then
  echo "CHANGELOG.md 里没有 [$VERSION] 这一节，或者这一节是空的" >&2
  exit 1
fi
print -r -- "$NOTES"
