#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rationale.py — 生成并**强制校验** 300 词 rationale

为什么必须校验
--------------
NESA 原文：「material that exceeds the stipulated word lengths or other
requirements will be disregarded」—— 超出的部分**直接忽略**。
不是扣分，是白写。

而 300 词是个很窄的窗口。写顺了很容易到 340。
所以这里把词数当成硬门禁：超一个词就失败，不出图。

词数怎么数
----------
按 NESA 惯例：以空格分隔的词计 1 个。
连字符词（"over-warm"）算 1 个；数字算 1 个；标点不计。
这个数法比 Word 略严格，宁可少写。

输出
----
    out/rationale.txt   —— 纯文本，方便贴进 folio
    out/rationale.pdf   —— A4 一页，双倍行距（HSC 格式要求）
"""
import os
import re
import sys

import pymupdf
import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import metrics  # noqa: E402

K = 72.0 / 25.4
W, H = 210.0, 297.0
ML, MR, MT = 25.0, 25.0, 25.0

_F = {
    "regular": "/System/Library/Fonts/Supplemental/Arial.ttf",
    "bold": "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
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


# ============================================================ 词数
def count_words(text):
    """NESA 惯例：空格分隔的 token，去掉纯标点。"""
    toks = re.split(r"\s+", str(text or "").strip())
    return len([t for t in toks if re.search(r"[A-Za-z0-9]", t)])


# 不该出现在 rationale 里的技术词 —— rationale 讲愿景，不讲设备
BANNED = ["dmx", "luminaire", "gobo", "hard patch", "dimmer",
          "channel number", "amperage", "wattage"]


def check(doc):
    errs, warns = [], []
    parts = doc.get("parts") or []
    if not parts:
        errs.append("rationale.yaml 里没有 parts")
        return errs, warns, 0

    meta = doc.get("meta") or {}
    hard_max = int(meta.get("hard_max", 300))

    # 四段式完整性（DoE 官方模板）
    need = {"intent", "moments", "elements", "audience"}
    got = {p.get("id") for p in parts}
    missing = need - got
    if missing:
        errs.append(f"rationale 缺段落：{', '.join(sorted(missing))}"
                    f"（DoE 四段式：intent / moments / elements / audience）")

    # 词数
    full = " ".join(str(p.get("text", "")) for p in parts)
    n = count_words(full)
    if n > hard_max:
        errs.append(f"rationale 有 {n} 词，超过上限 {hard_max} —— "
                    f"NESA 会把超出部分直接忽略，必须删到 {hard_max} 以内")
    elif n < int(hard_max * 0.85):
        warns.append(f"rationale 只有 {n} 词，离 {hard_max} 还差 {hard_max - n} 词 —— "
                     f"没写满等于放弃了论证空间")

    # 技术词
    low = full.lower()
    for b in BANNED:
        if b in low:
            errs.append(f"rationale 出现技术词 {b!r} —— "
                        f"这是导演概念，不是设备清单")

    # 段落别写成条目
    for p in parts:
        t = str(p.get("text", ""))
        if t.count("\n-") or t.strip().startswith("-"):
            warns.append(f"段落 {p.get('id')} 看起来是 bullet list —— "
                         f"rationale 应当是连贯散文")

    return errs, warns, n


# ============================================================ 输出
def write_txt(doc, out_txt):
    parts = doc["parts"]
    body = " ".join(" ".join(str(p.get("text", "")).split()) for p in parts)
    body = re.sub(r"\s+([.,;:])", r"\1", body)
    with open(out_txt, "w", encoding="utf-8") as f:
        f.write(body.strip() + "\n")
    return body


def write_pdf(doc, out_pdf, n_words):
    """A4 一页。HSC 格式：双倍行距、12pt 等效字。"""
    meta = doc.get("meta") or {}
    page = pymupdf.open().new_page(width=W * K, height=H * K)

    CAP = 3.6            # ≈12pt 的 cap 高
    LEAD = CAP * 2.0     # 双倍行距
    BW = W - ML - MR

    y = MT
    _put(page, ML, y + 5.0, "RATIONALE", 5.0, "bold")
    y += 8.5
    _put(page, ML, y + 3.0,
         f"{meta.get('play', '')} — {meta.get('playwright', '')}   |   "
         f"{meta.get('form', '')}", 2.6, "regular", grey=0.35)
    y += 5.0
    _put(page, ML, y + 3.0, f"{n_words} words", 2.6, "regular", grey=0.35)
    y += 8.0
    page.draw_line(pymupdf.Point(ML * K, y * K),
                   pymupdf.Point((W - MR) * K, y * K),
                   color=(0, 0, 0), width=0.7)
    y += LEAD

    for p in doc["parts"]:
        txt = " ".join(str(p.get("text", "")).split())
        for ln in _wrap(txt, BW, CAP):
            if y + LEAD > H - MT:
                break
            _put(page, ML, y + CAP, ln, CAP)
            y += LEAD
        y += LEAD * 0.5      # 段间半行

    page.insert_text(pymupdf.Point(ML * K, (H - MT + 8.0) * K),
                     "Rationale — submitted with the lighting design folio",
                     fontname="helv", fontsize=2.2 * K,
                     color=(0.45, 0.45, 0.45))
    page.parent.save(out_pdf, deflate=True)
    return 1


def main():
    p = os.path.join(ROOT, "data", "rationale.yaml")
    if not os.path.exists(p):
        print(f"  [ERROR] 找不到 {p}")
        return 1
    doc = yaml.safe_load(open(p, encoding="utf-8"))

    errs, warns, n = check(doc)
    for w in warns:
        print(f"  [WARN] {w}")
    if errs:
        print("\nRationale 校验失败，未出稿：")
        for e in errs:
            print(f"  [ERROR] {e}")
        return 1

    os.makedirs(os.path.join(ROOT, "out"), exist_ok=True)
    t = os.path.join(ROOT, "out", "rationale.txt")
    pdf = os.path.join(ROOT, "out", "rationale.pdf")
    write_txt(doc, t)
    write_pdf(doc, pdf, n)
    print(f"  TXT: {t}")
    print(f"  PDF: {pdf}")
    print(f"  OK: rationale {n} 词（上限 300）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
