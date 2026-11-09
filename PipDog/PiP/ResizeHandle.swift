import AppKit

/// PiP 面板右下角的缩放手柄：按面板的 contentAspectRatio 等比缩放，左上角固定，不会超出所在屏幕的可见区域。
/// 无边框窗口在系统层面的边缘缩放不可靠，所以自己处理拖动。
final class ResizeHandle: NSView {
    static let size: CGFloat = 18
    private let minimumWidth: CGFloat = 80
    private var startFrame = NSRect.zero
    private var startMouse = NSPoint.zero

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        let cursor: NSCursor
        if #available(macOS 15.0, *) {
            cursor = .frameResize(position: .bottomRight, directions: .all)
        } else {
            cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        startFrame = window?.frame ?? .zero
        startMouse = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, startFrame.width > 0 else { return }
        let mouse = NSEvent.mouseLocation
        let aspect = window.contentAspectRatio
        let ratio = aspect.width > 0 && aspect.height > 0 ? aspect.height / aspect.width : startFrame.height / startFrame.width
        // 向右或向下拖都算放大，取变化更大的那个方向
        let widthFromX = startFrame.width + (mouse.x - startMouse.x)
        let widthFromY = (startFrame.height + (startMouse.y - mouse.y)) / ratio
        var width = max(minimumWidth, max(widthFromX, widthFromY))
        // 左上角固定：右边不超过屏幕可见区域的右边，底边不低于可见区域的底边
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            let maxWidth = min(visible.maxX - startFrame.minX, (startFrame.maxY - visible.minY) / ratio)
            width = min(width, max(maxWidth, minimumWidth))
        }
        let height = width * ratio
        window.setFrame(NSRect(x: startFrame.minX, y: startFrame.maxY - height, width: width, height: height), display: true)
    }

    override func mouseUp(with event: NSEvent) {
        if let panel = window as? PiPPanel { panel.contentSizeDidSettle() } else { window?.invalidateShadow() }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.55).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        for inset in [5.0, 10.0] {
            path.move(to: NSPoint(x: bounds.maxX - 4, y: bounds.minY + 4 + inset))
            path.line(to: NSPoint(x: bounds.maxX - 4 - inset, y: bounds.minY + 4))
        }
        path.stroke()
    }
}
