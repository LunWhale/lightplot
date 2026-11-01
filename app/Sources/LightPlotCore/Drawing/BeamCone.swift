import Foundation

/// 光束锥（平面图上的方向提示）。
///
/// **只画"朝哪里"，不画"照到多亮"。**
/// 这是刻意的边界：真正的照度计算需要灯具光度曲线、悬挂高度、遮挡物，
/// 而那些数据在图纸上既没有也无关。画一个好看的假光斑比不画更糟 ——
/// 它会让人以为那是有依据的。
///
/// 所以这里只做一件事：从灯位出发，沿 aim 方向画一个与 `beam` 角同宽的
/// 虚线锥。它回答的是"这盏灯对着哪儿"，正是读图人需要的。
public enum BeamCone {

    /// 光束锥的默认长度（图纸 mm）。
    ///
    /// 18mm 在 1:25 下约等于 450mm 实物。这个长度是反复试出来的：
    ///   · 太短（<12mm）整条锥埋在桁架白底里，根本看不见
    ///     —— 桁架截面在图上就有 12mm 厚，灯又挂在桁架中心线上
    ///   · 太长（>30mm）在密集处会糊成一片灰，盖住布景与光区框
    public static let defaultLengthPaper: Double = 18.0

    /// 锥的起点从符号外缘起算，而不是从灯位中心。
    /// 否则锥的前 1/3 会被灯具符号自己的白底遮住。
    public static let startOffsetPaper: Double = 4.5

    /// 生成一个光束锥的边线（两条线，不封口）。
    ///
    /// - Parameters:
    ///   - apex: 灯位（图纸 mm）
    ///   - aim: 出光方向（度）
    ///   - beam: 光束角（度）。缺省用 25°。
    ///   - length: 锥长（图纸 mm）
    public static func edges(apex: Vec2, aim: Double, beam: Double?,
                             length: Double = defaultLengthPaper) -> [Vec2] {
        let halfAngle = (beam ?? 25) / 2
        guard halfAngle > 0.1, length > 0.1 else { return [] }
        let left = apex + Vec2(angleDegrees: aim - halfAngle, length: length)
        let right = apex + Vec2(angleDegrees: aim + halfAngle, length: length)
        return [left, right]
    }

    /// 锥的形状（用于画一条细虚线折线：apex → 左 → 右 → apex）。
    /// 不填充 —— 填充会盖住底下的桁架与灯具。
    public static func outline(apex: Vec2, aim: Double, beam: Double?,
                               length: Double = defaultLengthPaper) -> [Vec2] {
        let e = edges(apex: apex, aim: aim, beam: beam, length: length)
        guard e.count == 2 else { return [] }
        return e
    }
}

extension PlanCanvas {

    /// 画所有灯具的光束锥。
    ///
    /// 放在 FIXTURE 之前、TRUSS 之后：锥压在白底桁架上，
    /// 但会被灯具符号的白底盖住，于是"从灯口射出"的观感自然成立。
    mutating func drawBeamCones() {
        for (fixture, mount) in Resolver.allMounts(in: doc) {
            guard let world = mount.worldPoint else { continue }
            let origin = s(world)
            let aim = fixture.aim ?? 90
            let start = origin + Vec2(angleDegrees: aim, length: BeamCone.startOffsetPaper)
            let edges = BeamCone.edges(apex: start, aim: aim, beam: fixture.beam)
            guard edges.count == 2 else { continue }
            // 用虚线，避免和实体线混淆
            line(start, edges[0], "BEAM", dash: [1.6, 1.4])
            line(start, edges[1], "BEAM", dash: [1.6, 1.4])
        }
    }
}
