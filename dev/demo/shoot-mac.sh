#!/bin/zsh
# 拍 mac 窗口截图（app 的 TC_SNAPSHOT 调试开关，不需要屏幕录制权限）。先用 App/scripts/build-mac.sh 构建，查影视信息要内置密钥（TMDB_API_KEY）。
#   dev/demo/shoot-mac.sh <en|zh> <输出前缀> [VAR=值…]
# 偏好和缓存放在 $TC_BUILD_DIR/demo-data-<语言>（默认 ~/Library/Caches/transclient-build），默认打开影视信息
set -e
D=${0:A:h}
L=$1; OUT=$2; shift 2
DATA=${TC_BUILD_DIR:-$HOME/Library/Caches/transclient-build}/demo-data-$L
mkdir -p $DATA
[[ -f $DATA/prefs.json ]] || print -n '{"mediaInfo": true}' > $DATA/prefs.json
lang=$([[ $L == zh ]] && echo zh-Hans || echo en)
env -u TMDB_API_KEY TC_DATA_DIR=$DATA TC_CONFIG_FILE=$D/servers.json TC_SNAPSHOT=$OUT TC_SNAPSHOT_AT=${AT:-14} TC_SNAPSHOT_EXIT=1 "$@" \
  ${TC_BUILD_DIR:-$HOME/Library/Caches/transclient-build}/Peerdeck.app/Contents/MacOS/Peerdeck -AppleLanguages "($lang)" -ApplePersistenceIgnoreState YES >/dev/null 2>&1
