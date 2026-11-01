"""中文字体自动探测 —— macOS / Linux / Windows 通用。

为什么需要这个文件
------------------
DXF 的文字样式（style）必须指向一个**真实存在的字体文件**（.ttf/.ttc/.otf），
否则在 Vectorworks / AutoCAD 里打开时中文会变成问号或方块。
不同操作系统上字体路径完全不同，写死路径必然在另一台机器上崩。

优先级
------
1. 环境变量 LX_FONT（用户显式指定，最高优先级）
2. 各系统常见 CJK 字体（按顺序探测）
3. Linux 下遍历 /usr/share/fonts 找含 CJK 的字体
4. 全部失败 → 明确报错并给出修复命令（不静默降级成乱码）
"""
import os
import sys

# 按优先级排列：macOS → Linux → Windows
_CANDIDATES = [
    # ---- macOS ----
    "/System/Library/Fonts/PingFang.ttc",           # 苹方，macOS 10.11+ 默认中文
    "/System/Library/Fonts/Hiragino Sans GB.ttc",   # 冬青黑体简体
    "/System/Library/Fonts/STHeiti Light.ttc",      # 黑体-简
    "/System/Library/Fonts/Supplemental/Songti.ttc",
    "/Library/Fonts/Arial Unicode.ttf",
    # ---- Linux ----
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJKsc-Regular.otf",
    "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/noto/NotoSerifCJK-Regular.ttc",
    # ---- Windows ----
    "C:/Windows/Fonts/msyh.ttc",
    "C:/Windows/Fonts/simsun.ttc",
]

# matplotlib 用字体名（不是路径），按优先级
_MPL_NAMES = [
    "PingFang SC", "Hiragino Sans GB", "Heiti SC", "Songti SC", "Arial Unicode MS",
    "Noto Sans CJK SC", "Noto Sans CJK JP", "Noto Sans CJK", "Source Han Sans SC",
    "WenQuanYi Zen Hei", "Microsoft YaHei", "SimHei",
]


def dxf_font():
    """返回可用于 DXF 文字样式的字体**文件名**（不是路径）。

    实测结论（重要，别改回去）
    --------------------------
    ezdxf 渲染时用自己的字体管理器按**文件名**在系统字体中查找。
    - 传纯文件名 "NotoSansCJK-Regular.ttc" → 找到，中文正常渲染 ✅
    - 传绝对路径 "/usr/share/fonts/.../x.ttc" → 查找失败，回退到不含中文的
      默认字体，中文全部变成 □ 方块 ❌

    而且纯文件名在 DXF 里本来就是正确写法 —— 用户的 CAD 会去系统字体目录找，
    所以在 Mac 上打开也能正常显示。两个问题一次解决。
    """
    env = os.environ.get("LX_FONT")
    if env:
        if os.path.exists(env):
            return os.path.basename(env)
        sys.exit(
            "[字体] 环境变量 LX_FONT 指向的文件不存在：%s\n"
            "请改成真实路径，或删除该变量让程序自动探测。" % env
        )

    for p in _CANDIDATES:
        if os.path.exists(p):
            return os.path.basename(p)

    # Linux 兜底：遍历字体目录找 CJK
    for root in ("/usr/share/fonts", "/usr/local/share/fonts"):
        if not os.path.isdir(root):
            continue
        for dirpath, _dirnames, filenames in os.walk(root):
            for f in filenames:
                if "CJK" in f and f.lower().endswith((".ttc", ".otf", ".ttf")):
                    return f

    sys.exit(
        "[字体] 找不到任何中文字体文件，DXF 中的中文将无法正确显示。\n"
        "请手动指定，例如：\n"
        "  macOS:  export LX_FONT=/System/Library/Fonts/PingFang.ttc\n"
        "  Linux:  export LX_FONT=/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc\n"
    )


def mpl_setup():
    """配置 matplotlib 的中文字体（仅影响 PNG 预览；PDF/DXF 由 ezdxf 决定）。

    找不到中文字体时不中断，只警告 —— 预览图中文变方块是可接受的降级，
    不应该让整条出图流程失败。
    """
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.font_manager as fm

    available = {f.name for f in fm.fontManager.ttflist}
    chosen = [n for n in _MPL_NAMES if n in available]

    if not chosen:
        print("[字体] 警告：matplotlib 未找到中文字体，PNG 预览中的中文会显示为方块。")
        print("       PDF 与 DXF 不受影响（它们使用 ezdxf 的字体设置）。")
        print("       修复：pip install 一个中文字体，或设置 LX_FONT 后重试。")
        chosen = ["DejaVu Sans"]

    matplotlib.rcParams["font.family"] = "sans-serif"
    matplotlib.rcParams["font.sans-serif"] = chosen + ["DejaVu Sans"]
    matplotlib.rcParams["axes.unicode_minus"] = False
    return chosen


if __name__ == "__main__":
    print("DXF 字体：", dxf_font())
    print("matplotlib：", mpl_setup())


def make_portable(doc):
    """把 DXF 文字样式里的绝对路径改成纯文件名，并清理未使用的样式。

    为什么需要
    ----------
    渲染（matplotlib）需要字体的**完整路径**，否则中文渲染成空白。
    但 DXF 里存绝对路径的话，用户在自己电脑上打开就找不到了。

    所以在**渲染完成之后、保存 DXF 之前**调用本函数：
      - 绝对路径 → 纯文件名（如 "PingFang.ttc"），CAD 会去系统字体目录找
      - 顺手删掉 ezdxf 预置但没用到的样式，避免样式列表杂乱
    """
    # 1) 路径 → 文件名
    for style in doc.styles:
        f = style.dxf.get("font", "")
        if f and ("/" in f or "\\" in f):
            style.dxf.font = os.path.basename(f)

    # 说明：不删除 ezdxf 预置但未使用的样式。
    # setup=True 会带来 28 个 OpenSans/Liberation 样式，看着杂乱但无害；
    # 强行删除会因 DIMSTYLE 的 handle 引用而抛 DXFTableEntryError。
    # 保留它们比破坏 DXF 安全。
