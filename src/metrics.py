#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""metrics.py — 文字宽度的**真实**度量（单一定义来源）

为什么需要它
------------
排版避让、白底遮罩、图签自动缩字号，全都需要知道「这行字有多宽」。
以前用的是估算：`h * 0.58 * 1.72`（保守系数硬凑），因为当时中英混排、
字体是 PingFang，宽度根本没法算准。后果是**每张表都要单独调数字**，
调完换个字体又挤 —— 这就是反复打地鼠的根源。

现在中文已全部移除，只剩拉丁字符，字体固定为 Arial / Arial Narrow，
于是可以直接问字体文件本身要宽度（advance width），误差 < 1%。

单位约定
--------
本项目里 `height` 是 **DXF 的 TEXT height = cap height（mm）**。
字体的 advance width 是按 **em** 给的，所以：

    width_mm = text_length(s, em_pt) / K    其中 em_pt = cap_mm / EM_TO_CAP * K
             = text_length(s, 1.0) * cap_mm / EM_TO_CAP

实测：Arial cap/em = 0.7163（1467/2048）。
"""
import os

import pymupdf

K = 72.0 / 25.4
EM_TO_CAP = 0.7163

_PATHS = {
    "regular": ["/System/Library/Fonts/Supplemental/Arial.ttf",
                "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
                "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"],
    "bold": ["/System/Library/Fonts/Supplemental/Arial Bold.ttf",
             "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"],
    "narrow": ["/System/Library/Fonts/Supplemental/Arial Narrow.ttf",
               "/Library/Fonts/Arial Narrow.ttf"],
    "narrowbold": ["/System/Library/Fonts/Supplemental/Arial Narrow Bold.ttf"],
}

_cache = {}


def _font(family):
    if family in _cache:
        return _cache[family]
    for p in _PATHS.get(family, []):
        if os.path.exists(p):
            _cache[family] = pymupdf.Font(fontfile=p)
            return _cache[family]
    # 兜底：regular
    for p in _PATHS["regular"]:
        if os.path.exists(p):
            _cache[family] = pymupdf.Font(fontfile=p)
            return _cache[family]
    raise SystemExit("metrics: 找不到 Arial 字体")


def width_mm(s, cap_mm, family="regular"):
    """文字宽度（mm）。cap_mm = DXF TEXT height。"""
    s = str(s)
    if not s:
        return 0.0
    f = _font(family)
    em = cap_mm / EM_TO_CAP
    return f.text_length(s, em * K) / K


def em_for_cap(cap_mm):
    """DXF cap height -> PDF em size（同单位）。"""
    return cap_mm / EM_TO_CAP


def cap_for_em(em_mm):
    return em_mm * EM_TO_CAP


def fit_cap(s, cap_mm, max_w_mm, family="regular", min_cap=1.6):
    """把 cap 缩到能塞进 max_w_mm，返回新的 cap（不小于 min_cap）。"""
    w = width_mm(s, cap_mm, family)
    if w <= max_w_mm or w <= 0:
        return cap_mm
    return max(min_cap, cap_mm * max_w_mm / w * 0.98)


def text_bbox(s, x, y, cap_mm, family="regular", align="center",
              rot=0.0, pad=0.0):
    """返回 (x0, y0, x1, y1)，单位 mm，y 向上。

    align: center / left / right（水平）；垂直按 cap 上下居中
    （与 Pen.text 的 MIDDLE_* 对齐方式一致）。
    """
    w = width_mm(s, cap_mm, family) + 2 * pad
    h = cap_mm + 2 * pad
    if align == "left":
        x0 = x
    elif align == "right":
        x0 = x - w
    else:
        x0 = x - w / 2.0
    y0 = y - h / 2.0
    if abs(rot % 180) > 45:
        # 旋转 90°：宽高互换，以原点为中心
        return (x - h / 2.0, y - w / 2.0, x + h / 2.0, y + w / 2.0)
    return (x0, y0, x0 + w, y0 + h)
