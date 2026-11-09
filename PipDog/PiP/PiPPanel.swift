import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

/// 一个置顶、跨 Space 的浮动面板，实时显示某个窗口（或其中一块区域）的画面。
@MainActor
final class PiPPanel: NSPanel {
    private let capture: WindowCapture
    private let imageLayer = CALayer()
    /// 正在显示的帧；保留到下一帧到来，避免它的 IOSurface 被复用
    private var currentFrame: CapturedFrame?
    private var isClosing = false
    var onClose: (() -> Void)?
    /// 抓取意外结束（原窗口关闭等）时调用，参数是给用户看的说明
    var onEnded: ((String) -> Void)?

    /// - Parameters:
    ///   - region: 窗口内区域（点，窗口左上角为原点）；nil 表示整个窗口
    ///   - sourceBounds: 原窗口在屏幕上的位置（左上角原点的全局坐标），用来决定面板放在哪块屏幕
    ///   - cascadeIndex: 第几个面板，用来错开位置
    init(window target: SCWindow, region: CGRect?, sourceBounds: CGRect, cascadeIndex: Int) {
        capture = WindowCapture(window: target, region: region)
        let size = Self.panelSize(for: region?.size ?? target.frame.size, isRegion: region != nil)
        let screen = (Geometry.screen(containingTopLeftRect: sourceBounds) ?? Geometry.screenUnderMouse ?? NSScreen.main)?
            .visibleFrame ?? .zero
        let offset = CGFloat(cascadeIndex % 8) * 28
        let origin = NSPoint(x: max(screen.minX, screen.maxX - size.width - 20 - offset),
                             y: min(screen.maxY - size.height, screen.minY + 20 + offset))

        super.init(contentRect: NSRect(origin: origin, size: size),
                   styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false // NSPanel 默认 true：PipDog 一失去激活（框选结束、设置窗口切走）面板就会消失
        isMovableByWindowBackground = true
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear // 透明窗口 + 圆角图层，四角才不会露出黑色方角
        isReleasedWhenClosed = false
        contentAspectRatio = size

        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.cornerRadius = 12
        view.layer?.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.frame = view.bounds
        imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(imageLayer)
        // 无边框窗口的边缘缩放不可靠，右下角放一个缩放手柄
        let handleSize = ResizeHandle.size
        let handle = ResizeHandle(frame: NSRect(x: size.width - handleSize, y: 0, width: handleSize, height: handleSize))
        handle.autoresizingMask = [.minXMargin, .maxYMargin]
        view.addSubview(handle)
        contentView = view

        capture.onFrame = { [weak self] frame in self?.show(frame) }
        capture.onSourceSizeChange = { [weak self] size in self?.adaptAspect(to: size) }
        capture.onStop = { [weak self] reason in self?.captureEnded(reason) }
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
        let code = Int(event.keyCode)
        if code == kVK_Delete || code == kVK_Escape { close() } // ⌫ / Esc 关闭
        else { super.keyDown(with: event) }
    }

    /// 唯一的关闭流程：停止抓取（移除输出）→ 关窗 → 通知 PiPManager 移除。可以重复调用。
    override func close() {
        guard !isClosing else { return }
        isClosing = true
        let capture = capture
        Task { await capture.stop() }
        imageLayer.contents = nil
        currentFrame = nil
        super.close()
        onClose?()
        onClose = nil
        onEnded = nil
    }

    // MARK: - 内部

    private func show(_ frame: CapturedFrame) {
        let isFirst = currentFrame == nil
        CATransaction.begin()
        CATransaction.setDisableActions(true) // 关掉 contents 变化的隐式淡入动画
        imageLayer.contents = frame.surface
        CATransaction.commit()
        currentFrame = frame
        if isFirst { invalidateShadow() }
    }

    /// 源尺寸变化后按新宽高比调整面板，保持宽度和左上角不变（太高时缩小宽度）。
    private func adaptAspect(to source: CGSize) {
        guard source.width >= 1, source.height >= 1 else { return }
        contentAspectRatio = source
        var rect = frame
        let top = rect.maxY
        var width = rect.width
        var height = width * source.height / source.width
        let maxHeight = (screen?.visibleFrame.height ?? 900) * 0.8
        if height > maxHeight {
            height = maxHeight
            width = height * source.width / source.height
        }
        rect.size = NSSize(width: width, height: height)
        rect.origin.y = top - height
        setFrame(rect, display: true)
        invalidateShadow()
    }

    private func captureEnded(_ reason: WindowCapture.StopReason) {
        switch reason {
        case .windowClosed: onEnded?("原窗口已关闭，PiP 已结束")
        case .failed(let error): onEnded?("PiP 已结束：\(error.localizedDescription)")
        }
        close()
    }
}
