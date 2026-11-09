import AppKit
import ScreenCaptureKit

/// 一个置顶、跨 Space 的浮动面板，实时显示某个窗口（或其中一块区域）的画面。
@MainActor
final class PiPPanel: NSPanel, NSWindowDelegate {
    private let capture: WindowCapture
    private let imageLayer = CALayer()
    var onClose: (() -> Void)?

    /// - Parameters:
    ///   - region: 窗口内区域（点，窗口左上角为原点）；nil 表示整个窗口
    ///   - cascadeIndex: 第几个面板，用来错开位置
    init(window target: SCWindow, region: CGRect?, cascadeIndex: Int) {
        capture = WindowCapture(window: target, sourceRect: region)
        let size = Self.panelSize(for: region?.size ?? target.frame.size, isRegion: region != nil)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let offset = CGFloat(cascadeIndex % 8) * 28
        let origin = NSPoint(x: max(screen.minX, screen.maxX - size.width - 20 - offset),
                             y: min(screen.maxY - size.height, screen.minY + 20 + offset))

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

    /// 面板初始大小：保持源的宽高比。整窗默认宽 360；区域尽量按原尺寸显示，但限制在 160…480。
    private static func panelSize(for source: CGSize, isRegion: Bool) -> NSSize {
        let aspect = source.height / max(source.width, 1)
        var width: CGFloat = isRegion ? min(max(source.width, 160), 480) : 360
        var height = width * aspect
        if height > 480 {
            height = 480
            width = height / max(aspect, 0.01)
        }
        return NSSize(width: width, height: height)
    }

    func start() async throws {
        orderFrontRegardless()
        try await capture.start(fps: CaptureSettings.shared.frameRate)
    }

    /// 把新的帧率应用到正在运行的抓取。
    func setFrameRate(_ fps: Int) {
        Task {
            do { try await capture.setFrameRate(fps) } catch {
                NSLog("PipDog: 修改帧率失败：\(error.localizedDescription)")
            }
        }
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
