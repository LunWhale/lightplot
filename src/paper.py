#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""paper.py — 图纸视觉语法常量（单一定义来源）

这些数字是从 NIDA《EX MACHINA》A1 图纸（XMACH_LXGRID_JC_v5.pdf）实测反推的，
不是拍脑袋。测量方法见 docs/07-drafting-language.md。

参考图实测结果
--------------
线宽（pt → mm），共 10 级，动态范围 28:1：
    0.070pt = 0.025mm   ×108
    0.140pt = 0.049mm   ×842   ← 桁架、座位
    0.240pt = 0.085mm   ×8
    0.290pt = 0.102mm   ×22
    0.360pt = 0.127mm   ×28
    0.430pt = 0.152mm   ×476   ← 主体线
    0.500pt = 0.176mm   ×119
    0.580pt = 0.205mm   ×13
    0.720pt = 0.254mm   ×281   ← 灯具符号轮廓
    2.020pt = 0.713mm   ×45    ← 图框

颜色：只有 2 种 —— 黑 (0,0,0) ×1934，深灰 (0.24,0.24,0.24) ×8。
      没有任何彩色。层级完全靠线宽与字号表达。

填充：1492 处白色填充。这是「断裂」效果的真正实现方式 ——
      符号与文字用白底把后面的线盖掉，而不是真的把线裁断。

字号（pt → mm）：
    51.97pt = 18.3mm  图号「1」
    39.92pt = 14.1mm  剧名「EX MACHINA」
    25.00pt =  8.8mm  分区号「1」「2」「A」「H」
    24.79pt =  8.8mm  构件名「Truss 1」（且沿构件旋转）
    24.00pt =  8.5mm  位置名「LX」「FOH 1」
    18.00pt =  6.3mm  图签字段
    12.04pt =  4.2mm  尺寸数「0.5」「3.5」
    12.00pt =  4.2mm  设备名「SPEAKER」「LX 1.5」
     9.92pt =  3.5mm  通道号（在圆圈内）
     8.93pt =  3.1mm  色片号「L009」
"""

# ============================================================ 线宽（mm）
# ezdxf 的 lineweight 单位是 1/100 mm，所以值要 ×100
LW = {
    "HAIR":   0.025,   # 尺寸线、辅助、极细
    "TRUSS":  0.049,   # 桁架、座位、光区框
    "FINE":   0.085,   # 符号内部细节
    "THIN":   0.127,   # 布景细节、引线
    "MED":    0.152,   # 主体线（布景轮廓、座位）
    "OBJECT": 0.176,   # 设备轮廓
    "SYMBOL": 0.254,   # 灯具符号轮廓 ★
    "HEAVY":  0.350,   # 剖切线、重要构件
    "FRAME":  0.713,   # 图框
}


# DXF 只接受这些固定线宽值（单位 1/100 mm）
DXF_LW_VALUES = [0, 5, 9, 13, 15, 18, 20, 25, 30, 35, 40, 50, 53, 60, 70,
                 80, 90, 100, 106, 120, 140, 158, 200, 211]


def lw(name):
    """取合法的 DXF 线宽值（吸附到最近的枚举值）。

    DXF 规范只允许固定的一组线宽，任意浮点数会抛 DXFValueError。
    这里吸附，但保持 paper.LW 里的真实毫米值作为设计意图记录。
    """
    target = LW[name] * 100
    return min(DXF_LW_VALUES, key=lambda v: abs(v - target))


# ============================================================ 字号（mm，图纸高度）
# 层级：标题 → 构件 → 位置 → 设备 → 编号 → 色片/通道 → 说明
# 2026-10 复测：直接用 pymupdf 读参考图的 text span 字号（pt × 25.4/72），
# 得到的是「图纸上真实毫米高度」，比之前的目测值大一整档。
#   14.84  图号大数字
#   11.44  剧名 EX MACHINA
#    8.86  桁架名 Truss 1..4 / Truss 1 - OP / - PS（41 处）
#    8.50  LX 1..LX 6、FOH 1/2（LXGRID 图）
#    6.35  图框分区号 1-12 / A-H（95 处，之前我只用了 2.5mm）
#    5.71  图签图纸名 LX Truss Plan
#    5.16  图签字段（Scale : / Date : / 人名 / 1:25 @ A1）
#    4.9   Typical / Light / 面板小标题
#    4.25  图例灯具名、说明正文、+1250 标高（88 处）
#    3.50  通道号（圆圈内）
#    3.11  色片号 L711
#    1.36  RGB 这类用户字段
# 结论：参考图**正文就是 4.2mm 一档**，我原来全表小了 40%，这是「字太小」的根因。
# ⚠ 单位陷阱（2026-10 修正）
#   参考 PDF 里 pymupdf 报告的 span size 是 **em**，而 DXF TEXT 的 height 是 **cap**。
#   Arial: cap/em = 1467/2048 = 0.7163。
#   之前把实测 em 直接当 cap 用，全图文字放大了 1/0.7163 = 1.40 倍 ——
#   这就是「雷霆大文字」的根因。下表已全部换算成 cap。
#
#   ★ 系数只在 metrics.py 定义一次，这里 import 过来。曾经 paper / metrics /
#     pdfout 各写一份 0.7163 —— 三处副本必然漂移，且漂移时只有一处图纸会错。
from metrics import EM_TO_CAP  # noqa: F401  （re-export：paper.EM_TO_CAP 仍可用）

FS = {
    # 图签
    "SHEET_NO":   10.63,  # 大图号（实测 em 14.84）
    "SHOW":        8.19,  # 剧名（实测 em 11.44）
    "SHEET_TOTAL": 8.22,  # 总图数（实测 em 11.47）
    # 图面
    "ZONE":        6.35,  # 光区号（实测 em 8.86）
    "COMPONENT":   6.35,  # 桁架名（实测 em 8.81–8.86，41 处）
    "POSITION":    6.09,  # 位置名（实测 em 8.50）
    "BORDER":      4.55,  # 图框分区号（实测 em 6.35，95 处）
    "SUBTITLE":    4.09,  # 图纸名（实测 em 5.71）
    "FIELD":       3.70,  # 图签字段值（实测 em 5.11–5.18）
    "TB_LABEL":    3.70,  # 图签字段标签
    "LEGEND_HDR":  3.51,  # 图例分类标题（实测 em 4.89–4.92）
    "DEVICE":      3.04,  # 图例灯具名（实测 em 4.25）
    "NOTE":        3.04,  # 说明正文（实测 em 4.25）
    "DIM":         3.03,  # 标高 / 尺寸（实测 em 4.23）
    "UNIT":        2.51,  # 通道号（圆圈内，实测 em 3.50）
    "COLOR":       2.24,  # 色片号（实测 em 3.11–3.15）
    "MICRO":       1.80,  # 最小注释
}

# ============================================================ 颜色
# 参考图只有黑色。层级靠线宽，不靠颜色。
# ★ ACI 色号在 CAD 里是"随背景翻转"的：
#   ACI 7 = 白底显黑、黑底显白。
#   我们用它做白底遮罩，结果在 Vectorworks 白底上全渲染成**黑色**，
#   整个图黑乎乎（用户实测）。
#   DXF R2004+ 支持 true_color（24 位真彩），用它才是确定的颜色。
#   BLACK 保留 ACI 7（线要随背景走，这是对的）；
#   WHITE 必须用真彩 0xFFFFFF，不能依赖 ACI。
BLACK = 250      # ACI 250 深灰（比纯黑柔和，参考图实测 0.0 黑）
GREY = 8         # 只用于辅助信息（尺寸、光区），且要极少量
WHITE = 7        # 仅用于图层定义（图层色随背景）
WHITE_RGB = 0xFFFFFF   # 真彩白 —— 遮罩填充必须用这个
BLACK_RGB = 0x000000   # 真彩黑


# ============================================================ 图框
# 参考图实测：外框贴纸边 (0,0)-(841,594)，内框 (20,20)-(821,574)。
# 改这个值要同步 render.py 的 M / IN。
FRAME_MARGIN = 0.0
FRAME_INNER = 20.0

# ============================================================ 图层
# (名称, 颜色, 线型, 线宽键)
LAYERS = [
    ("BORDER",   BLACK, "Continuous", "FRAME"),
    ("GRID",     BLACK, "Continuous", "HAIR"),
    ("GRIDTEXT", BLACK, "Continuous", "THIN"),
    ("STAGE",    BLACK, "Continuous", "HEAVY"),
    ("SET",      BLACK, "Continuous", "MED"),
    ("SET_DASH", GREY,  "DASHED",     "TRUSS"),
    ("SET_FILL", WHITE, "Continuous", "HAIR"),   # 布景白底遮罩
    ("TRUSS",    BLACK, "Continuous", "TRUSS"),  # 桁架：极细双线
    ("TRUSS_FILL", WHITE, "Continuous", "HAIR"), # 桁架白底遮罩
    ("PIPE",     BLACK, "Continuous", "TRUSS"),  # LX/SOUND 管线：空心长条
    ("PIPE_FILL", WHITE, "Continuous", "HAIR"),  # 管线白底
    ("FIXTURE",   BLACK, "Continuous", "SYMBOL"),# 灯具符号轮廓
    ("FIXTURE_FILL", WHITE, "Continuous", "HAIR"),# 符号白底遮罩
    ("FIXTURE_TXT", BLACK, "Continuous", "THIN"),
    ("BEAM",     GREY,  "DASHED",     "TRUSS"),
    ("DIM",      BLACK, "Continuous", "FINE"),
    ("LEADER",   BLACK, "Continuous", "HAIR"),
    ("SEAT",     BLACK, "Continuous", "TRUSS"),
    ("ZONE",     GREY,  "DASHDOT",    "TRUSS"),
    ("TITLEBLK", BLACK, "Continuous", "FRAME"),
    ("TB_TEXT",  BLACK, "Continuous", "THIN"),
    ("NOTES",    BLACK, "Continuous", "THIN"),
    ("LEGEND",   BLACK, "Continuous", "THIN"),
    ("ACCENT",   BLACK, "Continuous", "HEAVY"),  # 剖切线（黑色，不是红色）
    ("MARK",     BLACK, "Continuous", "FINE"),   # 圆圈编号
    ("MASK",     WHITE, "Continuous", "HAIR"),   # 通用白底遮罩
]


# ============================================================ 绘制顺序
# 后画的盖住先画的。白底遮罩必须紧跟它要保护的对象之前。
DRAW_ORDER = [
    "GRID", "GRIDTEXT",
    "ZONE",
    "SEAT",
    "STAGE",
    "SET_FILL", "SET", "SET_DASH",
    "TRUSS_FILL", "TRUSS",
    "PIPE_FILL", "PIPE",
    "BEAM",
    "FIXTURE_FILL", "FIXTURE",
    "MASK", "MARK",
    "LEADER", "FIXTURE_TXT",
    "DIM",
    "BORDER", "TITLEBLK", "TB_TEXT", "NOTES", "LEGEND",
    "ACCENT",
]
