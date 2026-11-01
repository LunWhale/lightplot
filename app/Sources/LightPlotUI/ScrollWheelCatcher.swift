import SwiftUI

#if os(macOS)
import AppKit

/// 捕获滚轮 / 触控板缩放。
///
/// SwiftUI 至今没有跨平台的滚轮与捏合 API，只能落到 AppKit。
/// 这层刻意做成"零状态"：它只把事件转成回调，不持有任何视图状态 ——
/// 所有画布状态仍然在 `EditorModel` 里，所以交互逻辑依旧可测试。
struct ScrollWheelCatcher: NSViewRepresentable {
    /// (滚动量, 光标位置（视图坐标）, 缩放增量)
    let handler: (CGPoint, CGPoint, CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = CatcherView()
        view.handler = handler
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.handler = handler
    }

    final class CatcherView: NSView {
        var handler: ((CGPoint, CGPoint, CGFloat) -> Void)?
        private var magnifyAccumulator: CGFloat = 0

        override var acceptsFirstResponder: Bool { true }

        override func scrollWheel(with event: NSEvent) {
            // 触控板双指滚动的 delta 很小，鼠标滚轮很大。
            // 统一到"点"这个量级，否则同一个手势在两种设备上手感差一个数量级。
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
            let delta = CGPoint(x: event.scrollingDeltaX * scale,
                                y: event.scrollingDeltaY * scale)
            let local = convert(event.locationInWindow, from: nil)
            // AppKit 原点在左下，SwiftUI 在左上
            let flipped = CGPoint(x: local.x, y: bounds.height - local.y)
            handler?(delta, flipped, 0)
        }

        override func magnify(with event: NSEvent) {
            magnifyAccumulator += event.magnification
            let local = convert(event.locationInWindow, from: nil)
            let flipped = CGPoint(x: local.x, y: bounds.height - local.y)
            // 每次放大一点点，让缩放跟手而不是跳变
            let step = event.magnification
            handler?(.zero, flipped, step)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .arrow)
        }
    }
}
#endif
