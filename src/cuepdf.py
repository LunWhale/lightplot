#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cuepdf.py — 把 data/cues.yaml 排成可打印的 Cue Sheet PDF

为什么单独一个文件
------------------
Cue Sheet 是**在演出现场用的**：灯光操作员一只手拿它、另一只手推推子，
舞台上很暗。所以它必须是：
  · 纸，不是 CSV（Excel 打开会乱行）
  · 大字号、行距宽（暗环境能读）
  · 一页装不下就分页，且**每页重复表头**（翻页不用回想第几列）
  · Q 号在左边缘、加粗，一眼能定位

版面：A3 横向（420×297），左对齐无框线，靠留白和字重分区。
不用表格线 —— 参考图的语法就是没有表格线。
"""
import os
import sys

import pymupdf

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import metrics            # noqa: E402

K = 72.0 / 25.4
SHEET_W, SHEET_H = 420.0, 297.0      # A3 landscape
MARGIN = 12.0

# ★ Do NOT use pymupdf's built-in "china-s" for Latin text.
#   It renders every Latin glyph full-width, so "CUE SHEET" comes out as
#   "C U E   S H E E T" and every column overflows. Use the real Arial
#   faces, the same ones the drawings use (src/metrics.py owns the paths).
_FONT_FILES = {
    "regular": "/System/Library/Fonts/Supplemental/Arial.ttf",
    "bold": "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "narrow": "/System/Library/Fonts/Supplemental/Arial Narrow.ttf",
}
_font_cache = {}


def _font(family="regular"):
    if family in _font_cache:
        return _font_cache[family]
    for key in (family, "regular"):
        path = _FONT_FILES.get(key)
        if path and os.path.exists(path):
            f = pymupdf.Font(fontfile=path)
            f.buffer  # force load
            _font_cache[family] = (key, f)
            return _font_cache[family]
    raise SystemExit("cuepdf: Arial not found")


_registered = set()


def _put(page, x_mm, y_mm, text, cap_mm, family="regular", grey=0.0):
    """Place text by CAP height (same unit as the DXF drawings).

    pymupdf needs the font registered on the page once via insert_font();
    insert_text() then refers to it by name. (insert_text has no fontbuffer
    argument in 1.28 — that was the "bad fontfile" error.)
    """
    fam, f = _font(family)
    key = (id(page), fam)
    if key not in _registered:
        page.insert_font(fontname=fam, fontbuffer=f.buffer)
        _registered.add(key)
    em = cap_mm / metrics.EM_TO_CAP
    page.insert_text(pymupdf.Point(x_mm * K, y_mm * K), text,
                     fontname=fam, fontsize=em * K,
                     color=(grey, grey, grey))

# 列：(标题, 宽度mm, 是否用等宽数字对齐)
COLS = [
    ("Q",            16.0),
    ("ACT / SC",     24.0),
    ("CUE POINT (TRIGGER)", 86.0),
    ("LIGHTING STATE",     134.0),
    ("LANTERNS / GEL",      62.0),
    ("FADE",                24.0),
    ("NOTES",               50.0),
]

R_CAP = 2.35          # 正文 cap 高（mm）
R_LEAD = 3.9          # 行距
HDR_CAP = 2.6
ROW_PAD = 2.6         # 行间留白
SECTION_GAP = 4.5     # act 变化时的额外留白


def _wrap(text, width_mm, cap):
    """按真实字宽折行。中文按字断，拉丁按词断。"""
    text = " ".join(str(text or "").split())
    if not text:
        return []
    lines, cur = [], ""
    for ch in text:
        trial = cur + ch
        if metrics.width_mm(trial, cap, "regular") > width_mm and cur:
            # 拉丁词不要从中间断开：回退到最后一个空格
            if ch.isalnum() and " " in cur:
                cut = cur.rfind(" ")
                lines.append(cur[:cut])
                cur = cur[cut + 1:] + ch
            else:
                lines.append(cur)
                cur = ch
        else:
            cur = trial
    if cur:
        lines.append(cur)
    return lines


def _layout_rows(cues, prefix):
    """把每条 cue 折成若干行，返回 [(cue, [ (col_idx, line_text), ... ])]"""
    out = []
    for c in cues:
        cells = [
            f"{prefix} Q{c['q']}",
            c.get("act", ""),
            c.get("cue_point", ""),
            c.get("state", ""),
            c.get("lanterns", ""),
            c.get("fade", ""),
            c.get("notes", ""),
        ]
        wrapped = [_wrap(t, COLS[i][1] - 2.0, R_CAP) for i, t in enumerate(cells)]
        n = max(len(w) for w in wrapped)
        rows = []
        for li in range(n):
            rows.append([(i, w[li] if li < len(w) else "") for i, w in enumerate(wrapped)])
        out.append((c, rows))
    return out


def build(cd, out_pdf, rig_meta=None):
    prefix = (cd.get("meta") or {}).get("prefix", "LX")
    cues = cd["cues"]
    laid = _layout_rows(cues, prefix)

    doc = pymupdf.open()
    page = None
    y = 0.0

    x_useful = SHEET_W - 2 * MARGIN
    assert abs(sum(w for _, w in COLS) - x_useful) < 1.0, \
        f"列宽合计 {sum(w for _, w in COLS)} != 可用宽 {x_useful}"

    def col_x(i):
        return MARGIN + sum(w for _, w in COLS[:i])

    def new_page(first=False):
        nonlocal page, y
        page = doc.new_page(width=SHEET_W * K, height=SHEET_H * K)
        y = MARGIN
        # ---- 标题
        _put(page, MARGIN, y + 7.0, "CUE SHEET", 7.4, "regular")
        y += 10.0
        if rig_meta:
            sub = (f"{rig_meta.get('show', '')}   /   "
                   f"{rig_meta.get('playwright', '')}   /   "
                   f"{rig_meta.get('venue', '')}")
            _put(page, MARGIN, y + 3.2, sub, HDR_CAP, "regular")
        y += 6.5
        # 编号说明（任务书要求：表头写清编号方式）
        note = (f"Numbering: {cd.get('meta', {}).get('numbering', '')}"
                f"    Cues: {len(cues)}"
                + ("" if cd.get("meta", {}).get("verified")
                   else "    *** CUE POINTS NOT YET CHECKED AGAINST PRODUCTION SCRIPT ***"))
        _put(page, MARGIN, y + 2.4, note, R_CAP * 0.92, "regular", grey=0.35)
        y += 5.0
        # ---- 表头
        page.draw_line(pymupdf.Point(MARGIN * K, y * K),
                       pymupdf.Point((SHEET_W - MARGIN) * K, y * K),
                       color=(0, 0, 0), width=0.5)
        y += 1.6
        for i, (title, w) in enumerate(COLS):
            _put(page, col_x(i), y + HDR_CAP, title, HDR_CAP, "bold")
        y += HDR_CAP + 1.8
        page.draw_line(pymupdf.Point(MARGIN * K, y * K),
                       pymupdf.Point((SHEET_W - MARGIN) * K, y * K),
                       color=(0.55, 0.55, 0.55), width=0.25)
        y += 2.6

    new_page(first=True)
    prev_act = None

    for cue, rows in laid:
        act = cue.get("act", "")
        gap = SECTION_GAP if (prev_act and act != prev_act) else ROW_PAD

        block_h = len(rows) * R_LEAD + gap
        # 分页：留出页脚
        if y + block_h > SHEET_H - MARGIN - 4.0:
            # 页脚
            _put(page, MARGIN, SHEET_H - MARGIN + 1.0,
                 f"{prefix} CUE SHEET - page {doc.page_count}", 2.0,
                 "regular", grey=0.4)
            new_page()
            prev_act = None
            gap = ROW_PAD

        # act 分隔线
        if prev_act and act != prev_act:
            yy = y - SECTION_GAP * 0.45
            page.draw_line(pymupdf.Point(MARGIN * K, yy * K),
                           pymupdf.Point((SHEET_W - MARGIN) * K, yy * K),
                           color=(0.75, 0.75, 0.75), width=0.2)
        prev_act = act

        for ri, row in enumerate(rows):
            for ci, txt in row:
                if not txt:
                    continue
                # Q 号加粗效果：多描一遍
                if ci == 0:
                    _put(page, col_x(ci), y + R_CAP, txt, R_CAP, "bold")
                else:
                    _put(page, col_x(ci), y + R_CAP, txt, R_CAP, "regular",
                         grey=0.12 if ci in (3, 6) else 0.0)
            y += R_LEAD
        y += gap

    # 末页页脚
    _put(page, MARGIN, SHEET_H - MARGIN + 1.0,
         f"{prefix} CUE SHEET - page {doc.page_count}", 2.0, "regular", grey=0.4)

    doc.save(out_pdf, deflate=True)
    return doc.page_count


def main():
    import yaml
    root = os.path.dirname(HERE)
    cd = yaml.safe_load(open(os.path.join(root, "data", "cues.yaml"), encoding="utf-8"))
    rig = yaml.safe_load(open(os.path.join(root, "data", "rig.yaml"), encoding="utf-8"))
    out = os.path.join(root, "out", "cue_sheet.pdf")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    n = build(cd, out, rig.get("meta"))
    print(f"  PDF: {out}  ({n} 页, A3 横向)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
