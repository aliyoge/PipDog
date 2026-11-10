import AppKit
import ApplicationServices

/// 单击 PiP 时把原窗口切到前台：用协作激活把前台交给原 app；有辅助功能权限时再用 AX 把那个窗口提到最前。
/// PipDog 是菜单栏 app，点非激活的 PiP 时它不在前台，直接 activate() 在 macOS 14+ 常被忽略，
/// 所以先激活自己（刚收到用户点击），再 yieldActivation 并 activate(from:)，和 SnapshotPreview 还前台的做法一样。
/// 没有权限时只能隐藏 / 显示 app、在它不在前台时激活它；同一 app 的另一个窗口已在最前时，提不起指定窗口。
/// 这里绝不弹授权（辅助功能仍然只有双击功能需要）。
/// AX 调用放在后台，单次请求和整次操作都有超时，目标 app 卡住时不会冻结界面。
enum SourceWindowActivator {
    static let messagingTimeout: TimeInterval = 0.25
    static let totalTimeLimit: TimeInterval = 0.5
    /// AX 窗口位置大小和 CGWindow bounds 比较时允许的误差（点）
    static let tolerance: CGFloat = 2

    /// 单击 PiP：原窗口已经是屏幕上最前面的普通窗口时隐藏原 app（同 ⌘H，该 app 的所有窗口一起隐藏），
    /// 否则把原窗口切到前台。按当前窗口顺序判断，不记单击次数：用户自己切走后再单击会重新显示。
    /// 返回原 app 现在是否处于隐藏状态（PiP 据此立即显示 / 去掉暂停提示）；app 已退出或隐藏失败时返回 nil。
    @MainActor
    @discardableResult
    static func toggle(pid: pid_t, windowID: CGWindowID, appName: String) -> Bool? {
        guard WindowLocator.onScreenWindows().first?.id == windowID else {
            return bringToFront(pid: pid, windowID: windowID, appName: appName) ? false : nil
        }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            Feedback.show("「\(appName)」已经退出")
            return nil
        }
        guard app.hide() else {
            Feedback.show("无法隐藏「\(appName)」")
            return nil
        }
        return true
    }

    /// 把原窗口切到前台；返回 false 表示原 app 已经退出。
    @MainActor
    @discardableResult
    static func bringToFront(pid: pid_t, windowID: CGWindowID, appName: String) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            Feedback.show("「\(appName)」已经退出")
            return false
        }
        // 被隐藏（⌘H 或上一次单击）时先取消隐藏，不依赖 activate 的副作用
        if app.isHidden, !app.unhide() { Feedback.show("无法显示「\(appName)」") }
        let hasAccessibility = Permissions.hasAccessibility
        if NSApp.isActive || !app.isActive {
            if !NSApp.isActive { NSApp.activate() }
            NSApp.yieldActivation(to: app)
            _ = app.activate(from: .current)
        } else if !hasAccessibility {
            // 原 app 已在前台（用户在它的另一个窗口里）：没有辅助功能就提不起指定窗口，只提示，不请求权限
            Feedback.show("「\(appName)」已在前台；要切到这个窗口，需要在系统设置里给 PipDog 辅助功能权限")
        }
        guard hasAccessibility, let bounds = WindowLocator.bounds(of: windowID) else { return true }
        let title = WindowLocator.title(of: windowID)
        Task.detached { raiseWindow(pid: pid, bounds: bounds, title: title) }
        return true
    }

    /// 按位置和大小在原 app 的 AX 窗口里找到原窗口，提到最前并设为主窗口。找不到（如已最小化）就算了。
    /// 公开 API 拿不到 AX 窗口对应的 CGWindowID：位置大小相同的窗口有多个时，再用窗口标题区分。
    nonisolated static func raiseWindow(pid: pid_t, bounds: CGRect, title: String?) {
        let deadline = Date().addingTimeInterval(totalTimeLimit)
        let app = AXUIElementCreateApplication(pid)
        guard prepare(app, before: deadline) else { return }
        // 有权限时也通过 AX 置前 app：后台 app 发起的 activate 在 macOS 14+ 可能被系统忽略
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        guard prepare(app, before: deadline) else { return }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        let matches = windows.filter { window in
            guard let frame = frame(of: window, before: deadline) else { return false }
            return abs(frame.minX - bounds.minX) <= tolerance && abs(frame.minY - bounds.minY) <= tolerance
                && abs(frame.width - bounds.width) <= tolerance && abs(frame.height - bounds.height) <= tolerance
        }
        var target = matches.first
        if matches.count > 1, let title, !title.isEmpty,
           let titled = matches.first(where: { string(of: $0, kAXTitleAttribute, before: deadline) == title }) {
            target = titled
        }
        guard let window = target, prepare(window, before: deadline) else { return }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        guard prepare(window, before: deadline) else { return }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    private nonisolated static func string(of element: AXUIElement, _ name: String, before deadline: Date) -> String? {
        guard prepare(element, before: deadline) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// 时间还够的话，把这个元素的请求超时设成剩余时间和单次上限中较小的那个。
    private nonisolated static func prepare(_ element: AXUIElement, before deadline: Date) -> Bool {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining >= 0.01 else { return false }
        AXUIElementSetMessagingTimeout(element, Float(min(remaining, messagingTimeout)))
        return true
    }

    private nonisolated static func frame(of element: AXUIElement, before deadline: Date) -> CGRect? {
        func value(_ name: String) -> AXValue? {
            guard prepare(element, before: deadline) else { return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value,
                  CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            return unsafeDowncast(value, to: AXValue.self)
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let position = value(kAXPositionAttribute), AXValueGetValue(position, .cgPoint, &origin),
              let sizeValue = value(kAXSizeAttribute), AXValueGetValue(sizeValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
