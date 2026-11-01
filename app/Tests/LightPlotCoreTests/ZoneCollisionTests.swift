import Testing
import Foundation
@testable import LightPlotCore

/// 版面区域的几何冲突。
///
/// 上面几轮查的是"文字与文字"，这里查的是**区域与区域**：
/// 平面内容有没有压进图例栏、图例有没有压进图签、剖面绘图区有没有压进右栏。
///
/// 这类冲突比文字重叠更隐蔽 —— 文字重叠看得出来，
/// 但"一根桁架穿过图例"看起来就像图例里多了一条线。
@Suite("Layout region collisions")
struct LayoutRegionTests {

    /// 平面图里所有非图例/非图签的图形，必须完全落在绘图区内。
    @Test("Plan geometry stays out of the info column")
    func planGeometryClearOfInfoColumn() throws {
        var doc = try TestData.realDocument()
        _ = GelLibrary.fillMissingColours(in: &doc)
        let sheet = PlanSheet(fitting: doc)
        let area = SheetLayout.planArea(paper: sheet.layout.paper)

        // 图例内部会画灯具符号与色块 —— 它们的实体层名是空的（fill 无 layer）
        // 或 FIXTURE，但位置本来就在右栏里。所以判定要**按位置**：
        // 若整块图形完全落在信息栏内，它就是图例内容，不是侵入。
        let infoColumn = Rect(x0: SheetLayout.infoColumnX(for: sheet.layout.paper) - 4,
                              y0: 0, x1: sheet.layout.paper.widthMM, y1: sheet.layout.paper.heightMM)

        var intruders: [String] = []
        for op in sheet.ops {
            let layer = op.layer ?? ""
            let infoLayers: Set<String> = ["LEGEND", "TITLEBLK", "TB_TEXT", "NOTES",
                                           "BORDER", "GRIDTEXT"]
            guard !infoLayers.contains(layer) else { continue }
            guard let pts = op.pointsForBounds, !pts.isEmpty,
                  let b = Rect(points: pts) else { continue }
            // 完全在信息栏里的 = 图例自绘内容，跳过
            if infoColumn.contains(b.center) { continue }
            // 允许一点点线宽溢出
            if b.x1 > area.x1 + 1.0 || b.x0 < area.x0 - 1.0
                || b.y1 > area.y1 + 1.0 || b.y0 < area.y0 - 1.0 {
                intruders.append("\(layer) at \(b)")
            }
        }
        #expect(intruders.isEmpty,
                Comment(rawValue: "\(intruders.count) drawings enter the info column: "
                        + intruders.prefix(4).joined(separator: " | ")))
    }

    @Test("The legend box does not overlap the title block")
    func legendAboveTitleBlock() {
        let layout = SheetLayout()
        let legend = SheetLayout.legendRect(for: layout)
        let title = SheetLayout.titleBlockRect(for: layout)
        #expect(legend.y0 >= title.y1 - 0.01,
                "legend bottom \(legend.y0) must sit above title top \(title.y1)")
        #expect(!legend.overlapsStrictly(title))
    }

    @Test("The info column sits entirely inside the frame")
    func infoColumnInsideFrame() {
        for paper in PaperSize.all {
            let layout = SheetLayout(paper: paper)
            let title = SheetLayout.titleBlockRect(for: layout)
            let legend = SheetLayout.legendRect(for: layout)
            let inner = layout.innerFrame
            #expect(title.x1 <= inner.x1 - 5, "\(paper.name): title block crosses the frame")
            #expect(legend.x1 <= inner.x1 - 5, "\(paper.name): legend crosses the frame")
            #expect(title.x0 >= inner.x0 && title.y0 >= inner.y0)
            #expect(legend.y0 >= inner.y0)
        }
    }

    @Test("Section drawing stays out of its info panel")
    func sectionClearOfPanels() throws {
        let doc = try TestData.realDocument()
        let sheet = SectionSheet(fitting: doc)
        let area = sheet.layout.drawingArea
        let paper = sheet.layout.paper
        // 右栏起点（与 SectionBuilder.drawPanels 一致）
        let panelLeft = paper.widthMM - Paper.frameInner - 62 - 9

        var intruders: [String] = []
        for op in sheet.ops {
            let layer = op.layer ?? ""
            let panelLayers: Set<String> = ["TITLEBLK", "TB_TEXT", "NOTES",
                                            "BORDER", "GRIDTEXT"]
            guard !panelLayers.contains(layer) else { continue }
            guard let pts = op.pointsForBounds, !pts.isEmpty,
                  let b = Rect(points: pts) else { continue }
            if b.x1 > panelLeft + 1.0 {
                intruders.append("\(layer) reaches x=\(String(format: "%.1f", b.x1))")
            }
        }
        _ = area
        #expect(intruders.isEmpty,
                Comment(rawValue: "\(intruders.count) drawings enter the section panel: "
                        + intruders.prefix(4).joined(separator: " | ")))
    }
}
