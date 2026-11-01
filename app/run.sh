#!/bin/sh
# ============================================================
#  LightPlot 一键脚本
#
#  用法：
#     ./run.sh                 出全套图（默认 data/rig.yaml）
#     ./run.sh my_rig.yaml     用别的数据文件
#     ./run.sh --check         只校验，不出图（改完数据先跑这个）
#     ./run.sh --verify        只跑与旧管线的比对
#     ./run.sh --app           编译并打开图形应用
#
#  它做三件事，任何一步不过就停，绝不产出"看起来对"的图：
#     1. 数据校验     —— 有错就不出图
#     2. 出全套交付物 —— PDF + CSV 到 out_lpx/
#     3. 与旧管线比对 —— 逐灯核对色片、页码、比例
# ============================================================
set -eu
cd "$(dirname "$0")"

MODE="build"
case "${1:-}" in
  --check)  MODE="check";  shift ;;
  --verify) MODE="verify"; shift ;;
  --app)    MODE="app";    shift ;;
  -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

DATA="${1:-../data/rig.yaml}"
OUT="${LPX_OUT:-../out_lpx}"

if [ ! -f "$DATA" ]; then
  echo "找不到数据文件：$DATA" >&2
  exit 1
fi

# scenes.yaml 与 rig.yaml 放在一起时自动带上（场景图需要它）
DATA_DIR=$(dirname "$DATA")
SCENES="$DATA_DIR/scenes.yaml"
[ -f "$SCENES" ] || SCENES=""

hr() { printf '%s\n' "=============================================="; }
step() { printf '\n[%s] %s\n' "$1" "$2"; }

# ------------------------------------------------------------
# --app：编译并打开图形应用
#
# 这是文科生真正要用的入口。命令行那套是给自动化与回归用的。
# ------------------------------------------------------------
if [ "$MODE" = "app" ]; then
  hr
  echo " LightPlot — 打开应用"
  hr
  step "1/2" "编译应用 ..."
  if ! xcodebuild -project LightPlot.xcodeproj -scheme LightPlot-macOS \
        -configuration Release -derivedDataPath .build/xcode-app build \
        > /tmp/lpx_app_build.log 2>&1; then
    echo "  编译失败。完整输出在 /tmp/lpx_app_build.log" >&2
    grep -m5 "error:" /tmp/lpx_app_build.log >&2
    exit 1
  fi
  echo "  OK"

  step "2/2" "打开 ..."
  APP=".build/xcode-app/Build/Products/Release/LightPlot.app"
  if [ ! -d "$APP" ]; then
    echo "  找不到 $APP" >&2
    exit 1
  fi
  open "$APP"
  echo "  已打开。关掉窗口就是退出。"
  hr
  exit 0
fi

hr
echo " LightPlot"
echo " 数据：$DATA"
[ -n "$SCENES" ] && echo " 场景：$SCENES"
echo " 输出：$OUT"
hr

# ------------------------------------------------------------
# 1. 编译
# ------------------------------------------------------------
step "1/6" "编译 ..."
if ! swift build -c release --product lpx >/dev/null 2>&1; then
  echo "  编译失败。下面是完整输出：" >&2
  swift build -c release --product lpx
  exit 1
fi
LPX="$(swift build -c release --product lpx --show-bin-path)/lpx"
echo "  OK"

# ------------------------------------------------------------
# 2. 数据校验（硬门禁）
# ------------------------------------------------------------
step "2/6" "数据校验 ..."
if "$LPX" lint "$DATA" --strict > /tmp/lpx_lint.txt 2>&1; then
  echo "  没有发现问题"
else
  echo "" >&2
  echo "  数据有错，不出图。问题如下：" >&2
  sed 's/^/    /' /tmp/lpx_lint.txt >&2
  exit 1
fi

if [ "$MODE" = "check" ]; then
  echo ""
  echo " 只校验模式 —— 不出图"
  exit 0
fi

# ------------------------------------------------------------
# 3. 出全套交付物
# ------------------------------------------------------------
if [ "$MODE" = "build" ]; then
  step "3/6" "出图 ..."
  mkdir -p "$OUT"

  echo "  平面图 (A1 @ 1:25) ..."
  "$LPX" render "$DATA" "$OUT/LX_plan.pdf" | sed 's/^/    /'

  echo "  剖面图 (A3 @ 1:50) ..."
  "$LPX" section "$DATA" "$OUT/LX_section.pdf" | sed 's/^/    /'

  if [ -n "$SCENES" ]; then
    echo "  场景图 ..."
    "$LPX" scene "$DATA" "$SCENES" "$OUT" | sed 's/^/    /'
    "$LPX" section-state "$DATA" "$SCENES" "$OUT" | sed 's/^/    /'
    echo "  表格 ..."
    "$LPX" csv "$DATA" "$OUT" "$SCENES" | sed 's/^/    /'
  else
    echo "  （没有 scenes.yaml，跳过场景图与场景表）"
    "$LPX" csv "$DATA" "$OUT" | sed 's/^/    /'
  fi
else
  step "3/6" "出图 ..."
  echo "  跳过（--verify 模式）"
fi

# ------------------------------------------------------------
# 4. 与旧管线比对
#
#    旧 Python 管线的产出在 ../out/。它是冻结的参考答案 ——
#    逐灯核对色片、灯具总数、纸张、比例。
# ------------------------------------------------------------
step "4/6" "与旧管线比对 ..."
if [ -d ../out ] && [ -f ../out/LX_plan.pdf ]; then
  if "$LPX" verify-old "$DATA" ../out 2>&1 | sed 's/^/  /'; then
    :
  else
    echo "" >&2
    echo "  与旧管线不一致。上面标 FAIL 的行就是差异。" >&2
    exit 2
  fi
else
  echo "  跳过（找不到 ../out/ 里的参考 PDF）"
fi

# ------------------------------------------------------------
# 5. 平台编译门禁
#
#    iPad 不验证观感，但**不能坏** —— 早先加场景 UI 时
#    iPad 分支缺了两个导出函数，target 悄悄编译失败。
# ------------------------------------------------------------
step "5/6" "平台编译 ..."
if ./tools/platforms.sh 2>&1 | sed 's/^/  /'; then
  :
else
  echo "  平台编译失败。上面标 FAIL 的就是问题。" >&2
  exit 3
fi

# ------------------------------------------------------------
# 6. 小结
# ------------------------------------------------------------
step "6/6" "完成"
echo "  交付物在 $OUT："
ls -1 "$OUT" 2>/dev/null | sed 's/^/    /'
echo ""
hr
