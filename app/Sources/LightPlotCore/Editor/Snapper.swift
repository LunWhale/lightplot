import Foundation

/// 吸附引擎。
///
/// 全部在**图纸坐标（mm）**里算，因为吸附半径是视觉量：
/// 用户看到的 8pt 在 1:25 的图上就是 0.32mm 纸面。
/// 如果在文档坐标里吸附，"吸附强度"会随比例变化 —— 换 1:50 就变得很难吸上。
public enum Snapper {

    /// 找出离 `p` 最近的吸附目标。
    ///
    /// 优先级：端点 > 构件轴线 > 共线延长 > 网格。
    /// 端点优先是因为"两根桁架接起来"是最常见的操作，
    /// 而用户手指落在两根杆端之间时，想接的是端点，不是网格。
    public static func snap(_ p: Vec2,
                            doc: LXDocument,
                            layout: SheetLayout,
                            viewport: Viewport,
                            options: SnapOptions = SnapOptions(),
                            excludingPosition: String? = nil,
                            excludingFixture: Int? = nil) -> SnapResult {
        guard options.enabled else { return SnapResult(point: p, kind: nil, distance: .infinity) }

        // 吸附半径：屏幕点 → 图纸 mm
        let radiusPaper = options.radius / max(viewport.zoom, 1e-6)

        // 吸附按 **(优先级, 距离)** 取最优，而不是"先看距离、优先级只做兜底"。
        //
        // 早先的写法是 `d < best.distance || (d <= radius && 新rank更优)` ——
        // 但第一个条件会让**任何更近的点**无条件胜出，
        // 于是更近的网格点击败了稍远但更重要的构件端点。
        // 后果很实际：想把两根桁架接起来时，端点吸附永远抢不过网格，
        // 而"接桁架"正是端点吸附存在的理由。
        let rank: [SnapResult.SnapKind: Int] = [
            .endpoint: 0, .fixtureSlot: 1, .axis: 2, .collinear: 3, .grid: 4,
        ]
        var best = SnapResult(point: p, kind: nil, distance: radiusPaper)

        func consider(_ q: Vec2, _ kind: SnapResult.SnapKind) {
            let d = p.distance(to: q)
            guard d <= radiusPaper else { return }
            let newRank = rank[kind] ?? 9
            guard let currentKind = best.kind else {
                best = SnapResult(point: q, kind: kind, distance: d)
                return
            }
            let currentRank = rank[currentKind] ?? 9
            if newRank < currentRank || (newRank == currentRank && d < best.distance) {
                best = SnapResult(point: q, kind: kind, distance: d)
            }
        }

        // 1. 构件端点
        for position in doc.positions where position.id != excludingPosition {
            guard let shape = position.shape else { continue }
            consider(layout.toSheet(shape.start), .endpoint)
            consider(layout.toSheet(shape.end), .endpoint)
        }

        // 2. 构件轴线（最近点）
        for position in doc.positions where position.id != excludingPosition {
            guard let shape = position.shape else { continue }
            let a = layout.toSheet(shape.start)
            let b = layout.toSheet(shape.end)
            let (_, foot) = p.projected(onto: a, b)
            // 只吸附到轴线本身，不是延长线
            let t = ((foot - a).dot(b - a)) / max((b - a).lengthSquared, 1e-12)
            if t >= 0 && t <= 1 { consider(foot, .collinear) }
        }

        // 3. 与另一构件同 x / 同 y（极轴追踪）
        for position in doc.positions where position.id != excludingPosition {
            guard let shape = position.shape else { continue }
            let a = layout.toSheet(shape.start)
            let b = layout.toSheet(shape.end)
            if abs(a.y - b.y) < 0.01 {          // 水平杆
                consider(Vec2(p.x, a.y), .axis)
            } else if abs(a.x - b.x) < 0.01 {   // 竖直杆
                consider(Vec2(a.x, p.y), .axis)
            }
        }

        // 4. 构件上已有的灯具位置（对齐灯具很常用）
        for (fixture, mount) in Resolver.allMounts(in: doc) where fixture.unit != excludingFixture {
            if case .onPosition = mount, let w = mount.worldPoint {
                consider(layout.toSheet(w), .fixtureSlot)
            }
        }

        // 5. 网格（文档 mm 的整步长）
        if options.gridStep > 0 {
            let docPoint = layout.toDocument(p)
            let gx = (docPoint.x / options.gridStep).rounded() * options.gridStep
            let gy = (docPoint.y / options.gridStep).rounded() * options.gridStep
            consider(layout.toSheet(Vec2(gx, gy)), .grid)
        }

        return best
    }

    /// 吸附到"最近的构件"，返回 (构件 id, 沿图纸的投影点)。
    ///
    /// 灯具拖到杆附近时用它：命中即锁在杆上，这是"灯永不脱杆"的保证。
    /// 返回 nil 表示没有构件在吸附范围内 —— 此时调用方应当拒绝加入灯具，
    /// 或者明确把它做成台上实物，而不是凭空造一台飘着的灯。
    public static func nearestPosition(to p: Vec2,
                                       doc: LXDocument,
                                       layout: SheetLayout,
                                       viewport: Viewport,
                                       radiusPoints: Double = 12) -> (id: String, point: Vec2, distance: Double)? {
        let radiusPaper = radiusPoints / max(viewport.zoom, 1e-6)
        var best: (id: String, point: Vec2, distance: Double)?

        for position in doc.positions {
            guard let shape = position.shape else { continue }
            let a = layout.toSheet(shape.start)
            let b = layout.toSheet(shape.end)
            let (_, foot) = p.projected(onto: a, b)
            let d = p.distance(to: foot)
            guard d <= radiusPaper else { continue }
            if best == nil || d < best!.distance {
                best = (position.id, foot, d)
            }
        }
        return best
    }
}
