import Testing
import Foundation
@testable import LightPlotCore
@testable import LightPlotUI

/// 双击图纸文件必须真的打开它。
///
/// 应用在 `Info.plist` 里声明了 `.lpx` / `.yaml` / `.json`，
/// 所以 macOS 会让我们成为这些文件的默认打开方式。
/// 声明了却不处理，双击只会启动应用并停在示例文档 ——
/// 用户会以为图纸坏了。这类"偶发不打开"在真机上极难复现，
/// 所以两种时序都写成测试。
@Suite("Document opening")
struct DocumentOpeningTests {

    @Test("A file that arrives before the UI is ready is not lost")
    func earlyArrival() {
        let relay = DocumentOpenRelay()
        let url = URL(fileURLWithPath: "/tmp/early.lpx")

        // 界面还没挂上 —— 先到
        relay.receive(url)
        #expect(relay.hasPending, "the URL must be buffered, not dropped")

        var opened: [URL] = []
        relay.consumePending { opened.append($0) }

        #expect(opened.count == 1, "the buffered URL must be delivered once ready")
        #expect(opened.first == url)
        #expect(!relay.hasPending, "the buffer must be cleared after delivery")
    }

    @Test("A file that arrives after the UI is ready opens immediately")
    func lateArrival() {
        let relay = DocumentOpenRelay()
        var opened: [URL] = []
        relay.consumePending { opened.append($0) }
        #expect(opened.isEmpty, "nothing to deliver yet")

        let url = URL(fileURLWithPath: "/tmp/late.yaml")
        relay.receive(url)
        #expect(opened == [url], "an already-ready app must open it right away")
        #expect(!relay.hasPending)
    }

    @Test("Later files are delivered even after the first one")
    func repeatedOpen() {
        let relay = DocumentOpenRelay()
        var opened: [URL] = []
        relay.consumePending { opened.append($0) }

        let a = URL(fileURLWithPath: "/tmp/a.lpx")
        let b = URL(fileURLWithPath: "/tmp/b.yaml")
        relay.receive(a)
        relay.receive(b)

        #expect(opened == [a, b], "every opened file must be delivered, in order")
    }

    /// 端到端：把真实数据存成 `.lpx`，经接收器打开，文档内容必须对。
    @Test("Opening a real file through the relay loads the document")
    @MainActor
    func realFileThroughRelay() throws {
        let model = EditorModel()
        try model.open(url: TestData.rigYAML)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openrelay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("plan.lpx")
        #expect(model.save(to: path))

        // 模拟"应用刚启动就双击了一个 .lpx"
        let fresh = EditorModel()
        let relay = DocumentOpenRelay()
        var loaded: EditorModel?
        relay.consumePending { url in
            try? fresh.open(url: url)
            loaded = fresh
        }
        relay.receive(path)

        let got = try #require(loaded)
        #expect(got.state.doc.meta.show == "DEATH OF A SALESMAN")
        #expect(got.state.doc.fixtures.count == 32)
    }
}
