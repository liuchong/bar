import Foundation
import CoreGraphics

/// Packs every icon into visible screen regions, skipping the physical camera cutout.
public struct DrawerPlacement: Equatable, Sendable {
    public let index: Int
    public let frame: CGRect
    public init(index: Int, frame: CGRect) { self.index = index; self.frame = frame }
}

public enum DrawerLayout {
    public static func left(widths: [CGFloat], screen: CGRect, anchor: CGRect,
                            cutout: CGRect?, height: CGFloat) -> [DrawerPlacement] {
        var x = min(anchor.minX, screen.maxX) - 2
        var y = screen.maxY - height
        let padding: CGFloat = 6
        return widths.enumerated().map { index, raw in
            let width = min(max(22, raw), screen.width - padding * 2)
            if let cutout, y + height > cutout.minY, x > cutout.minX, x - width < cutout.maxX {
                x = cutout.minX - 4
            }
            // A physically full row continues below; no icon is put behind an overflow arrow.
            if x - width < screen.minX + padding {
                x = min(anchor.minX - 2, screen.maxX - padding); y -= height
            }
            x -= width
            return DrawerPlacement(index: index, frame: CGRect(x: x, y: y, width: width, height: height))
        }
    }
}

public enum StableMenuBar {
    /// Revealing an original item is safe only when it is on the same row and before the fixed anchor.
    public static func canReveal(originals: [CGRect], anchor: CGRect, displays: [CGRect]) -> Bool {
        !originals.isEmpty && originals.allSatisfy { frame in
            frame.width > 1 && frame.height > 1 && frame.maxX <= anchor.minX + 1 &&
            abs(frame.midY - anchor.midY) < max(frame.height, anchor.height) &&
            displays.contains { $0.contains(frame) }
        }
    }
}
