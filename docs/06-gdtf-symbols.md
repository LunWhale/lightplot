# 06 — 真实灯具符号：实测结论与实现

> 这一页取代了原先「下载 .gdtf 取 SVG」的假设。那个假设**在规范上成立，
> 在实践中只有 3% 命中率**。下面是 98 个厂家抽样得到的数据，以及最终采用的方案。

---

## 1. 实测数据（这是重点）

对 gdtf-lights.com 的 98 个厂家抽样，解压每个 .gdtf 检查内部资源：

| 资源 | 存在比例 | 说明 |
|---|---|---|
| `models/gltf/*.glb` 三维网格 | **96 / 98** | 几乎全都有 |
| `models/svg/*.svg` 平面符号 | **3 / 98** | 极少，且有假的 |
| `models/svg_side/*.svg` 剖面符号 | **0 / 98** | 一个都没有 |
| `thumbnail.svg` 矢量缩略图 | ~50% | 是示意图，**不是 1:1 实物图** |

**两个致命细节：**

1. **SVG 可能是占位符。** ALPHA LITE ALPHA1000 提供了 9 个 SVG，
   解压后每个都是「两个同心圆 + 十字 + 文字」—— 模板占位，不是灯具轮廓。
2. **SVG 可能不是 1:1。** Martin MAC Aura XIP 的 SVG 尺寸 268.9×78.4mm，
   而它真实的 GLB 包围盒是 333×321mm。按 SVG 画会得到一条扁长条，
   完全不是灯具形状。

所以：**只看「有没有 SVG」不够，必须与 GLB 尺寸交叉校验。**

---

## 2. 采用的方案：三级降级 + 交叉校验

```
             ┌─────────────────────────────────────────┐
             │ 1. 先算 GLB 包围盒（作为尺寸基准）        │
             └────────────────┬────────────────────────┘
                              ▼
             ┌─────────────────────────────────────────┐
             │ 2. 有 models/svg/<Model.File>.svg 吗？   │
             │    · 有真实 path/polygon？               │
             │    · 尺寸与 GLB 一致（±30%）？           │
             │    两者都满足 → 用它                     │
             └────────────────┬────────────────────────┘
                         不满足 │
                              ▼
             ┌─────────────────────────────────────────┐
             │ 3. GLB 俯视投影                          │
             │    沿 -Z 投影 → 栅格化 → find_contours   │
             │    → 按面积过滤碎线 → RDP 简化           │
             └────────────────┬────────────────────────┘
                         失败   │
                              ▼
                      raise（绝不手画）
```

实现：`src/gdtf_symbol.py`

### 关键参数

| 参数 | 值 | 理由 |
|---|---|---|
| `RDP_EPS` | 0.8 mm | 1:25 图上约 0.03mm，肉眼不可见 |
| `PPM` | 3.0 px/mm | 起点分辨率，超限自动降 |
| `MAX_GRID_PX` | 24 M | 防超大网格打爆内存 |
| 碎线过滤 | 面积 < 最大轮廓 3% | 滤掉旋钮/支架投影 |
| 尺寸校验容差 | ±30% | 实测 SVG 与 GLB 常差 2 倍以上 |

### 单位问题（实测踩坑）

GDTF 规范说模型单位是**米**，但实测有厂家用毫米/厘米：

| 灯具 | 原始跨度 | 实际单位 | 判定后尺寸 |
|---|---|---|---|
| ETC S4 Lustr X8 | 0.72 | m | 260×719 mm |
| Chauvet COLORado 1 Solo | 144 | **cm** | 95×145 mm |
| Martin MAC Aura XIP | 333 | **mm** | 333×321 mm |

`normalize_units()` 用「灯具真实尺寸应在 30mm–6m 之间」做量级判定，
自动识别单位。这是必需的，不做就会得到 144 米大的灯。

---

## 3. 结果

```
  [ OK ] profile    top   glb(m)  260.3× 719.3 mm  4 轮廓
  [ OK ] profile    side  glb(m)  719.0× 270.0 mm  3 轮廓
  [ OK ] fresnel    top   glb(m)  285.3× 443.4 mm  2 轮廓
  [ OK ] par        top   glb(cm)  95.0× 144.6 mm  3 轮廓
  [ OK ] led        top   glb(mm) 333.0× 321.1 mm  3 轮廓
  [ OK ] follow     top   glb(m)  250.3× 444.2 mm  3 轮廓
```

12 个视图全部提取成功，全部来自真实厂家 GDTF。

`profile/side` 能清楚看到 Source Four 的镜筒、遮扉槽和尾盖——
这是 GLB 投影出来的，不是画的。

---

## 4. 数据来源

**gdtf-lights.com 的公开 catalog API（无需登录）：**

```bash
# 搜索
curl "https://gdtf-lights.com/catalog-api.php?action=list&q=source+four&limit=10"

# 分类：profile / fresnel_pc / par / moving_spot / flood_cyc / pixel_bar ...
curl "https://gdtf-lights.com/catalog-api.php?action=list&category=fresnel_pc&limit=100"

# 详情（含 fixtureGdtf 下载路径）
curl "https://gdtf-lights.com/catalog-api.php?action=product&slug=etc-s4-series-3-lustr-x8-19deg"
```

返回的 `list.items[].fixtureGdtf` 就是 `/gdtf/XXX.gdtf`，直接拼域名下载。

**gdtf-share.com 的 API 需要登录**（`apis/public/getList.php` 返回 401），
但它首页有个公开的 `landing/resource/gdtf-mvr-assets.zip` —— 那是**品牌素材**
（logo、PPT 模板），不是灯具，别下。

---

## 5. 为什么不用厂家 SVG（即使有）

USITT RP-2 §2.2 原文：

> The luminaire symbols used on the light plot should represent the
> **approximate size and shape** of the luminaires **in scale**
> (except where computer applications supply more specific symbols).

关键词是 *approximate*。图纸符号不需要精确到螺丝，需要的是**轮廓对、尺寸对**。
GLB 投影给出的正是这个，而且 96% 的灯具都有。

反过来，厂家 SVG 即使是真的，也常带内部细节线（散热孔、logo），
在 1:25 下会糊成一团黑。GLB 投影 + RDP 简化反而更接近制图需要。

---

## 6. 重跑流程

```bash
python3 src/gdtf_fetch.py            # 下载 .gdtf → data/gdtf/
python3 src/gdtf_symbol.py --build   # 提取 → data/symbols.json
python3 src/gdtf_symbol.py --preview # 人眼确认形状 → out/symbols_preview.png
```

`symbols.json` 约 4MB，含每个灯具 top/side 两个视图的多边形（毫米，原点在包围盒中心）。

**换灯具**：改 `data/fixtures.yaml` 里的 `gdtf` 路径与 `slug`，重跑上面三步。

---

## 7. 已知限制

- **GLB 投影是"包络"，不是"结构"。** 它给出外轮廓，不区分机身/吊架/镜筒。
  要区分就得按 Model 拆开画——目前合并成一个外形，够用但不精细。
- **`par` 用了 cm 单位的厂家数据**，虽然归一化了，但轮廓细节比其他灯粗。
  换一个用米制单位的 PAR 会更准。
- **followspot 的 GLB 只有机身没有支架**，侧视图偏简单。
- 投影分辨率在超大网格上会降到 0.35 px/mm，此时轮廓会有轻微台阶。
