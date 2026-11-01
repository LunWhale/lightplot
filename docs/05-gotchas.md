# 05 — 踩过的坑

> 每条都是**实际撞到过**的，不是理论风险。
> 遇到类似症状先查这里。

---

## 1. 中文字体（最容易崩）

### 症状
DXF 在 Vectorworks/AutoCAD 里打开，中文全是 `?` 或方块。
或者 Python 直接报 `font not found`。

### 原因
DXF 的**文字样式（style）必须指向一个真实存在的字体文件**（.ttf/.ttc/.otf），
不是字体名。而各系统字体路径完全不同：

| 系统 | 路径 |
|---|---|
| macOS | `/System/Library/Fonts/PingFang.ttc` |
| Linux | `/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc` |
| Windows | `C:/Windows/Fonts/msyh.ttc` |

### 解法
已写 `src/fonts.py` 自动探测。若失败，手动指定：
```bash
export LX_FONT=/System/Library/Fonts/PingFang.ttc   # macOS
```

### ⚠️ 最反直觉的一点：DXF 样式里必须写**文件名**，不能写绝对路径

实测对比（同一份文档，只改字体写法）：

| DXF 样式里的 font 字段 | 渲染结果 |
|---|---|
| `/usr/share/fonts/noto/NotoSansCJK-Regular.ttc`（绝对路径） | **中文全是 □ 方块** ❌ |
| `NotoSansCJK-Regular.ttc`（纯文件名） | **中文正常** ✅ |

原因：ezdxf 渲染时用自己的字体管理器**按文件名在系统字体里查找**。
传绝对路径它找不到，就回退到不含中文字形的默认字体。

**而且纯文件名本来就是 DXF 的正确写法**——用户的 CAD 会去系统字体目录找，
所以在 Mac 上打开也能正常显示。一个改动同时解决渲染和可移植性。

代码里由 `fonts.dxf_font()` 保证返回文件名，`fonts.make_portable()`
在保存前再兜底一次（防止有人手滑传了路径）。

### 另一层坑
matplotlib 用的**字体名**（`PingFang SC`），不是路径。
`fonts.mpl_setup()` 单独处理。找不到时只警告不中断——PNG 预览中文变方块可接受，
PDF/DXF 不受影响。

### 还有：200dpi 的 PNG 预览会让中文看起来"挤在一起"
这是**栅格化假象**，不是真 bug。用 400dpi 渲染或看 PDF 就正常：
```bash
pdftoppm -r 400 -png out/LX_plan.pdf /tmp/zoom
```
判断中文是否真的坏了，**看 PDF 或放大看**，别用 200dpi 的 PNG 下结论。

---

## 2. DXF 文字样式的 `setup=True`

`ezdxf.new("R2010", setup=True)` 会预置标准线型（DASHED/DASHDOT 等）。
**不加 `setup=True`，用 DASHED 线型会报错或画成实线。**

代码里已有，改的时候别删。

---

## 3. `Text.set_placement()` 不接受 `rotation` 参数

### 错误写法
```python
t.set_placement((x, y), align=..., rotation=90)   # TypeError
```

### 正确写法
```python
t.set_placement((x, y), align=TextEntityAlignment.CENTER)
t.dxf.rotation = 90
```

---

## 4. `/tmp/calendar.py` 遮蔽标准库

### 症状
matplotlib 导入时 fontTools 崩溃，报奇怪的 `module 'calendar' has no attribute ...`。

### 原因
`/tmp` 在 `sys.path` 里，`/tmp/calendar.py` 覆盖了标准库 `calendar`。

### 解法
脚本别放 `/tmp`，或者用专门目录（如 `/var/minis/workspace/_t/`）。

---

## 5. brace expansion 在 `sh` 下不生效

### 错误
```sh
mkdir -p "$W"/{data,src,out}    # 在 dash/sh 下创建了字面目录 "{data,src,out}"
```

### 解法
显式列出，或用 `#!/bin/bash`。
本项目 `run.sh` 用 `#!/bin/sh` 且不依赖 brace expansion。

---

## 6. 坐标系混淆：世界坐标 vs 图纸坐标

### 症状
光束锥画到图纸外面去了；标注落在空白处。

### 原因
图纸坐标是「mm / 比例 + 原点偏移」，世界坐标是真实毫米。
混淆时算出来的点会跑到纸外。

### 解法
`render.py` / `section.py` 里所有画图都经过 `w2s()`（world→sheet）转换。
**任何直接写 `msp.add_line((x, y), ...)` 的地方都要检查是不是漏了 `w2s`。**

实际踩过：剖面图光束底边用了 `0` 而不是 `Y0`，导致光束穿过整张图。

---

## 7. 剖面图只该画横向桁架

### 症状
吊杆（BOOM SL / BOOM SR）在中心线剖面上重叠成一个。

### 原因
中心线剖面切的是**横向桁架**，吊杆在侧台，不在剖切面上。
两者 `y` 坐标相同，投影到剖面就重合了。

### 解法
```python
for p in d["positions"]:
    if p.get("kind") == "h":   # 只画横向
        draw_position(...)
```
吊杆只在平面图出现，这是正确做法。

---

## 8. YAML 字段名不一致

### 症状
`KeyError: 'venue'`

### 原因
`rig.yaml` 用的是 `stage` / `meta`，脚本里写的是 `venue` / `show`。

### 解法
改脚本适配数据（数据是主，代码是仆）。
**加新字段时先 `python3 -c "import yaml; print(yaml.safe_load(open('data/rig.yaml')).keys())"` 看一眼。**

---

## 9. PDF 是 matplotlib 渲染的，不是真 CAD 矢量

### 说明
`render.py` 用 `MatplotlibBackend` 把 DXF 画成 PDF。
它输出矢量 PDF，但**不是 CAD 原生打印**——图层、线宽、字体替换都经过 matplotlib。

### 影响
- 屏幕看没问题
- 但要**印刷级**输出，应该让用户在 Vectorworks/AutoCAD 里打开 DXF 再打印
- matplotlib 找不到中文字体时，PDF 里的中文会是方块（DXF 不受影响）

### 已在 `AGENTS.md` 记录为已知限制。

---

## 10. DXF 导入 Vectorworks 后会不会变成 Spotlight 灯具对象？

### 状态
**未验证。** 不要当成已知事实。

### 推测（不可当依据）
Vectorworks 可以用 `Spotlight > Convert to Instrument` 之类功能把图块转成灯具对象，
但需要图块带特定记录格式（Record Format）。我们的 DXF block 没有这些记录。

### 如果要验证
在 Vectorworks 里导入 `out/LX_plan.dxf`，试着把灯具 block 转成 Instrument，
看是否需要手动补 record。**已列入 `TASKS.md` P1-1。**

---

## 11. GitHub API 速率限制（做检索时）

- 搜索 API：**10 次/分钟**（未认证）
- 核心 API：**60 次/小时**（未认证）

超过会返回 `null` 而不是报错——容易误判成"没有结果"。
检索时加 `sleep 8`。

---

## 12. 检索时的反爬

| 站点 | 症状 | 解法 |
|---|---|---|
| DuckDuckGo HTML | 验证码（选鸭子） | 换 Bing 或直接访问目标站 |
| Bing | `site:` 查询触发验证码 | 直接访问站点搜索页 |
| forum.vectorworks.net | Cloudflare "Just a moment…" | 用浏览器（能过挑战），`execute_js` 提取 `[data-role="commentContent"]` |

---

## 13. qc.py 的默认值陷阱

`qc.py` 会检查灯具是否缺 `beam`/`trim`。但**默认值会掩盖真实问题**。

### 实际踩到
第一次跑质检报"32 台灯全缺 beam"——因为 YAML 里真没写。
修复时用 `f.setdefault('beam', BEAM.get(f['type'], 30))` 按类型补，
**但这是权宜之计**。真实项目里每台灯的光束角应该来自设计决定，不是默认值。

### 原则
默认值可以用于"让流程跑通"，但**必须在 `TASKS.md` 里记一笔**，最终要换成真实值。
（当前唯一开着的这类项是 P0-1 真实场地数据。）

---

## 14. 别忘了检查"图和表是否一致"

### 这是最容易出的错
平面图画了 32 台灯，灯具表导出 31 行，采购单写 33 台。

### 为什么手工会错
因为是三份独立文件。

### 为什么我们不会错
因为三份都从同一个 `rig.yaml` 生成。
**但前提是你没在某个脚本里私自过滤。** 改 `schedule.py` 时注意别加隐藏的筛选条件。

---

## 15. 诚实性的坑（非技术）

早期我对原型图说"完美""真正专业"，用户不满——实际是"结构对了、细节还粗"。

**这个项目的用户明确讨厌"看起来专业其实空洞"的东西。**
报告缺口比粉饰更有价值。评审图纸时用 `docs/02-drafting-spec.md` §12 的清单逐项打勾，
不要凭感觉说"很好"。

---

## 16. em ≠ cap：字号单位陷阱（2026-10，代价最大的一次）

### 现象
用户反复说「要么就是雷霆大文字要么就特别小」「表格里太 dumb」。
我以为是排版问题，改了三轮行距、列宽、缩进，都没解决。

### 根因
两个 API 报告的「字高」不是同一个量：

| 来源 | 报的是什么 | Arial 换算 |
|---|---|---|
| pymupdf `span["size"]` | **em**（字号） | 1 em |
| DXF `TEXT.height` | **cap height**（大写字母高） | 0.7163 em |

Arial 的 `capHeight = 1467 / unitsPerEm 2048 = 0.7163`。

我从参考 PDF 里量出「正文 4.25」，就直接写进 `paper.FS["NOTE"] = 4.2`。
结果每一处文字都放大了 **1/0.7163 = 1.40 倍**。全图统一错，所以怎么调排版都不对。

### 修法
`src/paper.py` 顶部的 `FS` 表现在**全部是 cap 值**，并留了 `EM_TO_CAP = 0.7163`。
从参考图量到 em 后必须乘 0.7163 才能填进表里。
`src/metrics.py` 的 `em_for_cap()` / `cap_for_em()` 是唯一换算入口，别在别处手算。

### 教训
**任何「从参考图量出来的数」在写进代码前，先确认量的是什么单位。**
量对了但单位错了，比量错更难查——因为它全局一致。

---

## 17. DXF 属性读取会抛异常，不是返回 None

`ent.dxf.get("family")` 对未设置的属性**抛 `DXFAttributeError`**，不是返回 `None`。
Python 的 `dict.get` 习惯在这里是错的。

```python
# 错：整段静默失败
fam = ent.dxf.get("family")          # raises

# 对
fam = ent.dxf.family if hasattr(ent.dxf, "family") else None
```

### 为什么危险
这个异常被 `try/except` 吞掉后，PDF 后端**一个字都没画**，
而 `verify.py` 只读 DXF，全程绿灯。**零文字 PDF 通过了全部检查。**

### 教训
出图后端要有独立的「我画了多少东西」计数，并和 DXF 对账。
`verify.py` 现在查 `LX_plan.pdf` 的可抽取字符数（应 > 1500）和 CJK 计数（应为 0）。

---

## 18. 图层排序会毁掉桁架的层次

PDF 后端最初按 `paper.DRAW_ORDER` 图层顺序重排实体，为了让白底遮罩生效。
结果桁架变成**空心方块**：所有 `TRUSS_FILL` 先画，所有 `TRUSS` 后画，
斜撑被同段的填充盖掉。

### 正确做法
**按实体创作顺序画**（`for ent in ents:`），不按图层重排。
遮罩/填充的先后关系由 `src/draft.py` 在生成实体时就排好（见 `truss()` 的 draw order：
post → 左腿填 → 左腿线 → 右腿填 → 右腿线 → 下弦 → 上弦）。

### 教训
「按图层整理」在 CAD 里是自然的想法，但对**依赖遮挡顺序**的图形是灾难。
层次感来自绘制顺序，不来自图层。

---

## 19. 参考图的「表格」不是表格

`XMACH_LXTrussPlan` 右栏并不是「灯具数量表」，是**灯具规格面板**：
Typical / Light Instr Generic / Selecon Acclaim Fresnel 650w / 30 台 + Notes。

我照着做成「INSTRUMENT SCHEDULE（型号 / 数量 / 位置）」是我的设计决定，
不是抄参考图。**别把它当成「参考图里有所以我也要有」的证据。**

参考图右栏实测结构（mm，从上到下）：
面板标题 em 4.9 → 条目名 em 4.25 → 数量 em 4.25（右对齐）→ Notes 正文 em 4.25 行距 4.83。
数量列距内框右边缘 **11.8mm**（不是贴边）——用户明确要求「个数要离边缘远一点」。
