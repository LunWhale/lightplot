#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""pdfout.py — 原生矢量 PDF 后端（PyMuPDF）

为什么要重写（而不是继续用 ezdxf 的 matplotlib 后端）
====================================================
实测结论（不是猜的）：

1. ezdxf 的**所有** drawing backend 在 pipeline 里把文字当路径画出，
   所以从 PDF 里 `get_text()` 取不到任何字 —— 交付物变成「看起来像图」，
   客户/同事无法复制灯具号去做表格，也没法用 pdftotext 校对。
2. matplotlib 是绘图库不是 CAD 渲染器：线宽按 pt 走、白填充是 hatch
   图案而不是 SOLID，细线在小尺寸下抗锯齿会糊掉。
3. 参考图的 PDF 是**真矢量 + 真字体**（`ArialNarrow` / `Arial` /
   `Helvetica` 都能被 pymupdf 读出 span 字号），我们照着它的语法做，
   才能逐项对齐。

这个后端做什么
--------------
读**已经画好的 DXF**（几何只有一份来源，DXF 仍然交付给 Vectorworks），
用 PyMuPDF 逐实体重绘：

    图层线宽（1/100mm） → pt        真线宽
    SOLID HATCH          → 白色填充  真遮挡
    TEXT                 → 真字体    可提取
    INSERT               → 递归变换  块引用展开
    DIMENSION            → virtual_entities 展开

坐标系
------
DXF：mm，y 向上。PDF：pt，y 向下。
    px = x * 72/25.4
    py = (SHEET_H - y) * 72/25.4
于是 1 图纸单位 = 1mm，1:25 就是真 1:25。

字体（照参考图实测的分工）
------------------------
    Arial Narrow       图签字段 / 图纸名 / 剧名 / 大图号
    Arial Narrow Bold  通道号（圆圈内）/ 色片号
    Arial             说明 / 图例 / 设备名 / 光区号
    Helvetica→Arial   构件名（Truss / LX 位置名）
"""
import os
import math

import pymupdf
import ezdxf

import paper

K = 72.0 / 25.4                    # mm -> pt

# ============================================================ 字体
_FONT_CANDIDATES = {
    "narrow": ["/System/Library/Fonts/Supplemental/Arial Narrow.ttf",
               "/Library/Fonts/Arial Narrow.ttf",
               "/usr/share/fonts/truetype/msttcorefonts/Arial_Narrow.ttf"],
    "narrowbold": ["/System/Library/Fonts/Supplemental/Arial Narrow Bold.ttf",
                   "/Library/Fonts/Arial Narrow Bold.ttf"],
    "regular": ["/System/Library/Fonts/Supplemental/Arial.ttf",
                "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
                "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"],
    "bold": ["/System/Library/Fonts/Supplemental/Arial Bold.ttf",
             "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"],
}

# 字体分工 —— 照参考图实测（pymupdf 读 span 的 font 字段）：
#   图签字段 / 图纸名 / 剧名 / 大图号  → ArialNarrow（窄体，省 20% 宽度）
#   通道号（圆圈内）/ 色片号          → ArialNarrow-Bold
#   说明 / 图例 / 设备名 / 光区号     → ArialMT（Helvetica 度量相同）
#   构件名（Truss N / LX n）          → ArialMT（参考图就是 Helvetica 8.8mm）
LAYER_TO_FAMILY = {
    "TB_TEXT": "narrow",
    "MARK": "narrowbold",
    "FIXTURE_TXT": "narrowbold",
    "GRIDTEXT": "regular",
}

_FONT_CACHE = {}


def font_path(family):
    for p in _FONT_CANDIDATES.get(family, []):
        if os.path.exists(p):
            return p
    # 兜底：任何能打开的无衬线体
    for p in _FONT_CANDIDATES["regular"]:
        if os.path.exists(p):
            return p
    raise SystemExit(f"找不到字体（family={family}）。请安装 Arial 或用 LX_FONT 指定。")


def get_font(family):
    if family not in _FONT_CACHE:
        _FONT_CACHE[family] = pymupdf.Font(fontfile=font_path(family))
    return _FONT_CACHE[family]


def text_width_mm(s, em_mm, family="regular"):
    """按真实字体度量算文字宽度（mm）。em_mm = 字号（em 高）。"""
    f = get_font(family)
    return f.text_length(str(s), em_mm * K) / K


# Arial 的 cap height / em = 1467/2048。参考图的 span size 是 **em**，
# 而 DXF 的 TEXT height 是 **cap**，所以写 DXF 时要乘这个系数。
from metrics import EM_TO_CAP


# ============================================================ 颜色
def _color(rgb_int):
    """DXF ACI -> (r,g,b)。只处理本项目用到的黑白灰。"""
    if rgb_int in (0, 7, 250, 256, None):
        return (0.0, 0.0, 0.0)
    if rgb_int == 8:
        return (0.24, 0.24, 0.24)
    if rgb_int == 1:
        return (1.0, 0.0, 0.0)
    return (0.0, 0.0, 0.0)


# ============================================================ 线型
_DASH = {
    "DASHED": "[3.2 1.6] 0",
    "DASHDOT": "[5.0 1.6 1.0 1.6] 0",
    "CONTINUOUS": None,
    "BYLAYER": None,
}


def _dashes(lt):
    return _DASH.get((lt or "CONTINUOUS").upper(), None)


# ============================================================ 变换
class Xform:
    """2D 仿射：先缩放旋转、再平移（DXF INSERT 语义）。"""

    __slots__ = ("sx", "sy", "rot", "tx", "ty", "base")

    def __init__(self, sx=1.0, sy=1.0, rot=0.0, tx=0.0, ty=0.0, base=(0.0, 0.0)):
        self.sx, self.sy = sx, sy
        self.rot = math.radians(rot)
        self.tx, self.ty = tx, ty
        self.base = base

    def apply(self, x, y):
        dx, dy = x - self.base[0], y - self.base[1]
        dx *= self.sx
        dy *= self.sy
        c, s = math.cos(self.rot), math.sin(self.rot)
        return (dx * c - dy * s + self.tx, dx * s + dy * c + self.ty)

    def delta_angle(self):
        return math.degrees(self.rot)

    def scale_avg(self):
        return (abs(self.sx) + abs(self.sy)) / 2.0

    def compose(self, other):
        """self ∘ other：先 other 再 self。"""
        # 结果为：scale 相乘、rotation 相加、平移用 self 变换 other 的原点
        nx, ny = self.apply(other.tx, other.ty)
        return Xform(self.sx * other.sx, self.sy * other.sy,
                     self.delta_angle() + other.delta_angle(), nx, ny)


IDENT = Xform()


# ============================================================ 渲染器
class PdfRenderer:
    def __init__(self, doc, sheet_w, sheet_h):
        self.doc = doc
        self.W = sheet_w
        self.H = sheet_h
        self.page = None
        self.mm = K

        # 图层属性查表
        self.layer_lw = {}
        self.layer_color = {}
        self.layer_lt = {}
        for lyr in doc.layers:
            if lyr.dxf.name in ("0", "Defpoints"):
                continue
            lw = lyr.dxf.lineweight
            self.layer_lw[lyr.dxf.name] = (lw / 100.0) if lw and lw > 0 else 0.13
            self.layer_color[lyr.dxf.name] = lyr.dxf.color
            self.layer_lt[lyr.dxf.name] = lyr.dxf.linetype

        # 绘制顺序：按 paper.DRAW_ORDER 分层，层内保持实体顺序
        self.order = {n: i for i, n in enumerate(paper.DRAW_ORDER)}

    # ---------------------------------------------------------- 坐标
    def P(self, x, y):
        return pymupdf.Point(x * self.mm, (self.H - y) * self.mm)

    # ---------------------------------------------------------- 样式
    def _lw(self, ent):
        lw = ent.dxf.lineweight if hasattr(ent.dxf, "lineweight") else -1
        if lw is None or lw < 0:
            lw = self.layer_lw.get(ent.dxf.layer, 0.13)
        else:
            lw = lw / 100.0
        return max(0.012, lw)

    def _col(self, ent):
        c = ent.dxf.color if hasattr(ent.dxf, "color") else 256
        if c in (256, None):
            c = self.layer_color.get(ent.dxf.layer, 7)
        return _color(c)

    def _dash(self, ent):
        lt = ent.dxf.linetype if hasattr(ent.dxf, "linetype") else "BYLAYER"
        if lt in (None, "BYLAYER"):
            lt = self.layer_lt.get(ent.dxf.layer, "CONTINUOUS")
        return _dashes(lt)

    # ---------------------------------------------------------- 基本图元
    # PyMuPDF 1.28 的 Page 没有 draw_polygon；填充必须走 Shape.finish(fill=...)。
    def _shape(self):
        sh = self.page.new_shape()
        return sh

    def line(self, p0, p1, ent):
        a, b = self.P(*p0), self.P(*p1)
        if abs(a.x - b.x) < 1e-6 and abs(a.y - b.y) < 1e-6:
            return
        sh = self._shape()
        sh.draw_line(a, b)
        sh.finish(color=self._col(ent), width=self._lw(ent) * self.mm,
                  dashes=self._dash(ent), lineCap=1, lineJoin=1)
        sh.commit()

    def poly(self, pts, ent, close=False):
        if len(pts) < 2:
            return
        seq = [self.P(*p) for p in pts]
        sh = self._shape()
        sh.draw_polyline(seq)
        sh.finish(color=self._col(ent), width=self._lw(ent) * self.mm,
                  dashes=self._dash(ent), lineCap=1, lineJoin=1,
                  closePath=bool(close))
        sh.commit()

    def filled(self, pts, ent, color=(1.0, 1.0, 1.0)):
        """SOLID 填充：真遮挡（不是 hatch 图案）。"""
        if len(pts) < 3:
            return
        seq = [self.P(*p) for p in pts]
        sh = self._shape()
        sh.draw_polyline(seq)
        sh.finish(color=None, fill=color, width=0, closePath=True)
        sh.commit()

    def circle(self, c, r, ent, fill=None):
        ctr = self.P(*c)
        rr = max(0.01, r * self.mm)
        sh = self._shape()
        sh.draw_circle(ctr, rr)
        sh.finish(color=self._col(ent), fill=fill,
                  width=self._lw(ent) * self.mm)
        sh.commit()

    def arc(self, c, r, a0, a1, ent):
        ctr = self.P(*c)
        rr = r * self.mm
        n = max(6, int(abs(a1 - a0) / 10))
        pts = []
        for i in range(n + 1):
            a = math.radians(a0 + (a1 - a0) * i / n)
            pts.append(pymupdf.Point(ctr.x + rr * math.cos(a),
                                     ctr.y - rr * math.sin(a)))
        sh = self._shape()
        sh.draw_polyline(pts)
        sh.finish(color=self._col(ent), width=self._lw(ent) * self.mm,
                  lineCap=1, lineJoin=1)
        sh.commit()

    # ---------------------------------------------------------- 文字
    def _family(self, ent):
        # 注意：ezdxf 的 dxf.get() 对不存在的属性会抛 DXFAttributeError
        # （不是返回 None）。这里必须先判 hasattr，否则所有 TEXT 都被跳过 ——
        # 曾经因此产出「零文字」的 PDF，而 verify 只查 DXF，假绿灯。
        if hasattr(ent.dxf, "family"):
            fam = ent.dxf.family
            if fam in _FONT_CANDIDATES:
                return fam
        return LAYER_TO_FAMILY.get(ent.dxf.layer, "regular")

    def text(self, ent, xf=IDENT):
        """
        DXF TEXT 的 height 是 **cap height**。
        PDF 的 fontsize 是 **em**，所以 fontsize_pt = cap_mm / EM_TO_CAP * K。
        """
        s = ent.dxf.text
        if not s:
            return
        h = ent.dxf.height * xf.scale_avg()
        em_pt = (h / EM_TO_CAP) * self.mm

        rot = (ent.dxf.rotation or 0.0) + xf.delta_angle()
        halign, valign = ent.dxf.halign, ent.dxf.valign
        ip = ent.dxf.insert
        ap = ent.dxf.get("align_point", None)
        # DXF：halign/valign 非 0 时用 align_point 作为定位点
        if (halign or valign) and ap is not None:
            px, py = ap.x, ap.y
        else:
            px, py = ip.x, ip.y
        px, py = xf.apply(px, py)

        fam = self._family(ent)
        f = get_font(fam)
        w = f.text_length(s, em_pt)

        # 先算基线原点（未旋转、y 向上的 mm 坐标）
        asc = f.ascender * em_pt
        desc = f.descender * em_pt        # 负数
        if halign in (1, 4):              # center
            ox = -w / 2.0
        elif halign in (2, 5):            # right
            ox = -w
        else:
            ox = 0.0
        if valign == 2:                   # middle：cap 的上下居中
            oy = -(h * self.mm) / 2.0
        elif valign == 3:                 # top
            oy = -(h * self.mm)
        elif valign == 1:                 # bottom
            oy = 0.0
        else:
            oy = 0.0                      # baseline

        base = pymupdf.Point(px * self.mm + ox, (self.H - py) * self.mm - oy)

        self.page.insert_font(fontname=fam, fontbuffer=f.buffer) \
            if fam not in self._registered else None
        self._registered.add(fam)
        self.page.insert_text(base, s, fontname=fam, fontsize=em_pt,
                              color=self._col(ent), rotate=rot,
                              render_mode=0)

    # ---------------------------------------------------------- HATCH
    def hatch(self, ent, xf=IDENT):
        solid = ent.dxf.solid_fill == 1
        color = (1.0, 1.0, 1.0) if solid else None
        for path in ent.paths:
            pts = self._hatch_path(path, xf)
            if len(pts) >= 3:
                self.filled(pts, ent, color=color or (0, 0, 0))

    def _hatch_path(self, path, xf):
        pts = []
        try:
            for v in path.vertices:
                x, y = float(v[0]), float(v[1])
                pts.append(xf.apply(x, y))
        except Exception:
            pass
        if not pts and hasattr(path, "edges"):
            cur = None
            for e in path.edges:
                try:
                    if e.type == 1:          # LineEdge
                        p0 = xf.apply(e.start[0], e.start[1])
                        p1 = xf.apply(e.end[0], e.end[1])
                        if not pts:
                            pts.append(p0)
                        pts.append(p1)
                except Exception:
                    continue
        return pts

    # ---------------------------------------------------------- 块引用
    def insert(self, ent, xf=IDENT, depth=0):
        if depth > 6:
            return
        name = ent.dxf.name
        blk = self.doc.blocks.get(name)
        if blk is None:
            return
        bp = ent.dxf.insert
        sx = ent.dxf.get("xscale", 1.0) or 1.0
        sy = ent.dxf.get("yscale", 1.0) or 1.0
        rot = ent.dxf.rotation or 0.0
        local = Xform(sx, sy, rot, bp.x, bp.y, base=(0.0, 0.0))
        # DXF 的块基准点：block.dxf.base_point
        base = blk.block.dxf.base_point
        local = Xform(sx, sy, rot,
                      bp.x - (base.x * sx), bp.y - (base.y * sy),
                      base=(base.x, base.y))
        xf2 = xf.compose(local) if xf is not IDENT else local
        for sub in blk:
            self.entity(sub, xf2, depth + 1)

    # ---------------------------------------------------------- 分发
    def entity(self, ent, xf=IDENT, depth=0):
        t = ent.dxftype()
        try:
            if t == "LINE":
                self.line(xf.apply(*ent.dxf.start.vec2),
                          xf.apply(*ent.dxf.end.vec2), ent)
            elif t == "LWPOLYLINE":
                pts = [xf.apply(float(p[0]), float(p[1]))
                       for p in ent.get_points("xy")]
                self.poly(pts, ent, close=bool(ent.closed))
            elif t == "POLYLINE":
                pts = [xf.apply(v.dxf.location.x, v.dxf.location.y)
                       for v in ent.vertices]
                self.poly(pts, ent, close=bool(ent.is_closed))
            elif t == "CIRCLE":
                self.circle(xf.apply(*ent.dxf.center.vec2),
                            ent.dxf.radius * xf.scale_avg(), ent)
            elif t == "ARC":
                self.arc(xf.apply(*ent.dxf.center.vec2),
                         ent.dxf.radius * xf.scale_avg(),
                         ent.dxf.start_angle, ent.dxf.end_angle, ent)
            elif t == "HATCH":
                self.hatch(ent, xf)
            elif t == "TEXT":
                self.text(ent, xf)
            elif t == "MTEXT":
                txt = ent.plain_text().replace("\n", " ")
                if txt.strip():
                    self._mtext(ent, txt, xf)
            elif t == "INSERT":
                self.insert(ent, xf, depth)
            elif t == "DIMENSION":
                for v in ent.virtual_entities():
                    self.entity(v, xf, depth + 1)
            elif t == "POINT":
                p = xf.apply(*ent.dxf.location.vec2)
                self.page.draw_circle(self.P(*p), 0.1, color=(0, 0, 0), width=0)
        except Exception as e:
            print(f"    [pdfout] 跳过 {t} ({ent.dxf.get('layer','?')}): {e}")

    def _mtext(self, ent, txt, xf):
        ip = ent.dxf.insert
        px, py = xf.apply(ip.x, ip.y)
        h = (ent.dxf.char_height or 2.5) * xf.scale_avg()
        em_pt = (h / EM_TO_CAP) * self.mm
        fam = "regular"
        f = get_font(fam)
        _register(self.page, fam)
        base = pymupdf.Point(px * self.mm, (self.H - py) * self.mm)
        self.page.insert_text(base, txt, fontname=fam, fontsize=em_pt,
                              color=self._col(ent))

    # ---------------------------------------------------------- 主流程
    def render(self, msp, path):
        self.page = self.doc_pdf.new_page(width=self.W * self.mm,
                                          height=self.H * self.mm)
        self._registered = set()
        ents = list(msp)

        # ★ 必须按**实体原始顺序**画，不能按图层排序。
        # 桁架的层次感完全依赖「白填充 / 描边」交替：
        #     竖杆(填+描) → 左斜撑(填) → 左斜撑(描) → 右斜撑(填) → 右斜撑(描)
        #     → 下弦 → 上弦
        # 一旦按图层分组，所有 TRUSS_FILL 会先画、所有 TRUSS 后画，
        # 白填充就把斜撑的描边盖掉了 —— 桁架会变成一堆空洞的色块。
        # render.py 本来就是按正确顺序 add 的，照抄顺序即可。
        for ent in ents:
            self.entity(ent)
        self.doc_pdf.save(path, deflate=True, garbage=3)
        return path


def _register(page, fam):
    f = get_font(fam)
    page.insert_font(fontname=fam, fontbuffer=f.buffer)


# ============================================================ 对外接口
def dxf_to_pdf(dxf_or_doc, pdf_path, sheet_w, sheet_h, png_path=None,
               png_dpi=200):
    """把 DXF（路径或 ezdxf Document）重绘成原生矢量 PDF（+ 可选 PNG）。"""
    doc = ezdxf.readfile(dxf_or_doc) if isinstance(dxf_or_doc, str) else dxf_or_doc
    msp = doc.modelspace()

    r = PdfRenderer(doc, sheet_w, sheet_h)
    r.doc_pdf = pymupdf.open()
    r.render(msp, pdf_path)

    if png_path:
        d = pymupdf.open(pdf_path)
        pix = d[0].get_pixmap(dpi=int(png_dpi))
        pix.save(png_path)
        d.close()
    return pdf_path


if __name__ == "__main__":
    import sys
    here = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, here)
    base = os.path.join(here, "..", "out", "LX_plan")
    dxf_to_pdf(base + ".dxf", "/tmp/pdfout_test.pdf", 841.0, 594.0,
               "/tmp/pdfout_test.png")
    d = pymupdf.open("/tmp/pdfout_test.pdf")
    print("page", d[0].rect)
    print("TEXT:", repr(d[0].get_text()[:200]))
