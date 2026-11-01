#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""plain.py — 生成「人话版」设计说明 PDF

用途
----
给完全不懂灯光的人（导演、演员、家长、评委）解释这套设计。
不是技术文档，是"为什么这么做"的说明。

设计原则
--------
1. **事实自动生成，观点手工写。**
   - "哪盏灯、什么颜色、挂在哪儿" → 从 rig.yaml / cues.yaml 读，绝不手写
   - "为什么这么打" → 在 data/explain.yaml 里手写
   手写数据必然漂移（灯号一改就错），所以把事实交给代码。

2. **不用行话。** 必须用时紧跟括号解释。校验器会检查这一点。

3. **诚实。** explain.yaml 的 honesty 节必须存在，缺了就报错 ——
   不许出"完美无缺"的说明。

输出：out/design_explained.pdf（A4 纵向）
"""
import os
import sys

import pymupdf
import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import metrics  # noqa: E402

K = 72.0 / 25.4
W, H = 210.0, 297.0
ML, MR, MT, MB = 20.0, 20.0, 20.0, 18.0

# ------------------------------------------------------------ 插图裁块
# 每张插图都是**从当前出图里实时裁出来的**，不是预先存好的图片。
# 坐标是 DXF 图纸毫米（原点左下）。
# 这样图改了、讲解里的插图自动跟着改，永远不会出现
# "文字说桁架是 M 形，插图里却是波浪线"这种漂移。
FIGURES = {
    # 舞台主体：三根桁架 + 灯具 + 标注。
    # ★ 不要用整张 A1（含图签和右栏）—— 缩到 110mm 宽时墨密度只剩 2%，
    #   印出来是一片空白，读者什么也看不到。裁"只含舞台"的一块。
    # ★ A1 的图缩到 A4 宽度必然读不清细节，这是物理限制，不是排版失误。
    #   所以这一块只负责让人看懂**版式**，细节靠后面的放大裁块。
    "plan":    ("out/LX_plan.pdf",    (140.0, 160.0, 640.0, 545.0), 400),
    # 桁架：取 LX2 中间一段，含 3 个节距 + 上下弦，看清 M 形腹杆
    "truss":   ("out/LX_plan.pdf",    (250.0, 419.0, 300.0, 439.0), 900),
    # 灯具符号 + 圆圈通道号 + 色片号（FOH 一排）
    "fixture": ("out/LX_plan.pdf",    (204.0, 172.0, 250.0, 202.0), 900),
    # 剖面图整体
    "section": ("out/LX_section.pdf", (12.0, 12.0, 408.0, 285.0), 200),
}

_F = {
    "regular": "/System/Library/Fonts/Supplemental/Arial.ttf",
    "bold": "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "italic": "/System/Library/Fonts/Supplemental/Arial Italic.ttf",
}
_c, _r = {}, set()


def _font(fam):
    if fam in _c:
        return _c[fam]
    path = _F.get(fam) or _F["regular"]
    if not os.path.exists(path):
        path = _F["regular"]
    f = pymupdf.Font(fontfile=path)
    f.buffer
    _c[fam] = (fam, f)
    return _c[fam]


def _put(page, x, y, text, cap, fam="regular", grey=0.0):
    name, f = _font(fam)
    k = (id(page), name)
    if k not in _r:
        page.insert_font(fontname=name, fontbuffer=f.buffer)
        _r.add(k)
    page.insert_text(pymupdf.Point(x * K, y * K), text,
                     fontname=name, fontsize=(cap / metrics.EM_TO_CAP) * K,
                     color=(grey, grey, grey))


def _wrap(text, width, cap, fam="regular"):
    words = " ".join(str(text or "").split()).split(" ")
    lines, cur = [], ""
    for w in words:
        trial = (cur + " " + w).strip()
        if metrics.width_mm(trial, cap, fam) > width and cur:
            lines.append(cur)
            cur = w
        else:
            cur = trial
    if cur:
        lines.append(cur)
    return lines


# ============================================================ 插图
def _figure_image(name):
    """把指定区域裁成 PNG，返回 (bytes, 宽mm, 高mm)。找不到就返回 None。"""
    spec = FIGURES.get(name)
    if not spec:
        return None
    rel, (x0, y0, x1, y1), dpi = spec
    path = os.path.join(ROOT, rel)
    if not os.path.exists(path):
        return None
    doc = pymupdf.open(path)
    page = doc[0]
    Hmm = page.rect.height / K
    clip = pymupdf.Rect(x0 * K, (Hmm - y1) * K, x1 * K, (Hmm - y0) * K)
    pix = page.get_pixmap(clip=clip, dpi=dpi)
    return pix.tobytes("png"), (x1 - x0), (y1 - y0)


# ============================================================ 校验
JARGON = ["DMX", "luminaire", "gobo", "frost", "iris", "shutter cut",
          "profile spot", "hard patch", "dimmer rack"]


def check(ex, rig, cues):
    errs, warns = [], []
    secs = {s["id"]: s for s in ex.get("sections", [])}
    if "honesty" not in secs:
        errs.append("explain.yaml 缺 honesty 节 —— 说明文档必须写明哪些没做完")
    for s in ex.get("sections", []):
        if not s.get("heading"):
            errs.append(f"节 {s.get('id')} 缺 heading")
        if not s.get("body"):
            errs.append(f"节 {s.get('id')} 缺 body")
    # 行话检查（只查手写的 body/detail，自动生成的部分不受影响）
    for s in ex.get("sections", []):
        blob = " ".join(str(s.get(k, "")) for k in ("body", "detail"))
        for it in s.get("items") or []:
            blob += " " + str(it.get("plain", ""))
        for j in JARGON:
            if j.lower() in blob.lower():
                warns.append(f"节 {s['id']} 用了行话 {j!r}，"
                             f"新手看不懂 —— 建议改成大白话或加括号解释")
    return errs, warns


# ============================================================ 自动事实
def facts_positions(rig):
    """每个吊挂位置：名字 / 高度 / 灯数 / 这排灯是干什么的。"""
    pos = {p["id"]: p for p in rig["positions"]}
    out = []
    for pid, p in pos.items():
        if p.get("type") == "line":
            continue
        fx = [f for f in rig["fixtures"] if f.get("pos") == pid]
        if not fx:
            continue
        types = sorted({f["type"] for f in fx})
        gels = sorted({f.get("gel", "") for f in fx})
        trim = p.get("trim", 0)
        out.append({
            "name": pid,
            "count": len(fx),
            "height": trim,
            "gels": gels,
            "types": types,
            "where": ("above the stage" if p.get("kind") == "h"
                      else "on a vertical bar at the side"),
        })
    return out


def facts_colours(rig):
    """每种色片：代号 / 名字 / 用了几台 / 用在哪儿。"""
    names = {g["gel"]: g["name"] for g in rig.get("gels", [])}
    out = []
    seen = []
    for f in rig["fixtures"]:
        g = f.get("gel", "")
        if g not in seen:
            seen.append(g)
    for g in seen:
        users = [f for f in rig["fixtures"] if f.get("gel") == g]
        out.append({
            "gel": g,
            "name": names.get(g, ""),
            "count": len(users),
            "positions": sorted({u["pos"] for u in users}),
        })
    return out


# ============================================================ 排版
def build(ex, rig, cues, out_pdf):
    meta = ex.get("meta") or {}
    doc = pymupdf.open()
    page = None
    y = 0.0
    pno = 0

    BW = W - ML - MR          # 正文宽度
    BODY = 3.0                # 正文 cap
    LEAD = 5.2
    HEAD = 4.6
    SUB = 2.9

    def footer():
        _put(page, ML, H - MB + 4.0,
             f"{meta.get('title', '')} — page {pno}", 1.9, "regular", grey=0.45)

    def new_page(first=False):
        nonlocal page, y, pno
        if page is not None:
            footer()
        page = doc.new_page(width=W * K, height=H * K)
        pno += 1
        y = MT
        if first:
            _put(page, ML, y + 9.0, meta.get("title", ""), 8.4, "bold")
            y += 13.0
            for ln in _wrap(meta.get("subtitle", ""), BW, SUB, "italic"):
                _put(page, ML, y + SUB, ln, SUB, "italic", grey=0.3)
                y += SUB + 2.4
            y += 3.0
            for ln in _wrap(meta.get("audience", ""), BW, 2.4, "regular"):
                _put(page, ML, y + 2.4, ln, 2.4, "regular", grey=0.45)
                y += 4.2
            y += 4.0
            page.draw_line(pymupdf.Point(ML * K, y * K),
                           pymupdf.Point((W - MR) * K, y * K),
                           color=(0, 0, 0), width=0.8)
            y += 9.0

    def need(h):
        nonlocal y
        if y + h > H - MB:
            new_page()

    def para(text, cap=BODY, fam="regular", grey=0.0, indent=0.0, lead=LEAD):
        nonlocal y
        for ln in _wrap(text, BW - indent, cap, fam):
            need(lead)
            _put(page, ML + indent, y + cap, ln, cap, fam, grey)
            y += lead

    new_page(first=True)

    for s in ex["sections"]:
        # 标题
        need(HEAD + 14)
        y += 2.0
        _put(page, ML, y + HEAD, s["heading"], HEAD, "bold")
        y += HEAD + 3.4
        # 短横线（视觉语法：不用框线）
        page.draw_line(pymupdf.Point(ML * K, y * K),
                       pymupdf.Point((ML + 14.0) * K, y * K),
                       color=(0, 0, 0), width=0.7)
        y += 5.0

        para(s.get("body", ""))
        y += 1.4

        # ---- 插图（从当前出图实时裁切）
        fig = s.get("figure")
        if fig:
            got = _figure_image(fig)
            if got:
                png, fw, fh = got
                # 按可用宽度等比缩放，最高不超过 78mm（避免吃掉整页）
                avail = BW
                scale = avail / fw
                dh = fh * scale
                if dh > 78.0:
                    scale *= 78.0 / dh
                    dh = 78.0
                dw = fw * scale
                need(dh + 9.0)
                y += 2.0
                x_off = ML + (BW - dw) / 2.0
                page.insert_image(
                    pymupdf.Rect(x_off * K, y * K,
                                 (x_off + dw) * K, (y + dh) * K),
                    stream=png)
                # 细边框（不是灰底 —— 图本身是白纸）
                page.draw_rect(
                    pymupdf.Rect(x_off * K, y * K,
                                 (x_off + dw) * K, (y + dh) * K),
                    color=(0.75, 0.75, 0.75), width=0.3)
                y += dh
                # 图注
                cap_txt = s.get("figure_caption") or ""
                if not cap_txt and fig == "plan":
                    cap_txt = ("The stage as seen from above. The three long "
                               "zig-zag bars are the trusses; the small shapes "
                               "on them are the lights. Full detail is on the "
                               "A1 sheet this is taken from.")
                if cap_txt:
                    y += 3.6
                    for ln in _wrap(cap_txt, BW, 2.3, "italic"):
                        need(4.0)
                        _put(page, ML, y + 2.3, ln, 2.3, "italic", grey=0.4)
                        y += 3.6
                y += 4.0

        if s.get("detail"):
            para(s["detail"], grey=0.28)
            y += 1.0

        # 自动生成的事实块
        if s.get("auto") == "positions":
            y += 3.0
            for it in facts_positions(rig):
                need(16)
                label = f"{it['name']}"
                _put(page, ML + 2.0, y + BODY, label, BODY, "bold")
                _put(page, ML + 2.0 + 34.0, y + BODY,
                     f"{it['count']} lights, hanging {it['height']} mm up, "
                     f"{it['where']}", BODY, "regular", grey=0.2)
                y += LEAD
                gl = ", ".join(it["gels"]) if it["gels"] else "-"
                _put(page, ML + 2.0 + 34.0, y + SUB,
                     f"colour: {gl}", SUB, "regular", grey=0.45)
                y += LEAD + 1.0
            y += 2.0

        if s.get("auto") == "colours":
            y += 3.0
            for it in facts_colours(rig):
                need(15)
                nm = it["name"] or "no colour"
                _put(page, ML + 2.0, y + BODY, it["gel"], BODY, "bold")
                _put(page, ML + 2.0 + 18.0, y + BODY, nm, BODY, "regular")
                _put(page, ML + 2.0 + 18.0 + 46.0, y + BODY,
                     f"{it['count']} lights — {', '.join(it['positions'])}",
                     BODY, "regular", grey=0.35)
                y += LEAD + 0.8
            y += 2.0

        # 条目列表
        for it in s.get("items") or []:
            need(20)
            term = it.get("term", "")
            _put(page, ML + 2.0, y + SUB + 0.4, term, SUB + 0.3, "bold")
            y += SUB + 3.6
            para(it.get("plain", ""), indent=2.0)
            y += 2.2

        y += 5.0

    footer()
    doc.save(out_pdf, deflate=True)
    return doc.page_count


def main():
    ex_p = os.path.join(ROOT, "data", "explain.yaml")
    rig_p = os.path.join(ROOT, "data", "rig.yaml")
    cue_p = os.path.join(ROOT, "data", "cues.yaml")
    for p in (ex_p, rig_p):
        if not os.path.exists(p):
            print(f"  [ERROR] 找不到 {p}")
            return 1
    ex = yaml.safe_load(open(ex_p, encoding="utf-8"))
    rig = yaml.safe_load(open(rig_p, encoding="utf-8"))
    cues = yaml.safe_load(open(cue_p, encoding="utf-8")) if os.path.exists(cue_p) else {}

    errs, warns = check(ex, rig, cues)
    for w in warns:
        print(f"  [WARN] {w}")
    if errs:
        print("\n说明文档校验失败，未出图：")
        for e in errs:
            print(f"  [ERROR] {e}")
        return 1

    out = os.path.join(ROOT, "out", "design_explained.pdf")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    n = build(ex, rig, cues, out)
    print(f"  PDF: {out}  ({n} 页, A4)")
    print(f"  OK: {len(ex['sections'])} 节, {len(warns)} warning(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
