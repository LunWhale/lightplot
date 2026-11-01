import Foundation

/// 构件合并。
///
/// 用户原话：「最基础的吸附功能，比如合并两个桁架为一个长桁架」。
///
/// **这是一个语义操作，不是拖拽的副产品。**
/// 因为灯具的 `x` 是**绝对轴坐标**，合并后杆的起点变了，
/// 但灯不需要改坐标 —— 它们本来就是世界坐标。
/// 真正需要改的是那些**按沿杆偏移保存**的东西（如果将来引入的话）。
///
/// 所以合并的难点不在算术，在**判定"该不该合并"**：
///   · 必须共线（同一 y，误差 < 0.5mm）
///   · 必须相接或有很小的缝（≤ 30mm），不能跨半米去接
///   · 类型必须相同（桁架不能和管线合并）
///   · 合并后不能把灯具放到杆外（否则合并本身制造了错误数据）
///
/// 四条里任何一条不满足，都不合并，并给出明确原因 ——
/// 静默地"差不多就合了"是这类编辑器最容易毁数据的做法。
public enum Merger {

    public struct Candidate: Equatable, Sendable {
        public let a: String          // 保留这根
        public let b: String          // 并入 a
        public let merged: Position
        public let fixturesMoved: Int
        public let gap: Double        // 原始缝隙（负值 = 重叠）

        public var description: String {
            "\(a) + \(b) → \(merged.id)  gap \(String(format: "%.1f", gap))mm"
        }
    }

    public enum Refusal: String, Equatable, Sendable {
        case notCollinear = "the two bars are not on the same axis"
        case differentType = "only bars of the same type can be joined"
        case tooFar = "the gap is too large to join"
        case wouldOrphan = "joining would leave lanterns outside the new bar"
        case sameBar = "a bar cannot be joined to itself"
    }

    public enum Result: Equatable, Sendable {
        case merge(Candidate)
        case refuse(Refusal)
    }

    /// 判定两根构件能否合并，以及合并后的形状。
    ///
    /// - Parameters:
    ///   - toleranceGap: 允许的最大缝隙（文档 mm）。默认 30mm ——
    ///     相当于图纸上 1.2mm，正好是手指能对上的精度。
    ///   - collinearTolerance: 判定共线的轴偏移容差（文档 mm）。
    public static func evaluate(_ a: Position, _ b: Position,
                                in doc: LXDocument,
                                toleranceGap: Double = 30,
                                collinearTolerance: Double = 0.5) -> Result {
        guard a.id != b.id else { return .refuse(.sameBar) }
        guard let sa = a.shape, let sb = b.shape else { return .refuse(.notCollinear) }
        // 方向检查在类型检查之前：横杆与立杆"共线"这件事本身就不成立，
        // 先报"方向不同"才不会误导用户去改类型。
        guard sa.isHorizontal == sb.isHorizontal else { return .refuse(.notCollinear) }
        guard a.type == b.type else { return .refuse(.differentType) }

        let merged: Position
        let gap: Double

        switch (sa, sb) {
        case (.horizontal(let ax0, let ax1, let ay), .horizontal(let bx0, let bx1, let by)):
            guard abs(ay - by) <= collinearTolerance else { return .refuse(.notCollinear) }
            let alo = min(ax0, ax1), ahi = max(ax0, ax1)
            let blo = min(bx0, bx1), bhi = max(bx0, bx1)
            gap = max(blo - ahi, alo - bhi)
            guard gap <= toleranceGap else { return .refuse(.tooFar) }

            var out = a
            out.x0 = min(alo, blo)
            out.x1 = max(ahi, bhi)
            out.y = ay
            merged = out

        case (.vertical(let ax, let ay0, let ay1), .vertical(let bx, let by0, let by1)):
            guard abs(ax - bx) <= collinearTolerance else { return .refuse(.notCollinear) }
            let alo = min(ay0, ay1), ahi = max(ay0, ay1)
            let blo = min(by0, by1), bhi = max(by0, by1)
            gap = max(blo - ahi, alo - bhi)
            guard gap <= toleranceGap else { return .refuse(.tooFar) }

            var out = a
            out.y0 = min(alo, blo)
            out.y1 = max(ahi, bhi)
            out.x = ax
            merged = out

        default:
            return .refuse(.notCollinear)
        }

        // 合并后每盏灯都必须仍然落在杆内。
        // 缝隙在容差内时这必然成立，但显式检查 ——
        // 一旦将来有人放宽 toleranceGap，这里会挡住"合并把灯放到杆外"。
        let attached = doc.fixtures.filter { $0.pos == a.id || $0.pos == b.id }
        for f in attached where !f.isFreeMounted {
            guard let shape = merged.shape else { return .refuse(.wouldOrphan) }
            let axis: Double?
            switch shape {
            case .horizontal: axis = f.x ?? f.y
            case .vertical:   axis = f.y ?? f.x
            }
            guard let axis else { return .refuse(.wouldOrphan) }
            let lo: Double, hi: Double
            switch shape {
            case .horizontal(let x0, let x1, _): lo = min(x0, x1); hi = max(x0, x1)
            case .vertical(_, let y0, let y1):   lo = min(y0, y1); hi = max(y0, y1)
            }
            if axis < lo - 1e-6 || axis > hi + 1e-6 { return .refuse(.wouldOrphan) }
        }

        // `a` 的名字优先保留（用户先画的那根）。
        // trim 取两者较高者 —— 挂得更高更安全，不会因为合并而变低。
        var final = merged
        final.id = a.id
        if let ta = a.trim, let tb = b.trim {
            final.trim = max(ta, tb)
        } else {
            final.trim = a.trim ?? b.trim
        }

        return .merge(Candidate(a: a.id, b: b.id, merged: final,
                                fixturesMoved: attached.count, gap: gap))
    }

    /// 对整份文档找出所有可合并的构件对（用于 hover 提示与"一键整理"）。
    ///
    /// 排序保证确定性：先按 A 的 id，再按 B 的 id。
    public static func candidates(in doc: LXDocument,
                                  toleranceGap: Double = 30) -> [Candidate] {
        var out: [Candidate] = []
        let positions = doc.positions.sorted { $0.id < $1.id }
        for i in 0..<positions.count {
            for j in (i + 1)..<positions.count {
                if case .merge(let c) = evaluate(positions[i], positions[j], in: doc,
                                                 toleranceGap: toleranceGap) {
                    out.append(c)
                }
            }
        }
        return out
    }

    /// 执行合并：把 `b` 的灯具改挂到 `a`，删除 `b`。
    ///
    /// 灯具的坐标**不改** —— 它们是绝对轴坐标，杆变长不会影响它们的位置。
    /// 这正是"沿杆绝对轴值"这个设计的价值：合并是无损的。
    public static func apply(_ candidate: Candidate, to doc: inout LXDocument) {
        guard let index = doc.positions.firstIndex(where: { $0.id == candidate.a }) else { return }
        doc.positions[index] = candidate.merged

        for i in doc.fixtures.indices where doc.fixtures[i].pos == candidate.b {
            doc.fixtures[i].pos = candidate.a
        }
        doc.positions.removeAll { $0.id == candidate.b }
    }
}
