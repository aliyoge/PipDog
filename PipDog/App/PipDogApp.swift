import SwiftUI

@main
struct PipDogApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("PipDog", systemImage: "pip") {
            MenuContent(pipManager: appDelegate.pipManager)
        }
        Settings {
            Text("PipDog 设置（待实现）").padding(40)
        }
    }
}

struct MenuContent: View {
    let pipManager: PiPManager

    var body: some View {
        // 这里的快捷键只用于在菜单里显示；真正的全局快捷键在 AppDelegate 里用 Carbon 注册
        Button("PiP 当前窗口") { Task { await pipManager.pipFocusedWindow() } }
            .keyboardShortcut("p", modifiers: [.control, .option])
        Button("框选区域 PiP…") { pipManager.selectRegion() }
            .keyboardShortcut("p", modifiers: [.control, .option, .shift])
        Button("关闭所有 PiP") { pipManager.closeAll() }
            .keyboardShortcut(.delete, modifiers: [.control, .option])
        Divider()
        Text("⌃⌥ + 双击：PiP 鼠标下方的区域")
        Divider()
        Button("检查权限") { Permissions.requestIfNeeded() }
        Divider()
        Button("退出 PipDog") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
