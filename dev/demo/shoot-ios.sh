#!/bin/zsh
# 拍 iOS 模拟器截图。app 要先装进模拟器；状态栏可以先固定成 9:41、满电：
#   xcrun simctl status_bar <设备> override --time 9:41 --batteryState discharging --batteryLevel 100 --wifiBars 3 --cellularMode notSupported
#   dev/demo/shoot-ios.sh <en|zh> <输出.png> <等待秒数> [VAR=值…]   # 变量加上 SIMCTL_CHILD_ 前缀传给 app
# 设备默认是已经启动的那台，可以用 SIM=<UDID> 指定
set -e
D=${0:A:h}
U=${SIM:-booted}
L=$1; OUT=$2; WAIT=$3; shift 3
DATA=${TC_BUILD_DIR:-$HOME/Library/Caches/transclient-build}/demo-data-ios-$L
mkdir -p $DATA
[[ -f $DATA/prefs.json ]] || print -n '{"mediaInfo": true}' > $DATA/prefs.json
lang=$([[ $L == zh ]] && echo zh-Hans || echo en)
xcrun simctl terminate $U dev.peerdeck.ios 2>/dev/null || true
vars=(SIMCTL_CHILD_TC_CONFIG_FILE=$D/servers.json SIMCTL_CHILD_TC_DATA_DIR=$DATA)
for v in "$@"; do vars+=("SIMCTL_CHILD_$v"); done
env $vars xcrun simctl launch $U dev.peerdeck.ios -AppleLanguages "($lang)" >/dev/null
sleep $WAIT
xcrun simctl io $U screenshot --type=png "$OUT" >/dev/null 2>&1
echo "$OUT"
