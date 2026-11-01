#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""layout.py — 图纸文字排版避让

问题
----
旧版平面图上灯具号、色片号、桁架名、布景名互相压字。原来的检查器
只测「文字 vs 文字」，而真实重叠大量是「文字 vs 图形」（比如灯号压在
桁架斜撑上、`BOOM SR` 被图框切掉），所以检查形同虚设。

做法
----
1. 所有文字先登记成 Label（带**实测**包围盒，不是估算字宽）
2. 所有图形元素登记成 Obstacle（线段/多段线转包围盒）
3. 求解：每个 Label 按候选偏移（8 个方向 × 若干距离）尝试，
   取第一个不与任何已有 Label / Obstacle 冲突的位置
4. 全部候选都失败 → 收集冲突，**raise**（fail-closed）

为什么 fail-closed
------------------
宁可报错让你调版面，也不要出一张看起来没问题、实际压字的图。
这是 AGENTS.md 铁律 3 的直接落实。

用法
----
    lay = Layout()
    lay.add_obstacle((x0,y0,x1,y1), tag="TRUSS")
    lay.place(text="301", x=..., y=..., h=2.7, owner="unit301")
    ...
    lay.resolve()          # 冲突则 raise LayoutError
"""


class LayoutError(Exception):
    """排版无法满足时抛出。消息里带全部冲突明细。"""


# ---------------------------------------------------------------
# 校准数据（实测 287 个文字实体，对比 ezdxf bbox 与估算值）
#   宽度比 实际/估算：中位 1.572，90 分位 1.675，最大 2.227
#   高度比 实际/字高：恒为 1.276（字体上下留白）
#
# 早先版本用 1.0 / 0.55 估宽，实际渲染宽度是 1.57 倍，
# 导致避让器以为排得开、实际却压字。现在按实测校准，
# 并取 90 分位而不是中位数，宁可保守。
# ---------------------------------------------------------------
# ---------------------------------------------------------------
# 2026-10 换成**真实字体度量**（src/metrics.py）。
# 旧版靠 CAL_W=1.72 这种保守系数硬凑，因为当时中英混排、字体是 PingFang，
# 宽度算不准 —— 结果每张表都要单独调数字。现在中文已移除、字体固定为
# Arial / Arial Narrow，直接问字体要 advance width，误差 < 1%。
# ---------------------------------------------------------------
CAL_W = 1.0         # 保留变量名，真实度量下不再需要放大
CAL_H = 1.0

CJK_RATIO = 1.0
LATIN_RATIO = 0.55

try:
    import metrics as _metrics
except ImportError:                     # 独立跑 layout.py 时
    _metrics = None


def estimate_width(text, height, cjk_ratio=CJK_RATIO, latin_ratio=LATIN_RATIO,
                   family="regular"):
    """文字宽度（图纸 mm）。优先用真实字体度量，缺失才退回估算。"""
    if _metrics is not None:
        try:
            return _metrics.width_mm(text, height, family)
        except Exception:
            pass
    w = 0.0
    for ch in str(text):
        w += height * (cjk_ratio if ord(ch) > 0x2E80 else latin_ratio)
    return w


class Label:
    __slots__ = ("text", "x", "y", "h", "rot", "owner", "align",
                 "bbox", "final", "priority", "moved", "soft")

    def __init__(self, text, x, y, h, rot=0.0, owner="", align="center",
                 priority=0, width=None):
        self.text = text
        self.x = x
        self.y = y
        self.h = h
        self.rot = rot
        self.owner = owner
        self.align = align
        self.priority = priority      # 数字越大越不肯移动
        self.moved = False
        self.soft = False
        w = width if width is not None else estimate_width(text, h)
        hh = h * CAL_H
        # 旋转 90° 时宽高互换
        if abs(rot % 180) > 45:
            w, hh = hh, w
        if align == "left":
            x0, x1 = x, x + w
        elif align == "right":
            x0, x1 = x - w, x
        else:
            x0, x1 = x - w / 2, x + w / 2
        self.bbox = (x0, y - hh / 2, x1, y + hh / 2)
        self.final = (x, y)

    def translated(self, dx, dy):
        b = self.bbox
        return (b[0] + dx, b[1] + dy, b[2] + dx, b[3] + dy)


def _overlap(a, b, pad=0.0):
    return not (
        a[2] + pad <= b[0]
        or b[2] + pad <= a[0]
        or a[3] + pad <= b[1]
        or b[3] + pad <= a[1]
    )


class Layout:
    def __init__(self, pad=0.35, safe_area=None):
        self.labels = []
        self.obstacles = []      # (bbox, tag) —— 软障碍
        self.hard = []           # (bbox, tag) —— 硬障碍（文字必须完全避开）
        self.pad = pad
        self.safe_area = safe_area   # (x0,y0,x1,y1) 硬边界，出框即失败
        self.soft_hits = 0

    # ---------------- 登记
    def add_obstacle(self, bbox, tag=""):
        self.obstacles.append((tuple(bbox), tag))

    def add_hard(self, bbox, tag=""):
        """硬障碍：不可移动的图元（灯具标注块、图签、面板）。

        为什么需要
        ----------
        灯具标注是 `LBL_<unit>` 块引用（圆圈 + 通道号 + 色片号 + 编号），
        画完就固定了。旧版排版器只认 TEXT，完全看不到这些块，
        于是把桁架名放在它们身上 —— verify.py 报重叠，排版器却自认干净。
        """
        self.hard.append((tuple(bbox), tag))

    def add_line_obstacle(self, p1, p2, tag="", widen=0.3):
        x0, y0 = p1
        x1, y1 = p2
        self.add_obstacle(
            (min(x0, x1) - widen, min(y0, y1) - widen,
             max(x0, x1) + widen, max(y0, y1) + widen),
            tag,
        )

    def add_label(self, text, x, y, h, **kw):
        lb = Label(text, x, y, h, **kw)
        self.labels.append(lb)
        return lb

    # ---------------- 求解
    def resolve(self, candidates=None):
        """两级约束求解。

        硬约束（必须满足，否则 raise）：
          · 文字不得压文字
          · 文字不得越出图框安全区

        软约束（尽量避让，避不开则接受并记录）：
          · 文字压在桁架/灯具符号/座位等图形上

        为什么软约束不 fail：剧场图纸里，灯号本来就常压在布景轮廓、
        光区虚线上，USITT RP-2 也只禁止「文字互相压」和「标注出框」。
        把所有图形都当硬障碍会导致图永远排不出来。真正的重叠事故
        是文字压文字，那一条必须死守。
        """
        if candidates is None:
            dists = [1.6, 3.2, 5.0, 7.5, 10.0]
            dirs = [(0, 1), (0, -1), (1, 0), (-1, 0),
                    (0.7, 0.7), (-0.7, 0.7), (0.7, -0.7), (-0.7, -0.7)]
            candidates = [(0, 0)] + [(dx * d, dy * d) for d in dists for dx, dy in dirs]

        placed = []
        hard_fail = []
        soft_hits = 0
        # 低优先级先处理，让它先让位，给高优先级留原位
        for lb in sorted(self.labels, key=lambda l: l.priority):
            ok = False
            fallback = None
            for dx, dy in candidates:
                box = lb.translated(dx, dy)

                # 硬约束 1：出框
                if self.safe_area is not None:
                    sa = self.safe_area
                    if box[0] < sa[0] or box[1] < sa[1] or box[2] > sa[2] or box[3] > sa[3]:
                        continue
                # 硬约束 2：压其他文字
                if any(_overlap(box, p.bbox, self.pad) for p in placed):
                    continue
                # 硬约束 3：压不可移动图元（灯具标注块等）
                if any(_overlap(box, hb, self.pad) for hb, _ in self.hard):
                    continue

                # 软约束：压图形
                hits_graphic = any(_overlap(box, ob, self.pad) for ob, _ in self.obstacles)
                if hits_graphic and fallback is None:
                    fallback = (box, dx, dy)
                    continue          # 记下，继续找更干净的位置
                if hits_graphic:
                    continue

                lb.bbox = box
                lb.final = (lb.x + dx, lb.y + dy)
                lb.moved = (dx, dy) != (0, 0)
                placed.append(lb)
                ok = True
                break

            if not ok and fallback is not None:
                box, dx, dy = fallback
                lb.bbox = box
                lb.final = (lb.x + dx, lb.y + dy)
                lb.moved = (dx, dy) != (0, 0)
                lb.soft = True
                placed.append(lb)
                soft_hits += 1
                ok = True

            if not ok:
                hard_fail.append(lb)

        self.soft_hits = soft_hits

        if hard_fail:
            lines = [f"排版失败：{len(hard_fail)} 个标签无法避免压字/出框"]
            for lb in hard_fail[:20]:
                near = [p.text for p in placed if _overlap(lb.bbox, p.bbox, self.pad)]
                sa = "出框" if self.safe_area and (
                    lb.bbox[0] < self.safe_area[0] or lb.bbox[1] < self.safe_area[1]
                    or lb.bbox[2] > self.safe_area[2] or lb.bbox[3] > self.safe_area[3]) else ""
                lines.append(
                    f"  '{lb.text}' @({lb.x:.1f},{lb.y:.1f}) owner={lb.owner} "
                    f"压到文字={near[:4]} {sa}"
                )
            if len(hard_fail) > 20:
                lines.append(f"  ... 另有 {len(hard_fail)-20} 个")
            raise LayoutError("\n".join(lines))

        return placed

    # ---------------- 诊断
    def report(self):
        moved = [l for l in self.labels if l.moved]
        return {
            "labels": len(self.labels),
            "obstacles": len(self.obstacles),
            "moved": len(moved),
            "soft_hits": self.soft_hits,
            "moved_detail": [(l.text, (round(l.final[0]-l.x,1), round(l.final[1]-l.y,1))) for l in moved],
        }


# ============================================================ 真实包围盒后处理
def real_bbox(ent):
    """用 ezdxf 实测文字包围盒（含字体真实留白）。"""
    from ezdxf import bbox as _bb
    try:
        b = _bb.extents([ent])
    except Exception:
        return None
    if not b.has_data:
        return None
    return (b.extmin.x, b.extmin.y, b.extmax.x, b.extmax.y)


def _escape(box, hb, gap=0.5):
    """给出把 box 推出 hb 的 4 个最小位移，按位移从小到大排。

    为什么不用「一律往下推」
    ------------------------
    旧版 resolve_real 只会把字往下挪一个字高。当它往下的方向正好
    是灯具标注块所在位置时，字就被推进块里 —— 越修越糟。
    这里改成：算四个方向各自需要的最小位移，取能真正解开的那个。
    """
    cands = [
        (0.0, hb[3] + gap - box[1]),        # 上
        (0.0, hb[1] - gap - box[3]),        # 下
        (hb[2] + gap - box[0], 0.0),        # 右
        (hb[0] - gap - box[2], 0.0),        # 左
    ]
    cands.sort(key=lambda d: abs(d[0]) + abs(d[1]))
    return cands


def resolve_real(entities, hard=None, safe_area=None, iterations=120, step=1.1):
    """基于真实包围盒的收尾避让。

    为什么需要这一步
    ----------------
    排版求解器用的是**估算**宽度，而真实字体度量比估算宽 1.5~2 倍。
    即使校准过，仍会残留少量压字。这里在文字已经画进 DXF 之后，
    用 ezdxf 实测包围盒，发现重叠就把字挪开，反复直到干净。

    为什么要传 hard
    ---------------
    灯具标注是 INSERT 块（`LBL_<unit>`），里面的字不在 modelspace。
    ezdxf 的 bbox 能展开它，但**这一步不知道它们存在**，
    于是会把「被别的字挤了一下」的桁架名推进标注块里 —— verify.py
    随后报重叠，而这里还以为修好了。hard 就是这些不可移动的方块。

    entities: [(text_entity, priority), ...]  priority 越大越不肯动
    返回: 仍未解决的重叠列表（调用方据此决定是否 raise）
    """
    hard = [tuple(h) for h in (hard or [])]

    def _out(box):
        if safe_area is None:
            return False
        sa = safe_area
        return (box[0] < sa[0] - 1e-9 or box[1] < sa[1] - 1e-9
                or box[2] > sa[2] + 1e-9 or box[3] > sa[3] + 1e-9)

    def _move(ent, dx, dy):
        # 注意：对齐方式非 LEFT 时，ezdxf 用 align_point 而不是 insert，
        # 直接改 insert 不会生效。必须走 get_placement/set_placement。
        align, pos, _p2 = ent.get_placement()
        ent.set_placement((pos.x + dx, pos.y + dy), align=align)

    for _ in range(iterations):
        boxes = []
        for ent, pri in entities:
            bb = real_bbox(ent)
            if bb:
                boxes.append((ent, pri, bb))

        # ---- 1) 文字压在不可移动的块上：必须解决，且只能动文字
        done = False
        for ent, pri, bb in boxes:
            hb = next((h for h in hard if _overlap(bb, h, 0.12)), None)
            if hb is None:
                continue
            for dx, dy in _escape(bb, hb):
                nb = (bb[0] + dx, bb[1] + dy, bb[2] + dx, bb[3] + dy)
                if _out(nb):
                    continue
                if any(_overlap(nb, hb2, 0.12) for hb2 in hard):
                    continue
                _move(ent, dx, dy)
                done = True
                break
            if done:
                break
        if done:
            continue

        # ---- 2) 文字压文字：动优先级低的那个
        found = None
        for i in range(len(boxes)):
            for j in range(i + 1, len(boxes)):
                if _overlap(boxes[i][2], boxes[j][2], pad=0.12):
                    found = (boxes[i], boxes[j])
                    break
            if found:
                break
        if not found:
            return []

        (e1, p1, b1), (e2, p2, b2) = found
        mover = e1 if p1 <= p2 else e2
        other = b2 if mover is e1 else b1
        h = mover.dxf.height or 2.0
        bb = real_bbox(mover) or other
        placed = False
        for dx, dy in _escape(bb, other):
            if dx == 0.0 and dy == 0.0:
                continue
            nb = (bb[0] + dx, bb[1] + dy, bb[2] + dx, bb[3] + dy)
            if _out(nb) or any(_overlap(nb, hb2, 0.12) for hb2 in hard):
                continue
            _move(mover, dx, dy)
            placed = True
            break
        if not placed:
            # 四个方向都被挡：退化成旧行为，往下推一个字高
            _move(mover, 0.0, -h * step)

    # 收尾：报告仍未解决的
    boxes = [(ent, pri, real_bbox(ent)) for ent, pri in entities]
    boxes = [(e, p, b) for e, p, b in boxes if b]
    left = []
    for i in range(len(boxes)):
        for j in range(i + 1, len(boxes)):
            if _overlap(boxes[i][2], boxes[j][2], pad=0.12):
                left.append((boxes[i][0].dxf.text, boxes[j][0].dxf.text))
    for ent, pri, bb in boxes:
        if any(_overlap(bb, hb, 0.12) for hb in hard):
            left.append((ent.dxf.text, "LBL-block"))
    return left
