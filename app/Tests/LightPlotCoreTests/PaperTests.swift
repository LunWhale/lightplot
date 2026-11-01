import Testing
import Foundation
@testable import LightPlotCore

@Suite("Paper grammar")
struct PaperTests {

    @Test("A1 and A3 match the real sheet sizes")
    func sheetSizes() {
        #expect(PaperSize.a1.widthMM == 841 && PaperSize.a1.heightMM == 594)
        #expect(PaperSize.a3.widthMM == 420 && PaperSize.a3.heightMM == 297)
    }

    @Test("Line weights keep the measured dynamic range")
    func lineWeights() {
        // 参考图实测 0.025 → 0.713 mm，动态范围 28:1。
        // 这个比值是"看起来像专业图纸"的关键，衰减了就变草稿。
        let ratio = Paper.LineWeight.frame.mm / Paper.LineWeight.hair.mm
        #expect(abs(ratio - 28.52) < 0.01, "dynamic range drifted to \(ratio)")
        #expect(Paper.LineWeight.symbol.mm == 0.254)
        #expect(Paper.LineWeight.truss.mm == 0.049)
    }

    @Test("DXF line weight snapping lands on legal enum values")
    func dxfWeights() {
        // DXF 只接受固定线宽枚举；任意浮点会抛 DXFValueError。
        // 0.025mm = 2.5/100mm，在 0 与 5 之间打平；取小值 0（0.00mm = 最细），
        // 与旧管线 `paper.lw()` 的行为一致。保持一致比"更接近"更重要。
        #expect(Paper.LineWeight.hair.dxfValue == 0)
        #expect(Paper.LineWeight.truss.dxfValue == 5)
        #expect(Paper.LineWeight.symbol.dxfValue == 25)
        #expect(Paper.LineWeight.frame.dxfValue == 70)
        #expect(Paper.LineWeight.heavy.dxfValue == 35)
    }

    @Test("Truss geometry is stored in real millimetres and scales down to the sheet")
    func trussSpec() {
        // 实测图纸值：pitch 11.7687 / 高 12.0227 / 竖杆 1.016 / 弦杆 2.032
        #expect(abs(Paper.TrussSpec.pitchOnSheet(scale: 25) - 11.7687) < 2e-3)
        #expect(abs(Paper.TrussSpec.heightOnSheet(scale: 25) - 12.0227) < 2e-3)
        #expect(abs(Paper.TrussSpec.postWidthOnSheet(scale: 25) - 1.016) < 2e-3)
        #expect(abs(Paper.TrussSpec.chordHeightOnSheet(scale: 25) - 2.032) < 2e-3)
        // 高/宽比 1.0216 —— 不是正方形，别看错
        #expect(abs(Paper.TrussSpec.aspect - 1.0216) < 1e-3)
        // 1:50 图上也必须成立（存真实毫米的好处）
        #expect(abs(Paper.TrussSpec.pitchOnSheet(scale: 50) - 11.7687 / 2) < 2e-3)
    }

    @Test("Pipe is an empty rectangle, not a line")
    func pipeSpec() {
        #expect(abs(Paper.PipeSpec.heightOnSheet(scale: 25) - 1.9476) < 2e-3)
    }

    @Test("Diagonals stay inside the cell and keep the authored winding")
    func diagonals() {
        for poly in [Paper.TrussSpec.diagonalLeft, Paper.TrussSpec.diagonalRight] {
            #expect(poly.count == 4)
            for p in poly {
                #expect(p.x >= -0.001 && p.x <= 1.001)
                #expect(p.y >= -0.001 && p.y <= 1.001)
            }
            // 无自交（蝴蝶结）—— 顺序错了就会画成"丑陋波浪线"
            #expect(hasNoSelfIntersection(poly), "diagonal self-intersects: \(poly)")
        }
    }

    @Test("Draw order covers every layer exactly once")
    func drawOrder() {
        let layerNames = Set(Paper.layers.map(\.name))
        #expect(Paper.drawOrder.count == Paper.layers.count,
                "draw order has \(Paper.drawOrder.count) entries for \(Paper.layers.count) layers")
        #expect(Set(Paper.drawOrder) == layerNames, "draw order and layer table disagree")
        #expect(Set(Paper.drawOrder).count == Paper.drawOrder.count, "duplicate in draw order")
    }

    @Test("Masks come before what they protect")
    func maskOrdering() {
        func index(_ n: String) -> Int { Paper.drawOrder.firstIndex(of: n) ?? -1 }
        // 白底必须紧挨在它保护的对象之前：先铺白，再画线。
        #expect(index("TRUSS_FILL") < index("TRUSS"))
        #expect(index("PIPE_FILL") < index("PIPE"))
        #expect(index("FIXTURE_FILL") < index("FIXTURE"))
        #expect(index("SET_FILL") < index("SET"))
        // 图框永远最后画，否则会被内容盖住
        #expect(index("BORDER") > index("FIXTURE"))
        #expect(index("ACCENT") == Paper.drawOrder.count - 1)
    }

    @Test("Font sizes never increase as you go down the hierarchy")
    func fontHierarchy() {
        let order: [Paper.FontSize] = [
            .sheetNo, .show, .zone, .component, .position, .subtitle,
            .field, .device, .note, .dim, .unit, .color, .micro,
        ]
        for (a, b) in zip(order, order.dropFirst()) {
            // 允许相等：.zone 与 .component 都是 6.35，.device 与 .note 都是 3.04。
            // 它们是不同角色、同一个实测字号，不是错误。
            #expect(a.capMM >= b.capMM, "\(a) must not be smaller than \(b)")
        }
        // 正文一档是 3.04mm cap（实测参考图 4.25mm em × 0.7163）
        #expect(abs(Paper.FontSize.note.capMM - 3.04) < 0.01)
    }

    // MARK: 辅助

    /// 判定四边形是否自交（相邻边共享端点不算）。
    private func hasNoSelfIntersection(_ p: [Vec2]) -> Bool {
        let n = p.count
        for i in 0..<n {
            let a1 = p[i], a2 = p[(i + 1) % n]
            for j in (i + 1)..<n {
                if j == i || (j + 1) % n == i || (i + 1) % n == j { continue }
                let b1 = p[j], b2 = p[(j + 1) % n]
                if segmentsIntersect(a1, a2, b1, b2) { return false }
            }
        }
        return true
    }

    private func segmentsIntersect(_ a1: Vec2, _ a2: Vec2, _ b1: Vec2, _ b2: Vec2) -> Bool {
        func orient(_ p: Vec2, _ q: Vec2, _ r: Vec2) -> Double {
            (q - p).cross(r - p)
        }
        let o1 = orient(a1, a2, b1), o2 = orient(a1, a2, b2)
        let o3 = orient(b1, b2, a1), o4 = orient(b1, b2, a2)
        return (o1 * o2 < 0) && (o3 * o4 < 0)
    }
}
