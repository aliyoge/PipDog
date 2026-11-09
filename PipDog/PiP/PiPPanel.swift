import AppKit
import ScreenCaptureKit
import CoreMedia

/// 一个置顶、跨 Space 的浮动面板，实时显示某个窗口的画面。
@MainActor
final class PiPPanel: NSPanel, NSWindowDelegate {
    private let target: SCWindow
    private let capture: WindowCapture
    private let imageLayer = CALayer()
    var onClose: (() -> Void)?

    init(window target: SCWindow) {
        self.target = target
        self.capture = WindowCapture(window: target)
        let aspect = target.frame.height / max(target.frame.width, 1)
        let width: CGFloat = 360
        let size = NSSize(width: width, height: width * aspect)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let origin = NSPoint(x: screen.maxX - size.width - 20, y: screen.minY + 20)

        super.init(contentRect: NSRect(origin: origin, size: size),
                   styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true
        hasShadow = true
        backgroundColor = .black
        isReleasedWhenClosed = false
        contentAspectRatio = size
        delegate = self

        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.frame = view.bounds
        imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(imageLayer)
        contentView = view

        capture.onFrame = { [weak self] surface in
            self?.imageLayer.contents = surface
        }
    }

    func start() async throws {
        orderFrontRegardless()
        try await capture.start()
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 53 { close() } // ⌫ / Esc 关闭
        else { super.keyDown(with: event) }
    }

    override func close() {
        Task { await capture.stop() }
        super.close()
        onClose?()
        onClose = nil
    }
}
