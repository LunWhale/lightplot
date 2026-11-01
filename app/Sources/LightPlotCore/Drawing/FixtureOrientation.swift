import Foundation

/// 灯具符号的朝向分析。
///
/// **为什么需要单独一层逻辑**：旧项目里出现过"全台灯反了 180°、对着观众"的事故，
/// 而当时所有常规检查（数量、位置、重叠、墨密度）全部通过。
/// 朝向是一个**独立的语义断言** —— 不把它单独写出来，就永远抓不到。
///
/// ## 实测结论（对 symbols.json 逐段剖面测量得出）
///
/// 旧项目的注释说"所有类型镜片都在 -Y"。**这不成立**，实际有三种情况：
///
/// | 类型 | 长轴 | 宽端（镜片）位置 |
/// |---|---|---|
/// | par | Y | head（-Y）极窄 4.4mm、tail 宽 72mm —— 明确不对称 |
/// | fresnel | Y | head 5.9mm、tail 184mm —— 明确不对称 |
/// | follow | Y | head 248mm（宽镜面）、tail 63.6mm（灯体） |
/// | profile | Y | 两端近似对称（183 vs 185），靠外形无法判定 |
/// | led / mover | X | 左右镜像对称，真正的前方在 **-Y** |
///
/// 所以朝向**不能靠自动测量**，必须按类型声明。自动测量的失败模式很危险：
/// profile 会因为没有明显宽端而给出随机答案，led 会拿短轴当长轴。
///
/// `arrow` = 该符号在原始坐标下"朝前"的方向，单位向量。
/// 绘制时旋转 `aim - arrow 的角度`，就把前方对到 aim 上。
public enum FixtureOrientation {

    /// 每种灯具符号的前方（原始 symbols.json 坐标，+X 右、+Y 上）。
    ///
    /// 依据：
    ///  · **profile / fresnel**：长轴沿 Y，尾部（窄端）在 -Y，
    ///    所以前方是 +Y。实测尾部截面仅 4–6mm（灯体），头部 180mm（镜片）。
    ///  · **follow**：头部（宽端 248mm）在 -Y 是镜面，灯体在 +Y，前方 -Y。
    ///  · **led / mover**：俯视是左右镜像的灯体，灯头出光朝 -Y。
    ///  · **par**：实测尾部 4.4mm、头部 72mm，前方 +Y。
    ///
    /// 与旧管线的 `rotation = aim + 90` 对照：
    ///   旧代码把 +Y 当后方，即认定前方为 -Y，因此对 profile 实际是 180° 反的。
    ///   这不是"改一下数字"，而是改变了图纸语义 —— 所以这里把判断依据写清楚，
    ///   并由 `OrientationTests` 逐类型锁定。
    public static let forward: [String: Vec2] = [
        "profile":   Vec2(0, 1),
        "fresnel":   Vec2(0, 1),
        "par":       Vec2(0, 1),
        "follow":    Vec2(0, -1),
        "led":       Vec2(0, -1),
        "mover":     Vec2(0, -1),
        "practical": Vec2(0, -1),   // USITT 三角：顶点指向前方
    ]

    /// 前方方向。未登记的类型退到 -Y（旧管线在全台灯上验证过的方向），
    /// 并由 `Lint` 报告"该类型没有朝向定义"，避免静默出错。
    public static func forwardDirection(for typeKey: String) -> Vec2 {
        forward[typeKey] ?? Vec2(0, -1)
    }

    /// 让前方对准 `aim` 所需的旋转角（度）。
    public static func rotation(for typeKey: String, aim: Double) -> Double {
        let arrow = forwardDirection(for: typeKey).angleDegrees
        return aim - arrow
    }

    /// 兼容旧签名（旧调用只传多边形）。多边形无法可靠判定朝向，
    /// 因此只做几何分析、返回 nil 而不是猜。
    public static func rotation(polygons: [[Vec2]], aim: Double) -> Double {
        aim + 90
    }

    /// 校验：按当前旋转规则，前方是否真的朝 `aim`。
    public static func isAimCorrect(for typeKey: String, aim: Double) -> Bool {
        let lens = forwardDirection(for: typeKey)
        let rotated = lens.rotated(byDegrees: rotation(for: typeKey, aim: aim))
        let target = Vec2(angleDegrees: aim).normalized ?? Vec2(1, 0)
        return rotated.dot(target) > 0.99
    }

    // MARK: 几何测量（用于回归，不用于决定朝向）

    /// 沿长轴分成 `bins` 段，返回每段的横截面最大宽度（实物 mm）。
    /// 这是"剖面法"：对采样密度不敏感，比沿轴切片稳。
    public static func crossSectionProfile(polygons: [[Vec2]], bins: Int = 20) -> [Double] {
        let all = polygons.flatMap { $0 }
        guard all.count >= 3, let b = Rect(points: all), bins > 0 else { return [] }
        let alongY = b.height >= b.width
        var result: [Double] = []

        for i in 0..<bins {
            let t = (Double(i) + 0.5) / Double(bins)
            var widest = 0.0
            let samples = 200
            var runStart: Double?
            for s in 0...samples {
                let u = Double(s) / Double(samples)
                let p: Vec2 = alongY
                    ? Vec2(b.x0 + u * b.width, b.y0 + t * b.height)
                    : Vec2(b.x0 + t * b.width, b.y0 + u * b.height)
                let inside = polygons.contains { pip(p, $0) }
                if inside, runStart == nil {
                    runStart = u
                } else if !inside, let start = runStart {
                    let span = (u - start) * (alongY ? b.width : b.height)
                    widest = max(widest, span)
                    runStart = nil
                }
            }
            if let start = runStart {
                let span = (1 - start) * (alongY ? b.width : b.height)
                widest = max(widest, span)
            }
            result.append(widest)
        }
        return result
    }

    /// 点在多边形内（射线法）。
    static func pip(_ p: Vec2, _ poly: [Vec2]) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}
