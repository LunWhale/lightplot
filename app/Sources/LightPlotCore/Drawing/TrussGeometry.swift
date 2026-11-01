import Foundation

/// 一个填充 + 描边的多边形（图纸 mm）。
///
/// 桁架、管线、设备块全部由这类多边形拼出来。
/// 每个多边形都先铺白底再描边 —— 这就是参考图里"线条在构件边界处断开"的实现方式。
public struct RenderPolygon: Equatable, Sendable {
    public var points: [Vec2]
    public var layer: String
    public var fillLayer: String?

    public init(points: [Vec2], layer: String, fillLayer: String? = nil) {
        self.points = points
        self.layer = layer
        self.fillLayer = fillLayer
    }

    /// 有向面积（正 = 逆时针）。
    public var signedArea: Double {
        guard points.count >= 3 else { return 0 }
        var a = 0.0
        for i in 0..<points.count {
            let p = points[i], q = points[(i + 1) % points.count]
            a += p.cross(q)
        }
        return a / 2
    }

    public var area: Double { abs(signedArea) }

    public var bounds: Rect? { Rect(points: points) }
}

/// 桁架几何 —— 逐项移植自实测的参考图构造。
///
/// 一个单元是 1:1.0216 的矩形，内部是：
///
///     ┌─────────────────────┐  上弦（高 = 0.169 × 截面高）
///     ├──┬─────────────┬───┤
///     │  │    Λ   Λ    │   │  斜撑是**平行四边形**（不是线）
///     │杆│   Λ     Λ   │杆 │  顶点在单元中央，两只脚落在下弦两端
///     ├──┴─────────────┴───┤
///     └─────────────────────┘  下弦
///
/// **绘制顺序决定层次**（照抄参考图 PDF 的路径顺序）：
///     1. 竖杆   2. 斜撑   3. 下弦   4. 上弦   5. 末端收边竖杆
/// 全是白填充 + 细描边，后画的盖住先画的。
/// 所以斜撑端头被弦杆吃掉，得到"Λ 顶点正贴住上弦下沿"的干净效果。
///
/// ★ 两个会毁掉效果的细节：
///   · 斜撑顶点顺序错了 → 画成自交"蝴蝶结" → 用户说的"丑陋波浪线"
///   · 节距不能摊余数 → 必须精确等于 W，末尾留不满一格的残格
public enum TrussGeometry {

    /// 生成一段桁架的所有多边形（图纸 mm）。
    ///
    /// - Parameters:
    ///   - start: 中心线起点（图纸 mm）
    ///   - end: 中心线终点（图纸 mm）
    ///   - cellWidth: 单元宽（图纸 mm）。1:25 时 ≈ 11.7688
    public static func polygons(from start: Vec2, to end: Vec2,
                                cellWidth: Double) -> [RenderPolygon] {
        let delta = end - start
        let length = delta.length
        guard length > 1e-6, cellWidth > 1e-9 else { return [] }

        let u = delta / length
        let n = Vec2(-u.y, u.x)          // 法向：+侧 = 上弦侧

        let W = cellWidth
        let H = W * Paper.TrussSpec.aspect
        let pw = W * (Paper.TrussSpec.postWidthMM / Paper.TrussSpec.pitchMM)   // 竖杆宽
        let ch = H * (Paper.TrussSpec.chordHeightMM / Paper.TrussSpec.heightMM) // 弦杆高
        let hw = H / 2

        /// (沿轴 s, 法向 t) → 图纸坐标。
        func P(_ s: Double, _ t: Double) -> Vec2 {
            start + u * s + n * t
        }

        var out: [RenderPolygon] = []
        func solid(_ pts: [Vec2]) {
            out.append(RenderPolygon(points: pts, layer: "TRUSS", fillLayer: "TRUSS_FILL"))
        }

        // ★ 节距必须精确等于 W。把余数摊到每一格会让 pitch 变成 11.59，
        //   29 格后累积偏差 5mm，整条桁架的斜撑全部错位。
        let step = W
        let cells = max(1, Int((length / W - 1e-6).rounded(.up)))

        let sectionCells = Paper.TrussSpec.sectionCells
        let sections = max(1, (cells + sectionCells - 1) / sectionCells)

        for k in 0..<sections {
            let begin = Double(k * sectionCells) * step
            let count = min(sectionCells, cells - k * sectionCells)
            guard count > 0 else { continue }
            // 末节可能只占不满一格：必须夹到构件长度，否则弦杆会伸出杆外
            // （51 格 × 11.7688 = 600.2mm，而杆只有 600mm）。
            let endS = min(begin + Double(count) * step, length)

            // 1. 竖杆
            for i in 0..<count {
                let s = begin + Double(i) * step
                let sEnd = min(s + pw, length)
                guard sEnd - s > 1e-6 else { continue }
                solid([P(s, hw), P(sEnd, hw), P(sEnd, -hw), P(s, -hw)])
            }

            // 2. 斜撑（左腿先、右腿后 —— 右腿压住左腿，产生层次）
            for i in 0..<count {
                let s0 = begin + Double(i) * step
                let wi = min(W, length - s0)
                if wi < W * 0.25 { break }
                for quad in [Paper.TrussSpec.diagonalLeft, Paper.TrussSpec.diagonalRight] {
                    let pts = quad.map { q -> Vec2 in
                        // q.y 是以单元左下角为原点的 y-up 归一化坐标；
                        // 换成以中线为原点：t = (q.y - 0.5) * H
                        P(s0 + q.x * wi, (q.y - 0.5) * H)
                    }
                    solid(pts)
                }
            }

            // 3/4. 本节弦杆：下弦先、上弦后
            for top in [false, true] {
                let tOut = top ? hw : -hw
                let tIn = top ? (hw - ch) : (-hw + ch)
                solid([P(begin, tOut), P(endS, tOut), P(endS, tIn), P(begin, tIn)])
            }
        }

        // 5. 末端收边竖杆（最后画，压住最后一节的弦杆断口）
        solid([P(length - pw, hw), P(length, hw),
               P(length, -hw), P(length - pw, -hw)])

        return out
    }
}

/// 管线几何 —— 一个**空心超长方形**，不是单线，也不是波浪。
///
/// 参考图实测：外高 5.52pt = 1.9476mm，白填充 + 0.144pt 细描边，**没有内线**。
/// 用户原话：「LX 和 SOUND 的这个线是空心线，是一个超级长方形。」
public enum PipeGeometry {

    public static func polygon(from start: Vec2, to end: Vec2,
                               height: Double) -> RenderPolygon? {
        let delta = end - start
        let length = delta.length
        guard length > 1e-6, height > 1e-9 else { return nil }
        let u = delta / length
        let n = Vec2(-u.y, u.x) * (height / 2)

        return RenderPolygon(
            points: [start - n, end - n, end + n, start + n],
            layer: "PIPE",
            fillLayer: "PIPE_FILL"
        )
    }
}
