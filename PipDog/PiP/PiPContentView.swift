import AppKit

/// PiP 面板的内容视图：区分单击和拖动，鼠标悬停时在左上角显示关闭按钮。
/// 按下后移动不到 clickThreshold 点就松开算单击；超过就交给系统拖动窗口，松开时不再算单击。
/// 叠在画面上的暂停提示不接收鼠标（hitTest 返回 nil），点在上面也算单击。
/// 缩放手柄和关闭按钮是子视图，点在它们上面的事件不会到这里。
final class PiPContentView: NSView {
    /// 单击和拖动的分界（点）
    static let clickThreshold: CGFloat = 4
    private static let buttonSize: CGFloat = 20
    private static let buttonInset: CGFloat = 6

    /// 单击（松开时调用），参数是松开时的修饰键
    var onClick: ((NSEvent.ModifierFlags) -> Void)?
    var onCloseButton: (() -> Void)?

    private let closeButton = CloseButton()
    private var mouseDownEvent: NSEvent?
    private var mouseDownLocation = NSPoint.zero
    private var isDragging = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        let size = Self.buttonSize
        closeButton.frame = NSRect(x: Self.buttonInset, y: frame.height - Self.buttonInset - size, width: size, height: size)
        closeButton.autoresizingMask = [.maxXMargin, .minYMargin] // 跟着左上角
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true
        addSubview(closeButton)
        // inVisibleRect：区域跟着视图大小自动更新，不用重建；面板不在前台时也要能悬停
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false } // 拖动由 mouseDragged 自己发起
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        mouseDownLocation = NSEvent.mouseLocation
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, !isDragging else { return }
        let mouse = NSEvent.mouseLocation
        guard hypot(mouse.x - mouseDownLocation.x, mouse.y - mouseDownLocation.y) >= Self.clickThreshold else { return }
        isDragging = true
        window?.performDrag(with: down) // 用按下时的事件，窗口和鼠标保持按下时的相对位置
    }

    override func mouseUp(with event: NSEvent) {
        let wasClick = mouseDownEvent != nil && !isDragging
        mouseDownEvent = nil
        isDragging = false
        guard wasClick else { return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // 小窗没有双击动作：快速连点时每一下都算单击（显示后马上再点就隐藏）；只有 ⌥ 连点的后几下忽略，避免重复截图
        if event.clickCount > 1, modifiers.contains(.option) { return }
        onClick?(modifiers)
    }

    @objc private func closeClicked() { onCloseButton?() }
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
        image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭")?
            .withSymbolConfiguration(config)
        toolTip = "关闭这个 PiP"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
