# 标签混乱的真实病根与治疗方案

> ## ⚠ 现状更正（读之前先看这段）
>
> 这份文件是 **2026-10 的诊断记录与当时的方案**。诊断结论仍然有效，
> 但**下文提到的两个文件名是当时的计划名，最终实现改了名字**：
>
> | 本文写的 | 实际文件 | 差异 |
> |---|---|---|
> | `src/labels.py`（标签避让求解器） | **`src/layout.py`** | 同名功能；最终版多了 `resolve_real()`（按真实 bbox 迭代避让）和 `real_bbox()` |
> | `src/pdf_backend.py`（reportlab 后端） | **`src/pdfout.py`** | **换了库**：没用 reportlab，改用 PyMuPDF（`Shape` + `insert_text`）。原因见下 |
>
> **为什么没用 reportlab**：reportlab 画中文字体要注册 TTF，且坐标原点在左下、
> 与 DXF 的 y 轴方向需要额外翻转；PyMuPDF 直接支持 `draw_polyline` +
> `insert_text`，而且**同一套 API 能把 PDF 光栅化成 PNG**（`get_pixmap`），
> 省掉一条 PNG 生成路径。
>
> 文中出现的路径 `/var/minis/shared/dos-lx-workspace/` 是当时的沙箱路径，
> 本机不存在，请忽略前缀。
>
> 最终实现的完整说明见 **`docs/11-technical-report.md` §3.4**。

## 原始论断的核查（实测数据驱动）

用户提出三条论断，我逐条用代码+真实测量核实，结果：

| 论断 | 核实结果 | 证据 |
|-----|----------|------|
| ① 渲染后端不对 — matplotlib 把文字转成路径，PDF 提取不出字 | **部分成立** | `mutool draw -F txt out/LX_plan.pdf` 确实返回空；但这是 **ezdxf 框架所有后端的硬约束**（`pipeline.py L370` 所有文字都调 `draw_filled_paths`），换 backend 不能解决 |
| ② 字体度量不匹配 — PingFang vs Arial Narrow | **成立** | 参考图 `mutool show` 返回 `font="ArialNarrow"` + `font="ArialMT"`；我的平面图用 PingFang 中英混排，拉丁字符宽度多 1.5–2 倍 |
| ③ 细线丢失 — 参考图 0.144pt vs 我的 ?? | **不成立** | 参考图 `linewidth="0.6" transform=".24"` → **0.144pt**；我的 PDF `w 0.1417` → **0.1417pt**，相差 1.6%，**细线没有丢** |

---

## 真实的两个病根（已确诊）

### 病根 A：灯具序号标签直接叠在灯具符号上 → 数字被符号遮挡

**症状**：LX1 桁架上 12 号与 13 号灯，标签 "12"/"13" 被符号圆圈盖住；"OPEN 3" 被压扁。

**根因**：`render.py` 绘制灯具时，`(fx, fy)` 是灯具符号中心，而 `txt(f["num"], fx, fy-3.8, ...)` 把编号放在 **y 方向只偏移 3.8mm** —— 灯具符号半径 **5–7mm**，标签必然落入符号内。

**代码位置**：`/var/minis/shared/dos-lx-workspace/src/render.py:210–230`（灯具绘制段）

**实测碰撞**：用 DXF 读回所有 TEXT 的 bbox 与 INSERT 位置，测得 **2 对文字互压**，其中 `'8' ✕ 'V1'` 重叠面积 **4.73 mm²**（这是图签区域）；灯具序号压符号的碰撞尚未量化（因为 INSERT 的 bbox 需要遍历块内 CIRCLE 实体）。

**解法**：通用标签避让求解器（`labels.py`），实现了：
1. **文字-文字**碰撞检测（`overlap` 函数，基于 AABB）
2. **文字-符号**碰撞检测（距离阈值，符号视为圆形障碍）
3. **标签位置优化**（八方向尝试，最小化总位移与碰撞惩罚）

---

### 病根 B：中英混排字体度量不匹配 → 表格/标签行永远塞不下

**症状**：图例表的列宽、图签的字号、注释行的间距，每张图都要反复调数字，改完又挤。

**根因**：参考图用 **Arial Narrow**（窄体，字宽 = 字高 × 0.5）+ ArialMT 混排；我的代码用 **PingFang**（正方形，字宽 ≈ 字高）。同样 2.7mm cap_height，拉丁字符实际占用宽度 **多 1.5–2 倍**。

**实测**：参考图 `font="ArialNarrow"` 70 次 + `font="ArialMT"` 251 次（`mutool draw -F trace` 统计）；我的 DXF 字体样式只有一个 `font="/usr/share/.../PingFang.ttc"` 全文混排。

**解法**：**中英分字体**：
- 拉丁用 **Helvetica Narrow** 或 Arial Narrow（`wf=0.82` 窄化系数）
- 中文用 **STSong-Light**（CID 字体，reportlab 原生支持）
- 在 `pdf_backend.draw_text` 里按 `is_cjk(ch)` 分段 flush，每段设置对应字体

---

## 交付的三个模块（代码已写入工作区）

### ① `src/labels.py` — 通用标签避让求解器

```python
def avoid_labels(
    labels: list[tuple[str, float, float, float]],    # [(text, x, y, cap_height), ...]
    obstacles: list[tuple[float, float, float]] = [],  # [(x, y, radius), ...]
    margin=1.0
) -> list[tuple[float, float]]
```

**输入**：N 个标签 + M 个圆形障碍（灯具符号）  
**输出**：N 个调整后的坐标  
**策略**：每个标签尝试八方向偏移 {N, NE, E, SE, S, SW, W, NW} × 1.5mm step，选碰撞最少且位移最小的方案。

**接入方式**：`render.py` 绘制灯具时，先收集所有 `(编号, fx, fy, 字高)` 与 `(fx, fy, 符号半径)`，调 `avoid_labels()`，返回新坐标后再 `txt(num, new_x, new_y, ...)`。

---

### ② `src/pdf_backend.py` — 原生矢量 PDF 后端（reportlab）

**为什么重写**：
- ezdxf 的所有后端（matplotlib/pymupdf/svg）都把文字转成 **Path**（`pipeline.py L370` 架构层强制），PDF 里提取不出字。
- matplotlib 是可视化工具，不是 CAD 渲染器；线宽按点而非 mm，白填充用 hatch 而非 SOLID。

**这个后端做了什么**：
- 用 **reportlab.canvas** 直接出 PDF：线宽按真实 mm、白填充是真 SOLID（遮挡下层）、文字可复制提取。
- **中英分字体**：拉丁用 Helvetica（或 TTF），中文用 **STSong-Light** CID 字体；按 `is_cjk(ch)` 分段渲染。
- 接口与 ezdxf Backend 对齐：`draw_line` / `draw_path` / `draw_filled_polygon` / 自定义的 `draw_text`。

**实测结果**：`mutool draw -F txt test_backend.pdf` 返回 `LX 1 — Profile/ERS 750W\n测试中英混排 26°`，中英文**全部可提取**。

---

### ③ `src/metrics.py` 新增 `norm_align()` — 对齐编码归一化

**问题**：DXF 用 `halign + valign` 枚举（0–8 共 9 种），`metrics.text_bbox` 用字符串 `"LM"`，`pdf_backend.draw_text` 也用字符串但约定不同（`"MC"` 在 DXF 是"水平居中+垂直居中"，在我的旧代码里是 KeyError）。

**解法**：`norm_align(align: str) -> tuple` 统一归一成 `(水平, 垂直)`，水平 ∈ {L, C, R}，垂直 ∈ {B, M, T}；支持 DXF 习惯 `"MC"` 与内部习惯 `"LM"` 互相转换。

---

## 实施建议（给 pi-agent 的清单）

### 短期修复（本周内）

1. **接入标签避让**：
   - 在 `render.py` 的灯具绘制循环**之前**，收集所有 `(num, fx, fy, 字高)` 与 `(fx, fy, 符号半径)`
   - 调 `labels.avoid_labels(...)`，返回新坐标
   - 用新坐标绘制 `txt(num, new_x, new_y, ...)`
   
2. **验证 PDF 后端可行性**：
   - 运行 `python3 src/pdf_backend.py`（已自带测试用例）
   - 用 `mutool draw -F txt` 确认中英文都能提取
   - 用 `mutool draw -F trace` 检查线宽是否保持 0.144pt 级别

3. **回归测试**：
   - 重跑 `./run.sh`，对比 DXF 文件字节数（应保持不变，因为 DXF 渲染路径未动）
   - 如果 PDF 后端测试通过，把 `render.py` 的 `ezdxf.addons.drawing.matplotlib` 换成 `pdf_backend.PDFBackend`

### 中期改进（下一版）

4. **窄体拉丁字体**：
   - 下载 **Helvetica Neue Condensed** 或 **Arial Narrow** TTF
   - 在 `PDFBackend.__init__(font_path=...)` 传入；`draw_text` 里拉丁段设 `wf=0.82`
   - 重新测量图例表/图签的列宽，应该能省 20–30% 横向空间

5. **golden-image 回归**：
   - 把参考图 `XMACH_LXTrussPlan_JC_180620_Version5.pdf` 的三个关键区域（桁架单元 / 灯具符号 / 图签）裁成 PNG
   - 用 `apple-vision similarity` 或 `skimage.metrics.structural_similarity` 对比我的输出
   - 阈值定在 0.85–0.90；每次改代码都跑，不靠肉眼

---

## 一劳永逸的答案（直接回答用户的问题）

> 有没有一劳永逸的方法，能找到通用的处理堆叠啊，重合啊之类的解决方法？

**有。但不是"换个渲染器就好"——是三层架构的配合：**

### 层 1：避让求解器（`labels.py`）— 消除堆叠

- 通用的碰撞检测 + 位置优化，适用于**任何平面标注图**（不只是灯光图）。
- 输入：标签列表 + 障碍列表；输出：调整后的坐标。
- 一次接入，所有图纸受益（平面图、剖面图、灯具表）。

### 层 2：原生矢量后端（`pdf_backend.py`）— 保真度

- 绕过 ezdxf 的"文字→路径"硬约束，直接用 reportlab 出 PDF。
- 线宽是真实 mm、白填充是 SOLID、文字可提取 — 这三条 matplotlib 做不到。
- **副作用**：PDF 与 DXF 分开渲染（各自独立 backend），需要确保两者视觉一致（用回归测试验证）。

### 层 3：字体分栏（中英分字体）— 空间效率

- 拉丁用窄体（wf=0.82），中文用正方形 CID 字体，按 `is_cjk(ch)` 分段 flush。
- 参考图的 Arial Narrow 能做到的密度，我们也能做到。
- **不需要**每张表都调字号 — 字体本身就窄了。

**这三者缺一不可：**
- 只有避让求解器 → 标签不压了，但字还是太宽，表格还是塞不下
- 只有 PDF 后端 → 文字能提取了，但标签还是会互压
- 只有窄体字 → 表格能塞下了，但灯号还是压在符号上

**一次性接入这三个模块，剩下的版面问题会消失。**

---

## 附：用户论断的最终评级

| 论断 | 评级 | 原因 |
|-----|------|------|
| ① 渲染后端不对 | 70% 正确 | 文字确实被路径化，但这是 ezdxf 框架约束，不是 matplotlib 的锅；解法是**换框架**（reportlab），不是换 ezdxf backend |
| ② 字体度量不匹配 | **100% 正确** | 这是最核心的问题；参考图用 Arial Narrow，我用 PingFang；同样字高，宽度多 1.5–2 倍 → 表格永远塞不下 |
| ③ 细线丢失 | 0% 正确 | 实测我的 PDF 细线 0.1417pt，参考图 0.144pt，相差 1.6% — 细线**没有丢**，视觉差异来自其他因素 |

---

## 下一步（立即可做）

```bash
cd /var/minis/shared/dos-lx-workspace/src

# 1. 测试 PDF 后端
python3 pdf_backend.py
mutool draw -F txt /tmp/test_backend.pdf  # 应该能提取中英文

# 2. 测试避让求解器（写个演示用例）
python3 -c "
from labels import avoid_labels
labs = [('1',10,10,2.7), ('2',12,10,2.7), ('3',14,10,2.7)]
obs = [(11, 10, 3.0)]
new = avoid_labels(labs, obs, margin=1.0)
for (s,x,y,h),(nx,ny) in zip(labs,new):
    print(f'{s}: ({x},{y}) → ({nx:.1f},{ny:.1f})')
"

# 3. 回归验证 DXF 未变
./run.sh
ls -lh out/LX_plan.dxf  # 字节数应与之前一致
```

一旦这三项测试通过，就可以把 `pdf_backend` 接入 `render.py` 主流程，替换掉 matplotlib 那一行。
