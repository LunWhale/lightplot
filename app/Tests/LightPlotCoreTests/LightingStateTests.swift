import Testing
import Foundation
@testable import LightPlotCore

/// 场景系统（设计状态）。
///
/// 设计任务书要求"两个形成对比的场景"，而且对比要来自
/// **光的组织方式**（色片 + 强度重新分配），不是另起一批灯位。
///
/// 这块功能在第一版里**完全缺失** —— 旧管线会出三张平面图
/// （基础 / kitchen / boston），LightPlot 只出一张。
@Suite("Lighting states")
struct LightingStateTests {

    private func realScenes() throws -> LightingStateSet {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("data/scenes.yaml")
        return try LightingStateCodec.decodeYAML(Data(contentsOf: url))
    }

    @Test("The real scenes.yaml parses into two states plus a transition")
    func parses() throws {
        let set = try realScenes()
        #expect(set.states.count == 2)
        #expect(set.transitions.count == 1)
        let ids = set.states.map(\.id)
        #expect(ids.contains("kitchen"))
        #expect(ids.contains("boston"))
    }

    @Test("Gel overrides are applied per fixture")
    func gelOverride() throws {
        let set = try realScenes()
        let doc = try TestData.realDocument()
        let kitchen = set.state(id: "kitchen")!

        // 灯 201 基础是 L132；kitchen 把它换成 L202
        let f201 = doc.fixture(unit: 201)!
        #expect(f201.gel == "L132")
        #expect(kitchen.gel(for: f201) == "L202")

        // 灯 101 基础 L201；kitchen 里保持 L201
        let f101 = doc.fixture(unit: 101)!
        #expect(kitchen.gel(for: f101) == "L201")
    }

    @Test("Levels fall back to defaultLevel")
    func levels() throws {
        let set = try realScenes()
        let kitchen = set.state(id: "kitchen")!
        #expect(kitchen.level(forPosition: "FOH") == 45)
        #expect(kitchen.level(forPosition: "LX2") == 0)
        // 未列出的构件 → defaultLevel (0)
        #expect(kitchen.level(forPosition: "NOT A REAL BAR") == 0)
    }

    @Test("Free-standing practicals read the SET level")
    func practicalLevel() throws {
        let set = try realScenes()
        let doc = try TestData.realDocument()
        let kitchen = set.state(id: "kitchen")!
        let practical = doc.fixture(unit: 901)!
        #expect(practical.isFreeMounted)
        #expect(kitchen.level(for: practical) == 70)
    }

    /// 这是任务书的核心要求：两个场景必须有实质对比。
    @Test("The two real scenes contrast enough to count as two states")
    func contrast() throws {
        let set = try realScenes()
        let doc = try TestData.realDocument()
        let k = set.state(id: "kitchen")!, b = set.state(id: "boston")!
        let c = set.contrast(k, b, doc: doc)
        #expect(c.isSufficient, "gel \(c.gelDifferences), level \(c.levelDifferences)")
        #expect(c.gelDifferences >= 2)
        #expect(c.levelDifferences >= 2)
    }

    @Test("Identical scenes are reported as insufficient contrast")
    func noContrast() throws {
        let doc = try TestData.realDocument()
        let a = LightingState(id: "a", name: "A", levels: ["LX1": 50])
        let b = LightingState(id: "b", name: "B", levels: ["LX1": 50])
        let set = LightingStateSet(states: [a, b])
        #expect(!set.contrast(a, b, doc: doc).isSufficient)
    }

    // MARK: 渲染

    /// **最致命的一类错误**：分场景图印错色号 —— 图看起来正常，
    /// 灯光师按图装片却装错。这条必须钉死。
    @Test("The scene sheet prints the overridden gel, not the base gel")
    func sheetShowsOverride() throws {
        let set = try realScenes()
        let doc = try TestData.realDocument()
        let kitchen = set.state(id: "kitchen")!

        func labels(_ sheet: PlanSheet) -> [String] {
            sheet.ops.compactMap { op -> String? in
                if case .text(let t) = op, t.layer == "FIXTURE_TXT" { return t.string }
                return nil
            }
        }
        let base = PlanSheet(fitting: doc, paper: .a1, scale: 25, lightingState: nil)
        let scen = PlanSheet(fitting: doc, paper: .a1, scale: 25, lightingState: kitchen)

        // 基础图：6 台 LX 1 的灯显示 L132
        #expect(labels(base).filter { $0 == "L132" }.count == 6)
        #expect(labels(base).filter { $0 == "L202" }.count == 0)

        // 场景图：同样的 6 台显示 L202，且不再出现 L132
        #expect(labels(scen).filter { $0 == "L202" }.count == 6)
        #expect(labels(scen).filter { $0 == "L132" }.count == 0)
    }

    @Test("The two scenes produce visibly different sheets")
    func scenesDiffer() throws {
        let set = try realScenes()
        let doc = try TestData.realDocument()
        func gelLabels(_ id: String) -> [String] {
            let st = set.state(id: id)!
            let sheet = PlanSheet(fitting: doc, paper: .a1, scale: 25, lightingState: st)
            return sheet.ops.compactMap { op -> String? in
                if case .text(let t) = op, t.layer == "FIXTURE_TXT",
                   t.string.hasPrefix("L") { return t.string }
                return nil
            }
        }
        let k = gelLabels("kitchen"), b = gelLabels("boston")
        #expect(k != b, "kitchen and boston must not print identical gel codes")
    }

    @Test("A scene sheet carries its name so the three plans are distinguishable")
    func banner() throws {
        let set = try realScenes()
        let doc = try TestData.realDocument()
        let kitchen = set.state(id: "kitchen")!
        let sheet = PlanSheet(fitting: doc, paper: .a1, scale: 25, lightingState: kitchen)
        let texts = sheet.ops.compactMap { op -> String? in
            if case .text(let t) = op { return t.string }
            return nil
        }
        #expect(texts.contains { $0.contains("KITCHEN") },
                "scene sheet must be labelled; got \(texts.filter { $0.contains("KITCH") })")

        // 基础图不该有场景标签
        let base = PlanSheet(fitting: doc, paper: .a1, scale: 25, lightingState: nil)
        let baseTexts = base.ops.compactMap { op -> String? in
            if case .text(let t) = op { return t.string }
            return nil
        }
        #expect(!baseTexts.contains { $0.contains("KITCHEN / NIGHT") })
    }

    @Test("Scene sheets keep every other quality bar")
    func sceneSheetQuality() throws {
        let set = try realScenes()
        let doc = try TestData.realDocument()
        for state in set.states {
            let sheet = PlanSheet(fitting: doc, paper: .a1, scale: 25, lightingState: state)
            #expect(sheet.contentFitsSheet, "\(state.id) must fit A1")
            // 零文字重叠（与其余图同一标准）
            var boxes: [(String, Rect)] = []
            for op in sheet.ops {
                guard case .text(let t) = op,
                      !t.string.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let b = t.family.measuring.textBox(t.string, at: t.origin, capMM: t.capMM,
                                                   align: t.align,
                                                   rotationDegrees: t.rotationDegrees)
                boxes.append((t.string, b))
            }
            var hits: [String] = []
            for i in 0..<boxes.count {
                for j in (i + 1)..<boxes.count {
                    guard boxes[i].0 != boxes[j].0 else { continue }
                    if boxes[i].1.overlapsStrictly(boxes[j].1, pad: 0.15) {
                        hits.append("'\(boxes[i].0)' x '\(boxes[j].0)'")
                    }
                }
            }
            #expect(hits.isEmpty,
                    Comment(rawValue: "\(state.id): " + hits.prefix(4).joined(separator: " | ")))
        }
    }
}

/// 分场景图的图面语义。
///
/// 三件事必须同时成立，否则这张图会误导施工：
///   1. 图例只列本场景用到的色片
///   2. 本场景关掉的灯画虚轮廓（而不是实线）
///   3. 最右侧构件的标注要翻到内侧，不能伸进图例栏
@Suite("Scene sheet semantics")
struct SceneSheetSemanticsTests {

    private func scenes() throws -> LightingStateSet {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("data/scenes.yaml")
        return try LightingStateCodec.decodeYAML(Data(contentsOf: url))
    }

    /// 从图例图层的文字里提取**色片码**。
    ///
    /// 判据要收紧：色片码是 `L`/`R` 后跟数字，或 `OPEN`。
    /// 早先用 `hasPrefix("L")`，于是灯具类型 `LED  LED Wash RGBW`
    /// 也被当成色片码 `LED` —— 测试因此"发现"了一个不存在的色片。
    /// 解析器过于宽松时，测试会替代码说谎。
    private func legendGels(_ sheet: PlanSheet) -> Set<String> {
        var out = Set<String>()
        for op in sheet.ops {
            guard case .text(let t) = op, t.layer == "LEGEND" else { continue }
            let head = t.string.components(separatedBy: "  ").first ?? ""
            if head == "OPEN" { out.insert(head); continue }
            guard head.count >= 2, "LR".contains(head.first!) else { continue }
            guard head.dropFirst().allSatisfy(\.isNumber) else { continue }
            out.insert(head)
        }
        return out
    }

    @Test("The legend lists only gels used in that scene")
    func legendMatchesScene() throws {
        let set = try scenes()
        let doc = try TestData.realDocument()
        let kitchen = set.state(id: "kitchen")!

        let base = PlanSheet(fitting: doc, paper: .a1, scale: 25, lightingState: nil)
        let scen = PlanSheet(fitting: doc, paper: .a1, scale: 25, lightingState: kitchen)

        let baseGels = legendGels(base)
        let sceneGels = legendGels(scen)

        // 基础图也只列"有灯在用"的色片。
        //
        // 早先断言 `baseGels.count >= 8`（列全表）。那是旧行为：
        // 色片表 9 项里 L711/L200/L202 没有任何灯在用，
        // 列出来只是让版面变挤、让读图人困惑。
        // 真实数据共有 6 个在用（L103/L119/L132/L156/L201/OPEN）。
        #expect(baseGels.count == 6,
                "base legend lists exactly the gels in use, got \(baseGels.sorted())")
        #expect(baseGels.contains("OPEN"), "OPEN is used by 10 lanterns")
        // kitchen 把 L132→L202、L156 关掉，所以色片集合不同、不是更短。
        #expect(Set(sceneGels) != Set(baseGels),
                "the scene must change the legend, not just shorten it")
        // kitchen 实际用到：L201（FOH 面光）/ L202（LX1，由 L132 替换）/
        // L119（BOOM SL）/ L103（台灯）/ L200（LX3，由 L711 替换）/ OPEN
        #expect(sceneGels.contains("L201"), "FOH is at 45%, so L201 is used")
        #expect(sceneGels.contains("L202"), "LX 1's L132 is overridden to L202")
        #expect(sceneGels.contains("L119"))
        #expect(sceneGels.contains("L103"))
        #expect(sceneGels.contains("OPEN"), "OPEN must stay: it means 'no gel'")

        // 被替换掉的色片不该出现
        #expect(!sceneGels.contains("L711"), "L711 is overridden to L200 in kitchen")
        // 但 L200 也不该出现 —— 因为 **L711 本来就没有灯在用**（只是色片表里的一项）。
        // 这是数据的真实情况：色片表 9 项里 L711 是悬空的，
        // 所以替换规则再正确也不会生效。旧管线的图例同样印了它。
        #expect(!sceneGels.contains("L200"),
                "no lantern uses L711, so its replacement L200 cannot appear either")
        #expect(!sceneGels.contains("L156"), "kitchen does not use L156")
    }

    @Test("Fixtures at 0% are drawn with a dashed outline")
    func darkFixturesAreDashed() throws {
        let set = try scenes()
        let doc = try TestData.realDocument()
        let kitchen = set.state(id: "kitchen")!

        // kitchen: BOOM SR = 0 → 601/602/603 应当虚轮廓
        let scen = PlanSheet(fitting: doc, paper: .a1, scale: 25, lightingState: kitchen)
        var dashed = 0, solid = 0
        for op in scen.ops {
            if case .stroke(_, _, "FIXTURE", _, let dash) = op {
                if dash != nil { dashed += 1 } else { solid += 1 }
            }
        }
        #expect(dashed > 0, "kitchen must show some lanterns as off (dashed)")

        // 基础图全部实线
        let base = PlanSheet(fitting: doc, paper: .a1, scale: 25, lightingState: nil)
        var baseDashed = 0
        for op in base.ops {
            if case .stroke(_, _, "FIXTURE", _, let dash) = op, dash != nil { baseDashed += 1 }
        }
        #expect(baseDashed == 0, "base plan has no scene, so nothing is 'off'")
    }

    @Test("The legend explains the dashed convention")
    func legendExplainsDashes() throws {
        let set = try scenes()
        let doc = try TestData.realDocument()
        let scen = PlanSheet(fitting: doc, paper: .a1, scale: 25,
                             lightingState: set.state(id: "kitchen"))
        let texts = scen.ops.compactMap { op -> String? in
            if case .text(let t) = op { return t.string }
            return nil
        }
        #expect(texts.contains { $0.contains("DASHED") },
                "a scene sheet must explain what a dashed lantern means")
    }

    /// 最右侧 BOOM 的标注曾经伸进图例栏，压住 "COLOUR"。
    @Test("Edge fixtures flip their labels inward")
    func edgeLabelsFlip() throws {
        let doc = try TestData.realDocument()
        let sheet = PlanSheet(fitting: doc, paper: .a1, scale: 25, lightingState: nil)
        let area = SheetLayout.planArea(paper: sheet.layout.paper)

        // 所有 FIXTURE_TXT 的 bbox 必须落在绘图区内
        var out: [String] = []
        for op in sheet.ops {
            guard case .text(let t) = op, t.layer == "FIXTURE_TXT" else { continue }
            let b = t.family.measuring.textBox(t.string, at: t.origin, capMM: t.capMM,
                                               align: t.align,
                                               rotationDegrees: t.rotationDegrees)
            if b.x1 > area.x1 + 0.5 || b.x0 < area.x0 - 0.5 {
                out.append("'\(t.string)' \(b)")
            }
        }
        #expect(out.isEmpty,
                Comment(rawValue: "\(out.count) labels outside the plan area: "
                        + out.prefix(4).joined(separator: " | ")))
    }

    @Test("No label overlaps on a scene sheet either")
    func sceneSheetNoOverlap() throws {
        let set = try scenes()
        let doc = try TestData.realDocument()
        for state in set.states {
            let sheet = PlanSheet(fitting: doc, paper: .a1, scale: 25, lightingState: state)
            var boxes: [(String, Rect)] = []
            for op in sheet.ops {
                guard case .text(let t) = op,
                      !t.string.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                boxes.append((t.string,
                              t.family.measuring.textBox(t.string, at: t.origin,
                                                         capMM: t.capMM, align: t.align,
                                                         rotationDegrees: t.rotationDegrees)))
            }
            var hits: [String] = []
            for i in 0..<boxes.count {
                for j in (i + 1)..<boxes.count {
                    guard boxes[i].0 != boxes[j].0 else { continue }
                    if boxes[i].1.overlapsStrictly(boxes[j].1, pad: 0.15) {
                        hits.append("'\(boxes[i].0)' x '\(boxes[j].0)'")
                    }
                }
            }
            #expect(hits.isEmpty,
                    Comment(rawValue: "\(state.id): " + hits.prefix(4).joined(separator: " | ")))
        }
    }
}
