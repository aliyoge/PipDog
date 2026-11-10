import AppKit
import Carbon.HIToolbox

/// 在每块屏幕上盖一层半透明遮罩，让用户拖出一个矩形。
/// 回调里的矩形是 Cocoa 全局坐标（左下角原点）；取消时为 nil。
/// 取消方式：Esc、右键、再次触发框选，或者 PipDog 失去激活（这时已经收不到 Esc）。
@MainActor
final class RegionSelector {
    private var overlays: [OverlayWindow] = []
    private var completion: ((CGRect?) -> Void)?
    private var previousApp: NSRunningApplication?
    private var resignObserver: NSObjectProtocol?

    var isActive: Bool { !overlays.isEmpty }

    func begin(completion: @escaping (CGRect?) -> Void) {
        guard !isActive else { return }
        self.completion = completion
        previousApp = NSWorkspace.shared.frontmostApplication
        overlays = NSScreen.screens.map { screen in
            let overlay = OverlayWindow(screen: screen)
            overlay.selectionView.onFinish = { [weak self] rect in self?.finish(rect) }
            overlay.orderFrontRegardless()
            return overlay
        }
        // 激活自己才能收到 Esc；结束后切回原来的 app
        NSApp.activate()
        let mouse = NSEvent.mouseLocation
        (overlays.first { $0.frame.contains(mouse) } ?? overlays.first)?.makeKey()
        NSCursor.crosshair.set()
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }

    func cancel() { finish(nil) }

    private func finish(_ rect: CGRect?) {
        guard isActive else { return }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        NSCursor.arrow.set()
        if let app = previousApp, app != NSRunningApplication.current { app.activate() }
        previousApp = nil
        let completion = completion
        self.completion = nil
        completion?(rect)
    }
}

/// 覆盖一整块屏幕的透明无边框窗口。
private final class OverlayWindow: NSWindow {
    let selectionView: SelectionView

    init(screen: NSScreen) {
        selectionView = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = selectionView
        initialFirstResponder = selectionView
    }

    override var canBecomeKey: Bool { true }
}

/// 绘制遮罩和选框，处理拖动。
private final class SelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    private var start: NSPoint?
    private var current: NSPoint?
    private let minimumSize: CGFloat = 20

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var selection: NSRect? {
        guard let start, let current else { return nil }
        return NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(start.x - current.x), height: abs(start.y - current.y))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        defer { start = nil; current = nil; needsDisplay = true }
        // 太小的选区（例如单击）忽略，继续等待重新拖动
        guard let rect = selection, rect.width >= minimumSize, rect.height >= minimumSize, let window else { return }
        onFinish?(window.convertToScreen(convert(rect, to: nil)))
    }

    override func rightMouseDown(with event: NSEvent) {
        onFinish?(nil) // 右键取消
    }

    override func keyDown(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape { onFinish?(nil) } // Esc 取消
        else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        drawHint()
        guard let rect = selection else { return }
        NSColor.clear.setFill()
        rect.fill(using: .copy)
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
        let label = "\(Int(rect.width)) × \(Int(rect.height))" as NSString
        label.draw(at: NSPoint(x: rect.minX + 4, y: rect.maxY + 4), withAttributes: textAttributes(size: 12))
    }

    private func drawHint() {
        let hint = String(localized: "Drag to select a region to PiP. Press Esc or right-click to cancel.") as NSString
        let attrs = textAttributes(size: 15)
        let size = hint.size(withAttributes: attrs)
        hint.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height - 60), withAttributes: attrs)
    }

    private func textAttributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowBlurRadius = 3
        return [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor.white, .shadow: shadow]
    }
}
