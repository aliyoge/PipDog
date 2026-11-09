import AppKit
import ScreenCaptureKit

/// 屏幕上的一个普通窗口（layer 0），bounds 为左上角原点的全局坐标。
struct WindowInfo: Sendable {
    let id: CGWindowID
    let pid: pid_t
    let bounds: CGRect
    let ownerName: String
}

/// 用公开的 CGWindowList / ScreenCaptureKit 接口定位窗口。始终排除 PipDog 自己的窗口。
@MainActor
enum WindowLocator {
    /// 屏幕上可见的普通窗口，按从前到后排列。
    static func onScreenWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        // 字典键直接用字符串（与 kCGWindow* 常量的值相同）
        return list.compactMap { dict -> WindowInfo? in
            guard (dict["kCGWindowLayer"] as? Int) == 0,
                  let id = dict["kCGWindowNumber"] as? CGWindowID,
                  let pid = dict["kCGWindowOwnerPID"] as? pid_t, pid != me,
                  let boundsDict = dict["kCGWindowBounds"] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 40, bounds.height >= 40
            else { return nil }
            if let alpha = dict["kCGWindowAlpha"] as? Double, alpha <= 0 { return nil }
            return WindowInfo(id: id, pid: pid, bounds: bounds,
                              ownerName: dict["kCGWindowOwnerName"] as? String ?? "?")
        }
    }

    /// 当前聚焦的窗口：最前面 app 的第一个普通窗口；如果最前面是 PipDog 自己，就取屏幕上最前面的别人的窗口。
    static func focusedWindow() -> WindowInfo? {
        let windows = onScreenWindows()
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return windows.first { $0.pid == pid } ?? windows.first
    }

    /// 包含某点（左上角原点的全局坐标）的最上层普通窗口。
    static func window(at point: CGPoint) -> WindowInfo? {
        onScreenWindows().first { $0.bounds.contains(point) }
    }

    /// 根据 CGWindowID 找到对应的 SCWindow。
    static func shareableWindow(for id: CGWindowID) async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return content.windows.first { $0.windowID == id }
    }
}
