import Foundation
// CGRect/CGSize/CGPoint live in CoreGraphics on macOS (Foundation provides them on Linux).
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Where to put the history panel so it opens near the mouse but stays fully on screen.
///
/// Uses macOS screen coordinates: origin at the bottom-left, y grows upward. A window's
/// frame origin is its bottom-left corner.
public enum PanelPlacement {
    /// - Parameters:
    ///   - size: Panel size.
    ///   - cursor: Mouse location (`NSEvent.mouseLocation`).
    ///   - visibleFrame: The screen area excluding the menu bar and Dock
    ///     (`NSScreen.visibleFrame`) of the screen containing the cursor.
    ///   - offset: Gap between the cursor and the panel's top-left corner.
    /// - Returns: The panel frame. Its top-left sits just below-right of the cursor,
    ///   flipped to the other side of the cursor when there isn't room, and finally clamped
    ///   inside `visibleFrame`.
    public static func frame(size: CGSize, cursor: CGPoint, visibleFrame: CGRect, offset: CGFloat = 8) -> CGRect {
        var x = cursor.x + offset
        var y = cursor.y - offset - size.height        // bottom edge when placed below the cursor

        if x + size.width > visibleFrame.maxX { x = cursor.x - offset - size.width }   // flip left
        if y < visibleFrame.minY { y = cursor.y + offset }                            // flip above

        // Clamp (also handles panels larger than the screen: pin to top-left).
        x = max(visibleFrame.minX, min(x, visibleFrame.maxX - size.width))
        y = min(visibleFrame.maxY - size.height, max(y, visibleFrame.minY))
        if size.height > visibleFrame.height { y = visibleFrame.maxY - size.height }
        if size.width > visibleFrame.width { x = visibleFrame.minX }

        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}
