#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""export.py — DXF/PDF/PNG 输出（单一定义来源）

============================================================
要修的那个 bug：PDF 不是 1:1，而是「内容被拉伸铺满纸张」
============================================================
旧代码：

    Frontend(...).draw_layout(msp, finalize=True)
    fig.set_size_inches(SHEET_W/25.4, SHEET_H/25.4, forward=True)

`finalize=True` 会让后端把坐标轴范围设成**图元包围盒**（DXF extents），
而不是图纸范围 (0,0)-(W,H)。实测本项目 DXF extents = 821×574mm，
纸张 841×594mm，于是：

    x 方向放大 841/821 = 1.0244 倍
    y 方向放大 594/574 = 1.0348 倍

两个方向还不一样 —— 因为 finalize 先按包围盒设范围、再用等比例适配画布，
最后 `set_size_inches` 又把画布改回纸张比。结果是**非等比拉伸 + 平移**：
1:25 的图实际变成约 1:24.4，桁架 12mm 单元画成 11.3mm，图框也不在 (10,10)。

为什么一直没被发现
------------------
`verify.py` 只检查 PDF 页面尺寸 841×594mm —— 这个永远是对的，
因为那是 figsize 决定的。错误全在页面**内容**里。典型的「假绿灯」。

正确做法
========
`finalize=False` + 显式钉死坐标范围：

    ax.set_xlim(0, SHEET_W); ax.set_ylim(0, SHEET_H)
    ax.set_aspect("equal", adjustable="box")

这样 1 图纸单位 = 1mm，1:25 就是真 1:25，图框就在 (10,10)。

`verify.py` 用 `check_scale()` 反解 PDF 里图框的实际位置和尺寸来验证，
不是看页面大小。
"""
import os

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt                              # noqa: E402
from ezdxf.addons.drawing import RenderContext, Frontend     # noqa: E402
from ezdxf.addons.drawing.matplotlib import MatplotlibBackend  # noqa: E402
from ezdxf.addons.drawing.config import (                    # noqa: E402
    Configuration, LineweightPolicy,
)

# ezdxf 的 matplotlib 后端把 DXF 线宽（1/100 mm）换算后**直接当 pt 写**，
# 没做 mm -> pt。不乘 72/25.4 的话整张图细 2.83 倍。
LW_SCALE = 72.0 / 25.4
PT_PER_MM = 72.0 / 25.4


def _config():
    return Configuration(
        lineweight_policy=LineweightPolicy.ABSOLUTE,
        lineweight_scaling=LW_SCALE,
        min_lineweight=0.02,
    )


def draw_sheet(doc, msp, base, sheet_w, sheet_h, dpi=300, png_dpi=200):
    """按真实图纸尺寸出 PDF + PNG。

    ★ 2026-10 换后端：PDF 不再走 matplotlib，改用 pdfout（PyMuPDF 原生矢量）。
      原因（实测）：
        - ezdxf 所有 backend 都把文字画成路径 → PDF 里 get_text() 为空，
          交付物无法复制灯具号、无法 pdftotext 校对；
        - matplotlib 线宽按 pt 而非图纸 mm，白填充是 hatch 图案不是 SOLID。
      现在 PDF 里：线宽是真 mm、白填充是真 SOLID、文字可提取（Arial Narrow）。
      PNG 也从 PDF 渲染，保证两者像素级一致。
    """
    import pdfout

    pdf_path = base + ".pdf"
    pdfout.dxf_to_pdf(doc, pdf_path, sheet_w, sheet_h,
                      png_path=base + ".png", png_dpi=png_dpi)
    return pdf_path


def draw_sheet_mpl(doc, msp, base, sheet_w, sheet_h, dpi=300, png_dpi=200):
    """旧路径（matplotlib）。保留作为兜底：万一 pdfout 出问题可切回来。"""
    fig = plt.figure(figsize=(sheet_w / 25.4, sheet_h / 25.4))
    ax = fig.add_axes([0.0, 0.0, 1.0, 1.0])
    ax.set_axis_off()

    Frontend(RenderContext(doc), MatplotlibBackend(ax),
             config=_config()).draw_layout(msp, finalize=False)

    ax.set_xlim(0.0, sheet_w)
    ax.set_ylim(0.0, sheet_h)
    ax.set_aspect("equal", adjustable="box")
    ax.set_position([0.0, 0.0, 1.0, 1.0])

    fig.set_size_inches(sheet_w / 25.4, sheet_h / 25.4, forward=True)
    fig.savefig(base + ".pdf", dpi=dpi, facecolor="white")
    fig.savefig(base + ".png", dpi=png_dpi, facecolor="white")
    plt.close(fig)
    return base + ".pdf"


# ---------------------------------------------------------------- 反解校验
def measure_sheet(pdf_path):
    """从 PDF 反解出图框的实际位置与尺寸（mm）。"""
    import pymupdf

    page = pymupdf.open(pdf_path)[0]
    pw = page.rect.width / PT_PER_MM
    ph = page.rect.height / PT_PER_MM

    best = None
    for pa in page.get_drawings():
        r = pa["rect"]
        w = r.width / PT_PER_MM
        h = r.height / PT_PER_MM
        if pa.get("fill") is not None:
            continue
        if w < pw * 0.85 or h < ph * 0.85:
            continue
        if best is None or w * h > best[0] * best[1]:
            best = (w, h, r.x0 / PT_PER_MM,
                    (page.rect.height - r.y1) / PT_PER_MM)
    if best is None:
        return {"page_w": pw, "page_h": ph}
    return {"page_w": pw, "page_h": ph,
            "frame_w": best[0], "frame_h": best[1],
            "frame_x0": best[2], "frame_y0": best[3]}


def check_scale(pdf_path, sheet_w, sheet_h, margin=None, tol=0.35):
    """验证 PDF 内容真是 1:1：图框应在 margin 处，尺寸 = 纸张 - 2×margin。

    margin 默认取 paper.FRAME_MARGIN（当前 0 = 外框贴纸边，照参考图）。
    早先写死 10.0，改成贴边后这条检查就把正确的图判成错误了。
    """
    if margin is None:
        try:
            import paper as _paper
            margin = getattr(_paper, "FRAME_MARGIN", 0.0)
        except Exception:
            margin = 0.0
    if not os.path.exists(pdf_path):
        return False, f"{pdf_path} 不存在"
    m = measure_sheet(pdf_path)
    if "frame_w" not in m:
        return False, "PDF 里找不到外图框"

    exp_w, exp_h = sheet_w - 2 * margin, sheet_h - 2 * margin
    dw, dh = m["frame_w"] - exp_w, m["frame_h"] - exp_h
    dx, dy = m["frame_x0"] - margin, m["frame_y0"] - margin
    err = max(abs(dw), abs(dh), abs(dx), abs(dy))
    detail = (f"图框 {m['frame_w']:.2f}×{m['frame_h']:.2f}mm "
              f"(应 {exp_w:.0f}×{exp_h:.0f}，差 {dw:+.2f}/{dh:+.2f})，"
              f"左下角 ({m['frame_x0']:.2f},{m['frame_y0']:.2f}) "
              f"(应 {margin:.0f},{margin:.0f}，差 {dx:+.2f}/{dy:+.2f})")
    return err <= tol, detail
