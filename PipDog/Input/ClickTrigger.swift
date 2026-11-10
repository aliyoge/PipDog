import AppKit
import CoreGraphics

/// 监听全局「修饰键 + 双击」，触发区域 PiP。回调参数是左上角原点的全局坐标。
/// - 功能关闭时什么都不装。
/// - 有辅助功能权限时用 ClickTap（独立线程上的 CGEventTap）：修饰键匹配时，
///   把触发用的第二次按下和对应的松开吞掉，目标 app 只收到第一次单击。
/// - 没有权限时退回 NSEvent 全局监听（只能旁观，双击仍会传给目标 app）。
/// - 功能开启期间每秒检查一次权限：授权后切到 tap，权限被撤销就拆掉 tap 退回旁观。
@MainActor
final class ClickTrigger {
    var onTrigger: ((CGPoint) -> Void)?

    private var isRunning = false
    private var enabled = false
    private var modifiers: NSEvent.ModifierFlags = []
    private var tap: ClickTap?
    private var fallbackMonitor: Any?
    private var maintenanceTimer: Timer?
    private var windowObservers: [NSObjectProtocol] = []
    private var rectsRefreshScheduled = false
    private var didGuideAccessibility = false
    private var waitingForAccessibility = false
    private var didAnnounceAccessibility = false

    func start(config: ShortcutConfig) {
        apply(config)
        isRunning = true
        refresh()
    }

    /// 设置变化时调用（开关、修饰键）。
    func apply(_ config: ShortcutConfig) {
        let justEnabled = isRunning && !enabled && config.clickEnabled
        enabled = config.clickEnabled
        modifiers = config.clickModifiers
        tap?.setConfig(enabled: enabled, modifiers: Self.eventFlags(from: modifiers))
        refresh()
        if justEnabled, !Permissions.hasAccessibility {
            didGuideAccessibility = true
            Permissions.showAlert(.accessibility)
        }
    }

    func stop() {
        isRunning = false
        refresh()
    }

    // MARK: - 状态切换

    /// 按「是否启用」和当前权限决定用 tap、旁观监听，还是什么都不装。
    private func refresh() {
        guard isRunning, enabled else {
            waitingForAccessibility = false
            removeTap()
            removeFallbackMonitor()
            maintenanceTimer?.invalidate()
            maintenanceTimer = nil
            return
        }
        startMaintenanceTimer()
        if Permissions.hasAccessibility {
            if tap == nil { installTap() }
            if tap != nil {
                removeFallbackMonitor()
                if waitingForAccessibility, !didAnnounceAccessibility {
                    didAnnounceAccessibility = true
                    Feedback.show("辅助功能已授权，\(KeyCodeNames.symbols(for: modifiers)) + 双击可以用了")
                }
                waitingForAccessibility = false
                return
            }
        } else {
            waitingForAccessibility = true
            removeTap()
        }
        installFallbackMonitor()
    }

    private func startMaintenanceTimer() {
        guard maintenanceTimer == nil else { return }
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh()
                self.refreshOwnWindowRects() // 兜底：通知漏掉的窗口变化
            }
        }
    }

    // MARK: - CGEventTap

    private func installTap() {
        let tap = ClickTap(
            onTrigger: { [weak self] point in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.onTrigger?(point) }
                }
            },
            onTapLost: { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.tapLost() }
                }
            })
        tap.setConfig(enabled: enabled, modifiers: Self.eventFlags(from: modifiers))
        tap.setOwnWindowRects(ownWindowRects())
        guard tap.start() else {
            NSLog("PipDog: 无法建立鼠标事件 tap，改用只能旁观的全局监听")
            return
        }
        self.tap = tap
        addWindowObservers()
    }

    private func removeTap() {
        tap?.stop()
        tap = nil
        removeWindowObservers()
    }

    private func tapLost() {
        NSLog("PipDog: 鼠标事件 tap 已失效（可能是辅助功能权限被撤销），重新检查")
        removeTap()
        refresh()
    }

    // MARK: - PipDog 自己的窗口（点在上面时不拦截）

    private func ownWindowRects() -> [CGRect] {
        NSApp.windows.filter { $0.isVisible && !$0.ignoresMouseEvents }.map { Geometry.flipped($0.frame) }
    }

    private func refreshOwnWindowRects() {
        tap?.setOwnWindowRects(ownWindowRects())
    }

    /// 合并同一轮里的多次窗口变化；放到下一轮主循环，关窗通知（willClose）发出时窗口还可见。
    private func scheduleRectsRefresh() {
        guard !rectsRefreshScheduled else { return }
        rectsRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.rectsRefreshScheduled = false
                self?.refreshOwnWindowRects()
            }
        }
    }

    private func addWindowObservers() {
        guard windowObservers.isEmpty else { return }
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRectsRefresh() }
        }
        let center = NotificationCenter.default
        windowObservers = [
            NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeOcclusionStateNotification,
            NSWindow.willCloseNotification, NSWindow.didBecomeKeyNotification,
            HoverHider.clickThroughDidChange, // 悬停隐藏的小窗点击穿透，不算 PipDog 自己的窗口
        ].map { center.addObserver(forName: $0, object: nil, queue: .main, using: refresh) }
    }

    private func removeWindowObservers() {
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers = []
    }

    // MARK: - 退回方案：只能旁观的全局监听

    private func installFallbackMonitor() {
        guard fallbackMonitor == nil else { return }
        fallbackMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let clickCount = event.clickCount
            let flags = event.modifierFlags
            MainActor.assumeIsolated { self?.handleObservedClick(clickCount: clickCount, flags: flags) }
        }
    }

    private func removeFallbackMonitor() {
        if let fallbackMonitor { NSEvent.removeMonitor(fallbackMonitor) }
        fallbackMonitor = nil
    }

    private func handleObservedClick(clickCount: Int, flags: NSEvent.ModifierFlags) {
        let pressed = flags.intersection([.control, .option, .shift, .command])
        guard clickCount == 2, enabled, pressed == modifiers else { return }
        guard Permissions.hasAccessibility else {
            if didGuideAccessibility {
                Feedback.show("\(KeyCodeNames.symbols(for: modifiers)) + 双击需要「辅助功能」权限，请在系统设置中打开")
            } else {
                didGuideAccessibility = true
                Permissions.showAlert(.accessibility)
            }
            return
        }
        onTrigger?(Geometry.mouseLocationTopLeft)
    }

    private static func eventFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result: CGEventFlags = []
        if flags.contains(.control) { result.insert(.maskControl) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        if flags.contains(.command) { result.insert(.maskCommand) }
        return result
    }
}
