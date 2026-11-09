import AppKit
import ApplicationServices

/// 单击 PiP 时把原窗口切到前台：先激活原 app；有辅助功能权限时再用 AX 把那个窗口提到最前。
/// 没有权限时只激活 app，不弹任何授权（辅助功能仍然只有双击功能需要）。
/// AX 调用放在后台，单次请求和整次操作都有超时，目标 app 卡住时不会冻结界面。
enum SourceWindowActivator {
    static let messagingTimeout: TimeInterval = 0.25
    static let totalTimeLimit: TimeInterval = 0.5
    /// AX 窗口位置大小和 CGWindow bounds 比较时允许的误差（点）
    static let tolerance: CGFloat = 2

    @MainActor
    static func bringToFront(pid: pid_t, windowID: CGWindowID, appName: String) {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            Feedback.show("「\(appName)」已经退出")
            return
        }
        _ = app.activate()
        guard Permissions.hasAccessibility, let bounds = WindowLocator.bounds(of: windowID) else { return }
        Task.detached { raiseWindow(pid: pid, bounds: bounds) }
    }

    /// 按位置和大小在原 app 的 AX 窗口里找到原窗口，提到最前并设为主窗口。找不到（如已最小化）就算了。
    nonisolated static func raiseWindow(pid: pid_t, bounds: CGRect) {
        let deadline = Date().addingTimeInterval(totalTimeLimit)
        let app = AXUIElementCreateApplication(pid)
        guard prepare(app, before: deadline) else { return }
        // 有权限时也通过 AX 置前 app：后台 app 发起的 activate 在 macOS 14+ 可能被系统忽略
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        guard prepare(app, before: deadline) else { return }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        for window in windows {
            guard let frame = frame(of: window, before: deadline) else { continue }
            guard abs(frame.minX - bounds.minX) <= tolerance, abs(frame.minY - bounds.minY) <= tolerance,
                  abs(frame.width - bounds.width) <= tolerance, abs(frame.height - bounds.height) <= tolerance
            else { continue }
            guard prepare(window, before: deadline) else { return }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            guard prepare(window, before: deadline) else { return }
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            return
        }
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
