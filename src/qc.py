"""图纸质检器 —— 确定性检查，失败即 raise，不产出错图。
用法: python3 qc.py rig.yaml
"""
import sys, yaml

class QCError(Exception):
    pass


def check_rig(d):
    """检查灯具数据完整性与一致性"""
    errs, warns = [], []
    fixt = d["fixtures"]
    pos = {p["id"]: p for p in d["positions"]}

    # 1. 必填字段
    for f in fixt:
        for k in ("unit", "pos", "type", "gel", "ch"):
            if k not in f or f[k] in (None, ""):
                errs.append(f"灯具 {f.get('unit','?')} 缺字段 {k}")

    # 2. 位置必须存在
    for f in fixt:
        if f.get("pos") not in pos:
            errs.append(f"灯具 {f['unit']} 的吊挂位置 '{f['pos']}' 不存在")

    # 3. 单位编号唯一
    seen = {}
    for f in fixt:
        u = f.get("unit")
        if u in seen:
            errs.append(f"灯具编号重复: {u}")
        seen[u] = True

    # 4. 通道唯一（同一通道不能挂两台）
    ch = {}
    for f in fixt:
        c = f.get("ch")
        if c in ch:
            errs.append(f"通道 {c} 冲突: 灯具 {ch[c]} 与 {f['unit']}")
        ch[c] = f["unit"]

    # 5b. 灯具类型必须已定义；必须有坐标
    types = d.get("types", {})
    for f in fixt:
        if f.get("type") not in types:
            errs.append(f"灯具 {f.get('unit')}: 未知灯具类型 '{f.get('type')}'")
        if "x" not in f and "y" not in f:
            errs.append(f"灯具 {f.get('unit')}: 缺坐标 x/y")

    # 5. 色片必须在色片表里
    gels = {g["gel"] for g in d.get("gels", [])}
    for f in fixt:
        g = f.get("gel")
        if g and g not in gels:
            errs.append(f"灯具 {f['unit']} 用了未定义的色片 {g}")

    # 6. 光束角必填（否则剖面图无法画）
    for f in fixt:
        if "beam" not in f:
            warns.append(f"灯具 {f['unit']} 缺 beam 光束角，剖面图将用默认值")

    # 6b. 位置构件类型：truss（格构桁架）/ pipe（空心长条管线）/ line（单线）
    # line 用于**非吊挂构件**：布景边缘、地面导轨等。用 truss 画布景边缘
    # 会让人误读成第四根灯杆 —— 这就是 SET EDGE 改成 line 的原因。
    for p in d["positions"]:
        t = p.get("type", "truss")
        if t not in ("truss", "pipe", "line"):
            errs.append(f"位置 {p['id']} 的 type={t!r} 非法（truss / pipe / line）")

    # 7. trim 高度合理性
    #   ★ 只查 truss / pipe —— 它们是**吊挂**构件，trim 必须有物理意义的高度。
    #     line 是非吊挂的地面/布景线（如 SET EDGE 在 ±0 地面上），trim=0 是对的。
    #     早先不区分类型，每次运行都报 "SET EDGE trim 0mm 偏低" ——
    #     假警报比漏报更危险：会训练人忽略所有警告。
    for p in d["positions"]:
        if p.get("type", "truss") not in ("truss", "pipe"):
            continue
        t = p.get("trim")
        if t is None:
            errs.append(f"位置 {p['id']} 缺 trim 高度")
        elif t > 12000:
            warns.append(f"位置 {p['id']} trim {t}mm 偏高，请确认")
        elif t < 1500:
            warns.append(f"位置 {p['id']} trim {t}mm 偏低，请确认")

    # 8. 吊点是否在舞台范围内
    sd = d["stage"]["depth"]
    for p in d["positions"]:
        y = p.get("y", 0)
        if y > sd + 200:
            errs.append(f"位置 {p['id']} 的 y={y} 超出舞台深度 {sd}")

    return errs, warns


if __name__ == "__main__":
    src = sys.argv[1] if len(sys.argv) > 1 else "rig.yaml"
    with open(src, encoding="utf-8") as f:
        d = yaml.safe_load(f)
    errs, warns = check_rig(d)
    for w in warns:
        print("  [警告]", w)
    if errs:
        for e in errs:
            print("  [错误]", e)
        raise QCError(f"质检未通过：{len(errs)} 个错误")
    print(f"  质检通过：{len(d['fixtures'])} 台灯具，{len(warns)} 条警告")
