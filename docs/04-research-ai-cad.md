# 04 — AI 做 CAD：案例、坑、最佳实践

> 检索时间 2026-10。为"怎么让 AI 稳定产出技术图纸"这个问题找的实证答案。
> 结论已固化进本项目架构。

---

## 1. 失败级联（MUSE）

> "实验揭示了从**可执行代码**到**有效几何**再到**工程可用设计**的清晰失败级联，
> 即使最强的模型在细粒度工程标准上也只取得有限成功。"

| 失败类型 | 表现 |
|---|---|
| 编译/API 错误 | 方法名错、参数类型错、退化几何 `Circle(0)` |
| **坐标系错误** | 模型从角落建起，脚本假设居中 → 尺寸落在空白纸上 |
| 单位漂移 | mm/inch/cm 混用 |
| 拓扑错误 | 非流形实体、未封闭曲面、自交、零厚度 |
| 复杂度崩塌 | 基本几何还行，真实特征就崩 |
| **欠定 → 幻觉** | 缺失/冲突的尺寸被**编造**而不是提问 |
| 一次就对 | 单次采样常常错，且没有 ground truth 可挑 |
| 不可编辑 | 输出是 mesh 或扁平脚本，丢失构造历史 |
| 长时程失配 | 长操作序列偏离意图 |

**每一级要单独设关卡。** 见 §4。

---

## 2. 基准数字（校准期望）

| 研究 | 结果 |
|---|---|
| **CADCodeVerify** | 视觉自验证：点云距离降 **7.30%**，成功率提升 **5.0%** |
| **BlenderLLM** | "现有模型在生成准确 CAD 脚本上有显著局限"，只能靠任务专用微调 + 迭代自改进 |
| **Text2CAD** | 需要 ~170K 模型 / ~660K 标注 + 专门训练的 transformer |
| **AIDL** | 明确归因："困难来自**无法做空间推理**，以及需要引导模型完成复杂的长程规划" |

**关键洞察**：通用 LLM 路线不是免费的。要么微调，要么把几何外包给求解器。

---

## 3. IR / 内核选项

### 2D 机械与制造
- **CadQuery** — OCCT 上的 Python 参数化 CAD
- **build123d** — 更 Pythonic 的现代后继，2026 年多数 CAD agent 的默认目标
- **ezdxf** — Python DXF 事实标准，**读写真实 DXF**，输出能在 AutoCAD/LibreCAD 打开 ← **本项目用这个**
- **OpenSCAD** — CSG 语言，语言小且封闭，最适合 agent
- **FreeCAD** — 完整参数化应用 + Python 控制台，可无头

### 矢量图形
- **TikZ**：DeTikZify、TikZero — 合成**图形程序**而非图像，为"高几何精度和可编辑性"
- **SVG**：StarVector、SVGenius
- **图表即代码**：**Mermaid**、**D2** — 模型写极小的声明式文本，布局引擎算所有几何。
  对流程图、单线图、机架立面、信号流，这是**可靠性最高的选项**，因为**没有坐标可供模型弄错**

---

## 4. 最佳实践（已固化进本项目）

### 4.1 写坐标契约，并放进系统提示**和**校验器

明确声明：
- 原点位置（如"原点 = 底面中心，+Z 向上"）
- 视图投影约定（第一角 / 第三角）
- 图纸尺寸与绘图区原点（"A1 = 594×841 mm，坐标从左下角起"）
- 尺寸从哪里量（"标注自身的点，不是视图边缘"）

然后**断言它**：检查包围盒、检查标注见证点是否落在几何上。

text-to-cad 的 `"measures blank paper"` 诊断就是这个契约的违规检测器。

### 4.2 单位固定在类型系统里，不靠提示

API 边界统一毫米，**每个参数名带单位**（`hole_d_mm`），校验器拒绝无单位数字。
绝不让模型每次调用自己选 mm/cm/inch。

### 4.3 给参考图 + 已知正确的输出

同 IR 里的**一个完整正确样例**，比几段描述更有价值：
AIDL 在 few-shot 下**打败了有训练数据的 OpenSCAD**。

具体做法：`reference/` 目录放（a）完成的脚本（b）渲染出的 PDF/PNG（c）特征清单，
让 agent 模仿结构。

### 4.4 拆成可验证步骤，每步后检查

```
规格（已审计）→ IR 代码（能编译）→ 实体（有效 B-rep、流形、包围盒符合规格）
→ 视图（无空白纸标注、无重叠、有隐藏线）→ 图纸（图签、比例适配图框）
→ 导出（PDF/DXF 重新打开并解析）
```

每个关卡都是确定性断言。CADTests 证明**测试还能引导生成**，不只是评分。

### 4.5 永远以确定性检查收尾，绝不以 VLM 的意见收尾

重新读产物：解析 PDF、用 ezdxf 重开 DXF、重新测包围盒、从内核重读孔径。

SolidWorks skill 的口号是对的：**"工具成功 ≠ 任务成功"**。

视觉只用于**版面美观和大致轮廓**，不用于测量。

### 4.6 让失败响亮，让输出可复现

Fail closed：raise，不写文件。
text-to-cad 还把 PDF 做成**内容的纯函数**——"不写创建日期，所以未改动的图纸重建出完全相同的文件"，
免费获得字节级回归测试。

### 4.7 写之前先澄清 ← 最高 ROI

ProCAD：**Chamfer 降 79.9%**，无效模型率 **4.8% → 0.9%**。

### 4.8 把验证过的模式固化成非 AI 宏

Vekta 的拆法就是模板：AI 写一次脚本，之后是确定性 Macro，"重放结果完全一致……不用 AI，不消耗额度"。

把随机过程转换成版本化产物。

### 4.9 事务性编辑

绝不原地改源文件。CAD-DXF agent 的规则：
"LLM 从不碰原始 DXF……原文件永不被修改"
`Prompt → LLM Planner → ChangeSet (JSON) → Validator → EditEngine → Save-As`

---

## 5. 案例研究

| 项目 | 做什么 | 为什么重要 |
|---|---|---|
| **text-to-cad**（~21k★, MIT） | Agent 插件，给 Claude Code/Codex/Cursor 本地 CAD 工作流：STEP/STL/3MF/GLB、**工程图 PDF**、DXF 排版、DFM 检查、G-code | 最完整的开源参考实现。12 个 skills |
| **draftsmith** | 平面图**场景图引擎**：事实（墙/门/窗）与表现（DXF/SVG/PNG）与派生真相（房间/面积/相邻）分离 | 架构范式：**几何是派生的，从不由 LLM 编写** |
| **AIBlueprint MCP** | ezdxf 无头 DXF + LibreCAD 预览，为场地平面图/建筑制图而做 | render-then-look 的廉价跨平台做法 |
| **autocad-mcp** | 8 个整合工具，双后端：AutoLISP 实时 / 无头 ezdxf | 双后端是务实的折中 |
| **SolidWorks Automation Skill** | Agent → Skill/MCP → 执行核 → SolidWorks → 原生 SLDPRT+SLDDRW → PDF，自动尺寸复核 | **"工具成功 ≠ 任务成功"** |
| **Vekta** | Vectorworks 2026 内置 AI，舞台灯光：放灯、patch DMX、标尺寸、填 worksheet | **唯一专业灯光案例**。运行脚本 + 完整 undo + 可固化 Macro |
| **结构图 LLM agent** | ReAct + RAG，生成代码在 AutoCAD 里产出结构图（图签、平立剖、标准符号与线型） | 同行评议证据，支持代码生成路线 |
| **BIMgent** | BIM 建模的 computer-use agent | GUI 驱动 CAD 的诚实天花板：**32%** |

---

## 6. 工具调用可靠性：一个不舒服的发现

**Harness 和 effort 层级与模型同等重要。** Terminal-Bench 2.1 有三个公开榜单，三个不同赢家：

| 榜单 | 赢家 | 分数 |
|---|---|---|
| 官方 (tbench.ai) | Claude Code × Fable 5, xhigh | 83.8 |
| Artificial Analysis | GPT-5.6 Sol, xhigh | 89.5 |
| vals.ai | GPT-5.6 Sol, Terminus 2 harness | 85.77 |

> "同一个基准，官方榜、Artificial Analysis 和 vals.ai 各自加冕不同的赢家。
> 差距不是刷分——是 **harness、effort 层级和快照日期**。"

**对你的意义**：**在你自己的 harness 里、用你自己的任务**去测模型。
5 分的榜单差距，小于你的工具 schema、重试策略、提示脚手架带来的方差。

其它数据：
- **ComponentBench**：只改观察/动作空间，同一模型成功率变动 **>30%**
- **CUADebug**：单次重执行把恢复率从 13.89% 提到 29.86%
- **CAST**：长时程有状态场景中，"单个错误动作可能导致不可逆的任务失败"

---

## 7. 给本项目的一句话总结

> 别让模型算几何。让它填数据，让 Python 算。
> 别信"看起来对"。用确定性检查复核。
> 规格缺了就问，绝不编。

---

## 8. 参考链接

**空间推理**：[SpatialEval](https://arxiv.org/abs/2406.14852) ·
[VSR](https://arxiv.org/abs/2205.00363) ·
[From Symbolic to Geometric](https://arxiv.org/abs/2606.04381) ·
[CoT Degrades](https://arxiv.org/abs/2604.16060)

**Text-to-CAD**：[CADCodeVerify](https://arxiv.org/abs/2410.05340) ·
[ProCAD](https://arxiv.org/abs/2602.03045) ·
[AIDL](https://arxiv.org/abs/2502.09819) ·
[CADIR](https://arxiv.org/abs/2608.00891) ·
[MUSE](https://arxiv.org/abs/2605.28579) ·
[CADTests](https://arxiv.org/abs/2605.07807) ·
[Consensus Selection](https://arxiv.org/abs/2608.09706) ·
[BlenderLLM](https://arxiv.org/abs/2412.14203)

**GUI agent**：[OSWorld](https://arxiv.org/abs/2404.07972) ·
[BIMgent](https://arxiv.org/abs/2506.07217) ·
[CUADebug](https://arxiv.org/abs/2608.02643) ·
[ComponentBench](https://arxiv.org/abs/2608.18307)

**工具**：[ezdxf](https://github.com/mozman/ezdxf) ·
[text-to-cad](https://github.com/earthtojake/text-to-cad) ·
[draftsmith](https://github.com/VedantS01/draftsmith) ·
[autocad-mcp](https://github.com/puran-water/autocad-mcp) ·
[Vekta](https://vekta.design/help/vekta) ·
[Mermaid](https://github.com/mermaid-js/mermaid) ·
[D2](https://github.com/d2lang/d2)
