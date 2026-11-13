import AppKit
import SwiftUI

/// 首启引导浮层的内容：纯数据，不读任何设置，方便以后单独渲染。
struct GettingStartedInfo {
    /// 菜单栏图标（和真实菜单栏里的一致，模板图）
    var menuBarIcon: NSImage?
    var title: String
    var message: String
}

/// 引导卡片：菜单栏图标 + 标题 + 一句说明。配色跟着欢迎窗口（系统材质 + 强调色），不接收鼠标。
struct GettingStartedView: View {
    let info: GettingStartedInfo

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let icon = info.menuBarIcon {
                Image(nsImage: icon)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 18, height: 18)
                    .padding(9)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(info.title)
                    .font(.headline)
                Text(info.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
    }
}

/// 首启引导浮层：菜单栏 app 没有主窗口，第一次打开后用户只看到菜单栏多了个图标，
/// 很容易以为「没反应」。欢迎窗口关掉之后，在菜单栏图标下面显示一张带箭头的卡片指出入口，
/// 点一下任意处消失（UserDefaults 记下已看过）；菜单「显示上手指引」可以重放。
///
/// 用一个铺满目标屏幕的透明窗口接管点击：卡片是它的子视图，除了箭头之外不画别的装饰，
/// 所以不会像模态引导那样长时间挡住整个屏幕。
@MainActor
enum GettingStarted {
    private static let shownKey = "PipDog.gettingStartedShown"
    private static var overlay: GettingStartedOverlay?

    /// 第一次启动：浮层关掉后调用 completion；之前看过就直接调用 completion。
    /// anchor 每次现取（菜单栏图标刚创建时可能还没布局好，拿不到就等一拍再试一次）。
    static func showOnFirstLaunch(anchor: @escaping @MainActor () -> NSRect?,
                                  then completion: @escaping @MainActor () -> Void) {
        guard !UserDefaults.standard.bool(forKey: shownKey) else {
            completion()
            return
        }
        present(anchor: anchor, retry: true, marksAsShown: true, then: completion)
    }

    /// 菜单「显示上手指引」：随时重放，不看 UserDefaults
    static func replay(anchor: NSRect?) {
        present(anchor: { anchor }, retry: true, marksAsShown: false, then: nil)
    }

    /// 浮层真正显示出来之后才记「已看过」；退出时不会留下一个下次不再出现的标记。
    private static func markAsShown() {
        UserDefaults.standard.set(true, forKey: shownKey)
    }

    private static func present(anchor: @escaping @MainActor () -> NSRect?, retry: Bool,
                                marksAsShown: Bool, then completion: (@MainActor () -> Void)?) {
        if let overlay { // 已经在显示（例如欢迎窗口还开着时点了菜单）：不叠第二层，这次的 completion 等它关掉再走
            if let completion { overlay.addCompletion(completion) }
            if marksAsShown { markAsShown() }
            return
        }
        let resolved = anchor()
        // 菜单栏图标还没布局好：等一拍再试一次，免得卡片乱摆
        if resolved == nil, retry {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MainActor.assumeIsolated {
                    present(anchor: anchor, retry: false, marksAsShown: marksAsShown, then: completion)
                }
            }
            return
        }
        guard let overlay = GettingStartedOverlay(anchor: resolved, onDismiss: {
            GettingStarted.overlay = nil
            completion?()
        }) else {
            completion?()
            return
        }
        self.overlay = overlay
        overlay.show()
        if marksAsShown { markAsShown() }
    }
}

/// 引导浮层的窗口和卡片：所有关闭路径都汇总到一处，用 isFinished 防重入。
@MainActor
private final class GettingStartedOverlay {
    private let window: NSWindow
    private let backdrop: GettingStartedBackdropView
    private var completions: [() -> Void] = []
    private var isFinished = false

    init?(anchor: NSRect?, onDismiss: @escaping () -> Void) {
        guard let screen = Self.screen(containing: anchor) else { return nil }
        completions = [onDismiss]
        backdrop = GettingStartedBackdropView(frame: NSRect(origin: .zero, size: screen.frame.size))
        window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentView = backdrop
        backdrop.onDismiss = { [weak self] in self?.close() }

        // 卡片放在图标下方：图标 → 箭头 → 卡片，箭头始终指向菜单栏图标
        let info = GettingStartedInfo(menuBarIcon: StatusMenu.icon(size: 18),
                                      title: String(localized: "PipDog is in the menu bar"),
                                      message: String(localized: "Click its icon for PiP, region capture and settings. This guide is in the menu too, under Show Getting Started."))
        let hosting = ClickThroughHostingView(rootView: GettingStartedView(info: info))
        let size = hosting.fittingSize
        let anchorView = anchor.map { Self.viewRect($0, in: screen) }
        let origin = Self.cardOrigin(size: size, anchor: anchorView, screen: screen)
        let cardFrame = NSRect(origin: origin, size: size)
        hosting.frame = cardFrame
        backdrop.addSubview(hosting)
        backdrop.anchor = anchorView
        backdrop.cardFrame = cardFrame
    }

    func show() {
        window.orderFrontRegardless()
    }

    /// 浮层已经显示时又来了一次（例如首启提示排队）：等它关掉时一起回调。
    func addCompletion(_ completion: @escaping () -> Void) {
        completions.append(completion)
    }

    private func close() {
        guard !isFinished else { return }
        isFinished = true
        window.orderOut(nil)
        window.contentView = nil
        let completions = completions
        self.completions = []
        completions.forEach { $0() }
    }

    // MARK: - 几何

    /// 菜单栏图标所在的屏幕（拿不到图标时用主屏）
    private static func screen(containing anchor: NSRect?) -> NSScreen? {
        guard let anchor else { return NSScreen.main ?? NSScreen.screens.first }
        return NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// 屏幕坐标 → 窗口内容坐标（窗口铺满整块屏幕，原点在屏幕左下角）
    private static func viewRect(_ rect: NSRect, in screen: NSScreen) -> NSRect {
        rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
    }

    /// 卡片位置：图标正下方居中，左右和上下都收在屏幕可见区域内
    private static func cardOrigin(size: NSSize, anchor: NSRect?, screen: NSScreen) -> NSPoint {
        let visible = viewRect(screen.visibleFrame, in: screen)
        let centerX = anchor?.midX ?? (visible.maxX - Self.screenInset - size.width / 2)
        let top = anchor.map { min($0.minY - Self.anchorGap, visible.maxY) } ?? visible.maxY - Self.screenInset
        let x = min(max(centerX - size.width / 2, visible.minX + Self.screenInset),
                    visible.maxX - Self.screenInset - size.width)
        return NSPoint(x: x, y: top - size.height)
    }

    /// 图标与卡片之间留给箭头的距离
    private static let anchorGap: CGFloat = 26
    private static let screenInset: CGFloat = 16
}

/// 引导浮层的背景：一层很淡的暗色 + 菜单栏图标的高亮框 + 指向图标的箭头。
/// 点一下任意处（包括卡片本身）关闭。
private final class GettingStartedBackdropView: NSView {
    var onDismiss: (() -> Void)?
    /// 菜单栏图标的位置（视图坐标）；nil 时不画高亮框和箭头
    var anchor: NSRect?
    /// 卡片的位置（视图坐标）：箭头从卡片上缘出发
    var cardFrame: NSRect = .zero

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.16).setFill()
        bounds.fill()
        guard let anchor else { return }
        let highlight = NSBezierPath(roundedRect: anchor.insetBy(dx: -6, dy: -6), xRadius: 7, yRadius: 7)
        highlight.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        highlight.stroke()

        let tip = NSPoint(x: anchor.midX, y: anchor.minY - 5)
        let start = NSPoint(x: min(max(anchor.midX, cardFrame.minX + 26), cardFrame.maxX - 26), y: cardFrame.maxY + 4)
        let line = NSBezierPath()
        line.move(to: start)
        line.line(to: tip)
        line.lineWidth = 2
        line.lineCapStyle = .round
        NSColor.controlAccentColor.setStroke()
        line.stroke()

        let head = NSBezierPath()
        head.move(to: tip)
        head.line(to: NSPoint(x: tip.x - 5.5, y: tip.y - 11))
        head.line(to: NSPoint(x: tip.x + 5.5, y: tip.y - 11))
        head.close()
        NSColor.controlAccentColor.setFill()
        head.fill()
    }

    override func mouseDown(with event: NSEvent) { onDismiss?() }
    override func rightMouseDown(with event: NSEvent) { onDismiss?() }
}

/// 卡片只是说明文字：不接收鼠标，点在卡片上也直接落到背景（关闭引导）。
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}