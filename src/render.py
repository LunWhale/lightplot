#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
render.py — 从 rig.yaml 生成专业灯光图纸
用法:
    python3 render.py rig.yaml            # 出图
    python3 render.py rig.yaml --check    # 只校验不出图
"""
import sys, os, math, argparse
import yaml
import qc
import fonts
import layout as lay_mod
import paper
import draw
import draft
import ezdxf
from ezdxf.enums import TextEntityAlignment

SHEET_W, SHEET_H = 841.0, 594.0   # A1 横向

# 校验统一走 qc.check_rig —— 这里曾经有一份 validate()，是它的弱化复制品：
#   - 少了 trim 合理性、吊点越界、beam 缺失、position.type 合法性四条
#   - 硬编码放过 pos == "SET EDGE"（那时 SET EDGE 还不是正式位置）
# 两份校验器必然漂移，且弱的那份会先放行。已删除，只留 qc 一份。

# ============================================================ 符号
# 真实符号来自 data/symbols.json —— 由 src/gdtf_symbol.py 从厂家 GDTF 提取。
# 这里只负责把多边形塞进 DXF block，绝不手画灯具形状。
# 坐标单位是毫米，与图纸 1:1，插入时按 1/SCALE 缩放。

SYMBOLS_JSON = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                            "data", "symbols.json")

# USITT RP-2 §6.9 Practical：三角形。这是规范符号，不是厂家产品。
USITT_PRACTICAL = [[(-90, -70), (90, -70), (0, 95)]]


def load_symbols():
    """读 symbols.json；缺失则明确报错，不静默退回手画。"""
    if not os.path.exists(SYMBOLS_JSON):
        raise SystemExit(
            "缺少 data/symbols.json —— 真实灯具符号尚未提取。\n"
            "请先运行：\n"
            "  python3 src/gdtf_fetch.py\n"
            "  python3 src/gdtf_symbol.py --build"
        )
    import json
    with open(SYMBOLS_JSON, encoding="utf-8") as f:
        return json.load(f)


def build_symbols(doc, syms=None):
    """把提取到的多边形写成 DXF block：SYM_<type>。"""
    syms = syms if syms is not None else load_symbols()
    for key, s in syms.items():
        b = doc.blocks.new(f"SYM_{key}")
        if "usitt" in s:
            polys = USITT_PRACTICAL            # 已是「多边形列表」，不要再套一层
        else:
            top = s.get("top")
            if not top:
                raise SystemExit(f"symbols.json 中 {key} 没有 top 视图，无法出平面图")
            polys = top["polygons"]
        # ★ 先铺白底，再描线。
        #   灯具是**挂在桁架上**的，不是浮在桁架前面：
        #   参考图里灯体是实心白块，桁架线在灯体轮廓处断开。
        #   旧版只画线框，桁架的弦杆/腹杆从灯体里穿过去，
        #   再叠上色片号、灯具号，就成了用户说的「乱糟糟」。
        #   填充用符号自身的多边形（不是外接矩形），轮廓才不会被白框糊掉。
        for poly in polys:
            if len(poly) < 3:
                continue
            h = b.add_hatch(dxfattribs={"layer": "MASK", "true_color": paper.WHITE_RGB})
            h.paths.add_polyline_path([(x, y) for x, y in poly], is_closed=True)
        for poly in polys:
            if len(poly) < 2:
                continue
            pts = [(x, y) for x, y in poly]
            if len(pts) >= 3:
                b.add_lwpolyline(pts, close=True, dxfattribs={"layer": "FIXTURE"})
            else:
                b.add_line(pts[0], pts[1], dxfattribs={"layer": "FIXTURE"})


def symbol_bbox(syms, key):
    """返回符号包围盒 (w, h) 毫米，用于排版避让。"""
    s = syms.get(key, {})
    if "usitt" in s:
        xs = [p[0] for p in USITT_PRACTICAL[0]]
        ys = [p[1] for p in USITT_PRACTICAL[0]]
        return (max(xs) - min(xs), max(ys) - min(ys))
    top = s.get("top")
    if not top:
        return (0.0, 0.0)
    bb = top["bbox"]
    return (bb[2] - bb[0], bb[3] - bb[1])



# ============================================================ 主绘制
def render(d, outdir="out", scene=None):
    os.makedirs(outdir, exist_ok=True)
    SCALE = float(d["meta"].get("scale", 25))
    # 图上全是英文，用 Arial（macOS/Windows/CAD 都自带）。
    # 中文字体只作回退：万一将来要出中文图。
    FONT = "Arial.ttf"
    try:
        fonts.dxf_font()       # 确认字体探测逻辑仍可用（失败不影响出图）
    except Exception:
        pass

    # ★ setup=False：不要 ezdxf 的默认样式集。
    #   setup=True 会塞进 25 个文字样式（OpenSans / Liberation 系列）和
    #   11 个 dimstyle，那些字体文件在 macOS 上**根本不存在**。
    #   DIMSTYLE 表还引用了它们（dimtxsty='OpenSansCondensed-Light'），
    #   Vectorworks 解析时找不到字体 -> 判定文件损坏 -> "unrecognized file"。
    #   实测证据：删掉那些样式后 ezdxf 自己都存不了盘：
    #     DXFTableEntryError: OpenSansCondensed-Light
    #   说明引用是悬空的，只是 ezdxf 写盘时不检查。
    doc = ezdxf.new("R2010", setup=False)
    doc.header["$INSUNITS"] = 4
    msp = doc.modelspace()

    # ---- 线型：setup=False 时只有 Continuous，虚线必须自己建
    #   DXF 线型定义是 dash/dot 序列，单位是图纸 mm（全局 LTSCALE=1）。
    for nm, pat in (("DASHED", [3.0, -1.5]),
                    ("DASHDOT", [4.0, -1.2, 0.0, -1.2]),
                    ("CENTER", [6.0, -1.5, 1.5, -1.5])):
        if nm not in doc.linetypes:
            doc.linetypes.add(nm, pattern=pat, description=nm)

    # ---- 图层（统一来自 paper.py）
    for name, color, lt, lwkey in paper.LAYERS:
        lay = doc.layers.add(name=name, color=color, linetype=lt,
                             lineweight=paper.lw(lwkey))
        # ★ 填充/遮罩图层的 ACI 7 会随背景翻转，Vectorworks 白底上变黑。
        #   图层也钉成真彩白，双保险（实体上已有 true_color）。
        if color == paper.WHITE:
            lay.dxf.true_color = paper.WHITE_RGB

    doc.styles.add("LBL", font=FONT)
    doc.styles.add("TTL", font=FONT)

    syms = load_symbols()
    build_symbols(doc, syms)

    # ---- 场景
    scene_data = None
    if scene:
        sp = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                          "data", "scenes.yaml")
        with open(sp, encoding="utf-8") as f:
            allsc = yaml.safe_load(f)
        scene_data = allsc["scenes"].get(scene)
        if scene_data is None:
            raise SystemExit(f"scenes.yaml 里没有场景 '{scene}'")
        over = scene_data.get("gel_override", {})
        for f in d["fixtures"]:
            if f.get("gel") in over:
                f["gel"] = over[f["gel"]]

    pen = draw.Pen(msp, doc)

    # 把会挡文字的图层登记成排版障碍（桁架/布景/符号/座位）
    BLOCKING = {"SET", "SET_DASH", "TRUSS", "FIXTURE", "SEAT"}
    _orig_line = pen.line
    _orig_poly = pen.poly
    def _line(p1, p2, layer="SET", lt=None):
        e = _orig_line(p1, p2, layer, lt)
        if layer in BLOCKING:
            lay.add_line_obstacle(p1, p2, tag=layer)
        return e
    def _poly(pts, layer="SET", close=False, lt=None):
        e = _orig_poly(pts, layer, close, lt)
        if layer in BLOCKING and len(pts) > 1:
            xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
            lay.add_obstacle((min(xs), min(ys), max(xs), max(ys)), tag=layer)
        return e
    pen.line = _line
    pen.poly = _poly

    # ---- 坐标：rig mm -> 图纸 mm
    PLAN_X0, PLAN_Y0 = 355.0, 215.0
    def w2s(x, y):
        return (PLAN_X0 + x / SCALE, PLAN_Y0 + y / SCALE)

    # ---- 排版器
    SAFE = (22.0, 22.0, SHEET_W - 22.0, SHEET_H - 22.0)
    lay = lay_mod.Layout(pad=0.45, safe_area=SAFE)
    text_entities = []

    def T(s, x, y, key="NOTE", layer="NOTES", rot=0.0,
          align=TextEntityAlignment.MIDDLE_CENTER, avoid=True, owner="",
          priority=0, style="LBL", color=None, mask=True):
        """按 paper.FS 字号表画字，并登记避让。"""
        size = paper.FS[key] if isinstance(key, str) else key
        t = pen.text(s, x, y, size, layer, rot=rot, align=align, style=style,
                     color=color, mask=mask, mask_pad=0.3)
        if avoid:
            amap = {TextEntityAlignment.MIDDLE_CENTER: "center",
                    TextEntityAlignment.MIDDLE_LEFT: "left",
                    TextEntityAlignment.MIDDLE_RIGHT: "right"}
            lb = lay.add_label(str(s), x, y, size, rot=rot, owner=owner,
                               align=amap.get(align, "center"), priority=priority)
            text_entities.append((t, lb, align))
        return t

    # ======================================================== 图框
    # 全部尺寸照参考图实测（见 docs/07-drafting-language.md）：
    #   外框 = 纸边 (0,0)-(841,594)，**不内缩**
    #   内框 = (19.98,19.98)-(821.01,574.04)，即 IN=20
    #   分区带 = 0..20（20mm 宽），刻度线 5mm 长，从内框向外
    #   列号文字中心 y=13.55，行号文字中心 x=15.05，字高 cap 4.55（em 6.35）
    M = 0.0
    pen.poly([(M, M), (SHEET_W - M, M), (SHEET_W - M, SHEET_H - M), (M, SHEET_H - M)],
             "BORDER", close=True)
    IN = 20.0
    pen.poly([(IN, IN), (SHEET_W - IN, IN), (SHEET_W - IN, SHEET_H - IN), (IN, SHEET_H - IN)],
             "BORDER", close=True)

    GX0, GX1, GY0, GY1 = IN, SHEET_W - IN, IN, SHEET_H - IN
    COLS, ROWS = 12, 8
    cw, chh = (GX1 - GX0) / COLS, (GY1 - GY0) / ROWS
    TICK = 5.0                       # 刻度线长（参考图实测 4.99）
    TX = 13.55                       # 列号文字中心 y（参考图实测）
    TY = 15.05                       # 行号文字中心 x
    for i in range(COLS):
        x = GX0 + (i + 0.5) * cw
        pen.line((x, GY1), (x, GY1 + TICK), "GRID")
        pen.line((x, GY0), (x, GY0 - TICK), "GRID")
        T(i + 1, x, TX, "BORDER", "GRIDTEXT", avoid=False)
        T(i + 1, x, SHEET_H - TX, "BORDER", "GRIDTEXT", avoid=False)
    for j in range(ROWS):
        y = GY0 + (j + 0.5) * chh
        pen.line((GX0, y), (GX0 - TICK, y), "GRID")
        pen.line((GX1, y), (GX1 + TICK, y), "GRID")
        T(chr(65 + j), TY, y, "BORDER", "GRIDTEXT", avoid=False)
        T(chr(65 + j), SHEET_W - TY, y, "BORDER", "GRIDTEXT", avoid=False)

    # ======================================================== 观众席
    SW, SD = d["stage"]["width"], d["stage"]["depth"]
    for r in range(5):
        yy = -1500 - r * 550
        for c in range(12):
            xx = -4200 + c * 760
            if abs(xx) > 4200 - r * 220:
                continue
            p0 = w2s(xx - 290, yy - 210)
            p1 = w2s(xx + 290, yy + 210)
            pen.rect(p0[0], p0[1], p1[0], p1[1], "SEAT")
    pen.line(w2s(-4200, -1500 - 4 * 550 - 300), w2s(4200, -1500 - 4 * 550 - 300), "SEAT")
    T("AUDIENCE / FOH", *w2s(0, -1500 - 4 * 550 - 700), "SUBTITLE", "SEAT",
      avoid=False)

    # ======================================================== 舞台
    pen.poly([w2s(-SW / 2, 0), w2s(-SW / 2, SD), w2s(SW / 2, SD), w2s(SW / 2, 0)],
             "STAGE", close=True)
    pen.line(w2s(-SW / 2, 0), w2s(SW / 2, 0), "STAGE")
    T("STAGE EDGE", *w2s(0, -240), "COLOR", "STAGE", avoid=False)

    # ======================================================== 布景
    for st in d.get("set", []):
        # ---- 楼梯：从一层到二层平台（UPPER LEVEL +2400）
        # 参考图语法：踏步是等距平行细线，两侧画斜边线，加一个向上箭头。
        # 位置选在舞台**右侧后方**，理由：
        #   · 上层平台右缘 x=7200，楼梯贴它下沿，是唯一不用穿过台面的路线
        #   · 避开 LX1/LX2/LX3 三根桁架的灯具落点（都在 x=-3300..3500 的中间带）
        #   · 在观众视线外侧，不抢主画面
        if st["kind"] == "stair":
            run_x0, run_x1 = st["x0"], st["x1"]
            y0_, y1_ = st["y0"], st["y1"]
            n = int(st.get("steps", 12))
            along_y = abs(y1_ - y0_) >= abs(run_x1 - run_x0)

            # 楼梯画法（制图惯例，不用矩形外框）：
            #   · 两条侧边线（梯段边）
            #   · 等距踏步线，垂直于行进方向，虚线
            #   · 一条短的 UP 箭头 + UP 文字，放在箭头尾
            # 不写外框：矩形加一堆平行线会被读成"一排座位"。
            # 不打断：3360mm 进深在 1:25 上是 134mm，A1 图幅完全放得下，
            #   打断线在放得下的时候是多余的,只会让图更乱。
            if along_y:
                pen.line(w2s(run_x0, y0_), w2s(run_x0, y1_), "SET")
                pen.line(w2s(run_x1, y0_), w2s(run_x1, y1_), "SET")
            else:
                pen.line(w2s(run_x0, y0_), w2s(run_x1, y0_), "SET")
                pen.line(w2s(run_x0, y1_), w2s(run_x1, y1_), "SET")
            for i in range(1, n):
                if along_y:
                    yy = y0_ + (y1_ - y0_) * i / n
                    a_, b_ = w2s(run_x0, yy), w2s(run_x1, yy)
                else:
                    xx = run_x0 + (run_x1 - run_x0) * i / n
                    a_, b_ = w2s(xx, y0_), w2s(xx, y1_)
                pen.line(a_, b_, "SET", "DASHED")

            # UP 箭头：只占中间 35%，短而明确
            if along_y:
                mid = (run_x0 + run_x1) / 2.0
                tail = w2s(mid, y0_ + (y1_ - y0_) * 0.42)
                tip = w2s(mid, y0_ + (y1_ - y0_) * 0.68)
            else:
                ay = (y0_ + y1_) / 2.0
                tail = w2s(run_x0 + (run_x1 - run_x0) * 0.42, ay)
                tip = w2s(run_x0 + (run_x1 - run_x0) * 0.68, ay)
            pen.line(tail, tip, "SET")
            _dx, _dy = tip[0] - tail[0], tip[1] - tail[1]
            _ln = math.hypot(_dx, _dy) or 1.0
            _dx, _dy = _dx / _ln, _dy / _ln
            _hw = 0.40
            for sgn in (-1, 1):
                pen.line(tip, (tip[0] - _dx * _hw * 1.7 - sgn * _dy * _hw,
                               tip[1] - _dy * _hw * 1.7 + sgn * _dx * _hw), "SET")
            T("UP", tail[0] + 1.1, tail[1], "MICRO", "SET",
              align=TextEntityAlignment.MIDDLE_LEFT, avoid=False)

            if st.get("label"):
                lx_ = (w2s(run_x0, y0_)[0] + w2s(run_x1, y0_)[0]) / 2
                ly_ = min(w2s(run_x0, y0_)[1], w2s(run_x0, y1_)[1]) - 3.2
                T(st["label"], lx_, ly_, "COLOR", "SET",
                  owner=f"set:{st['label']}", priority=6)
            continue
        if st["kind"] == "line":
            pa = w2s(st["x0"], st["y0"])
            pb = w2s(st["x1"], st["y1"])
            pen.line(pa, pb, "SET")
            if st.get("label"):
                # 水平线标签放线上方；竖线标签放线右侧
                if abs(pb[1] - pa[1]) < abs(pb[0] - pa[0]):
                    lx_, ly_ = (pa[0] + pb[0]) / 2, pa[1] + 3.2
                else:
                    lx_, ly_ = pa[0] + 2.6, (pa[1] + pb[1]) / 2
                T(st["label"], lx_, ly_, "COLOR", "SET",
                  owner=f"set:{st['label']}", priority=8)
        else:
            p0 = w2s(st["x0"], st["y0"])
            p1 = w2s(st["x1"], st["y1"])
            layername = "SET_DASH" if st.get("dashed") else "SET"
            pen.rect(p0[0], p0[1], p1[0], p1[1], layername)
            if st.get("label"):
                # 虚框（如 UPPER LEVEL）标签放上边线外侧；实体布景放下边线外侧
                # 虚线框（上层平台）标签放框**下边线外侧**（框顶被舞台线穿过）；
                # 实景放下边线外 7mm，让开灯位标注
                ly_ = p0[1] - 2.6 if st.get("dashed") else p0[1] - 7.2
                T(st["label"], (p0[0] + p1[0]) / 2, ly_,
                  "COLOR", layername, owner=f"set:{st['label']}", priority=2)

    # ======================================================== 光区
    for z in d.get("zones", []):
        pen.poly([w2s(z["x0"], z["y0"]), w2s(z["x1"], z["y0"]),
                  w2s(z["x1"], z["y1"]), w2s(z["x0"], z["y1"])],
                 "ZONE", close=True, lt="DASHDOT")
        T(z["id"], *w2s(z["x0"] + 420, z["y0"] + 260), "POSITION", "ZONE",
          avoid=False)

    # ======================================================== 桁架
    # 用 draft.truss()：上下弦矩形 + 正 M 格构 + 白底遮罩。
    # 单元宽 = 桁架实物宽 / 比例。300mm @ 1:25 → 12mm
    # 单元宽 = 参考图实测 pitch（图纸 mm），不是「300mm 实物 ÷ 比例」。
    # 参考图 pitch 11.7687mm @1:25 → 实物 294.2mm，与标称 300mm 差 2%。
    # 用实测值才能和参考图逐格对齐。
    TRUSS_CELL = draft.TRUSS["pitch_mm"]

    # 桁架名要等灯具标注块画完再放 —— 否则不知道它们占多宽。
    # 旧版按「灯具中心之间的最大空隙」放名字，但标注块从灯具中心
    # 向右伸约 15mm（圆圈 + 色片号 + 编号），名字压在块上，verify 报错。
    truss_names = []          # (position, a_, b_)
    trim_spans = {}           # pos_id -> (x0, x1)，桁架名要避开标高字
    pos_half = {}             # pos_id -> 构件半高（图纸 mm），灯具挂点用

    for p in d.get("positions", []):
        _kind = p.get("type", "truss")
        if p["kind"] == "h":
            a_ = w2s(p["x0"], p["y"])
            b_ = w2s(p["x1"], p["y"])
            if _kind == "pipe":
                draft.pipe(pen, a_, b_)
                pos_half[p["id"]] = draft.PIPE["height"] / 2.0
            elif _kind == "line":
                # 非吊挂构件（布景边缘等）：只画一条细线。
                # 用桁架画会让人误读成"第四根灯杆"。
                pen.line(a_, b_, "SET")
                pos_half[p["id"]] = 0.35
            else:
                draft.truss(pen, a_, b_, TRUSS_CELL)
                pos_half[p["id"]] = TRUSS_CELL / 2.0
            if _kind != "line":
                truss_names.append((p, a_, b_))
            # 标高放桁架左端下方（右端是 BOOM 的地盘，会撞）
            # 标高压在桁架左端下弦下方；桁架名改用「最宽空档」算法，
            # 并把这个占位登记进去，两者不会互相压。
            _tw = lay_mod.estimate_width(f"+{p['trim']}", paper.FS["DIM"])
            T(f"+{p['trim']}", a_[0] + 2.0,
              a_[1] - pos_half[p["id"]] - 3.4,
              "DIM", "DIM", align=TextEntityAlignment.MIDDLE_LEFT,
              owner=f"trim:{p['id']}", priority=6)
            trim_spans[p["id"]] = (a_[0] + 2.0, a_[0] + 2.0 + _tw)
        else:
            a_ = w2s(p["x"], p["y0"])
            b_ = w2s(p["x"], p["y1"])
            if _kind == "pipe":
                draft.pipe(pen, a_, b_)
                pos_half[p["id"]] = draft.PIPE["height"] / 2.0
            elif _kind == "line":
                pen.line(a_, b_, "SET")
                pos_half[p["id"]] = 0.35
            else:
                draft.truss(pen, a_, b_, TRUSS_CELL)
                pos_half[p["id"]] = TRUSS_CELL / 2.0
            # 竖直桁架（BOOM）：名字沿杆旋转 90°，放在杆的**外侧**，
            # 避开挂在杆上、朝内打光的灯具和它们的标注块。
            side = -1.0 if p["x"] < 0 else 1.0      # 朝图外的方向
            # 标高放在杆的**下端**（BOOM 最下一台灯通常在 900mm 以上，
            # 杆底 y0 一定空着），横排贴着杆外侧
            T(f"+{p['trim']}", a_[0] - side * (pos_half[p["id"]] + 2.0),
              a_[1] + 7.0, "DIM", "DIM",
              align=TextEntityAlignment.MIDDLE_RIGHT if side > 0
              else TextEntityAlignment.MIDDLE_LEFT,
              owner=f"trim:{p['id']}", priority=6)

    # 每个位置上的灯具标注块占位（x 区间），供桁架名找空档用
    label_spans = {}          # pos_id -> [(x0, x1), ...]


    # ======================================================== 灯具
    rig = []
    for f in d["fixtures"]:
        if f.get("pos") == "SET EDGE":
            x, y = f["x"], f["y"]
        else:
            pos = next(p for p in d["positions"] if p["id"] == f["pos"])
            if "x" in f:
                x, y = f["x"], f.get("y", pos.get("y", 0))
            elif "y" in f:
                x, y = pos.get("x", 0), f["y"]
            else:
                x, y = pos.get("x", 0), pos.get("y", 0)

        px, py = w2s(x, y)
        aim = f.get("aim", 90)

        # 参考图里灯具是**挂在桁架下方**的：符号顶边贴着桁架下沿，
        # 而不是符号中心对准桁架中心线。这里把插入点沿出光方向
        # 下移（半个桁架高 + 半个符号高）。
        # 参考图：灯具符号的底边紧贴桁架上沿，几乎无间隙。
        # 插入点 = 桁架上沿 + 半个符号长（沿出光方向）。
        _raw_w, _raw_h = symbol_bbox(syms, f["type"])
        _long = max(_raw_w, _raw_h)
        _sc0 = (11.2 / _long) if _long > 0 else 1.0
        _bh_paper = _raw_h * _sc0
        _bw_paper = _raw_w * _sc0
        _aim = math.radians(aim)
        _half_along = _bh_paper / 2 if abs(math.cos(_aim)) < 0.5 else _bw_paper / 2
        _mhalf = pos_half.get(f.get("pos"), TRUSS_CELL / 2.0)
        # 用户要求：「灯具放在桁架上，而不是桁架前面」。
        # 意思是符号中心就落在桁架中心线上，桁架从灯体后面穿过，
        # 灯体是实心白块 → 桁架线在灯体轮廓处断开（参考图就是这个语法）。
        # 旧版 _hang 把符号整个推到桁架外侧，看起来像浮在桁架前面。
        _hang = _mhalf
        px += math.cos(_aim) * _hang
        py += math.sin(_aim) * _hang

        # ---- 符号尺寸
        # symbols.json 里的坐标单位是**实物毫米**（GDTF 1:1）。
        # 目标：符号长轴在图纸上 = TARGET_LONG_PAPER（参考图实测 11.2mm）。
        # 所以 block scale = 目标图纸长度 / 实物长度 × SCALE 的倒数关系：
        #   图纸长度 = 实物长度 × scale / SCALE
        #   => scale = 目标图纸长度 × SCALE / 实物长度
        raw_w, raw_h = symbol_bbox(syms, f["type"])      # 实物 mm（block 内容单位）
        TARGET_LONG_PAPER = 11.2                          # 目标图纸长度 mm
        long_mm = max(raw_w, raw_h)
        # ezdxf 的 blockref scale 直接作用于 block 内容，**不再除 SCALE**。
        # 所以要让结果等于 11.2mm，scale = 11.2 / 实物长度。
        sc = (TARGET_LONG_PAPER / long_mm) if long_mm > 0 else 1.0

        ins = msp.add_blockref(f"SYM_{f['type']}", (px, py),
                               dxfattribs={"layer": "FIXTURE"})
        # ★ 符号「前方」是 -Y，不是 +Y。
        #   GDTF 提取时按 X,Y 直接投影，实测所有类型的**宽端（镜片/出光面）
        #   都在 -Y**：
        #     fresnel -Y 均宽 237.6 / +Y 均宽 186.2
        #     par     -Y  87.2 / +Y  67.7
        #     led     -Y 315.7 / +Y 206.7
        #   旧代码按 +Y 前方算 rotation = aim-90，结果**所有灯整体反了 180°**，
        #   图上就是「全部对着观众」。正确解：把 -Y 转到 aim 上，即 aim+90。
        #   aim: 0=+X（舞台右）, 90=+Y（朝后墙/上场方向）。
        ins.dxf.rotation = aim + 90
        ins.dxf.xscale = ins.dxf.yscale = sc

        # 图纸上的实际尺寸（供标注定位用）
        bw = raw_w * sc
        bh = raw_h * sc
        if abs((aim - 90) % 180) > 45:
            bw, bh = bh, bw

        # ---- 标注（实测参考图语法）
        #   圆圈通道号在灯具**左侧**，色片号在**右侧**，同一水平轴。
        #   实测：通道号 3.50mm，色片号 3.11mm，圆圈直径 ≈ 2.4 × 字高。
        #   灯具编号（unit）也放右侧、色片号下方。
        ang = math.radians(aim)
        ux, uy = math.cos(ang), math.sin(ang)
        vx, vy = -uy, ux          # 侧向（左 = -v）

        # ★ 侧向半宽必须取「符号在**垂直于出光方向**上的支撑半宽」，
        # 不能简单用 bw/2 或 bh/2。竖着的 BOOM 灯长轴是竖直的，
        # 用长轴一半会把圆圈和色片号推到 10mm 外，压到隔壁灯上。
        # 轴对齐矩形沿单位法向 n 的支撑函数 = (|nx|·bw + |ny|·bh) / 2
        # 沿出光方向的半长（符号长轴的一半）
        half_along = (bh if abs(uy) > 0.5 else bw) / 2.0
        r_mark = paper.FS["UNIT"] * 1.0

        # ★ 参考图语法（用户两次指正，这里按例子来）：
        #   ① 灯具**一半压在桁架上、一半伸出去** —— 符号中心落在桁架边缘，
        #      桁架从灯体后面穿过，白底填充让桁架线在灯体处自然断开。
        #   ② 圆圈通道号在**尾端**（背光方向），色片号/灯具号在**前端**（出光方向）。
        #      不是两个都挤在同一侧 —— 旧版就是那样，所以「乱糟糟」。
        # 该灯所属位置对象（判断横桁架 / 竖吊杆，以及构件中心线在哪）
        _pos_obj = None if f.get("pos") == "SET EDGE" else next(
            (q for q in d["positions"] if q["id"] == f["pos"]), None)
        _is_boom = bool(_pos_obj) and _pos_obj.get("kind") == "v"

        # 圆圈落在灯尾，但必须**让开桁架**（用户：尽量自然地放在桁架外）。
        # 沿灯轴往后退，退到圆盘完全离开构件带为止。
        _mh = pos_half.get(f.get("pos"), TRUSS_CELL / 2.0)
        _py0 = _pos_obj.get("y", 0.0) if _pos_obj else 0.0
        _px0 = _pos_obj.get("x", 0.0) if _pos_obj else 0.0
        _need = _mh + r_mark + 0.55
        _dd = half_along + r_mark + 0.7
        for _ in range(6):
            cx_, cy_ = px - ux * _dd, py - uy * _dd
            if _is_boom:
                gap = abs(cx_ - (PLAN_X0 + _px0 / SCALE)) - _need
            else:
                gap = abs(cy_ - (PLAN_Y0 + _py0 / SCALE)) - _need
            if gap >= 0:
                break
            ax = abs(ux) if _is_boom else abs(uy)
            _dd += (-gap) / max(ax, 0.25) + 0.15

        bname = f"LBL_{f['unit']}"
        if bname not in doc.blocks:
            blk = doc.blocks.new(bname)
            # 圆盘用多边形近似做**实心白底**：edge_path 的 arc 在 PDF 后端
            # 不一定被填充，用户要求「圆圈号码也要有实体，可覆盖」。
            import math as _m
            disc = [(r_mark * _m.cos(_m.radians(a)), r_mark * _m.sin(_m.radians(a)))
                    for a in range(0, 360, 10)]
            h0 = blk.add_hatch(dxfattribs={"layer": "MASK", "true_color": paper.WHITE_RGB})
            h0.paths.add_polyline_path(disc, is_closed=True)
            blk.add_circle((0, 0), r_mark, dxfattribs={"layer": "MARK"})
            blk.add_text(str(f["ch"]), height=paper.FS["UNIT"],
                         dxfattribs={"layer": "MARK", "style": "LBL"}
                         ).set_placement((0, 0), align=TextEntityAlignment.MIDDLE_CENTER)

        msp.add_blockref(bname, (cx_, cy_), dxfattribs={"layer": "FIXTURE_TXT"})

        # ---- 前端标注：色片号（上）/ 灯具号（下），各带白底
        # 行距：必须大于字形 ink 高度 + 白底余量，否则两行白框会互相压。
        row = (paper.FS["COLOR"] / 0.7163) * 1.12
        has_gel0 = bool(f.get("gel")) and f["gel"] != "-"
        _th = paper.FS["COLOR"]
        # 宽度用图层真实字体（Arial Narrow Bold）度量，不用 estimate_width：
        # 后者走 Arial，比实际宽 18%，会把标注白白推远 1.3mm。
        from metrics import width_mm as _wmm
        _tw = max(_wmm(str(f.get("gel") or f["unit"]), _th, "narrowbold"),
                  _wmm(str(f["unit"]), _th, "narrowbold"))
        # ★ 定位必须用**真实字形包围盒**，不能用 cap 高度当占位。
        #   字形实际高 2.86mm（cap 2.24 + 上伸/下伸），按 cap 算会短 0.6mm，
        #   字就戳进灯体包围盒里 —— verify 报 INSERT×TEXT 重叠，
        #   图上看起来也像贴着灯钩。这里先量一个探针字，拿到 ink 相对
        #   insert 的偏移，后面所有标注都用同一份偏移。
        _INK = getattr(render, "_ink_cache", None)
        if _INK is None:
            from ezdxf import bbox as _bbp
            _probe = msp.add_text("L000", height=_th,
                                  dxfattribs={"layer": "FIXTURE_TXT", "style": "LBL"})
            _probe.set_placement((0.0, 0.0), align=TextEntityAlignment.MIDDLE_CENTER)
            _pb = _bbp.extents([_probe])
            msp.delete_entity(_probe)
            _INK = (_pb.extmin.y, _pb.extmax.y)      # 相对 insert 的下/上沿
            render._ink_cache = _INK
        _ink_lo, _ink_hi = _INK
        _gap = 0.30                                   # 与灯体前端的净空
        # 先按「色片号在上、灯具号在下」排出一个整体高度
        _blk_h = (_ink_hi - _ink_lo) * 2 + (_th * 0.44)
        # 整体下沿贴灯：让最下面那行的 ink 下沿 = 灯端 + gap
        _fd = half_along + _gap - _ink_lo + _blk_h / 2.0
        fx_, fy_ = px + ux * _fd, py + uy * _fd

        def _front_txt(sv, dy):
            """带白底的标注文字。

            用户要求「文字框不透明、无边框、做小、贴着灯」。

            ★ 白底矩形必须**由真实字形包围盒反推**，不能靠字体度量估算。
            原因：DXF TEXT height 是 cap height，而字形有上伸部/下伸部；
            并且图层用 Arial Narrow Bold，与实际渲染字宽差 18%。
            估算出来的框永远差一点，线就从字的上沿/左右穿过去 ——
            这正是「L-code 看起来压根没有白底」的原因。

            做法：先在目标位置放字 → 用 ezdxf.bbox 量出**真实**包围盒
            → 删掉 → 按包围盒画白底 → 再把字放回去。
            代价是多一次实体创建，换来的是零误差。
            """
            from ezdxf import bbox as _bb2
            pos = (fx_, fy_ + dy)
            t = msp.add_text(str(sv), height=_th,
                             dxfattribs={"layer": "FIXTURE_TXT", "style": "LBL"})
            t.set_placement(pos, align=TextEntityAlignment.MIDDLE_CENTER)
            bb = _bb2.extents([t])
            msp.delete_entity(t)
            padx, pady = 0.22, 0.16
            x0, x1 = bb.extmin.x - padx, bb.extmax.x + padx
            y0, y1 = bb.extmin.y - pady, bb.extmax.y + pady
            h = msp.add_hatch(dxfattribs={"layer": "MASK", "true_color": paper.WHITE_RGB})
            h.paths.add_polyline_path(
                [(x0, y0), (x1, y0), (x1, y1), (x0, y1)], is_closed=True)
            t2 = msp.add_text(str(sv), height=_th,
                              dxfattribs={"layer": "FIXTURE_TXT", "style": "LBL"})
            t2.set_placement(pos, align=TextEntityAlignment.MIDDLE_CENTER)
            return t2

        if has_gel0:
            _front_txt(f["gel"], row * 0.5)
            _front_txt(f["unit"], -row * 0.5)
        else:
            _front_txt(f["unit"], 0)

        # 登记标注的真实占位 —— 排版器看不见 INSERT / 单独文字，
        # 必须显式告诉它，否则别的文字会压到标注上而排版器认为干净。
        _vh = max(r_mark, row * 0.5 + _th / 2 + 0.3)
        _lbl_bb = (min(cx_ - r_mark, fx_ - _tw / 2 - 0.5),
                   min(cy_ - r_mark, fy_ - _vh),
                   max(cx_ + r_mark, fx_ + _tw / 2 + 0.5),
                   max(cy_ + r_mark, fy_ + _vh))
        lay.add_hard(_lbl_bb, tag=f"label:{f['unit']}")
        _pos_key = f.get("pos")
        label_spans.setdefault(_pos_key, []).append(
            (_lbl_bb[0], _lbl_bb[2], _lbl_bb[1], _lbl_bb[3]))

        rig.append(f)

    # ======================================================== 桁架名
    # 参考图里桁架名有两种朝法：横着的压在桁架中段、竖着的沿杆旋转 90°。
    # 横放那个会跟灯具及其标注抢地方（灯就挂在桁架下面），所以统一改成
    # **竖排在桁架左端外侧**：只占一个字高的横向宽度，永远不压符号，
    # 也和 BOOM 的灯具（在更外侧）留出净空。
    for p, a_, b_ in truss_names:
        name = p["id"]
        if p["kind"] == "h":
            # 横向构件：竖排名字放在左端外侧
            nx = a_[0] - paper.FS["COMPONENT"] * 0.85
            ny = a_[1]
        else:
            # 竖向构件（BOOM）：名字贴在**最外侧标注块之外**。
            # 不能只按构件半高算 —— 灯具标注块比构件宽得多。
            side = -1.0 if p["x"] < 0 else 1.0
            spans = label_spans.get(name, [])
            if spans:
                edge = (min(s0 for s0, _, _, _ in spans) if side < 0
                        else max(s1 for _, s1, _, _ in spans))
            else:
                edge = a_[0] + side * draft.PIPE["height"]
            # 旋转 90° 后字高变成横向占位，中心再退半个字高
            nx = edge + side * (paper.FS["COMPONENT"] / 2 + 1.2)
            ny = (a_[1] + b_[1]) / 2
        T(name, nx, ny, "COMPONENT", "DIM",
          rot=90, align=TextEntityAlignment.MIDDLE_CENTER,
          owner=f"truss:{name}", priority=13, style="TTL")

    # ======================================================== 尺寸 / 比例尺
    try:
        # ★ 尺寸标注必须标**真实毫米**，不是图纸毫米。
        #   DXF 模型空间就是图纸空间（1:1 出图），量出来的 600 是纸面 600mm。
        #   dimstyle "EZDXF" 自带 dimlfac=100，600×100=60000 —— 用户读成 60 米。
        #   实际台宽 15000mm。正确 dimlfac = SCALE（25），600×25 = 15000。
        dim = msp.add_linear_dim(base=w2s(0, 7750), p1=w2s(-SW / 2, 7400),
                                 p2=w2s(SW / 2, 7400), dimstyle="EZDXF",
                                 override={"dimtxt": paper.FS["DIM"], "dimdec": 0,
                                           "dimlfac": SCALE})
        dim.render()
    except Exception as e:
        print("  dim warning:", e)

    seg_mm = 1000.0
    seg = seg_mm / SCALE
    sbx, sby, SBH = 42.0, 546.0, 4.0
    pen.line((sbx, sby), (sbx + 4 * seg, sby), "NOTES")
    pen.line((sbx, sby + SBH), (sbx + 4 * seg, sby + SBH), "NOTES")
    for i in range(5):
        x = sbx + i * seg
        pen.line((x, sby), (x, sby + SBH), "NOTES")
        T(str(i), x, sby - 3.4, "COLOR", "NOTES", avoid=False)
    for i in (0, 2):
        pen.line((sbx + i * seg, sby), (sbx + (i + 1) * seg, sby + SBH), "NOTES")
    T("m", sbx + 4 * seg + 3.0, sby + SBH / 2, "COLOR", "NOTES",
      align=TextEntityAlignment.MIDDLE_LEFT, avoid=False)
    T(f"SCALE 1:{int(SCALE)}  @  A1", sbx, sby + SBH + 5.0, "COLOR", "NOTES",
      align=TextEntityAlignment.MIDDLE_LEFT, avoid=False)

    # ======================================================== A-A 剖切线
    cut_y = SD * 0.5
    MAX_CUT_X = (690.0 - PLAN_X0 - 10.0) * SCALE
    # 剖切符号留在舞台宽度内，避免与两侧 BOOM 的标注打架
    cut_x0 = -SW / 2 + 300
    cut_x1 = SW / 2 - 300
    pen.line(w2s(cut_x0, cut_y), w2s(cut_x1, cut_y), "ACCENT", "DASHDOT")
    for cx, flip in ((cut_x0, 1), (cut_x1, -1)):
        p0 = w2s(cx, cut_y)
        ddx = 6.0 * flip
        pen.line((p0[0], p0[1] - 4.5), (p0[0], p0[1] + 4.5), "ACCENT")
        pen.line((p0[0], p0[1] + 4.5), (p0[0] + ddx, p0[1] + 4.5), "ACCENT")
        T("A", p0[0] + ddx * 1.8, p0[1] + 6.2, "SUBTITLE", "ACCENT",
          avoid=False)
    _cut_mid = w2s(0, cut_y)
    T("SECTION A-A", _cut_mid[0], _cut_mid[1] + 3.2, "COLOR", "ACCENT",
      avoid=False)

    # ======================================================== 右栏
    # 照参考图：右栏是**一列小字块**，没有表格框线，从图签往上堆。
    # 实测字号：块标题 4.89、条目 4.25、说明 4.2（行距 4.72）、
    # 图例条目间距 12.7~13.2。用户要求：不要「雷霆大文字」、不要太空表。
    LX0, LXR = 694.0, 821.0
    PAD_L = 4.0
    COL_INSET = 11.8            # 数量列距右边界（参考图实测 11.8mm；用户要求别贴框线）
    LEG_PITCH = 14.0
    NOTE_LEAD = 6.2      # 本机字体 4.2mm 字高实际包围盒 ≈5.4mm，行距要 6.2
    BLK_GAP = 7.0

    counts = {}
    for f in rig:
        counts[f["type"]] = counts.get(f["type"], 0) + 1
    used_types = [k for k in d["types"] if counts.get(k, 0) > 0]

    def fit_h(txt, h, maxw, minh=2.4):
        """把字号缩到能塞进 maxw（专业图签遇到长名字就是这么处理的）。"""
        w = lay_mod.estimate_width(txt, h)
        if w > maxw and w > 0:
            h = max(minh, h * maxw / w * 0.97)
        return h

    def block(title, height, ytop):
        """在 [ytop-height, ytop] 里画块头（标题 + 细线），返回块底 y。"""
        T(title, LX0, ytop - 4.6, "LEGEND_HDR", "LEGEND",
          align=TextEntityAlignment.MIDDLE_LEFT, avoid=False, style="TTL")
        pen.line((LX0, ytop - 8.4), (LXR, ytop - 8.4), "LEGEND")
        return ytop - height

    # ---------- 图签（钉在右下角）
    meta = d["meta"]
    TB0, TB1 = LX0, LXR
    TB_H = 76.0
    TBY0 = 26.0
    TBY1 = TBY0 + TB_H

    # ---------- 数据先算好，才能算总高、均分剩余空间
    gcount = {}
    for f in rig:
        g = f.get("gel")
        if g and g != "-":
            gcount[g] = gcount.get(g, 0) + 1
    known = {g["gel"]: g for g in d.get("gels", [])}
    gel_rows = [(gid, (known.get(gid) or {}).get("name", "(unlisted)"), cnt)
                for gid, cnt in sorted(gcount.items(), key=lambda kv: -kv[1])]

    notes = [
        "1.  Dimensions in mm. Datum = stage floor.",
        "2.  Trims + above stage floor.",
        "3.  Units: 1xx FOH, 2xx LX1, 3xx LX2,",
        "    4xx LX3, 5xx/6xx booms, 7xx movers,",
        "    8xx followspots, 9xx practicals.",
        "4.  Circled figures are DMX channels.",
        "5.  Colour call per COLOUR LIST.",
        "6.  Verify all rigging on site.",
    ]

    H_LEG = 12.0 + len(used_types) * LEG_PITCH + 5.0
    H_INS = 12.0 + len(used_types) * 6.6
    H_GEL = 12.0 + len(gel_rows) * 6.6
    H_NOT = 12.0 + len(notes) * NOTE_LEAD

    # ---------- 自上而下堆：图例 → 灯具表 → 色片表 → 说明 → 图签
    # 参考图的右栏就是这样：顶部图例、底部说明 + 图签，中间不留大空洞。
    # 分区带从 y=574 起（内框 574，编号在 574..584），内容绝不能进那里。
    # 自下而上堆叠：cursor = 下一个块的**底边**。
    # ★ 早先写错成「下一块顶 = 上一块底 + gap + h」，于是每块都压在上一块上，
    #   一次产生上百处重叠。正确写法是 cursor 一直往前推。
    COL_TOP = 566.0
    cursor = TBY1 + 9.0

    def stack(title, h):
        """在 cursor 处向上放一个块，返回块底 y，并把 cursor 推到块顶之上。"""
        nonlocal cursor
        ytop = cursor + h
        ybot = block(title, h, ytop)
        cursor = ytop + BLK_GAP
        return ybot

    # ---------- 说明
    ybot = stack("NOTES", H_NOT)
    yy = ybot + H_NOT - 12.0 - NOTE_LEAD / 2
    for n in notes:
        T(n, LX0, yy, "NOTE", "NOTES",
          align=TextEntityAlignment.MIDDLE_LEFT, avoid=False)
        yy -= NOTE_LEAD

    # ---------- 色片表
    ybot = stack("COLOUR LIST", H_GEL)
    yy = ybot + H_GEL - 12.0 - 3.1
    for gid, gname, cnt in gel_rows:
        T(gid, LX0, yy, "COLOR", "LEGEND",
          align=TextEntityAlignment.MIDDLE_LEFT, avoid=False)
        T(gname, LX0 + 15.0, yy, "NOTE", "LEGEND",
          align=TextEntityAlignment.MIDDLE_LEFT, avoid=False)
        T(str(cnt), LXR - COL_INSET, yy, "NOTE", "LEGEND",
          align=TextEntityAlignment.MIDDLE_RIGHT, avoid=False)
        yy -= 6.6

    # ---------- 灯具表
    ybot = stack("INSTRUMENT SCHEDULE", H_INS)
    yy = ybot + H_INS - 12.0 - 3.1
    for tkey in used_types:
        m = d["types"][tkey]
        positions = sorted({f["pos"] for f in rig if f["type"] == tkey})
        T(m["label"], LX0, yy, "NOTE", "LEGEND",
          align=TextEntityAlignment.MIDDLE_LEFT, avoid=False)
        T(str(counts[tkey]), LXR - COL_INSET, yy, "NOTE", "LEGEND",
          align=TextEntityAlignment.MIDDLE_RIGHT, avoid=False)
        T(" / ".join(positions), LX0 + 55.0, yy, "MICRO", "LEGEND",
          align=TextEntityAlignment.MIDDLE_LEFT, avoid=False, color=paper.GREY)
        yy -= 6.6

    # ---------- 图例
    ybot = stack("LEGEND  /  FIXTURE SYMBOLS", H_LEG)
    yy = ybot + H_LEG - 12.0 - LEG_PITCH / 2
    for tkey in used_types:
        m = d["types"][tkey]
        w_mm, h_mm = symbol_bbox(syms, tkey)
        sc = 7.6 / max(w_mm, h_mm, 1.0)
        ins = msp.add_blockref(f"SYM_{tkey}", (LX0 + 5.5, yy),
                               dxfattribs={"layer": "FIXTURE"})
        ins.dxf.xscale = ins.dxf.yscale = sc
        T(m["label"], LX0 + 13.0, yy + 2.8, "DEVICE", "LEGEND",
          align=TextEntityAlignment.MIDDLE_LEFT, avoid=False)
        T(str(counts[tkey]), LXR - COL_INSET, yy + 2.8, "DEVICE", "LEGEND",
          align=TextEntityAlignment.MIDDLE_RIGHT, avoid=False)
        T(m.get("role", ""), LX0 + 13.0, yy - 3.6, "COLOR", "LEGEND",
          align=TextEntityAlignment.MIDDLE_LEFT, avoid=False, color=paper.GREY)
        yy -= LEG_PITCH

    T(f"TOTAL {len(rig)} INSTRUMENTS", LXR - COL_INSET, ybot + 3.4, "MICRO",
      "LEGEND", align=TextEntityAlignment.MIDDLE_RIGHT, avoid=False,
      color=paper.GREY)

    # ======================================================== 图签
    pen.rect(TB0, TBY0, TB1, TBY1, "TITLEBLK")
    SPLIT = TB1 - 0.341 * (TB1 - TB0)
    TOPBAND = 20.0
    R_TOP = TBY1 - TOPBAND
    pen.line((SPLIT, TBY0), (SPLIT, TBY1), "TITLEBLK")
    pen.line((TB0, R_TOP), (SPLIT, R_TOP), "TITLEBLK")

    avail_w = (SPLIT - TB0) - 12.0
    _show_h = paper.FS["SHOW"]
    _w = lay_mod.estimate_width(meta["show"], _show_h)
    if _w > avail_w:
        _show_h = round(_show_h * avail_w / _w, 2)
    T(meta["show"], TB0 + 6.0, R_TOP + TOPBAND * 0.80, _show_h, "TB_TEXT",
      align=TextEntityAlignment.MIDDLE_LEFT, avoid=False, style="TTL")
    T(meta["playwright"], TB0 + 6.0, R_TOP + 4.0, "SUBTITLE", "TB_TEXT",
      align=TextEntityAlignment.MIDDLE_LEFT, avoid=False)

    # 子栏两格：标签与值同一行（参考图写法 "Scale : 1:25 @ A1"），同字号。
    # 旧版标签用 MICRO（em 2.5）而值用 FIELD（em 5.2），一大一小很突兀。
    ry = R_TOP
    _h_f = paper.FS["FIELD"]
    for k, v in (("DATE", meta["date"]),
                 ("SCALE", f"1:{int(SCALE)}  @  A1")):
        T(k, SPLIT + 3.0, ry - 5.6, _h_f, "TB_TEXT",
          align=TextEntityAlignment.MIDDLE_LEFT, avoid=False, color=paper.GREY)
        _lx = SPLIT + 3.0 + lay_mod.estimate_width(k, _h_f) + 2.4
        _vh = fit_h(v, _h_f, TB1 - _lx - 2.0)
        T(v, _lx, ry - 5.6, _vh, "TB_TEXT",
          align=TextEntityAlignment.MIDDLE_LEFT, avoid=False)
        ry -= 12.2
        pen.line((SPLIT, ry), (TB1, ry), "TITLEBLK")
    T(str(meta["sheet_no"]), (SPLIT + TB1) / 2, ry - 12.5, "SHEET_NO", "TB_TEXT",
      align=TextEntityAlignment.MIDDLE_CENTER, avoid=False, style="TTL")
    T(f"OF {meta['sheet_of']}", (SPLIT + TB1) / 2, ry - 30.0, "FIELD",
      "TB_TEXT", align=TextEntityAlignment.MIDDLE_CENTER, avoid=False)

    # 标签列宽按**实际字体**量，不要写死。
    # Hiragino 下 DESIGNER 只有 22.1mm，换 Arial 后是 27.0mm ——
    # 写死 30 会让值和标签撞在一起（verify 报 DIRECTOR × "I DON'T KNOW"）。
    _wide = max(lay_mod.estimate_width(k, paper.FS["TB_LABEL"])
                for k, _ in (("VENUE", 0), ("SHEET", 0), ("DIRECTOR", 0),
                             ("DESIGNER", 0), ("REVISION", 0)))
    LBLW = round(_wide + 6.0, 1)
    fields = [("VENUE", meta["venue"]),
              ("SHEET", f"{meta['sheet_title']}"),
              ("DIRECTOR", meta.get("director", "")),
              ("DESIGNER", meta.get("designer", "")),
              ("REVISION", f"{meta['revision']}   {meta['rev_note']}")]
    row_h = (R_TOP - TBY0) / len(fields)
    y = R_TOP
    for k, v in fields:
        T(k, TB0 + PAD_L, y - row_h / 2, "TB_LABEL", "TB_TEXT",
          align=TextEntityAlignment.MIDDLE_LEFT, avoid=False, color=paper.GREY)
        _vw = (SPLIT - TB0) - LBLW - 4.0
        _vh = fit_h(v, paper.FS["FIELD"], _vw)
        T(v, TB0 + LBLW, y - row_h / 2, _vh, "TB_TEXT",
          align=TextEntityAlignment.MIDDLE_LEFT, avoid=False)
        y -= row_h
        if y > TBY0 + 1.0:
            pen.line((TB0, y), (SPLIT, y), "TITLEBLK")

    # 方向标注
    T("^  UPSTAGE", *w2s(0, 8700), "COLOR", "NOTES",
      align=TextEntityAlignment.MIDDLE_CENTER, avoid=False)
    T("v  AUDIENCE", *w2s(-7500, -4200), "COLOR", "NOTES",
      align=TextEntityAlignment.MIDDLE_LEFT, avoid=False)
    T("DATUM: STAGE FLOOR = +/-0", *w2s(7500, -4200), "COLOR", "NOTES",
      align=TextEntityAlignment.MIDDLE_RIGHT, avoid=False)

    # ======================================================== 排版求解
    try:
        lay.resolve()
        rep = lay.report()
        print(f"  排版：{rep['labels']} 标签 / {rep['obstacles']} 障碍 / "
              f"{rep['moved']} 挪动 / {rep['soft_hits']} 压图形(已接受)")
        for ent, lb, align in text_entities:
            if lb.moved:
                ent.set_placement(lb.final, align=align)
    except lay_mod.LayoutError as e:
        print("\n" + "=" * 60)
        print(" 排版失败 —— 不出图")
        print("=" * 60)
        print(e)
        raise SystemExit(1)

    # ---- 真实包围盒收尾：估算避让后仍可能残留少量压字，用实测再修一轮
    # 图签里的字是**手工定位**的（照参考图网格），不能交给避让器乱挪，
    # 否则剧名/字段会互相推挤、整个图签塌掉。只对图面上的文字做收尾。
    # ★ 收尾避让器只许动**图面标注**（灯位、标高、布景名、光区号）。
    # 图签、右栏表格、分区号都是手工按网格排的，一旦被它挪动就会
    # 互相挤压 —— 实测曾把 LEGEND 标题挪到 Fresnel 那一行上。
    # ★ FIXTURE_TXT 必须排除！
    #   灯具的 L-code / 灯具号是**逐台手工定位**的（贴灯体前端），
    #   白底遮罩也是按那个位置算好尺寸画的。
    #   收尾器一旦把它们当普通文字挪走，字就跑到白底框外面去了 ——
    #   图上看到的就是「白底框在 A 处、字在 B 处、线从字中间穿过」。
    #   这就是「L-code 压根没有白底」的真正原因，不是框没画，是字被挪走了。
    _fixed_layers = {"TB_TEXT", "LEGEND", "NOTES", "GRIDTEXT", "TITLEBLK",
                     "FIXTURE_TXT"}
    all_texts = [(e, 5) for e in msp.query("TEXT")
                 if e.dxf.layer not in _fixed_layers]
    # 大字号给高优先级（不肯动）
    for e in msp.query("TEXT"):
        if e.dxf.layer in _fixed_layers:
            continue
        hh = e.dxf.height or 2
        if hh >= 10:
            all_texts = [(x, 20 if x is e else pr) for x, pr in all_texts]
        elif hh >= 5:
            all_texts = [(x, 12 if x is e else pr) for x, pr in all_texts]
    # 关键：把灯具标注块的占位传给收尾器。不传的话，它只知道文字，
    # 会把被挤动的字推进 LBL_* 块里 —— verify.py 随后报重叠。
    left = lay_mod.resolve_real(all_texts,
                                hard=[hb for hb, _t in lay.hard],
                                safe_area=SAFE)
    if left:
        print(f"  警告：仍有 {len(left)} 对文字压叠（已尽力微调）: {left[:5]}")
    else:
        print("  真实包围盒复核：零压字")

    # ======================================================== 输出
    stem = f"LX_plan_{scene}" if scene else "LX_plan"
    base = os.path.join(outdir, stem)

    import export as _export
    _export.draw_sheet(doc, msp, base, SHEET_W, SHEET_H)
    _ok, _detail = _export.check_scale(base + ".pdf", SHEET_W, SHEET_H)
    print(f"  PDF: {base}.pdf")
    print(f"        {'1:1 校验通过' if _ok else '比例错误: ' + _detail}")
    if not _ok:
        raise SystemExit(f"导出比例错误，拒绝出图：{_detail}")

    import fonts as _fonts
    _fonts.make_portable(doc)
    doc.saveas(base + ".dxf")
    # ---- 可移植性后处理：DXF 必须能被 Vectorworks / AutoCAD 打开
    #   ezdxf 的 $EXTMIN/$EXTMAX 在 saveas 时会被重置成哨兵值（1e+20），
    #   必须在文件写完之后做文本级修补。详见 src/dxfix.py
    import dxfix as _dxfix
    _rep = _dxfix.fix_dxf(base + ".dxf", SHEET_W, SHEET_H, verbose=False)
    if _rep["problems"]:
        for _p in _rep["problems"]:
            print(f"  DXF [WARN] {_p}")
    print("  DXF:", base + ".dxf")
    return base


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("yaml", nargs="?", default="rig.yaml")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--out", default="out")
    ap.add_argument("--scene", default=None, help="场景 id（见 data/scenes.yaml）")
    a = ap.parse_args()

    d = yaml.safe_load(open(a.yaml, encoding="utf-8"))
    errs, warns = qc.check_rig(d)
    for w in warns:
        print("  WARN ", w)
    if errs:
        print("\n校验失败，未出图：")
        for e in errs:
            print("  ERROR", e)
        sys.exit(1)
    print(f"校验通过：{len(d['fixtures'])} 台灯具，{len(warns)} 条警告")
    if not a.check:
        render(d, a.out, a.scene)
