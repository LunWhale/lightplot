#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""dxfix.py — DXF 交付前的可移植性后处理

为什么需要"后处理"而不是在 ezdxf 里设好
----------------------------------------
实测：ezdxf 的 `doc.header["$EXTMIN"] = (...)` 在内存里生效，
但 `saveas()` 写盘时会被**重置回哨兵值**：

    before save: (10.0, 10.0, 0.0)
    after reload: (1e+20, 1e+20, 1e+20)
    raw in file:  ('1e+20', '1e+20')      <- 文件里就是错的

所以必须在文件写完之后做**文本级**修补。这是唯一可靠的办法。

修的什么
--------
1. `$EXTMIN` / `$EXTMAX`  —— 哨兵值会让 CAD 的"缩放到全部"失效
2. `$LIMMIN` / `$LIMMAX`  —— A1 图纸曾写成 A3 的界限 (420,297)
3. 悬空线型名           —— 图层引用 'CONTINUOUS' 但表里只有 'Continuous'
4. `$LASTSAVEDBY`        —— 不暴露工具链
5. `EZDXF_META` XRECORD  —— 同上
6. 版本控制             —— R2004 (AC1018)

★ 为什么**不能**降到 R2000 (AC1015)
------------------------------------
DXF 的 true_color（组码 420，24 位真彩）是 **R2004 (AC1018) 才引入的**。
实测：

    R2000: 420 tag in file=False   reload true_color=None
    R2004: 420 tag in file=True    reload true_color=16777215

我们的白底遮罩必须用 true_color = 0xFFFFFF。降到 R2000 会把它**丢掉**，
遮罩退回 ACI 7（"随背景翻转"），在 Vectorworks 白底上渲染成**黑色** ——
整张图黑乎乎，正是用户截图看到的现象。

用法
----
    from dxfix import fix_dxf
    fix_dxf("out/LX_plan.dxf", sheet_w=841, sheet_h=594)
"""
import os
import re

import ezdxf

# ezdxf 写盘时会被重置的 header 变量，必须文本级修补
_TEXT_FIXED = ("$EXTMIN", "$EXTMAX", "$LIMMIN", "$LIMMAX")


def _content_extents(dxf_path):
    """算真实内容包围盒（模型空间 + 所有块定义）。"""
    from ezdxf import bbox
    doc = ezdxf.readfile(dxf_path)
    b = bbox.extents(doc.modelspace())
    if not b.has_data:
        return None
    return (b.extmin.x, b.extmin.y, b.extmax.x, b.extmax.y)


def _parse_tags(raw):
    """把 DXF 拆成 [(code_str, value_str), ...]。

    ★ 不要用正则跨行匹配 header 点值。
      上一版用 r"\\n\\s*20\\n" 定位 y 坐标，反斜杠 s 包含换行，
      正则一路吃到了下一行，把 header 写坏了（Missing required y coordinate）。
      按行成对解析是唯一可靠的做法。
    """
    lines = raw.split("\n")
    tags = []
    i = 0
    while i + 1 < len(lines):
        tags.append((lines[i].strip(), lines[i + 1]))
        i += 2
    return tags


def _write_tags(tags):
    out = []
    for code, value in tags:
        out.append("%3s" % code)
        out.append(value)
    return "\n".join(out) + "\n"


def _set_header_text(raw, var, values):
    """替换 header 变量的点值。按 tag 定位，不碰别的。"""
    tags = _parse_tags(raw)
    try:
        i = next(k for k, (c, v) in enumerate(tags)
                 if c == "9" and v.strip() == var)
    except StopIteration:
        return raw, False
    # 变量名之后的 10/20/30
    wanted = {"10": values[0], "20": values[1], "30": values[2]}
    done = 0
    k = i + 1
    while k < len(tags) and tags[k][0] != "9":
        code = tags[k][0]
        if code in wanted:
            tags[k] = (code, _fmt(wanted[code]))
            done += 1
            if done == 3:
                break
        k += 1
    if done < 3:
        return raw, False
    return _write_tags(tags), True


def _set_header_point2(raw, var, x, y):
    """替换只有 x/y 两个分量的 header 变量（$LIMMIN / $LIMMAX）。"""
    tags = _parse_tags(raw)
    try:
        i = next(k for k, (c, v) in enumerate(tags)
                 if c == "9" and v.strip() == var)
    except StopIteration:
        return raw, False
    k = i + 1
    got = 0
    while k < len(tags) and tags[k][0] != "9":
        if tags[k][0] == "10":
            tags[k] = ("10", _fmt(x)); got += 1
        elif tags[k][0] == "20":
            tags[k] = ("20", _fmt(y)); got += 1
        if got == 2:
            break
        k += 1
    if got < 2:
        return raw, False
    return _write_tags(tags), True


def _set_header_scalar(raw, var, code, value):
    tags = _parse_tags(raw)
    try:
        i = next(k for k, (c, v) in enumerate(tags)
                 if c == "9" and v.strip() == var)
    except StopIteration:
        return raw, False
    k = i + 1
    while k < len(tags) and tags[k][0] != "9":
        if tags[k][0] == code:
            tags[k] = (code, value)
            return _write_tags(tags), True
        k += 1
    return raw, False


def _fmt(v):
    """DXF 浮点格式：不用科学计数法，去尾零。"""
    s = "%.6f" % float(v)
    s = s.rstrip("0").rstrip(".")
    return s if s not in ("", "-") else "0.0"


def _fix_linetypes(doc):
    """把悬空的线型名按大小写不敏感匹配回表里的真名。"""
    table = {l.dxf.name.upper(): l.dxf.name for l in doc.linetypes}
    fixed = []
    for lay in doc.layers:
        want = lay.dxf.linetype
        if want in {l.dxf.name for l in doc.linetypes}:
            continue
        real = table.get(want.upper())
        if real:
            lay.dxf.linetype = real
            fixed.append((lay.dxf.name, want, real))
    return fixed


def _fix_textstyles(doc):
    """文字样式引用的字体文件缺失时回退到标准字体（CAD 找不到会报错）。"""
    fixed = []
    for st in doc.styles:
        f = (st.dxf.get("font") or "").strip()
        if not f:
            continue
        # DXF 里只允许文件名，不允许路径
        if "/" in f or "\\" in f:
            st.dxf.font = os.path.basename(f)
            fixed.append((st.dxf.name, f, st.dxf.font))
    return fixed


def _drop_meta(doc):
    """移除 ezdxf 自己的元数据记录（不在交付物里暴露工具链）。"""
    root = doc.rootdict
    if "EZDXF_META" in root:
        try:
            del root["EZDXF_META"]
            return True
        except Exception:
            return False
    return False


def fix_dxf(path, sheet_w=None, sheet_h=None, version="R2004", verbose=True,
            paper_is_sheet=True):
    """就地修补 DXF。返回一份报告 dict。

    paper_is_sheet:
      True  (默认) —— layout paper = 图纸尺寸（A1 841x594），scale 1:1。
                      适用于**图纸尺寸**的 DXF（内容 841x594）。
                      一张纸正好装下，Vectorworks 不会铺瓦。
      False        —— layout paper = 内容尺寸（21025x14850），scale 1:1。
                      适用于**真实尺寸**的 DXF。
    """
    rep = {"path": path, "fixes": []}

    # ---- 阶段 1：ezdxf 层能做的
    doc = ezdxf.readfile(path)

    lt = _fix_linetypes(doc)
    if lt:
        rep["fixes"].append(f"linetypes: {len(lt)} layer(s) re-pointed to real names")
        rep["linetype_detail"] = lt

    st = _fix_textstyles(doc)
    if st:
        rep["fixes"].append(f"textstyles: {len(st)} path(s) reduced to filenames")

    if _drop_meta(doc):
        rep["fixes"].append("removed EZDXF_META record")

    # layout：paper 与内容对齐，避免 Vectorworks 铺瓦
    if sheet_w and sheet_h:
        try:
            _b0 = None
            if paper_is_sheet:
                _pw, _ph, _sd = sheet_w, sheet_h, 1.0
            else:
                from ezdxf import bbox as _bb0
                _b0 = _bb0.extents(doc.modelspace())
                _pw = _b0.extmax.x - _b0.extmin.x
                _ph = _b0.extmax.y - _b0.extmin.y
                _sd = 1.0
            for lay in doc.layouts:
                l = lay.dxf_layout
                l.dxf.paper_width = _pw
                l.dxf.paper_height = _ph
                l.dxf.scale_numerator = 1.0
                l.dxf.scale_denominator = _sd
            rep["fixes"].append(
                f"layout paper -> {_pw:.0f}x{_ph:.0f} @ 1:{_sd:.0f}")
        except Exception as ex:
            rep["fixes"].append(f"layout: {type(ex).__name__}")

    # DIMENSION 不许留在 layer 0（Vectorworks 会当无名对象）
    moved = 0
    for e in doc.modelspace().query("DIMENSION"):
        if e.dxf.layer == "0":
            e.dxf.layer = "DIM"
            moved += 1
    if moved:
        rep["fixes"].append(f"{moved} DIMENSION moved off layer 0")

    # ★ 清理孤立对象：setup=False 会留下 owner handle 无效的 DICTIONARYVAR。
    #   实测 audit 报：Deleted DICTIONARYVAR(#2E) entity with invalid owner handle #2D
    #   Vectorworks 对这类结构很敏感。
    _audit = doc.audit()
    if _audit.errors or _audit.fixes:
        rep["fixes"].append(
            f"audit cleaned {len(_audit.errors)} error(s) / {len(_audit.fixes)} fix(es)")

    # 版本降级
    if version:
        doc.dxfversion = version
        rep["fixes"].append(f"version -> {version}")

    doc.saveas(path)

    # ---- 阶段 2：文本级修补 header（ezdxf 会重置这些）
    # ★ 不能假设纯 ASCII。DXF 里允许 UTF-8（R2007+）或 \U+nnnn 转义；
    #   直接 decode("ascii") 会在有 ±、— 这类字符时崩掉。
    #   这里用 utf-8 读、ascii 写回（DXF 输出必须是 ASCII 安全）。
    raw_bytes = open(path, "rb").read()
    try:
        raw = raw_bytes.decode("ascii")
    except UnicodeDecodeError as e:
        raise SystemExit(
            f"dxfix: {path} 含非 ASCII 字符（偏移 {e.start}）—— "
            f"DXF 交付物必须是纯 ASCII。请把该字符改成 ASCII 等价写法"
            f"（如 ± -> +/-0），不要依赖 \\U+ 转义，Vectorworks 不保证支持。")

    ext = _content_extents(path)
    if ext:
        x0, y0, x1, y1 = ext
        raw, ok1 = _set_header_text(raw, "$EXTMIN", (x0, y0, 0.0))
        raw, ok2 = _set_header_text(raw, "$EXTMAX", (x1, y1, 0.0))
        if ok1 and ok2:
            rep["fixes"].append(
                f"$EXTMIN/$EXTMAX -> ({x0:.1f},{y0:.1f})..({x1:.1f},{y1:.1f})")

    if sheet_w and sheet_h:
        # $LIMMIN / $LIMMAX 在 DXF 里只有 x/y（没有 z），单独处理
        raw, ok1 = _set_header_point2(raw, "$LIMMIN", 0.0, 0.0)
        raw, ok2 = _set_header_point2(raw, "$LIMMAX", sheet_w, sheet_h)
        if ok1 and ok2:
            rep["fixes"].append(
                f"$LIMMIN/$LIMMAX -> (0,0)..({sheet_w:.0f},{sheet_h:.0f})")
        else:
            rep["fixes"].append("$LIMMIN/$LIMMAX 修补失败（变量不存在？）")

    # ★ $PLIMMIN/$PLIMMAX（**图纸空间**界限）也必须设。
    #   实测：这一对一直是 A3 (420x297)，而内容 841x594，
    #   Vectorworks 用图纸空间界限当页面尺寸 -> 图显示成页面的 50%
    #   （841/420 = 2.00，用户截图里图正好占一半宽，完全吻合）。
    #   $LIMMAX 是模型空间，$PLIMMAX 是图纸空间，两套都要对。
    if sheet_w and sheet_h:
        raw, ok1 = _set_header_point2(raw, "$PLIMMIN", 0.0, 0.0)
        raw, ok2 = _set_header_point2(raw, "$PLIMMAX", sheet_w, sheet_h)
        if ok1 and ok2:
            rep["fixes"].append(
                f"$PLIMMIN/$PLIMMAX -> (0,0)..({sheet_w:.0f},{sheet_h:.0f})")

    raw, ok = _set_header_scalar(raw, "$LASTSAVEDBY", "1", "")
    if ok:
        rep["fixes"].append("$LASTSAVEDBY cleared")

    # ★ $ACADMAINTVER 必须匹配目标版本。
    #   R2000(AC1015) 的维护号是 0；我们降级后仍留着 R2010 的 6，
    #   这是版本混用的痕迹，CAD 可能因此判定文件不可信。
    if version == "R2000":
        raw, ok = _set_header_scalar(raw, "$ACADMAINTVER", "70", "0")
        if ok:
            rep["fixes"].append("$ACADMAINTVER -> 0 (R2000)")

    try:
        out = raw.encode("ascii")
    except UnicodeEncodeError as e:
        raise SystemExit(
            f"dxfix: 修补后仍含非 ASCII（偏移 {e.start}）—— 拒绝写出")
    open(path, "wb").write(out)

    # ---- 阶段 3：复验
    rep.update(verify_dxf(path, sheet_w, sheet_h))
    if verbose:
        for f in rep["fixes"]:
            print(f"    dxfix: {f}")
        for p in rep.get("problems", []):
            print(f"    dxfix [WARN] {p}")
    return rep


def verify_dxf(path, sheet_w=None, sheet_h=None):
    """可移植性检查。返回 {"ok": bool, "problems": [...], "stats": {...}}"""
    problems = []
    raw = open(path, "rb").read().decode("ascii", "replace")

    def hdr_point(var):
        m = re.search(r"\n  9\n" + re.escape(var) +
                      r"\n\s*10\n([^\n]*)\n\s*20\n([^\n]*)\n", raw)
        return (float(m.group(1)), float(m.group(2))) if m else None

    emin, emax = hdr_point("$EXTMIN"), hdr_point("$EXTMAX")
    stats = {"extmin": emin, "extmax": emax}

    # 1. 范围必须是有限且有序的
    for name, v in (("$EXTMIN", emin), ("$EXTMAX", emax)):
        if v is None:
            problems.append(f"{name} 缺失")
        elif abs(v[0]) > 1e6 or abs(v[1]) > 1e6:
            problems.append(f"{name} 仍是哨兵值 {v} —— CAD 无法缩放到内容")
    if emin and emax and not (emax[0] > emin[0] and emax[1] > emin[1]):
        problems.append(f"$EXTMIN {emin} 不小于 $EXTMAX {emax}")

    # 2. 界限必须匹配图纸
    lmax = hdr_point("$LIMMAX")
    stats["limmax"] = lmax
    if sheet_w and sheet_h and lmax:
        if abs(lmax[0] - sheet_w) > 1 or abs(lmax[1] - sheet_h) > 1:
            problems.append(
                f"$LIMMAX {lmax} 与图纸 {sheet_w:.0f}x{sheet_h:.0f} 不符")

    # 3. 悬空引用
    doc = ezdxf.readfile(path)
    lts = {l.dxf.name for l in doc.linetypes}
    bad_lt = [l.dxf.name for l in doc.layers if l.dxf.linetype not in lts]
    if bad_lt:
        problems.append(f"{len(bad_lt)} 个图层引用不存在的线型：{bad_lt[:4]}")

    sts = {s.dxf.name for s in doc.styles}
    bad_st = set()
    for e in doc.modelspace().query("TEXT"):
        if e.dxf.style not in sts:
            bad_st.add(e.dxf.style)
    if bad_st:
        problems.append(f"文字引用不存在的样式：{sorted(bad_st)}")

    # 4. NaN / Inf / 荒谬坐标
    bad_num = 0
    for i in range(0, len(raw.split("\n")) - 1, 2):
        pass
    for e in doc.modelspace():
        for attr in ("start", "end", "insert", "center"):
            p = e.dxf.get(attr) if hasattr(e.dxf, attr) else None
            if p is None:
                continue
            try:
                vals = (p.x, p.y)
            except Exception:
                continue
            for v in vals:
                if v != v or abs(v) > 1e7:
                    bad_num += 1
    if bad_num:
        problems.append(f"{bad_num} 个坐标是 NaN/Inf/荒谬值")

    # 5. handle 唯一性 + HANDSEED
    #    ★ 不要用文本正则数 handle。DXF 里 "330" 既是 owner 指针的组码，
    #      也可能恰好是某个实体的 handle 值；正则数出来的"重复"是假的。
    #      用 ezdxf 解析后的对象句柄集合才是真的。
    hs = set()
    for e in doc.modelspace():
        if e.dxf.hasattr("handle"):
            hs.add(e.dxf.handle)
    for b in doc.blocks:
        if b.block_record.dxf.hasattr("handle"):
            hs.add(b.block_record.dxf.handle)
        for e in b:
            if e.dxf.hasattr("handle"):
                hs.add(e.dxf.handle)
    for o in doc.objects:
        if o.dxf.hasattr("handle"):
            hs.add(o.dxf.handle)
    for t in list(doc.layers) + list(doc.styles) + list(doc.linetypes):
        if t.dxf.hasattr("handle"):
            hs.add(t.dxf.handle)
    if len(hs) == 0:
        problems.append("没有任何 handle —— 文件结构异常")
    m = re.search(r"\$HANDSEED\n\s*5\n([0-9A-F]+)\n", raw)
    if m and hs:
        seed = int(m.group(1), 16)
        mx = max(int(h, 16) for h in hs)
        if seed <= mx:
            problems.append(f"$HANDSEED 0x{seed:X} <= 最大 handle 0x{mx:X}")

    # 6. 顶点规模（Vectorworks 对超大 polyline 很慢）
    verts = sum(len(e) for e in doc.modelspace().query("LWPOLYLINE"))
    import collections
    ins = collections.Counter(e.dxf.name for e in doc.modelspace().query("INSERT"))
    for name, n in ins.items():
        try:
            blk = doc.blocks.get(name)
        except Exception:
            continue
        verts += sum(len(e) for e in blk.query("LWPOLYLINE")) * n
    stats["exploded_vertices"] = verts
    if verts > 120000:
        problems.append(
            f"展开后 {verts} 个顶点，超过 120k —— CAD 会很慢，应简化符号")

    # 6b. layout 纸张 x 比例 必须等于内容尺寸
    #     Vectorworks 用 layout 推视窗比例；对不上就显示错误的 1:5 之类。
    #     我们的策略是 paper = 内容尺寸 + scale 1:1（见 to_model_scale），
    #     所以这里检查的是这个等式，不限定具体是 A1+1:25 还是 内容+1:1。
    try:
        from ezdxf import bbox as _bb
        _b = _bb.extents(doc.modelspace())
        _W = _b.extmax.x - _b.extmin.x
        _H = _b.extmax.y - _b.extmin.y
        for lay in doc.layouts:
            _l = lay.dxf_layout
            _pw = _l.dxf.get("paper_width") or 0
            _ph = _l.dxf.get("paper_height") or 0
            _sd = _l.dxf.get("scale_denominator") or 1
            if _pw and _ph:
                if abs(_pw * _sd - _W) > 1 or abs(_ph * _sd - _H) > 1:
                    problems.append(
                        f"layout {lay.name!r}: paper {_pw:.0f}x{_ph:.0f} x 1:{_sd:.0f} "
                        f"= {_pw*_sd:.0f}x{_ph*_sd:.0f}，但内容 {_W:.0f}x{_H:.0f} —— "
                        f"Vectorworks 会显示错误的视窗比例")
    except Exception:
        pass

    # 7. 文件大小
    stats["bytes"] = os.path.getsize(path)
    if stats["bytes"] > 8e6:
        problems.append(f"文件 {stats['bytes'] / 1e6:.1f} MB 偏大")

    return {"ok": not problems, "problems": problems, "stats": stats}


def to_model_scale(dxf_path, scale, sheet_w=841.0, sheet_h=594.0, verbose=True):
    """把"图纸空间 mm"的 DXF 放大成"真实尺寸 mm"。

    ★ 为什么需要这一步（用户实测：导入后比例不对）
    ------------------------------------------------
    我们画图时模型空间 = **图纸毫米**：A1 纸 841x594，舞台 15000mm
    画成 600mm。这在"1:25 出图"的语境下是对的。

    但 CAD 不理解"图纸空间"。它把模型空间的 1 单位当成 1 个真实单位。
    所以 Vectorworks 看到的是一个 **841mm 宽的世界** —— 比真实舞台小 25 倍。

    正确做法：模型空间 = 真实尺寸。舞台 15000mm 就是 15000 单位，
    A1 纸框 841mm @1:25 变成 21025 单位，文字高度也跟着 x25。

    ★ 用 ezdxf 的 transform()，只调一次
    ------------------------------------
    transform() 会正确处理所有实体类型（LWPOLYLINE 的 bulge、
    TEXT 的 height、INSERT 的 scale、HATCH 的路径、DIMENSION 的 defpoint）。
    实测：841x594 -> 21025x14850，精确。

    早先我手写逐类型缩放，又叠加了 INSERT.scale 的额外乘法，
    结果放大成 x625（extents 跑到 98208）。不要手写。
    """
    import ezdxf as _ezdxf
    from ezdxf.math import Matrix44

    doc = _ezdxf.readfile(dxf_path)
    m = Matrix44.scale(float(scale), float(scale), 1.0)

    n = 0
    for e in doc.modelspace():
        try:
            e.transform(m)
            n += 1
        except Exception as ex:
            if verbose:
                print(f"      skip {e.dxftype()}: {type(ex).__name__}")

    # 线型比例跟着缩放，否则虚线 dash 相对图形变小 25 倍
    doc.header["$LTSCALE"] = float(scale)

    # ★ layout 的纸张和比例：必须让 paper x scale = 内容尺寸
    #
    # 为什么不能写 A1(841x594) + 1:25
    # -------------------------------
    # 那样算出来确实等于内容尺寸（841x25=21025），逻辑上自洽。
    # 但 Vectorworks 教育版有一个"可打印区域"（水印框），实测约
    # **20000 x 14000**（用户给出的中心点 (10000,7000) 反推）。
    # paper 写成 841x594 时，页面只占那个区域的 4%，画面看着"特别特别小"；
    # 用户手动改成 1:1 又会因为页面装不下内容而溢出。
    #
    # 正确做法：让 paper 直接等于**内容尺寸**，scale = 1:1。
    # 这样 Vectorworks 认为"这页纸就是 21025x14850"，内容 1:1 正好填满它，
    # 水印落在图框之外。
    #
    # ⚠ 这段必须在 saveas **之前** —— 早先被插到 return 后面成了死代码，
    #    layout 一直停在 420x297 1:1，正是用户看到 1:5 的原因。
    try:
        for lay in doc.layouts:
            l = lay.dxf_layout
            l.dxf.paper_width = sheet_w * scale
            l.dxf.paper_height = sheet_h * scale
            l.dxf.scale_numerator = 1.0
            l.dxf.scale_denominator = 1.0
    except Exception as ex:
        if verbose:
            print(f"      layout setup: {type(ex).__name__}")

    # ---- 写盘。之后 header 的四个变量会被重置，必须在文本层补回
    doc.saveas(dxf_path)

    from ezdxf import bbox as _bb
    _b = _bb.extents(doc.modelspace())
    _set_limits_text(dxf_path, sheet_w * scale, sheet_h * scale, verbose)
    _raw = open(dxf_path, "rb").read().decode("ascii")
    _raw, _ok1 = _set_header_text(_raw, "$EXTMIN",
                                  (_b.extmin.x, _b.extmin.y, 0.0))
    _raw, _ok2 = _set_header_text(_raw, "$EXTMAX",
                                  (_b.extmax.x, _b.extmax.y, 0.0))
    if _ok1 and _ok2:
        open(dxf_path, "wb").write(_raw.encode("ascii"))
        if verbose:
            print(f"    $EXTMIN/$EXTMAX -> "
                  f"({_b.extmin.x:.0f},{_b.extmin.y:.0f}).."
                  f"({_b.extmax.x:.0f},{_b.extmax.y:.0f})")

    if verbose:
        print(f"    model scale x{scale:.0f} (drawing mm -> real mm), {n} entities")
    return dxf_path


def _set_limits_text(path, limx, limy, verbose=True):
    """文本层写入 $LIMMIN/$LIMMAX（ezdxf 会在 saveas 时重置这两个）。"""
    raw = open(path, "rb").read().decode("ascii")
    raw, ok1 = _set_header_point2(raw, "$LIMMIN", 0.0, 0.0)
    raw, ok2 = _set_header_point2(raw, "$LIMMAX", limx, limy)
    if ok1 and ok2:
        open(path, "wb").write(raw.encode("ascii"))
        if verbose:
            print(f"    $LIMMAX -> ({limx:.0f}, {limy:.0f})")
    return ok1 and ok2


def make_dwg(dxf_path, verbose=True):
    """用 libredwg 的 dxf2dwg 转出 DWG。

    ★ 为什么需要这个
    ----------------
    实测：Vectorworks 2026 的 Info.plist 里**没有注册 .dxf**，
    只注册了 DWG（CFBundleTypeOSTypes = MDWG）。
    macOS 上 .dxf 默认关联到 LibreOffice（org.libreoffice.dxf-document）。
    所以「双击 dxf」永远不会用 Vectorworks 打开 —— 必须走
    File > Import > Import Single DXF/DWG。

    ★ libredwg 的 "Duplicate handle" 报错是误报
    ---------------------------------------------
    实测：ezdxf 官方最小文件（一条直线）转 DWG 也报
        ERROR: Duplicate handle 1F for object 43 already points to object 0
    所以这条不能当判据。真正的判据是输出文件是否有效（file 命令能识别）。
    """
    import shutil
    import subprocess

    exe = shutil.which("dxf2dwg")
    if not exe:
        return None, "dxf2dwg 未安装（brew install libredwg）"

    dwg = os.path.splitext(dxf_path)[0] + ".dwg"
    if os.path.exists(dwg):
        os.remove(dwg)
    r = subprocess.run([exe, "-y", "-o", dwg, dxf_path],
                       capture_output=True, text=True)
    if not os.path.exists(dwg):
        return None, f"转换失败：{r.stdout[-300:]}{r.stderr[-300:]}"
    # 验证 DWG 文件头
    with open(dwg, "rb") as f:
        magic = f.read(6)
    if not magic.startswith(b"AC10"):
        return None, f"输出不是有效 DWG（magic={magic!r}）"
    if verbose:
        print(f"    DWG: {dwg}  ({os.path.getsize(dwg) / 1024:.0f} KB)")
    return dwg, None


if __name__ == "__main__":
    import sys
    p = sys.argv[1] if len(sys.argv) > 1 else "out/LX_plan.dxf"
    w = float(sys.argv[2]) if len(sys.argv) > 2 else 841.0
    h = float(sys.argv[3]) if len(sys.argv) > 3 else 594.0
    r = fix_dxf(p, w, h)
    print("\nOK" if r["ok"] else "\nPROBLEMS")
    sys.exit(0 if r["ok"] else 1)
