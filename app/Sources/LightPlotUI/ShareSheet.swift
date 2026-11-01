#if os(iOS)
import SwiftUI
import UIKit

/// 系统分享面板。
///
/// iPad 上导出的 PDF 落在 `Documents/`，但用户不可能知道那个路径。
/// 这里直接把文件交给系统，用户可以「存储到文件」「发送邮件」「打印」——
/// 打印这一条尤其重要：交付物是要装裱的实体图纸。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
#endif
