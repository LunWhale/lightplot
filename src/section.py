#!/usr/bin/env python3
"""灯光剖面图 / Lighting Section —— 读取 rig.yaml，输出 A3 剖面图纸。
用法: python3 section.py rig.yaml
"""
import os, math, yaml
import qc
import ezdxf
from ezdxf.enums import TextEntityAlignment

# 剖面图的 PDF/PNG 已改走 pdfout（PyMuPDF 原生矢量），不再需要 matplotlib。
# 这里不再 import matplotlib / RenderContext / Frontend / MatplotlibBackend，
# 也不再调 fonts.mpl_setup() —— 那是给 matplotlib 预览配中文字体用的，已无用。
import fonts

FONT = "Arial.ttf"   # 图上全英文，用 Arial
SCALE = 50.0            # 1:50
SHEET_W, SHEET_H = 420.0, 297.0   # A3

X0, Y0 = 24.0, 62.0     # 剖面原点 = 台面 ±0 的图纸坐标
Y_OFF = 4200.0          # rig y 平移：覆盖 观众席(-4000) 到 后墙(+9000)

def s(y_rig, h):
    """rig 坐标 (纵深, 高度) -> 图纸坐标"""
    return (X0 + (y_rig + Y_OFF) / SCALE, Y0 + h / SCALE)


def build(doc):
    # setup=False 时只有 Continuous，虚线要自己建
    for nm, pat in (("DASHED", [3.0, -1.5]),
                    ("DASHDOT", [4.0, -1.2, 0.0, -1.2]),
                    ("CENTER", [6.0, -1.5, 1.5, -1.5])):
        if nm not in doc.linetypes:
            doc.linetypes.add(nm, pattern=pat, description=nm)

    def L(name, color, lt="Continuous", lw=18):
        lay = doc.layers.add(name=name, color=color, linetype=lt, lineweight=lw)
        if color == 7:      # ACI 7 随背景翻转 -> 钉真彩白
            lay.dxf.true_color = 0xFFFFFF
    for a in [("BORDER",250,"Continuous",35),("GRID",8,"Continuous",9),
              ("GRIDTEXT",250,"Continuous",13),("STAGE",250,"Continuous",50),
              ("SET",250,"Continuous",25),("TRUSS",250,"Continuous",18),
              ("FIXTURE",250,"Continuous",20),("FIXTURE_TXT",250,"Continuous",13),
              ("BEAM",8,"DASHED",9),("DIM",1,"Continuous",13),
              ("SEAT",8,"Continuous",9),("TITLEBLK",250,"Continuous",35),
              ("TB_TEXT",250,"Continuous",13),("NOTES",250,"Continuous",13),
              ("HUMAN",5,"Continuous",18),("ACCENT",1,"Continuous",25)]:
        L(*a)
    doc.styles.add("LBL", font=FONT)
    doc.styles.add("TTL", font=FONT)
    return doc


def draw_border(msp):
    """图框与分区带。与平面图同一套尺寸（见 src/paper.py FRAME_MARGIN/FRAME_INNER）。

    外框贴纸边 (0,0)，内框 20mm，分区带 20mm 宽，刻度 5mm 向外。
    早先是外框 10 / 内框 16，与平面图不一致，而且 check_scale 会判错。
    """
    msp.add_lwpolyline([(0,0),(SHEET_W,0),(SHEET_W,SHEET_H),(0,SHEET_H)],
                       close=True, dxfattribs={"layer":"BORDER"})
    msp.add_lwpolyline([(20,20),(SHEET_W-20,20),(SHEET_W-20,SHEET_H-20),(20,SHEET_H-20)],
                       close=True, dxfattribs={"layer":"BORDER"})
    TICK = 5.0
    TX, TY = 13.55, 15.05
    for i,ch in enumerate("ABCDEFGH"):
        yy = 20 + (SHEET_H-40)*(i+0.5)/8
        msp.add_text(ch, height=4.55, dxfattribs={"layer":"GRIDTEXT","style":"LBL"}) \
           .set_placement((TX, yy), align=TextEntityAlignment.MIDDLE_CENTER)
        msp.add_text(ch, height=4.55, dxfattribs={"layer":"GRIDTEXT","style":"LBL"}) \
           .set_placement((SHEET_W-TX, yy), align=TextEntityAlignment.MIDDLE_CENTER)
    for i in range(1,9):
        xx = 20 + (SHEET_W-40)*(i-0.5)/8
        msp.add_text(str(i), height=4.55, dxfattribs={"layer":"GRIDTEXT","style":"LBL"}) \
           .set_placement((xx, TX), align=TextEntityAlignment.MIDDLE_CENTER)
        msp.add_text(str(i), height=4.55, dxfattribs={"layer":"GRIDTEXT","style":"LBL"}) \
           .set_placement((xx, SHEET_H-TX), align=TextEntityAlignment.MIDDLE_CENTER)
        msp.add_line((xx,20),(xx,20-TICK), dxfattribs={"layer":"GRID"})
        msp.add_line((xx,SHEET_H-20),(xx,SHEET_H-20+TICK), dxfattribs={"layer":"GRID"})


def human(msp, y_rig, h_base=0.0, height=1750.0):
    """1.75m 人形比例参照（USITT 要求剖面必须有人形）"""
    x, y = s(y_rig, h_base)
    k = height / SCALE
    hd = 0.13 * k
    msp.add_circle((x, y + k - hd), hd, dxfattribs={"layer":"HUMAN"})
    msp.add_lwpolyline([(x, y), (x, y + k - hd*2)], dxfattribs={"layer":"HUMAN"})
    msp.add_lwpolyline([(x - 0.16*k, y + 0.62*k), (x, y + 0.74*k), (x + 0.16*k, y + 0.62*k)],
                       dxfattribs={"layer":"HUMAN"})
    msp.add_lwpolyline([(x, y + 0.05*k), (x - 0.09*k, y)], dxfattribs={"layer":"HUMAN"})
    msp.add_lwpolyline([(x, y + 0.05*k), (x + 0.09*k, y)], dxfattribs={"layer":"HUMAN"})
    msp.add_text("1.75m", height=2.2, dxfattribs={"layer":"HUMAN","style":"LBL"}) \
       .set_placement((x + 0.1*k, y + k + 1.0), align=TextEntityAlignment.LEFT)


def draw_venue(msp, d):
    """场地剖面：台面、台口、马道、观众席起坡、后墙。

    旧版只有台面 + 后墙 + 假台阶，USITT RP-2 §3 要求的
    台口(plaster line)、建筑细节、视线点全缺。这里补齐。
    """
    ven = d["stage"]
    sd = ven["depth"]
    bh = ven.get("grid_height", 7500)        # 栅顶高度
    pros_h = ven.get("proscenium_height", 6000)
    pros_x = ven.get("proscenium_x", -700)   # 台口位置（纵深，负=台唇外）
    rake = ven.get("audience_rake", 150)     # 每排升起
    rows = ven.get("audience_rows", 8)
    row_d = ven.get("audience_row_depth", 520)

    def poly(pts, layer="STAGE", close=False):
        msp.add_lwpolyline([s(y, h) for y, h in pts], close=close,
                           dxfattribs={"layer": layer})

    # ---- 台面
    poly([(0, 0), (sd, 0)], "STAGE")
    # ---- 台唇（apron）+ 台口台阶
    poly([(0, 0), (pros_x, 0), (pros_x, -180), (-600, -180), (-600, -900)], "STAGE")

    # ---- 后墙 + 栅顶
    poly([(sd, 0), (sd, bh)], "STAGE")
    poly([(pros_x - 900, bh), (sd, bh)], "STAGE")

    # ---- 台口（proscenium）：两侧塔 + 上方门头
    poly([(pros_x, 0), (pros_x, pros_h)], "STAGE")
    poly([(pros_x, pros_h), (pros_x - 350, pros_h)], "STAGE")
    poly([(pros_x - 350, pros_h), (pros_x - 350, bh)], "STAGE")
    t = msp.add_text("PROSCENIUM", height=2.0,
                     dxfattribs={"layer": "DIM", "style": "LBL"})
    t.set_placement(s(pros_x - 160, pros_h + 250), align=TextEntityAlignment.CENTER)
    t.dxf.rotation = 90

    # ---- 马道（catwalk）：沿后墙与中部
    for cy, tag in ((sd * 0.45, "CATWALK 1"), (sd * 0.82, "CATWALK 2")):
        poly([(cy, 4200), (cy + 1200, 4200)], "STAGE")
        poly([(cy, 4200), (cy, 5000)], "STAGE")
        poly([(cy + 1200, 4200), (cy + 1200, 5000)], "STAGE")
        msp.add_text(tag, height=1.6, dxfattribs={"layer": "DIM", "style": "LBL"}) \
           .set_placement(s(cy + 600, 5250), align=TextEntityAlignment.CENTER)

    # ---- 观众席起坡（真实坡度，不是画几根线）
    # 只画落在图框内的排数：超出纸面的排不画，否则线条会冲出图框
    seat_y0 = pros_x - 300
    LEFT_LIMIT = 18.0
    drawn = 0
    for i in range(rows):
        yy = seat_y0 - i * row_d
        if s(yy - row_d, 0)[0] < LEFT_LIMIT:
            break
        hh = -700 + i * rake
        poly([(yy, hh), (yy - row_d, hh)], "SEAT")
        poly([(yy - row_d, hh), (yy - row_d, hh + rake)], "SEAT")
        # 座位小方块
        poly([(yy - 60, hh), (yy - 460, hh), (yy - 460, hh + 90), (yy - 60, hh + 90)],
             "SEAT", close=True)
        drawn += 1

    # ---- 高度标尺
    for h in range(0, int(bh) + 1, 1000):
        xx, yy = s(pros_x - 1500, h)
        msp.add_lwpolyline([(xx, yy), (xx + 2.4, yy)], dxfattribs={"layer": "DIM"})
        msp.add_text(f"+{h}", height=1.9, dxfattribs={"layer": "DIM", "style": "LBL"}) \
           .set_placement((xx - 0.8, yy - 0.7), align=TextEntityAlignment.RIGHT)
    xx, _ = s(pros_x - 1500, 0)
    msp.add_lwpolyline([(xx, Y0), (xx, s(0, bh)[1])], dxfattribs={"layer": "DIM"})

    # ---- 文字标注
    def lab(txt, y, h, ht=2.4, layer="DIM", rot=0):
        e = msp.add_text(txt, height=ht, dxfattribs={"layer": layer, "style": "LBL"})
        e.set_placement(s(y, h), align=TextEntityAlignment.CENTER)
        if rot:
            e.dxf.rotation = rot
        return e

    lab("STAGE FLOOR  +/-0  (VERTICAL ZERO)", sd * 0.55, -420, 2.6)
    lab("BACK WALL", sd - 260, bh * 0.60, 2.2, rot=90)
    lab("GRID", sd * 0.55, bh + 220, 2.2)
    lab("AUDIENCE", seat_y0 - drawn * row_d * 0.5, -560, 2.6, layer="SEAT")
    lab("UPSTAGE", sd - 900, bh + 700, 2.6)
    lab("DOWNSTAGE", pros_x + 600, bh + 700, 2.6)


def draw_set_section(msp, d):
    """布景剖面。

    旧版剖面图里完全没有布景，导致「光打在什么上」无从判断。
    这里把平面图里的 set 元素按 A-A 切线投影成剖面：
      · 横跨切线的 rect → 画出其高度（用 height 字段，缺省 900）
      · line → 画成竖向线（墙/隔断）
    """
    cut_y = d["stage"]["depth"] * 0.5
    for st in d.get("set", []):
        if st["kind"] == "rect":
            y0, y1 = st["y0"], st["y1"]
            if not (y0 <= cut_y <= y1):
                continue
            hgt = st.get("height", 900)
            xa, xb = st["x0"], st["x1"]
            msp.add_lwpolyline(
                [s(cut_y, 0), s(cut_y, hgt), s(cut_y, hgt)],
                dxfattribs={"layer": "SET"})
            # 用一条水平线表示该布景在剖面上的高度
            msp.add_lwpolyline(
                [s(y0, hgt), s(y1, hgt)], dxfattribs={"layer": "SET"})
            if st.get("label"):
                msp.add_text(st["label"], height=1.8,
                             dxfattribs={"layer": "SET", "style": "LBL"}) \
                   .set_placement(s((y0 + y1) / 2, hgt + 130),
                                  align=TextEntityAlignment.CENTER)
        elif st["kind"] == "line":
            hgt = st.get("height", 2400)
            msp.add_lwpolyline([s(st["y0"], 0), s(st["y0"], hgt)],
                               dxfattribs={"layer": "SET"})
            if st.get("label"):
                msp.add_text(st["label"], height=1.8,
                             dxfattribs={"layer": "SET", "style": "LBL"}) \
                   .set_placement(s(st["y0"] + 150, hgt * 0.8),
                                  align=TextEntityAlignment.LEFT)


def draw_boom_section(msp, d):
    """侧吊杆（BOOM）在剖面上的侧视。

    旧版只画 kind=h 的桁架，BOOM SL/SR 在剖面图里完全消失。
    """
    booms = [p for p in d.get("positions", []) if p.get("kind") == "v"]
    if not booms:
        return
    # BOOM 在台口两侧（横向 x=±8100），中心线剖面并不切到它们；
    # 旧版把横向 x 当纵深直接投影，画到纸外去了。
    # 正确做法：画在它们真实纵深处，虚线，并注明 BEYOND CUT。
    # 左右两根纵深一致，剖面上重合 —— 只画一根，标签合并。
    p0 = booms[0]
    y_mid = (p0.get("y0", 0) + p0.get("y1", 0)) / 2.0
    trim = max(b.get("trim", 3600) for b in booms)
    msp.add_lwpolyline([s(y_mid, 0), s(y_mid, trim)],
                       dxfattribs={"layer": "TRUSS", "linetype": "DASHED"})
    msp.add_lwpolyline([s(y_mid - 350, 0), s(y_mid + 350, 0),
                        s(y_mid + 350, 120), s(y_mid - 350, 120)],
                       close=True, dxfattribs={"layer": "TRUSS"})
    names = " / ".join(b["id"] for b in booms)
    msp.add_text(f"{names}  (BEYOND CUT)", height=1.8,
                 dxfattribs={"layer": "DIM", "style": "LBL"}) \
       .set_placement(s(y_mid + 500, trim + 300), align=TextEntityAlignment.LEFT)


def draw_position(msp, p, d):
    """吊挂位置：桁架端面 + 灯具 + 光束。

    光束规则（改进点）：
      · 每台灯用自己的 focus_y（rig.yaml 里可选的 focus_y 字段，
        缺省回退到舞台中区）——旧版全部取中区，是错的。
      · 只画该位置的首末两台边界灯，避免 6 条锥叠成乱线。
      · 光束在焦点处收束到光斑，之后不再延伸（真实灯具就是这样）。
    """
    y = p.get("y", 0)
    trim = p.get("trim", 6000)
    x, ytop = s(y, trim)
    halfw = (p.get("width", 400) / 2) / SCALE

    # 桁架端面
    msp.add_lwpolyline([(x-halfw, ytop-0.5), (x+halfw, ytop-0.5),
                        (x+halfw, ytop+0.5), (x-halfw, ytop+0.5)], close=True,
                       dxfattribs={"layer": "TRUSS"})
    msp.add_text(p["id"], height=2.6,
                 dxfattribs={"layer": "FIXTURE_TXT", "style": "LBL"}) \
       .set_placement((x, ytop + 3.2), align=TextEntityAlignment.CENTER)
    msp.add_text(f"+{int(trim)}", height=2.4, dxfattribs={"layer": "DIM", "style": "LBL"}) \
       .set_placement((x + halfw + 3.4, ytop - 0.8), align=TextEntityAlignment.LEFT)

    fx = [f for f in d["fixtures"] if f.get("pos") == p["id"]]
    if not fx:
        return

    n = min(len(fx), 6)
    sd = d["stage"]["depth"]
    # 默认焦点按位置性质分配：FOH 打近区/中区，LX1 打近中，LX2 打中区，
    # LX3 打后区/天幕。全都打中区会导致光束交叉成一团。
    pos_focus = {
        "FOH LX": sd * 0.22,
        "LX 1":   sd * 0.38,
        "LX 2":   sd * 0.62,
        "LX 3":   sd * 0.88,
    }
    default_focus = pos_focus.get(p["id"], sd * 0.5)

    for i in range(n):
        ox = (i - (n - 1) / 2) * 1.9
        bx, by = x + ox, ytop - 0.5

        # 灯具本体（符号化的小方块 + 镜筒）
        msp.add_lwpolyline([(bx-0.5, by), (bx-0.5, by-1.6),
                            (bx+0.5, by-1.6), (bx+0.5, by)], close=True,
                           dxfattribs={"layer": "FIXTURE"})

        if i not in (0, n - 1) and n > 2:
            continue                       # 只画边界灯的光束

        f = fx[i]
        ang = float(f.get("beam", 26))
        focus_y = float(f.get("focus_y", default_focus))
        # 焦点不能超出舞台深度
        focus_y = max(200.0, min(focus_y, sd - 200.0))

        dist = math.hypot(focus_y - y, trim)          # 斜距 mm
        radius = math.tan(math.radians(ang / 2.0)) * dist   # 光斑半径 mm

        fx_d, fy_d = s(focus_y, 0)
        r_paper = radius / SCALE

        # 两条边界光束：从灯口到焦点光斑两端
        for sgn in (-1, 1):
            ex = fx_d + sgn * r_paper
            # 不穿后墙
            wall_x = s(sd, 0)[0]
            ex = min(ex, wall_x)
            msp.add_lwpolyline([(bx + sgn * 0.35, by - 1.6), (ex, fy_d)],
                               dxfattribs={"layer": "BEAM"})
        # 光斑横线（表明覆盖范围）
        msp.add_lwpolyline([(fx_d - r_paper, fy_d), (fx_d + r_paper, fy_d)],
                           dxfattribs={"layer": "BEAM"})


def draw_panels(msp, d):
    # 右栏必须落在**内框以内**（内框 20..400），否则会压到分区带和分区号。
    # 参考图右栏宽 120.39mm 是 A1 的；等比到 A3 = 60.1mm。
    # 起点 = 400 - 60.1 = 339.9。
    # 早先写 X=300/W=100（右边界 400 刚好压线），后改 350/50（右边界 400 仍压线）。
    # 现在留 1mm 余量。
    X = 339.0
    W = 60.0
    def box(y0, y1, title):
        msp.add_lwpolyline([(X,y0),(X+W,y0),(X+W,y1),(X,y1)], close=True,
                           dxfattribs={"layer":"TITLEBLK"})
        msp.add_text(title, height=2.6, dxfattribs={"layer":"TB_TEXT","style":"TTL"}) \
           .set_placement((X+2, y1-4), align=TextEntityAlignment.LEFT)
    # 说明
    box(200, 274, "NOTES")
    notes = [
        "1. Section cut on centreline, looking SL.",
        "2. Vertical zero = stage floor. Horizontal zero = plaster line.",
        "3. All trim heights measured floor to BOTTOM OF PIPE.",
        "4. Beam cones shown at nominal beam angle, edge to edge.",
        "5. Human figure 1.75m for scale (USITT RP-2).",
        "6. Verify sightlines and masking before focus.",
    ]
    # 60mm 宽放不下一整行，必须折行。按空格断词，用 layout 的宽度估算。
    import layout as _lay

    def _wrap(txt, width, h):
        words = txt.split()
        lines, cur = [], ""
        for w in words:
            trial = (cur + " " + w).strip()
            if _lay.estimate_width(trial, h) > width and cur:
                lines.append(cur)
                cur = w
            else:
                cur = trial
        if cur:
            lines.append(cur)
        return lines

    _yy = 267.0
    for n in notes:
        for _ln in _wrap(n, W - 4.0, 2.0):
            msp.add_text(_ln, height=2.0,
                         dxfattribs={"layer": "NOTES", "style": "LBL"}) \
               .set_placement((X + 2, _yy), align=TextEntityAlignment.LEFT)
            _yy -= 3.6
        _yy -= 1.4
    # 高度表
    box(140, 197, "TRIM SCHEDULE")
    # ★ 列偏移必须跟着 W 走。W 从 100 改成 60 后，旧的 (2/52/78) 会让
    #   "TYPE" 列跑到 x=417..423，直接出纸（420mm）。
    hdr = [("POSITION", 2), ("TRIM +mm", 30), ("TYPE", 46)]
    for t, ox in hdr:
        msp.add_text(t, height=1.9, dxfattribs={"layer":"TB_TEXT","style":"LBL"}) \
           .set_placement((X+ox, 190), align=TextEntityAlignment.LEFT)
    msp.add_lwpolyline([(X+2,188),(X+W-2,188)], dxfattribs={"layer":"NOTES"})
    for i, p in enumerate(d["positions"][:8]):
        yy = 183 - i*5.2
        msp.add_text(p["id"], height=1.9, dxfattribs={"layer":"NOTES","style":"LBL"}) \
           .set_placement((X+2, yy), align=TextEntityAlignment.LEFT)
        msp.add_text(f"+{int(p.get('trim',0))}", height=1.9, dxfattribs={"layer":"NOTES","style":"LBL"}) \
           .set_placement((X+30, yy), align=TextEntityAlignment.LEFT)
        msp.add_text(p.get("kind",""), height=1.9, dxfattribs={"layer":"NOTES","style":"LBL"}) \
           .set_placement((X+46, yy), align=TextEntityAlignment.LEFT)
    # 图签
    box(20, 135, "")
    cx = X + W/2
    msp.add_text(d["meta"]["show"], height=5.4, dxfattribs={"layer":"TB_TEXT","style":"TTL"}) \
       .set_placement((cx, 122), align=TextEntityAlignment.CENTER)
    msp.add_text(d["meta"]["playwright"], height=2.6, dxfattribs={"layer":"TB_TEXT","style":"LBL"}) \
       .set_placement((cx, 115), align=TextEntityAlignment.CENTER)
    msp.add_lwpolyline([(X,110),(X+W,110)], dxfattribs={"layer":"NOTES"})
    msp.add_text(d["meta"]["venue"], height=3.0, dxfattribs={"layer":"TB_TEXT","style":"TTL"}) \
       .set_placement((cx, 104), align=TextEntityAlignment.CENTER)
    msp.add_lwpolyline([(X,99),(X+W,99)], dxfattribs={"layer":"NOTES"})
    msp.add_text("LIGHTING SECTION", height=3.2,
                 dxfattribs={"layer":"TB_TEXT","style":"TTL"}).set_placement((cx, 93), align=TextEntityAlignment.CENTER)
    # 图签字段与平面图同源（rig.yaml meta），别在两处各写一份
    _m = d["meta"]
    rows = [("DESIGNER", _m.get("designer", "")),
            ("DIRECTOR", _m.get("director", "")),
            ("SCALE", "1:50 @ A3"),
            ("DATE", _m.get("date", "")),
            ("SHEET", f"{_m.get('sheet_no_section', 2)} OF {_m.get('sheet_of', 2)}"),
            ("REV", _m.get("revision", "V1"))]
    for i,(k,v) in enumerate(rows):
        yy = 86 - i*8
        msp.add_lwpolyline([(X,yy+3),(X+W,yy+3)], dxfattribs={"layer":"NOTES"})
        msp.add_text(k, height=1.8, dxfattribs={"layer":"TB_TEXT","style":"LBL"}) \
           .set_placement((X+2, yy), align=TextEntityAlignment.LEFT)
        msp.add_text(str(v), height=2.2, dxfattribs={"layer":"TB_TEXT","style":"LBL"}) \
           .set_placement((X+38, yy), align=TextEntityAlignment.LEFT)
    msp.add_text("(C) 2026 - DRAWING ISSUE FOR PRODUCTION", height=1.6,
                 dxfattribs={"layer":"TB_TEXT","style":"LBL"}).set_placement((cx, 22.5), align=TextEntityAlignment.CENTER)


def render(d, outdir="out"):
    os.makedirs(outdir, exist_ok=True)
    # 同上：setup=False，不引入系统里不存在的字体样式
    doc = ezdxf.new("R2010", setup=False)
    doc.header["$INSUNITS"] = 4
    doc = build(doc)
    msp = doc.modelspace()
    draw_border(msp)
    draw_venue(msp, d)
    draw_set_section(msp, d)
    draw_boom_section(msp, d)
    for p in d["positions"]:
        if p.get("kind") == "h":
            draw_position(msp, p, d)
    human(msp, d["stage"]["depth"] * 0.42)
    draw_panels(msp, d)
    # 标题（必须在图框内：A3 内框上边 277，旧版写到 300 直接出了纸）
    msp.add_text("SECTION A-A", height=4.4, dxfattribs={"layer":"TB_TEXT","style":"TTL"}) \
       .set_placement((s(d["stage"]["depth"]*0.4, 0)[0], 258), align=TextEntityAlignment.CENTER)
    msp.add_text("SECTION A-A  LOOKING SL  /  SCALE 1:50 @ A3", height=2.0,
                 dxfattribs={"layer":"DIM","style":"LBL"}) \
       .set_placement((s(d["stage"]["depth"]*0.4, 0)[0], 251), align=TextEntityAlignment.CENTER)

    dxf_p = os.path.join(outdir, "LX_section.dxf")
    pdf_p = os.path.join(outdir, "LX_section.pdf")
    png_p = os.path.join(outdir, "LX_section.png")

    # 先渲染（需要字体完整路径），再改成可移植文件名，最后存 DXF
    import export as _export
    _export.draw_sheet(doc, msp, pdf_p[:-4], SHEET_W, SHEET_H)
    _ok, _detail = _export.check_scale(pdf_p, SHEET_W, SHEET_H)
    print(f"  PDF: {pdf_p}")
    print(f"        {'1:1 校验通过' if _ok else '比例错误: ' + _detail}")
    if not _ok:
        raise SystemExit(f"导出比例错误，拒绝出图：{_detail}")

    fonts.make_portable(doc)
    doc.saveas(dxf_p)
    import dxfix as _dxfix
    _rep = _dxfix.fix_dxf(dxf_p, SHEET_W, SHEET_H, verbose=False)
    if _rep["problems"]:
        for _p in _rep["problems"]:
            print(f"  DXF [WARN] {_p}")
    print(f"  DXF: {dxf_p}")


if __name__ == "__main__":
    # ★ 必须支持 --out：不带的话多个项目会互相覆盖 out/。
    #   实测过：用别的 rig 跑剖面图，把主项目的 out/LX_section.pdf 覆盖了。
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("rig", nargs="?", default="rig.yaml")
    ap.add_argument("--out", default="out", help="输出目录（默认 out/）")
    a = ap.parse_args()
    src = a.rig
    with open(src, encoding="utf-8") as f:
        d = yaml.safe_load(f)
    errs, warns = qc.check_rig(d)
    for w in warns:
        print("  [警告]", w)
    if errs:
        for e in errs:
            print("  [错误]", e)
        raise SystemExit("质检未通过，已中止出图（不产出错图）")
    render(d, outdir=a.out)
