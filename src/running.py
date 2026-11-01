#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""running.py — 生成 Running Script（提示本 / prompt copy）

这是什么
--------
给**舞台监督**用的。剧本正文在左边，cue 号在右边，念到那一句就喊 Go。
和 Cue Sheet 是一对：
  · Cue Sheet  —— 按 cue 号顺序排，给灯光操作员看
  · Running Script —— 按剧本顺序排，给舞台监督看
两份文件的 cue 号必须**一一对应**，任务书抽查的就是这个。

为什么单独一个文件
------------------
Running Script 的排版逻辑和 Cue Sheet 完全不同：
  · 左边是连续正文（不能分栏，要能顺着读）
  · cue 号贴在右侧空白，用引线指向触发的那一行
  · 换页时不能把 cue 和它的台词拆到两页

校验（失败即停）
----------------
1. script.yaml 里的每个 cue 号必须在 cues.yaml 存在
2. cues.yaml 里的每个 cue 必须出现在 script.yaml 里（一个不能漏）
3. cue 顺序必须与 cues.yaml 一致
4. 同一个 cue 不能标两次
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
SHEET_W, SHEET_H = 297.0, 420.0     # A4 portrait —— 提示本要拿在手里
MARGIN_L, MARGIN_R = 16.0, 46.0     # 右侧留宽边放 cue 号
MARGIN_T, MARGIN_B = 16.0, 16.0

_FONTS = {
    "regular": "/System/Library/Fonts/Supplemental/Arial.ttf",
    "bold": "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
}
_cache, _reg = {}, set()


def _font(fam):
    if fam in _cache:
        return _cache[fam]
    path = _FONTS.get(fam) or _FONTS["regular"]
    f = pymupdf.Font(fontfile=path)
    f.buffer
    _cache[fam] = (fam, f)
    return _cache[fam]


def _put(page, x, y, text, cap, fam="regular", grey=0.0):
    name, f = _font(fam)
    key = (id(page), name)
    if key not in _reg:
        page.insert_font(fontname=name, fontbuffer=f.buffer)
        _reg.add(key)
    em = cap / metrics.EM_TO_CAP
    page.insert_text(pymupdf.Point(x * K, y * K), text,
                     fontname=name, fontsize=em * K,
                     color=(grey, grey, grey))


# ============================================================ 校验
def check(cues_doc, script_doc):
    """返回 (errors, warnings)。"""
    errs, warns = [], []
    cue_qs = [str(c["q"]) for c in cues_doc["cues"]]
    cue_set = set(cue_qs)

    beats = script_doc.get("beats") or []
    if not beats:
        errs.append("script.yaml 里没有任何 beat —— 运行脚本是空的")
        return errs, warns

    marked = [str(b["cue"]) for b in beats if b.get("cue") is not None]

    # 1. script 里的 cue 必须存在
    for q in marked:
        if q not in cue_set:
            errs.append(f"running script 标了 Q{q}，但 cues.yaml 里没有这个 cue")

    # 2. 不能重复
    seen = {}
    for i, q in enumerate(marked):
        if q in seen:
            errs.append(f"Q{q} 在 running script 里标了两次（第 {seen[q]+1} 和第 {i+1} 个 beat）")
        seen[q] = i

    # 3. 一个都不能漏
    missing = [q for q in cue_qs if q not in seen]
    if missing:
        errs.append(f"cues.yaml 有 {len(missing)} 个 cue 没在 running script 里标出："
                    f"{', '.join('Q' + q for q in missing[:8])}"
                    + ("..." if len(missing) > 8 else ""))

    # 4. 顺序必须一致
    if not missing and not errs:
        order_in_script = [q for q in marked if q in cue_set]
        if order_in_script != cue_qs:
            for a, b in zip(order_in_script, cue_qs):
                if a != b:
                    errs.append(f"cue 顺序不一致：running script 先出现 Q{a}，"
                                f"cues.yaml 里却是 Q{b} 在前")
                    break

    # 5. 舞台提示类 beat 提醒
    stage_only = [b for b in beats if str(b.get("who", "")).upper() == "STAGE"]
    if stage_only:
        warns.append(f"{len(stage_only)} 个 beat 是舞台提示而非台词，"
                     f"舞台监督无法靠台词叫 cue —— 请确认这些点有明确的视觉信号")

    if not (script_doc.get("meta") or {}).get("edition"):
        warns.append("script.yaml 的 meta.edition 为空 —— 提示本上没印剧本版本，"
                     "排演时无法确认用的是哪一本")

    return errs, warns


# ============================================================ 排版
def _wrap(text, width_mm, cap, fam="regular"):
    text = " ".join(str(text or "").split())
    if not text:
        return []
    lines, cur = [], ""
    for ch in text:
        trial = cur + ch
        if metrics.width_mm(trial, cap, fam) > width_mm and cur:
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


BODY_CAP = 3.1          # 正文 cap 高（mm）
LEAD = 5.0              # 行距
SPEAKER_CAP = 2.9
CUE_CAP = 3.4
ACT_CAP = 3.8


def build(cues_doc, script_doc, out_pdf):
    prefix = (cues_doc.get("meta") or {}).get("prefix", "LX")
    cue_by_q = {str(c["q"]): c for c in cues_doc["cues"]}
    beats = script_doc["beats"]
    meta = script_doc.get("meta") or {}

    body_w = SHEET_W - MARGIN_L - MARGIN_R

    doc = pymupdf.open()
    page = None
    y = 0.0
    page_no = 0

    def footer():
        _put(page, MARGIN_L, SHEET_H - MARGIN_B + 3.0,
             f"RUNNING SCRIPT — {meta.get('designer', '')} — page {page_no}",
             2.0, "regular", grey=0.4)

    def new_page(first=False):
        nonlocal page, y, page_no
        if page is not None:
            footer()
        page = doc.new_page(width=SHEET_W * K, height=SHEET_H * K)
        page_no += 1
        y = MARGIN_T
        if first:
            _put(page, MARGIN_L, y + 7.0, "RUNNING SCRIPT", 6.6, "bold")
            y += 11.0
            sub = meta.get("edition") or "SCRIPT EDITION NOT SET"
            _put(page, MARGIN_L, y + 3.0, sub, 2.4, "regular", grey=0.35)
            y += 7.0
            _put(page, MARGIN_L, y + 3.0,
                 f"Cue numbering: {(cues_doc.get('meta') or {}).get('numbering', '')}",
                 2.4, "regular", grey=0.35)
            y += 8.0
            # 页眉分隔线
            page.draw_line(pymupdf.Point(MARGIN_L * K, y * K),
                           pymupdf.Point((SHEET_W - MARGIN_R) * K, y * K),
                           color=(0, 0, 0), width=0.6)
            # 右侧 cue 栏标题
            _put(page, SHEET_W - MARGIN_R + 4.0, y - 1.6, "CUE", 2.4, "bold")
            y += 6.0
        else:
            _put(page, MARGIN_L, y + 4.0, "RUNNING SCRIPT (continued)", 2.6,
                 "bold", grey=0.45)
            y += 9.0

    new_page(first=True)
    prev_act = None

    for b in beats:
        act = b.get("act", "")
        q = str(b["cue"]) if b.get("cue") is not None else None

        # 幕/场切换：留白 + 小标题
        if act and act != prev_act:
            if y > MARGIN_T + 20:
                y += 3.0
            if y + 14 > SHEET_H - MARGIN_B:
                new_page()
            _put(page, MARGIN_L, y + ACT_CAP, act, ACT_CAP, "bold", grey=0.0)
            y += ACT_CAP + 3.2
            page.draw_line(pymupdf.Point(MARGIN_L * K, y * K),
                           pymupdf.Point((SHEET_W - MARGIN_R) * K, y * K),
                           color=(0.7, 0.7, 0.7), width=0.25)
            y += 3.6
            prev_act = act

        who = str(b.get("who", "")).strip()
        line = b.get("line", "")
        after = b.get("cue_after", True)

        # 折行
        ind = 12.0 if who and who.upper() != "STAGE" else 0.0
        body_lines = _wrap(line, body_w - ind, BODY_CAP)
        who_lines = _wrap(who.upper(), body_w - 4, SPEAKER_CAP, "bold") if who else []

        need = (len(who_lines) * (SPEAKER_CAP + 2.0)
                + len(body_lines) * LEAD
                + (7.0 if q else 0.0))
        if y + need > SHEET_H - MARGIN_B:
            new_page()

        # 说话人
        for wl in who_lines:
            _put(page, MARGIN_L, y + SPEAKER_CAP, wl, SPEAKER_CAP, "bold")
            y += SPEAKER_CAP + 2.0

        # cue 号：画在**触发那一行之前或之后**，右侧栏 + 引线
        if q and not after:
            _cue_mark(page, q, cue_by_q, prefix, y, lead_in=True)
        body_top = y
        for bl in body_lines:
            _put(page, MARGIN_L + ind, y + BODY_CAP, bl, BODY_CAP)
            y += LEAD
        if q and after:
            _cue_mark(page, q, cue_by_q, prefix, y, lead_in=False,
                      ref_y=body_top + LEAD * max(0, len(body_lines) - 1))

        y += 1.8

    footer()
    doc.save(out_pdf, deflate=True)
    return doc.page_count


def _cue_mark(page, q, cue_by_q, prefix, y, lead_in, ref_y=None):
    """在右侧栏画 cue 号 + 引线。lead_in=True 表示这句**之前**走 cue。"""
    label = f"{prefix} Q{q}"
    x_right = SHEET_W - MARGIN_R + 4.0
    yy = y + 1.4
    _put(page, x_right, yy + CUE_CAP, label, CUE_CAP, "bold")

    c = cue_by_q.get(q) or {}
    fade = str(c.get("fade", "") or "").strip()
    if fade:
        _put(page, x_right, yy + CUE_CAP + 3.4, fade, 1.9, "regular", grey=0.4)

    # 引线：从 cue 号左侧指向触发行
    ry = ref_y if ref_y is not None else yy
    if lead_in:
        # 之前：短横线在文字上方
        page.draw_line(pymupdf.Point((SHEET_W - MARGIN_R - 6.0) * K, ry * K),
                       pymupdf.Point(x_right * K, ry * K),
                       color=(0.35, 0.35, 0.35), width=0.3)
        page.draw_line(pymupdf.Point(x_right * K, ry * K),
                       pymupdf.Point(x_right * K, (yy + CUE_CAP * 0.45) * K),
                       color=(0.35, 0.35, 0.35), width=0.3)
    else:
        page.draw_line(pymupdf.Point((SHEET_W - MARGIN_R - 6.0) * K, (ry + BODY_CAP * 0.35) * K),
                       pymupdf.Point((SHEET_W - MARGIN_R + 1.0) * K, (ry + BODY_CAP * 0.35) * K),
                       color=(0.35, 0.35, 0.35), width=0.3)


def main():
    cues_p = os.path.join(ROOT, "data", "cues.yaml")
    script_p = os.path.join(ROOT, "data", "script.yaml")
    for p in (cues_p, script_p):
        if not os.path.exists(p):
            print(f"  [错误] 找不到 {p}")
            return 1
    cues_doc = yaml.safe_load(open(cues_p, encoding="utf-8"))
    script_doc = yaml.safe_load(open(script_p, encoding="utf-8"))

    errs, warns = check(cues_doc, script_doc)
    for w in warns:
        print(f"  [WARN] {w}")
    if errs:
        print("\nRunning script 校验失败，未出图：")
        for e in errs:
            print(f"  [ERROR] {e}")
        return 1

    out = os.path.join(ROOT, "out", "running_script.pdf")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    n = build(cues_doc, script_doc, out)
    print(f"  PDF: {out}  ({n} 页, A4)")
    print(f"  OK: {len(script_doc['beats'])} beats / "
          f"{len(cues_doc['cues'])} cues, {len(warns)} warning(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
