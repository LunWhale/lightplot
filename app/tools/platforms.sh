#!/bin/sh
# ============================================================
#  三个 target 都必须能编译。
#
#  iPad 这一段不验证观感（那需要真机），但**不能坏** ——
#  早先加场景 UI 时，iPad 分支缺了两个导出函数，
#  target 悄悄编译失败好几天没人发现。这条就是防它。
# ============================================================
set -e
cd "$(dirname "$0")/.."

fail=0
check() {
  name="$1"; shift
  printf '  %-16s ' "$name"
  if xcodebuild "$@" build >"/tmp/gate_$name.log" 2>&1; then
    echo OK
  else
    echo FAIL
    grep -m3 "error:" "/tmp/gate_$name.log" 2>/dev/null | sed 's/^/      /'
    fail=1
  fi
}

echo "Platform builds"
echo "----------------------------------------------"
check macOS-Debug   -project LightPlot.xcodeproj -scheme LightPlot-macOS   -configuration Debug   -derivedDataPath .build/xcode-rel
check macOS-Release -project LightPlot.xcodeproj -scheme LightPlot-macOS   -configuration Release -derivedDataPath .build/xcode-rel
check iPadOS        -project LightPlot.xcodeproj -scheme LightPlot-iPadOS  -configuration Debug   -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/xcode-ios
echo "----------------------------------------------"
[ "$fail" = "0" ] && echo "all platforms build" || echo "BUILD FAILURES — see /tmp/gate_*.log"
exit $fail
