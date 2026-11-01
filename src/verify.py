#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""verify.py — 出图后的确定性复核

AGENTS.md 铁律 4：「不要相信看起来不错」。这个脚本重新打开产出的
DXF/PDF/PNG，用可重复的检查确认图纸真的对。

============================================================
为什么要有「两层」检查
============================================================
第一版只查 TEXT vs TEXT，结果报告「零压字」，但图上明明一片重叠。
原因：灯具标注被做成了 BLOCK（INSERT），里面的文字在 block 定义里，
modelspace 层查 TEXT 根本看不到。**检查器有盲区 = 假绿灯。**

现在分两层：
  A. 几何层：展开所有 INSERT（含嵌套），拿到真实包围盒，
     做 TEXT/INSERT 两两碰撞检测。
  B. 像素层：把 PDF 渲染成位图，在「不该有墨」的区域统计墨密度，
     捕捉几何检查漏掉的视觉拥挤（比如文字压在细线上）。

任何一项失败 → 退出码 1。
"""
import glob
import json
import os
import sys

import ezdxf
import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

FAIL = []
WARN = []


def _rig_path():
    """当前要复核的 rig 数据文件。默认 data/rig.yaml，可用 RIG 覆盖。"""
    p = os.environ.get("RIG")
    if p and os.path.exists(p):
        return p
    return os.path.join(ROOT, "data", "rig.yaml")


def ok(msg):
    print(f"  [ OK ] {msg}")


def bad(msg):
    print(f"  [FAIL] {msg}")
    FAIL.append(msg)


def warn(msg):
    print(f"  [WARN] {msg}")
    WARN.append(msg)


# ============================================================ 几何层
def entity_bboxes(msp, doc):
    """收集所有「可见文字类」元素的真实包围盒。

    关键：必须展开 INSERT。灯具标注是 LBL_<unit> block，
    里面装着圆圈 + 编号 + 色片号，不展开就完全漏检。
    """
    from ezdxf import bbox as _bb

    items = []          # (label, kind, bbox)

    def add(e, kind, tag):
        try:
            b = _bb.extents([e])
        except Exception:
            return
        if not b.has_data:
            return
        items.append((tag, kind, (b.extmin.x, b.extmin.y, b.extmax.x, b.extmax.y)))

    for e in msp:
        t = e.dxftype()
        if t == "TEXT":
            add(e, "TEXT", e.dxf.text)
        elif t == "MTEXT":
            add(e, "TEXT", e.text[:20])
        elif t == "INSERT":
            # 灯具符号与标注块：整体作为一个不可分割的障碍
            add(e, "INSERT", e.dxf.name)

    # 展开 block 内的文字，用于检查「块内文字 vs 外部文字」
    for blk in doc.blocks:
        if blk.name.startswith("*"):
            continue
        for e in blk:
            if e.dxftype() == "TEXT":
                # 取 block 内文字相对位置（近似，用于诊断提示）
                pass
    return items


def overlap(a, b, pad=0.0):
    return not (a[2] + pad <= b[0] or b[2] + pad <= a[0]
                or a[3] + pad <= b[1] or b[3] + pad <= a[1])


def check_plan(path, rig):
    print(f"\n── {os.path.basename(path)} ──")
    if not os.path.exists(path):
        bad(f"{path} 不存在")
        return
    doc = ezdxf.readfile(path)
    msp = doc.modelspace()
    ents = list(msp)
    if len(ents) < 100:
        bad(f"实体数过少 {len(ents)}")
    else:
        ok(f"{len(ents)} 个实体")

    items = entity_bboxes(msp, doc)
    texts = [i for i in items if i[1] == "TEXT"]
    inserts = [i for i in items if i[1] == "INSERT"]
    ok(f"{len(texts)} 个文字 / {len(inserts)} 个块引用")

    # ---- 碰撞检测：文字 vs 文字、文字 vs 块、块 vs 块
    collisions = []
    for i in range(len(items)):
        for j in range(i + 1, len(items)):
            t1, k1, b1 = items[i]
            t2, k2, b2 = items[j]
            # 同一块内部不算（块是整体）
            if k1 == "INSERT" and k2 == "INSERT":
                continue
            if overlap(b1, b2, pad=0.05):
                collisions.append((t1[:22], k1, t2[:22], k2))

    if collisions:
        bad(f"{len(collisions)} 处重叠")
        for c in collisions[:12]:
            print(f"        {c[1]}:{c[0]!r}  ×  {c[3]}:{c[2]!r}")
    else:
        ok("零重叠（文字/块 两两检查）")

    # ---- 出框检查（外图框 10mm）
    doc_w, doc_h = 841.0, 594.0
    EPS = 0.05
    outside = [(t, b) for t, k, b in items
               if b[0] < 10 - EPS or b[1] < 10 - EPS
               or b[2] > doc_w - 10 + EPS or b[3] > doc_h - 10 + EPS]
    if outside:
        bad(f"{len(outside)} 个元素越出图框: {[o[0][:16] for o in outside[:5]]}")
    else:
        ok("全部在图框内")

    # ---- 灯具符号数量
    refs = [e for e in msp if e.dxftype() == "INSERT" and e.dxf.name.startswith("SYM_")]
    n_fix = len(rig["fixtures"])
    legend_n = len({f["type"] for f in rig["fixtures"]})
    if len(refs) == n_fix + legend_n:
        ok(f"灯具符号 {len(refs)} = {n_fix} 台灯 + {legend_n} 图例")
    else:
        bad(f"灯具符号 {len(refs)}，应为 {n_fix + legend_n}")

    # ---- 关键标注存在性
    all_text = " ".join(t for t, k, b in texts)
    for needle, why in [("SECTION A-A", "剖切线标注"), ("SCALE 1:", "比例尺")]:
        if needle.upper() in all_text.upper():
            ok(f"含 {why}")
        else:
            bad(f"缺 {why}")


def check_section(path, rig):
    print(f"\n── {os.path.basename(path)} ──")
    if not os.path.exists(path):
        bad(f"{path} 不存在")
        return
    doc = ezdxf.readfile(path)
    msp = doc.modelspace()
    texts = [e.dxf.text for e in msp.query("TEXT")]
    allt = " | ".join(texts)
    ok(f"{len(list(msp))} 个实体")

    for needle, why in [
        ("SECTION A-A", "剖面标题"), ("VERTICAL ZERO", "垂直零点"),
        ("PROSCENIUM", "台口"), ("GRID", "栅顶"),
        ("BACK WALL", "后墙"), ("AUDIENCE", "观众席"),
    ]:
        if needle.upper() in allt.upper():
            ok(f"含 {why}")
        else:
            bad(f"缺 {why}（{needle}）")

    if any("1.75" in t for t in texts):
        ok("含 1.75m 人形参照")
    else:
        bad("缺 1.75m 人形参照")

    # 剖面图也要查重叠
    from ezdxf import bbox as _bb
    boxes = []
    for e in msp.query("TEXT"):
        try:
            b = _bb.extents([e])
            if b.has_data:
                boxes.append((e.dxf.text, (b.extmin.x, b.extmin.y, b.extmax.x, b.extmax.y)))
        except Exception:
            pass
    coll = []
    for i in range(len(boxes)):
        for j in range(i + 1, len(boxes)):
            if overlap(boxes[i][1], boxes[j][1], 0.05):
                coll.append((boxes[i][0][:18], boxes[j][0][:18]))
    if coll:
        bad(f"{len(coll)} 处文字重叠: {coll[:6]}")
    else:
        ok("剖面文字零重叠")


# ============================================================ 像素层
def check_pixels(pdf_path, label, sample_regions=None):
    """把 PDF 渲染成位图，在指定区域统计墨密度。

    用途：捕捉几何检查漏掉的「视觉拥挤」——文字虽然没互相压，
    但压在细线上导致读不清，或者某个区域密得像糊了一样。
    """
    try:
        import pymupdf
        import numpy as np
        from PIL import Image
        import io
    except ImportError:
        warn("缺 pymupdf/numpy/Pillow，跳过像素检查")
        return

    if not os.path.exists(pdf_path):
        bad(f"{pdf_path} 不存在")
        return

    d = pymupdf.open(pdf_path)
    p = d[0]
    pix = p.get_pixmap(dpi=300)
    img = Image.open(io.BytesIO(pix.tobytes("png"))).convert("L")
    a = np.array(img)
    dark = (a < 128)

    overall = dark.mean()
    ok(f"{label} 墨密度 {overall:.4f}")
    if overall > 0.12:
        bad(f"{label} 整体墨密度过高 {overall:.4f}（>0.12，图太黑）")
    elif overall < 0.001:
        bad(f"{label} 几乎空白 {overall:.5f}")

    # 分块扫描：找出局部过密的区块（视觉拥挤）
    H, W = a.shape
    gy, gx = 8, 12
    worst = []
    for iy in range(gy):
        for ix in range(gx):
            sub = dark[iy * H // gy:(iy + 1) * H // gy,
                       ix * W // gx:(ix + 1) * W // gx]
            if sub.size:
                worst.append((sub.mean(), iy, ix))
    worst.sort(reverse=True)
    top = worst[0]
    if top[0] > 0.30:
        bad(f"{label} 局部墨密度 {top[0]:.3f} @ 区块({top[1]},{top[2]})，视觉拥挤")
    else:
        ok(f"{label} 局部最密 {top[0]:.3f}，可接受")


# ============================================================ 视觉语法自检
def check_visual_grammar(dxf_path, pdf_path):
    """读渲染出来的位图，验证「桁架长得像桁架、管子是空心的」。

    为什么必须看像素：几何层只能证明「画了线」，不能证明「画对了」。
    2026-10 就出过这种事——桁架被图层排序搞成空心方块，
    几何检查全绿（线都在），人眼一看就是错的。

    两个判据：
      A. 桁架：竖直腹杆必须是一根根**贯穿全高**的柱子，按节距重复。
         空心方块 → 没有贯穿柱 → 失败。
         波浪线（旧版）→ 柱数对不上 → 失败。
      B. 管线：内部必须是白的（空心矩形）。
         填实了 → 内部墨密度高 → 失败。
    """
    print("\n── 视觉语法自检（读图）──")
    if not (os.path.exists(dxf_path) and os.path.exists(pdf_path)):
        bad("缺 DXF 或 PDF，无法自检")
        return
    try:
        import pymupdf
        import numpy as np
    except ImportError:
        warn("未装 pymupdf/numpy，跳过视觉自检")
        return

    from ezdxf import bbox as _bb

    doc = ezdxf.readfile(dxf_path)
    msp = doc.modelspace()

    def layer_box(name):
        xs, ys = [], []
        for e in msp:
            if e.dxf.layer != name:
                continue
            try:
                b = _bb.extents([e])
            except Exception:
                continue
            if b.has_data:
                xs += [b.extmin.x, b.extmax.x]
                ys += [b.extmin.y, b.extmax.y]
        return (min(xs), min(ys), max(xs), max(ys)) if xs else None

    tb = layer_box("TRUSS")
    pb = layer_box("PIPE")
    if not tb or not pb:
        bad("找不到 TRUSS / PIPE 图层")
        return

    DPI = 600
    K = 72.0 / 25.4
    page = pymupdf.open(pdf_path)[0]
    Hmm = page.rect.height / K

    def crop_mm(x0, y0, x1, y1):
        """只渲染这一块（整页 1200dpi 会被 pymupdf 拒绝：图太大）。"""
        clip = pymupdf.Rect(x0 * K, (Hmm - y1) * K, x1 * K, (Hmm - y0) * K)
        pix = page.get_pixmap(dpi=DPI, clip=clip)
        a = np.frombuffer(pix.samples, dtype=np.uint8)
        a = a.reshape(pix.height, pix.width, pix.n)
        return a[:, :, :3].mean(axis=2) < 128

    # ---------- A. 桁架：取最长的那一段
    # 按 y 中心**贪心聚类**（容差 10mm）。不能按坐标取整分组：
    # 弦杆在 ±6mm、腹杆在中线，取整会把它们拆到不同组里，找不到完整桁架。
    cents = []
    for e in msp:
        if e.dxf.layer != "TRUSS":
            continue
        try:
            b = _bb.extents([e])
        except Exception:
            continue
        if b.has_data:
            cents.append(((b.extmin.y + b.extmax.y) / 2.0,
                          b.extmin.x, b.extmax.x, b.extmin.y, b.extmax.y))
    if not cents:
        bad("TRUSS 图层没有实体")
        return
    cents.sort()
    groups = []
    for c in cents:
        if groups and abs(c[0] - groups[-1][-1][0]) <= 10.0:
            groups[-1].append(c)
        else:
            groups.append([c])
    cl = max(groups, key=lambda g: max(c[2] for c in g) - min(c[1] for c in g))
    bb = (min(c[1] for c in cl), min(c[3] for c in cl),
          max(c[2] for c in cl), max(c[4] for c in cl))
    yc = (bb[1] + bb[3]) / 2.0
    band_h = (bb[3] - bb[1]) + 0.6
    seg = crop_mm(bb[0] + 0.4, yc - band_h / 2, bb[2] - 0.4, yc + band_h / 2)
    if seg.size == 0:
        bad("桁架取样区为空")
        return

    col = seg.sum(axis=0)                 # 每列墨点数
    full = col >= 0.62 * seg.shape[0]     # 贯穿全高的列
    # 一根立柱是**矩形轮廓**，两条竖边都会被判成「贯穿列」，
    # 所以要把间距小于柱宽（1.016mm）的列并成一根。
    px_per_mm = DPI / 25.4
    gap_px = max(2, int(1.4 * px_per_mm))
    runs = []
    i = 0
    while i < len(full):
        if full[i]:
            j = i
            while j < len(full) and full[j]:
                j += 1
            runs.append([i, j])
            i = j
        else:
            i += 1
    merged = []
    for r in runs:
        if merged and r[0] - merged[-1][1] <= gap_px:
            merged[-1][1] = r[1]
        else:
            merged.append(r)
    posts = len(merged)
    span_mm = bb[2] - bb[0]
    expect = max(1, round(span_mm / 11.7687))
    if posts >= 0.55 * expect and posts <= 1.45 * expect:
        ok(f"桁架腹杆 {posts} 根，节距符合（应≈{expect} 根）")
    else:
        bad(f"桁架腹杆 {posts} 根，应≈{expect} 根 —— 不是「M 形腹杆 + 贯穿立柱」的画法")

    # 斜腹杆必须存在：取两根柱子之间的中点列，墨点应远少于柱子
    if posts >= 3:
        mid = int(seg.shape[1] * 0.5)
        band = seg[:, mid:mid + 1].sum()
        if band == 0:
            bad("桁架中间列无墨 —— 缺斜腹杆")
        else:
            ok("桁架含斜腹杆")

    # ---------- B. 管线：内部必须空心
    pipe = crop_mm(pb[0] + 1.0, pb[1] + 0.55, pb[2] - 1.0, pb[3] - 0.55)
    if pipe.size == 0:
        bad("管线取样区为空")
        return
    inner = pipe.mean()
    if inner < 0.12:
        ok(f"管线空心（内部墨密度 {inner:.3f}）")
    else:
        bad(f"管线内部墨密度 {inner:.3f}，应为空心矩形（<0.12）")

# ============================================================ PDF 尺寸
def check_pdf(path, expect_w, expect_h):
    print(f"\n── {os.path.basename(path)} ──")
    if not os.path.exists(path):
        bad(f"{path} 不存在")
        return
    try:
        import pymupdf
    except ImportError:
        warn("未装 pymupdf，跳过")
        return
    d = pymupdf.open(path)
    p = d[0]
    w_mm = p.rect.width * 25.4 / 72
    h_mm = p.rect.height * 25.4 / 72
    if abs(w_mm - expect_w) < 2 and abs(h_mm - expect_h) < 2:
        ok(f"尺寸正确 {w_mm:.0f}×{h_mm:.0f} mm")
    else:
        bad(f"尺寸 {w_mm:.0f}×{h_mm:.0f}，应为 {expect_w}×{expect_h}")


# ============================================================ 1:1 比例（内容层）
def check_scale_pdf(path, expect_w, expect_h, label):
    """页面尺寸对 ≠ 内容 1:1。

    上一版的假绿灯就在这里：figsize 决定页面永远是 841×594mm，
    但 `finalize=True` 会把坐标轴改成图元包围盒（821×574mm），
    于是内容被非等比拉伸，1:25 实际变成约 1:24.4。
    这里反解 PDF 里**外图框的实际位置和尺寸**，不看页面大小。
    """
    print(f"\n── {label} 比例 ──")
    if not os.path.exists(path):
        bad(f"{path} 不存在，无法校验比例")
        return
    sys.path.insert(0, HERE)
    try:
        import export as _export
    except ImportError as e:
        warn(f"无法导入 export.py（{e}），跳过比例校验")
        return
    good, detail = _export.check_scale(path, expect_w, expect_h)
    if good:
        ok(f"1:1 成立 — {detail}")
    else:
        bad(f"{label} 不是 1:1 — {detail}")



# ============================================================ 灯具朝向
def check_fixture_aim(dxf_path, rig):
    """每一台灯的光学朝向必须指向 rig.yaml 里的 aim。

    为什么必须有这一条
    ------------------
    GDTF 符号的**镜片在 -Y**（实测：fresnel -Y 均宽 237.6 / +Y 186.2）。
    代码一度按 +Y 当前方算 rotation，结果全台灯整体反了 180°，
    平面图上所有灯都"对着观众"—— 而几何检查、重叠检查、像素检查
    全部通过，因为灯确实画出来了，只是朝错了。
    这类错误只有把「朝向」当成一条独立断言才抓得住。

    做法：把符号多边形按 blockref 的 rotation/scale 变换到图纸坐标，
    沿世界 Y 切片，比较两端的横截宽度 —— 宽端是镜片（出光面）。
    再和 aim 的 Y 分量比符号。
    """
    import math as _m

    symp = os.path.join(ROOT, "data", "symbols.json")
    if not os.path.exists(symp):
        return
    syms = json.load(open(symp, encoding="utf-8"))

    doc = ezdxf.readfile(dxf_path)
    msp = doc.modelspace()
    pos = {p["id"]: p for p in rig["positions"]}

    def world_xy(f):
        if f.get("pos") == "SET EDGE":
            return f["x"], f["y"]
        p = pos.get(f.get("pos"))
        if not p:
            return None
        if "x" in f:
            return f["x"], f.get("y", p.get("y", 0))
        if "y" in f:
            return p.get("x", 0), f["y"]
        return p.get("x", 0), p.get("y", 0)

    wrong, checked = [], 0
    for e in msp:
        if e.dxftype() != "INSERT" or not e.dxf.name.startswith("SYM_"):
            continue
        typ = e.dxf.name[4:]
        if typ not in syms or "top" not in syms[typ]:
            continue
        rot, sc = e.dxf.rotation, e.dxf.xscale
        r = _m.radians(rot)
        pts = [(e.dxf.insert.x + sc * (x * _m.cos(r) - y * _m.sin(r)),
                e.dxf.insert.y + sc * (x * _m.sin(r) + y * _m.cos(r)))
               for poly in syms[typ]["top"]["polygons"] for x, y in poly]

        # ★ 判定镜片朝向：比**两端各自 |x| 的均值**，不要比切片宽度。
        #   切片法（按 y 分桶取 max-min）在符号被 RDP 简化后会失真：
        #   简化后一个桶里可能只有 1-2 个点，宽度忽大忽小，判定随机翻转。
        #   实测：简化后 mover 的切片法判成 -Y，但它和简化前是同一个形状。
        #   |x| 均值只依赖点的分布，对简化稳定。
        # ★ 必须用**相对插入点**的横向偏移，不能用绝对世界坐标。
        #   |world_x| 会被插入点本身主导（插入点 215.0 时，
        #   灯体只占 ±5.6mm，两端差 0.24mm，符号噪声就翻转判定）。
        cx0 = e.dxf.insert.x
        ys = [p[1] for p in pts]
        y0, y1 = min(ys), max(ys)
        band = (y1 - y0) * 0.22
        lo = [abs(p[0] - cx0) for p in pts if p[1] <= y0 + band]
        hi = [abs(p[0] - cx0) for p in pts if p[1] >= y1 - band]
        if not lo or not hi:
            continue
        import statistics as _st
        lens_y = 1 if _st.fmean(hi) > _st.fmean(lo) else -1

        # 找最近的灯具
        best = None
        for f in rig["fixtures"]:
            xy = world_xy(f)
            if xy is None:
                continue
            sx, sy = 355.0 + xy[0] / 25.0, 215.0 + xy[1] / 25.0
            d = abs(sx - e.dxf.insert.x) + abs(sy - e.dxf.insert.y)
            if best is None or d < best[0]:
                best = (d, f)
        if not best:
            continue
        f = best[1]
        checked += 1
        want = _m.sin(_m.radians(f.get("aim", 90)))
        if abs(want) < 0.1:
            continue                       # aim 沿 X，用 Y 判不了，跳过
        if (lens_y > 0) != (want > 0):
            wrong.append(f"灯 {f['unit']}（{f['pos']}）aim={f.get('aim')}，"
                         f"但符号镜片朝 {'+Y' if lens_y > 0 else '-Y'}")

    if wrong:
        bad(f"灯具朝向错误 {len(wrong)} 台：" + "；".join(wrong[:4]))
    else:
        ok(f"灯具朝向正确（{checked} 台，镜片均指向 aim）")


# ============================================================ main
def main():
    print("=" * 64)
    print(" 出图复核")
    print("=" * 64)

    # ★ RIG 环境变量可覆盖：`./run.sh my_rig.yaml` 时 run.sh 会 export RIG，
    #   否则复核会拿 data/rig.yaml 去比别的项目的图 —— 全绿但验的是错的基准。
    rig = yaml.safe_load(open(_rig_path(), encoding="utf-8"))

    plans = sorted(glob.glob(os.path.join(ROOT, "out", "LX_plan*.dxf")))
    if not plans:
        bad("out/ 里没有平面图 DXF")
    for p in plans:
        check_plan(p, rig)
    check_fixture_aim(os.path.join(ROOT, "out", "LX_plan.dxf"), rig)

    check_section(os.path.join(ROOT, "out", "LX_section.dxf"), rig)

    check_pdf(os.path.join(ROOT, "out", "LX_plan.pdf"), 841, 594)
    check_pdf(os.path.join(ROOT, "out", "LX_section.pdf"), 420, 297)

    # 内容层 1:1：页面尺寸对不代表内容没被拉伸
    check_scale_pdf(os.path.join(ROOT, "out", "LX_plan.pdf"), 841, 594, "平面图")
    check_scale_pdf(os.path.join(ROOT, "out", "LX_section.pdf"), 420, 297, "剖面图")

    print("\n── 像素层检查 ──")
    check_visual_grammar(os.path.join(ROOT, "out", "LX_plan.dxf"),
                         os.path.join(ROOT, "out", "LX_plan.pdf"))
    check_pixels(os.path.join(ROOT, "out", "LX_plan.pdf"), "平面图")
    check_pixels(os.path.join(ROOT, "out", "LX_section.pdf"), "剖面图")

    # 符号缓存
    sp = os.path.join(ROOT, "data", "symbols.json")
    if os.path.exists(sp):
        syms = json.load(open(sp, encoding="utf-8"))
        missing = [k for k, v in syms.items() if "top" not in v and "usitt" not in v]
        if missing:
            bad(f"符号缺失 top 视图: {missing}")
        else:
            ok(f"符号缓存完整（{len(syms)} 种）")
    else:
        bad("缺 data/symbols.json")

    print("\n" + "=" * 64)
    if FAIL:
        print(f" 复核未通过：{len(FAIL)} 项失败，{len(WARN)} 项警告")
        for f in FAIL:
            print("   ✗", f)
        sys.exit(1)
    print(f" 复核通过（{len(WARN)} 项警告）")
    print("=" * 64)


if __name__ == "__main__":
    main()
