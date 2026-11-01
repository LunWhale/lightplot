# LightPlot

给舞台灯光设计用的绘图工具。Mac + iPad 同一套代码。

**核心承诺：导出的平面图是 1:25 的 A1、剖面图是 1:50 的 A3，印刷出来量得到真实尺寸。**

---

## 打包成 .app / .dmg

```bash
./package.sh              # 出 dist/LightPlot.app + dist/LightPlot-0.001.dmg
./package.sh --no-dmg     # 只出 .app
```

脚本做六件事，每一步都有自检：编译 Release（**通用二进制**，Apple 芯片与 Intel
都能跑）→ 校验 bundle（标识 / 版本 / 文件关联 / 签名）→ 输出到 `dist/` →
组装镜像（应用 + `/Applications` 快捷方式 + 安装说明）→ 生成压缩 DMG →
**挂上镜像并真的启动一次**，确认能用才算成功。

```
dist/LightPlot.app            10M
dist/LightPlot-0.001.dmg     3.1M    SHA-256 一并打印
```

**签名状态（重要）**：本机没有 Apple 开发者证书，所以是 **ad-hoc 签名**。
在本机能直接打开；拷到别的 Mac 上第一次会提示"无法验证开发者"，
需要右键 →「打开」，或 `xattr -dr com.apple.quarantine /Applications/LightPlot.app`。
这句话也写进了 DMG 里的 `安装说明.txt`。
要彻底消除提示，需要 Developer ID 证书 + 公证（notarization）。

---

## 第一次用：三步

**第一步 —— 打开应用**

```bash
cd app
./run.sh --app          # 编译并打开（第一次会慢，约半分钟）
```

或者用 Xcode：`open LightPlot.xcodeproj`，然后按 ⌘R。

**第二步 —— 填上你的场地**

窗口右边就是检查器（默认打开）。从上往下填：

| 填什么 | 在哪 |
|---|---|
| 剧名、编剧、场地、导演、设计师 | 检查器最上面的 **SHEET** |
| 舞台宽、深、栅顶高度、台口高度 | **STAGE** |
| 观众席几排、每排多深、有没有起坡 | **AUDIENCE** |

数字都是**毫米**。不知道就先按示例值放着，之后随时能改。

**第三步 —— 加灯杆、加灯、出图**

1. 工具栏「➕」→ Truss，画一根灯杆
2. 选中灯杆 → 灯杆图标 → 选灯具类型，灯就吸在杆上了
3. 检查器里改色片、朝向、通道号
4. 工具栏最右边的导出图标 → **Sheet PDF**
5. 打出来，用尺子量 —— 图上 1 毫米就是现实的 25 毫米

---

## 一分钟上手（命令行）

```bash
cd app
./run.sh                    # 一条命令：校验 → 出全套 → 与旧管线比对
./run.sh --check            # 只校验数据（改完数据先跑这个）
swift test                  # 410 个测试
open LightPlot.xcodeproj    # 用 Xcode 打开应用
```

`./run.sh` 做的就是下面这些，不想记命令就用它：

```bash
swift run lpx render  ../data/rig.yaml /tmp/plan.pdf    # A1 @ 1:25
swift run lpx section ../data/rig.yaml /tmp/sec.pdf     # A3 @ 1:50
swift run lpx verify-old ../data/rig.yaml ../out        # 与旧管线逐灯比对
```

也可以手动编译并打开应用：

```bash
xcodebuild -project LightPlot.xcodeproj -scheme LightPlot-macOS \
           -configuration Debug -derivedDataPath .build/xcode build
open .build/xcode/Build/Products/Debug/LightPlot.app
```

---

## 它做什么

| 你想要的 | 在 LightPlot 里 |
|---|---|
| 输入真实场地尺寸 | 检查器 → Stage（宽/深/栅顶/台口/观众席/起坡） |
| 输入剧名、作者、场地、导演、设计师 | 检查器 → Sheet |
| 换纸幅（A0–A4 / Letter / Tabloid，横竖都行） | ⌘⇧P Page Setup（会告诉你这张纸能装多大场地） |
| 像无边记一样自由移动 | 无限画布，图纸浮在上面 |
| 画桁架/管线 | 工具栏「Truss」，拖两端改长度 |
| 两根桁架接成一根 | 选中两根 → 「Join」（共线且缝隙 ≤30mm 才会合） |
| 放灯 | 选中桁架 → 「Lantern」菜单，灯自动吸在杆上 |
| 让灯沿杆滑动 | 直接拖灯 |
| 让灯转向 | 检查器里的方向滑杆，或点 ↑↓←→ |
| 选色片 | 检查器里选，色块显示真实颜色 |
| 检查错误 | 状态栏的绿灯 / 底部检查面板 |
| 出图 | 「Export A1 PDF」，或 ⌘⇧E |

**界面跟随系统语言**（中文系统显示中文，其余显示英文）。
**图上永远不出现中文** —— DXF/PDF 交付物的硬约束，编辑器会当场拦下来。
两者不冲突：界面是给人用的，图纸是给现场和考官看的。

---

## 它不做什么（有意为之）

- **不算照度**。光束锥只表示"朝哪儿"和"光斑多宽"，不表示"多亮"。
  真正的照度计算要光度曲线和环境反射，图纸里既没有也不需要 ——
  画一个好看的假光斑比不画更糟。
- **不猜灯具俯仰角**。剖面图上的光轴由"灯口 → 焦点"的几何决定，
  不是硬编一个倾角。要改照射角就改焦点（每盏灯可选 `focusDepth`）。
- **不做 3D**。平面图 + 剖面图足够交付。
- **不替代 Vectorworks**。它擅长通用几何；LightPlot 只擅长"灯光出图"，
  并且在做这一件事上知道 Vectorworks 不知道的东西（L201 是什么色、两个场景的对比够不够）。
- **不导 DXF / DWG**。LightPlot 出 PDF 与 CSV。
  要给 Vectorworks 的 CAD 文件（`out/cad/*.dxf`、`*.dwg`）由旧 Python 管线生成 ——
  `./run.sh`（仓库根目录）会把它们算出来。
  这不是缺口：交付要求是"打印出来量得到真实尺寸"，PDF 已经做到（实测 841×594 mm）。

---

## 结构

```
app/
  Package.swift              Swift Package（内核 + UI + 命令行）
  LightPlot.xcodeproj        xcodegen 生成，macOS + iPad 双 target
  Sources/LightPlotCore/     内核：无 UI 依赖，全部 365 个测试覆盖
    Geometry/                向量、矩形、三种坐标空间与变换
    Paper/                   视觉语法常量、字体度量
    Model/                   文档、构件、解析、版面、色片库
    Lint/                    28 条规则 + 稳定错误码
    Digest/                  可 diff 的数字摘要
    Drawing/                 绘制指令、桁架/管线几何、灯具符号、朝向
    Editor/                  事件、吸附、reduce 内核、合并
    Export/                  CoreGraphics 矢量 PDF、可复现输出、PDF 文字层读取
    Verify/                  与旧管线的差分比对（PDF 文字层 + DXF 几何）
  Sources/LightPlotUI/       SwiftUI 画布、检查器、离屏截图
  Sources/LightPlotApp/      应用入口
  Sources/lpx/              命令行：digest / lint / render / section / scene /
                            section-state / csv / verify-old / diff / snapshot
  Tests/                    365 个测试
  tools/platforms.sh        三个 target（macOS Debug/Release、iPadOS）编译门禁
```

---

## 三条设计纪律

**1. 几何只生成一次。**
`PlanBuilder` 产出 `[DrawOp]` 指令列表，PDF 后端和屏幕画布各自只是"把指令画出来"。
旧管线有两套独立渲染实现（DXF + 手写 PDF），改一处忘一处就不一致。
副产品是巨大的好处：指令列表本身可断言，所以 GUI 能被精确测试。

**2. 所有编辑走 `Editor.reduce(state, event)` 纯函数。**
拖拽、吸附、合并、旋转、撤销都能在无窗口环境断言。
200 步随机编辑测试逐轮检查：灯号唯一、构件上的灯不脱杆、比例始终合法。

**3. 比例锁死，只移动图框。**
`SheetLayout.fitted()` 只居中不缩放。放不下时明确报错，绝不悄悄裁剪。

---

## 验证装置（这是本项目最值钱的部分）

```bash
swift test
```

- **故障注入**：28 条规则，每条都有一个"注入已知错误"的用例。
  元测试强制 1:1 —— 新增规则不加用例，测试直接失败。
  这守的是"断言存在但从未被执行过"这类假绿灯。
- **确定性**：摘要两次运行字节相同；JSON 键有序；
  `lpx --reproducible` 让 PDF 也逐字节可复现（钉掉时间戳与文档 ID）。
- **应用 = 命令行**：两边写出的 PDF 正规化后**逐字节相同**
  （同一核心的两个外壳，不能各自"看起来都对"）。
- **纸张扫描**：7 种幅面 × 2 朝向 × 5 个比例 × 真实数据，
  装得下就必须零文字重叠且比例说真话，装不下就必须出提示页。
- **平台门禁**：macOS Debug/Release 与 iPadOS 三个 target 必须都编译通过。
- **单行变更**：改一个字段，摘要只应变化一行。
- **端到端**：真实数据 → 真实 PDF → 重新打开验证尺寸与覆盖。
- **差分回归**：同一份数据，与旧 Python 管线的**实际产出**逐项比对 ——
  平面图比色片（PDF 文字层，逐灯 30 组 × 3 份）、剖面图比构件表、
  平面图坐标比 DXF 里的符号插入点（69 组同类型对的间距零误差）。

---

## 字体

内置 **Liberation Sans**（SIL OFL，可随应用分发）。
它与 Arial 的字符 advance width **逐字符相同**（实测 73 个字符 MAXDIFF = 0.000），
所以换字体不会让既有版式重排；cap/em 不同（0.6880 vs 0.7163），
而代码是从字体文件读这个值，所以字高在任何字体下都一致。

**iPad 与 Mac 现在用同一份字体文件**，出图排版完全一致。
哈希与踩坑记录见 `Sources/LightPlotCore/Resources/Fonts/README.md`。

## 已知缺口

- **iPad Release 真机构建需要开发团队**。模拟器构建不需要。
- **真机手感未验证**：Pencil 延迟、双指缩放的跟手程度只有上手才能判断。
  模拟器只能证明布局、渲染与交互逻辑正确。
- **不算照度**（见上文「它不做什么」）。

---

## 数据格式

**直接读旧管线的 `data/rig.yaml`，不覆盖原文件。**
导出 A1 PDF 是独立动作。这样"新工具"和"能交付"两件事不会绑死。

应用自己的格式 `.lpx` 是稳定 JSON（键有序），适合进版本管理。

---

*详细决策记录见 `PROGRESS.md`。*
