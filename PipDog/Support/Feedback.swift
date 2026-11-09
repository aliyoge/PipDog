import AppKit

/// 给用户的轻量提示：在鼠标所在屏幕顶部显示一个几秒后自动消失的小浮层（不需要通知权限），同时写日志。
@MainActor
enum Feedback {
    private static var hud: HUDPanel?
    private static var generation = 0
    private static let duration: Duration = .seconds(2.5)

    static func show(_ message: String) {
        NSLog("PipDog: \(message)")
        let hud = hud ?? HUDPanel()
        self.hud = hud
        hud.show(message, on: Geometry.screenUnderMouse ?? NSScreen.main)
        generation += 1
        let current = generation
        Task { @MainActor in
            try? await Task.sleep(for: duration)
            if current == generation { hud.orderOut(nil) }
        }
    }
}

/// 不抢焦点、不接收鼠标的提示浮层。
private final class HUDPanel: NSPanel {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let maxTextWidth: CGFloat = 420

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.alignment = .center
        label.preferredMaxLayoutWidth = maxTextWidth
        background.addSubview(label)
        contentView = background
    }

    func show(_ message: String, on screen: NSScreen?) {
        label.stringValue = message
        let text = label.sizeThatFits(NSSize(width: maxTextWidth, height: 400))
        let textSize = NSSize(width: ceil(min(text.width, maxTextWidth)), height: ceil(text.height))
        let size = NSSize(width: textSize.width + 32, height: textSize.height + 20)
        label.frame = NSRect(x: 16, y: 10, width: textSize.width, height: textSize.height)
        let visible = screen?.visibleFrame ?? .zero
        setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 40,
                        width: size.width, height: size.height), display: true)
        orderFrontRegardless()
    }
}
