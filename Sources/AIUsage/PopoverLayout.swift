import Foundation

enum PopoverLayout {
    static func contentSize(in visibleFrame: CGRect) -> CGSize {
        // Reserve space for AppKit's popover chrome as well as the edge margin.
        CGSize(width: min(380, max(1, visibleFrame.width - 48)),
               height: min(500, max(1, visibleFrame.height - 48)))
    }

    static func constrained(_ frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        let safe = visibleFrame.insetBy(dx: 8, dy: 8)
        let size = CGSize(width: min(frame.width, safe.width), height: min(frame.height, safe.height))
        return CGRect(x: min(max(frame.minX, safe.minX), safe.maxX - size.width),
                      y: min(max(frame.minY, safe.minY), safe.maxY - size.height),
                      width: size.width, height: size.height)
    }
}
