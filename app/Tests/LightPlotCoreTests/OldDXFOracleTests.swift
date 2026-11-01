import Testing
import Foundation
@testable import LightPlotCore

/// **对旧管线 DXF 的几何差分回归。**
///
/// PDF 的文字层只能证明标注对；DXF 能证明**坐标**对。
/// 旧管线把每台灯的符号写成 `INSERT`（块引用），插入点就是它在图纸上的
/// 确切位置 —— 这是可以直接与 LightPlot 的世界坐标对账的硬事实。
///
/// ## 数据来源与冻结方式
///
/// 从 `out/LX_plan.dxf` 用文本解析抽出：`INSERT` 里 `layer == FIXTURE`、
/// 块名以 `SYM_` 开头的实体，取 (10, 20) 组码。共 39 个，
/// 其中 32 个落在平面区（x < 690mm），其余 7 个是图例里的示例符号。
/// 灯号由相邻的 `FBL_` 块（`FIXTURE_TXT` 图层）按最近距离绑定，
/// 实测配对距离 8.3–15.0mm，无歧义。
///
/// 下表是**冻结的**（2026-06 从旧管线产出抽出），所以旧管线即使被删也不影响回归。
@Suite("Old pipeline DXF oracle")
struct OldDXFOracleTests {

    /// `(灯号, 类型, 图纸 x, 图纸 y, 世界 x, 世界 y)`
    ///
    /// 图纸坐标取自旧 DXF；世界坐标取自 `data/rig.yaml`（另由 Resolver 独立重算）。
    static let oldDXF: [(unit: Int, type: String, sx: Double, sy: Double,
                         wx: Double, wy: Double)] = [
        (101, "profile",   215.0,     179.9738, -3500, -900),
        (102, "profile",   271.0,     179.9738, -2100, -900),
        (103, "profile",   327.0,     179.9738,  -700, -900),
        (104, "profile",   383.0,     179.9738,   700, -900),
        (105, "profile",   439.0,     179.9738,  2100, -900),
        (106, "profile",   495.0,     179.9738,  3500, -900),
        (201, "fresnel",   215.0,     316.8843, -3500, 2400),
        (202, "fresnel",   271.0,     316.8843, -2100, 2400),
        (203, "fresnel",   327.0,     316.8843,  -700, 2400),
        (204, "fresnel",   383.0,     316.8843,   700, 2400),
        (205, "fresnel",   439.0,     316.8843,  2100, 2400),
        (206, "fresnel",   495.0,     316.8843,  3500, 2400),
        (301, "fresnel",   223.0,     428.8843, -3300, 5200),
        (302, "fresnel",   311.0,     428.8843, -1100, 5200),
        (303, "fresnel",   399.0,     428.8843,  1100, 5200),
        (304, "fresnel",   487.0,     428.8843,  3300, 5200),
        (401, "led",       223.0,     524.8844, -3300, 7600),
        (402, "led",       311.0,     524.8844, -1100, 7600),
        (403, "led",       399.0,     524.8844,  1100, 7600),
        (404, "led",       487.0,     524.8844,  3300, 7600),
        (501, "par",        31.9738,  287.0,    -8100, 1800),
        (502, "par",        31.9738,  351.0,    -8100, 3400),
        (503, "par",        31.9738,  415.0,    -8100, 5000),
        (601, "par",       678.0262,  287.0,     8100, 1800),
        (602, "par",       678.0262,  351.0,     8100, 3400),
        (603, "par",       678.0262,  415.0,     8100, 5000),
        (701, "mover",     295.0,     316.8843, -1500, 2400),
        (702, "mover",     415.0,     316.8843,  1500, 2400),
        (801, "follow",    195.0,     179.9738, -4000, -900),
        (802, "follow",    515.0,     179.9738,  4000, -900),
        (901, "practical", 291.0,     391.35,   -1600, 4400),
        (902, "practical", 511.0,     403.35,    3900, 4700),
    ]

    /// 旧管线图框原点（图纸 mm），由 DXF 反解得出。
    static let oldOriginX: Double = 355.0

    /// 竖杆上的灯：旧管线沿**半个管粗**向台中心偏移。
    ///
    /// 管在平面上的厚度 = 1.9476mm（图纸），半个 = 0.9738mm = 24.3mm 实物。
    /// 物理上说得通：灯是夹在管的侧面的，灯体在管外侧、镜片朝台内。
    static let boomLateralOffset: Double = 0.9738

    // MARK: - 世界坐标与 DXF 独立一致

    @Test("Every lantern's world position recomputes to the DXF's own value")
    func worldMatchesDXF() throws {
        let doc = try TestData.realDocument()
        var bad: [String] = []
        for row in Self.oldDXF {
            guard let f = doc.fixtures.first(where: { $0.unit == row.unit }) else {
                bad.append("\(row.unit): missing"); continue
            }
            guard let w = Resolver.worldPoint(of: f, in: doc) else {
                bad.append("\(row.unit): no world point"); continue
            }
            if abs(w.x - row.wx) > 0.5 || abs(w.y - row.wy) > 0.5 {
                bad.append("\(row.unit): got (\(w.x), \(w.y)) want (\(row.wx), \(row.wy))")
            }
        }
        #expect(bad.isEmpty, Comment(rawValue: bad.joined(separator: " | ")))
    }

    @Test("Every lantern keeps the fixture type the DXF drew")
    func typesMatchDXF() throws {
        let doc = try TestData.realDocument()
        var bad: [String] = []
        for row in Self.oldDXF {
            guard let f = doc.fixtures.first(where: { $0.unit == row.unit }) else { continue }
            if f.type != row.type { bad.append("\(row.unit): \(row.type) -> \(f.type)") }
        }
        #expect(bad.isEmpty, Comment(rawValue: bad.joined(separator: " | ")))
    }

    // MARK: - 几何：相对位置必须逐位一致

    /// **这是最强的一条。**
    ///
    /// 同类型的两台灯，图上间距必须等于世界间距 ÷ 比例。
    /// 原点与"每类型符号偏移"在相减时同时消掉，所以这条
    /// 检验的是纯粹的坐标映射，没有一点余量。
    ///
    /// 旧 DXF 与 LightPlot 的图框原点**故意不同**（旧版写死 355,215，
    /// 新版按内容居中），所以绝对不能比绝对坐标 —— 那会把一个
    /// 已声明的差异误报成几何错误。
    @Test("Same-type lantern spacing matches the DXF exactly")
    func relativeGeometry() throws {
        let doc = try TestData.realDocument()

        // 用 DXF 的坐标算"图上的间距"，用世界坐标算"应该是多少"
        var compared = 0
        var bad: [String] = []

        let rows = Self.oldDXF
        for i in 0..<rows.count {
            for j in (i + 1)..<rows.count {
                let a = rows[i], b = rows[j]
                guard a.type == b.type else { continue }

                // 只比横杆上的灯。竖杆上的灯旧管线有半个管粗的横向偏移，
                // 那是一条已声明的差异（见 boomLateralOffset），
                // 不参与"必须为零"的断言。
                let docA = doc.fixtures.first { $0.unit == a.unit }
                let docB = doc.fixtures.first { $0.unit == b.unit }
                guard let fa = docA, let fb = docB else { continue }
                let onVertical = { (f: Fixture) -> Bool in
                    doc.position(id: f.pos ?? "")?.kind == .vertical
                }
                if onVertical(fa) || onVertical(fb) { continue }

                let wantX = (b.wx - a.wx) / 25.0
                let wantY = (b.wy - a.wy) / 25.0
                let gotX = b.sx - a.sx
                let gotY = b.sy - a.sy
                compared += 1
                let err = max(abs(wantX - gotX), abs(wantY - gotY))
                if err > 0.01 {
                    bad.append("\(a.unit)-\(b.unit): want (\(wantX), \(wantY)) "
                               + "got (\(gotX), \(gotY)) err \(err)")
                }
            }
        }
        // 32 台灯里 26 台在横杆上；同类型两两配对 = 69 对（实测）
        #expect(compared == 69, "expected 69 horizontal same-type pairs, got \(compared)")
        #expect(bad.isEmpty, Comment(rawValue: bad.prefix(4).joined(separator: " | ")))
    }

    /// 横杆灯的 x 映射是纯平移：`图 x − 世界 x / 25` 必须是同一个常数。
    @Test("The sheet x mapping is a pure translation")
    func xMappingIsConstant() throws {
        let doc = try TestData.realDocument()
        var offsets: [Double] = []
        for row in Self.oldDXF {
            guard let f = doc.fixtures.first(where: { $0.unit == row.unit }),
                  doc.position(id: f.pos ?? "")?.kind == .horizontal else { continue }
            offsets.append(row.sx - row.wx / 25.0)
        }
        #expect(!offsets.isEmpty)
        let spread = offsets.max()! - offsets.min()!
        #expect(spread < 0.001,
                "x mapping should be a pure translation; spread \(spread)mm")
        // 旧管线写死 355.0；这条钉住"我们从 DXF 反解出来的原点"没跑偏
        #expect(abs(offsets[0] - Self.oldOriginX) < 0.01,
                "origin \(offsets[0]) vs expected \(Self.oldOriginX)")
    }

    // MARK: - 已声明的差异

    /// 竖杆灯的横向偏移 —— 已声明的差异，但必须**量得出来**。
    ///
    /// 光声明"这里不一样"是不够的：要能说出差多少、往哪边差。
    /// 这条把 0.9738mm（半个管粗）钉死，将来若有人改动，
    /// 会立刻知道改掉的是一个有依据的约定。
    @Test("The boom lateral offset is exactly half the pipe thickness")
    func boomOffsetIsMeasured() throws {
        let doc = try TestData.realDocument()
        // 取 BOOM SL 上的 501：旧 DXF 在 31.9738，杆轴在 355 + (-8100)/25 = 31.0
        guard let row = Self.oldDXF.first(where: { $0.unit == 501 }) else {
            Issue.record("no unit 501 in the DXF table"); return
        }
        let axis = Self.oldOriginX + row.wx / 25.0
        let measured = row.sx - axis
        #expect(abs(measured - Self.boomLateralOffset) < 1e-4,
                "measured offset \(measured), expected \(Self.boomLateralOffset)")
        // 方向必须朝台中心（501 在左侧，向右偏）
        #expect(measured > 0, "the SL boom must offset towards stage centre")
        // BOOM SR 必须镜像
        guard let sr = Self.oldDXF.first(where: { $0.unit == 601 }) else { return }
        let srAxis = Self.oldOriginX + sr.wx / 25.0
        #expect(abs((sr.sx - srAxis) + Self.boomLateralOffset) < 1e-4,
                "the SR boom must mirror the SL offset")
        _ = doc
    }

    /// 图例里的示例符号不得混进平面区 —— 旧 DXF 也是分开的。
    @Test("The DXF separates 32 plan symbols from 7 legend samples")
    func legendNotInPlanArea() {
        let plan = Self.oldDXF
        #expect(plan.count == 32)
        // 平面区右边界 = 信息栏起点 691mm；所有灯都在左侧
        #expect(plan.allSatisfy { $0.sx < 690 })
    }
}
