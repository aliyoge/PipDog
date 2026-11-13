import AppKit
import CoreGraphics

/// 增强模式的开关逻辑：开启时装上 EnhancedHotKeys（fn 组合热键 + 悬停裸键），关闭时彻底拆掉 tap。
///
/// 和 ClickTrigger 一样每秒复查一次辅助功能：授权后自动装上，运行中被撤销就拆掉并说明一次。
/// 只有用户刚打开开关、当时还没有权限，才走系统的辅助功能提示（本次运行一次）；启动时没有权限只等，
/// 不弹任何窗口。
@MainActor
final class EnhancedMode {
    static let shared = EnhancedMode()

    /// fn + P / fn + ⇧ + P（主线程）
    var onGlobalKey: ((EnhancedHotKeys.GlobalKey) -> Void)?
    /// 悬停裸键（主线程）
    var onHoverKey: ((EnhancedHotKeys.HoverKey) -> Void)?

    private var isRunning = false
    private var enabled = false
    private var tap: EnhancedHotKeys?
    private var maintenanceTimer: Timer?
    /// 指针下方的小窗矩形（左上角原点）：悬停裸键只在指针落在里面时生效
    private var panelRects: [CGRect] = []
    private var didGuideAccessibility = false
    private var waitingForAccessibility = false
    private var didAnnounceReady = false
    private var didAnnounceRevoked = false

    private init() {}

    /// 启动时调用：按保存的开关决定是否装 tap，不提示权限。
    func start() {
        isRunning = true
        enabled = EnhancedModeSettings.shared.isEnabled
        refresh()
    }

    /// 设置里的开关变了。
    func apply(enabled: Bool) {
        let justEnabled = !self.enabled && enabled
        self.enabled = enabled
        refresh()
        guard justEnabled, !Permissions.hasAccessibility else { return }
        guard !didGuideAccessibility else {
            Feedback.show(String(localized: "Enhanced Mode needs Accessibility permission. Turn it on in System Settings."))
            return
        }
        didGuideAccessibility = true
        Permissions.showAlert(.accessibility, message: String(localized: "Enhanced Mode needs Accessibility. Turn on PipDog in System Settings › Privacy & Security › Accessibility."))
    }

    /// PiP 面板打开、关闭、移动、缩放或悬停隐藏时由 PiPManager 更新。
    func setPanelRects(_ rects: [CGRect]) {
        panelRects = rects
        tap?.setPanelRects(rects)
    }

    func stop() {
        isRunning = false
        refresh()
    }

    // MARK: - 状态切换

    /// 按「开关是否打开」和当前权限决定装 tap 还是只等权限。关闭时什么都不留。
    private func refresh() {
        guard isRunning, enabled else {
            waitingForAccessibility = false
            removeTap()
            maintenanceTimer?.invalidate()
            maintenanceTimer = nil
            return
        }
        startMaintenanceTimer()
        if Permissions.hasAccessibility {
            if tap == nil { installTap() }
            if tap != nil {
                if waitingForAccessibility, !didAnnounceReady {
                    didAnnounceReady = true
                    Feedback.show(String(localized: "Accessibility granted. Enhanced Mode is ready."))
                }
                waitingForAccessibility = false
                return
            }
        } else {
            if tap != nil { announceRevoked() } // 运行中被撤销了辅助功能
            waitingForAccessibility = true
            removeTap()
        }
    }

    private func startMaintenanceTimer() {
        guard maintenanceTimer == nil else { return }
        maintenanceTimer = Timer.scheduledOnCommonModes(interval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func installTap() {
        let tap = EnhancedHotKeys(
            onGlobalKey: { [weak self] key in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.onGlobalKey?(key) }
                }
            },
            onHoverKey: { [weak self] key in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.onHoverKey?(key) }
                }
            },
            onTapLost: { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.tapLost() }
                }
            })
        tap.setPanelRects(panelRects)
        guard tap.start() else {
            NSLog("PipDog: couldn't create the keyboard event tap for Enhanced Mode; waiting for Accessibility")
            return
        }
        self.tap = tap
    }

    private func removeTap() {
        tap?.stop()
        tap = nil
    }

    private func tapLost() {
        NSLog("PipDog: Enhanced Mode event tap was invalidated (Accessibility may have been revoked); checking again")
        if !Permissions.hasAccessibility { announceRevoked() }
        removeTap()
        refresh()
    }

    /// 运行中辅助功能被关掉：本次运行只说一次，和 ClickTrigger 的提示分开写，免得两句话混在一起。
    private func announceRevoked() {
        guard !didAnnounceRevoked else { return }
        didAnnounceRevoked = true
        Feedback.show(String(localized: "Accessibility was turned off, so Enhanced Mode isn't available. Turn PipDog back on in System Settings › Privacy & Security › Accessibility."))
    }
}