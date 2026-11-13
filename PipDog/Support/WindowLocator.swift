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
    /// 子窗口 / 浮层 / 内部 surface 用「layer 0 + 正常 app + 正常尺寸」排除：规则照搬参照实现
    /// my-window-pip 的 `ShareableContentStore.isCandidate`，不额外发明几何规则（比如和父窗口重合度）。
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
                  isCandidateWindow(bounds: bounds, pid: pid, title: dict["kCGWindowName"] as? String)
            else { return nil }
            if let alpha = dict["kCGWindowAlpha"] as? Double, alpha <= 0 { return nil }
            return WindowInfo(id: id, pid: pid, bounds: bounds,
                              ownerName: dict["kCGWindowOwnerName"] as? String ?? "?")
        }
    }

    /// 能当 PiP 目标的窗口最小边长（点）
    static let minimumWindowSide: CGFloat = 80
    /// 没有标题的窗口至少要有这么大（点²）才当成主窗口：小的无标题窗口多半是内部浮层
    static let minimumUntitledArea: CGFloat = 200 * 200

    /// 像「用户眼里的主窗口」：属于正在运行、没隐藏的普通 app，尺寸正常。
    /// 标题要屏幕录制权限才拿得到（没权限时都是空），所以只对没有标题的情况加尺寸/类型要求：
    /// 菜单栏 app（accessory）和未知类型必须有标题才认得出来，Dock 图标这类内部窗口（prohibited）一律不要。
    private static func isCandidateWindow(bounds: CGRect, pid: pid_t, title: String?) -> Bool {
        guard bounds.width >= minimumWindowSide, bounds.height >= minimumWindowSide else { return false }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated, !app.isHidden else { return false }
        switch app.activationPolicy {
        case .regular:
            break
        case .accessory:
            // 菜单栏 app 的窗口：要有标题才认得出来（避免 Dock 图标、浮层这类内部窗口）
            guard let title, !title.isEmpty else { return false }
        case .prohibited:
            return false
        @unknown default:
            guard let title, !title.isEmpty else { return false }
        }
        if title?.isEmpty ?? true, bounds.width * bounds.height < minimumUntitledArea { return false }
        return true
    }

    /// 最前面 app 的第一个普通窗口。最前面是 PipDog 自己（例如设置窗口打开时）就取屏幕上最前面的别人的窗口。
    static func focusedWindow() -> FocusedWindow {
        let windows = onScreenWindows()
        guard let app = NSWorkspace.shared.frontmostApplication, app != NSRunningApplication.current else {
            return windows.first.map(FocusedWindow.found) ?? .nothing
        }
        if let window = windows.first(where: { $0.pid == app.processIdentifier }) { return .found(window) }
        return .noWindow(appName: app.localizedName ?? String(localized: "The frontmost app"))
    }

    /// 包含某点（左上角原点的全局坐标）的最上层普通窗口。
    static func window(at point: CGPoint) -> WindowInfo? {
        onScreenWindows().first { $0.bounds.contains(point) }
    }

    /// 某个窗口当前的位置大小、是否在当前桌面上，以及标题。只查一次窗口列表（每秒的监视用）。
    /// 窗口已经不在窗口列表里时为 nil。
    struct WindowSnapshot: Sendable {
        let bounds: CGRect
        let isOnScreen: Bool
        let title: String?
    }

    nonisolated static func snapshot(of id: CGWindowID) -> WindowSnapshot? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let dict = list.first(where: { ($0["kCGWindowNumber"] as? CGWindowID) == id }),
              let bounds = bounds(from: dict)
        else { return nil }
        return WindowSnapshot(bounds: bounds, isOnScreen: dict["kCGWindowIsOnscreen"] as? Bool ?? false,
                              title: dict["kCGWindowName"] as? String)
    }

    /// 某个窗口当前的位置和大小（包括最小化或在别的 Space 上的窗口）；窗口已关闭时为 nil。
    /// 不绑定主线程：移动窗口后在后台确认原窗口是否到位。
    nonisolated static func bounds(of id: CGWindowID) -> CGRect? {
        snapshot(of: id)?.bounds
    }

    /// 窗口是不是在当前桌面上显示（kCGWindowIsOnscreen：最小化、在别的桌面（Space）、所属 app 隐藏时为 false）；
    /// 窗口已不存在时为 nil。移到屏幕边上的窗口仍算显示。
    static func isOnScreen(_ id: CGWindowID) -> Bool? {
        snapshot(of: id)?.isOnScreen
    }

    /// 某个窗口的标题（kCGWindowName，有屏幕录制权限时才有）；没有时为 nil。
    static func title(of id: CGWindowID) -> String? {
        snapshot(of: id)?.title
    }

    /// 源窗口此刻是不是真的看得见：在当前桌面上（不在别的 Space、没最小化、app 没隐藏），
    /// 且没有被其他窗口完全盖住。只给 Chromium 停帧提示用（画面已经停住时才每秒查一次），不在热路径上。
    static func isFullyVisible(_ id: CGWindowID) -> Bool? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        // 不在当前桌面的窗口列表里：别的 Space、最小化了，或所属 app 被隐藏
        guard let index = list.firstIndex(where: { ($0["kCGWindowNumber"] as? CGWindowID) == id }) else {
            return false
        }
        guard let rect = bounds(from: list[index]) else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        // 排在我们前面的窗口就是盖住我们的；自己的窗口（提示浮层、设置窗口）不算
        let covering = list[..<index].compactMap { dict -> CGRect? in
            guard (dict["kCGWindowOwnerPID"] as? pid_t) != me else { return nil }
            if let alpha = dict["kCGWindowAlpha"] as? Double, alpha <= 0.01 { return nil }
            guard let rect = bounds(from: dict), rect.width >= 1, rect.height >= 1 else { return nil }
            return rect
        }
        return !Geometry.isCovered(rect, by: covering)
    }

    /// 根据 CGWindowID 找到对应的 SCWindow。只接受 layer 0 的普通窗口：子窗口/浮层不能当抓取目标。
    static func shareableWindow(for id: CGWindowID) async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return content.windows.first { $0.windowID == id && $0.windowLayer == 0 }
    }

    /// 某个 app 现在可捕获的普通窗口（layer 0）：源 app 重启后按它找原窗口。
    static func shareableWindows(forBundleID bundleID: String) async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return content.windows.filter {
            $0.windowLayer == 0 && $0.owningApplication?.bundleIdentifier == bundleID
        }
    }

    private nonisolated static func bounds(from dict: [String: Any]) -> CGRect? {
        guard let boundsDict = dict["kCGWindowBounds"] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
    }
}
