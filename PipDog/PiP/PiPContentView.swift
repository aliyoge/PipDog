import AppKit

/// PiP 面板的内容视图：区分单击和拖动，鼠标悬停时在左上角显示关闭按钮。
/// 按下后移动不到 clickThreshold 点就松开算单击；超过就交给系统拖动窗口（画面放大时是平移画面），松开时不再算单击。
/// 叠在画面上的暂停提示不接收鼠标（hitTest 返回 nil），点在上面也算单击。
/// 切回原窗口用单击还是双击看 WindowClickSettings（默认双击）；⌥ + 单击总是快速查看。
/// 缩放手柄和关闭按钮是子视图，点在它们上面的事件不会到这里。
/// 滚轮 / 触控板滚动、捏合放大缩小画面（1…8 倍，以鼠标处为中心），不改小窗大小；放大后拖动是平移画面，
/// 缩回 1 倍才是拖动小窗；⌘ + 单击一步恢复 1 倍。放大时左下角显示倍数。
/// 缩放和平移只改画面图层的 frame，暂停提示、×、缩放手柄、倍数提示不跟着缩放。
final class PiPContentView: NSView {
    /// 单击和拖动的分界（点）
    static let clickThreshold: CGFloat = 4
    static let maximumZoom: CGFloat = 8
    private static let buttonSize: CGFloat = 20
    private static let buttonInset: CGFloat = 6

    /// 单击（松开时调用），参数是松开时的修饰键
    var onClick: ((NSEvent.ModifierFlags) -> Void)?
    var onCloseButton: (() -> Void)?
    /// 缩放停下约 0.3 秒后调用（参数是缩放倍数），PiPPanel 用来调整抓取分辨率
    var onZoomSettled: ((CGFloat) -> Void)?
    /// 鼠标进入 / 离开（悬停自动隐藏用）
    var onPointerEntered: (() -> Void)?
    var onPointerExited: (() -> Void)?
    /// 画面图层（PiPPanel 创建）；缩放平移时改它的 frame。zPosition 设成 -1，明确排在所有子视图（×、倍数、手柄、暂停提示）下面
    var imageLayer: CALayer? {
        didSet {
            imageLayer?.zPosition = -1
            updateImageFrame()
        }
    }

    /// 把 × 和倍数提示移到子视图最上面（PiPPanel 加完暂停提示后调用，免得被它压暗）
    func bringChromeToFront() {
        addSubview(closeButton)
        addSubview(zoomBadge)
    }
    /// 画面缩放倍数，1…maximumZoom
    private(set) var zoom: CGFloat = 1

    private let closeButton = CloseButton()
    private let zoomBadge = ZoomBadge()
    private var mouseDownEvent: NSEvent?
    private var mouseDownLocation = NSPoint.zero
    private var isDragging = false
    /// 这一串连点是不是 ⌥ 点击（nil：还没开始或被拖动打断），以及它从系统 clickCount 的第几下开始
    private var seriesOption: Bool?
    private var seriesStart = 0
    /// 画面图层左下角相对视图的偏移，按视图宽高归一化（1 - zoom…0）；缩放小窗时保持不变
    private var panOffset = CGPoint.zero
    private var isPanning = false
    private var lastPanLocation = NSPoint.zero
    private var zoomSettleTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let size = Self.buttonSize
        closeButton.frame = NSRect(x: Self.buttonInset, y: frame.height - Self.buttonInset - size, width: size, height: size)
        closeButton.autoresizingMask = [.maxXMargin, .minYMargin] // 跟着左上角
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true
        addSubview(closeButton)
        zoomBadge.isHidden = true
        addSubview(zoomBadge)
        // inVisibleRect：区域跟着视图大小自动更新，不用重建；面板不在前台时也要能悬停
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false } // 拖动由 mouseDragged 自己发起
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        closeButton.isHidden = false
        onPointerEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.isHidden = true
        onPointerExited?()
    }

    /// 屏幕坐标的点是不是在 × 或缩放手柄（子视图）上
    func isOverChrome(screenPoint: NSPoint) -> Bool {
        guard let window, let superview else { return false }
        let point = superview.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        guard let hit = hitTest(point) else { return false }
        return hit !== self
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateImageFrame() // 小窗缩放后保持缩放倍数和平移位置
    }

    // MARK: - 缩放和平移

    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return } // 惯性滚动不算，松手就停
        // 触控板是像素级的滚动量，鼠标滚轮按行算
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1)
        guard delta != 0 else { return }
        setZoom(zoom * exp(delta), anchor: convert(event.locationInWindow, from: nil))
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), anchor: convert(event.locationInWindow, from: nil))
    }

    /// 以 anchor（视图坐标）为中心缩放：缩放前后鼠标下面是画面里的同一点。
    private func setZoom(_ value: CGFloat, anchor: NSPoint) {
        let newZoom = min(max(value, 1), Self.maximumZoom)
        guard newZoom != zoom, bounds.width > 0, bounds.height > 0 else { return }
        let a = CGPoint(x: anchor.x / bounds.width, y: anchor.y / bounds.height)
        panOffset = CGPoint(x: a.x - (a.x - panOffset.x) * newZoom / zoom, y: a.y - (a.y - panOffset.y) * newZoom / zoom)
        zoom = newZoom
        updateImageFrame()
        zoomDidChange()
    }

    /// ⌘ + 单击：恢复 1 倍
    private func resetZoom() {
        guard zoom != 1 else { return }
        zoom = 1
        panOffset = .zero
        updateImageFrame()
        zoomDidChange()
    }

    private func zoomDidChange() {
        zoomBadge.show(zoom: zoom, in: bounds)
        zoomSettleTimer?.invalidate()
        zoomSettleTimer = Timer.scheduledOnCommonModes(interval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onZoomSettled?(self.zoom)
            }
        }
    }

    /// 平移画面（屏幕点数）
    private func pan(by delta: CGPoint) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        panOffset.x += delta.x / bounds.width
        panOffset.y += delta.y / bounds.height
        updateImageFrame()
    }

    /// 限制平移范围（画面不露出空白），再设画面图层的 frame。
    private func updateImageFrame() {
        let low = 1 - zoom
        panOffset = CGPoint(x: min(max(panOffset.x, low), 0), y: min(max(panOffset.y, low), 0))
        guard let imageLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true) // 不要隐式动画，跟手
        imageLayer.frame = CGRect(x: panOffset.x * bounds.width, y: panOffset.y * bounds.height,
                                  width: bounds.width * zoom, height: bounds.height * zoom)
        CATransaction.commit()
        zoomBadge.show(zoom: zoom, in: bounds)
    }

    // MARK: - 单击和拖动

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        mouseDownLocation = NSEvent.mouseLocation
        isDragging = false
        isPanning = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }
        let mouse = NSEvent.mouseLocation
        if isPanning {
            pan(by: CGPoint(x: mouse.x - lastPanLocation.x, y: mouse.y - lastPanLocation.y))
            lastPanLocation = mouse
            return
        }
        guard !isDragging,
              hypot(mouse.x - mouseDownLocation.x, mouse.y - mouseDownLocation.y) >= Self.clickThreshold else { return }
        isDragging = true
        if zoom > 1 { // 放大后拖动是平移画面，从按下的位置算起
            isPanning = true
            pan(by: CGPoint(x: mouse.x - mouseDownLocation.x, y: mouse.y - mouseDownLocation.y))
            lastPanLocation = mouse
        } else {
            window?.performDrag(with: down) // 用按下时的事件，窗口和鼠标保持按下时的相对位置
        }
    }

    override func mouseUp(with event: NSEvent) {
        let wasClick = mouseDownEvent != nil && !isDragging
        mouseDownEvent = nil
        isDragging = false
        isPanning = false
        guard wasClick else {
            seriesOption = nil // 拖动打断连点
            return
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let option = modifiers.contains(.option)
        if modifiers.contains(.command), !option { // ⌘ + 单击只恢复 1 倍，不切换原窗口，也不算进连点
            seriesOption = nil
            resetZoom()
            return
        }
        // 系统的 clickCount 不分修饰键：⌥ 和不带 ⌥ 换着点时，从换的那一下重新数
        if event.clickCount <= 1 || seriesOption != option {
            seriesOption = option
            seriesStart = event.clickCount - 1
        }
        let clickCount = event.clickCount - seriesStart
        if option {
            // ⌥ + 单击快速查看，两种设置下都一样；⌥ 连点的后几下忽略，避免重复截图
            if clickCount == 1 { onClick?(modifiers) }
            return
        }
        switch WindowClickSettings.shared.mode { // 每次点击实时读取设置
        case .single:
            onClick?(modifiers) // 快速连点时每一下都算（切回后马上再点就移到旁边）
        case .double:
            // 第 2、4、6… 下才算：快速连续双击两次（切回再移走）会被系统数成第 4 下，不能只认第 2 下
            if clickCount > 0, clickCount.isMultiple(of: 2) { onClick?(modifiers) }
        }
    }

    @objc private func closeClicked() { onCloseButton?() }
}

/// 画面放大时左下角的倍数提示（如「2.5×」），1 倍时隐藏。不接收鼠标。
private final class ZoomBadge: NSTextField {
    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        textColor = .white
        alignment = .center
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = 4
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(zoom: CGFloat, in bounds: NSRect) {
        isHidden = zoom <= 1
        guard !isHidden else { return }
        stringValue = String(format: "%.1f×", zoom)
        let size = NSSize(width: 44, height: 18)
        frame = NSRect(x: 6, y: 6, width: size.width, height: size.height)
    }
}

/// 左上角的 × 按钮：深色圆底、白色叉，面板不在前台时第一次点击也生效。
private final class CloseButton: NSButton {
    init() {
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyUpOrDown
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, NSColor.black.withAlphaComponent(0.6)]))
        image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: String(localized: "Close"))?
            .withSymbolConfiguration(config)
        toolTip = String(localized: "Close This PiP")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
