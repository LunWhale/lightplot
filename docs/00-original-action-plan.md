# 用 AI 出专业灯光图：可行路线（Mac mini + DeepSeek）

> 目标：不学 Vectorworks，产出达到 NIDA《EX MACHINA》那两张图水准的图纸。
> 本文是**行动方案**，不是资料汇编。

---

## 一、先诊断：为什么 AI 直接操作 Vectorworks 必然失败

你遇到的三个症状，根因只有一个——**你让 LLM 去做几何**。

| 你的症状 | 真实原因 |
|---|---|
| 空间感弱、尺寸不对 | LLM 不擅长坐标、拓扑、比例。它逐条"猜"数字，没有全局约束 |
| 不专业、没注释、线不对 | GUI 自动化只能"画线"，不理解图层/线宽/图例/图签的**体系** |
| 灯具用简陋形状 | 它不知道 USITT RP-2 符号，也没有可复用的符号库 |

GUI 自动化（点鼠标、AppleScript）在精密制图上**结构性不可靠**：没有坐标系、没有事务、误点无法回滚、每次结果都不同。Vectorworks 官方论坛已有用户报告非官方 MCP 导致崩溃。

**结论：不要让 AI 画图。让 AI 写数据，让代码画图。**

---

## 二、正确架构（这是唯一可靠的路）

```
① 灯具数据（YAML / JSON）      ← AI 只负责填这个
        ↓
② 校验器（Python）             ← 确定性：查重号、查地址冲突、查漏字段
        ↓
③ 渲染器（Python + ezdxf）     ← 确定性：符号库、图层、线宽、图签、标注
        ↓
④ 输出：DXF（可进 Vectorworks 编辑）+ PDF（给人看）+ CSV（调度表）
```

**为什么这样能专业：**
- 线宽、图层、图签、图例是**代码里写死的一次性定义**，永远不会走样
- 灯具符号是**块（Block）**，按真实尺寸定义，一次做好终身复用
- 所有表（灯具表/色片表/回路表/DMX 表）都是**同一份数据的排序视图**——这正是 Vectorworks + Lightwright 的架构

**专业图包的本质**（USITT 2025 推荐做法）：
> 每个调度表都是**同一份灯具记录的不同排序**。
> 按位置排 → 灯具表；按 channel 排 → 通道表；按 universe/address 排 → DMX 表；按型号排 → 采购单。

数据模型建一次，渲染无数份文档。**这是你要抓的核心。**

---

## 三、你不需要买的东西（省钱的坏消息/好消息）

| 你想的 | 结论 |
|---|---|
| 淘宝买灯具 3D 模型 | ❌ **完全没用**。3ds Max / OBJ / FBX 是渲染模型，不是 2D 平面符号。灯光图要的是**俯视轮廓 + 挂点 + 光束角**，3D 模型给你一堆无用的面 |
| 用 Blender | ⚠️ 只在你要做 **3D 预览渲染**（previz）时才有用，不是出图工具 |
| 买 Vectorworks | 💡 教育版免费；但**你不需要它来出图**，只需要它来「打开 DXF 微调」 |
| 装一堆 MCP | ❌ 不需要。你只需要**文件读写 + 跑 Python**，这是内置能力 |

---

## 四、你真正需要的东西（全部免费）

### 1. 软件（Mac mini 上）
```bash
# 用 uv 管 Python 环境（推荐，干净）
curl -LsSf https://astral.sh/uv/install.sh | sh

uv venv ~/lx-venv
source ~/lx-venv/bin/activate
uv pip install ezdxf pyyaml matplotlib
```

### 2. 灯具符号来源（三档，从易到难）
| 来源 | 说明 | 难度 |
|---|---|---|
| **自己写块** | 我给你的脚本里已有 7 种（Profile/Fresnel/PAR/LED/Mover/Followspot/Practical），按 USITT RP-2 简化绘制 | ⭐ 已可用 |
| **GDTF 库** | [gdtf-share.com](https://gdtf-share.com) 免费下载真实灯具定义，含 3D 模型 + 尺寸。可解析出真实长宽用于符号 | ⭐⭐ |
| **Vectorworks 符号库** | VW 自带 Spotlight 灯具符号，可导出 DXF 复用（教育版也能导） | ⭐⭐⭐ |

> **关键：符号只要"按真实尺寸、按标准形状"就够了。** 不需要精确到每颗螺丝——Vectorworks 自带的符号也只是示意。

### 3. 参考图纸（学"专业感"从哪来）
- [Live Design Light Plot Library](https://www.livedesignonline.com/livedesignonlinecom/lighting-plot-library) — 百老汇真实图纸免费下载
- [The Lighting Archive](https://thelightingarchive.org) — 含《狮子王》cue sheet
- **USITT RP-2 / GRP 5.0 / Lighting Documentation RP 2025** — 三份 PDF，是"专业"的定义

---

## 五、MCP 到底要不要？要哪些？

**答案：基本不要。** 你已经有 shell + 文件读写 + Python 执行——这就是完整的"代码执行 MCP"能力。

真要装，只需这 3 个（按需）：
| MCP | 用途 | 必要性 |
|---|---|---|
| **Filesystem**（官方） | 让 agent 安全读写项目目录 | ⭐⭐⭐ 必需 |
| **DesktopCommander** | 终端 + 文件搜索 + diff 编辑，10k★，跨平台 | ⭐⭐⭐ 推荐 |
| **vectorworks-bridge** / **giorgiomoroder/vectorworks-mcp** | 若你确实要读写 .vwx 里的灯具数据 | ⭐ 可选，Beta |

**明确不要**：Blender MCP（除非做 previz）、AutoCAD MCP（Mac 版不支持 AutoLISP）、任何 GUI 点击类 MCP。

---

## 六、分阶段路线（建议照这个顺序）

### 阶段 0：跑通（1 天）
1. 装 uv + ezdxf
2. 运行我给你的 `dos_lx_plan.py`
3. 得到 PDF + DXF，用任意看图软件打开确认

### 阶段 1：数据化（2–3 天）
把硬编码的灯具列表抽成 `rig.yaml`：
```yaml
venue:
  name: "Studio Theatre"
  stage: {width: 9000, depth: 7000, datum: 0}
positions:
  - {id: LX1, type: truss, y: 2000, trim: 6500}
  - {id: LX2, type: truss, y: 4500, trim: 6500}
fixtures:
  - {unit: 201, pos: LX1, x: -3500, type: fresnel, gel: L132, ch: 11, purpose: "K1 warm"}
```
AI 只改这个文件 → 跑渲染 → 看图。**这就是你的日常循环。**

### 阶段 2：补齐图包（1 周）
按 USITT 清单，把 4 张图做齐：
1. **LX Plan**（平面）✅ 已有
2. **Section**（剖面，标 trim 高度 + 人形比例）
3. **Instrument Schedule**（灯具表，按位置排序）
4. **Cue Sheet**（cue 表）

### 阶段 3：接进 Vectorworks（可选，1 天）
DXF 拖进 VW → 符号自动成为可编辑对象 → 用 Spotlight 的 `Create Instrument` 转成真灯具。
**这样你既不用学 VW，又能拿到 VW 的原生能力。**

---

## 七、给 AI 的提示词模板（关键）

不要问"帮我画一张灯光图"。要这样：

```
读 lx/rig.yaml，然后：
1. 在 LX2 位置增加 4 台 Fresnel，x = -3300/-1100/1100/3300，
   gel L201，channel 从 41 开始递增，purpose "MID AREA"
2. 检查：unit 编号是否重复、channel 是否冲突、每个 fixture 是否缺 gel/type
3. 跑 python3 render.py，把报错修到通过
4. 生成 PDF，然后你自己看图，指出哪里标注重叠
```

**要点：**
- 给**坐标**，不要给"左边一点"
- 让它**先校验再渲染**
- 让它**渲染后自己看图**（vision 反馈闭环）
- 一次只改一类东西

---

## 八、验收清单（专业 vs 业余的分界线）

- [ ] 有图签（项目/剧目/导演/设计师/日期/比例/图号/修订表）
- [ ] 有图例，每个符号都有定义 + 数量
- [ ] 有线宽层次（0.15 / 0.30 / 0.60 / 0.70 mm），布景压灰
- [ ] 灯具按真实比例、指向焦点、摇头灯画扫描半径
- [ ] 每个灯有 unit 编号 + 色片号
- [ ] 尺寸标注：基准面写清楚，trim 到管底
- [ ] 有 NOTE 区块（挂灯/对光/安全说明）
- [ ] 有色片表、灯具表
- [ ] 图幅网格（1–12 / A–H），可交叉引用
- [ ] 所有表的数据与图**完全对得上**

---

## 九、一句话总结

> **不要让 AI 当绘图员，让它当资料员。**
> AI 填 YAML，Python 画图，DXF 进 Vectorworks。
> 这条路不依赖任何 MCP、不需要学 CAD 软件、不需要买模型。

---

## 十、四路检索的实证结论（2026-10 核实）

### 10.1 你的方案是可行的 —— Pi + DeepSeek V4.1 Flash 都能用

| 你的说法 | 核实结果 |
|---|---|
| "DeepSeek v4.1 flash" | ✅ **存在**。模型名 `DeepSeek-V4.1-Flash`，API 名 `deepseek-flash`，2026-09-10 发布。552B MoE，输入 8B/输出 16B 激活参数，**原生视觉**，1M 上下文，支持工具调用。 |
| "pi-agent" | ✅ 指 **Pi**（pi.dev，Earendil，MIT，~116k★）。终端 harness，**原生 MCP 支持**（stdio + HTTP），可用 `models.json` 接 OpenAI/Anthropic 兼容端点。 |
| 接 DeepSeek 到 Pi | ✅ 走 `https://api.deepseek.com`（OpenAI 格式）或 `/anthropic`（Anthropic 格式）。 |
| 备选 harness | Claude Code（MCP 生态最成熟，DeepSeek 官方文档直接支持）、OpenHands（沙箱）、Codex CLI（一条命令接 DeepSeek）。 |

**重要修正**：我前面说"不确定 V4.1 flash 是否存在"——是我错了，它存在。

### 10.2 为什么"AI 直接操作 Vectorworks"必然失败（有数据）

| 证据 | 数字 |
|---|---|
| OSWorld（真实桌面任务，人 vs AI） | 人 **72.36%**，最好模型 **12.24%**，跨应用工作流仅 **6%** |
| BIMgent（专门为 BIM 软件做的 GUI agent） | **32%** 成功率（SOTA），所有基线 **0%** |
| CUADebug（204 条失败轨迹分析） | "**因果错误早于终端失败**"——你在 40 步后才发现错了 |
| 推理时增加算力 | 不是变好，而是把"卡住"变成"**过早假成功**" |
| 换 harness（同一模型） | 成功率波动 **>30%** |

这就是你"空间感弱、维持不对"的**可测量原因**，不是你操作问题。

### 10.3 为什么 LLM 天生做不了几何（这是关键机理）

- **SpatialEval（NeurIPS'24）**：竞争模型的空间推理**可能低于随机猜测**；更致命的是——**"当同时提供文字和图像时，只要文字线索足够，多模态模型就不再依赖图像"**。
- **VSR**：人类 >95%，SOTA 模型约 70%；**"模型普遍无法识别物体朝向关系"**——而平面图/剖面图编码的正是朝向。
- **From Symbolic to Geometric**：LLM 的空间能力是**符号层面的模式匹配**，不是**几何计算**；"LLM 操作离散 token，缺乏连续空间表示、显式几何计算和结构化空间算子"。
- **CoT 会让空间推理变差**（17 个模型 / 13 个基准）。
- 即使外挂 3D 模块，上限也只有 **62.5%**。

**所以：不要让模型算坐标。让它写程序，让内核算。**

### 10.4 最有效的三个干预（按性价比排序）

1. **写图前先审规格（spec audit）** —— ProCAD 论文：**Chamfer 距离降低 79.9%**，无效模型率 4.8%→0.9%。做法极简：缺尺寸就**问**，绝不编数字。这是**单项收益最大**的改动。
2. **渲染器自己报错（fail-closed）** —— 参考 text-to-cad 的 `engineering-drawing` skill：画的时候逐字形测量，检测"**标注落在空白纸上**"（坐标契约违规）和"**标注重叠**"，**raise 而不是输出一张错图**。失败不留文件。
3. **确定性复核，不信 VLM 打分** —— 重新打开 DXF、重新解析 PDF、重新测量包围盒。SolidWorks skill 的口号：**"工具成功 ≠ 任务成功"**。

反面：**"渲染后再看"被高估了**。CADCodeVerify 只带来 7.3%/5.0% 提升，且 SpatialEval 证明模型有文字就不看图。**限制迭代 2–3 次，且禁止它改测量值。**

### 10.5 直接对标的商业产品：Vekta（Vectorworks 内置）

这是唯一找到的**舞台灯光专业**AI 案例，模式值得抄：
- 在 Vectorworks 2026 里工作（macOS/Win），能做"放灯、**patch DMX**、标尺寸、改名、填 worksheet、生成 paperwork"
- **关键**：它"读取当前文档…**运行脚本**"，结果"落在你的 .vwx 里，**支持完整 undo**"
- 可复用 **Macro**："一键重放到任何文件，**运行时不消耗 AI**"

**这正是我们的架构**：AI 只写一次脚本，之后固化成确定性宏。区别是 Vekta 要订阅，我们是开源可控。

### 10.6 已验证的开源参考实现

| 项目 | 价值 |
|---|---|
| **text-to-cad**（~21k★, MIT） | 最完整的参考架构：12 个 skills，含 `engineering-drawing`（PDF 出图 + 空白纸/重叠检测）、`dxf`、`step-parts`（真实零件库检索 + sha256 校验） |
| **draftsmith** | 平面图**场景图引擎**：区分"事实（墙/门）"与"表现（DXF/SVG）"与"派生真相（房间/面积）"——**几何永远是算出来的，不是 AI 写的** |
| **AIBlueprint MCP** | ezdxf 无头出 DXF + LibreCAD 预览，跨平台，无 AutoCAD 许可 |
| **autocad-mcp** | 双后端模式：能 GUI 时走 AutoLISP，否则走无头 ezdxf。**同一套工具 API** |

### 10.7 对当前原型的改进清单（按优先级）

基于以上证据，`render.py` / `section.py` 应该补：

1. **坐标契约检查**：每个标注点必须落在几何上，否则报错（对应"measures blank paper"）
2. **标注重叠检测**：逐字测量宽度，检测碰撞后自动偏移或报错
3. **规格审计**：rig.yaml 缺 `trim`/`beam`/`gel` 时**报错而不是默认值**
4. **失败不留文件**：校验不过就不写 DXF/PDF
5. **确定性输出**：不写时间戳，同一输入产出字节级相同的文件
6. **样本共识**：同一份数据出 3 个版式候选，选几何最一致的那个

