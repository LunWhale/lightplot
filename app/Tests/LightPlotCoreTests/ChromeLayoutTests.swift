import Testing
import Foundation
@testable import LightPlotCore
@testable import LightPlotUI

/// 画布上方的浮层工具栏不能遮住图纸。
///
/// 这类缺陷在缩略图里看不出来（工具栏是半透明的），
/// 但用户第一次打开应用就看到被切掉一角的图 —— 那是"这软件没做完"的第一印象。
///
/// 判据写成几何断言：适配之后图纸的上下边界必须落在
/// `[chromeTop, size − chromeBottom]` 这个可见区间内。
@MainActor
@Suite("Chrome layout")
struct ChromeLayoutTests {

    private func model(_ page: EditorModel.SheetPage = .plan) throws -> EditorModel {
        let m = EditorModel()
        try m.open(url: TestData.workspaceRoot.appendingPathComponent("data/rig.yaml"))
        m.page = page
        return m
    }

    @Test("The fitted sheet sits between the floating toolbar and the status bar")
    func sheetClearsChrome() throws {
        let sizes: [CGSize] = [
            CGSize(width: 1280, height: 820),
            CGSize(width: 900, height: 620),     // 最小窗口
            CGSize(width: 2000, height: 1400),
        ]
        for size in sizes {
            let m = try model()
            m.setCanvasSize(Vec2(size.width, size.height))
            m.fitToSheet()

            let frame = m.currentPaperFrame
            let vp = m.viewport
            let top = vp.toView(Vec2(frame.x0, frame.y1))     // 图纸左上角
            let bottom = vp.toView(Vec2(frame.x0, frame.y0))  // 图纸左下角

            let label = "\(Int(size.width))x\(Int(size.height))"
            #expect(top.y >= EditorModel.chromeTopPoints - 1,
                    "\(label): the sheet top (\(top.y)) is under the toolbar")
            #expect(bottom.y <= size.height - EditorModel.chromeBottomPoints + 1,
                    "\(label): the sheet bottom (\(bottom.y)) is under the status bar")
            #expect(top.x >= -1 && vp.toView(Vec2(frame.x1, frame.y1)).x <= size.width + 1,
                    "\(label): the sheet is horizontally outside the canvas")
        }
    }

    /// 派生视口（用户还没手动接管视角时用的那个）也必须让开浮层。
    @Test("The derived viewport reserves the same space as fitToSheet")
    func derivedViewportClearsChrome() throws {
        let m = try model()
        m.setCanvasSize(Vec2(1280, 820))
        // 不调用 fitToSheet —— 走派生路径

        let frame = m.currentPaperFrame
        let vp = m.viewport
        let top = vp.toView(Vec2(frame.x0, frame.y1))
        #expect(top.y >= EditorModel.chromeTopPoints - 1,
                "the derived viewport puts the sheet top at \(top.y)")
    }

    /// 状态栏的比例必须跟着页面走：平面 1:25，剖面 1:50。
    @Test("The status bar reports the scale of the page being shown")
    func scaleFollowsPage() throws {
        let m = try model(.plan)
        let planScale = m.currentScaleDenominator
        #expect(planScale == 25)

        m.page = .section
        let sectionScale = m.currentScaleDenominator
        #expect(sectionScale == 50,
                "the section is drawn at 1:50, the status bar says 1:\(sectionScale)")
    }
}
