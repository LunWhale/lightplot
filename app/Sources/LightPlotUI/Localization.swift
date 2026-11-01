import Foundation

/// 界面中文化。
///
/// ## 为什么是手写表，而不是 `Localizable.strings`
///
/// `LightPlotUI` 是 SwiftPM 目标，同时被 macOS 与 iPadOS 两个 Xcode 目标引用。
/// 走系统本地化需要 `defaultLocalization` + 资源包 + `.xcstrings`，
/// 三处配置任何一处漏掉，表现就是"界面静默变回英文" —— 而这种失败
/// 在自动化测试里看不见（测试跑在英文环境里）。
///
/// 显式表的好处：**可以直接断言**。`LocalizationTests` 会扫源码里每一个
/// `L10n.t("…")` 键，确认它在这张表里、中文非空、且确实与英文不同。
/// 新增界面文字却忘了翻译，测试立刻变红。
///
/// ## 语言选择
///
/// 跟随系统首选语言：`zh*` → 中文，其余 → 英文。
/// 也允许代码里覆盖（测试与将来的设置项用）。
public enum L10n {

    public enum Language: String, Sendable, CaseIterable {
        case chinese, english
    }

    /// 当前语言。默认跟随系统。
    public nonisolated(unsafe) static var language: Language = systemLanguage()

    static func systemLanguage() -> Language {
        let tag = Locale.preferredLanguages.first ?? "en"
        return tag.lowercased().hasPrefix("zh") ? .chinese : .english
    }

    /// 取一条界面文字。
    ///
    /// 英文原串同时是**键**：表里没有时原样返回英文，
    /// 于是漏翻只会显示英文，不会显示成键名或空白。
    public static func t(_ english: String) -> String {
        guard language == .chinese else { return english }
        return table[english] ?? english
    }

    /// 带插值的界面文字。
    public static func tf(_ english: String, _ args: CVarArg...) -> String {
        String(format: t(english), arguments: args)
    }

    /// 英文 → 中文对照表。
    ///
    /// 术语处理：`trim` / `cue` / `gel` / `DMX` 这类舞台行话保留英文，
    /// 因为中文剧场里也是直接说英文（译成"吊杆高度"反而不好对上现场）。
    public static let table: [String: String] = [
        // ---- 检查器：分组标题
        "Sheet": "图纸信息",
        "Stage": "舞台",
        "Audience": "观众席",
        "Scene": "场景",
        "Selection": "选择",
        "Checks": "检查",
        "Set piece": "布景",
        "Acting zone": "光区",
        "Position": "吊挂位置",
        "Lantern": "灯具",

        // ---- 图纸信息
        "Show": "剧名",
        "Playwright": "编剧",
        "Venue": "剧场",
        "Director": "导演",
        "Designer": "灯光设计",
        "Sheet title": "图名",
        "Date": "日期",
        "Revision": "版本",
        "Revision note": "版本说明",
        "Scale": "比例",
        "Paper": "纸张",
        "Centre the plan": "图纸居中",
        "Shift on paper": "在纸上微调",
        "Does not fit on this sheet": "这张纸装不下",
        "Use a larger sheet or 1:50.": "换更大的纸，或改成 1:50。",
        "Fits %.1f x %.1f m at 1:%.0f": "最多装 %.1f x %.1f 米（1:%.0f）",

        // ---- 舞台
        "Stage width": "舞台宽",
        "Stage depth": "舞台深",
        "Grid height": "栅顶高度",
        "Proscenium height": "台口高度",
        "Plaster line": "台口线位置",
        "Audience rows": "观众席排数",
        "Row depth": "每排进深",
        "Rake per row": "每排起坡",

        // ---- 场景
        "Base (no scene)": "基础图（不含场景）",
        "Base": "基础图",
        "Base plan uses the document's own gels.": "基础图用文档里原本的色片。",
        "Lit": "亮灯数",
        "Gels": "色片数",
        "Contrast may be too weak for two distinct scenes.": "两个场景的对比可能不够明显。",
        "in scene": "场景内",

        // ---- 灯具
        "Type": "类型",
        "Location": "位置",
        "Aim": "朝向",
        "Channel": "通道",
        "Purpose": "用途",
        "What does it light?": "这盏灯照什么？",
        "Beam": "光束角",
        "Colour": "色片",
        "Delete lantern": "删除这盏灯",
        "The sheet prints the second one.": "图上印的是右边那个。",

        // ---- 吊挂位置
        "Name": "名称",
        "Length": "长度",
        "Cells": "格数",
        "Trim": "trim",
        "Lanterns": "灯具数",
        "Join the two selected trusses": "合并选中的两根桁架",
        "Delete position": "删除这个位置",

        // ---- 布景 / 光区
        "Kind": "种类",
        "Label": "标注",
        "Size": "尺寸",
        "Height": "高度",
        "Steps": "踏步数",
        "Tread": "踏面深度",
        "Centre": "中心",
        "Lanterns inside": "区内灯具数",
        "Delete set piece": "删除这个布景",
        "Delete zone": "删除这个光区",
        "Drag it on the canvas to move it.": "在画布上拖动可以移动它。",

        // ---- 提示与状态
        "All checks pass": "检查全部通过",
        "Nothing to report": "没有发现问题",
        "Tap a lantern or a truss to edit it.": "点一盏灯或一根杆来编辑。",
        "Drag a lantern along its bar to slide it. Drag a truss end to resize. Pinch to zoom.":
            "沿杆拖灯可以滑动；拖桁架端点可以改长度；捏合可以缩放。",
        "All %d rows see the stage": "全部 %d 排都能看到台面",
        "%d of %d rows blocked": "%d / %d 排视线受阻",
        "worst: row %d, %d mm": "最差：第 %d 排，%d 毫米",
        "Lantern %d": "灯具 %d",

        // ---- 工具栏
        "Undo": "撤销",
        "Redo": "重做",
        "Add a lantern to the selected truss": "往选中的杆上加一盏灯",
        "Add a truss, set piece or zone": "加桁架、布景或光区",
        "Join trusses": "合并桁架",
        "Delete selection": "删除选中",
        "Beams": "光束",
        "Fit": "适配窗口",
        "Page Setup": "页面设置",
        "Inspector": "检查器",
        "Save": "保存",
        "Export": "导出",
        "Show this plan in a scene state": "按场景状态查看这张图",
        "Sheet PDF": "图纸 PDF",
        "Tables (CSV)": "表格（CSV）",
        "All scene sheets": "所有场景的图",

        // ---- 页面设置面板
        "Paper size and scale for this sheet": "这张图的纸张尺寸与比例",
        "Paper size": "纸张尺寸",
        "Orientation": "方向",
        "Result": "结果",
        "Landscape": "横向",
        "Portrait": "纵向",
        "Drawing area": "可绘制区域",
        "Holds up to": "最多能装",
        "Your content": "你的内容",
        "Default is A1 — the standard sheet for a lighting plan.":
            "默认 A1 —— 灯光平面图的标准图幅。",
        "Plan fits inside the drawing area": "图纸在可绘制区域内",
        "Content does not fit. The sheet will print a notice instead of the plan.":
            "内容装不下。这张纸会印一张说明页，而不是图纸。",
        "Apply": "应用",
        "Applied": "已应用",
        "Cancel": "取消",
        "Done": "完成",

        // ---- 页面 / 图名
        "Plan": "平面图",
        "Section": "剖面图",

        // ---- 导出流程
        "Choose where to save the PDF.": "选择 PDF 保存位置。",
        "This paper cannot hold the plan at this scale.": "这张纸在这个比例下装不下。",

        // ---- 文件与编辑命令
        "New Plan": "新建图纸",
        "Open…": "打开…",
        "Export A1 PDF…": "导出 A1 PDF…",
        "Open a plan": "打开图纸",
        "Start a new plan": "新建图纸",
        "Lighting plots that print at true scale.": "打印出来量得到真实尺寸的灯光图。",
        "Lighting plans at 1:25, drawn on a canvas.": "1:25 的灯光图，在画布上直接画。",
        "Files in the old YAML format open directly. Nothing is overwritten until you export.":
            "旧格式的 YAML 文件可以直接打开。在你导出之前，原文件不会被改动。",

        // ---- 未能保存等提示
        "Could not save the document.": "文档保存失败。",
        "Untitled": "未命名",
        "Edited": "已修改",
        "Could not export the PDF.": "PDF 导出失败。",
    ]
}
