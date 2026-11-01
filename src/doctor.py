"""环境自检 —— 接手第一件事就是跑这个。

用法：
    python3 src/doctor.py

它会检查：Python 版本、依赖包、中文字体、数据文件、能否出图。
全部通过说明环境就绪；有失败项会给出具体修复命令。
"""
import os
import subprocess
import sys

OK = "[ OK ]"
BAD = "[FAIL]"
WARN = "[WARN]"


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    fails = 0
    warns = 0

    print("=" * 62)
    print(" 舞台灯光出图工具链 —— 环境自检")
    print("=" * 62)

    # --- Python ---
    v = sys.version_info
    if v >= (3, 9):
        print(f"{OK} Python {v.major}.{v.minor}.{v.micro}")
    else:
        print(f"{BAD} Python {v.major}.{v.minor} —— 需要 3.9+")
        fails += 1

    # --- 依赖 ---
    deps = [("ezdxf", "ezdxf"), ("yaml", "pyyaml"), ("matplotlib", "matplotlib"),
            ("numpy", "numpy"), ("PIL", "Pillow"), ("trimesh", "trimesh"),
            ("skimage", "scikit-image"), ("svgelements", "svgelements"),
            ("pymupdf", "pymupdf")]
    for mod, pkg in deps:
        try:
            m = __import__(mod)
            ver = getattr(m, "__version__", "?")
            print(f"{OK} {pkg} {ver}")
        except ImportError:
            print(f"{BAD} {pkg} 未安装 —— 运行: pip3 install {pkg}")
            fails += 1

    # --- 真实灯具符号缓存 ---
    syms = os.path.join(root, "data", "symbols.json")
    gdtf_dir = os.path.join(root, "data", "gdtf")
    if os.path.exists(syms):
        try:
            import json
            with open(syms, encoding="utf-8") as f:
                sj = json.load(f)
            miss = [k for k, v in sj.items() if "top" not in v and "usitt" not in v]
            if miss:
                print(f"{WARN} symbols.json 有 {len(miss)} 种缺 top 视图: {miss}")
                warns += 1
            else:
                print(f"{OK} 灯具符号 {len(sj)} 种（data/symbols.json）")
        except Exception as e:
            print(f"{BAD} symbols.json 解析失败: {e}")
            fails += 1
    else:
        print(f"{WARN} 缺 data/symbols.json —— run.sh 会自动提取")
        warns += 1

    if os.path.isdir(gdtf_dir):
        n = len([x for x in os.listdir(gdtf_dir) if x.endswith(".gdtf")])
        print(f"{OK} GDTF 原始文件 {n} 个（data/gdtf/）")
    else:
        print(f"{WARN} 缺 data/gdtf/ —— run.sh 会自动下载")

    # --- 场景数据 ---
    scenes = os.path.join(root, "data", "scenes.yaml")
    if os.path.exists(scenes):
        try:
            import yaml as _y
            with open(scenes, encoding="utf-8") as f:
                sc = _y.safe_load(f).get("scenes", {})
            print(f"{OK} 场景 {len(sc)} 个: {', '.join(sc)}")
        except Exception as e:
            print(f"{BAD} scenes.yaml 解析失败: {e}")
            fails += 1
    else:
        print(f"{WARN} 缺 data/scenes.yaml —— 无法出分场景平面图")
        warns += 1

    # --- 中文字体 ---
    sys.path.insert(0, here)
    try:
        import fonts
        try:
            fp = fonts.dxf_font()
            print(f"{OK} 中文字体 {fp}")
        except SystemExit as e:
            print(f"{BAD} 中文字体缺失\n      {e}")
            fails += 1
        mpl = fonts.mpl_setup()
        if "DejaVu Sans" in mpl and len(mpl) == 1:
            print(f"{WARN} matplotlib 无中文字体，PNG 预览中文会是方块（PDF/DXF 正常）")
            warns += 1
        else:
            print(f"{OK} matplotlib 中文字体 {mpl[0]}")
    except Exception as e:
        print(f"{WARN} 字体模块异常: {e}")
        warns += 1

    # --- 数据文件 ---
    rig = os.path.join(root, "data", "rig.yaml")
    if os.path.exists(rig):
        try:
            import yaml
            d = yaml.safe_load(open(rig, encoding="utf-8"))
            n = len(d.get("fixtures", []))
            print(f"{OK} data/rig.yaml —— {n} 台灯具，{len(d.get('positions', []))} 个位置")
        except Exception as e:
            print(f"{BAD} data/rig.yaml 解析失败: {e}")
            fails += 1
    else:
        print(f"{BAD} 缺少 data/rig.yaml")
        fails += 1

    # --- 目录 ---
    outd = os.path.join(root, "out")
    os.makedirs(outd, exist_ok=True)
    print(f"{OK} 输出目录 out/")

    # --- 端到端试跑 ---
    print("\n--- 试跑质检 ---")
    r = subprocess.run(
        [sys.executable, os.path.join(here, "qc.py"), rig],
        capture_output=True, text=True, cwd=root,
    )
    if r.returncode == 0:
        print(r.stdout.strip() or "(无输出)")
        print(f"{OK} 质检通过")
    else:
        print(r.stdout.strip())
        print(r.stderr.strip())
        print(f"{BAD} 质检未通过 —— 数据有错误，见上")
        fails += 1

    # --- 汇总 ---
    print("\n" + "=" * 62)
    if fails == 0:
        print(f" 环境就绪（{warns} 条提示）。可以运行： ./run.sh")
    else:
        print(f" 有 {fails} 项需要修复，{warns} 条提示。按上面的提示处理。")
    print("=" * 62)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
