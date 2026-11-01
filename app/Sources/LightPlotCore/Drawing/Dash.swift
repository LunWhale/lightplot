import Foundation

/// 线型图案（图纸 mm）。
///
/// DXF 里线型是命名资源（`DASHED` / `DASHDOT`），由 CAD 按 `$LTSCALE` 展开；
/// PDF 与画布没有线型概念，只能自己算虚线段。两者必须用**同一组长度**，
/// 否则同一张图在 PDF 与 DXF 里疏密不同。
public enum Dash {
    /// 虚线：用于布景虚框、观众席行线。
    public static let dashed: [Double] = [2.0, 1.2]
    /// 点划线：用于光区边界。
    public static let dashDot: [Double] = [3.0, 1.0, 0.25, 1.0]

    public static func pattern(for layer: String) -> [Double] {
        switch layer {
        case "DASHED":  return dashed
        case "DASHDOT": return dashDot
        default:        return dashed
        }
    }

    /// 按图层规范取图案。
    public static func pattern(layerSpec: Paper.LayerSpec) -> [Double]? {
        switch layerSpec.lineType {
        case "DASHED":  return dashed
        case "DASHDOT": return dashDot
        default:        return nil
        }
    }
}
