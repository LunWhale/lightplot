# 内置字体

## 放什么

`LiberationSans-Regular.ttf` / `LiberationSans-Bold.ttf`，来自
[liberation-fonts 2.1.5](https://github.com/liberationfonts/liberation-fonts)，
**SIL Open Font License 1.1**（见 `LICENSE-Liberation.txt`）。

## 为什么是它，而不是 Arial

| | Arial | Liberation Sans |
|---|---|---|
| 授权 | Monotype 商用，**不能随应用分发** | SIL OFL，可随应用分发 |
| iPad 上有吗 | **没有** | 随包分发，两端一致 |
| 字符 advance width | — | **与 Arial 逐字符相同（实测 73 个字符 MAXDIFF = 0.000）** |

Liberation Sans 是专门为"度量兼容 Arial"设计的替代字体。
所以换用它**不会**让既有版式重排 —— 这一点有测试守着
（`FontLockTests.advancesAreStable`）。

## 一个必须知道的差异

advance width 相同，但 **cap/em 不同**：

```
Arial          cap/em = 0.7163
Liberation Sans cap/em = 0.6880
```

`FontLibrary.regular.capToEm` 是**从字体文件读出来的**，不是硬编码常量。
所以"cap 高度 3.04mm 的字"在任何字体下都是 3.04mm 高，
只是所需的 em 尺寸不同（Liberation 需要更大的 em）。

`Paper.emToCapFallback = 0.7163` 保留下来，仅作"字体加载失败"时的兜底，
并在注释里标明它记录的是 Arial 的值。

## 字体文件哈希

一旦下面的哈希变了，**所有文字定位的基准都作废**，
必须重新 `--bless` 黄金图并检查所有按字宽算的版式
（图签列宽、标签避让、图例折行）。

```
788abee4c806d660e8aee46689dd8540cd4bb98da03dcc9d171ce3efd99a9173  LiberationSans-Bold.ttf
76d04c18ea243f426b7de1f3ad208e927008f961dc5945e5aad352d0dfde8ee8  LiberationSans-Regular.ttf
```

## 踩过的坑

**PostScript 名不带 `-Regular`。** 常规体叫 `LiberationSans`，
粗体才叫 `LiberationSans-Bold`。在候选列表里写 `LiberationSans-Regular`
会解析失败并**静默退回 Arial** —— 而画面上看起来一切正常。

**SPM 的 `.process` 会把资源打平到 bundle 根目录**，不保留 `Fonts/` 子目录。
所以 `Bundle.module.urls(forResourcesWithExtension:subdirectory:)` 两处都要找。

**缓存与注册的顺序。** 早先"先查缓存、后注册字体"，并发首次调用时
会把系统回退字体写进缓存且永不再更新。现在整段「注册 → 解析 → 写缓存」
在同一把锁内完成，兜底结果不入缓存。
