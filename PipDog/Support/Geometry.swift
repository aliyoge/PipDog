import AppKit

/// 坐标系换算。
/// - CGWindow bounds、AX 位置、CGEvent.location、SCWindow.frame：全局坐标，原点在主屏左上角，y 向下。
/// - NSScreen、NSWindow、NSEvent.mouseLocation：Cocoa 坐标，原点在主屏左下角，y 向上。
@MainActor
enum Geometry {
    /// 主屏（菜单栏所在屏幕）的高度，两套坐标系以它为翻转轴。
    static var primaryScreenHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// 在两套坐标系之间翻转一个点（双向通用）。
    static func flipped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    /// 在两套坐标系之间翻转一个矩形（双向通用）。
    static func flipped(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// 当前鼠标位置（左上角原点的全局坐标）。
    static var mouseLocationTopLeft: CGPoint { flipped(NSEvent.mouseLocation) }

    /// 和某个矩形（左上角原点的全局坐标）重叠面积最大的屏幕。
    static func screen(containingTopLeftRect rect: CGRect) -> NSScreen? {
        let cocoa = flipped(rect)
        func overlap(_ screen: NSScreen) -> CGFloat {
            let r = screen.frame.intersection(cocoa)
            return r.isNull ? 0 : r.width * r.height
        }
        return NSScreen.screens.filter { overlap($0) > 0 }.max { overlap($0) < overlap($1) }
    }

    /// 鼠标所在的屏幕。
    static var screenUnderMouse: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }

    /// 网格采样判断 `rect` 是不是被 `covering` 里的一堆矩形完全盖住：只要有一个采样点露在外面就不算。
    /// 边缘往里收 `tolerance`，免得取整误差把「露出半像素」当成可见。PiP 面板和源窗口的可见性都用这一套判断。
    nonisolated static func isCovered(_ rect: CGRect, by covering: [CGRect],
                                     gridSize: Int = 5, tolerance: CGFloat = 2) -> Bool {
        guard !covering.isEmpty, gridSize > 0 else { return false }
        let frame = rect.insetBy(dx: tolerance, dy: tolerance)
        guard frame.width > 0, frame.height > 0 else { return false }
        for row in 0..<gridSize {
            for column in 0..<gridSize {
                let point = CGPoint(x: frame.minX + frame.width * (CGFloat(column) + 0.5) / CGFloat(gridSize),
                                    y: frame.minY + frame.height * (CGFloat(row) + 0.5) / CGFloat(gridSize))
                if !covering.contains(where: { $0.contains(point) }) { return false }
            }
        }
        return true
    }
}
