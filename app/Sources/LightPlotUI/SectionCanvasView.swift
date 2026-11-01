import SwiftUI
import LightPlotCore

/// 剖面图画布。
///
/// **复用 `SheetCanvas` 的全部绘制代码**，只把"指令列表"和"纸张尺寸"换掉。
/// 这样平面图与剖面图只有一个绘制实现 —— 不会出现"平面改了、剖面忘了改"。
///
/// 做法：把 `SectionSheet` 包装成一个 `PlanSheet` 形状的适配器。
/// 这比"复制一份 SheetCanvas"安全得多，也比"给 SheetsCanvas 加泛型参数"侵入更小。
public struct SectionCanvasView: View {
    let section: SectionSheet
    let viewport: Viewport
    let canvasSize: Vec2
    let autoFit: Bool

    public init(section: SectionSheet, viewport: Viewport,
                canvasSize: Vec2 = Vec2(1000, 700), autoFit: Bool = true) {
        self.section = section
        self.viewport = viewport
        self.canvasSize = canvasSize
        self.autoFit = autoFit
    }

    public var body: some View {
        // 用 PlanSheet 作为"指令 + 版面"的载体：
        // 剖面图的版面在 SectionLayout 里，这里把它投影成一个等价的 SheetLayout，
        // 只为让 SheetCanvas 能按同一套逻辑做纸张与视口换算。
        SheetCanvas(sheet: adapterSheet,
                    viewport: viewport,
                    selection: .empty,
                    showBeams: true,
                    hoverPosition: nil,
                    autoFit: autoFit,
                    canvasSize: canvasSize)
    }

    /// 把剖面图的指令与纸张包装成 `PlanSheet`。
    ///
    /// 注意 `layout` 只用于"纸张尺寸/图框"这类通用信息；
    /// 剖面图的几何已经在 `ops` 里算好了（含纵深→横轴的换向），
    /// 所以这里的 `SheetLayout` 不做任何坐标换算，只提供纸面。
    private var adapterSheet: PlanSheet {
        var layout = SheetLayout(paper: section.layout.paper,
                                 scaleDenominator: section.layout.scaleDenominator,
                                 originOnSheet: section.layout.originOnSheet)
        // 剖面图的绘图区比平面图窄（右侧有信息栏），但纸面尺寸相同。
        _ = layout
        return PlanSheet(preRenderedDoc: section.doc,
                         layout: layout,
                         ops: section.ops)
    }
}
