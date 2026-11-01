import SwiftUI
import LightPlotCore

/// 页面设置。
///
/// 独立面板（macOS 上的 sheet），不是塞在侧栏里的两个下拉 ——
/// 因为"换纸"是一次**版面决策**：它同时改变可用绘图区、
/// 能装下多大的场地、以及图签/图例的排版。
/// 用户需要一次看到所有这些后果，而不是改完再回头发现图溢出。
///
/// 默认 **A1 横向**（舞台平面图的标准幅面）。
public struct PageSetupPanel: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    /// 面板里暂存的设置 —— 点"应用"才写回文档。
    /// 这样用户可以试几种尺寸，看到"能装多大"再决定，不产生一串撤销点。
    @State private var standard: PaperSize.PaperStandard
    @State private var orientation: PaperOrientation
    @State private var scale: Double
    @State private var applied = false

    public init(model: EditorModel) {
        self.model = model
        let paper = model.state.layout.paper
        _standard = State(initialValue: paper.standard ?? .a1)
        _orientation = State(initialValue: paper.orientation)
        _scale = State(initialValue: model.state.layout.scaleDenominator)
    }

    private var candidatePaper: PaperSize {
        PaperSize(standard: standard, orientation: orientation)
    }

    private var candidateLayout: SheetLayout {
        SheetLayout.fitted(to: model.state.doc.contentBounds,
                           paper: candidatePaper,
                           scaleDenominator: scale)
    }

    private var content: Rect { model.state.doc.contentBounds }

    private var fits: Bool { candidateLayout.contentFits(content) }

    private var capacity: Vec2 {
        SheetLayout.capacity(paper: candidatePaper, scale: scale)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            HStack(alignment: .top, spacing: 0) {
                form
                    .frame(width: 330)
                Divider()
                preview
                    .frame(maxWidth: .infinity)
            }

            Divider()
            footer
        }
        .frame(width: 720, height: 470)
        .background(.background)
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.badge.gearshape")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.t("Page Setup"))
                    .font(.system(size: 15, weight: .semibold))
                Text(L10n.t("Paper size and scale for this sheet"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: 表单

    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 幅面
            VStack(alignment: .leading, spacing: 6) {
                label("Paper size")
                Picker("", selection: $standard) {
                    ForEach(PaperSize.PaperStandard.allCases, id: \.self) { s in
                        Text(s.name).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(L10n.t("Default is A1 — the standard sheet for a lighting plan."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // 朝向
            VStack(alignment: .leading, spacing: 6) {
                label("Orientation")
                Picker("", selection: $orientation) {
                    ForEach(PaperOrientation.allCases, id: \.self) { o in
                        Text(L10n.t(o.title)).tag(o)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // 比例
            VStack(alignment: .leading, spacing: 6) {
                label("Scale")
                Picker("", selection: $scale) {
                    Text("1:20").tag(20.0)
                    Text("1:25").tag(25.0)
                    Text("1:50").tag(50.0)
                    Text("1:100").tag(100.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // 结果预览（数字，不是形容词）
            VStack(alignment: .leading, spacing: 5) {
                label("Result")
                stat("Paper", candidatePaper.displayName
                     + String(format: "  %.0f x %.0f mm",
                              candidatePaper.widthMM, candidatePaper.heightMM))
                stat("Drawing area",
                     String(format: "%.0f x %.0f mm",
                            SheetLayout.planArea(paper: candidatePaper).width,
                            SheetLayout.planArea(paper: candidatePaper).height))
                stat("Holds up to",
                     String(format: "%.1f x %.1f m", capacity.x / 1000, capacity.y / 1000))
                stat("Your content",
                     String(format: "%.1f x %.1f m", content.width / 1000, content.height / 1000))
            }

            if !fits {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(L10n.t("Content does not fit. The sheet will print a notice instead of the plan."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(18)
    }

    // MARK: 预览

    /// 纸面比例预览 —— 让用户直接看到"图在纸上占多少"。
    private var preview: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                let inset: CGFloat = 28
                let availW = geo.size.width - inset * 2
                let availH = geo.size.height - inset * 2
                let k = min(availW / candidatePaper.widthMM,
                            availH / candidatePaper.heightMM)
                let w = candidatePaper.widthMM * k
                let h = candidatePaper.heightMM * k

                ZStack {
                    // 纸
                    Rectangle()
                        .fill(.white)
                        .frame(width: w, height: h)
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                        .overlay(Rectangle().strokeBorder(.black.opacity(0.18)))

                    // 内框
                    Rectangle()
                        .strokeBorder(.black.opacity(0.35), lineWidth: 1)
                        .frame(width: w * (1 - 40 / candidatePaper.widthMM),
                               height: h * (1 - 40 / candidatePaper.heightMM))

                    // 绘图区（左侧实线框）
                    let area = SheetLayout.planArea(paper: candidatePaper)
                    Rectangle()
                        .fill(Color.accentColor.opacity(fits ? 0.10 : 0.16))
                        .frame(width: area.width * k, height: area.height * k)
                        .offset(x: (area.x0 * k) - w / 2 + (area.width * k) / 2,
                                y: -((area.y0 * k) - h / 2 + (area.height * k) / 2))
                        .overlay(
                            Rectangle()
                                .strokeBorder(fits ? Color.accentColor.opacity(0.5)
                                                   : Color.orange,
                                              style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                                .frame(width: area.width * k, height: area.height * k)
                                .offset(x: (area.x0 * k) - w / 2 + (area.width * k) / 2,
                                        y: -((area.y0 * k) - h / 2 + (area.height * k) / 2))
                        )

                    // 信息栏（右侧灰块）
                    let infoX = SheetLayout.infoColumnX(for: candidatePaper)
                    let infoW = SheetLayout.infoColumnWidth(for: candidatePaper)
                    Rectangle()
                        .fill(.black.opacity(0.10))
                        .frame(width: infoW * k,
                               height: h * (1 - 40 / candidatePaper.heightMM))
                        .offset(x: (infoX - candidatePaper.widthMM / 2) * k + (infoW * k) / 2,
                                y: 0)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }

            Text(fits ? L10n.t("Plan fits inside the drawing area")
                      : "Plan would overflow — pick a bigger sheet or smaller scale")
                .font(.caption2)
                .foregroundStyle(fits ? Color.secondary : Color.orange)
        }
        .padding(18)
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 10) {
            if applied {
                Label("Applied", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
            Spacer()
            Button(L10n.t("Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button(applied ? L10n.t("Done") : L10n.t("Apply")) {
                apply()
                if applied { dismiss() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isUnchanged && !applied)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var isUnchanged: Bool {
        let p = model.state.layout.paper
        return p == candidatePaper && model.state.layout.scaleDenominator == scale
    }

    /// 一次点击压**一个**撤销点 —— 不是先改纸再改比例两个。
    private func apply() {
        model.dispatch(batch: [
            .setPaper(candidatePaper),
            .setScale(scale),
        ])
        applied = true
    }

    // MARK: 小部件

    private func label(_ text: String) -> some View {
        Text(L10n.t(text))
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }

    private func stat(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L10n.t(name))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.caption.monospacedDigit())
                .textSelection(.enabled)
        }
    }
}
