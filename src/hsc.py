#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""hsc.py — HSC Drama Design (Lighting) 合规门禁

为什么单独一个检查器
--------------------
HSC 的失分很少是"图画得不好"，而是**材料不齐或规格不对**：
  · 只有平面图，没有提示本 → Execution 直接掉到 3-4 分档
  · rationale 超 300 词 → 超出部分被忽略
  · 两个场景不形成对比 → 概念分上不去
  · 只交了一个场景 → 不满足 "two key scenes"

这些全部是**可机检的**。所以做成门禁：缺一样就不许交付。

依据（NESA Drama Stage 6 Syllabus 2009 · Design 选项）
------------------------------------------------------
必交材料：
  1. 300 词 rationale（director's concept 口吻）
  2. 灯光平面图，1:25，针对 2 个场景
     必须含：① 舞台平面图 + 重要布景元素
             ② 灯具位置
             ③ 色片颜色 / 灯具 / 每盏灯覆盖的区域
             ④ 两个场景的灯具与色片清单 + 说明
  3. Cue sheet
  4. Running script / prompt copy（标注 cue 点）
  5. 装裱：不许用玻璃

评分三条标准（各 10 分）：
  1. Design concept/vision
  2. Appropriateness
  3. Execution（plan + cue sheet + prompt copy 的清晰与准确）

用法
----
    python3 src/hsc.py            # 检查并打印清单
    python3 src/hsc.py --strict   # 任何缺失都非零退出
"""
import argparse
import os
import sys

import pymupdf
import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

K = 72.0 / 25.4


def _load(rel):
    p = os.path.join(ROOT, rel)
    if not os.path.exists(p):
        return None
    try:
        return yaml.safe_load(open(p, encoding="utf-8"))
    except Exception:
        return None


def _pdf_text(rel):
    p = os.path.join(ROOT, rel)
    if not os.path.exists(p):
        return ""
    try:
        return "\n".join(pg.get_text() for pg in pymupdf.open(p))
    except Exception:
        return ""


def _pdf_pages(rel):
    p = os.path.join(ROOT, rel)
    if not os.path.exists(p):
        return 0
    try:
        return len(pymupdf.open(p))
    except Exception:
        return 0


def check():
    """返回 (items, errors, warnings)。items = [(要求, 状态, 说明)]"""
    items, errs, warns = [], [], []

    rig = (_load(os.environ.get("RIG") or "data/rig.yaml")) or {}
    cues = _load("data/cues.yaml") or {}
    script = _load("data/script.yaml") or {}
    rat = _load("data/rationale.yaml") or {}
    scenes = _load("data/scenes.yaml") or {}

    # ---- 1. rationale
    if not rat:
        errs.append("缺 data/rationale.yaml —— HSC 必交 300 词 rationale")
        items.append(("300-word rationale", "MISSING", ""))
    else:
        import rationale as R
        e, w, n = R.check(rat)
        if e:
            errs.extend(e)
            items.append(("300-word rationale", "FAIL", f"{n} 词"))
        else:
            items.append(("300-word rationale", "OK", f"{n} 词 / 上限 300"))

    # ---- 2. 平面图（2 个场景，1:25）
    plans = [f for f in os.listdir(os.path.join(ROOT, "out"))
             if f.startswith("LX_plan") and f.endswith(".pdf")] \
        if os.path.isdir(os.path.join(ROOT, "out")) else []
    if len(plans) < 3:      # 主图 + 2 个场景
        errs.append(f"平面图只有 {len(plans)} 张，HSC 要 2 个场景 —— "
                    f"应至少有主图 + 2 个分场景图")
        items.append(("Lighting plan × 2 scenes", "FAIL", f"{len(plans)} 张"))
    else:
        items.append(("Lighting plan × 2 scenes", "OK",
                      f"{len(plans)} 张: {', '.join(sorted(plans))}"))

    # 比例 1:25
    sc = (rig.get("meta") or {}).get("scale", 0)
    if int(sc) != 25:
        errs.append(f"平面图比例是 1:{sc}，HSC 硬性要求 1:25")
        items.append(("Scale 1:25", "FAIL", f"1:{sc}"))
    else:
        items.append(("Scale 1:25", "OK", "1:25"))

    # ---- 3. 两个场景必须形成对比
    sc_list = list((scenes.get("scenes") or {}).keys())
    if len(sc_list) < 2:
        errs.append(f"scenes.yaml 只定义了 {len(sc_list)} 个场景，HSC 要 2 个")
        items.append(("Two contrasting scenes", "FAIL", f"{len(sc_list)} 个"))
    else:
        # 对比度：色片覆盖差异 + 强度差异
        a = (scenes["scenes"][sc_list[0]].get("gel_override") or {})
        b = (scenes["scenes"][sc_list[1]].get("gel_override") or {})
        diff_gel = sum(1 for k in set(a) | set(b) if a.get(k) != b.get(k))
        la = scenes["scenes"][sc_list[0]].get("levels") or {}
        lb = scenes["scenes"][sc_list[1]].get("levels") or {}
        diff_lv = sum(1 for k in set(la) | set(lb)
                      if abs((la.get(k) or 0) - (lb.get(k) or 0)) >= 15)
        if diff_gel == 0 and diff_lv < 2:
            errs.append(f"场景 {sc_list[0]} 与 {sc_list[1]} 几乎一样 —— "
                        f"HSC marker 明确要求对比要够大")
            items.append(("Two contrasting scenes", "FAIL",
                          f"色片差 {diff_gel} 项 / 强度差 {diff_lv} 项"))
        else:
            items.append(("Two contrasting scenes", "OK",
                          f"{sc_list[0]} vs {sc_list[1]}：色片差 {diff_gel} 项，"
                          f"强度差 {diff_lv} 项"))

    # ---- 4. cue sheet
    nc = len(cues.get("cues") or [])
    if nc == 0:
        errs.append("cues.yaml 里没有 cue")
        items.append(("Cue sheet", "MISSING", ""))
    else:
        has_pdf = os.path.exists(os.path.join(ROOT, "out", "cue_sheet.pdf"))
        items.append(("Cue sheet", "OK" if has_pdf else "PARTIAL",
                      f"{nc} 条 cue" + ("" if has_pdf else "（PDF 未生成）")))

    # ---- 5. running script
    nb = len(script.get("beats") or [])
    if nb == 0:
        errs.append("script.yaml 里没有 beat —— 提示本缺失是 Execution 的主要失分点")
        items.append(("Running script", "MISSING", ""))
    else:
        import running as R
        e, w = R.check(cues, script)
        if e:
            errs.extend([f"running script: {x}" for x in e])
            items.append(("Running script", "FAIL", f"{nb} beats"))
        else:
            items.append(("Running script", "OK", f"{nb} beats / {nc} cues 对齐"))

    # ---- 6. 每盏灯必须标出覆盖区域（acting zones）
    zones = rig.get("zones") or []
    if not zones:
        errs.append("rig.yaml 没有 zones —— HSC 要求明确标出每个表演区")
        items.append(("Acting zones marked", "MISSING", ""))
    else:
        items.append(("Acting zones marked", "OK",
                      f"{len(zones)} 个: {', '.join(z['id'] for z in zones)}"))

    # ---- 7. 每台灯必须有 purpose（照哪里）
    nopurpose = [f["unit"] for f in (rig.get("fixtures") or [])
                 if not f.get("purpose")]
    if nopurpose:
        errs.append(f"{len(nopurpose)} 台灯没有 purpose 字段 —— "
                    f"HSC 要求说明每盏灯覆盖的区域：{nopurpose[:6]}")
        items.append(("Every lantern has a purpose", "FAIL",
                      f"{len(nopurpose)} 台缺"))
    else:
        items.append(("Every lantern has a purpose", "OK",
                      f"{len(rig.get('fixtures') or [])} 台全部有"))

    # ---- 8. 装裱警告（不可机检，只能提醒）
    items.append(("Mounting: no glass", "MANUAL",
                  "NESA：Glass is not permitted。装订/打印时自己确认"))

    # ---- 9. 原创声明（不可机检）
    items.append(("Originality declaration signed", "MANUAL",
                  "随 folio 提交，学生与教师签署"))

    return items, errs, warns


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--strict", action="store_true")
    a = ap.parse_args()

    items, errs, warns = check()

    print("=" * 68)
    print(" HSC Drama Design (Lighting) — 交付合规检查")
    print(" 依据 NESA Drama Stage 6 Syllabus (2009) · Design 选项")
    print("=" * 68)
    for req, st, note in items:
        mark = {"OK": "[ OK ]", "FAIL": "[FAIL]", "MISSING": "[ -- ]",
                "PARTIAL": "[PART]", "MANUAL": "[MANU]"}.get(st, "[ ?? ]")
        print(f" {mark} {req:34s} {note}")

    print("-" * 68)
    if errs:
        print(f" 不满足 {len(errs)} 项：")
        for e in errs:
            print(f"   · {e}")
        print("\n 未通过 —— 按 HSC 规格，这份 folio 不能交。")
        return 1
    print(" 全部可机检项通过。")
    print(" 剩 2 项需人工确认（装裱无玻璃、原创声明已签）。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
