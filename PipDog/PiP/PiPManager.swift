import AppKit
import ScreenCaptureKit

/// 管理所有 PiP 面板：找到目标窗口、创建面板、关闭。
@MainActor
final class PiPManager {
    private var panels: [CGWindowID: PiPPanel] = [:]

    func pipFrontmostWindow() async {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            // 取该 app 在屏幕上最前面、有一定尺寸的普通窗口
            guard let window = content.windows.first(where: {
                $0.owningApplication?.processID == app.processIdentifier
                    && $0.windowLayer == 0 && $0.frame.width > 80 && $0.frame.height > 80
            }) else {
                NSLog("PipDog: 没找到 \(app.localizedName ?? "?") 的可抓取窗口")
                return
            }
            if let existing = panels[window.windowID] {
                existing.orderFrontRegardless()
                return
            }
            let panel = PiPPanel(window: window)
            panel.onClose = { [weak self] in self?.panels[window.windowID] = nil }
            panels[window.windowID] = panel
            try await panel.start()
        } catch {
            NSLog("PipDog: 启动 PiP 失败：\(error.localizedDescription)")
        }
    }

    func closeAll() {
        panels.values.forEach { $0.close() }
        panels.removeAll()
    }
}
