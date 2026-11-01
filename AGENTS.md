# AGENT.md — 舞台灯光设计出图工作流 · 操作手册

> 你（AI agent）接手了这套工作流。读完这一页你就能出图。
> **不要跳读「铁律」和「失败模式」两节** —— 那里的每一条都是踩过的坑。

---

## 0. 三十秒版本

```
data/*.yaml  ──►  src/qc.py  ──►  src/render.py / section.py  ──►  DXF + PDF
（你只改这个）     （不过就停）      src/schedule.py / cues.py       CSV + 表
                                   src/rationale.py / plain.py     文字材料
                                          ↓
                                    src/verify.py + tools/golden.py + src/hsc.py
                                          ↓
                                    不通过 → 不出图
```

**你只负责填 YAML。代码负责所有几何。**
原因见 §2 铁律 1 —— 一句话：LLM 算坐标必然出错，填字段不会。

**一条命令：**
```bash
./run.sh              # 全套出图
./run.sh --check      # 只校验数据，不出图（改完数据先跑这个）
```

---

## 1. 这套工作流交付什么

| # | 交付物 | 文件 | 谁看 |
|---|---|---|---|
| 1 | **灯光平面图** × 2 场景 | `out/LX_plan_kitchen.pdf`<br>`out/LX_plan_boston.pdf` | 导演、灯光师 |
| 2 | **Cue Sheet** | `out/cue_sheet.pdf` | 灯光操作员 |
| 3 | **Running Script**（提示本） | `out/running_script.pdf` | 舞台监督 |
| 4 | **剖面图**（辅助） | `out/LX_section.pdf` | 技术执行 |
| 5 | **300 词 rationale** | `out/rationale.pdf` | 考官 |
| 6 | **人话版说明** | `out/design_explained.pdf` | 完全不懂灯的人 |
| 7 | 灯具表 / 色片表 | `out/*.csv` | 执行 |

**HSC 场景下 1–5 是必交**，6 是加分（"加入视觉图像支撑戏剧愿景"是 marker 明确表扬的做法）。

---

## 2. 铁律（违反会毁掉整个项目）

### 1. 绝不让 LLM 直接算坐标或画线
如果你发现自己在想"这个灯应该放在 x=3200, y=1500"——**停下来**。
那是 `data/rig.yaml` 的事。让代码算。

### 2. 绝不编造尺寸
规格缺了就**问用户**。论文实测：写图前审规格能让无效模型率 4.8%→0.9%。
`data/rig.yaml` 里现在的场地是**虚构的**，见 §5。

### 3. 失败即停止
`qc.py` 报错就不许出图。宁可没有文件，也不要一张看起来对、实际错的图。
所有校验器都是**硬门禁**，不是建议。

### 4. 不要相信"看起来不错"
用确定性检查复核：重新打开 DXF、重新解析 PDF、数灯具、量框线、读位图。
VLM 自评不可靠 —— SpatialEval 发现"有文字线索时模型就不再依赖图像"。

### 5. 不要引入 GUI 自动化或 Vectorworks MCP
已核实：Vectorworks 无官方 MCP；社区三个全是 Beta；官方论坛有用户报告非官方 MCP 导致崩溃。
数据：GUI agent 在 OSWorld 只有 12.24%（人 72.36%）。

### 6. 图上不许出现中文
代码注释、文档可以中文；**画进图里的字必须英文**。
学校剧场、HSC 考官都读英文。混中文会显得没做完。

### 7. 不要有 AI 指纹
图上不许出现 "AI"、"auto-generated"、"GPT"、"model" 这类字样。
参考图的图签只有剧名、作者、剧场、日期、比例、图号、导演、设计师。

---

## 3. 数据文件怎么填

### 3.1 `data/rig.yaml` — 唯一的几何真相

```yaml
meta:
  profile: hsc              # hsc = 不出瓦数/DMX；industry = 出
  show: DEATH OF A SALESMAN
  playwright: ARTHUR MILLER
  venue: STUDIO THEATRE
  scale: 25                 # HSC 硬性 1:25
  director: I DON'T KNOW    # 不知道就写这个，别留空
  designer: Brooks Li

stage:
  width: 15000              # mm。**必须是实测值**
  depth: 9000
  grid_height: 8000         # 栅顶高度
  proscenium_height: 6500
  proscenium_x: -1200

positions:                  # 吊挂位置
- id: LX 1
  kind: h                   # h = 水平吊杆，v = 竖直 BOOM
  type: truss               # truss = 格构桁架，pipe = 空心管，line = 非吊挂构件
  x0: -7500
  x1: 7500
  y: 2400
  trim: 6500                # 高度 mm

zones:                      # 表演区（HSC 要求明确标出）
- id: K1
  x0: -7600
  y0: 3600
  x1: -1300
  y1: 8700

fixtures:
- unit: 101                 # 灯号，必须唯一
  pos: FOH LX               # 必须存在于 positions
  x: -3500                  # 沿杆位置
  type: profile             # 见 §3.2
  aim: 90                   # 出光方向，度。0=+X, 90=+Y(朝后墙), 180=-X, 270=-Y
  gel: L201                 # 色片，必须在 gels 里
  purpose: FACE F1          # 照哪里。HSC 要求每盏灯都有
  beam: 26                  # 光束角
```

**`aim` 是最容易搞错的一项。** `90` 表示灯口朝向后墙（舞台里侧）。
FOH 面光要照舞台 → `aim: 90`。BOOM SL 在舞台左侧要横穿舞台 → `aim: 0`。

### 3.2 灯具类型

| type | 图上标签 | 典型用途 |
|---|---|---|
| `profile` | Profile / ERS 750W | 面光、造型光、追光前身 |
| `fresnel` | Fresnel 650W | 柔和洗光 |
| `par` | PAR 500W | 侧光、强烈色彩 |
| `led` | LED Wash RGBW | 天幕、色彩变化（`gel: OPEN`，自己会变颜色） |
| `mover` | Moving Light 300W | 特殊、追人 |
| `follow` | Followspot 1200W | 追光（`gel: OPEN`） |
| `practical` | Practical | 台上实物光源（台灯、冰箱） |

### 3.3 `data/scenes.yaml` — 两个场景的对比

```yaml
scenes:
  kitchen:
    gel_override: {L132: "L202", L711: "L200"}
    levels: {FOH: 45, LX1: 30, LX2: 0, ...}
  boston:
    gel_override: {L201: "L132", ...}
    levels: {FOH: 70, LX1: 55, ...}
```

**HSC marker 明确要求两个场景对比够大。** `hsc.py` 会算色片差异项数和强度差异项数，
太少就报错。经验值：至少 3 项色片差异 + 2 项 ≥15% 的强度差异。

### 3.4 `data/cues.yaml` — Cue Sheet

```yaml
meta:
  numbering: "Continuous through the play, prefix LX"
  prefix: LX
  verified: false           # 没和制作脚本逐条核对前必须是 false

cues:
- q: "0.5"                 # 开演前状态用 0.x
  act: "A1 / pre-show"
  cue_point: "House open. Audience entering, preset in place."
  state: >
    这个 cue 之后画面变成什么样。写清楚哪些区亮/暗、什么颜色、
    台上被照亮的是哪里。
  lanterns: "401-404 (OPEN) @12%"
  fade: "-"
  notes: 给操作员的提示
```

**校验器会挡住的错误：**
- cue 号重号或没递增
- `lanterns` 里的灯号不存在
- 色片和 `rig.yaml` 里那台灯的不一致
- cue 点写"大约在中段"这类模糊描述（舞台监督没法喊 Go）

### 3.5 `data/script.yaml` — Running Script

每个 beat 一行：`act` / `who` / `line` / `cue` / `cue_after`。

**它和 `cues.yaml` 必须一一对应。** 校验器会查：
- script 里的 cue 号在 cues.yaml 存在
- cues.yaml 里每个 cue 都在 script 里出现
- 顺序一致
- 同一个 cue 不标两次

---

## 4. 自检机制（为什么可以相信输出）

三道门，每道都是**硬失败**：

### 门 1：`src/verify.py` — 几何与像素
重新打开产出的 DXF/PDF，验：
- 图框尺寸精确（841×594 / 420×297）
- 灯具数量对得上 `rig.yaml`
- **零重叠**（文字压文字、文字出框）
- **灯具朝向正确** —— 把每个符号多边形变换到图纸坐标，沿 Y 切片比两端宽度，
  判定镜片是否指向 `aim`。这条抓到过"全台灯 180° 反了"的 bug。
- **视觉语法自检（读位图）** —— 数桁架腹杆根数（应≈跨度/11.7687）、
  验证管线内部是空心的、量墨密度。

### 门 2：`tools/golden.py` — 黄金图回归
从参考图（`brief/reference/*.pdf`，Vectorworks 画的 NIDA 图纸）裁出构件级切片，
和当前出图对应区域做 SSIM。低于 0.60 就失败。

**关键防呆：任一裁块墨密度低于 1% 直接 FAIL。**
早先版本坐标标错，裁到空白区，两块全白 → SSIM=1.0 → 假通过。
现在不可能了。

### 门 3：`src/hsc.py` — HSC 合规
按 NESA 要求逐条检查：rationale 词数、两个场景的对比度、
每个表演区是否标出、每盏灯是否有 purpose、提示本是否齐。

---

## 5. 现在这套数据是假的（最重要的一条）

`data/rig.yaml` 里的场地是**虚构**的（"STUDIO THEATRE - BLACK BOX"，编的尺寸）。

**接手第一件事：向用户要真实条件。** 缺这三样不要往下做：

1. **场地**：舞台尺寸、可用吊点位置和高度、观众席形式
2. **设计意图**：走写实还是表现？时间线要不要跨越？
3. **设备限制**：有没有指定灯具型号、学校库存有什么

拿到后填进 `rig.yaml`，跑 `./run.sh`，图立刻变成真的。

**在这个发生之前，任何交付物都必须带假设声明。**
`src/plain.py` 的 honesty 节就是干这个的，不要删。

---

## 6. 失败模式（都是真踩过的）

| 症状 | 根因 | 修法 |
|---|---|---|
| 所有灯对着观众 | GDTF 符号镜片在 **-Y**，代码按 +Y 算 | `rotation = aim + 90`。`verify.py` 现在会抓 |
| 字大得离谱 | `pymupdf span["size"]` 是 **em**，DXF `TEXT.height` 是 **cap** | `EM_TO_CAP = 0.7163`，`paper.FS` 全存 cap |
| 标注白底框"没有" | 收尾避让器把 `FIXTURE_TXT` 图层的字**挪走**了，白底留在原地 | 该图层加入 `_fixed_layers` 排除 |
| 白底框盖不住字 | 按 cap 高度画框，字形还有上伸/下伸部 | 先放字 → 量真实 bbox → 删字 → 按 bbox 画白底 → 放回字 |
| 桁架变成空心方块 | `render()` 按图层排序，破坏了绘制层次 | 严格按 authored 顺序遍历实体 |
| 尺寸标注显示 60000 | `dimstyle "EZDXF"` 自带 `dimlfac=100` | 显式 `dimlfac = SCALE` |
| PDF 一个字都没有但 verify 全绿 | `dxf.get("family")` 抛异常被 `except` 吞掉 | 用 `hasattr` 守卫；未知实体要计数对账 |
| 楼梯像一排座位 | 画了矩形外框 + 平行线 | 只画两条侧边 + 踏步线 + UP 箭头，不封口 |
| **Vectorworks 说 "unrecognized file"** | ① `ezdxf.new(setup=True)` 注入 25 个系统里不存在的字体样式，dimstyle 悬空引用它们 ② `$EXTMIN/$EXTMAX` 是哨兵值 ③ `$LIMMAX` 写成 A3 ④ 23 个图层引用不存在的线型名 | `setup=False` + `src/dxfix.py`。见 `docs/10-vectorworks.md` |
| **双击 dxf 打不开** | Vectorworks 只注册了 DWG（`MDWG`），**没注册 .dxf**；macOS 上 .dxf 关联 LibreOffice | 必须走 `File > Import`，用 `out/cad/*` |
| **导入后黑乎乎** | ACI 7 = "随背景翻转"，白底遮罩在白底 CAD 上变黑 | 遮罩用真彩 `0xFFFFFF`（组码 420）；需 **R2004+**，不能降 R2000 |
| **导入后比例差 25 倍** | 模型空间画的是"图纸 mm"（841 宽），CAD 当成真实尺寸 | `dxfix.to_model_scale()` 放大到真实尺寸（21025 宽） |
| **Vectorworks 显示 1:5，改 1:1 就溢出** | layout 的 `paper_width` 还是 A3 (420)，`scale_denominator` 还是 1 | layout 设成 `paper=A1 841x594` + `scale 1:25`，使 `paper × scale = 内容尺寸` |
| **改了 header 但文件里没变** | ezdxf 在 `saveas()` 时把 `$EXTMIN/$EXTMAX/$LIMMIN/$LIMMAX` 重置 | 只能文本层补，且必须在 `saveas()` **之后** |
| **导入后图只占页面一半** | `$PLIMMAX`（**图纸空间**界限）还是 A3 420，而内容是 841 | 四处尺寸全部对齐：`$LIMMAX` / `$PLIMMAX` / `$EXTMAX` / layout paper |
| 符号简化后朝向检查误报 | 切片宽度法在稀疏点上不稳定 | 改比两端 `\|x - insert.x\|` 的均值 |
| DXF 里出现 `±` `©` | 图上写了非 ASCII | DXF 必须纯 ASCII，用 `+/-0`、`(C)` |

---

## 7. 换一部戏怎么用（换项目）

工作流**不绑定**《推销员之死》。换戏只改数据：

```bash
# 1. 复制一份数据
cp data/rig.yaml data/visit.yaml

# 2. 改 meta / stage / positions / fixtures / zones
#    （参考 §3 的字段说明）

# 3. 单独出图到别的目录，不覆盖原项目
.venv/bin/python src/qc.py       data/visit.yaml
.venv/bin/python src/render.py   data/visit.yaml --out out_visit
.venv/bin/python src/section.py  data/visit.yaml --out out_visit
.venv/bin/python src/schedule.py data/visit.yaml --out out_visit
```

**所有出图脚本都支持 `--out`。** 不用它就会覆盖 `out/` ——
这是实测踩过的坑（用另一部戏的数据跑剖面图，把主项目的 `LX_section.pdf` 覆盖了）。

已实测：把 32 台灯 / 7 个位置 / 15m 舞台换成
6 台灯 / 3 个位置 / 9m 舞台（Dürrenmatt《The Visit》），
平面图、剖面图、表格全部正确输出，图签自动变成新剧名。

**但 `cues.yaml` / `script.yaml` / `rationale.yaml` / `explain.yaml` 是剧本相关的，
必须重写。** 它们的校验器会告诉你缺什么。

---

## 8. 改代码的规矩

- **改数据不改代码。** 除非要加新能力。
- **每次改完必跑 `./run.sh`**，全绿才算完。
- **改视觉语法前先量参考图。** `docs/07-drafting-language.md` 里全是实测数字，
  不要凭印象调参。用户的原话：「不要相信看起来不错」。
- **改完视觉语法要重新 `--bless` 黄金图**，并说明为什么改。
- **DXF 只能写 ASCII。** 图上不要出现 `±` `©` `—` 这类字符，
  用 `+/-0` `(C)` `-` 代替。`dxfix.py` 会硬失败。
- **交付给 CAD 的 DXF 在 `out/cad/`，是真实尺寸（21025×14850）。**
  `out/*.dxf` 是图纸尺寸，只供 verify/golden 复核。两套不能混。
- **遮罩必须用真彩白 `0xFFFFFF`，不能用 ACI 7。** ACI 7 随背景翻转。
- **改图框尺寸要同步三处**：`paper.FRAME_MARGIN/FRAME_INNER`、
  `render.py` 的 `M/IN`、`section.py` 的 `draw_border()`。
  漏一处 `check_scale()` 就会把正确的图判成错误。
- **加新灯具类型**：`render.py` 的 `build_symbols()` 加 block，
  `qc.py` 的 BEAM 默认表加角度，`schedule.py` 的 `DMX_FOOTPRINT` 加占用。

---

## 9. 给用户的沟通方式

- 中文交流，术语中英混用（trim / cue / patch / gel 保留英文）。
- 用户是初学者，**不要假设他懂 Vectorworks**。
- 用户明确讨厌"看起来专业其实空洞"的东西。
  **诚实报告缺口比粉饰更有价值。**
- 已经犯过的错：早期说原型图"完美""真正专业"，实际是"结构对了、细节还粗"。
- 用户会读图。**只报绿色对勾不够，要给他看放大裁块。**

---

## 10. 文件地图

```
run.sh                     一键出图
AGENT.md                   你正在读的
README.md                  给人类看的说明
data/rig.yaml              ★ 灯具与场地（唯一需要改的几何数据）
data/scenes.yaml           ★ 两个场景的色片/强度
data/cues.yaml             ★ Cue Sheet
data/script.yaml           ★ Running Script 的 beat
data/rationale.yaml        ★ 300 词 rationale
data/explain.yaml          ★ 人话版说明的正文
data/symbols.json          厂家真实符号（自动生成，不要手改）
data/golden.json           黄金图基准（--bless 生成）

src/qc.py                  数据质检门禁
src/render.py              平面图
src/section.py             剖面图
src/schedule.py            灯具表/色片表
src/cues.py                Cue Sheet + 交叉校验
src/cuepdf.py              Cue Sheet 排版
src/running.py             Running Script + 对齐校验
src/rationale.py           300 词 rationale + 词数门禁
src/plain.py               人话版说明（自动插图）
src/hsc.py                 HSC 合规检查
src/verify.py              几何 + 像素复核
src/dxfix.py               DXF 可移植性后处理 + DWG 导出（Vectorworks 靠它）
src/paper.py               视觉语法常量（线宽/字号/图层）
src/draw.py                绘制原语（桁架/管线/白底遮罩）
src/metrics.py             字宽单一真相（唯一允许算宽度的地方）
src/pdfout.py              原生矢量 PDF 后端
src/layout.py              排版避让
src/gdtf_fetch.py          下载真实 GDTF
src/gdtf_symbol.py         从 GDTF 提取二维符号
src/fonts.py               跨平台字体探测
src/doctor.py              环境自检
tools/golden.py            黄金图回归
tools/extract_ref.py       从参考图扒构件几何
docs/07-drafting-language.md  视觉语法实测数据（调参前必读）
docs/09-selfcheck.md       三道自检门的原理与盲区
docs/10-vectorworks.md     DXF 打不开的诊断与修复（含 ezdxf 的 EXTMIN 坑）
docs/11-technical-report.md ★ 改代码之前必读：架构决定、缺陷全表、已知死路、安全边界
TASKS.md                   还没做的事（只记开着的项）
```

**改视觉语法之前，先读 `docs/07-drafting-language.md`。**
那里是参考图的实测数字（桁架节距 11.7687mm、管高 1.9476mm、字号换算
`EM_TO_CAP = 0.7163` 等）。凭印象调参会立刻跑偏。

---

*本文件随工作流演进更新。做了重大变更就回来改这里。*
