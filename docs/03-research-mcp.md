# 03 — MCP 生态检索结论

> 检索时间：2026-10。目的：确认「用 MCP 让 AI 操作 Vectorworks」是否可行。
> **结论：不可行，不要走这条路。只需要文件读写 + Python 执行能力。**

---

## 1. 直接答案

| 问题 | 答案 |
|---|---|
| Vectorworks 有官方 MCP 吗？ | **没有。** Vectorworks 官方 GitHub 组织只有 `developer-scripting`、`developer-sdk`、`developer-worksheets`、`developer-content`，无 MCP 仓库 |
| 有社区版吗？ | 有 3 个，**全是 Beta**，star 数 0–15 |
| 能用吗？ | 官方论坛有用户报告**非官方 MCP 导致 Vectorworks 崩溃** |
| 需要什么 MCP？ | **官方 Filesystem MCP** 或 **DesktopCommanderMCP**（文件读写 + 跑 Python）。不需要 CAD 类 MCP |

---

## 2. Vectorworks 社区 MCP 实况

| 项目 | Star | 最后更新 | 机制 | macOS | 问题 |
|---|---|---|---|---|---|
| `vicquick/vwx-mcp` | 15 | 2026-10-13 | 248 个工具 + 3071 函数知识索引；C++ 面板插件 | ⚠️ 需走旧 TCP 对话框桥 | **Windows 优先**，需 VW SDK 构建 |
| `chronista-club/vectorworks-mcp` | 11 | 2026-04-14 | Rust MCP + C++ SDK 插件 + Unix socket | ✅ 支持 | **需从源码编译**（Xcode + Rust + VW SDK），只有 6 个工具 |
| `giorgiomoroder/vectorworks-mcp` | 0 | 2026-10-16 | 纯 Python，无 SDK，Spotlight 优先 | ✅ Mac 原生 | Beta，仅测过 VW 2026 macOS |
| `Gribiche64/vectorworks-bridge` | 1 | 2026-09-05 | Lightwright XML 交换，无插件 | ✅ | 只处理灯具数据，不画图 |

**共同问题**：都是逆向或半官方接口，版本一变就崩；没有事务/回滚；出错后文档可能损坏。

### Vectorworks 官方立场

官方论坛主题 #134256 "official Model Context Protocol" 确认：
- 截至 2026-10 **没有官方 MCP**
- 用户在请求
- 有用户（Tom Klaber）测试非官方版本时**遇到崩溃**

Vectorworks 官方的自动化路径是：**Python (`vs` 模块，VW 2014 起)**、VectorScript、Marionette、SDK。
这是正路，但需要写代码，不是 MCP 能替代的。

---

## 3. 其它 CAD 的 MCP 生态（供参考）

| 软件 | 官方 MCP | 社区 MCP | macOS |
|---|---|---|---|
| **Rhino/Grasshopper** | ✅ **`mcneel/RhinoAI`**（366★，唯一官方第一方） | `jingcheng-chen/rhinomcp`（1153★，Rhino 8 Win+Mac） | ✅ |
| **Blender** | ❌ | `ahujasid/mcp-for-blender`（31k★，原 blender-mcp） | ✅ |
| **FreeCAD** | ❌ | `neka-nat/freecad-mcp`（2905★） | ✅ |
| **SketchUp** | ❌（Trimble 无） | `mhyrr/sketchup-mcp`（494★） | ⚠️ 有限 |
| **AutoCAD** | ❌ | `puran-water/autocad-mcp`（571★）双后端 | ⚠️ Mac 版**不支持 AutoLISP** |
| **SolidWorks / Fusion / Revit** | ❌ | 多个 | ❌ 全 Windows/COM |

**关键**：Rhino 是唯一有官方 MCP 的 CAD，而且 Mac 原生支持。
如果将来要换工具，Rhino + Grasshopper 是最顺的路径（参数化布灯很适合灯光设计）。

---

## 4. 文件/执行类 MCP（这才是要用的）

| 项目 | Star | 说明 |
|---|---|---|
| **`modelcontextprotocol/servers`** | 91k★ | 官方参考实现。`Filesystem`（安全文件操作 + 访问控制）是核心 |
| **`wonderwhy-er/DesktopCommanderMCP`** | 10k★ | 终端控制 + 文件搜索 + diff 编辑 + 内存中执行 Python/Node/R + PDF/DOCX/Excel |
| `pydantic/mcp-run-python` | 194★ | 沙箱化 Python |
| `tumf/mcp-shell-server` | 201★ | 白名单 shell 命令 + 审计日志 |

**对本项目**：只需要「读 `rig.yaml` → 改 → 跑 `python3 src/render.py`」。
官方 Filesystem MCP + 终端执行就够，DesktopCommanderMCP 更省事（一个就够）。

---

## 5. 娱乐灯光专用 MCP（有意思但都用不上）

| 项目 | Star | 说明 |
|---|---|---|
| `bbernstein/lacylights-mcp` | 15★ | LacyLights 系统的剧场灯光设计，DMX 灯具、GDTF 导入、looks/cues、剧本分析 |
| `Pahegi/ma3-mcp` | 34★ | grandMA3 控台控制 |
| `chienchuanw/gma2-mcp` | 16★ | grandMA2 |
| `Gribiche64/vectorworks-bridge` | 1★ | Vectorworks Spotlight 灯具数据（Lightwright XML） |

**为什么用不上**：这些是**控台/数据**层面的工具，不产出**图纸**。
我们要的是出图，不是控灯。

---

## 6. 关于 Pi + DeepSeek 的可行性

已核实（2026-10）：

| 项目 | 状态 |
|---|---|
| **DeepSeek V4.1 Flash** | ✅ 真实存在。模型 `DeepSeek-V4.1-Flash`，API 名 `deepseek-flash`，2026-09-10 发布。552B MoE，输入 8B/输出 16B 激活参数，**原生视觉**，1M 上下文，支持工具调用 |
| **Pi** | ✅ `pi.dev`（Earendil，MIT，~116k★）。终端 harness，**原生 MCP 支持**（stdio + HTTP），`models.json` 可接 OpenAI/Anthropic 兼容端点 |
| **接 DeepSeek** | ✅ `https://api.deepseek.com`（OpenAI 格式）或 `https://api.deepseek.com/anthropic`（Anthropic 格式） |

**配置要点**：
- MCP 配置文件：`~/.pi/agent/mcp.json`（全局）或 `.pi/mcp.json`（项目级）
- 模型配置：`models.json`
- 文档：https://pi.dev/docs/latest/mcp · https://pi.dev/docs/latest/models

**备选 harness**（若 Pi 不顺）：
- **Claude Code** — MCP 生态最成熟，DeepSeek 官方文档直接支持（`ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic`）
- **Codex CLI** — DeepSeek 官方一条命令接入
- **OpenHands** — 带沙箱

---

## 7. 给用户的建议（一句话版）

> 你不需要任何 CAD 类 MCP。
> 你需要的是：**文件读写 + 能跑 Python**。
> 然后让 AI 只改 `data/rig.yaml`，代码负责画图。
