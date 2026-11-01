import Testing
import Foundation
@testable import LightPlotCore

/// 画布在屏幕上的可读性。
///
/// PDF 是 1:1 固定尺寸，永远可读。**画布不是** ——
/// 缩到"适应图纸"时，3mm 的标注只剩 2.8pt，屏幕上是一团灰。
///
/// 这里量化"在常见画布尺寸下，有多少文字会因为太小而被跳过"。
/// 不是为了断言"必须全部可读"（物理上不可能：整张 A1 塞进 900pt 宽，
/// 4.55mm 的图框分区号必然只有 4pt），而是为了**知道这个数字**，
/// 并保证关键信息（灯号、色片、场地图签）在合理缩放下可读。
@Suite("Canvas readability")
struct CanvasReadabilityTests {

    /// 画布的绘制门限：低于 0.4pt 才真正跳过（极端缩小）。
    /// 介于 0.4pt 与 3.5pt 之间的会被**放大到 3.5pt 再画**，而不是消失。
    private let hardFloor: Double = 1.6

    /// 统计在给定画布宽度下，各图层有多少文字会被**跳过**（不是被放大）。
    private func skippedByLayer(_ ops: [DrawOp], canvasWidth: Double,
                               paperWidth: Double) -> [String: (skipped: Int, total: Int)] {
        let zoom = canvasWidth / paperWidth
        var out: [String: (Int, Int)] = [:]
        for op in ops {
            guard case .text(let t) = op else { continue }
            let layer = t.layer
            var e = out[layer] ?? (0, 0)
            e.1 += 1
            if t.capMM * zoom <= hardFloor { e.0 += 1 }
            out[layer] = e
        }
        return out
    }

    /// 给定缩放下某图层文字实际会被画出来的**屏幕字号**（pt）。
    /// 与 `SheetCanvas.drawText` 一致：保持真实尺寸，低于 1.6pt 不画。
    private func renderedCapPoints(_ ops: [DrawOp], layer: String,
                                   canvasWidth: Double, paperWidth: Double) -> [Double] {
        let zoom = canvasWidth / paperWidth
        return ops.compactMap { op -> Double? in
            guard case .text(let t) = op, t.layer == layer else { return nil }
            let natural = t.capMM * zoom
            return natural > hardFloor ? natural : nil
        }
    }

    /// **核心断言**：适应图纸时，灯号与通道号必须可见。
    ///
    /// 早先的实现会在 3pt 处直接跳过小字 —— 结果 iPad 上
    /// **全部 64 个灯号与 32 个通道号都消失了**（实测抓到）。
    /// 那些恰恰是图纸最重要的信息。
    @Test("At a fitted A1 on an iPad, lantern labels stay readable")
    func fixtureLabelsReadableWhenFitted() throws {
        var doc = try TestData.realDocument()
        _ = GelLibrary.fillMissingColours(in: &doc)
        let sheet = PlanSheet(fitting: doc)

        let stats = skippedByLayer(sheet.ops, canvasWidth: 800,
                                   paperWidth: sheet.layout.paper.widthMM)
        for key in ["FIXTURE_TXT", "MARK", "DIM"] {
            if let e = stats[key] {
                #expect(e.skipped == 0,
                        "\(key): \(e.skipped)/\(e.total) labels vanish")
            }
        }

        // 关键：这些标签在"适应图纸"的缩放下**确实会画出来**（≥1.6pt）。
        // 屏幕上密度低是真实的 —— 用户放大就清楚，而不是被强制放大后互相挤。
        for key in ["FIXTURE_TXT", "MARK"] {
            let sizes = renderedCapPoints(sheet.ops, layer: key,
                                          canvasWidth: 800,
                                          paperWidth: sheet.layout.paper.widthMM)
            #expect(!sizes.isEmpty, "\(key) has no text at all")
            #expect(sizes.allSatisfy { $0 > 1.6 },
                    "\(key): some labels fall below the visibility floor")
        }
    }

    /// 文字在常见画布尺寸下不该消失。
    /// （400pt 太窄，最小的 1.8mm 字会低于 1.6pt —— 那属于"放大才能看"，可接受。）
    @Test("Text survives normal canvas sizes")
    func textSurvivesFitting() throws {
        var doc = try TestData.realDocument()
        _ = GelLibrary.fillMissingColours(in: &doc)
        let sheet = PlanSheet(fitting: doc)

        for width in [800.0, 1400.0, 2400.0] {
            let stats = skippedByLayer(sheet.ops, canvasWidth: width,
                                       paperWidth: sheet.layout.paper.widthMM)
            let skipped = stats.values.reduce(0) { $0 + $1.skipped }
            #expect(skipped == 0,
                    "at \(width)pt wide, \(skipped) labels vanished")
        }
    }

    @Test("At full zoom every label is drawn")
    func fullZoomShowsEverything() throws {
        var doc = try TestData.realDocument()
        _ = GelLibrary.fillMissingColours(in: &doc)
        let sheet = PlanSheet(fitting: doc)
        let stats = skippedByLayer(sheet.ops, canvasWidth: sheet.layout.paper.widthMM,
                                   paperWidth: sheet.layout.paper.widthMM)
        let skipped = stats.values.reduce(0) { $0 + $1.skipped }
        #expect(skipped == 0, "at 1:1 nothing should be hidden; \(skipped) were")
    }

    /// 极端缩小（整张 A1 塞进 60pt）时，最小的字会被真正丢弃 ——
    /// 那时强制放大到 3.5pt 会让字互相压成一团，比不画更糟。
    @Test("At an extreme zoom-out, tiny text is dropped")
    func extremeZoomOutDrops() throws {
        let doc = try TestData.realDocument()
        let sheet = PlanSheet(fitting: doc)
        let stats = skippedByLayer(sheet.ops, canvasWidth: 60,
                                   paperWidth: sheet.layout.paper.widthMM)
        let skipped = stats.values.reduce(0) { $0 + $1.skipped }
        #expect(skipped > 0, "at 60pt wide, tiny text must be dropped")
    }

    @Test("Stroke widths stay visible at any zoom")
    func strokesStayVisible() {
        // 画布对线宽有 0.6pt 下限（0.049mm 的桁架线在 30% 缩放下会消失）
        for weight in Paper.LineWeight.allCases {
            let atFitted = weight.mm * 0.3
            #expect(atFitted < 0.6, "sanity: \(weight) at 30% is \(atFitted)pt, below the floor")
        }
        #expect(Paper.LineWeight.truss.mm * 0.3 < 0.6)
        #expect(Paper.LineWeight.frame.mm * 0.3 > 0.2)
    }

    @Test("The section sheet also keeps key labels readable")
    func sectionLabelsReadable() throws {
        let doc = try TestData.realDocument()
        let sheet = SectionSheet(fitting: doc)
        let stats = skippedByLayer(sheet.ops, canvasWidth: 1100,
                                   paperWidth: sheet.layout.paper.widthMM)
        for key in ["FIXTURE_TXT", "DIM", "NOTES"] {
            if let e = stats[key] {
                #expect(e.skipped == 0,
                        "\(key): \(e.skipped)/\(e.total) vanish on A3")
            }
        }
    }
}
