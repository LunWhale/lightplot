import Testing
import Foundation
@testable import LightPlotCore
@testable import LightPlotUI

/// 极端数据：空文档、一台灯、超大场地、极扁/极瘦舞台。
///
/// 这些不是"用户会这么做"，而是**程序的边界**。
/// 边界上崩溃或画出无意义的图，都会让用户失去信任 ——
/// 而且平时用正常数据永远发现不了。
@Suite("Extreme data")
struct ExtremeDataTests {

    private func base() -> LXDocument {
        var doc = LXDocument()
        doc.meta = .init(profile: "study", show: "EDGE", scale: 25,
                         date: "01/01/2027", revision: "V1", revNote: "X")
        doc.stage = .init(width: 12000, depth: 9000, datum: 0,
                          gridHeight: 7000, prosceniumHeight: 5500,
                          prosceniumX: -1000, audienceRows: 5,
                          audienceRowDepth: 550, audienceRake: 300)
        doc.types = ["profile": .init(label: "Profile / ERS 750W", watt: 750)]
        doc.gels = [Gel(code: "L201", name: "Lee 201  Full CT Blue"),
                    Gel(code: "OPEN", name: "No colour")]
        return doc
    }

    private func texts(_ ops: [DrawOp]) -> [String] {
        ops.compactMap { op -> String? in
            if case .text(let t) = op { return t.string }
            return nil
        }
    }

    // MARK: 空

    @Test("A document with nothing in it still renders a valid sheet")
    func emptyDocument() {
        var doc = base()
        doc.positions = []
        doc.fixtures = []
        doc.zones = []
        doc.setPieces = []

        let plan = PlanSheet(fitting: doc)
        #expect(plan.contentFitsSheet)
        #expect(plan.ops.count > 50, "a sheet should still have a border and a title block")

        let t = texts(plan.ops)
        #expect(t.contains("EDGE"), "the title block must still print")
        #expect(t.contains("FIXTURES"), "the legend heading must still print")

        let section = SectionSheet(fitting: doc)
        #expect(section.ops.count > 50)
    }

    @Test("Every stage size from zero to absurd renders without crashing")
    func stageSizes() {
        for (w, d) in [(1.0, 1.0), (100, 100), (30000, 20000), (60000, 1000), (1000, 60000)] {
            var doc = base()
            doc.stage.width = w
            doc.stage.depth = d
            doc.positions = [Position(id: "LX 1", kind: .horizontal, type: .truss,
                                      x0: -w / 2, x1: w / 2, y: d / 2, trim: 7000)]
            doc.fixtures = [Fixture(unit: 101, pos: "LX 1", x: 0, type: "profile",
                                    aim: 90, gel: "L201", ch: 1,
                                    purpose: "X", beam: 26)]
            let label = "\(Int(w))x\(Int(d))"
            let plan = PlanSheet(fitting: doc)
            // 要么装得下并画出内容，要么装不下并给提示页 —— 不能是空的
            #expect(!plan.ops.isEmpty, Comment(rawValue: label))
            if plan.contentFitsSheet {
                #expect(texts(plan.ops).contains("101"),
                        Comment(rawValue: "\(label): the lantern is missing"))
            } else {
                #expect(texts(plan.ops).contains { $0.contains("DOES NOT FIT") },
                        Comment(rawValue: "\(label): overflowed silently"))
            }
        }
    }

    // MARK: 一台灯

    @Test("A single lantern on a single bar is fully annotated")
    func singleLantern() {
        var doc = base()
        doc.positions = [Position(id: "LX 1", kind: .horizontal, type: .truss,
                                  x0: -6000, x1: 6000, y: 4500, trim: 7000)]
        doc.fixtures = [Fixture(unit: 101, pos: "LX 1", x: 0, type: "profile",
                                aim: 90, gel: "L201", ch: 7, purpose: "FACE",
                                beam: 26)]
        let plan = PlanSheet(fitting: doc)
        let t = texts(plan.ops)
        #expect(t.contains("101"), "unit number")
        #expect(t.contains("L201"), "gel code")
        #expect(t.contains("7"), "channel")
        #expect(t.contains("LX 1"), "bar name")
        #expect(t.contains("+7000"), "trim")
        #expect(plan.textFit.totalDropped == 0)
    }

    // MARK: 极端灯数

    @Test("One hundred lanterns do not crash any renderer")
    func manyLanterns() {
        var doc = base()
        doc.positions = (1...10).map { i in
            Position(id: "LX \(i)", kind: .horizontal, type: .truss,
                     x0: -6000, x1: 6000,
                     y: 500 + Double(i) * 800, trim: 7000)
        }
        doc.fixtures = (0..<100).map { i in
            Fixture(unit: 101 + i, pos: "LX \(1 + i % 10)",
                    x: -5600 + Double(i / 10) * 1200,
                    type: "profile", aim: 90, gel: "L201", ch: 1 + i,
                    purpose: "P\(i)", beam: 26)
        }
        // A0 @ 1:50 都装不下 100 台灯的可读标注 —— 允许丢标注，但不许崩
        let plan = PlanSheet(fitting: doc, paper: .a0, scale: 50, lightingState: nil)
        #expect(!plan.ops.isEmpty)
        _ = SectionSheet(fitting: doc, paper: .a0, scale: 50, lightingState: nil)
    }

    // MARK: 缺失/怪异字段

    @Test("A lantern without a channel or aim still draws")
    func sparseLantern() {
        var doc = base()
        doc.positions = [Position(id: "LX 1", kind: .horizontal, type: .truss,
                                  x0: -6000, x1: 6000, y: 4500, trim: 7000)]
        doc.fixtures = [Fixture(unit: 101, pos: "LX 1", x: 0, type: "profile",
                                aim: nil, gel: nil, ch: nil, purpose: nil,
                                beam: nil)]
        let plan = PlanSheet(fitting: doc)
        #expect(texts(plan.ops).contains("101"))
        // 缺省时按制图惯例补：aim 90、色片 OPEN
        #expect(texts(plan.ops).contains("OPEN"))
    }

    @Test("A lantern on a position that does not exist is caught by lint, not by a crash")
    func orphanLantern() {
        var doc = base()
        doc.positions = [Position(id: "LX 1", kind: .horizontal, type: .truss,
                                  x0: -6000, x1: 6000, y: 4500, trim: 7000)]
        doc.fixtures = [Fixture(unit: 101, pos: "NOWHERE", x: 0, type: "profile",
                                aim: 90, gel: "L201", ch: 1, purpose: "X",
                                beam: 26)]
        let codes = Set(Lint.check(doc).map(\.code))
        #expect(codes.contains(.fixtureUnknownPosition),
                "lint must name the problem: \(codes)")
        // 即使数据有错，出图也不能崩
        _ = PlanSheet(fitting: doc)
    }

    // MARK: 纸张与比例的极端组合

    @Test("Every paper from A0 to A4 renders something usable or says why not")
    func paperRange() {
        var doc = base()
        doc.positions = [Position(id: "LX 1", kind: .horizontal, type: .truss,
                                  x0: -6000, x1: 6000, y: 4500, trim: 7000)]
        doc.fixtures = [Fixture(unit: 101, pos: "LX 1", x: 0, type: "profile",
                                aim: 90, gel: "L201", ch: 1, purpose: "X",
                                beam: 26)]
        for paper in PaperSize.all {
            for scale in [200.0, 100, 50, 25, 10, 5] {
                let plan = PlanSheet(fitting: doc, paper: paper, scale: scale,
                                     lightingState: nil)
                let label = "\(paper.name)@1:\(Int(scale))"
                if plan.contentFitsSheet {
                    #expect(!plan.ops.isEmpty, Comment(rawValue: label))
                    let t = texts(plan.ops)
                    // 比例行必须与现实一致
                    #expect(t.contains { $0.contains("1:\(Int(scale))") },
                            Comment(rawValue: "\(label): no honest scale line"))
                } else {
                    #expect(texts(plan.ops).contains { $0.contains("DOES NOT FIT") },
                            Comment(rawValue: "\(label): silent overflow"))
                }
            }
        }
    }

    /// 非法的比例不能被静默接受。
    @Test("A nonsensical scale is rejected rather than producing garbage")
    func badScale() {
        var doc = base()
        doc.positions = [Position(id: "LX 1", kind: .horizontal, type: .truss,
                                  x0: -6000, x1: 6000, y: 4500, trim: 7000)]
        doc.fixtures = []
        for scale in [0.0, -25.0] {
            let layout = SheetLayout.fitted(to: doc.contentBounds, paper: .a1,
                                            scaleDenominator: scale)
            // 绝不产生 NaN / inf 坐标
            #expect(layout.isValid, "scale \(scale) produced an invalid layout")
        }
    }

    // MARK: 应用层

    @MainActor
    @Test("The app opens an empty document without crashing")
    func appOpensEmpty() throws {
        var doc = base()
        doc.positions = []
        doc.fixtures = []
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("empty.yaml")
        try DocumentCodec.encodeYAML(doc).write(to: url, atomically: true, encoding: .utf8)

        let model = EditorModel()
        try model.open(url: url)
        #expect(model.state.doc.fixtures.isEmpty)
        let pdf = dir.appendingPathComponent("p.pdf")
        #expect(model.exportPDF(to: pdf) != nil)
    }
}
