import SwiftUI
import UniformTypeIdentifiers
import LightPlotCore
import LightPlotUI

/// LightPlot —— macOS / iPadOS 应用入口。
///
/// 一个 `WindowGroup` + `DocumentGroup` 的取舍：
/// 用 `DocumentGroup` 能白拿"打开/保存/最近文件/自动保存"，但它的 `FileDocument`
/// 要求整个文档可序列化且读写是同步的 —— 对我们这份 YAML/JSON 混合格式来说太重。
/// 所以这里用普通 `WindowGroup` + 自己的文件菜单，
/// 换来的是"打开旧 rig.yaml 不覆盖原文件"这个明确的语义。
@main
struct LightPlotApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(LightPlotAppDelegate.self) private var appDelegate
    #endif

    /// 启动即进入编辑器（带一份可用的示例骨架）。
    ///
    /// 不先放欢迎页：用户打开就想画图，而"空白文档"比"先点两下再看到空白"更好。
    /// 打开旧项目走 File > Open（Cmd-O），与其它 Mac 应用一致。
    @State private var opened: EditorModel? = EditorModel(doc: SampleDocument.make())

    var body: some Scene {
        WindowGroup {
            Group {
                if let model = opened {
                    EditorView(model: model)
                } else {
                    WelcomeView { url in
                        open(url)
                    } onNew: {
                        opened = EditorModel(doc: SampleDocument.make())
                    }
                }
            }
            // 界面挂上后接收"双击文件"事件（含早到的那种）。
            .onAppear {
                #if os(macOS)
                appDelegate.relay.consumePending { url in open(url) }
                #endif
            }
            // iPad：从"文件"或别的应用把图纸拖进来
            .onOpenURL { url in open(url) }
        }
        .commands { menuCommands }
    }

    private func open(_ url: URL) {
        // 复用编辑器已有的打开逻辑，避免"菜单打开"与"应用内打开"行为不一致。
        let model = opened ?? EditorModel(doc: SampleDocument.make())
        do {
            try model.open(url: url)
            opened = model
        } catch {
            // 打不开就保留当前文档，而不是把用户的工作替换成示例 ——
            // 静默替换会让人以为文件丢了。
        }
    }

    @CommandsBuilder
    private var menuCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L10n.t("New Plan")) {
                if let model = opened {
                    model.replaceDocument(SampleDocument.make())
                } else {
                    opened = EditorModel(doc: SampleDocument.make())
                }
            }
            .keyboardShortcut("n", modifiers: .command)

            Button(L10n.t("Open…")) {
                #if os(macOS)
                let panel = FilePanel()
                if let url = panel.chooseOpen() { open(url) }
                #endif
            }
            .keyboardShortcut("o", modifiers: .command)

            Button(L10n.t("Save")) {
                guard let model = opened else { return }
                if model.saveInPlace() { return }
                #if os(macOS)
                let suggested = (model.state.doc.meta.show.isEmpty
                                 ? "Untitled" : model.state.doc.meta.show) + ".lpx"
                if let url = FilePanel().chooseSaveDocument(suggested: suggested) {
                    model.save(to: url)
                }
                #endif
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(opened == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button(L10n.t("Export A1 PDF…")) {
                #if os(macOS)
                guard let model = opened else { return }
                let panel = FilePanel()
                if let url = panel.chooseSave(suggested: (model.state.doc.meta.show.isEmpty
                                                          ? "LX Plan" : model.state.doc.meta.show + " LX Plan") + ".pdf") {
                    model.exportPDF(to: url)
                }
                #endif
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(opened == nil)
        }
    }
}

/// 起始页。
struct WelcomeView: View {
    let onOpen: (URL) -> Void
    let onNew: () -> Void

    var body: some View {
        VStack(spacing: 26) {
            VStack(spacing: 8) {
                Image(systemName: "light.max")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.secondary)
                Text("LightPlot")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text(L10n.t("Lighting plans at 1:25, drawn on a canvas."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                Button(action: onNew) {
                    Label(L10n.t("Start a new plan"), systemImage: "plus.rectangle.on.rectangle")
                        .frame(maxWidth: 260)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    #if os(macOS)
                    let panel = FilePanel()
                    if let url = panel.chooseOpen() { onOpen(url) }
                    #endif
                } label: {
                    Label("Open rig.yaml…", systemImage: "folder")
                        .frame(maxWidth: 260)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Text(L10n.t("Files in the old YAML format open directly. Nothing is overwritten until you export."))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(minWidth: 520, minHeight: 460)
        .padding(40)
    }
}

#if os(macOS)
import AppKit

/// 极简文件面板封装。做成类型是为了让 App 层不直接依赖 AppKit 细节。
struct FilePanel {
    func chooseOpen() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .yaml, .json,
            UTType(filenameExtension: "lpx") ?? .json,
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    func chooseSave(suggested: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested
        panel.allowedContentTypes = [.pdf]
        return panel.runModal() == .OK ? panel.url : nil
    }

    func chooseSaveDocument(suggested: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested
        panel.allowedContentTypes = [UTType(filenameExtension: "lpx") ?? .json]
        return panel.runModal() == .OK ? panel.url : nil
    }
}
#endif

/// 新建文档的示例内容。
///
/// 有意做成"能立刻出图"的骨架：一个空舞台 + 一根桁架 + 两盏灯。
/// 用户打开就有东西可拖，而不是面对一张白纸不知道从哪开始。
enum SampleDocument {
    static func make() -> LXDocument {
        var doc = LXDocument()
        doc.meta = .init(profile: "study",
                         show: "NEW SHOW",
                         playwright: "",
                         venue: "STUDIO THEATRE",
                         sheetTitle: "LX PLAN",
                         scale: 25,
                         date: todayString(),
                         revision: "V1",
                         revNote: "FIRST ISSUE",
                         director: "I DON'T KNOW",
                         designer: "")
        doc.stage = .init(width: 12000, depth: 8000, datum: 0, gridHeight: 7000,
                          prosceniumHeight: 6000, prosceniumX: -1000,
                          audienceRows: 5, audienceRowDepth: 560, audienceRake: 150)
        doc.positions = [
            Position(id: "LX 1", kind: .horizontal, type: .truss,
                     x0: -6000, x1: 6000, y: 2400, trim: 6000),
            Position(id: "FOH LX", kind: .horizontal, type: .pipe,
                     x0: -6000, x1: 6000, y: -800, trim: 6800),
        ]
        doc.types = [
            "profile": .init(label: "Profile / ERS 750W", watt: 750, role: "FACE"),
            "fresnel": .init(label: "Fresnel 650W", watt: 650, role: "SOFT WASH"),
            "par": .init(label: "PAR 500W", watt: 500, role: "SIDE LIGHT"),
            "led": .init(label: "LED Wash RGBW", watt: 200, role: "COLOUR WASH"),
            "mover": .init(label: "Moving Light 300W", watt: 300, role: "SPECIAL"),
            "follow": .init(label: "Followspot 1200W", watt: 1200, role: "FOLLOWSPOT"),
            "practical": .init(label: "Practical", watt: 0, role: "PRACTICAL"),
        ]
        // 整个色库都装进新文档。
        // 不能只取前 N 个：用户完全可能选到第 13 个色号，
        // 那时 lint 会报"未定义的色片"，而这条错误对用户毫无意义。
        doc.gels = GelLibrary.all.map { GelLibrary.gel(from: $0) }
        doc.fixtures = [
            Fixture(unit: 101, pos: "FOH LX", x: -2000, type: "profile", aim: 90,
                    gel: "L201", ch: 1, purpose: "FACE F1", beam: 26),
            Fixture(unit: 102, pos: "FOH LX", x: 2000, type: "profile", aim: 90,
                    gel: "L201", ch: 2, purpose: "FACE F2", beam: 26),
            Fixture(unit: 201, pos: "LX 1", x: -2000, type: "fresnel", aim: 90,
                    gel: "L132", ch: 11, purpose: "WARM WASH", beam: 45),
            Fixture(unit: 202, pos: "LX 1", x: 2000, type: "fresnel", aim: 90,
                    gel: "L132", ch: 12, purpose: "WARM WASH", beam: 45),
        ]
        doc.zones = [
            Zone(id: "K1", x0: -6000, y0: 3000, x1: 0, y1: 7500),
            Zone(id: "K2", x0: 0, y0: 3000, x1: 6000, y1: 7500),
        ]
        return doc
    }

    static func todayString() -> String {
        // 图签上的日期用固定格式，不依赖 locale。
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yyyy"
        f.locale = Locale(identifier: "en_GB")
        return f.string(from: Date())
    }
}
