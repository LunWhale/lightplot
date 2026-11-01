#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""draft.py — 舞台灯光图纸的构件绘制原语

所有几何参数都从 NIDA《EX MACHINA》两张 A1 图纸的 PDF 矢量路径里
直接量出来的，不是估的。测量脚本见 tools/measure_reference.py。

============================================================
一、桁架（Truss）—— 实测自 XMACH_LXTrussPlan
============================================================
一个桁架单元是 **34.08 × 34.08 pt 的正方形**（比例 1:1）。内部构造：

    上弦  = 矩形，高 5.76pt（= 0.169 × 单元宽）
    下弦  = 矩形，高 5.76pt
    竖杆  = 矩形，宽 2.88pt（= 0.0845），垂直连接上下弦
    斜撑  = **平行四边形**（不是线！），厚 2.64pt（= 0.0775）
            apex 在单元中心顶部，两腿落到下弦两端 —— 形成 Λ
    全部白色填充 + 0.144pt 描边

绘制顺序决定层次：先竖杆和弦杆，斜撑最后画 → 斜撑压在上弦之上。

视觉上就是： `|  Λ  |  Λ  |  Λ  |`  —— 这就是用户说的「正 M」，
因为相邻单元的 Λ 共享竖杆，连起来看像连续的 M。

============================================================
二、管线（LX / SOUND pipe）—— 实测自 XMACH_LXGRID
============================================================
不是单线，是**空心长条**：

    外框  = 矩形，宽 18pt，**白色填充 + 0.72pt 粗描边**
    内线  = 两条平行细线，各距外框 3.4pt，0.36pt

所以看起来是「一个超级长的空心长方形，里面还有两条线」。
"""
import math

from ezdxf.enums import TextEntityAlignment

import paper
from paper import FS


# ============================================================ 桁架
# 实测自 XMACH_LXTrussPlan（A1），单元素归一化坐标（x 从左，y 从顶）
#
#   cell 是 1:1 正方形（实测 34.08 × 34.08 pt）
#   ┌──────────────────────────┐  y=0
#   │        上弦 0.169        │
#   ├──┬────────────────────┬──┤  y=0.169
#   │  │      Λ  Λ          │  │
#   │杆│     Λ    Λ         │杆│  斜撑是**平行四边形**，不是线
#   │  │    Λ      Λ        │  │
#   ├──┴────────────────────┴──┤  y=0.831
#   │        下弦 0.169        │
#   └──────────────────────────┘  y=1.0
#
# 关键：斜撑两端**伸进弦杆内部**（y=0.063 / 0.937），
# 但弦杆最后画（白底+描边），把斜撑端头盖住 →
# 视觉上 Λ 的顶点正好贴住上弦下边缘，两个脚贴住下弦上边缘。
# 实测（tools/extract_ref.py 从参考图 PDF 直接扒出来，见 data/ref_symbols.json）
# 单元 pitch 11.77mm、高 12.02mm（高/宽 = 1.0216），竖杆 1.016mm，弦杆 2.032mm。
# 斜撑是**平行四边形**，顶点在单元**中央**、两只脚落在下弦两端 —— 连起来是正 M。
# ★ 顶点顺序必须照 PDF 描边路径：顶内 → 顶外 → 底内 → 底外。
#   顺序错了会画成「蝴蝶结」（自交），渲出来就是用户说的「丑陋波浪线」。
TRUSS = {
    "pitch_mm": 11.7687,             # 单元宽（图纸 mm @1:25）
    "post_w":  1.016 / 11.7687,      # 0.0863
    "chord_h": 2.032 / 12.0227,      # 0.169
    "aspect":  12.0227 / 11.7687,    # H / W
    # 参考图里弦杆每 5 个单元（1.5m 一节）画一段，段与段之间靠
    # 「下一节的竖杆压在上一节弦杆断口上」形成层次感。别改成通长。
    "section_cells": 5,
    "diag_left":  [(0.48921, 0.06338), (0.56835, 0.10563),
                   (0.16547, 0.93662), (0.08633, 0.90141)],
    "diag_right": [(0.94964, 0.90141), (0.87050, 0.93662),
                   (0.46763, 0.10563), (0.54676, 0.06338)],
}


def truss(pen, p0, p1, cell_w, layer="TRUSS", fill_layer="TRUSS_FILL"):
    """画一段桁架（上下弦 + 正 M 格构）。

    p0, p1 : 图纸坐标端点（中心线）
    cell_w : 单元宽（图纸 mm）。桁架实物宽 300mm @ 1:25 → 12mm

    绘制顺序照抄参考图（PDF 里的路径顺序就是这么排的）：
        1. 竖杆   2. 斜撑   3. 下弦   4. 上弦
    全是白填充 + 细描边，后画的盖住先画的。
    所以斜撑的端头会被弦杆吃掉，得到「Λ 顶点正好顶到上弦下沿」
    的干净效果；相邻单元的斜撑在顶点处互相压，产生层次感。
    """
    x0, y0 = p0
    x1, y1 = p1
    dx, dy = x1 - x0, y1 - y0
    L = math.hypot(dx, dy)
    if L < 1e-6:
        return
    ux, uy = dx / L, dy / L
    nx, ny = -uy, ux                 # 法向（+ 侧 = 上弦侧）

    W = cell_w
    H = W * TRUSS["aspect"]          # 实测 高/宽 = 1.0216

    pw = TRUSS["post_w"] * W         # 竖杆宽
    ch = TRUSS["chord_h"] * H        # 弦杆高

    # ★ 节距必须**精确等于** W，不能把余数摊到每一格上。
    # 参考图里 Truss 1 从 54.19 到 376.34mm，实测每格 11.7687mm，
    # 末尾是**不满一格**的残格（11.77×27 = 317.8，剩 4.35mm）。
    # 早先写 int(round(L/W)) 再 L/n_cells 平均，会把 pitch 变成 11.59，
    # 29 格之后累积偏差 5mm —— 整条桁架的斜撑全部错位。
    step = W
    n_cells = max(1, int(math.ceil(L / W - 1e-6)))

    def P(s, t):
        """(沿轴 s, 法向 t) -> 图纸坐标。t=+H/2 是上弦外边。"""
        return (x0 + ux * s + nx * t, y0 + uy * s + ny * t)

    def solid(pts):
        h = pen.msp.add_hatch(
            dxfattribs={"layer": fill_layer, "true_color": paper.WHITE_RGB})
        h.paths.add_polyline_path(pts, is_closed=True)
        pen.poly(pts, layer, close=True)

    # ---------- 分段：参考图里弦杆不是通长一根，而是每 5 个单元
    # （= 1.5m 一节）一段，段与段之间留一道可见的接缝。
    # 竖杆也是「一节里 5 根 + 末尾收一根」，所以接缝处的竖杆压在后一节
    # 的弦杆上面 —— 这个层次感是参考图的关键，别改成通长。
    SECT = TRUSS["section_cells"]              # 5
    n_sect = max(1, int(math.ceil(n_cells / SECT)))
    cell_of_sect = [min(SECT, n_cells - k * SECT) for k in range(n_sect)]

    for k in range(n_sect):
        s_begin = k * SECT * step
        s_end = s_begin + cell_of_sect[k] * step
        # 1. 竖杆（末节可能不满一格，只画到 L）
        for i in range(cell_of_sect[k]):
            s = s_begin + i * step
            s_end_i = min(s + pw, L)
            if s_end_i - s < 1e-6:
                continue
            solid([P(s, H / 2), P(s_end_i, H / 2),
                   P(s_end_i, -H / 2), P(s, -H / 2)])
        # 2. 斜撑（两个平行四边形，右腿后画压住左腿）
        for i in range(cell_of_sect[k]):
            s0 = s_begin + i * step
            w_i = min(W, L - s0)          # 末格收窄
            if w_i < W * 0.25:
                break

            def PP(fx, fy, _s0=s0, _w=w_i):
                # fy 从**上弦外沿**量起（PDF 向下），换算成以中线为原点
                return P(_s0 + fx * _w, (0.5 - fy) * H)

            for quad in (TRUSS["diag_left"], TRUSS["diag_right"]):
                solid([PP(fx, fy) for fx, fy in quad])
        # 3/4. 本节的弦杆：下弦先、上弦后，各一根
        for top in (False, True):
            t_out = H / 2 if top else -H / 2
            t_in = (H / 2 - ch) if top else (-H / 2 + ch)
            solid([P(s_begin, t_out), P(s_end, t_out),
                   P(s_end, t_in), P(s_begin, t_in)])

    # 末端的收边竖杆（画在最后，压住最后一节的弦杆断口）
    solid([P(L - pw, H / 2), P(L, H / 2),
           P(L, -H / 2), P(L - pw, -H / 2)])


# ============================================================ 管线（LX / SOUND）
# 实测参考图 XMACH_LXGRID，PDF 原始路径：
#   fill=(1,1,1) 的四条 l 段 (1382.16,410.16)→(192.72,410.16)→(192.72,404.64)
#                →(1382.16,404.64)→闭合，随后 qu 描边 lw=0.144
#   即外高 5.52pt = 1.9476mm，白填充 + 0.144pt 细描边，**没有内线**。
# 用户的话：「LX 和 SOUND 的这个线是空心线，是一个超级长方形。」
PIPE = {
    "height": 1.9476,   # 图纸 mm —— 空心长条外高（= 5.52pt）
}


def pipe(pen, p0, p1, height=None, layer="PIPE", fill_layer="PIPE_FILL"):
    """画一根 LX / SOUND 管线：一个**空心超长方形**。

    p0, p1 : 中心线两端（图纸 mm）
    height : 外高，默认 PIPE["height"]（1.95mm，1:25 图上约 49mm 实物）

    做法与参考图一致：先白色填充矩形（把底下的线切断），
    再沿四边描一圈闭合折线。只有四条边，没有中间线、没有波浪。
    """
    h = PIPE["height"] if height is None else height
    x0, y0 = p0
    x1, y1 = p1
    dx, dy = x1 - x0, y1 - y0
    L = math.hypot(dx, dy)
    if L < 1e-6:
        return
    ux, uy = dx / L, dy / L
    nx, ny = -uy, ux
    hw = h / 2.0

    def P(s, t):
        return (x0 + ux * s + nx * t, y0 + uy * s + ny * t)

    corners = [P(0, -hw), P(L, -hw), P(L, hw), P(0, hw)]
    hatch = pen.msp.add_hatch(
        dxfattribs={"layer": fill_layer, "true_color": paper.WHITE_RGB})
    hatch.paths.add_polyline_path(corners, is_closed=True)
    pen.poly(corners, layer, close=True)


# ============================================================ 设备方块
def device_box(pen, label, cx, cy, w, h, size=None, layer="SET",
               fill_layer="SET_FILL"):
    """设备方块（SPEAKER / projector 等）：白底 + 边线 + 居中标签。

    参考图里 SPEAKER 就是白底矩形，桁架线在它边界处断开。
    """
    size = size or FS["DEVICE"]
    pen.mask_rect(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2,
                  layer=fill_layer)
    pen.rect(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2, layer)
    pen.text(label, cx, cy, size, layer, align=TextEntityAlignment.MIDDLE_CENTER)


# ============================================================ 圆圈编号
def channel_mark(pen, value, cx, cy, size=None):
    """USITT RP-2 §6.14.1：圆形 = Channel。

    参考图所有通道号都在圆圈里，圆圈直径 ≈ 2.1 × 字高。
    """
    size = size or FS["UNIT"]
    r = size * 1.05
    pen.mask_circle((cx, cy), r)
    pen.circle((cx, cy), r, "MARK")
    pen.text(value, cx, cy, size, "MARK",
             align=TextEntityAlignment.MIDDLE_CENTER)
    return r
