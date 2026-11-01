import Testing
import Foundation
@testable import LightPlotCore

@Suite("Text metrics")
struct TextMetricsTests {

    @Test("Width is advance × cap / capToEm")
    func monospaceWidth() {
        let m = MonospacedMeasurement(advancePerCharacterEM: 0.5, capToEm: 0.7163)
        // 3 字 × 0.5 em × (4mm / 0.7163) = 8.3764mm
        let w = m.widthMM("ABC", capMM: 4)
        #expect(abs(w - 3 * 0.5 * 4 / 0.7163) < 1e-9)
        #expect(m.widthMM("", capMM: 4) == 0)
    }

    @Test("em and cap convert both ways")
    func unitConversion() {
        let m = MonospacedMeasurement(capToEm: 0.7163)
        let em = m.emSize(forCapMM: 3.04)
        #expect(abs(em - 3.04 / 0.7163) < 1e-12)
        #expect(abs(m.capMM(forEmSize: em) - 3.04) < 1e-12)
    }

    /// 这条测试守的是"雷霆大文字"那个 bug：
    /// 把 em 当 cap 用会让全图文字放大 1.40 倍。
    @Test("Mixing up em and cap would inflate text by 1.4×")
    func emCapTrap() {
        let m = MonospacedMeasurement(capToEm: 0.7163)
        let cap: Double = 3.04
        let wrong = cap                    // 当成 em 直接写
        let right = m.emSize(forCapMM: cap)
        #expect(abs(right / wrong - 1 / 0.7163) < 1e-9)
        #expect(right / wrong > 1.39)
    }

    @Test("Fitting shrinks a too-long string and leaves a short one alone")
    func fitting() {
        let m = MonospacedMeasurement(advancePerCharacterEM: 0.5, capToEm: 0.7163)
        let cap: Double = 4
        #expect(m.fitCapMM("AB", capMM: cap, maxWidthMM: 100) == cap)

        // 能塞下时必须塞下
        let long = String(repeating: "A", count: 20)
        let fitted = m.fitCapMM(long, capMM: cap, maxWidthMM: 50)
        #expect(fitted < cap)
        #expect(m.widthMM(long, capMM: fitted) <= 50 + 1e-6)
        #expect(fitted >= 1.6)

        // 塞不下时停在可读下限，而不是缩到看不见。
        // 这是设计决定：图签宁可截断/换行，也不出 0.4mm 的不可读文字。
        let absurd = String(repeating: "A", count: 400)
        let floored = m.fitCapMM(absurd, capMM: cap, maxWidthMM: 50, minCapMM: 1.6)
        #expect(floored == 1.6)
        #expect(m.widthMM(absurd, capMM: floored) > 50)
    }

    @Test("Text box honours alignment")
    func textBox() {
        let m = MonospacedMeasurement(advancePerCharacterEM: 0.5, capToEm: 0.7163)
        let cap: Double = 4
        let w = m.widthMM("ABCD", capMM: cap)
        let p = Vec2(100, 50)

        let center = m.textBox("ABCD", at: p, capMM: cap, align: .center)
        #expect(abs(center.center.x - 100) < 1e-9)

        let left = m.textBox("ABCD", at: p, capMM: cap, align: .left)
        #expect(abs(left.x0 - 100) < 1e-9)
        #expect(abs(left.width - w) < 1e-9)

        let right = m.textBox("ABCD", at: p, capMM: cap, align: .right)
        #expect(abs(right.x1 - 100) < 1e-9)

        // 垂直按 cap 居中
        #expect(abs(center.center.y - 50) < 1e-9)
        #expect(abs(center.height - cap) < 1e-9)
    }

    @Test("Rotated text swaps its box dimensions")
    func rotatedBox() {
        let m = MonospacedMeasurement(advancePerCharacterEM: 0.5, capToEm: 0.7163)
        let cap: Double = 4
        let w = m.widthMM("ABCDEFGH", capMM: cap)
        let box = m.textBox("ABCDEFGH", at: .zero, capMM: cap, rotationDegrees: 90)
        #expect(abs(box.width - cap) < 1e-9)
        #expect(abs(box.height - w) < 1e-9)
    }

    @Test("The real font reports a sane cap/em ratio")
    func realFont() {
        let m = FontLibrary.regular
        // Arial 0.7163；Helvetica ≈ 0.717；任何常见 grotesque 都在 0.66–0.76。
        // 超出这个范围说明字体解析错了（例如静默拿到了 symbol 字体）。
        #expect(m.capToEm > 0.60 && m.capToEm < 0.78, "capToEm=\(m.capToEm) for \(m.fontIdentifier)")
        #expect(m.widthMM("A", capMM: 4) > 1.0)
        #expect(m.widthMM("AAAA", capMM: 4) > m.widthMM("A", capMM: 4) * 3.5)
        #expect(m.fontIdentifier.isEmpty == false)
    }

    @Test("Wider glyphs measure wider than narrow ones")
    func glyphWidths() {
        let m = FontLibrary.regular
        #expect(m.widthMM("W", capMM: 4) > m.widthMM("I", capMM: 4))
        #expect(m.widthMM("1111", capMM: 4) < m.widthMM("8888", capMM: 4) * 1.2)
    }
}
