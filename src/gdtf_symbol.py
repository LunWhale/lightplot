#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gdtf_symbol.py — 从真实 GDTF 提取灯具二维符号

为什么需要这个模块
------------------
AGENTS.md 原计划是「下载 .gdtf，取里面的 SVG」。实测结果（98 家厂家抽样）：

    models/svg/        3 / 98   （其中还有占位符：只有圆圈+十字+文字）
    models/svg_side/   0 / 98
    models/gltf/*.glb  96 / 98  ← 几乎都有

所以只用 SVG 会让 97% 的灯具没有符号。本模块因此实现两级策略：

    A  models/svg/<Model.File>.svg
       厂家给的 1:1 矢量符号。会做「真符号」校验：
       元素必须有真正的 path/polygon/polyline，且不能只是同心圆+十字。

    B  models/gltf/*.glb  →  俯视投影  →  轮廓提取  →  RDP 简化
       三维网格沿 -Z 投影，栅格化求轮廓，简化到可用的顶点数。
       这条路径对 ETC Source Four 实测得到 78 顶点的精确外形。

    C  都失败 → 抛异常。绝不退回手画抽象形状。

坐标系
------
GDTF 右手系：X 右，Y 前（出光方向），Z 上。
  top  视图 = 沿 -Z 看，平面 (X, Y)
  side 视图 = 沿 -X 看，平面 (Y, Z)

输出单位统一为 **毫米**，原点在插入点（Model 的 SVGOffset / 包围盒中心）。
这样直接喂给 DXF，比例就是 1:1。

用法：
    python3 src/gdtf_symbol.py --build      # 提取全部 → data/symbols.json
    python3 src/gdtf_symbol.py --preview    # 出一张对比图 out/symbols_preview.png
"""
import argparse
import io
import json
import math
import os
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# 轮廓简化容差（米）。0.0008 m = 0.8 mm，在 1:25 图上约 0.03 mm，肉眼看不出。
RDP_EPS = 0.0008
# GLB 投影栅格分辨率（像素/毫米）
SIMPLIFY_MM = 0.3      # 轮廓简化容差（实物毫米），见 simplify_contour
PPM = 3.0
# 小于这个像素面积的轮廓当噪点丢掉
MIN_CONTOUR_PX = 40
# 栅格总像素上限，超了就自动降分辨率
MAX_GRID_PX = 24_000_000
# 灯具真实尺寸合理区间（米）。超出说明厂家单位不是米。
SANITY_MIN_M = 0.03
SANITY_MAX_M = 6.0


def normalize_units(span_m):
    """GDTF 规范说模型单位是米，但实测有厂家用毫米/厘米。

    返回 (scale, label)，scale 乘到原始坐标上即得米。
    """
    longest = max(span_m)
    if SANITY_MIN_M <= longest <= SANITY_MAX_M:
        return 1.0, "m"
    for scale, label in ((0.001, "mm"), (0.01, "cm")):
        if SANITY_MIN_M <= longest * scale <= SANITY_MAX_M:
            return scale, label
    # 兜底：按量级猜
    if longest > 1000:
        return 0.001, "mm?"
    if longest > 100:
        return 0.01, "cm?"
    return 1.0, "m?"


# ============================================================ 几何工具
def rdp(pts, eps):
    """Ramer–Douglas–Peucker 折线简化。"""
    if len(pts) < 3:
        return list(pts)
    import numpy as np
    a = np.asarray(pts[0], dtype=float)
    b = np.asarray(pts[-1], dtype=float)
    ab = b - a
    n = math.hypot(ab[0], ab[1])
    P = np.asarray(pts, dtype=float)
    if n < 1e-12:
        d = np.hypot(P[:, 0] - a[0], P[:, 1] - a[1])
    else:
        d = np.abs(ab[0] * (P[:, 1] - a[1]) - ab[1] * (P[:, 0] - a[0])) / n
    i = int(d.argmax())
    if d[i] > eps:
        return rdp(pts[: i + 1], eps)[:-1] + rdp(pts[i:], eps)
    return [pts[0], pts[-1]]


def polygon_area(pts):
    s = 0.0
    for i in range(len(pts)):
        x0, y0 = pts[i]
        x1, y1 = pts[(i + 1) % len(pts)]
        s += x0 * y1 - x1 * y0
    return abs(s) * 0.5


# ============================================================ 策略 B：GLB 投影
# ============================================================ 轮廓简化
# 为什么必须简化
# --------------
# GLB 投影出来的是**栅格描迹**（marching squares 沿像素走），
# 一个 profile 符号 6449 个顶点，其中 5744 段几乎是直线。
# 直接写进 DXF 的后果（实测）：
#   · 单图展开后 360,973 个顶点
#   · 文件 3.1 MB
#   · Vectorworks / AutoCAD 打开和缩放都明显卡
# 参考图（Vectorworks 原生画的）一个灯具符号只有几十个顶点。
#
# 容差取 0.3mm（**实物**单位）。符号在图上按 1:25 缩到约 11mm 长，
# 0.3mm 实物 = 0.012mm 图纸，远小于 0.144pt（0.05mm）线宽，
# 肉眼看不出差别，但顶点数降到 1.6%。

def simplify_contour(points, eps_mm=0.3):
    """Ramer–Douglas–Peucker 折线简化。points 单位是米，eps_mm 是毫米。"""
    n = len(points)
    if n < 3:
        return list(points)
    eps = eps_mm / 1000.0
    keep = [False] * n
    keep[0] = keep[-1] = True
    stack = [(0, n - 1)]
    while stack:
        i, j = stack.pop()
        if j <= i + 1:
            continue
        ax, ay = points[i]
        bx, by = points[j]
        dx, dy = bx - ax, by - ay
        seg = math.hypot(dx, dy)
        best = -1.0
        bi = -1
        for k in range(i + 1, j):
            px, py = points[k]
            if seg < 1e-12:
                d = math.hypot(px - ax, py - ay)
            else:
                d = abs(dy * (px - ax) - dx * (py - ay)) / seg
            if d > best:
                best = d
                bi = k
        if best > eps and bi > 0:
            keep[bi] = True
            stack.append((i, bi))
            stack.append((bi, j))
    return [p for p, k in zip(points, keep) if k]


def project_glb(glb_bytes, view):
    """把 GLB 网格沿指定轴投影，返回 [(x,y), ...] 轮廓列表（米）。

    view='top'  → 沿 -Z 投影到 XY
    view='side' → 沿 -X 投影到 YZ
    """
    import numpy as np
    import trimesh
    from PIL import Image, ImageDraw
    from skimage import measure

    mesh = trimesh.load(io.BytesIO(glb_bytes), file_type="glb", force="mesh")
    V = np.asarray(mesh.vertices, dtype=float)
    F = np.asarray(mesh.faces, dtype=int)
    if len(V) == 0 or len(F) == 0:
        raise RuntimeError("GLB 网格为空")

    if view == "top":
        xy = V[:, [0, 1]]
    elif view == "side":
        xy = V[:, [1, 2]]
    else:
        raise ValueError(f"未知视图 {view}")

    mn = xy.min(axis=0)
    mx = xy.max(axis=0)
    span = mx - mn
    if span[0] <= 0 or span[1] <= 0:
        raise RuntimeError("GLB 投影退化（跨度为 0）")

    # 单位归一化：把坐标换算到米
    scale, unit_label = normalize_units(span)
    if scale != 1.0:
        xy = xy * scale
        mn = xy.min(axis=0)
        mx = xy.max(axis=0)
        span = mx - mn

    # 分辨率自适应：先按 PPM，超上限就降
    ppm = PPM
    for _ in range(6):
        W = int(math.ceil(span[0] * 1000 * ppm)) + 12
        H = int(math.ceil(span[1] * 1000 * ppm)) + 12
        if W * H <= MAX_GRID_PX:
            break
        ppm *= 0.5
    else:
        raise RuntimeError(f"投影栅格仍过大 {W}x{H}")
    ppm = max(ppm, 0.35)          # 不低于 0.35 px/mm

    pad = 6
    W = int(math.ceil(span[0] * 1000 * ppm)) + 2 * pad
    H = int(math.ceil(span[1] * 1000 * ppm)) + 2 * pad

    img = Image.new("1", (W, H), 0)
    draw = ImageDraw.Draw(img)
    for tri in F:
        draw.polygon(
            [
                (
                    (xy[i][0] - mn[0]) * 1000 * ppm + pad,
                    H - ((xy[i][1] - mn[1]) * 1000 * ppm + pad),
                )
                for i in tri
            ],
            fill=1,
        )

    mask = np.asarray(img, dtype=float)
    contours = sorted(measure.find_contours(mask, 0.5), key=len, reverse=True)

    # 先算所有轮廓的面积，用于按相对大小过滤噪点
    cand = []
    for c in contours:
        if len(c) < 15:
            continue
        a = polygon_area([(p[1], p[0]) for p in c])
        if a < MIN_CONTOUR_PX:
            continue
        cand.append((a, c))
    if not cand:
        raise RuntimeError("投影未得到任何轮廓")

    # 只保留面积 >= 最大轮廓 3% 的，滤掉旋钮/支架投影的碎线
    biggest = max(a for a, _ in cand)
    cand = [(a, c) for a, c in cand if a >= biggest * 0.03]

    polys = [
        [
            ((col - pad) / ppm / 1000 + mn[0], (H - row - pad) / ppm / 1000 + mn[1])
            for row, col in c
        ]
        for _, c in cand
    ]
    # ---- 简化：栅格描迹 -> 折线
    before = sum(len(p) for p in polys)
    polys = [simplify_contour(p, SIMPLIFY_MM) for p in polys]
    polys = [p for p in polys if len(p) >= 3]      # 简化后退化成线的丢掉
    after = sum(len(p) for p in polys)
    if after < before:
        print(f"       简化轮廓 {before} -> {after} 顶点 "
              f"({100.0 * after / before:.1f}%)")
    if not polys:
        raise RuntimeError("简化后没有有效轮廓")

    return polys, (mn, mx), unit_label


# ============================================================ 策略 A：SVG
def _svg_is_real(elements):
    """判断 SVG 是不是真符号。

    实测 ALPHA LITE 的 "models/svg" 只是两个同心圆 + 十字 + 文字，
    这是占位符不是灯具轮廓。真符号必须有真正的路径或折线。
    """
    kinds = {}
    for e in elements:
        kinds[type(e).__name__] = kinds.get(type(e).__name__, 0) + 1
    real = kinds.get("Path", 0) + kinds.get("Polyline", 0) + kinds.get("Polygon", 0)
    rects = kinds.get("Rect", 0)
    # 有真实路径，或者至少 2 个矩形（机身/吊架），才算真符号
    return real >= 1 or rects >= 2


def parse_svg(data, model):
    """解析 SVG，返回轮廓列表（米）。坐标系已换算到 GDTF 插入点。"""
    import numpy as np
    import svgelements as se

    svg = se.SVG.parse(io.BytesIO(data))
    elems = list(svg.elements())
    if not _svg_is_real(elems):
        raise RuntimeError("SVG 是占位符（无真实路径）")

    # SVG 单位 → 米。svgelements 把长度换算成 px（96 dpi）
    px2m = 0.0254 / 96.0

    polys = []
    for e in elems:
        try:
            if isinstance(e, (se.Path, se.Polyline, se.Polygon, se.Rect, se.Circle,
                              se.Ellipse, se.Line)):
                subpaths = e.as_subpaths() if hasattr(e, "as_subpaths") else [e]
                for sp in subpaths:
                    pts = []
                    try:
                        n = max(8, int(sp.length() / (2 * px2m)) if sp.length() else 8)
                        n = min(n, 2000)
                        for i in range(n + 1):
                            p = sp.point(i / n)
                            if p is None:
                                continue
                            pts.append((float(p.x) * px2m, float(p.y) * px2m))
                    except Exception:
                        continue
                    pts = rdp(pts, RDP_EPS)
                    if len(pts) >= 3:
                        polys.append(pts)
        except Exception:
            continue

    if not polys:
        raise RuntimeError("SVG 解析后没有可用轮廓")
    return polys, None


# ============================================================ 主提取
def _bbox_of(polys):
    import numpy as np
    allp = np.concatenate([np.asarray(p, dtype=float) for p in polys])
    mn = allp.min(axis=0)
    mx = allp.max(axis=0)
    return (float(mx[0] - mn[0]), float(mx[1] - mn[1]))


def _size_agrees(a, b, tol=0.30):
    """两个尺寸是否一致（相对误差在 tol 内）。

    用于交叉校验厂家 SVG 和 GLB 模型。实测有厂家把 SVG 做成了
    示意图而非 1:1 实物图，不校验就会用错符号。
    """
    for x, y in zip(a, b):
        ref = max(x, y, 1e-9)
        if abs(x - y) / ref > tol:
            return False
    return True


def extract(gdtf_path, entry, view="top"):
    """从 .gdtf 提取一个视图的符号。

    多部件灯具（base + yoke + head）会**合并**成一个完整外形，
    而不是只取第一个部件——否则移动灯只能得到一个底座。

    优先级：
      1. 厂家 SVG，**但必须先与 GLB 包围盒交叉校验**。
         尺寸不符说明该 SVG 不是 1:1 实物图（实测确实存在），弃用。
      2. GLB 俯视投影。

    返回 dict:
        polygons: [[[x,y],...], ...]   单位 mm，原点=包围盒中心
        bbox:     [x0,y0,x1,y1]        单位 mm
        source:   "svg" | "glb(...)"
        detail:   诊断信息
    """
    with zipfile.ZipFile(gdtf_path) as z:
        names = z.namelist()
        svg_dir = "models/svg" if view == "top" else "models/svg_side"

        model_files = entry.get("model_files") or []
        if not model_files and "description.xml" in names:
            import re
            xml = z.read("description.xml").decode("utf-8", "ignore")
            model_files = re.findall(r'<Model\s+[^>]*File="([^"]+)"', xml)

        notes = []

        # ---------- 先算 GLB 参考尺寸（用于校验 SVG）
        glbs = [n for n in names if n.startswith("models/gltf/") and n.endswith(".glb")]
        glbs = [n for n in glbs if "filament" not in n.lower()]
        glbs.sort(key=lambda n: ("yoke" in n.lower(), n))
        glb_polys, glb_used, glb_units, glb_errors = [], [], set(), []
        for g in glbs:
            try:
                polys, bounds, unit_label = project_glb(z.read(g), view)
                glb_polys.extend(polys)
                glb_used.append(g.split("/")[-1])
                glb_units.add(unit_label)
            except Exception as e:
                glb_errors.append(f"{g}: {e}")
        glb_size = _bbox_of(glb_polys) if glb_polys else None

        # ---------- 策略 A：厂家 SVG（必须通过尺寸校验）
        svg_polys, svg_used = [], []
        for mf in model_files:
            if not mf:
                continue
            cand = f"{svg_dir}/{mf}.svg"
            if cand not in names:
                continue
            try:
                polys, _ = parse_svg(z.read(cand), mf)
                svg_polys.extend(polys)
                svg_used.append(cand)
            except Exception as e:
                notes.append(f"{cand}: {e}")

        if svg_polys:
            svg_size = _bbox_of(svg_polys)
            if glb_size and not _size_agrees(svg_size, glb_size):
                notes.append(
                    f"SVG 尺寸 {svg_size[0]*1000:.0f}×{svg_size[1]*1000:.0f}mm "
                    f"与 GLB {glb_size[0]*1000:.0f}×{glb_size[1]*1000:.0f}mm 不符，弃用"
                )
            else:
                return _finish(svg_polys, "svg", " + ".join(svg_used))

        # ---------- 策略 B：GLB 投影
        if glb_polys:
            tag = "glb(" + ",".join(sorted(glb_units)) + ")"
            res = _finish(glb_polys, tag, " + ".join(glb_used))
            if notes:
                res["notes"] = notes
            return res

        detail = "; ".join(notes + glb_errors) or "GDTF 内既无可用 SVG 也无可用 GLB"
        raise RuntimeError(f"[{view}] 无法提取符号 — {detail}")


def _finish(polys, source, detail):
    """统一到毫米、原点移到包围盒中心。"""
    import numpy as np

    polys_mm = [[(x * 1000.0, y * 1000.0) for x, y in p] for p in polys]
    allp = np.concatenate([np.asarray(p) for p in polys_mm])
    mn = allp.min(axis=0)
    mx = allp.max(axis=0)
    cx = (mn[0] + mx[0]) / 2.0
    cy = (mn[1] + mx[1]) / 2.0
    polys_mm = [[(x - cx, y - cy) for x, y in p] for p in polys_mm]
    bbox = [float(mn[0] - cx), float(mn[1] - cy), float(mx[0] - cx), float(mx[1] - cy)]
    return {
        "polygons": [[[round(x, 2), round(y, 2)] for x, y in p] for p in polys_mm],
        "bbox": [round(v, 2) for v in bbox],
        "source": source,
        "detail": detail,
    }


# ============================================================ 构建缓存
def build(manifest_path=None, out_path=None):
    import yaml

    manifest_path = manifest_path or os.path.join(ROOT, "data", "fixtures.yaml")
    out_path = out_path or os.path.join(ROOT, "data", "symbols.json")
    man = yaml.safe_load(open(manifest_path, encoding="utf-8"))

    result = {}
    print("=" * 70)
    print(" 从 GDTF 提取灯具符号")
    print("=" * 70)

    for key, entry in man["fixtures"].items():
        if "gdtf" not in entry:
            result[key] = {"usitt": entry.get("usitt", "practical")}
            print(f"  [USITT] {key:10s} 规范符号（非厂家产品）")
            continue

        path = os.path.join(
            ROOT, "data", "gdtf", f"{key}__{entry['slug']}.gdtf"
        )
        if not os.path.exists(path):
            raise SystemExit(f"缺少 GDTF：{path}\n请先运行 python3 src/gdtf_fetch.py")

        sym = {"name": entry["name"], "manufacturer": entry.get("manufacturer", "")}
        for view in ("top", "side"):
            try:
                sym[view] = extract(path, entry, view)
                v = sym[view]
                w = v["bbox"][2] - v["bbox"][0]
                h = v["bbox"][3] - v["bbox"][1]
                print(
                    f"  [ OK ] {key:10s} {view:5s} {v['source']:4s} "
                    f"{w:6.1f}×{h:6.1f} mm  {len(v['polygons'])} 轮廓"
                )
            except Exception as e:
                print(f"  [WARN] {key:10s} {view:5s} {e}")
                sym[view] = None
        result[key] = sym

    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=1)
    print("-" * 70)
    print(f" 写入 {out_path}")
    return result


# ============================================================ 预览
def preview(symbols_path=None, out_png=None):
    """把提取到的符号画成对比图，人眼确认形状对不对。"""
    from PIL import Image, ImageDraw

    symbols_path = symbols_path or os.path.join(ROOT, "data", "symbols.json")
    out_png = out_png or os.path.join(ROOT, "out", "symbols_preview.png")
    syms = json.load(open(symbols_path, encoding="utf-8"))

    cell_w, cell_h = 300, 220
    items = []
    for key, s in syms.items():
        if "top" not in s:
            continue
        for view in ("top", "side"):
            if s.get(view):
                items.append((f"{key} / {view} [{s[view]['source']}]", s[view]))

    cols = 4
    rows = (len(items) + cols - 1) // cols
    W, H = cols * cell_w, rows * cell_h + 30
    img = Image.new("RGB", (W, H), "white")
    d = ImageDraw.Draw(img)
    d.text((10, 8), "GDTF symbol extraction preview  (mm, true scale)", fill="black")

    for idx, (label, s) in enumerate(items):
        cx = (idx % cols) * cell_w
        cy = (idx // cols) * cell_h + 30
        d.rectangle([cx, cy, cx + cell_w - 1, cy + cell_h - 1], outline="#cccccc")
        d.text((cx + 6, cy + 4), label[:42], fill="#444444")
        bb = s["bbox"]
        w = bb[2] - bb[0]
        h = bb[3] - bb[1]
        pad = 26
        sc = min((cell_w - 2 * pad) / max(w, 1), (cell_h - 2 * pad - 14) / max(h, 1))
        ox = cx + cell_w / 2
        oy = cy + 14 + (cell_h - 14) / 2
        for poly in s["polygons"]:
            pts = [(ox + x * sc, oy - y * sc) for x, y in poly]
            if len(pts) >= 2:
                d.line(pts + [pts[0]], fill="black", width=2)
        d.text((cx + 6, cy + cell_h - 14), f"{w:.0f} x {h:.0f} mm", fill="#888888")

    os.makedirs(os.path.dirname(out_png), exist_ok=True)
    img.save(out_png)
    print(" 预览图:", out_png)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", action="store_true")
    ap.add_argument("--preview", action="store_true")
    a = ap.parse_args()
    if a.build:
        build()
    if a.preview:
        preview()
    if not (a.build or a.preview):
        ap.print_help()
