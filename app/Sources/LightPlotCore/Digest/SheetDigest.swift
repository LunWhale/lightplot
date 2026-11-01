import Foundation

/// 图纸数字摘要。
///
/// **为什么需要它**：这是整套自检体系的核心产物。
///
/// GUI 的"看起来对"不可靠，图像对比也不可靠（空白对空白 = 完美相似，
/// 旧项目在这个坑里栽过）。而一份**人也能读、机器也能 diff** 的纯文本摘要：
///
///   · 每一行都是一个可解释的断言
///   · 数据不变它就不变（`cmp` 级别）
///   · 数据一变，差异立刻定位到具体对象
///
/// 所有数值量化到 0.001，所有列表按稳定键排序，**不含时间戳与随机数**。
public enum SheetDigest {

    public static let version = "v1"

    public static func render(_ doc: LXDocument,
                              layout: SheetLayout,
                              text: TextMeasuring = FontLibrary.regular,
                              includeLint: Bool = true) -> String {
        var lines: [String] = []
        func line(_ key: String, _ value: String) {
            lines.append(key.padding(toLength: 13, withPad: " ", startingAt: 0) + " " + value)
        }

        line("#", "LightPlot sheet digest \(version)")

        // 文档
        line("document", doc.meta.show)
        line("meta", [
            "profile=\(doc.meta.profile)",
            "venue=\(doc.meta.venue)",
            "scale=1:\(f(doc.meta.scale, 0))",
            "rev=\(doc.meta.revision)",
            "date=\(doc.meta.date)",
        ].joined(separator: "  "))
        line("titleblock", [
            "director=\(doc.meta.director)",
            "designer=\(doc.meta.designer)",
            "sheet_no=\(doc.meta.sheetNo)/\(doc.meta.sheetOf)",
        ].joined(separator: "  "))

        // 字体 —— 度量变了所有文字定位都变，因此必须进摘要
        line("font", "face=\(text.fontIdentifier)  cap_to_em=\(f(text.capToEm, 4))")

        // 图纸
        let outer = layout.outerFrame
        let inner = layout.innerFrame
        line("paper", "\(f(layout.paper.widthMM)) x \(f(layout.paper.heightMM))  scale 1:\(f(layout.scaleDenominator, 0))")
        line("frame.outer", "\(f(outer.x0)),\(f(outer.y0)) -> \(f(outer.x1)),\(f(outer.y1))")
        line("frame.inner", "\(f(inner.x0)),\(f(inner.y0)) -> \(f(inner.x1)),\(f(inner.y1))")
        line("origin", "doc 0,0 at sheet \(f(layout.originOnSheet.x)),\(f(layout.originOnSheet.y))")

        // 场地
        let sb = doc.stageBounds
        line("stage", "w=\(f(doc.stage.width)) d=\(f(doc.stage.depth)) grid=\(f(doc.stage.gridHeight))")
        line("stage.bounds", "\(f(sb.x0)),\(f(sb.y0)) -> \(f(sb.x1)),\(f(sb.y1))")

        // 构件
        for p in doc.positions.sorted(by: { $0.id < $1.id }) {
            guard let shape = p.shape else {
                line("position", "\(p.id)  INVALID SHAPE")
                continue
            }
            let spanDoc = shape.length
            let spanSheet = layout.sheetLength(spanDoc)
            let cells = max(1, Int((shape.length / Paper.TrussSpec.pitchMM).rounded(.up)))
            let expect = max(1, Int((spanSheet / Paper.TrussSpec.pitchOnSheet(scale: layout.scaleDenominator)).rounded()))
            line("position", [
                p.id,
                "type=\(p.type.rawValue)",
                "kind=\(p.kind.rawValue)",
                // 端点坐标必须进摘要：构件上下左右移动时，
                // 如果摘要不变，回归就看不见这个改动 —— 这是一个曾经真存在的盲区。
                "at=\(f(shape.start.x)),\(f(shape.start.y))->\(f(shape.end.x)),\(f(shape.end.y))",
                "span=\(f(spanSheet))",
                "cells=\(cells)",
                "expect=\(expect)",
                "trim=\(p.trim.map { f($0, 0) } ?? "-")",
                "sect=\(f(p.halfHeightOnSheet(scale: layout.scaleDenominator) * 2))",
            ].joined(separator: "  "))
        }

        // 灯具
        for (fixture, mount) in Resolver.allMounts(in: doc) {
            var parts: [String] = ["\(fixture.unit)"]
            parts.append("pos=\(fixture.pos ?? "-")")
            parts.append("type=\(fixture.type)")
            switch mount {
            case .onPosition(let id, let axis, let shape):
                let p = mount.worldPoint ?? .zero
                parts.append("on=\(id)")
                parts.append("axis=\(f(axis))")
                parts.append("offset=\(f(mount.offsetFromStart ?? 0))")
                parts.append("world=\(f(p.x)),\(f(p.y))")
                parts.append("onbar=\(Resolver.isOnPosition(mount) ? 1 : 0)")
                _ = shape
            case .free(let p):
                parts.append("free")
                parts.append("world=\(f(p.x)),\(f(p.y))")
            case .unresolved(let code):
                parts.append("UNRESOLVED")
                parts.append("code=\(code.rawValue)")
            }
            if let aim = fixture.aim {
                let d = Vec2(angleDegrees: aim)
                parts.append("aim=\(f(aim, 1))")
                parts.append("dir=\(f(d.x, 2)),\(f(d.y, 2))")
            } else {
                parts.append("aim=-")
            }
            parts.append("gel=\(fixture.gelCode)")
            parts.append("ch=\(fixture.ch.map { String($0) } ?? "-")")
            parts.append("beam=\(fixture.beam.map { f($0, 1) } ?? "-")")
            line("fixture", parts.joined(separator: "  "))
        }

        // 光区
        for z in doc.zones.sorted(by: { $0.id < $1.id }) {
            let r = z.rect
            line("zone", "\(z.id)  \(f(r.width)) x \(f(r.height))  at \(f(r.x0)),\(f(r.y0))")
        }

        // 布景
        for s in doc.setPieces {
            let r = s.rect
            var parts = [s.kind.rawValue, "\(f(r.width))x\(f(r.height))", "at \(f(r.x0)),\(f(r.y0))"]
            if let label = s.label, !label.isEmpty { parts.append("label=\(label)") }
            if s.dashed == true { parts.append("dashed") }
            if let steps = s.steps { parts.append("steps=\(steps)") }
            line("set", parts.joined(separator: "  "))
        }

        // 色片
        for g in doc.gels.sorted(by: { $0.code < $1.code }) {
            let rgb = g.rgb.map { String(format: "#%06X", $0) } ?? "none"
            line("gel", "\(g.code)  rgb=\(rgb)  \(g.name)")
        }

        // 计数
        line("counts", [
            "positions=\(doc.positions.count)",
            "fixtures=\(doc.fixtures.count)",
            "zones=\(doc.zones.count)",
            "set=\(doc.setPieces.count)",
            "gels=\(doc.gels.count)",
            "types=\(doc.types.count)",
        ].joined(separator: "  "))

        // 校验摘要
        if includeLint {
            let issues = Lint.check(doc)
            let errors = issues.filter { $0.severity == .error }.count
            let warnings = issues.filter { $0.severity == .warning }.count
            line("lint", "error=\(errors)  warning=\(warnings)")
            for issue in issues {
                let sev = issue.severity.rawValue.lowercased()
                line("lint.\(sev)", "\(issue.code.rawValue)  \(issue.subject)  \(issue.message)")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// 定点格式化。
    ///
    /// 用 `String(format:)` 而不是默认的 Double 描述，因为后者会随
    /// 值的量级在 "1e-05" 与 "0.00001" 之间切换，导致 diff 噪声。
    static func f(_ v: Double, _ places: Int = 3) -> String {
        guard v.isFinite else { return "nan" }
        let x = abs(v) < 5e-7 ? 0 : v     // 消除 -0.000
        return String(format: "%.\(places)f", x)
    }
}
