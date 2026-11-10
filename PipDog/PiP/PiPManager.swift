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
    /// 每次「关闭所有」加一：之前还在查找窗口的打开请求作废，不再弹出小窗
    private var closeGeneration = 0
    private let regionSelector = RegionSelector()
    private let minimumRegion: CGFloat = 20
    private let fallbackRegionSize = CGSize(width: 480, height: 300)

    init() {
        CaptureSettings.shared.onFrameRateChange = { [weak self] fps in
            self?.panels.values.forEach { $0.setFrameRate(fps) }
        }
        WindowClickSettings.shared.onModeChange = { [weak self] mode in
            self?.panels.values.forEach { $0.clickModeDidChange(mode) }
        }
        PiPAppearanceSettings.shared.onChange = { [weak self] in
            self?.panels.values.forEach { $0.appearanceDidChange() }
        }
    }

    /// PiP 最前面 app 的窗口。最前面的 app 没有可 PiP 的窗口时只提示，不去抓别的 app 的窗口。
    func pipFocusedWindow() async {
        switch WindowLocator.focusedWindow() {
        case .found(let window): await open(window, region: nil)
        case .noWindow(let appName): Feedback.show(String(localized: "“\(appName)” has no window to PiP"))
        case .nothing: Feedback.show(String(localized: "There's no window on screen to PiP"))
        }
    }

    /// 显示框选遮罩，选完后 PiP 选中的区域。框选中再按一次（快捷键或菜单）就取消。
    func selectRegion() {
        if regionSelector.isActive {
            regionSelector.cancel()
            return
        }
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
            Feedback.show(String(localized: "There's no window under the selection to PiP"))
            return
        }
        await open(window, screenRegion: rect)
    }

    /// 修饰键 + 双击：PiP 鼠标下方的容器元素；找不到合适元素时用以点击处为中心的固定大小区域。
    /// 辅助功能查询放在后台线程，避免目标 app 卡住时冻结主线程。
    func pipElement(at point: CGPoint) async {
        guard let window = WindowLocator.window(at: point) else {
            Feedback.show(String(localized: "There's no window under the pointer to PiP"))
            return
        }
        let found = await Task.detached { AXRegionFinder.containerFrame(at: point, in: window) }.value
        let region = found ?? CGRect(x: point.x - fallbackRegionSize.width / 2, y: point.y - fallbackRegionSize.height / 2,
                                     width: fallbackRegionSize.width, height: fallbackRegionSize.height)
        await open(window, screenRegion: region)
    }

    func closeAll() {
        closeGeneration += 1
        regionSelector.cancel()
        panels.values.forEach { $0.close() }
        panels.removeAll()
    }

    // MARK: - 内部

    /// 把屏幕区域裁剪到窗口内并换成窗口内坐标，然后打开 PiP。
    private func open(_ window: WindowInfo, screenRegion: CGRect) async {
        let clipped = screenRegion.intersection(window.bounds)
        guard !clipped.isNull, clipped.width >= minimumRegion, clipped.height >= minimumRegion else {
            Feedback.show(String(localized: "The region is too small (at least \(Int(minimumRegion))×\(Int(minimumRegion))), so no PiP was opened"))
            return
        }
        let relative = clipped.offsetBy(dx: -window.bounds.minX, dy: -window.bounds.minY)
        await open(window, region: relative)
    }

    private func open(_ window: WindowInfo, region: CGRect?) async {
        let key = PiPKey(windowID: window.id, region: region)
        if let existing = panels[key] {
            existing.revealIfHidden() // 悬停隐藏中：不然看起来像没反应
            existing.orderFrontRegardless()
            return
        }
        guard !pending.contains(key) else { return }
        pending.insert(key)
        defer { pending.remove(key) }
        let generation = closeGeneration

        let scWindow: SCWindow
        do {
            guard let found = try await WindowLocator.shareableWindow(for: window.id) else {
                Feedback.show(String(localized: "Can't capture this window of “\(window.ownerName)”"))
                return
            }
            scWindow = found
        } catch {
            report(error)
            return
        }
        guard generation == closeGeneration else { return } // 查找期间按了「关闭所有」

        let panel = PiPPanel(window: scWindow, region: region, source: window, cascadeIndex: panels.count)
        panel.onClose = { [weak self] in
            guard let self else { return }
            panels[key] = nil
            // 同一窗口的最后一个 PiP（整窗、区域）关了，才把移到屏幕边上的原窗口放回去
            if !panels.keys.contains(where: { $0.windowID == key.windowID }) {
                SourceWindowActivator.restoreIfStashed(windowID: key.windowID)
            }
        }
        panel.onEnded = { message in Feedback.show(message) }
        panels[key] = panel
        SourceWindowActivator.cancelPendingRestore(windowID: window.id) // 又开了这个窗口的 PiP：停放做完不再放回
        do {
            try await panel.start()
        } catch {
            // 启动期间用户已经关掉了这个小窗（或按了「关闭所有」）：静默结束，不弹错误
            let stillOpen = panels[key] === panel
            panel.close()
            if stillOpen { report(error) }
        }
    }

    private func report(_ error: any Error) {
        NSLog("PipDog: failed to start PiP: \(error.localizedDescription)")
        if Permissions.isScreenRecordingError(error) {
            Permissions.showAlert(.screenRecording, afterFailure: true)
        } else {
            Feedback.show(String(localized: "Couldn't start PiP: this window can't be captured right now. Try again later.")) // 系统原文（多半是英文）只写日志
        }
    }
}
