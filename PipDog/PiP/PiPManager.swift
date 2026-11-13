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
    /// 重连换过 windowID 的源窗口：旧 ID → 新 ID。判断「同一窗口的最后一个 PiP」时两边都要看。
    private var reconnectedWindowIDs: [CGWindowID: CGWindowID] = [:]
    /// 已经开过多少个新面板：级联位置的序号（关完所有面板后从头开始）
    private var cascadeCount = 0
    /// 每次「关闭所有」加一：之前还在查找窗口的打开请求作废，不再弹出小窗
    private var closeGeneration = 0
    /// 小窗悬停隐藏 / 恢复：悬停按键只在看得见的小窗上生效
    private var hoverObserver: NSObjectProtocol?
    /// 小窗移动（拖动中逐个事件改原点）：只刷新悬停按键的命中区，位置记忆还是松手时才写
    private var moveObserver: NSObjectProtocol?
    private let regionSelector = RegionSelector()
    private let minimumRegion: CGFloat = 20
    private let fallbackRegionSize = CGSize(width: 480, height: 300)

    init() {
        CaptureSettings.shared.onChange = { [weak self] in
            self?.panels.values.forEach { $0.captureSettingsDidChange() }
        }
        AppFrameRateSettings.shared.onChange = { [weak self] bundleID in
            guard let self else { return }
            panels.values.filter { $0.sourceBundleID == bundleID }.forEach { $0.captureSettingsDidChange() }
        }
        WindowClickSettings.shared.onModeChange = { [weak self] mode in
            self?.panels.values.forEach { $0.clickModeDidChange(mode) }
        }
        PiPAppearanceSettings.shared.onChange = { [weak self] in
            self?.panels.values.forEach { $0.appearanceDidChange() }
        }
        hoverObserver = NotificationCenter.default.addObserver(forName: HoverHider.clickThroughDidChange, object: nil,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHotKeyRects() }
        }
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: nil,
                                                            queue: .main) { [weak self] note in
            // note 不是 Sendable：只带出窗口身份，主线程上再查是不是小窗
            let identifier = note.object.map { ObjectIdentifier($0 as AnyObject) }
            MainActor.assumeIsolated {
                guard let self, let identifier,
                      self.panels.values.contains(where: { ObjectIdentifier($0) == identifier }) else { return }
                self.refreshHotKeyRects()
            }
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
        reconnectedWindowIDs.removeAll()
    }

    /// 面板现在在字典里的 key。源 app 重启重连后 windowID 会变、key 跟着换，
    /// 所以面板相关的回调不能捕获创建时的旧 key。
    private func key(for panel: PiPPanel) -> PiPKey? {
        panels.first { $0.value === panel }?.key
    }

    /// 同一个源窗口可能因 app 重启换过 windowID：把新旧 ID 归成一组，判断「最后一个 PiP」时整组都要看。
    private func windowIDs(of windowID: CGWindowID) -> Set<CGWindowID> {
        var group: Set<CGWindowID> = [windowID]
        var changed = true
        while changed {
            changed = false
            for (old, new) in reconnectedWindowIDs where group.contains(old) || group.contains(new) {
                if group.insert(old).inserted { changed = true }
                if group.insert(new).inserted { changed = true }
            }
        }
        return group
    }

    // MARK: - 键盘控制的悬停按键

    /// 指针停在小窗上时按的裸键（= - F D ⌫ / fn 轻点）：作用在指针下方的小窗上。
    /// fn 轻点要能把藏起来的小窗叫回来，所以那次隐藏的也算。
    func handleHoverKey(_ key: EnhancedHotKeys.HoverKey) {
        guard let panel = panel(under: NSEvent.mouseLocation, includingHidden: key == .toggleHidden) else { return }
        panel.handleHoverKey(key)
    }

    /// 指针下方的面板：看得见的优先；重叠时取窗口前后顺序最前面的一块。
    /// 包括隐藏的时（fn 轻点）退而求其次。
    private func panel(under point: NSPoint, includingHidden: Bool = false) -> PiPPanel? {
        let candidates = panels.values.filter { $0.frame.contains(point) }
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 {
            let only = candidates[0]
            return only.isVisibleForSnapping || includingHidden ? only : nil
        }
        // panels 是插入顺序：重叠时按窗口前后顺序选最前面的一块。
        // NSApp.orderedWindows 在没有 Dock 图标的 app 里可能为空，用 CGWindowList 的 z 序（从前到后）。
        let order = windowNumbersFrontToBack()
        func frontIndex(_ panel: PiPPanel) -> Int { order[panel.windowNumber] ?? Int.max }
        if let visible = candidates.filter(\.isVisibleForSnapping).min(by: { frontIndex($0) < frontIndex($1) }) {
            return visible
        }
        return includingHidden ? candidates.min(by: { frontIndex($0) < frontIndex($1) }) : nil
    }

    /// 屏幕上窗口的前后顺序（窗口号 → 下标，越小越靠前）
    private func windowNumbersFrontToBack() -> [Int: Int] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var order: [Int: Int] = [:]
        for (index, info) in list.enumerated() {
            guard let number = info[kCGWindowNumber as String] as? Int, order[number] == nil else { continue }
            order[number] = index
        }
        return order
    }

    /// 悬停按键的命中区（左上角原点的全局坐标）：只看看得见、没被悬停隐藏的小窗
    private func refreshHotKeyRects() {
        EnhancedMode.shared.setPanelRects(panels.values
            .filter { $0.isVisibleForSnapping && !$0.isHoverHidden }
            .map { Geometry.flipped($0.frame) })
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
        if let existing = panels[key] { // 查找期间同一目标已经开出了面板：前置它，别再开一条流
            existing.revealIfHidden()
            existing.orderFrontRegardless()
            return
        }

        let panel = PiPPanel(window: scWindow, region: region, source: window, cascadeIndex: cascadeCount,
                             restoredTopLeft: PiPPositionMemory.shared.topLeft(for: key))
        panel.resolveDragFrame = { [weak self, weak panel] frame, modifiers in
            guard let self, let panel else { return frame }
            return self.snapDragFrame(frame, for: panel, modifierFlags: modifiers)
        }
        panel.onMoved = { [weak self, weak panel] topLeft in
            // 源 app 重启后 key 换过，所以每次现查，不用闭包捕获的旧 key
            guard let self, let panel, let key = self.key(for: panel) else { return }
            PiPPositionMemory.shared.remember(topLeft: topLeft, for: key)
            self.refreshHotKeyRects()
        }
        panel.onGeometryChanged = { [weak self] in self?.refreshHotKeyRects() }
        // 源 app 退出后重连成功：面板没变，换成新窗口的身份（key 里的 windowID 跟着换）
        panel.onReconnect = { [weak self, weak panel] oldWindowID, newWindowID, newPID in
            guard let self, let panel, let oldKey = self.key(for: panel) else { return }
            let newKey = PiPKey(windowID: newWindowID, region: panel.sourceRegion)
            guard newKey != oldKey else { return }
            // 停放记录先迁到新窗口（pid、AX 窗口都换成新进程的）：下面若关掉这个面板，
            // 才不会拿旧记录把另一个面板正在显示的新窗口拉回去
            SourceWindowActivator.migrateStash(from: oldWindowID, to: newWindowID, pid: newPID)
            if self.panels[newKey] != nil {
                // 新窗口上已经有另一个面板（同一 app 两个整窗 PiP 接到同一个新窗口）：
                // 后来这个（刚重连上的）走正常关闭，不覆盖已有面板
                self.reconnectedWindowIDs[oldWindowID] = newWindowID // 两个 ID 仍是同一个窗口，恢复要看整组
                panel.close()
                return
            }
            self.panels[oldKey] = nil
            self.panels[newKey] = panel
            self.reconnectedWindowIDs[oldWindowID] = newWindowID
            PiPPositionMemory.shared.migrate(from: oldKey, to: newKey)
        }
        panel.onClose = { [weak self, weak panel] in
            guard let self, let panel, let key = self.key(for: panel) else { return }
            self.panels[key] = nil
            self.refreshHotKeyRects()
            if self.panels.isEmpty { self.cascadeCount = 0 } // 全关了以后，新面板从第一个级联位置重新开始
            // 同一窗口的最后一个 PiP（整窗、区域）关了，才把移到屏幕边上的原窗口放回去；
            // 源 app 重启后旧 ID、新 ID 指的是同一个窗口，两边都没有面板了才算最后一个
            let ids = self.windowIDs(of: key.windowID)
            guard !self.panels.keys.contains(where: { ids.contains($0.windowID) }) else { return }
            ids.forEach { SourceWindowActivator.restoreIfStashed(windowID: $0) }
            self.reconnectedWindowIDs = self.reconnectedWindowIDs.filter {
                !ids.contains($0.key) && !ids.contains($0.value)
            }
        }
        panel.onEnded = { message in Feedback.show(message) }
        panels[key] = panel
        refreshHotKeyRects()
        SourceWindowActivator.cancelPendingRestore(windowID: window.id) // 又开了这个窗口的 PiP：停放做完不再放回
        do {
            try await panel.start()
            if panels[key] === panel { cascadeCount += 1 } // 启动失败或期间被关掉：不占级联位置
        } catch {
            // 启动期间用户已经关掉了这个小窗（或按了「关闭所有」）：静默结束，不弹错误
            let stillOpen = panels[key] === panel
            panel.close()
            if stillOpen { report(error) }
        }
    }

    // MARK: - 拖动吸附

    /// 拖动中的窗口位置：靠近面板所在屏幕的可见区域（去掉菜单栏、Dock）边缘，或同一屏幕上其他 PiP 的边缘时对齐，
    /// 相邻 PiP 边缘贴合不留缝。按住 Control 临时不吸附。只改位置，不改尺寸。
    private func snapDragFrame(_ proposed: CGRect, for moving: PiPPanel,
                               modifierFlags: NSEvent.ModifierFlags) -> CGRect {
        guard !modifierFlags.contains(.control) else { return proposed }
        let screens = NSScreen.screens
        let screenFrames = screens.map(\.frame)
        guard let index = SnappingGeometry.screenIndex(containing: proposed, in: screenFrames) else { return proposed }
        // 只让同一屏幕上的其他 PiP 参与：跨屏只露过来一点的不算，免得产生看不见的吸附
        let siblings = panels.values.filter {
            $0 !== moving && $0.isVisibleForSnapping
                && SnappingGeometry.screenIndex(containing: $0.frame, in: screenFrames) == index
        }.map(\.frame)
        return SnappingGeometry.snappedFrame(proposed, in: screens[index].visibleFrame, siblings: siblings)
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
