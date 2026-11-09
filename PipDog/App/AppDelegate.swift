import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let pipManager = PiPManager()
    private let clickTrigger = ClickTrigger()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Permissions.requestIfNeeded()
        registerHotKeys()
        clickTrigger.onTrigger = { [pipManager] point in
            Task { await pipManager.pipElement(at: point) }
        }
        clickTrigger.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeys.shared.unregisterAll()
        clickTrigger.stop()
    }

    /// 默认快捷键见 Shortcuts（菜单里显示的也是这些）。
    private func registerHotKeys() {
        let hotKeys = HotKeys.shared
        let manager = pipManager
        let ctrlOpt = HotKeys.Modifier.control | HotKeys.Modifier.option
        hotKeys.register(keyCode: kVK_ANSI_P, modifiers: ctrlOpt) {
            Task { await manager.pipFocusedWindow() }
        }
        hotKeys.register(keyCode: kVK_ANSI_P, modifiers: ctrlOpt | HotKeys.Modifier.shift) {
            manager.selectRegion()
        }
        hotKeys.register(keyCode: kVK_Delete, modifiers: ctrlOpt) {
            manager.closeAll()
        }
    }
}
