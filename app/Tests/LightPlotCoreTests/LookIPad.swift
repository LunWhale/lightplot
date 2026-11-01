import Testing
import Foundation
import SwiftUI
import AppKit
@testable import LightPlotCore
@testable import LightPlotUI

/// iPad 布局验收。
///
/// 之前只做了"能编译"的门禁。但用户要求是 **iPad 不能坏** ——
/// 布局坏了照样是坏。`NSHostingView` 渲染走的是同一套 SwiftUI 布局，
/// 所以在 Mac 上就能验证 iPad 的尺寸下排版是否成立。
@MainActor
@Suite("iPad layout")
struct LookIPadTests {

    private func shot<V: View>(_ v: V, _ w: CGFloat, _ h: CGFloat,
                               _ path: String) throws -> Int {
        let host = NSHostingView(rootView: v.frame(width: w, height: h))
        host.frame = NSRect(x: 0, y: 0, width: w, height: h)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            Issue.record("could not allocate a bitmap for \(path)"); return 0
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = rep.representation(using: .png, properties: [:]) ?? Data()
        try data.write(to: URL(fileURLWithPath: path))
        return data.count
    }

    /// iPad **横向**尺寸下的编辑界面。
    ///
    /// **只测 ≥900 宽的尺寸，这是有原因的**：`EditorView` 在 macOS 上带
    /// `.frame(minWidth: 900)`，所以在 Mac 上用 834 宽渲染时，SwiftUI 会先
    /// 按 900 布局再裁剪 —— 量到的"画布宽度"是 613 而不是 834，
    /// 于是看到的是**被裁过的 macOS 布局**，不是 iPad 的真实排版。
    ///
    /// 早先的版本把 834×1194 也当成 iPad 竖屏来测，得到的是假结论。
    /// 竖屏排版必须在 iPad 模拟器或真机上看，不能靠这条测试代替。
    @Test("The editor lays out on iPad landscape sizes")
    func iPadLandscape() throws {
        let sizes: [(name: String, w: CGFloat, h: CGFloat)] = [
            ("pro11-landscape", 1194, 834),
            ("ipad10-landscape", 1080, 810),
            ("mini-landscape", 1133, 744),
            ("pro129-landscape", 1366, 1024),
        ]
        let model = EditorModel()
        try model.open(url: TestData.workspaceRoot.appendingPathComponent("data/rig.yaml"))

        for s in sizes {
            let bytes = try shot(EditorView(model: model), s.w, s.h,
                                 "/tmp/ipad_\(s.name).png")
            #expect(bytes > 80_000,
                    "\(s.name): only \(bytes) bytes — the layout probably collapsed")
            // 画布必须真的拿到宽度（不是被裁成一条）
            #expect(model.debugCanvasSize.x > 600,
                    "\(s.name): canvas width collapsed to \(model.debugCanvasSize.x)")
        }
    }

    /// 竖屏时检查器变成抽屉（`narrowInspector`），抽屉宽度必须放得下中文。
    @Test("The inspector drawer fits Chinese text at iPad portrait width")
    func inspectorDrawerWidth() throws {
        let original = L10n.language
        L10n.language = .chinese
        defer { L10n.language = original }

        let model = EditorModel()
        try model.open(url: TestData.workspaceRoot.appendingPathComponent("data/rig.yaml"))
        model.dispatch(.select(.init(fixtures: [201])))

        // 抽屉宽度是 min(340, 窗口宽 × 0.82)：mini 竖屏 744 → 340
        for w in [300.0, 340.0] as [CGFloat] {
            let bytes = try shot(InspectorPanel(model: model).frame(width: w),
                                 340, 1000, "/tmp/ipad_drawer_\(Int(w)).png")
            #expect(bytes > 15_000, "drawer at \(w)pt rendered \(bytes) bytes")
        }
    }


}
