import Foundation
#if os(macOS)
import AppKit
#endif

/// 「双击图纸文件」的接收器。
///
/// ## 为什么需要
///
/// `project.yml` 里把 `.lpx` / `.yaml` / `.json` 声明成本应用可打开的类型，
/// 于是 macOS 会让我们成为这些文件的默认打开方式。但如果没有接收器，
/// 双击**只会启动应用**，然后停在示例文档上 —— 文件根本没被打开。
///
/// 那比"不声明类型"更糟：用户会以为自己的图纸坏了。
///
/// ## 一个时序坑
///
/// `application(_:open:)` 可能在 SwiftUI 的窗口与 `onAppear`
/// **就绪之前**就触发。所以这里先把 URL 存起来，
/// 等界面挂上之后由 `consumePending` 取走处理。
///
/// 两个时序都有测试（`DocumentOpeningTests`），因为这类"偶发不打开"
/// 的缺陷在真机上极难复现。
public final class DocumentOpenRelay: ObservableObject {

    /// 界面就绪后设置的处理函数。
    private var handler: ((URL) -> Void)?
    /// 界面还没就绪时先存着的那一个。
    private var pending: URL?

    public init() {}

    /// 收到一个要打开的文件。
    public func receive(_ url: URL) {
        if let handler {
            handler(url)
        } else {
            pending = url
        }
    }

    /// 界面挂上后调用：设置处理函数，并把早到的那个交出去。
    public func consumePending(using handler: @escaping (URL) -> Void) {
        self.handler = handler
        if let url = pending {
            pending = nil
            handler(url)
        }
    }

    /// 还有没有没被处理掉的文件（诊断与测试用）。
    public var hasPending: Bool { pending != nil }
}

#if os(macOS)
/// AppKit 侧的薄壳：把 `application(_:open:)` 转给 `DocumentOpenRelay`。
public final class LightPlotAppDelegate: NSObject, NSApplicationDelegate {
    public let relay = DocumentOpenRelay()

    public override init() { super.init() }

    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { relay.receive(url) }
    }
}
#endif
