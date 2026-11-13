import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let pipManager = PiPManager()
    private let clickTrigger = ClickTrigger()
    private var statusMenu: StatusMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Permissions.hadScreenRecordingAtLaunch
        SnapshotPreview.removeTemporaryFiles() // 上次异常退出时可能留下快速查看的截图

        let settings = ShortcutSettings.shared
        settings.performAction = { [pipManager] action in
            switch action {
            case .pipWindow: Task { await pipManager.pipFocusedWindow() }
            case .selectRegion: pipManager.selectRegion()
            case .closeAll: pipManager.closeAll()
            }
        }
        settings.activate() // 注册保存的（或默认的）全局快捷键

        clickTrigger.onTrigger = { [pipManager] point in
            Task { await pipManager.pipElement(at: point) }
        }
        settings.onConfigChange = { [clickTrigger] config in clickTrigger.apply(config) }
        clickTrigger.start(config: settings.config)
        // 键盘控制：默认关。开关打开时提示一次辅助功能，关闭时把 tap 彻底拆掉
        EnhancedMode.shared.onGlobalKey = { action in
            ShortcutSettings.shared.performAction?(action == .pipWindow ? .pipWindow : .selectRegion)
        }
        EnhancedMode.shared.onHoverKey = { [pipManager] key in pipManager.handleHoverKey(key) }
        EnhancedModeSettings.shared.onChange = {
            EnhancedMode.shared.apply(enabled: EnhancedModeSettings.shared.isEnabled)
        }
        EnhancedMode.shared.start()
        statusMenu = StatusMenu()
        // 启动时的提示按顺序来：先使用说明（只有第一次启动，欢迎窗口关掉后才继续），再首启引导浮层
        // （指出菜单位置，点一下关闭），再上次退出没放回的窗口，再没生效的快捷键
        // （浮层点一下才关，两条之间隔开）。启动时不弹权限框。
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                Onboarding.showOnFirstLaunch {
                    GettingStarted.showOnFirstLaunch(anchor: { self.statusMenu?.statusItemScreenFrame }) {
                        Onboarding.handBackActivationAfterGuide() // 引导浮层关掉后再把前台还给原来的 app
                        let leftover = SourceWindowActivator.showLeftoverNoticeIfNeeded()
                        Task { @MainActor in
                            if leftover { try? await Task.sleep(for: .seconds(3)) }
                            ShortcutSettings.shared.showLaunchFailuresIfNeeded()
                        }
                    }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pipManager.closeAll() // 先关小窗：重连器、抓取和悬停状态一起停掉，放回窗口后不会再被接上
        SourceWindowActivator.restoreAllStashed() // 移到屏幕边上的窗口同步放回原位
        HotKeys.shared.unregisterAll()
        clickTrigger.stop()
        EnhancedMode.shared.stop() // 键盘 tap 跟着一起拆
        SnapshotPreview.removeTemporaryFiles()
    }
}
