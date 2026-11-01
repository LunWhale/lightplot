#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""draw.py — 图纸视觉语法的基础绘制原语

这里只放「怎么画」，不放「画什么」。业务逻辑在 render.py。

设计依据来自 NIDA《EX MACHINA》A1 图纸的实测（见 paper.py 注释与
docs/07-drafting-language.md）。三条铁律：

1. **单色。** 只有黑线 + 白底。层级靠线宽，不靠颜色。
   参考图 1934 条黑色路径、0 条彩色路径。

2. **白底遮罩做「断裂」。** 符号、文字、设备块都先铺一层白色填充，
   后画的东西会盖住先画的东西。看起来像线条在边界处断开，实际是
   白色在遮挡。参考图用了 1492 处白填充做这件事。

3. **线宽动态范围要大。** 参考图 0.025→0.713mm（28:1）。
   全是 0.15mm 的图看起来像草稿。
"""
import math

from ezdxf.enums import TextEntityAlignment

import paper
from paper import FS


class Pen:
    """带白底遮罩能力的绘制器。"""

    def __init__(self, msp, doc):
        self.msp = msp
        self.doc = doc
        self._mask_depth = 0

    # ---------------------------------------------------------- 基础
    def line(self, p1, p2, layer="SET", lt=None):
        a = {"layer": layer}
        if lt:
            a["linetype"] = lt
        return self.msp.add_line(p1, p2, dxfattribs=a)

    def poly(self, pts, layer="SET", close=False, lt=None):
        a = {"layer": layer}
        if lt:
            a["linetype"] = lt
        return self.msp.add_lwpolyline(pts, close=close, dxfattribs=a)

    def rect(self, x0, y0, x1, y1, layer="SET"):
        return self.poly([(x0, y0), (x1, y0), (x1, y1), (x0, y1)], layer, close=True)

    def circle(self, c, r, layer="FIXTURE"):
        return self.msp.add_circle(c, r, dxfattribs={"layer": layer})

    def arc(self, c, r, a0, a1, layer="FIXTURE"):
        return self.msp.add_arc(c, r, a0, a1, dxfattribs={"layer": layer})

    # ---------------------------------------------------------- 白底遮罩
    def mask(self, pts, layer="MASK"):
        """用白色填充盖住一块区域。这是「断裂」的实现方式。

        ezdxf 的 SOLID hatch 在 matplotlib 后端会渲染成实心白块，
        正好用来遮住下面的线。
        """
        h = self.msp.add_hatch(dxfattribs={"layer": layer, "true_color": paper.WHITE_RGB})
        h.paths.add_polyline_path(pts, is_closed=True)
        return h

    def mask_rect(self, x0, y0, x1, y1, pad=0.0, layer="MASK"):
        return self.mask(
            [(x0 - pad, y0 - pad), (x1 + pad, y0 - pad),
             (x1 + pad, y1 + pad), (x0 - pad, y1 + pad)],
            layer=layer,
        )

    def mask_circle(self, c, r, layer="MASK"):
        h = self.msp.add_hatch(dxfattribs={"layer": layer, "true_color": paper.WHITE_RGB})
        h.paths.add_edge_path().add_arc(c, r, 0, 360)
        return h

    # ---------------------------------------------------------- 文字
    def text(self, s, x, y, size, layer="NOTES", rot=0.0,
             align=TextEntityAlignment.MIDDLE_CENTER, style="LBL",
             color=None, mask=False, mask_pad=0.35):
        """画文字。mask=True 时先在字底下铺白底，防止压线。"""
        h = size
        if mask:
            w = estimate_text_width(str(s), h)
            if abs(rot % 180) > 45:
                w, hh = h, w
            else:
                hh = h
            if align == TextEntityAlignment.MIDDLE_LEFT:
                x0, x1 = x - mask_pad, x + w + mask_pad
            elif align == TextEntityAlignment.MIDDLE_RIGHT:
                x0, x1 = x - w - mask_pad, x + mask_pad
            else:
                x0, x1 = x - w / 2 - mask_pad, x + w / 2 + mask_pad
            self.mask_rect(x0, y - hh / 2 - mask_pad, x1, y + hh / 2 + mask_pad)
        t = self.msp.add_text(str(s), height=size, rotation=rot,
                              dxfattribs={"layer": layer, "style": style})
        if color is not None:
            t.dxf.color = color
        t.set_placement((x, y), align=align)
        return t

    # ---------------------------------------------------------- 圆圈编号
    def mark(self, s, x, y, size=None, layer="MARK"):
        """USITT RP-2 §6.14.1：圆形 = Channel（通道）。

        参考图所有通道号都画在圆圈里。裸数字不符合规范，也读不清。
        """
        size = size or FS["UNIT"]
        r = size * 1.05          # 圆圈要给数字留呼吸，参考图 r/字高 ≈ 1.05
        self.mask_circle((x, y), r)
        self.circle((x, y), r, layer)
        self.text(s, x, y, size, layer, align=TextEntityAlignment.MIDDLE_CENTER)
        return r


def estimate_text_width(s, h, family="regular"):
    """文字宽度（图纸 mm）—— 真实字体度量，不是估算。"""
    try:
        import metrics as _m
        return _m.width_mm(s, h, family)
    except Exception:
        w = 0.0
        for ch in str(s):
            w += h * (1.0 if ord(ch) > 0x2E80 else 0.58)
        return w


# ============================================================ 构件绘制
def truss_bar(pen, x0, y0, x1, y1, width_mm, layer="TRUSS", fill_layer="TRUSS_FILL"):
    """双线构件条 —— 参考图里桁架/管就是这个样子。

    实测：参考图的桁架是一条 11.3pt 宽的**白色填充条 + 0.14pt 细描边**，
    不是实心三角格构。用户说的「双线」就是这两条边线。

    width_mm 是构件在图纸上的实际宽度（mm）。
    """
    dx, dy = x1 - x0, y1 - y0
    L = math.hypot(dx, dy)
    if L < 1e-9:
        return
    ux, uy = dx / L, dy / L
    nx, ny = -uy * width_mm / 2, ux * width_mm / 2

    a = (x0 + nx, y0 + ny)
    b = (x1 + nx, y1 + ny)
    c = (x1 - nx, y1 - ny)
    d = (x0 - nx, y0 - ny)

    # 白底：先铺，盖住下面的东西
    pen.mask([a, b, c, d], layer=fill_layer)
    # 双线：只画两条长边 + 两个端封
    pen.line(a, b, layer)
    pen.line(d, c, layer)
    pen.line(a, d, layer)
    pen.line(b, c, layer)


def truss_end_cap(pen, x, y, angle_deg, width_mm, layer="TRUSS", seg=None):
    """构件端头的三角格构 —— 参考图「Truss 形状」的关键特征。

    实测参考图：整条桁架不铺满斜撑（那样太脏），只在端头/节点处
    画一小段三角形格构，让读图人知道「这是桁架，不是圆管」。
    seg 是格构段长度，默认约 1.6 倍截面宽。
    """
    a = math.radians(angle_deg)
    ux, uy = math.cos(a), math.sin(a)
    nx, ny = -uy, ux
    hw = width_mm / 2
    seg = seg or width_mm * 1.6

    p0 = (x, y)
    p1 = (x + ux * seg, y + uy * seg)
    pm = (x + ux * seg / 2, y + uy * seg / 2)

    # 上下弦
    pen.line((p0[0] + nx * hw, p0[1] + ny * hw), (p1[0] + nx * hw, p1[1] + ny * hw), layer)
    pen.line((p0[0] - nx * hw, p0[1] - ny * hw), (p1[0] - nx * hw, p1[1] - ny * hw), layer)
    # 端封
    pen.line((p0[0] + nx * hw, p0[1] + ny * hw), (p0[0] - nx * hw, p0[1] - ny * hw), layer)
    pen.line((p1[0] + nx * hw, p1[1] + ny * hw), (p1[0] - nx * hw, p1[1] - ny * hw), layer)
    # 一根斜撑（左下 -> 右上），构成一个三角
    pen.line((p0[0] - nx * hw, p0[1] - ny * hw), (p1[0] + nx * hw, p1[1] + ny * hw), layer)
    # 中竖杆
    pen.line((pm[0] + nx * hw, pm[1] + ny * hw), (pm[0] - nx * hw, pm[1] - ny * hw), layer)


def truss_mid_pattern(pen, x0, y0, x1, y1, width_mm, layer="TRUSS", bay=None):
    """长构件的中间格构：稀疏的之字形斜撑。

    参考图在长桁架上每隔一段画一个三角，不是连续 Z 字。
    这里按 bay 间距画，密度接近参考图。
    """
    dx, dy = x1 - x0, y1 - y0
    L = math.hypot(dx, dy)
    if L < 1e-9:
        return
    ux, uy = dx / L, dy / L
    nx, ny = -uy * width_mm / 2, ux * width_mm / 2
    bay = bay or width_mm * 6      # 每 6 倍截面宽一个节间

    n = max(1, int(L / bay))
    step = L / n
    for i in range(n):
        t0 = i * step
        t1 = (i + 1) * step
        ax, ay = x0 + ux * t0, y0 + uy * t0
        bx, by = x0 + ux * t1, y0 + uy * t1
        if i % 2 == 0:
            pen.line((ax + nx, ay + ny), (bx - nx, by - ny), layer)
        else:
            pen.line((ax - nx, ay - ny), (bx + nx, by + ny), layer)


def equipment_block(pen, label, x, y, w, h, size=None):
    """设备方块（SPEAKER 等）：白底 + 细边 + 居中标签。

    参考图里 SPEAKER 就是一个白底方块，桁架线在它边界处断开。
    """
    size = size or FS["DEVICE"]
    pen.mask_rect(x - w / 2, y - h / 2, x + w / 2, y + h / 2, pad=0)
    pen.rect(x - w / 2, y - h / 2, x + w / 2, y + h / 2, "SET")
    pen.text(label, x, y, size, "SET", align=TextEntityAlignment.MIDDLE_CENTER)
