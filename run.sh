#!/bin/sh
# ============================================================
#  一键出全套交付物
#
#  用法：
#     ./run.sh                 # 用 data/rig.yaml 出全套
#     ./run.sh my_rig.yaml     # 指定其他数据文件
#     ./run.sh --check         # 只跑校验，不出图（改完数据先跑这个）
# ============================================================
set -e
cd "$(dirname "$0")"

if [ -x ".venv/bin/python" ]; then PY=".venv/bin/python"; else PY="python3"; fi

CHECK_ONLY=0
if [ "$1" = "--check" ]; then CHECK_ONLY=1; shift; fi
DATA="${1:-data/rig.yaml}"
# 传给下游：verify / hsc 需要知道复核的是哪份数据，
# 否则换项目跑会用 data/rig.yaml 当基准 —— 全绿但验错了对象。
export RIG="$DATA"
export DATA

[ -f "$DATA" ] || { echo "找不到数据文件：$DATA"; exit 1; }

echo "=============================================="
echo " 数据：$DATA"
echo "=============================================="

# ---- 1. 数据质检（不通过就停，绝不产出错图）
echo ""
echo "[1/9] 数据质检 ..."
$PY src/qc.py "$DATA"

# ---- 2. 灯具符号（缺就提取，有则跳过）
echo ""
echo "[2/9] 灯具符号 ..."
$PY src/gdtf_fetch.py
$PY src/gdtf_symbol.py --build

if [ "$CHECK_ONLY" = "1" ]; then
  echo ""
  echo " 只校验模式 —— 后续步骤跳过"
  $PY src/cues.py
  $PY src/rationale.py >/dev/null 2>&1 && echo " rationale OK" || true
  exit 0
fi

# ---- 3. 平面图（主图 + 两个场景）
echo ""
echo "[3/9] 平面图 ..."
$PY src/render.py "$DATA"
for SCENE in kitchen boston; do
  echo "       场景 $SCENE ..."
  $PY src/render.py "$DATA" --scene "$SCENE"
done

# ---- 4. 剖面图
echo ""
echo "[4/9] 剖面图 ..."
$PY src/section.py "$DATA"

# ---- 5. 表格
echo ""
echo "[5/9] 灯具表 / 色片表 ..."
$PY src/schedule.py "$DATA"

# ---- 6. Cue Sheet + Running Script（编号交叉校验）
echo ""
echo "[6/9] Cue Sheet + Running Script ..."
$PY src/cues.py
$PY src/cuepdf.py
$PY src/running.py

# ---- 7. 文字材料（rationale + 人话说明）
echo ""
echo "[7/9] 文字材料 ..."
$PY src/rationale.py
$PY src/plain.py

# ---- 8. CAD 交付：模型空间转真实尺寸 + 导出 DWG
echo ""
echo "[8/9] CAD 交付：模型空间转真实尺寸 + 导出 DWG"
$PY - <<'PYEOF'
import sys, glob, os, yaml
sys.path.insert(0, "src")
import dxfix

# ★ 必须跟 $1 走，不能写死 data/rig.yaml。
#   早先这里写死了 —— `./run.sh my_rig.yaml` 会用 my_rig.yaml 出图，
#   却按 rig.yaml 的比例去缩放 CAD，比例错了还全绿。
rig_path = os.environ.get("DATA") or "data/rig.yaml"
rig = yaml.safe_load(open(rig_path, encoding="utf-8"))
SCALE = int((rig.get("meta") or {}).get("scale", 25))

# ★ 关键：缩放到"真实尺寸"会破坏 verify/golden（它们按图纸 mm 判断）。
#   所以 out/*.dxf 保持图纸 mm（供复核与归档），
#   另存一份 out/cad/ 是真实尺寸（供 Vectorworks 导入）。
import shutil
os.makedirs("out/cad", exist_ok=True)

# 图纸尺寸：平面 A1 841x594，剖面 A3 420x297
SHEETS = {"LX_section": (420.0, 297.0)}
for f in sorted(glob.glob("out/LX_plan*.dxf")) + ["out/LX_section.dxf"]:
    if not os.path.exists(f):
        continue
    stem = os.path.splitext(os.path.basename(f))[0]
    sw, sh = SHEETS.get(stem, (841.0, 594.0))
    dst = os.path.join("out/cad", os.path.basename(f))
    shutil.copy(f, dst)
    dxfix.to_model_scale(dst, SCALE, sw, sh, verbose=False)
    dwg, err = dxfix.make_dwg(dst, verbose=False)
    print(f"   {os.path.basename(dst):26s} x{SCALE} -> "
          f"{'DWG OK' if dwg else err}")
PYEOF

echo ""
echo "[9/9] 复核 ..."
$PY src/verify.py
$PY tools/golden.py
$PY src/hsc.py

echo ""
echo "=============================================="
echo " 完成。交付物在 out/："
ls -1 out/ 2>/dev/null | sed 's/^/   /'
echo "=============================================="
