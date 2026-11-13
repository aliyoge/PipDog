import AppKit

/// PiP 面板的内容视图：区分单击和拖动，鼠标悬停时在左上角显示关闭按钮。
/// 按下后移动不到 clickThreshold 点就松开算单击；超过就自己拖动窗口（放大后是平移画面），松开时不再算单击。
/// 拖动不用系统的 performDrag：那样拿不到逐帧位置，没法实时吸附屏幕边缘和相邻小窗（吸附由 PiPPanel 注入的 onDragFrame 算）。
/// 叠在画面上的暂停提示不接收鼠标（hitTest 返回 nil），点在上面也算单击。
/// 切回原窗口用单击还是双击看 WindowClickSettings（默认双击）；⌥ + 单击总是快速查看。
/// 缩放手柄和关闭按钮是子视图，点在它们上面的事件不会到这里。
///
/// 缩放和平移都在采集端裁剪：视图只记下要看的那块源区域（基准矩形里左上角原点归一化的锚点 + 倍数），
/// 停下约 0.25 秒后经 onRegionSettled 交给 WindowCapture 设 sourceRect。画面永远 1:1 铺满小窗，不再放大图层插值。
/// ⌘ + 滚动以指针为锚缩放（1…20 倍），⌘ + 拖动框选放大，放大后滚动 / 拖动平移画面，捏合同样缩放；
/// ⌘ + 双击恢复 1 倍（回到整窗或区域 PiP 的那块区域）。放大时左下角显示倍数。
/// 画面图层、暂停提示、×、缩放手柄、倍数提示都不随缩放变化。
final class PiPContentView: NSView {
    /// 单击和拖动的分界（点）
    static let clickThreshold: CGFloat = 4
    static let maximumZoom: CGFloat = 20
    /// 缩放 / 平移停下多久之后才更新采集端的裁剪区域（防抖）
    private static let regionUpdateDelay: TimeInterval = 0.25
    /// 框选放大的最小边长（点），再小当成误触
    private static let minimumSelection: CGFloat = 8
    private static let buttonSize: CGFloat = 20
    private static let buttonInset: CGFloat = 6
    /// 控制条与面板左、右、上边缘的距离
    private static let controlBarInset: CGFloat = 6

    /// 单击（松开时调用），参数是松开时的修饰键
    var onClick: ((NSEvent.ModifierFlags) -> Void)?
    var onCloseButton: (() -> Void)?
    /// 缩放 / 平移停下后调用（参数是窗口内坐标、点、左上角原点的可见区域），PiPPanel 用它设采集的 sourceRect
    var onRegionSettled: ((CGRect) -> Void)?
    /// 鼠标进入 / 离开（悬停自动隐藏用）
    var onPointerEntered: (() -> Void)?
    var onPointerExited: (() -> Void)?
    /// 拖动中算吸附后的窗口（参数是鼠标位移换算出的 frame、当前修饰键），返回要用的 frame；只改原点
    var onDragFrame: ((CGRect, NSEvent.ModifierFlags) -> CGRect)?
    /// 窗口拖动结束（松手）时调用，参数是最终的窗口 frame：这时才记住位置
    var onDragEnded: ((NSRect) -> Void)?
    /// 画面图层（PiPPanel 创建）。采集端已经裁剪好，它永远和小窗一样大：1:1 显示，不再放大插值。
    /// zPosition 设成 -1，明确排在所有子视图（×、倍数、手柄、暂停提示）下面
    var imageLayer: CALayer? {
        didSet {
            imageLayer?.zPosition = -1
            layoutImageLayer()
        }
    }

    /// 缩放倍数，1…maximumZoom
    private var zoom: CGFloat = 1
    /// 可见区域中心在基准矩形里的位置（左上角原点，0…1）。按倍数收进合法范围，保证看不到基准以外的地方
    private var anchor = CGPoint(x: 0.5, y: 0.5)
    /// 缩放的基准矩形（窗口内坐标，点，左上角原点）：整个窗口，或区域 PiP 的那块区域；原窗口 resize 时跟着变
    private var baseRect: CGRect

    private let closeButton = CloseButton()
    private let zoomBadge = ZoomBadge()
    /// 顶部悬停控制条（PiPPanel 接线并灌状态；它是子视图，不随缩放变化）
    let controlBar = PiPControlBar(frame: .zero)
    /// ⌘ 框选时的矩形提示（在画面之上）
    private let selectionLayer = CAShapeLayer()
    private var selectionStart: NSPoint?
    private var selectionCurrent: NSPoint?
    private var mouseDownEvent: NSEvent?
    private var mouseDownLocation = NSPoint.zero
    private var isDragging = false
    /// 按下时的鼠标位置和窗口原点（屏幕坐标），拖动时按累计位移算窗口位置，不会因为窗口跟着动而漂移
    private var dragStartMouse = NSPoint.zero
    private var dragStartOrigin = NSPoint.zero
    private var isMovingWindow = false
    /// 这一串连点是不是 ⌥ 点击（nil：还没开始或被拖动打断），以及它从系统 clickCount 的第几下开始
    private var seriesOption: Bool?
    private var seriesStart = 0
    private var isPanning = false
    private var lastPanLocation = NSPoint.zero
    /// 这次按下是落在控制条上：拖动只移动面板（放大时不平移画面），松开也不算「切回源窗口」的单击
    private var startedOnControlBar = false
    private var regionUpdateTimer: Timer?

    /// - Parameter baseRect: 缩放的基准矩形（窗口内坐标，点）：整个窗口，或区域 PiP 的那块区域
    init(frame frameRect: NSRect, baseRect: CGRect) {
        self.baseRect = baseRect.width >= 1 && baseRect.height >= 1
            ? baseRect
            : CGRect(origin: .zero, size: frameRect.size)
        super.init(frame: frameRect)
        wantsLayer = true
        let size = Self.buttonSize
        closeButton.frame = NSRect(x: Self.buttonInset, y: frame.height - Self.buttonInset - size, width: size, height: size)
        closeButton.autoresizingMask = [.maxXMargin, .minYMargin] // 跟着左上角
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true
        addSubview(closeButton)
        zoomBadge.isHidden = true
        addSubview(zoomBadge)
        addSubview(controlBar)
        layoutControlBar(for: frameRect.size)
        selectionLayer.fillColor = NSColor.white.withAlphaComponent(0.16).cgColor
        selectionLayer.strokeColor = NSColor.controlAccentColor.cgColor
        selectionLayer.lineWidth = 1.5
        selectionLayer.isHidden = true
        selectionLayer.frame = bounds
        selectionLayer.contentsScale = 2
        layer?.addSublayer(selectionLayer)
        // inVisibleRect：区域跟着视图大小自动更新，不用重建；面板不在前台时也要能悬停
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false } // 拖动由 mouseDragged 自己发起
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 把 ×、倍数提示和控制条移到子视图最上面（PiPPanel 加完暂停提示后调用，免得被它压暗）
    func bringChromeToFront() {
        addSubview(closeButton)
        addSubview(zoomBadge)
        addSubview(controlBar)
    }

    override func mouseEntered(with event: NSEvent) {
        showChrome()
        onPointerEntered?()
    }

    /// 指针还在小窗里时重新显示 × 和控制条。隐藏期间收到的 mouseExited 把它们藏了起来，
    /// fn / ⌥ 轻点或再次 PiP 同一窗口把小窗叫回来时不会自动再收到 mouseEntered。
    func showChrome() {
        closeButton.isHidden = false
        controlBar.setVisible(true, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.isHidden = true
        controlBar.setVisible(false, animated: true)
        onPointerExited?()
    }

    /// 屏幕坐标的点是不是在 ×、缩放手柄或控制条（含控制条下面的名称提示）上
    func isOverChrome(screenPoint: NSPoint) -> Bool {
        guard let window, let superview else { return false }
        let point = superview.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        if controlBar.contains(contentPoint: convert(point, from: superview)) { return true }
        guard let hit = hitTest(point) else { return false }
        return hit !== self
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutImageLayer() // 小窗缩放后画面还是 1:1 铺满
        selectionLayer.frame = bounds
        layoutControlBar(for: newSize)
    }

    /// 控制条贴在顶部，左边让开左上角的 ×，右边内缩一点（面板圆角会把它的上角裁掉）
    private func layoutControlBar(for size: NSSize) {
        let leading = Self.buttonInset + Self.buttonSize + 6 // × 占的宽度
        controlBar.frame = NSRect(x: leading,
                                  y: size.height - Self.controlBarInset - PiPControlBar.height,
                                  width: max(size.width - leading - Self.controlBarInset, 1),
                                  height: PiPControlBar.height)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        selectionLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    // MARK: - 缩放和平移（采集端裁剪）

    /// 基准矩形变了（原窗口 resize、区域被窗口裁小）：锚点收进新范围，再按新基准重新下发可见区域
    func updateBaseRect(_ rect: CGRect) {
        guard rect.width >= 1, rect.height >= 1, rect != baseRect else { return }
        baseRect = rect
        anchor = clampedAnchor(anchor, zoom: zoom)
        scheduleRegionUpdate()
    }

    /// 当前可见的源区域（窗口内坐标，点，左上角原点）：交给采集端设 sourceRect
    private var visibleRegion: CGRect {
        let width = baseRect.width / zoom
        let height = baseRect.height / zoom
        return CGRect(x: baseRect.minX + anchor.x * baseRect.width - width / 2,
                      y: baseRect.minY + anchor.y * baseRect.height - height / 2,
                      width: width, height: height)
    }

    /// 把锚点收进当前倍率的合法范围：可见区域不超出基准矩形
    private func clampedAnchor(_ anchor: CGPoint, zoom: CGFloat) -> CGPoint {
        guard zoom > 1 else { return CGPoint(x: 0.5, y: 0.5) }
        let half = 1 / (2 * zoom)
        return CGPoint(x: min(max(anchor.x, half), 1 - half), y: min(max(anchor.y, half), 1 - half))
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return } // 惯性滚动不算，松手就停
        if event.modifierFlags.contains(.command) {
            // 触控板是像素级的滚动量，鼠标滚轮按行算
            let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1)
            guard delta != 0 else { return }
            zoom(to: zoom * exp(delta), at: convert(event.locationInWindow, from: nil))
        } else {
            // 放大后滚动是平移画面：画面跟着手指走（滚轮按行算，一行约 10 点）
            guard zoom > 1 else { return }
            let unit: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            pan(byContentShift: CGPoint(x: event.scrollingDeltaX * unit, y: event.scrollingDeltaY * unit))
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(to: zoom * (1 + event.magnification), at: convert(event.locationInWindow, from: nil))
    }

    /// 以 pointer（视图坐标，左下原点）为锚缩放：缩放前后指针下面是画面里的同一个点
    private func zoom(to value: CGFloat, at pointer: NSPoint) {
        let target = min(max(value, 1), Self.maximumZoom)
        guard target != zoom, bounds.width > 0, bounds.height > 0 else { return }
        // 指针在可见区域里的位置（左上角原点），再换算成在基准矩形里的位置
        let visible = CGPoint(x: pointer.x / bounds.width, y: 1 - pointer.y / bounds.height)
        let source = CGPoint(x: anchor.x - 1 / (2 * zoom) + visible.x / zoom,
                             y: anchor.y - 1 / (2 * zoom) + visible.y / zoom)
        zoom = target
        // 让 source 在新倍率下仍落在指针处，再把锚点收进合法范围
        anchor = clampedAnchor(CGPoint(x: source.x - visible.x / target + 1 / (2 * target),
                                       y: source.y - visible.y / target + 1 / (2 * target)), zoom: target)
        zoomDidChange()
    }

    /// 平移画面：delta 是画面在视图里的位移（点，x 向右、y 向上）。
    /// 视图坐标 y 向上，锚点 / 基准矩形是左上角原点、y 向下，所以 y 要和 x 反过来加。
    private func pan(byContentShift delta: CGPoint) {
        guard zoom > 1, bounds.width > 0, bounds.height > 0 else { return }
        // 1 个视图点 = 1 / (视图宽 × 倍数) 个基准矩形比例
        anchor = clampedAnchor(CGPoint(x: anchor.x - delta.x / (bounds.width * zoom),
                                       y: anchor.y + delta.y / (bounds.height * zoom)), zoom: zoom)
        scheduleRegionUpdate()
    }

    /// ⌘ + 双击：恢复 1 倍，回到整个基准矩形（整窗或区域 PiP 的那块区域）。
    /// 源 app 重启重连换了新窗口时，面板也会调它（新窗口的位置/尺寸可能完全不同，旧的裁剪区域不再适用）。
    func resetZoom() {
        guard zoom != 1 else { return }
        zoom = 1
        anchor = CGPoint(x: 0.5, y: 0.5)
        zoomBadge.show(zoom: zoom, in: bounds)
        scheduleRegionUpdate()
    }

    private func zoomDidChange() {
        zoomBadge.show(zoom: zoom, in: bounds)
        scheduleRegionUpdate()
    }

    /// 缩放 / 平移停下约 0.25 秒后把可见区域交给采集端：拖动时不反复重配抓取流，松手才更新（防抖）
    private func scheduleRegionUpdate() {
        regionUpdateTimer?.invalidate()
        regionUpdateTimer = Timer.scheduledOnCommonModes(interval: Self.regionUpdateDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onRegionSettled?(self.visibleRegion)
            }
        }
    }

    /// 画面图层永远和小窗一样大（采集端已经裁剪好，1:1 显示）
    private func layoutImageLayer() {
        guard let imageLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true) // 不要隐式动画
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    /// 控制条 / 悬停按键的缩放：以画面中心为准，倍数收在 1…maximumZoom
    func zoom(by factor: CGFloat) {
        zoom(to: zoom * factor, at: NSPoint(x: bounds.midX, y: bounds.midY))
    }

    // MARK: - 框选放大

    /// ⌘ + 拖动：按下开始框选，松开时放大到框住的源区域
    private func beginSelection(at point: NSPoint) {
        selectionStart = clampToBounds(point)
        selectionCurrent = selectionStart
        selectionLayer.isHidden = false
        selectionLayer.path = nil
    }

    private func updateSelection(to point: NSPoint) {
        guard let start = selectionStart else { return }
        selectionCurrent = clampToBounds(point)
        selectionLayer.path = CGPath(rect: selectionRect(from: start, to: selectionCurrent ?? start), transform: nil)
    }

    private func cancelSelection() {
        selectionStart = nil
        selectionCurrent = nil
        selectionLayer.path = nil
        selectionLayer.isHidden = true
    }

    /// 框选矩形（视图坐标，左下原点）
    private var selectionRect: CGRect {
        guard let start = selectionStart else { return .zero }
        return selectionRect(from: start, to: selectionCurrent ?? start)
    }

    private func selectionRect(from start: NSPoint, to end: NSPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(start.x - end.x), height: abs(start.y - end.y))
    }

    private func clampToBounds(_ point: NSPoint) -> NSPoint {
        NSPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }

    /// 放大到框住的源区域：保持小窗宽高比，框里的内容全部可见（取两个方向里较小的倍数）
    private func applySelection(_ rect: CGRect) {
        guard rect.width >= Self.minimumSelection, rect.height >= Self.minimumSelection,
              bounds.width > 0, bounds.height > 0 else { return }
        // 框在可见区域里的归一化位置（左上角原点），再换算成在基准矩形里的归一化矩形
        let visible = CGRect(x: rect.minX / bounds.width, y: 1 - rect.maxY / bounds.height,
                             width: rect.width / bounds.width, height: rect.height / bounds.height)
        let source = CGRect(x: anchor.x - 1 / (2 * zoom) + visible.minX / zoom,
                            y: anchor.y - 1 / (2 * zoom) + visible.minY / zoom,
                            width: visible.width / zoom, height: visible.height / zoom)
        guard source.width > 0, source.height > 0 else { return }
        let target = min(max(min(1 / source.width, 1 / source.height), 1), Self.maximumZoom)
        zoom = target
        anchor = clampedAnchor(CGPoint(x: source.midX, y: source.midY), zoom: target)
        zoomDidChange()
    }

    // MARK: - 单击和拖动

    override func mouseDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // 控制条上的按下：拖动只移动面板（放大时也不平移画面），松开不算单击
        startedOnControlBar = controlBar.contains(contentPoint: convert(event.locationInWindow, from: nil))
        if modifiers.contains(.command) {
            // ⌘ + 双击恢复 1 倍；⌘ + 拖动框选放大；⌘ + 单击什么都不做（不然和框选抢手势）
            startedOnControlBar = false
            endClickSeries()
            if event.clickCount >= 2 {
                cancelSelection()
                resetZoom()
            } else {
                beginSelection(at: convert(event.locationInWindow, from: nil))
            }
            return
        }
        cancelSelection()
        mouseDownEvent = event
        mouseDownLocation = NSEvent.mouseLocation
        dragStartMouse = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
        dragStartOrigin = window?.frame.origin ?? .zero
        isDragging = false
        isPanning = false
        isMovingWindow = false
    }

    override func mouseDragged(with event: NSEvent) {
        if selectionStart != nil {
            updateSelection(to: convert(event.locationInWindow, from: nil))
            return
        }
        guard mouseDownEvent != nil else { return }
        let mouse = NSEvent.mouseLocation
        if isPanning {
            pan(byContentShift: CGPoint(x: mouse.x - lastPanLocation.x, y: mouse.y - lastPanLocation.y))
            lastPanLocation = mouse
            return
        }
        if !isDragging {
            guard hypot(mouse.x - mouseDownLocation.x, mouse.y - mouseDownLocation.y) >= Self.clickThreshold else { return }
            isDragging = true
            if zoom > 1, !startedOnControlBar { // 放大后拖动是平移画面（按住控制条拖动还是移动面板），从按下的位置算起
                isPanning = true
                pan(byContentShift: CGPoint(x: mouse.x - mouseDownLocation.x, y: mouse.y - mouseDownLocation.y))
                lastPanLocation = mouse
                return
            }
            isMovingWindow = true
        }
        moveWindow(with: event) // 1 倍时拖动窗口，每个事件都重新算吸附
    }

    /// 自己拖动窗口：位移从按下时累计（窗口跟着动，事件里的位置也跟着变，所以用屏幕坐标的差值），
    /// 只改原点、不改尺寸；吸附由 onDragFrame 算（按住 Control 时它是恒等变换）。
    private func moveWindow(with event: NSEvent) {
        guard let window else { return }
        let current = window.convertPoint(toScreen: event.locationInWindow)
        let proposed = CGRect(origin: NSPoint(x: (dragStartOrigin.x + current.x - dragStartMouse.x).rounded(),
                                              y: (dragStartOrigin.y + current.y - dragStartMouse.y).rounded()),
                              size: window.frame.size)
        let resolved = onDragFrame?(proposed, event.modifierFlags) ?? proposed
        window.setFrameOrigin(resolved.origin)
    }

    override func mouseUp(with event: NSEvent) {
        if selectionStart != nil {
            let selection = selectionRect
            cancelSelection()
            seriesOption = nil // 框选打断连点
            applySelection(selection)
            return
        }
        let wasClick = mouseDownEvent != nil && !isDragging
        let movedWindow = isMovingWindow
        mouseDownEvent = nil
        isDragging = false
        isPanning = false
        isMovingWindow = false
        if movedWindow, let window { onDragEnded?(window.frame) } // 松手才记位置，拖动中不写盘
        guard wasClick, !startedOnControlBar else {
            seriesOption = nil // 拖动或点控制条打断连点
            return
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let option = modifiers.contains(.option)
        if modifiers.contains(.command), !option { // ⌘ 的手势在 mouseDown 里处理，不算进连点
            seriesOption = nil
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

    /// ⌘ 手势不算点击：作废按下状态和连点计数
    private func endClickSeries() {
        mouseDownEvent = nil
        isDragging = false
        isPanning = false
        isMovingWindow = false
        seriesOption = nil
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