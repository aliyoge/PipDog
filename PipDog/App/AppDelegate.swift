import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let pipManager = PiPManager()
    private let clickTrigger = ClickTrigger()

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Permissions.hadScreenRecordingAtLaunch

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
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeys.shared.unregisterAll()
        clickTrigger.stop()
    }
}
