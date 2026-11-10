import AppKit
import ApplicationServices

/// 单击 PiP 时把原窗口切到前台：用协作激活把前台交给原 app；有辅助功能权限时再用 AX 把那个窗口提到最前。
/// PipDog 是菜单栏 app，点非激活的 PiP 时它不在前台，直接 activate() 在 macOS 14+ 常被忽略，
/// 所以先激活自己（刚收到用户点击），再 yieldActivation 并 activate(from:)，和 SnapshotPreview 还前台的做法一样。
/// 原窗口已在最前时再单击：用 AX 把窗口移到屏幕边上，只留 1 点在屏幕内（不隐藏 app，抓取不停，小窗画面照常更新），
/// 下次单击移回原位。不用 hide()：隐藏 app 会让 ScreenCaptureKit 停掉抓取。
/// 没有权限时只能在 app 不在前台时激活它，移不了窗口，同一 app 的另一个窗口已在最前时也提不起指定窗口。
/// 这里绝不弹授权（辅助功能仍然只有双击功能需要）。
/// AX 调用放在后台，单次请求和整次操作都有超时，目标 app 卡住时不会冻结界面。
enum SourceWindowActivator {
    static let messagingTimeout: TimeInterval = 0.25
    static let totalTimeLimit: TimeInterval = 0.5
    /// AX 窗口位置大小和 CGWindow bounds 比较时允许的误差（点）
    static let tolerance: CGFloat = 2

    /// 被移到屏幕边上的窗口：原来的位置大小（全局左上角坐标）和移过去的 x
    private struct Stash {
        var original: CGRect
        var parkedX: CGFloat
    }

    @MainActor private static var stashed: [CGWindowID: Stash] = [:]

    /// 单击 PiP：窗口被我们移到了屏幕边上 → 移回原位并切到前台；原窗口已经是屏幕上最前面的普通窗口 →
    /// 移到屏幕边上；否则切到前台。按当前状态判断，不记单击次数。
    /// 返回原 app 现在是否处于隐藏状态（PiP 据此显示 / 去掉暂停提示，只有真的隐藏（⌘H）才算）；app 已退出时返回 nil。
    @MainActor
    @discardableResult
    static func toggle(pid: pid_t, windowID: CGWindowID, appName: String) -> Bool? {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            stashed[windowID] = nil
            Feedback.show("「\(appName)」已经退出")
            return nil
        }
        stashed = stashed.filter { WindowLocator.bounds(of: $0.key) != nil } // 已关闭的窗口不再记
        let bounds = WindowLocator.bounds(of: windowID)
        if let stash = stashed[windowID] {
            stashed[windowID] = nil
            // 还在我们放的位置才移回；用户自己挪走了就当普通窗口处理
            if let bounds, abs(bounds.minX - stash.parkedX) <= tolerance {
                restore(pid: pid, windowID: windowID, appName: appName, from: bounds, to: stash.original.origin)
                return app.isHidden
            }
        }
        guard WindowLocator.onScreenWindows().first?.id == windowID, let bounds else {
            return bringToFront(pid: pid, windowID: windowID, appName: appName) ? false : nil
        }
        guard Permissions.hasAccessibility else {
            Feedback.show("要把「\(appName)」移到屏幕旁边并保持画面更新，需要在系统设置里给 PipDog 辅助功能权限")
            return false
        }
        let parked = parkedOrigin(for: bounds)
        let title = WindowLocator.title(of: windowID)
        Task {
            let movedX = await Task.detached { moveWindow(pid: pid, bounds: bounds, title: title, to: parked) }.value
            if let movedX {
                stashed[windowID] = Stash(original: bounds, parkedX: movedX)
            } else {
                Feedback.show("无法移动「\(appName)」的窗口")
            }
        }
        return false
    }

    /// PiP 关闭时：窗口还在屏幕边上的话放回原位（不切前台）。
    @MainActor
    static func restoreIfStashed(pid: pid_t, windowID: CGWindowID) {
        guard let stash = stashed.removeValue(forKey: windowID), Permissions.hasAccessibility,
              let bounds = WindowLocator.bounds(of: windowID), abs(bounds.minX - stash.parkedX) <= tolerance
        else { return }
        let title = WindowLocator.title(of: windowID)
        let origin = stash.original.origin
        Task.detached { _ = moveWindow(pid: pid, bounds: bounds, title: title, to: origin) }
    }

    /// 先把窗口移回原位，再切到前台，这样窗口直接出现在原来的地方。
    @MainActor
    private static func restore(pid: pid_t, windowID: CGWindowID, appName: String, from bounds: CGRect, to origin: CGPoint) {
        let title = WindowLocator.title(of: windowID)
        Task {
            let movedX = await Task.detached { moveWindow(pid: pid, bounds: bounds, title: title, to: origin) }.value
            if movedX == nil { Feedback.show("无法把「\(appName)」的窗口移回原位") }
            bringToFront(pid: pid, windowID: windowID, appName: appName)
        }
    }

    /// 屏幕边上的停放位置（全局左上角坐标，和 AX 位置、CGWindow bounds 一致）：
    /// 移到窗口所在屏幕的右边缘外，只留 1 点在屏幕内（完全移出屏幕有些 app 会停止绘制），y 不变。
    /// 右边紧挨着另一块屏幕时改放左边缘；两边都有屏幕时放到所有屏幕的最右边。
    @MainActor
    private static func parkedOrigin(for bounds: CGRect) -> CGPoint {
        let screens = NSScreen.screens.map { Geometry.flipped($0.frame) } // 转成左上角坐标；x 两套坐标一样
        let screen = Geometry.screen(containingTopLeftRect: bounds).map { Geometry.flipped($0.frame) }
            ?? screens.first ?? bounds
        let rows = bounds.minY..<max(bounds.maxY, bounds.minY + 1)
        func hasScreen(atX x: CGFloat) -> Bool {
            screens.contains { $0.minX <= x && x < $0.maxX && $0.minY < rows.upperBound && rows.lowerBound < $0.maxY }
        }
        if !hasScreen(atX: screen.maxX) { return CGPoint(x: screen.maxX - 1, y: bounds.minY) }
        if !hasScreen(atX: screen.minX - 1) { return CGPoint(x: screen.minX - bounds.width + 1, y: bounds.minY) }
        return CGPoint(x: (screens.map(\.maxX).max() ?? screen.maxX) - 1, y: bounds.minY)
    }

    /// 把原窗口切到前台；返回 false 表示原 app 已经退出。
    @MainActor
    @discardableResult
    static func bringToFront(pid: pid_t, windowID: CGWindowID, appName: String) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            Feedback.show("「\(appName)」已经退出")
            return false
        }
        // 被隐藏（用户按了 ⌘H 等）时先取消隐藏，不依赖 activate 的副作用
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
        guard let window = findWindow(in: app, bounds: bounds, title: title, before: deadline),
              prepare(window, before: deadline) else { return }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        guard prepare(window, before: deadline) else { return }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    /// 把原窗口（按位置大小和标题找）移到 origin（全局左上角坐标），不改大小、不切前台。
    /// 返回移动后读回的 x（系统可能把位置限制在别处）；找不到窗口、被拒绝或位置没变时返回 nil。
    nonisolated static func moveWindow(pid: pid_t, bounds: CGRect, title: String?, to origin: CGPoint) -> CGFloat? {
        let deadline = Date().addingTimeInterval(totalTimeLimit)
        let app = AXUIElementCreateApplication(pid)
        guard let window = findWindow(in: app, bounds: bounds, title: title, before: deadline),
              prepare(window, before: deadline) else { return nil }
        var point = origin
        guard let value = AXValueCreate(.cgPoint, &point),
              AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success,
              let moved = frame(of: window, before: deadline)
        else { return nil }
        let reached = abs(moved.minX - origin.x) <= tolerance
        return reached || abs(moved.minX - bounds.minX) > tolerance ? moved.minX : nil
    }

    /// 在 app 的 AX 窗口里按位置和大小（误差 tolerance）找原窗口；有多个时再用窗口标题区分。
    private nonisolated static func findWindow(in app: AXUIElement, bounds: CGRect, title: String?,
                                               before deadline: Date) -> AXUIElement? {
        guard prepare(app, before: deadline) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        let matches = windows.filter { window in
            guard let frame = frame(of: window, before: deadline) else { return false }
            return abs(frame.minX - bounds.minX) <= tolerance && abs(frame.minY - bounds.minY) <= tolerance
                && abs(frame.width - bounds.width) <= tolerance && abs(frame.height - bounds.height) <= tolerance
        }
        if matches.count > 1, let title, !title.isEmpty,
           let titled = matches.first(where: { string(of: $0, kAXTitleAttribute, before: deadline) == title }) {
            return titled
        }
        return matches.first
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
