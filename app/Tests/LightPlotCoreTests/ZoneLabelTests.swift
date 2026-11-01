import Testing
import Foundation
@testable import LightPlotCore

/// 表演区的名字必须完整落在**该区自己的矩形内**。
///
/// 光区边界是点划线。标签若压在边界上，字母会被线条切断 ——
/// 这类问题在缩略图里看不出来，放大才明显，而且不产生"文字互相重叠"，
/// 所以文本碰撞检查抓不到它（线不是文字）。
///
/// 判据写成几何断言：标签的文字框必须被分区矩形含住。
@Suite("Zone labels")
struct ZoneLabelTests {

    @Test("Every zone label sits fully inside its own zone rectangle")
    func labelsInsideZones() throws {
        var doc = try DocumentCodec.decodeYAML(Data(contentsOf: TestData.rigYAML))
        _ = GelLibrary.fillMissingColours(in: &doc)

        for paper in [PaperSize.a1, .a0, .a2] {
            for scale in [25.0, 50] {
                let sheet = PlanSheet(fitting: doc, paper: paper, scale: scale,
                                      lightingState: nil)
                guard sheet.contentFitsSheet else { continue }

                for zone in doc.zones {
                    let zoneRect = sheet.layout.sheetRect(forDocumentRect: zone.rect)
                    guard let label = sheet.ops.first(where: { op in
                        if case .text(let t) = op { return t.layer == "ZONE" }
                        return false
                    }).flatMap({ op -> TextOp? in
                        if case .text(let t) = op, t.string == zone.id { return t }
                        return nil
                    }) else { continue }

                    let box = label.family.measuring.textBox(
                        label.string, at: label.origin, capMM: label.capMM,
                        align: label.align, rotationDegrees: label.rotationDegrees)

                    let label2 = "\(paper.name)@1:\(Int(scale)) zone \(zone.id)"
                    // 0.2mm 容差：边界线本身有宽度
                    #expect(box.x0 >= zoneRect.x0 - 0.2, "\(label2): overflows left")
                    #expect(box.x1 <= zoneRect.x1 + 0.2, "\(label2): overflows right")
                    #expect(box.y0 >= zoneRect.y0 - 0.2, "\(label2): overflows bottom")
                    #expect(box.y1 <= zoneRect.y1 + 0.2, "\(label2): overflows top")
                }
            }
        }
    }
}
