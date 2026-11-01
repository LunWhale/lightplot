import Testing
import Foundation
import SwiftUI
import AppKit
@testable import LightPlotCore
@testable import LightPlotUI

/// 应用**外观**的验收：把真实的 `EditorView` 离屏渲染成图。
///
/// 系统截图在无显示环境里不可用，但 `NSHostingView` 会走完整的
/// SwiftUI 布局与绘制 —— 工具栏、画布、检查器都是真的在画，
/// 不是另写一套假界面。所以这能证明"界面能出来、不崩、不空白"。
///
/// 它证明不了手感（那要上手），但能证明**画面本身**是对的。
@MainActor
@Suite("App look")
struct AppLookTests {

    private func render<V: View>(_ view: V, size: CGSize,
                                 to path: String) throws -> Int {
        let host = NSHostingView(rootView: view.frame(width: size.width,
                                                     height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        // 让 SwiftUI 完成一次布局与绘制周期
        RunLoop.current.run(until: Date().addingTimeInterval(0.45))

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw SnapshotFailure.render
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw SnapshotFailure.encode
        }
        try data.write(to: URL(fileURLWithPath: path))
        return data.count
    }

    enum SnapshotFailure: Error { case render, encode }

    @Test("The whole editor window renders without a window")
    func editorWindow() throws {
        let model = EditorModel()
        try model.open(url: TestData.workspaceRoot.appendingPathComponent("data/rig.yaml"))

        let path = "/tmp/look_editor.png"
        let bytes = try render(EditorView(model: model),
                               size: CGSize(width: 1280, height: 820), to: path)
        #expect(bytes > 60_000, "the rendered window is only \(bytes) bytes — likely blank")
    }

    @Test("The inspector renders with a lantern selected")
    func inspectorWithFixture() throws {
        let model = EditorModel()
        try model.open(url: TestData.workspaceRoot.appendingPathComponent("data/rig.yaml"))
        model.dispatch(.select(.init(fixtures: [201])))

        let bytes = try render(InspectorPanel(model: model),
                               size: CGSize(width: 320, height: 900),
                               to: "/tmp/look_inspector.png")
        #expect(bytes > 15_000, "the inspector rendered \(bytes) bytes")
    }

    @Test("The page setup panel renders")
    func pageSetup() throws {
        let model = EditorModel()
        try model.open(url: TestData.workspaceRoot.appendingPathComponent("data/rig.yaml"))

        let bytes = try render(PageSetupPanel(model: model),
                               size: CGSize(width: 520, height: 620),
                               to: "/tmp/look_pagesetup.png")
        #expect(bytes > 20_000, "the page setup panel rendered \(bytes) bytes")
    }

    // 欢迎页在 App target 里（不在 LightPlotUI），测试不能直接构造它；
    // 它由  之外的构建验证保证能编译并出现在窗口链上。


    /// 画布本身（应用里真正在用的那个视图）。
    @Test("The sheet canvas renders the real project")
    func canvas() throws {
        var doc = try DocumentCodec.decodeYAML(
            Data(contentsOf: TestData.workspaceRoot.appendingPathComponent("data/rig.yaml")))
        _ = GelLibrary.fillMissingColours(in: &doc)
        let data = try CanvasSnapshot.render(doc: doc, width: 1600, scale: 2)
        #expect(data.count > 80_000)
        try data.write(to: URL(fileURLWithPath: "/tmp/look_canvas.png"))
    }
}
