import AppKit
import ScreenCaptureKit

/// 一个 PiP 的身份：窗口 + 区域（整窗时区域为零）。同一目标再次触发会把已有面板提到前面。
struct PiPKey: Hashable {
    let windowID: CGWindowID
    let x, y, width, height: Int

    init(windowID: CGWindowID, region: CGRect?) {
        self.windowID = windowID
        let r = region?.integral ?? .zero
        x = Int(r.minX); y = Int(r.minY); width = Int(r.width); height = Int(r.height)
    }
}

/// 管理所有 PiP 面板：定位目标窗口、创建面板、关闭。所有矩形都是左上角原点的全局坐标。
@MainActor
final class PiPManager {
    private var panels: [PiPKey: PiPPanel] = [:]
    private var pending: Set<PiPKey> = []
    private let regionSelector = RegionSelector()
    private let minimumRegion: CGFloat = 20
    private let fallbackRegionSize = CGSize(width: 480, height: 300)

    init() {
        CaptureSettings.shared.onFrameRateChange = { [weak self] fps in
            self?.panels.values.forEach { $0.setFrameRate(fps) }
        }
    }

    /// PiP 当前聚焦的整个窗口。
    func pipFocusedWindow() async {
        guard let window = WindowLocator.focusedWindow() else {
            NSLog("PipDog: 没找到可 PiP 的窗口")
            return
        }
        await open(window, region: nil)
    }

    /// 显示框选遮罩，选完后 PiP 选中的区域。
    func selectRegion() {
        regionSelector.begin { [weak self] cocoaRect in
            guard let self, let cocoaRect else { return }
            let rect = Geometry.flipped(cocoaRect)
            Task { await self.pipRegion(rect) }
        }
    }

    /// PiP 屏幕上的一块区域：取包含区域中心的最上层窗口，并把区域裁剪到该窗口内。
    func pipRegion(_ rect: CGRect) async {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let window = WindowLocator.window(at: center) else {
            NSLog("PipDog: 选区下方没有可 PiP 的窗口")
            return
        }
        await open(window, screenRegion: rect)
    }

    /// 修饰键 + 双击：PiP 鼠标下方的容器元素；找不到合适元素时用以点击处为中心的固定大小区域。
    func pipElement(at point: CGPoint) async {
        guard let window = WindowLocator.window(at: point) else { return }
        let region = AXRegionFinder.containerFrame(at: point, in: window)
            ?? CGRect(x: point.x - fallbackRegionSize.width / 2, y: point.y - fallbackRegionSize.height / 2,
                      width: fallbackRegionSize.width, height: fallbackRegionSize.height)
        await open(window, screenRegion: region)
    }

    func closeAll() {
        regionSelector.cancel()
        panels.values.forEach { $0.close() }
        panels.removeAll()
    }

    // MARK: - 内部

    /// 把屏幕区域裁剪到窗口内并换成窗口内坐标，然后打开 PiP。
    private func open(_ window: WindowInfo, screenRegion: CGRect) async {
        let clipped = screenRegion.intersection(window.bounds)
        guard !clipped.isNull, clipped.width >= minimumRegion, clipped.height >= minimumRegion else { return }
        let relative = clipped.offsetBy(dx: -window.bounds.minX, dy: -window.bounds.minY)
        await open(window, region: relative)
    }

    private func open(_ window: WindowInfo, region: CGRect?) async {
        let key = PiPKey(windowID: window.id, region: region)
        if let existing = panels[key] {
            existing.orderFrontRegardless()
            return
        }
        guard !pending.contains(key) else { return }
        pending.insert(key)
        defer { pending.remove(key) }

        do {
            guard let scWindow = try await WindowLocator.shareableWindow(for: window.id) else {
                NSLog("PipDog: ScreenCaptureKit 找不到 \(window.ownerName) 的窗口 \(window.id)")
                return
            }
            let panel = PiPPanel(window: scWindow, region: region, cascadeIndex: panels.count)
            panel.onClose = { [weak self] in self?.panels[key] = nil }
            panels[key] = panel
            do {
                try await panel.start()
            } catch {
                panel.close()
                throw error
            }
        } catch {
            NSLog("PipDog: 启动 PiP 失败：\(error.localizedDescription)")
        }
    }
}
