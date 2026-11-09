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
        Button("设置…") {
            SettingsActivation.shared.willOpen()
            openSettings()
        }
        .keyboardShortcut(",")
        Button("检查权限") { Permissions.checkAndExplain() }
        Divider()
        Button("退出 PipDog") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func actionButton(_ action: ShortcutAction, perform: @escaping () -> Void) -> some View {
        let combo = settings.combo(for: action)
        let shortcut = combo?.keyboardShortcut
        // SwiftUI 无法表示的键（如 F5）直接写在标题里
        var title = action.title
        if let combo, shortcut == nil { title += "  \(combo.display)" }
        return Button(title, action: perform).keyboardShortcut(shortcut)
    }
}
