import AppKit

/// 监听全局「修饰键 + 双击」，触发区域 PiP。回调参数是左上角原点的全局坐标。
/// 注意：全局监听只能旁观事件，双击本身仍会传给目标 app。
@MainActor
final class ClickTrigger {
    var onTrigger: ((CGPoint) -> Void)?
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let clickCount = event.clickCount
            let flags = event.modifierFlags
            MainActor.assumeIsolated { self?.handle(clickCount: clickCount, flags: flags) }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(clickCount: Int, flags: NSEvent.ModifierFlags) {
        let pressed = flags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function, .numericPad])
        let config = ShortcutSettings.shared.config
        // 修饰键精确匹配设置里的组合（忽略 Caps Lock / fn）
        guard config.clickEnabled, clickCount == 2, pressed == config.clickModifiers else { return }
        guard Permissions.hasAccessibility else {
            Permissions.requestAccessibility()
            return
        }
        onTrigger?(Geometry.mouseLocationTopLeft)
    }
}
