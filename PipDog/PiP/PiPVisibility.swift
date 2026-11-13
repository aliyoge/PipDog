import AppKit

/// 判断 PiP 面板此刻是不是真的呈现在用户眼前：先看它在不在当前桌面的窗口列表里
/// （不在就是切到了别的 Space），再用 CGWindowList 的层级看它有没有被别的窗口完全盖住。
///
/// 只关心「自己这块」的可见性；源窗口属于别的 app，抓不抓得到由 ScreenCaptureKit 决定。
/// CGWindowList 的顺序是屏幕上的前后顺序（前 → 后），所以排在我们前面的窗口就是盖住我们的。
@MainActor
enum PiPVisibility {
    /// 面板边缘往里收一点，免得取整误差把「露出半像素」当成可见。
    private static let edgeTolerance: CGFloat = 2

    /// 面板当前是否可见（在活动桌面上、且没有被完全遮挡）。
    static func isVisible(_ window: NSWindow) -> Bool {
        guard window.isVisible, window.windowNumber > 0 else { return false }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return true }
        let number = CGWindowID(window.windowNumber)
        // 不在列表里：当前桌面上没有它（其他 Space、已最小化或隐藏）
        guard let index = list.firstIndex(where: { ($0["kCGWindowNumber"] as? CGWindowID) == number }) else {
            return false
        }
        let me = ProcessInfo.processInfo.processIdentifier
        // 只算盖在我们前面的窗口；自己的窗口（提示浮层、设置窗口）不算遮挡，免得提示一闪就降帧
        let covering = list[..<index].compactMap { dict -> CGRect? in
            guard (dict["kCGWindowOwnerPID"] as? pid_t) != me else { return nil }
            if let alpha = dict["kCGWindowAlpha"] as? Double, alpha <= 0.01 { return nil }
            guard let boundsDict = dict["kCGWindowBounds"] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 1, bounds.height >= 1 else { return nil }
            return bounds
        }
        // 前后顺序和覆盖采样与源窗口共用一套判断：有一点露在外面就算可见
        return !Geometry.isCovered(Geometry.flipped(window.frame), by: covering, tolerance: edgeTolerance)
    }
}
