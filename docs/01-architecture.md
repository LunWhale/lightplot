# 01 — 架构与原理

> **一句话**：AI 填数据，代码画图。
> 这份文档解释为什么必须这样，以及反面证据有多硬。

---

## 1. 问题：AI 直接操作 CAD 会怎样

用户最初的做法是让 AI 通过 MCP 直接操作 Vectorworks。结果：能做基础操作，但
"空间感弱、尺寸比例不对、看起来不专业、灯具用简陋形状代替"。

这不是操作问题，是**架构问题**。三条独立证据链：

### 1.1 GUI 自动化 agent 的成功率

| 基准 | 人类 | 最好模型 | 说明 |
|---|---|---|---|
| **OSWorld**（369 个真实桌面任务） | **72.36%** | **12.24%** | 跨应用工作流仅 **6%**；部分应用 **0%** |
| **BIMgent**（专为 BIM 软件做的 GUI agent） | — | **32%** | 所有基线模型 **0%** |

BIMgent 的 32% 是**专门为建筑建模软件定制的 agentic 框架**，不是通用 computer-use agent。
这就是 GUI 驱动 CAD 的天花板。

### 1.2 错误发现得太晚

**CUADebug** 标注了 204 条 OSWorld 失败轨迹，结论：

> "计算机使用 agent 通过截图和底层鼠标键盘操作与图形界面交互，但**因果错误可能早于终端失败**……任务推理与控制是最大的失败类别（110/204）。"

你在第 40 步才发现错了——那时几何已经全错。而且单一重执行只能把恢复率从
13.89% 提到 29.86%。

### 1.3 为什么增加算力没用

*Rethinking Inference-Time Scaling in Local Computer-Use Agents*：

> "额外计算往往带来递减收益，同时**改变失败模式**……失败从重复或停滞轨迹转向**过早的假成功**……更长的时程往往**延长错误轨迹而非纠正它**。"

---

## 2. 更根本的原因：LLM 做不了几何

### 2.1 SpatialEval（NeurIPS'24）

三个发现，第三个最致命：

> "(1) 空间推理构成显著挑战，竞争模型可能**落后于随机猜测**；
> (2) 尽管有额外视觉输入，VLM 往往**不如**对应的 LLM；
> (3) **当文字和图像同时可用时，只要有足够的文字线索，多模态模型就不再依赖视觉信息。**"

第 3 点直接杀死"渲染后让 AI 看一眼"的幻想——你给它文字描述，它就不看图了。

### 2.2 Visual Spatial Reasoning（VSR）

> "人类上限超过 95%，而 SOTA 模型只达到约 70%……被测模型**普遍无法识别物体朝向关系**。"

**朝向关系正是平面图编码的东西**——一个灯朝哪个方向打、光束角多少、焦点在哪。

### 2.3 根本机理

*From Symbolic to Geometric*：

> "这种能力主要是**符号性的**，源于对空间语言的模式匹配，而非对空间的**真正几何推理**。
> 因为 LLM 操作离散 token，它们缺乏对连续空间表示的**原生支持**、显式几何计算和结构化空间算子。"

### 2.4 外挂工具也救不了

*Limits of Spatial Imagery Reasoning in Frontier LLM Models* 给前沿 MLLM 外挂了一个
"Imagery Module"（渲染 + 旋转 3D 模型）：

> "性能低于预期，准确率最高只有 **62.5%**……即使把维护和操作整体 3D 状态的重担外包出去，系统仍然失败。"

### 2.5 CoT 会让它更差

*Chain-of-Thought Degrades Visual Spatial Reasoning*（17 个模型 / 13 个基准）：

> "CoT 提示**一致性地降低**视觉空间推理性能……模型遭受严重的捷径学习，即使图像不存在也会从文本先验中**幻觉出视觉细节**。"

---

## 3. 所以架构是这样

```
┌─────────────────────────────────────────────────────────┐
│  AI 的工作：只改 data/rig.yaml                            │
│  ── 按 schema 填字段，不做任何坐标运算                      │
└───────────────────────┬─────────────────────────────────┘
                        ▼
┌─────────────────────────────────────────────────────────┐
│  qc.py：确定性校验（失败即 raise，不产出错图）              │
│  ── 重号 / 通道冲突 / 未定义色片 / 不存在位置 / 缺字段      │
└───────────────────────┬─────────────────────────────────┘
                        ▼
┌─────────────────────────────────────────────────────────┐
│  render.py / section.py / schedule.py                   │
│  ── 线宽、图层、图签、图例全部写死在代码里                   │
│  ── 坐标由 Python 算，AI 不参与                             │
└───────────────────────┬─────────────────────────────────┘
                        ▼
                   DXF / PDF / CSV
```

### 三个关键性质

1. **模型从不算几何。** 它写数据，Python 算坐标。这消除了"符号 vs 几何"失败和单位漂移。
2. **输出是文本，可 diff、可复核、可版本化。** 错误定位到某一行，不是截图轨迹的第 37 步。
3. **数据与表现分离。** 灯具表、色片表、通道表是**同一份数据的不同视图**，
   所以图和表永远不会互相矛盾——这是手工做图最容易出错的地方。

---

## 4. 三个最有效的干预（按性价比）

### 4.1 写图前先审规格 ← 收益最大

**ProCAD / Clarify Before You Draw**：

> "几何描述可能欠定或内部不一致……现有微调模型倾向于**反应式地遵循用户指令并在文本模糊时幻觉尺寸**……一个主动澄清 agent，审计提示并只在必要时提出针对性澄清问题，以产出**自洽的规格**。"
>
> 结果：**Chamfer 距离降低 79.9%**，无效模型率 **4.8% → 0.9%**，超过包括 Claude Sonnet 4.5 在内的前沿闭源模型。

**做法极简**：缺尺寸就问，绝不编数字。这是所有干预里 ROI 最高的，而且几乎零成本。

### 4.2 渲染器自己报错（fail-closed）

参考 text-to-cad 的 `engineering-drawing` skill，它在画图时**逐字形测量**并打印诊断：

> - **"measures blank paper"**：标注的模型点没落在视图几何上。几乎总是因为零件从角落建起而脚本假设它是居中的。
> - **"annotation overlaps"**：两个标注印在一起……文字在渲染时逐字形测量，所以它在**墨迹**上触发而不是在标记上。
>
> "脚本 raise 而不是写出错误或缺失的文档……**渲染失败不留文件。**"

**这是最高杠杆的技巧**：坐标契约检查 + 版面碰撞检查 + 失败关闭，全部确定性、全部免费、全在渲染器里而不在模型里。

### 4.3 确定性复核，不信 VLM 打分

重新打开 DXF、重新解析 PDF、重新测量包围盒。
SolidWorks Automation Skill 的口号是对的：**"工具成功 ≠ 任务成功"**（Tool success is not treated as task success）。

视觉反馈只该用于**版面美观和大致轮廓**，不能用于测量。

---

## 5. 反面：被高估的做法

### "渲染后让 AI 看一眼再改"

**CADCodeVerify** 用 VLM 生成并回答验证问题，然后纠正偏差，结果：
**点云距离降 7.30%，成功率提升 5.0%**。

个位数。而且是补丁不是解药。加上 §2.1 的 SpatialEval 结论（有文字就不看图），
这个循环结构上就不可靠。

**结论**：如果要用，限制 2–3 次迭代，且**禁止它修改任何测量值**。

---

## 6. 对标：Vekta（Vectorworks 2026 内置 AI）

唯一找到的**舞台灯光专业** AI 案例，模式与我们一致：

- 在 Vectorworks 2026 里工作（macOS/Win）
- 能做：放灯、**patch DMX**、标尺寸、改名、填 worksheet、生成 paperwork
- **关键**：它"读取当前文档……**运行脚本**"，结果"落在你的 .vwx 里，**支持完整 undo**"
- 可复用 **Macro**："一键重放到任何文件，**运行时不消耗 AI**"

**这正是我们的架构**：AI 只写一次，之后固化成确定性宏。
区别是 Vekta 要订阅，我们开源可控。

---

## 7. 已验证的开源参考实现

| 项目 | 价值 |
|---|---|
| **text-to-cad**（~21k★, MIT） | 最完整的参考架构。12 个 skills，含 `engineering-drawing`（PDF 出图 + 空白纸/重叠检测）、`dxf`、`step-parts`（真实零件库检索 + sha256 校验） |
| **draftsmith** | 平面图**场景图引擎**：区分"事实（墙/门）"、"表现（DXF/SVG）"、"派生真相（房间/面积）"。**几何永远是算出来的，不是 AI 写的** |
| **AIBlueprint MCP** | ezdxf 无头出 DXF + LibreCAD 预览，跨平台，无需 AutoCAD 许可 |
| **autocad-mcp** | 双后端：能 GUI 时走 AutoLISP，否则走无头 ezdxf。**同一套工具 API** |

**成功项目的共同点**：
1. LLM 写代码或声明式 DSL；真实内核执行
2. 输出 fail-closed：raise，不写出看似合理的错文件
3. 标准件/符号靠**检索**，只有新结构才靠生成
4. 每次生成后确定性复核
5. 文档级 undo / 事务边界
6. **可重放的非 AI 路径**：验证过的模式固化成宏，零 token 且不会漂移

---

## 8. 参考链接

**空间推理**：[SpatialEval](https://arxiv.org/abs/2406.14852) ·
[VSR](https://arxiv.org/abs/2205.00363) ·
[From Symbolic to Geometric](https://arxiv.org/abs/2606.04381) ·
[CoT Degrades Spatial Reasoning](https://arxiv.org/abs/2604.16060) ·
[Limits of Spatial Imagery](https://arxiv.org/abs/2603.26779)

**Text-to-CAD**：[CADCodeVerify](https://arxiv.org/abs/2410.05340) ·
[ProCAD / Clarify Before You Draw](https://arxiv.org/abs/2602.03045) ·
[AIDL](https://arxiv.org/abs/2502.09819) ·
[CADIR](https://arxiv.org/abs/2608.00891) ·
[MUSE](https://arxiv.org/abs/2605.28579)

**GUI agent**：[OSWorld](https://arxiv.org/abs/2404.07972) ·
[BIMgent](https://arxiv.org/abs/2506.07217) ·
[CUADebug](https://arxiv.org/abs/2608.02643) ·
[ComponentBench](https://arxiv.org/abs/2608.18307)

**工具**：[ezdxf](https://github.com/mozman/ezdxf) ·
[build123d](https://github.com/gumyr/build123d) ·
[text-to-cad](https://github.com/earthtojake/text-to-cad) ·
[draftsmith](https://github.com/VedantS01/draftsmith) ·
[Vekta](https://vekta.design/help/vekta)
