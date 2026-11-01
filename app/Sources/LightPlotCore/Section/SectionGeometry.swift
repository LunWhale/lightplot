import Foundation

/// 剖面图专用几何。
///
/// 平面图只需要"投影"，剖面图需要**真实的物理关系**：
///   · 光束从灯口射出，按光束角张开，落到焦点上
///   · 光束会被布景挡住（这是剖面图最有价值的信息之一）
///   · 观众视线要从眼位出发，越过前座头顶，落到台面
///
/// 这些不是装饰。剖面图的意义就在于它是**唯一能看出"光有没有被挡"**的那张图。
public enum SectionGeometry {

    // MARK: 光束

    /// 一条光束在给定纵深处的高度范围（mm）。
    ///
    /// 用真实的光束角在半角方向上展开 —— 不是"画两条斜线"。
    /// 这样"这盏灯在 4m 处光斑多宽"是量得出来的。
    public struct BeamSlice: Equatable, Sendable {
        public let depth: Double
        public let low: Double
        public let high: Double
        public var width: Double { high - low }
        public var centre: Double { (low + high) / 2 }
    }

    /// 从灯位出发的光束包络。
    ///
    /// - Parameters:
    ///   - apex: 灯口位置 (纵深, 高度)
    ///   - aimDegrees: 出光方向。剖面图里只关心纵深-高度平面：
    ///                   90 = 垂直向下打（最常见的舞台灯位）
    ///                   0  = 水平朝后墙打
    ///   - beamAngle: 全光束角（度）
    ///   - reach: 包络长度（mm）
    public struct BeamEnvelope: Equatable, Sendable {
        public let apex: Vec2
        /// 光轴方向（单位向量，x = 纵深增加方向，y = 高度增加方向）。
        public let axis: Vec2
        /// 两侧包络方向。
        public let edges: [Vec2]
        public let length: Double

        /// 在给定纵深处的截面。返回 nil 表示该纵深不在这条光束的覆盖内。
        ///
        /// **光轴垂直于纵深轴时要特殊处理。** 灯正对下方打（axis.x ≈ 0）是
        /// 最常见的舞台灯位，此时 `(depth - apex.x) / axis.x` 是除零。
        /// 正确解：垂直光束在一整段纵深上都存在，其横向宽度由光束角决定，
        /// 而不是由"沿轴走了多远"决定 —— 此时截面直接取 apex 处的几何。
        public func slice(atDepth depth: Double) -> BeamSlice? {
            let perpendicular = axis.x.magnitude < 1e-9

            if perpendicular {
                // 垂直光束：只有正好在 apex 纵深上才取截面。
                // 用一个与光束角相符的小容差，避免浮点抖动。
                guard abs(depth - apex.x) < max(1.0, length * 1e-6) else { return nil }
                // 整条光束在 apex 处的横向跨度由两侧边界决定
                var ys: [Double] = [apex.y]
                for e in edges {
                    // 任何方向都能用：直接取该方向到 length 的端点高度
                    ys.append(apex.y + e.y * length)
                }
                return BeamSlice(depth: depth, low: ys.min() ?? apex.y,
                                 high: ys.max() ?? apex.y)
            }

            let t = (depth - apex.x) / axis.x
            guard t >= 0, t <= length else { return nil }
            let centre = apex.y + axis.y * t

            var lows: [Double] = [centre]
            var highs: [Double] = [centre]
            for e in edges {
                guard e.x.magnitude > 1e-9 else { continue }
                let s = (depth - apex.x) / e.x
                guard s >= 0, s <= length else { continue }
                let y = apex.y + e.y * s
                lows.append(y)
                highs.append(y)
            }
            return BeamSlice(depth: depth, low: lows.min() ?? centre,
                             high: highs.max() ?? centre)
        }

        /// 沿**光轴**走 `distance` 时的光束宽度。
        ///
        /// 这是物理上正确的量：光锥沿自身轴均匀张开，
        /// 所以宽度 = 2 · tan(半角) · 沿轴距离。
        /// 不要用"同一纵深处两条边界的高度差"代替 —— 光轴倾斜时那个量不等于宽度。
        public func widthAlongAxis(atDistance distance: Double) -> Double {
            let halfAngle = edges[0].angleDegrees - axis.angleDegrees
            return 2 * tan(abs(halfAngle) * .pi / 180) * max(0, distance)
        }

        /// 两条包络线的端点（画图用）。
        public var endpoints: (Vec2, Vec2) {
            (apex + edges[0] * length, apex + edges[1] * length)
        }
    }

    /// 生成光束包络。
    ///
    /// `aim` 的语义与平面图一致（0 = +X = 朝后墙，90 = +Y），
    /// 但在剖面图里 y 是**高度**，所以：
    ///   · aim 90（朝后墙）在剖面上是"朝右、略向下"？
    ///     不 —— 平面图的 +Y 是纵深，剖面图的横轴才是纵深。
    ///     所以 aim 90 → 剖面图上光轴朝 +纵深（水平向右）。
    ///   · 真正的"往下打"由灯位高度与焦点深度共同决定，见 `axisFor`。
    ///
    /// 这里不猜灯具的俯仰角：灯具没有 `tilt` 字段，硬编一个会得到假的照射角。
    /// 所以光轴方向**由几何决定**：从灯口指向焦点。这才是物理上真实发生的事。
    public static func envelope(apex: Vec2,
                               focusDepth: Double,
                               focusHeight: Double,
                               beamAngle: Double,
                               reach: Double) -> BeamEnvelope {
        let target = Vec2(focusDepth, focusHeight)
        let delta = target - apex
        let distance = max(delta.length, 1.0)
        let axis = delta / distance
        let halfAngle = (beamAngle / 2) * .pi / 180
        let edges = [axis.rotated(byDegrees: halfAngle * 180 / .pi),
                     axis.rotated(byDegrees: -halfAngle * 180 / .pi)]
        return BeamEnvelope(apex: apex, axis: axis, edges: edges,
                            length: max(reach, distance))
    }

    // MARK: 遮挡

    /// 一个在剖面上占据矩形区域的不透明物（布景、台口塔、观众席）。
    public struct Blocker: Equatable, Sendable {
        public let rect: Rect
        public let label: String
        public init(_ rect: Rect, _ label: String) {
            self.rect = rect
            self.label = label
        }
    }

    /// 光束被谁挡住了。
    ///
    /// 返回第一段被阻断的纵深范围 —— 读图人最需要知道的是
    /// "光从哪儿开始打不到"，而不是"被几个东西挡了"。
    ///
    /// 判定方式：沿光轴采样，检查该点的横向跨度是否完全落入某个遮挡物内。
    /// 只有**完全**被挡住才算遮挡：部分遮挡会留下边缘光，那是设计的一部分。
    public static func blockage(_ beam: BeamEnvelope,
                                by blockers: [Blocker],
                                samples: Int = 120) -> (depth: Double, label: String)? {
        guard !blockers.isEmpty, samples > 1 else { return nil }
        for i in 1...samples {
            let t = beam.length * Double(i) / Double(samples)
            let centre = beam.apex + beam.axis * t
            guard let slice = beam.slice(atDepth: centre.x) else { continue }
            // 光束在该处的完整竖直跨度
            let span = Rect(x0: centre.x - 1, y0: slice.low,
                            x1: centre.x + 1, y1: slice.high)
            for b in blockers where b.rect.contains(Vec2(centre.x, slice.low))
                && b.rect.contains(Vec2(centre.x, slice.high)) {
                _ = span
                return (centre.x, b.label)
            }
        }
        return nil
    }

    // MARK: 视线

    /// 观众视线检查。
    ///
    /// 这是"更复杂的剖面图"里最实质的一项：**起坡够不够**。
    /// 每排观众的眼睛要能越过前一座观众的头顶看到台口底边。
    ///
    /// 判定用经典公式：眼高 1150mm（坐姿），头顶 1250mm，
    /// 从前排头顶拉一条线到台口底（plaster line 处高度 0），
    /// 该线的斜率就是"该排能看到台面所需的最小抬高"。
    public struct SightLine: Equatable, Sendable {
        public let row: Int
        public let eyeDepth: Double
        public let eyeHeight: Double
        /// 是否看得到台口底边。
        public let seesStageFloor: Bool
        /// 需要的抬高量（mm）。负值表示还差多少。
        public let margin: Double
    }

    public static let seatedEyeHeight: Double = 1150
    public static let seatedHeadHeight: Double = 1250

    /// 计算所有排的视线。
    ///
    /// - Parameters:
    ///   - rowCount: 排数
    ///   - rowDepth: 排距
    ///   - rake: 每排升高
    ///   - firstRowDepth: 第一排所在纵深（负值，在台口外侧）
    ///   - plasterDepth: 台口纵深
    ///   - stageFloor: 台面高度（通常 0）
    public static func sightLines(rowCount: Int,
                                 rowDepth: Double,
                                 rake: Double,
                                 firstRowDepth: Double,
                                 plasterDepth: Double,
                                 stageFloor: Double = 0,
                                 stageEdgeDepth: Double = 0) -> [SightLine] {
        guard rowCount > 0, rowDepth > 0 else { return [] }
        var out: [SightLine] = []
        // 目标点：台口底边（更严的标准是台口最前缘的台面）
        let target = Vec2(stageEdgeDepth, stageFloor)

        for i in 0..<rowCount {
            let depth = firstRowDepth - Double(i) * rowDepth
            // 第 i 排的地面标高（负值 = 下沉，正值 = 起坡抬高）
            let floor = Double(i) * rake
            let eye = floor + seatedEyeHeight

            // 前一排的头顶
            let prevFloor = Double(max(0, i - 1)) * rake
            let prevHead = prevFloor + seatedHeadHeight

            if i == 0 {
                // 第一排没有前排遮挡，只看眼睛能否看到目标
                out.append(SightLine(row: i, eyeDepth: depth, eyeHeight: eye,
                                     seesStageFloor: true, margin: eye))
                continue
            }

            // 从目标点穿过前座头顶的直线，在本排纵深处的高度
            let prevDepth = firstRowDepth - Double(i - 1) * rowDepth
            let dTarget = prevDepth - target.x
            let hTarget = prevHead - target.y
            guard abs(dTarget) > 1e-6 else {
                out.append(SightLine(row: i, eyeDepth: depth, eyeHeight: eye,
                                     seesStageFloor: false, margin: -999))
                continue
            }
            let slope = hTarget / dTarget
            let required = target.y + slope * (depth - target.x)
            let margin = eye - required
            out.append(SightLine(row: i, eyeDepth: depth, eyeHeight: eye,
                                 seesStageFloor: margin >= 0, margin: margin))
        }
        return out
    }
}
