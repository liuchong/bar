import Foundation
import CoreGraphics

/// Packs every icon into visible screen regions, skipping the physical camera cutout.
public struct DrawerPlacement: Equatable, Sendable {
    public let index: Int
    public let frame: CGRect
    public init(index: Int, frame: CGRect) { self.index = index; self.frame = frame }
}

public enum DrawerLayout {
    /// The entire row stays below the system bar, including one physical pixel of clearance.
    public static func belowRow(width: CGFloat, screen: CGRect, anchor: CGRect,
                                menuBarBottom: CGFloat, height: CGFloat, row: Int,
                                backingScale: CGFloat, side: ItemSide = .left) -> CGRect {
        let proposedX = side == .left ? anchor.midX - width : anchor.midX
        let x = max(screen.minX + 8, min(proposedX, screen.maxX - width - 8))
        let top = menuBarBottom - 1 / max(1, backingScale) - CGFloat(row) * height
        return CGRect(x: x, y: top - height, width: width, height: height)
    }

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
    /// Opening a collected item does not require relocating it across Bar.
    /// Only accept a complete, visible hit rectangle on the same display and row.
    public static func canInteract(originals: [CGRect], anchor: CGRect, displays: [CGRect]) -> Bool {
        !originals.isEmpty && originals.allSatisfy { frame in
            frame.width > 1 && frame.height > 1 &&
            abs(frame.midY - anchor.midY) < max(frame.height, anchor.height) &&
            !anchor.contains(CGPoint(x: frame.midX, y: frame.midY)) &&
            displays.contains { $0.contains(frame) && $0.contains(anchor) }
        }
    }
}
