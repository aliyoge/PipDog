import SwiftUI

@main
struct PipDogApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("PipDog", systemImage: "pip") {
            MenuContent(pipManager: appDelegate.pipManager)
        }
        Settings {
            SettingsView()
        }
    }
}

struct MenuContent: View {
    let pipManager: PiPManager
    @Environment(\.openSettings) private var openSettings
    private var settings: ShortcutSettings { .shared }

    var body: some View {
        // 菜单里的快捷键只用于显示（随设置实时更新）；真正的全局快捷键由 ShortcutSettings 用 Carbon 注册
        actionButton(.pipWindow) { Task { await pipManager.pipFocusedWindow() } }
        actionButton(.selectRegion) { pipManager.selectRegion() }
        actionButton(.closeAll) { pipManager.closeAll() }
        if settings.config.clickEnabled {
            Divider()
            Text("\(KeyCodeNames.symbols(for: settings.config.clickModifiers)) + 双击：PiP 鼠标下方的区域")
        }
        Divider()
        Button("设置…") { showSettings() }.keyboardShortcut(",")
        Button("检查权限") { Permissions.requestIfNeeded() }
        Divider()
        Button("退出 PipDog") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func actionButton(_ action: ShortcutAction, perform: @escaping () -> Void) -> some View {
        let combo = settings.combo(for: action)
        let shortcut = combo?.keyboardShortcut
        // SwiftUI 无法表示的键（如 F5）直接写在标题里
        let title = (combo != nil && shortcut == nil) ? "\(action.title)  \(combo!.display)" : action.title
        return Button(title, action: perform).keyboardShortcut(shortcut)
    }

    /// 菜单栏 app 没有 Dock 图标，需要先激活自己，设置窗口才会出现在最前面。
    private func showSettings() {
        NSApp.activate()
        openSettings()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            for window in NSApp.windows where window.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }
}
