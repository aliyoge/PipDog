import AppKit

/// 坐标系换算。
/// - CGWindow bounds、AX 位置、SCWindow.frame：全局坐标，原点在主屏左上角，y 向下。
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
}
