import AppKit
import ApplicationServices
import os

/// AXUIElement 可以在任意线程使用：包一层，在主线程的停放记录和后台的移动之间传递。
struct AXWindowRef: @unchecked Sendable {
    let element: AXUIElement
}

/// 单击 PiP 时把原窗口切到前台：用协作激活把前台交给原 app；有辅助功能权限时再用 AX 把那个窗口提到最前。
/// PipDog 是菜单栏 app，点非激活的 PiP 时它不在前台，直接 activate() 在 macOS 14+ 常被忽略，
/// 所以先激活自己（刚收到用户点击），再 yieldActivation 并 activate(from:)，和 SnapshotPreview 还前台的做法一样。
/// 原窗口已在最前时再单击：用 AX 把窗口移到屏幕边上，只留 1 点在屏幕内（不隐藏 app，抓取不停，小窗画面照常更新），
/// 下次单击移回原位。不用 hide()：隐藏 app 会让 ScreenCaptureKit 停掉抓取。
/// 没有权限时只能在 app 不在前台时激活它，移不了窗口，同一 app 的另一个窗口已在最前时也提不起指定窗口。
/// 只有用户要移动窗口而缺权限时，才走 `Permissions` 现有的系统授权框（每次运行一次）；切到前台从不请求权限。
/// AX 调用放在后台，单次请求和整次操作都有超时，目标 app 卡住时不会冻结界面。
enum SourceWindowActivator {
    static let messagingTimeout: TimeInterval = 0.25
    static let totalTimeLimit: TimeInterval = 0.5
    /// 移动后等窗口列表里的原窗口（CGWindowID）到位的最长时间
    static let verifyTimeLimit: TimeInterval = 0.3
    /// AX 窗口位置大小和 CGWindow bounds 比较时允许的误差（点）
    static let tolerance: CGFloat = 2

    /// 被移到屏幕边上的窗口：原 app 进程、原来的位置大小（全局左上角坐标）、移过去的 x，
    /// 以及停放时移动的那个 AX 窗口（移回时优先用它，不再按位置大小去猜）。
    /// 开始移动前就写入，确认原窗口移回原位后才删除；移动失败才丢弃。
    private struct Stash {
        var pid: pid_t
        var original: CGRect
        var parkedX: CGFloat
        var window: AXWindowRef?
    }

    /// 一次移动的结果：实际移动的 AX 窗口，和窗口列表里原窗口移动后的 x
    struct MoveResult: Sendable {
        let window: AXWindowRef
        let x: CGFloat
    }

    @MainActor private static var stashed: [CGWindowID: Stash] = [:]
    /// 正在移动（停放或移回）的窗口：同一窗口同时只有一次移动，期间的单击忽略
    @MainActor private static var moving: Set<CGWindowID> = []
    /// 移动途中最后一个 PiP 被关掉了：移完（或移回失败后）再放回原位
    @MainActor private static var restoreWhenDone: Set<CGWindowID> = []
    /// 本次运行是否已经为移动窗口弹过辅助功能系统授权框（之后只提示）
    @MainActor private static var requestedAccessibility = false
    /// 退出时关上：之后后台不再开始停放移动；锁保证关上之前正在进行的那一次已经做完
    private static let parkGate = OSAllocatedUnfairLock(initialState: false)

    /// 单击 PiP：窗口被我们移到了屏幕边上（或看起来停在屏幕外）→ 移回并切到前台；原窗口已经是屏幕上最前面的普通窗口 →
    /// 移到屏幕边上，把前台交给下面的窗口；否则切到前台。按当前状态判断，不记单击次数。
    /// 返回原 app 现在是否处于隐藏状态（PiP 据此显示 / 去掉暂停提示，只有真的隐藏（⌘H）才算）；app 已退出时返回 nil。
    @MainActor
    @discardableResult
    static func toggle(pid: pid_t, windowID: CGWindowID, appName: String) -> Bool? {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            stashed[windowID] = nil
            Feedback.show("「\(appName)」已经退出")
            return nil
        }
        guard !moving.contains(windowID) else { return app.isHidden } // 上一次移动还没完成
        stashed = stashed.filter { WindowLocator.bounds(of: $0.key) != nil } // 已关闭的窗口不再记
        let bounds = WindowLocator.bounds(of: windowID)
        if let stash = stashed[windowID], let bounds {
            if isParked(bounds, stash) {
                moveBack(pid: pid, windowID: windowID, appName: appName, from: bounds, to: stash.original.origin,
                         window: stash.window)
                return app.isHidden
            }
            stashed[windowID] = nil // 用户自己挪走了，当普通窗口处理
        }
        if let bounds, isMostlyOffscreen(bounds) {
            // 没有记录却停在屏幕外（记录丢了、上次 PipDog 异常退出）：拉回屏幕内，不当成新的原位置再停一次
            moveBack(pid: pid, windowID: windowID, appName: appName, from: bounds, to: onScreenOrigin(for: bounds), window: nil)
            return app.isHidden
        }
        guard WindowLocator.onScreenWindows().first?.id == windowID, let bounds else {
            return bringToFront(pid: pid, windowID: windowID, appName: appName) ? false : nil
        }
        guard Permissions.hasAccessibility else {
            askForAccessibility("要把「\(appName)」移到屏幕旁边并保持画面更新，需要在「系统设置 › 隐私与安全性 › 辅助功能」里打开 PipDog")
            return false
        }
        park(pid: pid, windowID: windowID, appName: appName, bounds: bounds)
        return false
    }

    /// 缺辅助功能时：本次运行第一次走 `Permissions` 的系统授权框（把 PipDog 登记到列表里），之后只提示。
    @MainActor
    private static func askForAccessibility(_ message: String) {
        if requestedAccessibility {
            Feedback.show(message)
        } else {
            requestedAccessibility = true
            Permissions.showAlert(.accessibility, message: message)
        }
    }

    /// 还停在我们放的位置（或几乎全在屏幕外）
    @MainActor
    private static func isParked(_ bounds: CGRect, _ stash: Stash) -> Bool {
        abs(bounds.minX - stash.parkedX) <= tolerance || isMostlyOffscreen(bounds)
    }

    /// 先记下原位置再移到屏幕边上；成功后记下实际移动的 AX 窗口并把前台交给下面的窗口，失败就丢掉记录。
    @MainActor
    private static func park(pid: pid_t, windowID: CGWindowID, appName: String, bounds: CGRect) {
        let parked = parkedOrigin(for: bounds)
        let title = WindowLocator.title(of: windowID)
        stashed[windowID] = Stash(pid: pid, original: bounds, parkedX: parked.x, window: nil)
        moving.insert(windowID)
        Task {
            let result = await Task.detached {
                moveWindow(pid: pid, windowID: windowID, known: nil, bounds: bounds, title: title, to: parked,
                           allowClamped: true, gated: true)
            }.value
            moving.remove(windowID)
            let closedMeanwhile = restoreWhenDone.remove(windowID) != nil
            guard let result else {
                stashed[windowID] = nil
                Feedback.show("无法移动「\(appName)」的窗口")
                return
            }
            stashed[windowID]?.parkedX = result.x
            stashed[windowID]?.window = result.window
            if closedMeanwhile {
                restoreIfStashed(windowID: windowID)
            } else {
                handFocus(awayFrom: windowID, pid: pid)
            }
        }
    }

    /// 先把窗口移回去（原位置或屏幕内），确认原窗口到位后才删记录、再切到前台；失败保留记录并提示。
    /// 没有辅助功能时只提示，不切前台（否则键盘会进到屏幕外的窗口里）。
    @MainActor
    private static func moveBack(pid: pid_t, windowID: CGWindowID, appName: String, from bounds: CGRect, to origin: CGPoint,
                                 window: AXWindowRef?) {
        guard Permissions.hasAccessibility else {
            askForAccessibility("「\(appName)」的窗口在屏幕边上，移回需要在「系统设置 › 隐私与安全性 › 辅助功能」里打开 PipDog")
            return
        }
        let title = WindowLocator.title(of: windowID)
        moving.insert(windowID)
        Task {
            let result = await Task.detached {
                moveWindow(pid: pid, windowID: windowID, known: window, bounds: bounds, title: title, to: origin,
                           allowClamped: false)
            }.value
            moving.remove(windowID)
            let closedMeanwhile = restoreWhenDone.remove(windowID) != nil
            guard let result else {
                Feedback.show("无法把「\(appName)」的窗口移回原位")
                if closedMeanwhile { restoreIfStashed(windowID: windowID) } // 期间 PiP 关了：再试一次放回
                return
            }
            stashed[windowID] = nil
            // 用已知的位置和 AX 窗口提起，不依赖窗口列表是否已经更新
            bringToFront(pid: pid, windowID: windowID, appName: appName,
                         knownFrame: CGRect(origin: origin, size: bounds.size), knownWindow: result.window)
        }
    }

    /// 停放后把前台和键盘交给下面那个窗口（不隐藏任何 app）：同 app 的窗口用 AX 提起；
    /// 别的 app 用协作激活再 AX 提起。屏幕上没有别的窗口时交给访达；停放的就是访达时交给另一个普通 app。
    @MainActor
    private static func handFocus(awayFrom windowID: CGWindowID, pid: pid_t) {
        if let next = WindowLocator.onScreenWindows().first(where: { $0.id != windowID && !isMostlyOffscreen($0.bounds) }) {
            if next.pid != pid, let app = NSRunningApplication(processIdentifier: next.pid), !app.isTerminated {
                handOver(to: app)
            }
            let title = WindowLocator.title(of: next.id)
            let nextPID = next.pid
            let bounds = next.bounds
            Task.detached { raiseWindow(pid: nextPID, bounds: bounds, title: title) }
            return
        }
        let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        let fallback = (finder?.processIdentifier == pid ? nil : finder) ?? NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && $0.processIdentifier != pid && $0 != NSRunningApplication.current
                && !$0.isHidden && !$0.isTerminated
        }
        guard let fallback, !fallback.isTerminated else {
            NSLog("PipDog: 停放后没有可以接手前台的 app")
            return
        }
        handOver(to: fallback)
    }

    /// 协作激活：PipDog 不在前台时先激活自己，再把前台交给 app（和 bringToFront 一样）。
    @MainActor
    private static func handOver(to app: NSRunningApplication) {
        if !NSApp.isActive { NSApp.activate() }
        NSApp.yieldActivation(to: app)
        _ = app.activate(from: .current)
    }

    /// 某个窗口的最后一个 PiP 关闭时：窗口还在屏幕边上的话放回原位（不切前台）。
    /// 正在移动就等移完再放回；放回失败保留记录（下次 PiP 这个窗口单击、或退出 PipDog 时再试）。
    @MainActor
    static func restoreIfStashed(windowID: CGWindowID) {
        if moving.contains(windowID) {
            restoreWhenDone.insert(windowID)
            return
        }
        guard let stash = stashed[windowID] else { return }
        // 窗口已经关了，或用户自己挪走了：不用再记
        guard let bounds = WindowLocator.bounds(of: windowID), isParked(bounds, stash) else {
            stashed[windowID] = nil
            return
        }
        guard Permissions.hasAccessibility else { return } // 移不了：保留记录，之后单击会提示
        let title = WindowLocator.title(of: windowID)
        moving.insert(windowID)
        Task {
            let result = await Task.detached {
                moveWindow(pid: stash.pid, windowID: windowID, known: stash.window, bounds: bounds, title: title,
                           to: stash.original.origin, allowClamped: false)
            }.value
            moving.remove(windowID)
            let closedAgain = restoreWhenDone.remove(windowID) != nil
            if result != nil {
                stashed[windowID] = nil
            } else if closedAgain {
                restoreIfStashed(windowID: windowID) // 期间又开关过 PiP：再试一次
            }
        }
    }

    /// 退出或重启 PipDog 前：同步把还停在屏幕边上的窗口放回原位（进程马上结束，不能交给 Task）。
    /// 先关上 parkGate，正在进行的停放做完、之后的不再执行；用户自己挪走的窗口不动。每个窗口最多约 0.8 秒。
    @MainActor
    static func restoreAllStashed() {
        parkGate.withLock { $0 = true }
        if !moving.isEmpty { Thread.sleep(forTimeInterval: 0.1) } // 让窗口列表跟上刚做完的移动
        let entries = stashed
        stashed = [:]
        let hasAccessibility = Permissions.hasAccessibility
        var stuck: [String] = []
        for (windowID, stash) in entries {
            guard let bounds = WindowLocator.bounds(of: windowID), isParked(bounds, stash) else { continue }
            let restored = hasAccessibility && moveWindow(
                pid: stash.pid, windowID: windowID, known: stash.window, bounds: bounds,
                title: WindowLocator.title(of: windowID), to: stash.original.origin, allowClamped: false) != nil
            if !restored { stuck.append("\(windowID)（pid \(stash.pid)）") }
        }
        guard !stuck.isEmpty else { return }
        NSLog("PipDog: 退出时这些窗口没能移回原位：\(stuck.joined(separator: "、"))")
        Feedback.show(hasAccessibility ? "有窗口没能移回原位，还在屏幕边上" : "有窗口还在屏幕边上，移回需要辅助功能权限")
    }

    /// 窗口几乎完全在所有屏幕之外（只露出不到 tolerance 点宽），比如被停在屏幕边上的窗口。
    @MainActor
    private static func isMostlyOffscreen(_ bounds: CGRect) -> Bool {
        let visible = NSScreen.screens.map { Geometry.flipped($0.frame).intersection(bounds) }
            .filter { !$0.isNull }.map(\.width).max() ?? 0
        return visible <= tolerance
    }

    /// 没有原位置记录时拉回屏幕的位置：窗口所在（或主）屏幕的可见区域内，离边缘留一点距离。
    @MainActor
    private static func onScreenOrigin(for bounds: CGRect) -> CGPoint {
        let inset: CGFloat = 20
        let screen = Geometry.screen(containingTopLeftRect: bounds) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return CGPoint(x: inset, y: max(bounds.minY, inset)) }
        let visible = Geometry.flipped(screen.visibleFrame)
        let x = min(max(bounds.minX, visible.minX + inset), max(visible.maxX - bounds.width - inset, visible.minX))
        let y = min(max(bounds.minY, visible.minY), max(visible.maxY - 60, visible.minY))
        return CGPoint(x: x, y: y)
    }

    /// 屏幕边上的停放位置（全局左上角坐标，和 AX 位置、CGWindow bounds 一致）：
    /// 移到窗口所在屏幕的右边缘外，只留 1 点在屏幕内（完全移出屏幕有些 app 会停止绘制），y 不变。
    /// 右边紧挨着另一块屏幕时改放左边缘；两边都有屏幕时放到所有屏幕的最右边。
    @MainActor
    private static func parkedOrigin(for bounds: CGRect) -> CGPoint {
        let screens = NSScreen.screens.map { Geometry.flipped($0.frame) } // 转成左上角坐标；x 两套坐标一样
        let screen = Geometry.screen(containingTopLeftRect: bounds).map { Geometry.flipped($0.frame) }
            ?? screens.first ?? bounds
        let rows = bounds.minY..<max(bounds.maxY, bounds.minY + 1)
        func hasScreen(atX x: CGFloat) -> Bool {
            screens.contains { $0.minX <= x && x < $0.maxX && $0.minY < rows.upperBound && rows.lowerBound < $0.maxY }
        }
        if !hasScreen(atX: screen.maxX) { return CGPoint(x: screen.maxX - 1, y: bounds.minY) }
        if !hasScreen(atX: screen.minX - 1) { return CGPoint(x: screen.minX - bounds.width + 1, y: bounds.minY) }
        return CGPoint(x: (screens.map(\.maxX).max() ?? screen.maxX) - 1, y: bounds.minY)
    }

    /// 把原窗口切到前台；返回 false 表示原 app 已经退出。
    /// knownFrame / knownWindow：刚移回时已知的位置和 AX 窗口，不再从窗口列表重新读（可能还没更新）。
    @MainActor
    @discardableResult
    static func bringToFront(pid: pid_t, windowID: CGWindowID, appName: String,
                             knownFrame: CGRect? = nil, knownWindow: AXWindowRef? = nil) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            Feedback.show("「\(appName)」已经退出")
            return false
        }
        // 被隐藏（用户按了 ⌘H 等）时先取消隐藏，不依赖 activate 的副作用
        if app.isHidden, !app.unhide() { Feedback.show("无法显示「\(appName)」") }
        let hasAccessibility = Permissions.hasAccessibility
        if NSApp.isActive || !app.isActive {
            handOver(to: app)
        } else if !hasAccessibility {
            // 原 app 已在前台（用户在它的另一个窗口里）：没有辅助功能就提不起指定窗口，只提示，不请求权限
            Feedback.show("「\(appName)」已在前台；要切到这个窗口，需要在系统设置里给 PipDog 辅助功能权限")
        }
        guard hasAccessibility, let bounds = knownFrame ?? WindowLocator.bounds(of: windowID) else { return true }
        let title = WindowLocator.title(of: windowID)
        Task.detached { raiseWindow(pid: pid, bounds: bounds, title: title, known: knownWindow) }
        return true
    }

    /// 在原 app 的 AX 窗口里找到原窗口（优先用已知的 AX 窗口），提到最前并设为主窗口。找不到（如已最小化）就算了。
    nonisolated static func raiseWindow(pid: pid_t, bounds: CGRect, title: String?, known: AXWindowRef? = nil) {
        let deadline = Date().addingTimeInterval(totalTimeLimit)
        let app = AXUIElementCreateApplication(pid)
        guard prepare(app, before: deadline) else { return }
        // 有权限时也通过 AX 置前 app：后台 app 发起的 activate 在 macOS 14+ 可能被系统忽略
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        guard let window = resolve(known, in: app, bounds: bounds, title: title, before: deadline),
              prepare(window, before: deadline) else { return }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        guard prepare(window, before: deadline) else { return }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    /// 把原窗口移到 origin（全局左上角坐标），不改大小、不切前台。以窗口列表里原窗口（windowID）的实际位置为准：
    /// AX 窗口移动了、原窗口却没到位（移错了同 app 的另一个窗口），就把那个窗口放回去，当作失败。
    /// allowClamped：系统把位置限制在别处时也算成功（停放用）。gated：受 parkGate 控制（停放用）。
    /// 返回实际移动的 AX 窗口和原窗口移动后的 x；失败返回 nil。
    nonisolated static func moveWindow(pid: pid_t, windowID: CGWindowID, known: AXWindowRef?, bounds: CGRect, title: String?,
                                       to origin: CGPoint, allowClamped: Bool, gated: Bool = false) -> MoveResult? {
        let deadline = Date().addingTimeInterval(totalTimeLimit)
        let app = AXUIElementCreateApplication(pid)
        guard let window = resolve(known, in: app, bounds: bounds, title: title, before: deadline),
              let before = frame(of: window, before: deadline) else { return nil }
        let applied = gated
            ? parkGate.withLockUnchecked { closed in !closed && setPosition(of: window, to: origin, before: deadline) }
            : setPosition(of: window, to: origin, before: deadline)
        guard applied else { return nil }

        // 等原窗口在窗口列表里到位（窗口服务器可能稍晚一点更新）
        let verifyDeadline = Date().addingTimeInterval(verifyTimeLimit)
        while true {
            if let now = WindowLocator.bounds(of: windowID), abs(now.minX - origin.x) <= tolerance {
                return MoveResult(window: AXWindowRef(element: window), x: now.minX)
            }
            guard Date() < verifyDeadline else { break }
            Thread.sleep(forTimeInterval: 0.03)
        }
        let after = frame(of: window, before: Date().addingTimeInterval(messagingTimeout))
        if allowClamped, let now = WindowLocator.bounds(of: windowID), abs(now.minX - bounds.minX) > tolerance,
           let after, abs(after.minX - now.minX) <= tolerance {
            return MoveResult(window: AXWindowRef(element: window), x: now.minX) // 系统把位置限制在了别处
        }
        if let after, abs(after.minX - before.minX) > tolerance || abs(after.minY - before.minY) > tolerance {
            _ = setPosition(of: window, to: before.origin, before: Date().addingTimeInterval(messagingTimeout))
        }
        return nil
    }

    private nonisolated static func setPosition(of window: AXUIElement, to origin: CGPoint, before deadline: Date) -> Bool {
        guard prepare(window, before: deadline) else { return false }
        var point = origin
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }

    /// 已知的 AX 窗口还在、位置大小也对得上就用它；否则按位置大小和标题重新找。
    private nonisolated static func resolve(_ known: AXWindowRef?, in app: AXUIElement, bounds: CGRect, title: String?,
                                            before deadline: Date) -> AXUIElement? {
        if let known, let frame = frame(of: known.element, before: deadline), matches(frame, bounds) {
            return known.element
        }
        return findWindow(in: app, bounds: bounds, title: title, before: deadline)
    }

    private nonisolated static func matches(_ frame: CGRect, _ bounds: CGRect) -> Bool {
        abs(frame.minX - bounds.minX) <= tolerance && abs(frame.minY - bounds.minY) <= tolerance
            && abs(frame.width - bounds.width) <= tolerance && abs(frame.height - bounds.height) <= tolerance
    }

    /// 在 app 的 AX 窗口里按位置和大小（误差 tolerance）找原窗口。有多个时只在标题能唯一区分时才选，
    /// 否则返回 nil（宁可不动，也不移错窗口）。公开 API 拿不到 AX 窗口对应的 CGWindowID。
    private nonisolated static func findWindow(in app: AXUIElement, bounds: CGRect, title: String?,
                                               before deadline: Date) -> AXUIElement? {
        guard prepare(app, before: deadline) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        let candidates = windows.filter { window in
            guard let frame = frame(of: window, before: deadline) else { return false }
            return matches(frame, bounds)
        }
        guard candidates.count > 1 else { return candidates.first }
        guard let title, !title.isEmpty else { return nil }
        let titled = candidates.filter { string(of: $0, kAXTitleAttribute, before: deadline) == title }
        return titled.count == 1 ? titled.first : nil
    }

    private nonisolated static func string(of element: AXUIElement, _ name: String, before deadline: Date) -> String? {
        guard prepare(element, before: deadline) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// 时间还够的话，把这个元素的请求超时设成剩余时间和单次上限中较小的那个。
    private nonisolated static func prepare(_ element: AXUIElement, before deadline: Date) -> Bool {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining >= 0.01 else { return false }
        AXUIElementSetMessagingTimeout(element, Float(min(remaining, messagingTimeout)))
        return true
    }

    private nonisolated static func frame(of element: AXUIElement, before deadline: Date) -> CGRect? {
        func value(_ name: String) -> AXValue? {
            guard prepare(element, before: deadline) else { return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value,
                  CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            return unsafeDowncast(value, to: AXValue.self)
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let position = value(kAXPositionAttribute), AXValueGetValue(position, .cgPoint, &origin),
              let sizeValue = value(kAXSizeAttribute), AXValueGetValue(sizeValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
