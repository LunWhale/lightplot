# 10 · 让 DXF 能被 Vectorworks 打开

## 症状

Vectorworks 2026 导入 `out/LX_plan.dxf` 时报：

> This is an unrecognized file. It may be a Vectorworks file created by a newer
> version of the application, it may be a very old MiniCAD file, it may have been
> created by another application, or it may have been corrupted by a hardware or
> system error.

并且先提示"这个文件创建于 2026 版本的 Vectorworks"。

## 诊断过程（全部实测，不是猜测）

### 先排除误报

用 libredwg 的 `dxf2dwg` 转换，报：

```
ERROR: Duplicate handle 1F for object 2145 already points to object 0
```

但拿 **ezdxf 官方最小文件**（一行直线）去试，报**完全相同**的错：

```
ezdxf 最小文件 → ERROR: Duplicate handle 1F for object 109 already points to object 0
```

结论：这是 libredwg 对 ezdxf 输出的**固有误报**，不能当判据。
`ezdxf.audit()` 和 `recover.readfile()` 都是 0 errors / 0 fixes。

我自己写的 handle 唯一性检查一开始也报"1746 个重复"，
后来发现是**我把 modelspace 实体数了两遍**——模型空间的内容本身就是
`*Model_Space` 块的内容，不是两份。修正后 0 重复。

### 找到的真实缺陷

| # | 缺陷 | 证据 | 影响 |
|---|---|---|---|
| 1 | `$EXTMIN/$EXTMAX` 永远是哨兵值 | `(1e+20,1e+20)` / `(-1e+20,-1e+20)` | CAD 的"缩放到全部"失效 |
| 2 | `$LIMMAX` 是 A3 的 `(420,297)` | A1 图纸却写 A3 界限 | 打开时视窗错 |
| 3 | 23 个图层引用 `'CONTINUOUS'` | 线型表里只有 `'Continuous'` | 悬空引用，违反 DXF 规范 |
| 4 | 展开后 360,973 个顶点 | 单个 profile 符号 6,449 顶点 | 打开/缩放极慢 |
| 5 | 文件 3.14 MB | — | 同上 |
| 6 | `$LASTSAVEDBY = 'ezdxf'` | — | 暴露工具链 |
| 7 | 非 ASCII 字符 `±` `©` | `STAGE FLOOR ±0`、`© 2026` | DXF 必须是 ASCII |

### 为什么 `$EXTMIN` 是 ezdxf 的坑

```python
doc.header["$EXTMIN"] = (10.0, 10.0, 0.0)
print(doc.header["$EXTMIN"])   # (10.0, 10.0, 0.0)   ← 内存里生效
doc.saveas(path)
# 重新读取：
#   $EXTMIN = (1e+20, 1e+20, 1e+20)   ← 又变回哨兵值
# 文件原文：
#   $EXTMIN
#    10
#   1e+20
```

**ezdxf 在写盘时把它重置了。** 所以必须在文件写完之后做**文本级**修补。

## 修复方案

### `src/dxfix.py` — 交付前可移植性后处理

三个阶段：

**阶段 1（ezdxf 层）**
- 悬空线型名按大小写不敏感匹配回表里的真名
- 文字样式里的路径削成文件名（DXF 只允许文件名）
- 移除 `EZDXF_META` 记录
- `DIMENSION` 从 layer 0 移到 `DIM`
- 版本降到 **R2000（AC1015）**——兼容性最好

**阶段 2（文本层，绕开 ezdxf 的重置）**

按 DXF tag 成对解析，不用正则跨行：

```python
def _parse_tags(raw):
    lines = raw.split("\n")
    return [(lines[i].strip(), lines[i+1]) for i in range(0, len(lines)-1, 2)]
```

> **踩过的坑**：第一版用 `r"\n\s*20\n"` 定位 y 坐标，`\s` 包含换行，
> 正则一路吃到下一行，把 header 写坏成 `Missing required y coordinate`。
> 按行成对解析是唯一可靠的做法。

修补：`$EXTMIN` / `$EXTMAX` / `$LIMMIN` / `$LIMMAX` / `$LASTSAVEDBY`

**阶段 3（复验）** `verify_dxf()` 检查 7 项，任一不过就报 WARN。

### `src/gdtf_symbol.py` — 轮廓简化

GDTF 的 GLB 投影出来是**栅格描迹**（marching squares 沿像素走），
一个 profile 符号 6449 顶点，其中 5744 段几乎是直线。

加 RDP（Ramer–Douglas–Peucker），容差 **0.3mm 实物**：

```
symbol      raw     simplified
profile   18214  →  368   (2.0%)
fresnel    9516  →  148   (1.6%)
par        3535  →  111   (3.1%)
led        9415  →  138   (1.5%)
mover      9415  →  138   (1.5%)
follow     9575  →   41   (0.4%)
```

0.3mm 实物 = 0.012mm 图纸，远小于 0.145pt（0.05mm）线宽，肉眼无差别。
**包围盒完全不变**（最大差 0.1mm），形状叠加对比验证过。

结果：**3.14 MB → 602 KB**，展开顶点 363,341 → 约 3,000。

### 图框照参考图改

| 项 | 改前 | 改后（= 参考图实测） |
|---|---|---|
| 外框 | (10,10)–(831,584) | **(0,0)–(841,594)** 贴纸边 |
| 内框 | (20,20)–(821,574) | (20,20)–(821,574) 不变 |
| 分区带 | 10mm | **20mm** |
| 刻度线 | 5mm，向内 | 5mm，**向外** |
| 列号中心 y | 15.0 | **13.55** |
| 行号中心 x | 15.0 | **15.05** |
| 分区号字高 | cap 6.35 | **cap 4.55** |

`check_scale()` 里的 `margin=10.0` 也改成读 `paper.FRAME_MARGIN`，
否则会把正确的图判成错误。

## 验证命令

```bash
.venv/bin/python src/dxfix.py out/LX_plan.dxf 841 594
# 期望：OK
```

`run.sh` 里已经自动跑，任何 WARN 都会打印。

## 第二轮修复：真正的原因

第一轮修完你那边仍然打不开。继续查，找到两个更根本的问题。

### 原因 A：`ezdxf.new(setup=True)` 塞进了不存在的字体

`setup=True` 会给文档注入 **25 个文字样式**（OpenSans / Liberation 系列）
和 **11 个 dimstyle**，而 `dimstyle` 的 `dimtxsty` 指向
`'OpenSansCondensed-Light'`。

**这些字体文件在 macOS 上根本不存在：**

```
OpenSans-Regular.ttf         MISSING
LiberationSans-Regular.ttf   MISSING
Hiragino Sans GB.ttc         FOUND
```

铁证：把这些样式删掉后，**ezdxf 自己都存不了盘**：

```
DXFTableEntryError: OpenSansCondensed-Light
```

说明引用是悬空的，只是 ezdxf 写盘时不检查。CAD 解析到不存在的字体，
很可能直接判定"文件损坏"。

**修复**：`ezdxf.new(..., setup=False)`，只保留 `Standard` + 我们自己的
`LBL` / `TTL`（Arial.ttf）。线型也自己建（`DASHED` / `DASHDOT` / `CENTER`）。

### 原因 B：Vectorworks 根本没注册 `.dxf`

```bash
plutil -p "Vectorworks 2026.app/Contents/Info.plist" | grep -c -i dxf
# → 0
```

Vectorworks 只注册了 DWG：

```
CFBundleTypeName = Vectorworks DWG document
CFBundleTypeOSTypes = Array { MDWG }
```

而 macOS 上 `.dxf` 的默认关联是 **LibreOffice**：

```
mdls -name kMDItemContentType out/LX_plan.dxf
# → "org.libreoffice.dxf-document"
```

所以"双击 dxf"永远不会用 Vectorworks 打开。**必须走菜单导入**。

**修复**：`run.sh` 现在额外产出 **DWG**（`out/*.dwg`，AC1015），
这是 Vectorworks 原生注册的格式。

### 顺带修的

- `$ACADMAINTVER` 降级后仍留着 R2010 的值 `6`，R2000 应为 `0`
- `setup=False` 留下 owner handle 无效的 `DICTIONARYVAR`，`dxfix` 现在跑 audit 清理
- 图上字体从 `Hiragino Sans GB.ttc`（中文字体）换成 `Arial.ttf`（全英文图）
- 图签标签列宽改成**按实际字体实测**，不写死（Arial 下 DESIGNER 是 27.0mm，
  Hiragino 下只有 22.1mm，写死 30 会让值撞上标签）

## 当前产物

```
out/LX_plan.dxf          AC1015  583 KB   EXT (0,0)..(841,594)
out/LX_plan.dwg          AC1015  212 KB   ← Vectorworks 用这个
out/LX_plan_kitchen.dwg  AC1015  212 KB
out/LX_plan_boston.dwg   AC1015  212 KB
out/LX_section.dxf       AC1015   54 KB   EXT (0,0)..(420,297)
out/LX_section.dwg       AC1015   21 KB
```

样式表干净：`Standard(txt) / LBL(Arial.ttf) / TTL(Arial.ttf)`
线型表：`ByBlock / ByLayer / Continuous / DASHED / DASHDOT / CENTER`
`audit()` 0 errors / 0 fixes。

## 第三轮：黑乎乎 + 比例不对

你导入后看到两个现象，都定位到了。

### 现象 1：整张图黑乎乎

**原因：ACI 7 号色是"随背景翻转"的。**

我们用它画白底遮罩：

```python
h = msp.add_hatch(color=paper.WHITE, ...)   # WHITE = 7
```

在 DXF 里 ACI 7 = 白底显黑、黑底显白。Vectorworks 白底上，
**所有遮罩渲染成黑色** —— 就是截图里那片黑。

**修复**：遮罩改用 24 位真彩 `0xFFFFFF`（组码 420）。

但还有个坑：**`true_color` 是 R2004 才引入的**。实测：

```
R2000: 420 tag in file=False   reload true_color=None
R2004: 420 tag in file=True    reload true_color=16777215
```

而我上一轮为了兼容性把版本降到了 R2000 —— 真彩被**丢掉**了。
所以 `dxfix` 的目标版本改成 **R2004 (AC1018)**。

### 现象 2：比例不对

**原因：模型空间画的是"图纸毫米"，不是"真实毫米"。**

我们画图时 A1 纸 841×594，舞台 15000mm 画成 600mm。
这在"1:25 出图"的语境下是对的，**但 CAD 不理解"图纸空间"**。

CAD 把模型空间的 1 单位当成 1 个真实单位。所以 Vectorworks 看到的是
一个 **841mm 宽的世界** —— 比真实舞台小 25 倍。

**修复**：`dxfix.to_model_scale()` 把模型空间放大 25 倍：

```
图纸 841 × 594 mm  ->  模型 21025 × 14850 mm
舞台 600 mm        ->  舞台 15000 mm   ← CAD 里量出来是真的
文字 2.5 mm        ->  62.5 mm         （出图 1:25 时打印回 2.5mm）
线宽 不缩放        （DXF lineweight 本来就是真实 mm）
```

验证：

```
STAGE 图层 extents: 15000.0 x 9284.0 mm   ← 与 rig.yaml 一致
```

**踩过的坑**：第一版我手写逐类型缩放，又叠加了 `INSERT.scale` 的额外乘法，
结果放大成 x625（extents 跑到 98208）。改用 ezdxf 的 `transform()`
一次搞定，精确到 21025×14850。

### 目录结构变了

```
out/*.dxf        图纸尺寸（841×594）—— 供 verify/golden 复核、归档
out/cad/*.dxf    真实尺寸（21025×14850）—— 给 Vectorworks 导入
out/cad/*.dwg    同上，DWG 格式
```

**导入请用 `out/cad/` 里的文件。**

## 第四轮：比例仍不对（显示 1:5）

你导入后右上角显示 **1:5**，改成 1:1 画面就溢出纸框。

### 根因：layout 的纸张尺寸是 A3，内容是 A1

DXF 里除了几何，还有 **layout（图纸布局）** 记录，其中写着：

```
paper_width = 420.0     ← A3
paper_height = 297.0    ← A3
scale_numerator = 1.0
scale_denominator = 1.0  ← 1:1
```

而内容已经是 **21025 × 14850 mm**（A1 @1:25）。
Vectorworks 用 `paper × scale` 推算视窗，`420 × 1 = 420` 对不上 21025，
于是显示一个离谱的比例，改成 1:1 就溢出。

**修复**：`to_model_scale()` 现在同时设 layout：

```
paper 841 × 594 (A1)  ×  scale 1:25  =  21025 × 14850  ✓
```

验证：

```
out/cad/LX_plan.dxf
  内容 21025x14850  EXT (21025,14850)  LIM (21025,14850)
  layout 841x594 1:25 -> 21025x14850 MATCH
```

### 三个我自己踩的坑

**坑 1：`return` 前面的死代码**

我把设 layout 的代码插到了 `return dxf_path` **后面**，整段永远不执行。
所以上一轮"修好了"其实根本没跑。检查方法：看函数体里 `return` 的位置。

**坑 2：`$LIMMAX` 也会被 ezdxf 重置**

和 `$EXTMIN` 一样：内存里设对，`saveas()` 后又变回旧值。
实测：

```
d.header["$LIMMAX"] = (21025.0, 14850.0)
d.saveas(p); ezdxf.readfile(p).header["$LIMMAX"]
# -> (420.0, 297.0)   ← 又变回去了
```

必须文本层修补。现在 `$EXTMIN/$EXTMAX/$LIMMIN/$LIMMAX` 四个都在文本层写。

**坑 3：`saveas()` 的顺序**

文本层修补必须在 `saveas()` **之后**做，否则会被覆盖。
现在的顺序是：设 layout → `saveas()` → 文本层补四个 header 变量。

## 第五轮：1:5 / 1:25 都"太小"——教育版可打印区域

你给的两条线索拼起来就清楚了：

> 默认 1:5；改成 1:25 后画面**特别特别小**
> Vectorworks 无限画布上有一个规范区域，上面水印下面水印，
> 中心大约 **(10000, 7000)**

中心 (10000,7000) ⇒ 那个区域是 **20000 × 14000**。

### 为什么两种比例都不对

| 内容 21025mm 在 | 打印宽度 | 占 20000 区域 |
|---|---|---|
| 1:5 | 4205 mm | **21%** |
| 1:25 | 841 mm | **4%** ← "特别小" |
| 1:1 | 21025 mm | 105% ← 溢出 |

要填满那个区域，比例必须接近 **1:1.05**。所以 Vectorworks 给的
1:5 和 1:25 都不对，而你手动改 1:1 又溢出 —— 因为**页面(layout paper)**
当时只有 841×594，装不下 21025 的内容。

### 根因：layout paper 和内容尺寸脱节

Vectorworks 判断"这页纸多大"用的是 layout 的 `paper_width/height`，
不是内容包围盒。之前：

```
paper 841 x 594   (A1)     scale 1:25
```

逻辑上 841×25 = 21025 自洽，但页面本身只有 841 宽，
相对 20000 的区域只占 4% —— 就是你看到的"特别小"。

### 修复：paper 直接等于内容尺寸

```python
paper_width  = 21025   # = 内容宽
paper_height = 14850   # = 内容高
scale        = 1:1
```

这样 Vectorworks 认为"这页纸就是 21025×14850"，内容 1:1 正好填满，
水印落在图框之外。

验证：

```
out/cad/LX_plan.dxf
  内容 21025x14850   paper 21025x14850  1:1
  paper x scale = 21025x14850  MATCH
  占 20000x14000 水印区: 105% x 106%
```

### 还剩 5% 溢出

21025 比 20000 宽 5%，14850 比 14000 高 6%。所以画面会**略微**盖住水印。

两个选择：

- **A（当前）**：保持 21025×14850 = A1 @1:25 精确。HSC 要求 1:25，
  多出的 5% 可以靠调整图框内缩吸收。
- **B**：把 paper 设成 20000×14000，实际比例变成 1:26.3 —— 不是 1:25 了。

**默认走 A。** 如果 A 还是盖住水印，告诉我，我改成 B。

## 第六轮：图只占页面一半 —— `$PLIMMAX` 是 A3

你的截图给了决定性证据：**图正好占页面宽度的一半**。

```
841 / 420 = 2.00        <- 内容 841mm ÷ 图纸空间界限 420mm
```

### 根因：DXF 有两套"界限"，我只改了一套

| 变量 | 含义 | 之前的值 |
|---|---|---|
| `$LIMMIN/$LIMMAX` | **模型空间**界限 | 841×594 ✅ 已改 |
| `$PLIMMIN/$PLIMMAX` | **图纸空间**界限 | **420×297 ❌ 从没改过** |

Vectorworks 用**图纸空间界限**（`$PLIMMAX`）当页面尺寸。
页面 420，内容 841 → 图显示成 50%。

所以前几轮我改 `$LIMMAX`、改 layout paper，都没用 —— 改的是模型空间那一套，
Vectorworks 看的是图纸空间那一套。

### 修复

`fix_dxf()` 现在把两套界限都设成图纸尺寸：

```
$LIMMIN    = (0, 0)
$LIMMAX    = (841, 594)     <- 模型空间
$PLIMMIN   = (0, 0)
$PLIMMAX   = (841, 594)     <- 图纸空间（关键）
$EXTMIN    = (0, 0, 0)
$EXTMAX    = (841, 594, 0)
layout     = 841 x 594 @ 1:1
```

四者全部 = A1。

### 教训

DXF 里描述"图纸多大"的地方有**四处**，Vectorworks 至少看其中两处。
改一处没用。要改就全改，然后用 `verify_dxf()` 断言它们互相一致。

## 仍需人工确认

**我无法自动化 Vectorworks 导入。** 交付后请手动验证：

**先试 DWG（推荐）：**
1. Vectorworks 2026 → 新建空文档
2. `File > Import > Import Single DXF/DWG`
3. 选 **`out/cad/LX_plan.dwg`**
4. 单位 **Millimeters**
5. 比例应该**自动显示 1:25**。如果还是 1:5 或别的，告诉我实际数字

**比例对照（重要）**：
| 文件 | 内容尺寸 | 正确比例 |
|---|---|---|
| `out/cad/LX_plan.dwg` | 21025 × 14850 mm | **1:25** @ A1 |
| `out/cad/LX_section.dwg` | 10500 × 7425 mm | **1:25** @ A3 |
| `out/LX_plan.dxf`（旧，图纸尺寸） | 841 × 594 mm | 1:1 @ A1 |

**再试 DXF（对比用）：**
同上，但选 `out/LX_plan.dxf`。

请告诉我：哪个能开、哪个不能、报什么错。
如果两个都不行，下一步我会把 DXF 再降级到 R12（AC1009，最简结构）。

**不要承诺**"导入后自动变成 Spotlight 灯具对象"——**未验证**。

## 备选：DWG

Vectorworks 官方文档原话：

> Recent versions of AutoCAD have issues when reading some DXF files, such as
> losing links to images, so **DWG is usually a safer choice** in that case.

本机已有 libredwg（`dxf2dwg`），实测能产出有效 DWG：

```bash
dxf2dwg -y -o out/LX_plan.dwg out/LX_plan.dxf
file out/LX_plan.dwg   # DWG AutoDesk AutoCAD 2000
```

但 libredwg 对 ezdxf 输出有一堆 `Unknown DXF code` 警告，
转换质量未在 Vectorworks 里验证。**DXF 仍是主路线**，DWG 只作备选。
