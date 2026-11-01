#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""extract_ref.py — 从 NIDA 参考图 PDF 里**扒**出构件几何，写成 data/ref_symbols.json

为什么这么做
------------
参考图是 Vectorworks 画的。与其我照猫画虎重新编一个桁架，不如直接从 PDF 的
矢量路径里把「一个桁架单元」和「一个灯具符号」原样量出来，存成归一化坐标，
运行时按需要缩放。这样画出来的东西和参考图**同源**，不是仿的。

输出（全部是相对量，不含绝对坐标）：
    truss.cell   : 单元宽高、弦杆/竖杆尺寸、两条斜撑的四点多边形（归一化）
    fixture      : 灯具符号（灯体路径 + 挂架 + 圆圈 + 色片遮罩）归一化
    pipe         : LX / SOUND 空心管的宽与内线位置

用法：
    .venv/bin/python tools/extract_ref.py            # 重新生成 json
"""
import json
import os
import statistics

import pymupdf

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PDF = os.path.join(ROOT, "brief/reference/XMACH_LXTrussPlan_JC_180620_Version5.pdf")
OUT = os.path.join(ROOT, "data/ref_symbols.json")

PT = 72.0 / 25.4          # 1 mm = 2.8346 pt


def mm(v):
    return v / PT


def bbox_mm(r):
    return (mm(r.x0), mm(r.y0), mm(r.x1), mm(r.y1))


def extract_truss(drawings):
    # 1) 竖杆：细高矩形，高 33~35pt，宽 2.2~3.2pt
    posts = []
    for d in drawings:
        for it in d["items"]:
            if it[0] != "re":
                continue
            r = it[1]
            if 32 < r.height < 36 and 2.2 < r.width < 3.2:
                posts.append((r.x0, r.y0, r.width, r.height))
    if not posts:
        raise SystemExit("找不到竖杆")
    # 取第一段桁架（y0 相同的一组）
    y0 = min(p[1] for p in posts)
    band = sorted([p for p in posts if abs(p[1] - y0) < 0.5], key=lambda p: p[0])
    ytop = band[0][1]
    H = band[0][3]
    xs = [p[0] for p in band]
    pitch = statistics.median([b - a for a, b in zip(xs, xs[1:])])
    post_w = statistics.median([p[2] for p in band])

    # 2) 弦杆：长矩形，高 = 5.76pt
    chords = []
    for d in drawings:
        for it in d["items"]:
            if it[0] != "re":
                continue
            r = it[1]
            if r.width > 100 and 5.0 < r.height < 6.5 and abs(r.y0 - ytop) < 0.5:
                chords.append(r)
    chord_h = statistics.median([c.height for c in chords]) if chords else 5.76

    # 3) 斜撑：四边形，高 25~32pt，宽 12~20pt，落在第一段桁架范围内
    legs = []
    x_end = xs[0] + pitch * 6
    for d in drawings:
        for it in d["items"]:
            if it[0] != "qu":
                continue
            pts = it[1]
            ys = [p.y for p in pts]
            xs_ = [p.x for p in pts]
            if not (ytop - 2 < min(ys) and max(ys) < ytop + H + 2):
                continue
            if not (24 < max(ys) - min(ys) < 33):
                continue
            if not (11 < max(xs_) - min(xs_) < 21):
                continue
            if not (xs[0] - 2 < min(xs_) and max(xs_) < x_end):
                continue
            legs.append(pts)
    # 只保留第一个单元的两条
    cell0 = xs[0]
    in_cell = []
    for lg in legs:
        cx = sum(p[0] for p in lg) / len(lg)
        if cell0 - 1 < cx < cell0 + pitch + 1:
            in_cell.append(lg)
    # 用**描边路径**的顺序（qu 里的点是无序的，直接连会变蝴蝶结）
    ordered = []
    for pts in in_cell:
        cx = sum(p.x for p in pts) / len(pts)
        # 在 drawings 里找同位置的 l 路径
        best = None
        for d in drawings:
            if len(d["items"]) < 4 or d["items"][0][0] != "l":
                continue
            first = d["items"][0][1]
            if abs(mm(first.x) - mm(pts[0].x)) < 0.05 and abs(mm(first.y) - mm(pts[0].y)) < 0.05:
                cand = [it[1] for it in d["items"] if it[0] == "l"]
                if len(cand) == 4:
                    best = cand
                    break
        ordered.append(best if best else pts)
    in_cell = ordered
    in_cell.sort(key=lambda lg: sum(p.x for p in lg) / len(lg))
    if len(in_cell) < 2:
        raise SystemExit(f"第一个单元只找到 {len(in_cell)} 条斜撑")
    left, right = in_cell[0], in_cell[1]

    def norm(pts):
        return [[round((p.x - cell0) / pitch, 5), round((p.y - ytop) / H, 5)]
                for p in pts]

    return {
        "pitch_mm": round(mm(pitch), 4),
        "height_mm": round(mm(H), 4),
        "post_w_mm": round(mm(post_w), 4),
        "chord_h_mm": round(mm(chord_h), 4),
        "leg_left": norm(left),
        "leg_right": norm(right),
        "draw_order": ["post", "leg_left", "leg_right", "chord_bottom", "chord_top"],
    }


def extract_fixture(drawings):
    # 灯体：11.18 x 8.00 mm，0.72pt 描边，10 个 item
    body = None
    for d in drawings:
        r = d["rect"]
        if (abs(mm(r.width) - 11.176) < 0.06
                and abs(mm(r.height) - 8.001) < 0.06
                and len(d["items"]) >= 8):
            body = d
            break
    if body is None:
        raise SystemExit("找不到灯具符号")
    bx0, by0, bx1, by1 = bbox_mm(body["rect"])
    bw, bh = bx1 - bx0, by1 - by0

    path = []
    for it in body["items"]:
        k = it[0]
        if k == "l":
            path.append(["L",
                         round((mm(it[1].x) - bx0) / bw, 5),
                         round((mm(it[1].y) - by0) / bh, 5),
                         round((mm(it[2].x) - bx0) / bw, 5),
                         round((mm(it[2].y) - by0) / bh, 5)])
        elif k == "c":
            path.append(["C",
                         round((mm(it[1].x) - bx0) / bw, 5),
                         round((mm(it[1].y) - by0) / bh, 5),
                         round((mm(it[2].x) - bx0) / bw, 5),
                         round((mm(it[2].y) - by0) / bh, 5),
                         round((mm(it[3].x) - bx0) / bw, 5),
                         round((mm(it[3].y) - by0) / bh, 5),
                         round((mm(it[4].x) - bx0) / bw, 5),
                         round((mm(it[4].y) - by0) / bh, 5)])
        else:
            path.append([k])

    # 挂架：水平细条（1.016 高），与灯体 y 中心同一水平带
    yoke = None
    for d in drawings:
        for it in d["items"]:
            if it[0] != "re":
                continue
            r = it[1]
            b = bbox_mm(r)
            if (abs(b[3] - b[1] - 1.016) < 0.06
                    and 11.0 < b[2] - b[0] < 13.0
                    and abs((b[1] + b[3]) / 2 - (by0 + bh * 0.4275)) < 1.2
                    and b[0] < bx0 + 1 and b[2] > bx0 + bw - 6):
                yoke = b
                break
        if yoke:
            break

    # 圆圈（通道号）：直径 6.096，紧靠灯体左侧
    circ = None
    for d in drawings:
        r = d["rect"]
        b = bbox_mm(r)
        if (abs(b[2] - b[0] - 6.096) < 0.06
                and abs(b[3] - b[1] - 6.096) < 0.06
                and -12 < b[0] - bx0 < -1
                and abs((b[1] + b[3]) / 2 - (by0 + bh / 2)) < 2.0):
            circ = b
            break

    out = {
        "body_w_mm": round(bw, 4),
        "body_h_mm": round(bh, 4),
        "body_path": path,
        "stroke_pt": round(body.get("width") or 0.72, 3),
    }
    if yoke:
        out["yoke_mm"] = [round(v - bx0, 4) if i % 2 == 0 else round(v - by0, 4)
                          for i, v in enumerate(yoke)]
    if circ:
        out["circle_mm"] = [round(v - bx0, 4) if i % 2 == 0 else round(v - by0, 4)
                            for i, v in enumerate(circ)]
    return out


def extract_pipe(drawings):
    # LX / SOUND 空心管：细长矩形，宽 ~1.95mm
    best = None
    for d in drawings:
        for it in d["items"]:
            if it[0] != "re":
                continue
            r = it[1]
            w, h = mm(r.width), mm(r.height)
            if (1.7 < w < 2.2 and h > 40) or (1.7 < h < 2.2 and w > 40):
                best = (w, h)
                break
        if best:
            break
    if not best:
        return {}
    return {"width_mm": round(min(best), 4)}


def main():
    doc = pymupdf.open(PDF)
    drawings = doc[0].get_drawings()
    data = {
        "_source": os.path.relpath(PDF, ROOT),
        "truss": extract_truss(drawings),
        "fixture": extract_fixture(drawings),
        "pipe": extract_pipe(drawings),
    }
    with open(OUT, "w") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
    print(json.dumps(data, indent=2, ensure_ascii=False))
    print("\n->", OUT)


if __name__ == "__main__":
    main()
