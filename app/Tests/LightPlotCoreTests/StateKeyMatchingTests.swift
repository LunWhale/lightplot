import Testing
import Foundation
@testable import LightPlotCore
@testable import LightPlotUI

/// 场景强度键与构件名的匹配。
///
/// **这是最危险的一类 bug：它让整个功能静默失效。**
///
/// `scenes.yaml` 用短键（`FOH` / `LX1`），
/// 而 `rig.yaml` 的构件名是 `FOH LX` / `LX 1`。
/// 直接 `levels[id]` 会全部查不到 → 一律 `defaultLevel = 0` → **整个场景全黑**。
///
/// 而旧管线的 `levels` 字段从来没人读，所以这个错配一直没暴露。
@Suite("Scene key matching")
struct StateKeyMatchingTests {

    private func scenes() throws -> LightingStateSet {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("data/scenes.yaml")
        return try LightingStateCodec.decodeYAML(Data(contentsOf: url))
    }

    private func doc() throws -> LXDocument { try TestData.realDocument() }

    @Test("Short scene keys match the document's longer position names")
    func shortKeysMatch() throws {
        let set = try scenes()
        let kitchen = set.state(id: "kitchen")!
        let d = try doc()

        // 文档里的名字
        let ids = Set(d.positions.map(\.id))
        #expect(ids.contains("FOH LX"))
        #expect(ids.contains("LX 1"))

        // scenes.yaml 里写的是 "FOH" / "LX1"
        #expect(kitchen.levels["FOH"] != nil)
        #expect(kitchen.levels["FOH LX"] == nil)

        // 查文档里的名字必须能拿到值
        #expect(kitchen.level(forPosition: "FOH LX") == 45)
        #expect(kitchen.level(forPosition: "LX 1") == 30)
        #expect(kitchen.level(forPosition: "LX 2") == 0)
        #expect(kitchen.level(forPosition: "BOOM SL") == 60)
    }

    /// 若这条坏了，整个场景会静默变成全黑 —— 而看起来一切正常。
    @Test("No scene silently becomes all-dark")
    func notAllDark() throws {
        let set = try scenes()
        let d = try doc()
        for state in set.states {
            let lit = state.litCount(in: d)
            #expect(lit > 0,
                    "\(state.id): every lantern resolves to 0% — the key matching is broken")
        }
    }

    @Test("Exact keys still win over fuzzy matching")
    func exactWins() throws {
        let st = LightingState(id: "t", name: "T",
                               levels: ["LX 1": 80, "LX1": 20])
        // 精确命中 "LX 1"
        #expect(st.level(forPosition: "LX 1") == 80)
    }

    /// 多个模糊匹配说明数据有歧义 —— 宁可退回默认，也不要猜。
    @Test("Ambiguous fuzzy matches fall back to the default level")
    func ambiguousFallsBack() throws {
        let st = LightingState(id: "t", name: "T",
                               levels: ["LX": 10, "LX1": 20], defaultLevel: 5)
        // "LX 1" 归一化成 "LX1"，精确命中 20
        #expect(st.level(forPosition: "LX 1") == 20)
        // "LX 2" 归一化 "LX2"：没有精确命中，"LX" 是前缀但 "LX1" 不是
        #expect(st.level(forPosition: "LX 2") == 10)
        // 完全不相关的名字 → 默认值
        #expect(st.level(forPosition: "SOMETHING ELSE") == 5)
    }

    @Test("Whitespace and case do not matter")
    func normalisation() {
        let st = LightingState(id: "t", name: "T",
                               levels: ["boom sl": 40], defaultLevel: 0)
        #expect(st.level(forPosition: "BOOM SL") == 40)
        #expect(st.level(forPosition: "BOOMSL") == 40)
        #expect(st.level(forPosition: "BOOM-SL") == 40)
    }

    // MARK: 剖面图也吃场景

    /// 厨房那场 LX 2 是 0。剖面上若还画着它的光束，读图人会以为它亮着。
    @Test("A scene section does not draw beams for bars at 0%")
    func sectionRespectsDarkBars() throws {
        let set = try scenes()
        let d = try doc()
        let base = SectionSheet(fitting: d, paper: .a3, scale: 50, lightingState: nil)
        let kitchen = SectionSheet(fitting: d, paper: .a3, scale: 50,
                                   lightingState: set.state(id: "kitchen"))

        func beamCount(_ s: SectionSheet) -> Int {
            s.ops.reduce(0) { acc, op in
                if case .stroke(_, _, "BEAM", _, _) = op { return acc + 1 }
                return acc
            }
        }
        #expect(beamCount(kitchen) < beamCount(base),
                "kitchen turns LX 2 off, so it must have fewer beams")
        #expect(beamCount(kitchen) > 0, "but not zero — the lit bars still show")
    }

    @Test("A dark bar's lantern body is drawn dashed")
    func darkBarBodyDashed() throws {
        let set = try scenes()
        let d = try doc()
        let kitchen = SectionSheet(fitting: d, paper: .a3, scale: 50,
                                   lightingState: set.state(id: "kitchen"))
        var dashed = 0
        for op in kitchen.ops {
            if case .stroke(_, _, "FIXTURE", _, let dash) = op, dash != nil { dashed += 1 }
        }
        #expect(dashed > 0, "the 0% bar's lantern body must be dashed")
    }

    @Test("The section title names the scene")
    func sectionTitle() throws {
        let set = try scenes()
        let d = try doc()
        let kitchen = SectionSheet(fitting: d, paper: .a3, scale: 50,
                                   lightingState: set.state(id: "kitchen"))
        let titles = kitchen.ops.compactMap { op -> String? in
            if case .text(let t) = op, t.string.hasPrefix("SECTION A-A") { return t.string }
            return nil
        }
        #expect(titles.contains { $0.contains("KITCHEN") },
                "scene sections must be distinguishable: \(titles)")
    }
}

/// 检查器与图面的一致性。
///
/// 场景激活时，图上印的是**场景色片**，而检查器若只读文档基础值，
/// 用户会看到"图上 L202、面板 L132" —— 分不清哪个对。
@MainActor
@Suite("Inspector consistency")
struct InspectorConsistencyTests {

    private func kitchenModel() throws -> EditorModel {
        let model = EditorModel()
        try model.open(url: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("data/rig.yaml"))
        model.selectState("kitchen")
        return model
    }

    @Test("The effective gel is the scene's, not the base one")
    func effectiveGel() throws {
        let model = try kitchenModel()
        let f201 = model.state.doc.fixture(unit: 201)!
        #expect(f201.gel == "L132", "the document keeps the base gel")
        #expect(model.activeState?.gel(for: f201) == "L202",
                "the scene turns it into L202")
    }

    @Test("Fixtures the scene does not override keep their base gel")
    func unoverridden() throws {
        let model = try kitchenModel()
        let f101 = model.state.doc.fixture(unit: 101)!
        #expect(f101.gel == "L201")
        #expect(model.activeState?.gel(for: f101) == "L201")
    }

    /// 退出场景后必须回到基础值 —— 否则用户会以为文档被改了。
    @Test("Leaving the scene restores the base gel")
    func leaving() throws {
        let model = try kitchenModel()
        model.selectState(nil)
        let f201 = model.state.doc.fixture(unit: 201)!
        #expect(model.activeState == nil)
        #expect(f201.gel == "L132", "the document must never be mutated by scene switching")
    }

    /// 场景切换不能改文档内容（只改渲染）。
    @Test("Switching scenes never mutates the document")
    func scenesDoNotMutate() throws {
        let model = EditorModel()
        try model.open(url: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("data/rig.yaml"))
        let before = try DocumentCodec.encodeJSON(model.state.doc)

        model.selectState("kitchen")
        model.selectState("boston")
        model.selectState(nil)

        let after = try DocumentCodec.encodeJSON(model.state.doc)
        #expect(before == after, "scene switching must be a pure view operation")
        #expect(model.state.canUndo == false, "and it must not create undo points")
    }
}
