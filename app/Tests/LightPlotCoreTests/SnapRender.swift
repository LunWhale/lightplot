import Testing
import SwiftUI
import Foundation
@testable import LightPlotCore
@testable import LightPlotUI

/// 吸附指示器的实际渲染 —— 光有代码不算数，得看得见。
@MainActor
@Test func renderSnapIndicator() throws {
    let doc = try TestData.validDocument()
    let model = EditorModel(doc: doc)
    model.setCanvasSize(Vec2(1100, 760))
    model.fitToSheet()

    // 模拟：用户把构件左端点拖到"接近另一根杆端点"的位置
    let target = model.state.layout.toSheet(Vec2(-7500, 2400))   // LX 1 左端
    let near = target + Vec2(2.2, 1.6)                            // 吸附半径内但未命中
    model.updateSnapPreview(at: near, excluding: "LX 1")

    #expect(model.snapPreview != nil, "snap preview should be active near an endpoint")

    let view = SheetCanvas(sheet: model.sheet,
                           viewport: model.viewport,
                           selection: .empty,
                           showBeams: true,
                           hoverPosition: nil,
                           autoFit: false,
                           canvasSize: Vec2(1100, 760),
                           snapPreview: model.snapPreview)
        .frame(width: 1100, height: 760)

    let r = ImageRenderer(content: view)
    r.scale = 3
    guard let cg = r.cgImage else { Issue.record("render failed"); return }
    try NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: "/tmp/snap_indicator.png"))
}
