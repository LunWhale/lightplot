import Foundation
import Testing
@testable import LightPlotCore

/// 测试数据工厂。
///
/// 两条纪律：
///  1. `validDocument()` 必须能产出**零问题**文档 —— 它是所有故障注入的基线。
///     基线本身有问题，后面的断言就全部失去意义。
///  2. `realDocument()` 读仓库里**真实**的 `data/rig.yaml`。
///     用它做回归，才能保证"应用读得懂旧项目"，而不是读得懂我编的样例。
enum TestData {

    /// 工作区根目录（由本文件位置反推，避免依赖当前工作目录）。
    static let workspaceRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // LightPlotCoreTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // app/
        .deletingLastPathComponent()   // 工作区根

    static var rigYAML: URL { workspaceRoot.appendingPathComponent("data/rig.yaml") }

    static func realDocument() throws -> LXDocument {
        let data = try Data(contentsOf: rigYAML)
        return try DocumentCodec.decodeYAML(data)
    }

    /// 一份完整、无问题的文档。三个构件覆盖三种类型（truss / pipe / line），
    /// 三盏灯覆盖三种挂载方式（沿水平杆 / 沿竖直杆 / 自由摆放）。
    static func validDocument() -> LXDocument {
        var doc = LXDocument()
        doc.meta = .init(profile: "study",
                         show: "TEST SHOW",
                         playwright: "A PLAYWRIGHT",
                         venue: "TEST VENUE",
                         sheetTitle: "LX PLAN",
                         scale: 25,
                         date: "01/01/2026",
                         revision: "V1",
                         revNote: "FIRST ISSUE",
                         director: "A DIRECTOR",
                         designer: "A DESIGNER")
        doc.stage = .init(width: 15000, depth: 9000, datum: 0, gridHeight: 8000,
                          prosceniumHeight: 6500, prosceniumX: -1200,
                          audienceRows: 7, audienceRowDepth: 560, audienceRake: 160)
        doc.positions = [
            Position(id: "LX 1", kind: .horizontal, type: .truss,
                     x0: -7500, x1: 7500, y: 2400, trim: 6500),
            Position(id: "BOOM SL", kind: .vertical, type: .pipe,
                     x: -8100, y0: 900, y1: 7200, trim: 3600),
            // 非吊挂的地面布景线。trim=0 是对的，不得产生"trim 偏低"警告。
            Position(id: "SET EDGE", kind: .horizontal, type: .line,
                     x0: -6500, x1: 6500, y: 1500, trim: 0),
        ]
        doc.fixtures = [
            Fixture(unit: 101, pos: "LX 1", x: -3500, type: "profile", aim: 90,
                    gel: "L201", ch: 1, purpose: "FACE F1", beam: 26),
            Fixture(unit: 501, pos: "BOOM SL", y: 1800, type: "par", aim: 0,
                    gel: "L119", ch: 41, purpose: "SIDE SL", beam: 25),
            Fixture(unit: 901, pos: "SET EDGE", x: -1600, y: 4400, type: "practical",
                    aim: 90, gel: "OPEN", ch: 91, purpose: "FRIDGE", beam: 60, trim: 0),
        ]
        doc.gels = [
            Gel(code: "L201", name: "Lee 201 Full CT Blue", purpose: "FRONT", rgb: 0x2E4E8F),
            Gel(code: "L119", name: "Lee 119 Dark Blue", purpose: "SIDE", rgb: 0x1F3F8F),
            Gel(code: "OPEN", name: "No colour", purpose: "PRACTICAL"),
        ]
        doc.types = [
            "profile": .init(label: "Profile / ERS 750W", watt: 750, role: "FACE"),
            "par": .init(label: "PAR 500W", watt: 500, role: "SIDE LIGHT"),
            "practical": .init(label: "Practical", watt: 0, role: "PRACTICAL"),
        ]
        doc.zones = [Zone(id: "K1", x0: -7600, y0: 3600, x1: -1300, y1: 8700)]
        return doc
    }

    /// 摘要里"变化的行"。用于断言"改一个字段只影响一行"。
    static func changedLines(_ a: String, _ b: String) -> [String] {
        let la = a.split(separator: "\n", omittingEmptySubsequences: false)
        let lb = b.split(separator: "\n", omittingEmptySubsequences: false)
        var out: [String] = []
        for i in 0..<max(la.count, lb.count) {
            let x = i < la.count ? String(la[i]) : "<missing>"
            let y = i < lb.count ? String(lb[i]) : "<missing>"
            if x != y { out.append("\(x)  ->  \(y)") }
        }
        return out
    }
}
