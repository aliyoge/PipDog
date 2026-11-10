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
        statusMenu = StatusMenu()
        SourceWindowActivator.showLeftoverNoticeIfNeeded() // 上次退出时没放回的窗口（不是权限提示）
    }

    func applicationWillTerminate(_ notification: Notification) {
        SourceWindowActivator.restoreAllStashed() // 移到屏幕边上的窗口同步放回原位
        HotKeys.shared.unregisterAll()
        clickTrigger.stop()
        SnapshotPreview.removeTemporaryFiles()
    }
}
