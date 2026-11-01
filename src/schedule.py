"""灯具表 / Instrument Schedule + 色片表 / Colour Call

★ 关于 "profile"（交付档位）
--------------------------------
同一份数据，两种读者：

  profile: hsc        —— HSC Drama Individual Project（默认）
      只输出 **位置 / 编号 / 类型 / 色片 / 用途**。
      不输出瓦数、不输出 DMX。理由：HSC 评分看的是设计判断
      （为什么用这个色、这盏灯照哪里），不是电学参数。
      多写瓦数和通道反而稀释重点，且 HSC 场地是学校剧场，
      灯具型号和通道分配在考场上根本不成立。

  profile: industry   —— 真实演出
      额外输出瓦数 W、DMX 占用、DMX 地址。

档位从 rig.yaml 的 meta.profile 读，默认 hsc。
"""
import os, yaml, csv
import qc

ORDER = {"FOH LX": 0, "LX 1": 1, "LX 2": 2, "LX 3": 3,
         "BOOM SL": 4, "BOOM SR": 5, "SET": 6}

# DMX 占用通道数（每台灯的**实际**占用，不是 1）
# 用户指出：401-404 (LED) 实际占 6 通道；701/702 (mover) 占 16；
# 801/802 (followspot) 占 2。旧版表格把每台灯都当 1 通道，是错的。
DMX_FOOTPRINT = {
    "profile":  2,    # 调光 + 遮扉/光圈（简化）
    "fresnel":  1,
    "par":      1,
    "led":      6,    # RGBWA + 频闪 + 效果
    "mover":   16,    # 平移/俯仰/颜色/图案/棱镜/调焦/光圈/频闪
    "follow":   2,    # 调光 + 光圈
    "practical": 1,
}


def footprint(f):
    """单台灯占用的 DMX 通道数。"""
    return DMX_FOOTPRINT.get(f.get("type"), 1)


def dmx_total(d):
    return sum(footprint(f) for f in d["fixtures"])


def schedule(d):
    """按位置 → 单位号排序"""
    rows = sorted(d["fixtures"], key=lambda f: (ORDER.get(f["pos"], 99), f["unit"]))
    return rows

def hookup(d):
    """按通道排序"""
    return sorted(d["fixtures"], key=lambda f: f["ch"])

def colour_call(d):
    """按色片统计用量"""
    from collections import Counter
    c = Counter(f["gel"] for f in d["fixtures"])
    names = {g["gel"]: g["name"] for g in d["gels"]}
    return [(g, names.get(g, ""), n) for g, n in c.most_common()]

def shop_order(d):
    """按灯具类型统计"""
    from collections import Counter
    c = Counter(f["type"] for f in d["fixtures"])
    return sorted(c.items(), key=lambda x: -x[1])

def profile_of(d):
    """交付档位：'hsc'（默认）或 'industry'。"""
    return (d.get("meta") or {}).get("profile", "hsc")


def to_csv(d, outdir="out"):
    os.makedirs(outdir, exist_ok=True)
    p1 = os.path.join(outdir, "instrument_schedule.csv")
    with open(p1, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        ind = profile_of(d) == "industry"
        head = ["POS", "UNIT", "TYPE", "BEAM", "GEL", "PURPOSE"]
        if ind:
            head += ["W", "CH", "DMX_ADDR", "DMX_CH"]
        w.writerow(head)
        addr = 1
        for x in schedule(d):
            fp = footprint(x)
            row = [x["pos"], x["unit"], x["type"], x.get("beam", ""),
                   x.get("gel", ""), x.get("purpose", "")]
            if ind:
                row += [x.get("w", ""), x["ch"],
                        f"{addr}-{addr + fp - 1}", fp]
            w.writerow(row)
            addr += fp
    p2 = os.path.join(outdir, "channel_hookup.csv")
    with open(p2, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        ind = profile_of(d) == "industry"
        if ind:
            w.writerow(["CH", "UNIT", "POS", "TYPE", "GEL",
                        "DMX_CH", "DMX_ADDR", "PURPOSE"])
            addr = 1
            addrs = {}
            for x in schedule(d):
                fp = footprint(x)
                addrs[x["unit"]] = (addr, addr + fp - 1, fp)
                addr += fp
            for x in hookup(d):
                a0, a1, fp = addrs[x["unit"]]
                w.writerow([x["ch"], x["unit"], x["pos"], x["type"],
                            x.get("gel", ""), fp, f"{a0}-{a1}",
                            x.get("purpose", "")])
        else:
            # HSC 档位不出通道表 —— 学校剧场没有固定调光台编号
            w.writerow(["POS", "UNIT", "TYPE", "GEL", "PURPOSE"])
            for x in hookup(d):
                w.writerow([x["pos"], x["unit"], x["type"],
                            x.get("gel", ""), x.get("purpose", "")])
    return p1, p2

def report(d):
    print("\n=== 灯具表 / INSTRUMENT SCHEDULE ===")
    print(f"{'POS':<9}{'U#':<6}{'TYPE':<10}{'BM':<5}{'GEL':<8}{'CH':<5}PURPOSE")
    print("-" * 68)
    for x in schedule(d):
        print(f"{x['pos']:<9}{x['unit']:<6}{x['type']:<10}{x.get('beam',''):<5}"
              f"{x.get('gel',''):<8}{x['ch']:<5}{x.get('purpose','')}")
    print("\n=== 色片表 / COLOUR CALL ===")
    for g, n, c in colour_call(d):
        print(f"  {g:<8}{n:<28}{c} 台")
    print("\n=== 设备清单 / SHOP ORDER ===")
    for t, c in shop_order(d):
        print(f"  {t:<12}{c} 台")

if __name__ == "__main__":
    # ★ 同 section.py：必须支持 --out，否则多项目互相覆盖。
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("rig", nargs="?", default="rig.yaml")
    ap.add_argument("--out", default="out", help="输出目录（默认 out/）")
    a = ap.parse_args()
    src = a.rig
    d = yaml.safe_load(open(src, encoding="utf-8"))
    errs, warns = qc.check_rig(d)
    if errs:
        for e in errs:
            print("  [错误]", e)
        raise SystemExit("质检未通过")
    report(d)
    p1, p2 = to_csv(d, a.out)
    print(f"\n  CSV: {p1}\n  CSV: {p2}")
