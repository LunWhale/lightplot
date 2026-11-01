import Testing
import SwiftUI
import AppKit
import Foundation
@testable import LightPlotCore
@testable import LightPlotUI

/// 场景功能在应用里的接入。
///
/// 核心模型 + CLI 早就有了，但**应用界面里没有任何入口** ——
/// 用户打不开、看不到、比不了两个场景，而那是设计任务书的核心要求。
@MainActor
@Suite("Scene UI wiring")
struct SceneUIWiringTests {

    private func scenesURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("data/scenes.yaml")
    }

    @Test("Loading the rig auto-loads the sibling scenes.yaml")
    func autoLoadSibling() throws {
        let rigURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("data/rig.yaml")
        let model = EditorModel()
        try model.open(url: rigURL)
        #expect(model.hasStates, "opening rig.yaml should pick up scenes.yaml next to it")
        #expect(model.states.states.count == 2)
        #expect(model.activeStateID == nil, "default view is the base plan")
    }

    @Test("Switching a scene changes the printed gel codes")
    func switchStateChangesSheet() throws {
        let model = EditorModel(doc: try TestData.realDocument())
        model.loadStates(from: scenesURL())
        #expect(model.hasStates)

        func gelLabels() -> [String] {
            model.sheet.ops.compactMap { op -> String? in
                if case .text(let t) = op, t.layer == "FIXTURE_TXT",
                   t.string.hasPrefix("L") { return t.string }
                return nil
            }
        }

        let base = gelLabels()
        #expect(base.contains("L132"))

        model.selectState("kitchen")
        let kitchen = gelLabels()
        #expect(kitchen.contains("L202"), "kitchen must show L202")
        #expect(!kitchen.contains("L132"), "kitchen must not still show the base L132")

        model.selectState("boston")
        let boston = gelLabels()
        #expect(boston.contains("L103"))
        #expect(kitchen != boston)

        model.selectState(nil)
        #expect(gelLabels() == base, "going back to base must restore the original gels")
    }

    @Test("The active state is reported for the title bar and export name")
    func activeStateNaming() throws {
        let model = EditorModel(doc: try TestData.realDocument())
        model.loadStates(from: scenesURL())
        #expect(model.activeState == nil)

        model.selectState("kitchen")
        #expect(model.activeState?.id == "kitchen")

        let name = model.defaultExportFilename()
        #expect(name.contains("KITCHEN"), "export name must identify the scene: \(name)")
    }

    @Test("Exporting all states produces one PDF per scene plus the base")
    func exportAll() throws {
        let model = EditorModel(doc: try TestData.realDocument())
        model.loadStates(from: scenesURL())

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("states-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let urls = model.exportAllStates(to: dir)
        #expect(urls.count == 3, "base + kitchen + boston, got \(urls.count)")
        #expect(Set(urls.map(\.lastPathComponent)).count == 3, "names must be unique")
        for u in urls {
            let size = try FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int ?? 0
            #expect(size > 50_000, "\(u.lastPathComponent) too small: \(size)")
        }
    }

    @Test("Contrast is computable from the model for the inspector panel")
    func contrastInModel() throws {
        let model = EditorModel(doc: try TestData.realDocument())
        model.loadStates(from: scenesURL())
        model.selectState("kitchen")
        let c = model.contrast(with: "boston")
        #expect(c != nil)
        #expect(c!.isSufficient)
    }

    /// 场景面板与画布都要能真的画出来 —— 光有代码不算数。
    @Test("The editor renders with a scene selected")
    func renderWithScene() throws {
        let model = EditorModel(doc: try TestData.realDocument())
        model.loadStates(from: scenesURL())
        model.selectState("boston")
        model.setCanvasSize(Vec2(1100, 760))
        model.fitToSheet()

        let view = SheetCanvas(sheet: model.sheet, viewport: model.viewport,
                               selection: .empty, showBeams: true,
                               hoverPosition: nil, autoFit: false,
                               canvasSize: Vec2(1100, 760))
            .frame(width: 1100, height: 760)
        let r = ImageRenderer(content: view)
        r.scale = 1
        #expect(r.cgImage != nil, "the canvas must render in a scene state")
    }

    @Test("The inspector renders the scene panel without crashing")
    func renderInspector() throws {
        let model = EditorModel(doc: try TestData.realDocument())
        model.loadStates(from: scenesURL())
        model.selectState("kitchen")
        let host = NSHostingView(rootView: InspectorPanel(model: model)
            .frame(width: 286, height: 700))
        host.frame = NSRect(x: 0, y: 0, width: 286, height: 700)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            Issue.record("no bitmap rep"); return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        #expect(rep.pixelsWide > 0)
    }
}
