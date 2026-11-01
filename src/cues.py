#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cues.py — Cue Sheet 生成与**交叉校验**

为什么要有这个文件
------------------
任务书 §5 说得很清楚：四份交付物（平面图 / Cue Sheet / 标注剧本 / 色片表）
之间的**编号与名称必须完全对应**，抽查的就是这个一致性。

手工维护一份 Cue Sheet，几乎必然出现「Q7 写了 305 号灯，但图里没有 305」。
所以这里把它做成代码：Cue Sheet 里的每一个灯具号、每一个色片号，
都必须能在 data/rig.yaml 里查到；查不到就**拒绝出表**（和 qc.py 一样失败即停）。

用法
----
    python3 src/cues.py                  # 校验 + 输出 CSV
    python3 src/cues.py --report         # 校验 + 打印到终端
"""
import csv
import os
import re
import sys

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


# ============================================================ 解析
# lanterns 字段的写法：「201-202 (L132) @48%, 101-106 (L201) @45%, 902 (L103) @70%」
# 也可能是「401 (L711) @45% 单侧, 601-603 (L156) @8%」
_SEG = re.compile(r"([0-9]{1,4}(?:\s*-\s*[0-9]{1,4})?)\s*\(([^)]*)\)")

def parse_lanterns(s):
    """把 lanterns 字段拆成 [(unit_list, gel), ...]。

    unit_list 是展开后的整数列表；gel 是字符串（可能是 OPEN）。
    """
    out = []
    for m in _SEG.finditer(s or ""):
        rng, gel = m.group(1), m.group(2).strip()
        if "-" in rng:
            a, b = [int(x) for x in rng.split("-")]
            units = list(range(a, b + 1))
        else:
            units = [int(rng)]
        out.append((units, gel))
    return out


def parse_qno(q):
    """Q 编号转可比较的数值。'0.5' -> 0.5，'12' -> 12.0"""
    return float(str(q))


# ============================================================ 校验
def check(d, cd):
    """返回 (errors, warnings)。errors 非空 → 拒绝出表。"""
    errs, warns = [], []
    cues = cd.get("cues") or []
    if not cues:
        errs.append("cues.yaml contains no cues")
        return errs, warns

    fixtures = {int(f["unit"]): f for f in d["fixtures"]}
    gels = {g["gel"] for g in d.get("gels", [])}
    prefix = (cd.get("meta") or {}).get("prefix", "LX")

    # ---- 1. 编号：不重号、不跳号（允许小数）、必须递增
    seen = {}
    prev = None
    for i, c in enumerate(cues):
        q = c.get("q")
        if q is None:
            errs.append(f"cue #{i + 1} has no q number")
            continue
        key = str(q)
        if key in seen:
            errs.append(f"{prefix} Q{key} duplicated (entries {seen[key] + 1} and {i + 1})")
        seen[key] = i
        v = parse_qno(q)
        if prev is not None and v <= prev:
            errs.append(f"{prefix} Q{key} is not increasing (previous is Q{cues[i - 1]['q']})")
        prev = v

    # ---- 2. 必填列（任务书 §6.2 加粗的 6 列）
    for c in cues:
        for k, label in (("q", "Q No."), ("cue_point", "Cue Point"),
                         ("state", "Lighting State"), ("lanterns", "Lanterns/Gel"),
                         ("fade", "Fade Time")):
            if not str(c.get(k) or "").strip():
                errs.append(f"{prefix} Q{c.get('q')} is missing {label}")

    # ---- 3. 灯具号必须存在，且色片必须与该灯在 rig.yaml 里的一致
    for c in cues:
        q = c.get("q")
        segs = parse_lanterns(c.get("lanterns", ""))
        if not segs:
            errs.append(f"{prefix} Q{q} lanterns field yields no fixtures")
            continue
        for units, gel in segs:
            if gel not in gels:
                errs.append(f"{prefix} Q{q} uses undefined gel {gel}")
            for u in units:
                if u not in fixtures:
                    errs.append(f"{prefix} Q{q} references non-existent lantern {u}")
                    continue
                real = fixtures[u].get("gel")
                if gel and gel != real:
                    # OPEN 特殊：mover/follow 在 rig.yaml 里就是 OPEN
                    errs.append(
                        f"{prefix} Q{q}: lantern {u} is listed as {gel} "
                        f"but rig.yaml has {real} — drawing and sheet disagree")

    # ---- 3b. cue 点必须钉在可执行事件上（任务书 §6.5）
    # 舞台监督要能在那一瞬间喊 Go，所以「大约」「中途」这类都不合格。
    VAGUE = ["about", "around", "sometime", "mid-scene", "roughly",
             "approximately", "at some point"]
    for c in cues:
        cp = str(c.get("cue_point") or "")
        for v in VAGUE:
            if v in cp.lower():
                errs.append(f"{prefix} Q{c.get('q')} cue point is too vague "
                            f"(contains {v!r}): {cp[:40]}")

    # ---- 4. 覆盖性：每台灯至少被一个 cue 用到（否则买了不用）
    used = set()
    for c in cues:
        for units, _gel in parse_lanterns(c.get("lanterns", "")):
            used.update(units)
    idle = sorted(set(fixtures) - used)
    if idle:
        warns.append(f"{len(idle)} lanterns are never used by any cue: {idle[:12]}")

    # ---- 5. 未核对提醒（诚实性）
    if not (cd.get("meta") or {}).get("verified"):
        warns.append("cues.yaml has verified: false — cue points not yet checked against the production script")

    return errs, warns


# ============================================================ 输出
HEADER = ["Q", "ACT / SC", "CUE POINT (TRIGGER)", "LIGHTING STATE",
          "LANTERNS / GEL", "FADE", "NOTES"]


def _one_line(s):
    return " ".join(str(s or "").split())


def to_csv(d, cd, outdir="out"):
    os.makedirs(outdir, exist_ok=True)
    p = os.path.join(outdir, "cue_sheet.csv")
    prefix = (cd.get("meta") or {}).get("prefix", "LX")
    with open(p, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        w.writerow(HEADER)
        for c in cd["cues"]:
            w.writerow([f"{prefix} Q{c['q']}", _one_line(c.get("act")),
                        _one_line(c.get("cue_point")),
                        _one_line(c.get("state")),
                        _one_line(c.get("lanterns")),
                        _one_line(c.get("fade")),
                        _one_line(c.get("notes"))])
    return p


def report(d, cd):
    prefix = (cd.get("meta") or {}).get("prefix", "LX")
    print("\n=== CUE SHEET / 灯光 cue 表 ===")
    print(f"{len(cd['cues'])} cues ({prefix} Q{cd['cues'][0]['q']} – "
          f"{prefix} Q{cd['cues'][-1]['q']})")
    print("-" * 78)
    for c in cd["cues"]:
        print(f"\n{prefix} Q{c['q']:<5} [{_one_line(c.get('act'))}]")
        print(f"  TRIGGER  {_one_line(c.get('cue_point'))}")
        print(f"  STATE    {_one_line(c.get('state'))[:150]}")
        print(f"  LANTERNS {_one_line(c.get('lanterns'))}")
        print(f"  FADE     {_one_line(c.get('fade'))}")
        n = _one_line(c.get("notes"))
        if n:
            print(f"  NOTES    {n[:150]}")


def main():
    rig_p = os.path.join(ROOT, "data", "rig.yaml")
    cue_p = os.path.join(ROOT, "data", "cues.yaml")
    if not os.path.exists(cue_p):
        print(f"not found: {cue_p}")
        return 1
    d = yaml.safe_load(open(rig_p, encoding="utf-8"))
    cd = yaml.safe_load(open(cue_p, encoding="utf-8"))

    errs, warns = check(d, cd)
    for w in warns:
        print(f"  [WARN] {w}")
    if errs:
        print("\nCue sheet validation failed, not written:")
        for e in errs:
            print(f"  [ERROR] {e}")
        return 1

    p = to_csv(d, cd, os.path.join(ROOT, "out"))
    print(f"  CSV: {p}")
    if "--report" in sys.argv:
        report(d, cd)
    else:
        print(f"  OK: {len(cd['cues'])} cues, {len(warns)} warning(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
