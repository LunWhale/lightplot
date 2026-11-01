#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""golden.py — 黄金图回归：把当前出图和参考图逐块比对

为什么需要它
------------
现有的 verify.py 检查的是「符合我写的规则」：不重叠、不出框、桁架腹杆根数对。
这些都对，但都是**我定义的规则**。它们抓不到「规则全过，但看起来就是不像」。

参考图（brief/reference/*.pdf，Vectorworks 画的 NIDA 图纸）是唯一的
外部标准。这个工具把参考图的**局部特征**和当前出图的对应区域做像素比对，
给一个相似度分数。分数掉了就说明视觉语法漂移了。

怎么比
------
不是整张图比（版式不同，整图 SSIM 没意义）。比的是**构件级切片**：

  truss   桁架单元：一个节距的腹杆 + 上下弦
  pipe    空心管线截面
  fixture 灯具符号 + 标注块

每块的做法：
  1. 从参考图按给定 mm 坐标裁出来（坐标在 REF_CROPS 里手标一次）
  2. 从当前出图里找到对应构件（按 DXF 里的位置），裁同样大小
  3. 二值化 + 归一化尺寸 → SSIM
  4. 低于阈值就 FAIL

阈值怎么定
----------
参考图和我们的实现**不可能**完全一样（字体渲染、抗锯齿、坐标取整）。
实测同一构件两次渲染的 SSIM 在 0.97 以上；不同实现之间在 0.55-0.85。
所以阈值定 0.60 —— 低于它说明形状本身错了，不是渲染差异。

用法
----
    python3 tools/golden.py            # 比对并打印分数
    python3 tools/golden.py --bless    # 重新标定基准（改了参考裁块后）
"""
import argparse
import json
import os
import sys

import numpy as np
import pymupdf

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REF = os.path.join(ROOT, "brief/reference/XMACH_LXTrussPlan_JC_180620_Version5.pdf")
CUR = os.path.join(ROOT, "out/LX_plan.pdf")
BASE = os.path.join(ROOT, "data/golden.json")

K = 72.0 / 25.4
DPI = 600
THRESHOLD = 0.60

# ------------------------------------------------------------ 裁块坐标
# 坐标单位 mm。参考图原点在**页面左上**（PDF 坐标）；
# 当前出图原点在**页面左下**（DXF 坐标）—— flip_y 处理这个差别。
#
# ★ 这些坐标是用「墨迹密度探测」实测出来的，不是猜的：
#   参考图桁架第 1 行 y≈59-71，x 从 54.2 开始，一个节距 11.77mm；
#   当前出图 LX2 桁架 y≈429，x 从 55 开始，同一节距。
#   探针脚本见 docs/09-selfcheck.md。
#
# ★ 最重要的一条：两边裁块都**必须含墨**。
#   早先版本坐标标错，裁到空白区域，两块全白 → SSIM=1.0 → 假通过。
#   现在 MIN_INK 会挡住这种情况：任一裁块墨密度低于 1% 直接 FAIL。
REF_CROPS = {
    # 一个完整桁架节距：上下弦 + 一根竖腹杆 + 斜腹杆（M 形）
    "truss_cell":    (54.19, 58.3, 66.5, 71.5),
    # 桁架中段的连续若干节距（看节距是否均匀）
    "truss_run":     (150.0, 58.0, 174.0, 72.0),
    # 灯具符号 + 圆圈通道号 + 色片号（参考图右侧 LX 行）
    "fixture_block": (700.6, 515.0, 745.0, 545.0),
}

# 当前出图里对应的裁块（DXF 图纸坐标 mm，原点左下）
CUR_CROPS = {
    "truss_cell":    (120.0, 421.5, 133.0, 435.5),
    "truss_run":     (300.0, 421.5, 324.0, 435.5),
    "fixture_block": (205.0, 172.0, 249.0, 202.0),
}

# 任一裁块墨密度低于此值 → 说明坐标标错了，不是"完美匹配"
MIN_INK = 0.008


def _crop_gray(pdf, x0, y0, x1, y1, flip_y):
    """裁一块，返回 0-1 灰度数组（1 = 白）。"""
    doc = pymupdf.open(pdf)
    page = doc[0]
    Hmm = page.rect.height / K
    if flip_y:
        r = pymupdf.Rect(x0 * K, (Hmm - y1) * K, x1 * K, (Hmm - y0) * K)
    else:
        r = pymupdf.Rect(x0 * K, y0 * K, x1 * K, y1 * K)
    pix = page.get_pixmap(clip=r, dpi=DPI, colorspace=pymupdf.csGRAY)
    a = np.frombuffer(pix.samples, dtype=np.uint8).reshape(pix.height, pix.width)
    return a.astype(float) / 255.0


def _resize(a, shape):
    """最近邻缩放到目标尺寸。不引 skimage 也行，但引了更准。"""
    try:
        from skimage.transform import resize as sk_resize
        return sk_resize(a, shape, order=1, preserve_range=True, anti_aliasing=True)
    except Exception:
        yi = (np.linspace(0, a.shape[0] - 1, shape[0])).astype(int)
        xi = (np.linspace(0, a.shape[1] - 1, shape[1])).astype(int)
        return a[np.ix_(yi, xi)]


def _ssim(a, b):
    try:
        from skimage.metrics import structural_similarity as ssim
        return float(ssim(a, b, data_range=1.0))
    except Exception:
        # 退路：归一化互相关
        a = a - a.mean()
        b = b - b.mean()
        d = (np.sqrt((a * a).sum()) * np.sqrt((b * b).sum())) or 1.0
        return float((a * b).sum() / d)


def compare():
    if not os.path.exists(REF):
        return None, f"参考图不存在：{REF}"
    if not os.path.exists(CUR):
        return None, f"当前出图不存在：{CUR}"

    results = {}
    empty = []
    for name, rbox in REF_CROPS.items():
        cbox = CUR_CROPS.get(name)
        if not cbox:
            continue
        ra = _crop_gray(REF, *rbox, flip_y=False)     # 参考图 y 向下
        ca = _crop_gray(CUR, *cbox, flip_y=True)      # DXF y 向上
        # ★ 反假通过：任一裁块是空白，说明坐标错了
        r_ink = 1.0 - float(ra.mean())
        c_ink = 1.0 - float(ca.mean())
        if r_ink < MIN_INK or c_ink < MIN_INK:
            empty.append(f"{name}(参考墨密度 {r_ink:.4f} / 当前 {c_ink:.4f})")
            results[name] = 0.0
            continue
        # 统一到同一尺寸
        ca = _resize(ca, ra.shape)
        score = _ssim(ra, ca)
        results[name] = round(score, 4)
    if empty:
        return results, ("crop is blank, coordinates are wrong "
                         "(this is NOT a perfect match): " + "; ".join(empty))
    return results, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bless", action="store_true",
                    help="把当前分数写成新的基准")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    res, err = compare()
    if err:
        print(f"  [FAIL] 黄金图：{err}")
        return 1

    base = {}
    if os.path.exists(BASE):
        try:
            base = json.load(open(BASE, encoding="utf-8"))
        except Exception:
            base = {}

    if a.bless:
        json.dump(res, open(BASE, "w", encoding="utf-8"), indent=2)
        print(f"  基准已写入 {BASE}: {res}")
        return 0

    fails = []
    for name, score in res.items():
        prev = base.get(name)
        tag = "OK  "
        if score < THRESHOLD:
            tag = "FAIL"
            fails.append(name)
        extra = ""
        if prev is not None:
            d = score - prev
            if d < -0.06:
                tag = "FAIL"
                fails.append(name)
                extra = f"  (基准 {prev:.3f}，掉了 {abs(d):.3f})"
            else:
                extra = f"  (基准 {prev:.3f})"
        if not a.quiet:
            print(f"  [{tag}] 黄金图 {name:14s} SSIM {score:.3f}{extra}")

    if fails:
        print(f"\n  黄金图比对未通过：{', '.join(fails)}")
        print(f"  说明：参考图在 {os.path.relpath(REF, ROOT)}，"
              f"阈值 {THRESHOLD}。视觉语法漂移了，不是渲染差异。")
        return 1
    if not a.quiet:
        print(f"  黄金图比对通过（{len(res)} 个构件，阈值 {THRESHOLD}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
