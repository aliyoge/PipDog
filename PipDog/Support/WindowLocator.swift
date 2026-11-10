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
    enum FocusedWindow {
        case found(WindowInfo)
        /// 最前面的 app 没有可 PiP 的窗口
        case noWindow(appName: String)
        case nothing
    }

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
                  let bounds = bounds(from: dict),
                  bounds.width >= 40, bounds.height >= 40
            else { return nil }
            if let alpha = dict["kCGWindowAlpha"] as? Double, alpha <= 0 { return nil }
            return WindowInfo(id: id, pid: pid, bounds: bounds,
                              ownerName: dict["kCGWindowOwnerName"] as? String ?? "?")
        }
    }

    /// 最前面 app 的第一个普通窗口。最前面是 PipDog 自己（例如设置窗口打开时）就取屏幕上最前面的别人的窗口。
    static func focusedWindow() -> FocusedWindow {
        let windows = onScreenWindows()
        guard let app = NSWorkspace.shared.frontmostApplication, app != NSRunningApplication.current else {
            return windows.first.map(FocusedWindow.found) ?? .nothing
        }
        if let window = windows.first(where: { $0.pid == app.processIdentifier }) { return .found(window) }
        return .noWindow(appName: app.localizedName ?? "最前面的 app")
    }

    /// 包含某点（左上角原点的全局坐标）的最上层普通窗口。
    static func window(at point: CGPoint) -> WindowInfo? {
        onScreenWindows().first { $0.bounds.contains(point) }
    }

    /// 某个窗口当前的位置和大小（包括最小化或在别的 Space 上的窗口）；窗口已关闭时为 nil。
    /// 不绑定主线程：移动窗口后在后台确认原窗口是否到位。
    nonisolated static func bounds(of id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let dict = list.first(where: { ($0["kCGWindowNumber"] as? CGWindowID) == id })
        else { return nil }
        return bounds(from: dict)
    }

    /// 窗口是不是在当前桌面上显示（kCGWindowIsOnscreen：最小化、在别的桌面（Space）、所属 app 隐藏时为 false）；
    /// 窗口已不存在时为 nil。移到屏幕边上的窗口仍算显示。
    static func isOnScreen(_ id: CGWindowID) -> Bool? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let dict = list.first(where: { ($0["kCGWindowNumber"] as? CGWindowID) == id })
        else { return nil }
        return dict["kCGWindowIsOnscreen"] as? Bool ?? false
    }

    /// 某个窗口的标题（kCGWindowName，有屏幕录制权限时才有）；没有时为 nil。
    static func title(of id: CGWindowID) -> String? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let dict = list.first(where: { ($0["kCGWindowNumber"] as? CGWindowID) == id })
        else { return nil }
        return dict["kCGWindowName"] as? String
    }

    /// 根据 CGWindowID 找到对应的 SCWindow。
    static func shareableWindow(for id: CGWindowID) async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return content.windows.first { $0.windowID == id }
    }

    private nonisolated static func bounds(from dict: [String: Any]) -> CGRect? {
        guard let boundsDict = dict["kCGWindowBounds"] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
    }
}
