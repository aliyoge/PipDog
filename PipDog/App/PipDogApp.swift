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
        Button("PiP 当前窗口") { Task { await pipManager.pipFrontmostWindow() } }
        Button("关闭所有 PiP") { pipManager.closeAll() }
        Divider()
        Button("检查权限") { Permissions.requestIfNeeded() }
        Divider()
        Button("退出 PipDog") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
