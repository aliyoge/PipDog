import CoreGraphics
import Foundation
import ScreenCaptureKit

/// 源 app 退出后，等它重启并把 PiP 接回新窗口。
///
/// 每 2.5 秒问一次 ScreenCaptureKit 同一 bundleID 的窗口（只取 layer 0 的普通窗口），按
/// 「同一个 windowID → 标题完全相同 → 尺寸接近且唯一」的顺序挑一个；找到就交给
/// `PiPPanel` 重建 `WindowCapture`。最多等 5 分钟：超时就回调 `onTimeout`，由面板走正常关闭流程。
/// 超时按时间算，不被在途的 `SCShareableContent` 查询挡住。
///
/// 只在等待期间存在：面板拿到新窗口或用户关闭面板都会 `stop()`，定时器随之销毁。
/// `stop()` 不丢回调：重建抓取失败时面板用 `resumeWaiting()` 接着等，超时和匹配回调仍然有效。
@MainActor
final class SourceWindowReconnector {
    /// 要找的窗口：退出时的样子。windowID 可能被系统收回，标题和尺寸是主要线索。
    struct Target: Equatable {
        let bundleID: String
        let windowID: CGWindowID
        /// 退出前的窗口标题（有屏幕录制权限才有，可能为 nil）
        let title: String?
        let size: CGSize
    }

    /// 候选窗口的纯数据快照：匹配逻辑不碰 SCWindow，便于单独核对
    struct Candidate: Equatable {
        let windowID: CGWindowID
        let title: String
        let size: CGSize
    }

    static let defaultInterval: TimeInterval = 2.5
    static let defaultTimeout: TimeInterval = 5 * 60
    /// 没有标题时，多大尺寸差还算「同一个窗口」（相对原窗口尺寸）
    private static let sizeTolerance: CGFloat = 0.15

    private let target: Target
    private let interval: TimeInterval
    private let timeout: TimeInterval
    private var startedAt = ProcessInfo.processInfo.systemUptime
    private var timer: Timer?
    private var isChecking = false
    private var isWaiting = false

    /// 找到窗口（主线程回调，参数是新窗口）
    var onWindow: ((SCWindow) -> Void)?
    /// 等太久了（主线程回调）
    var onTimeout: (() -> Void)?

    init(target: Target, interval: TimeInterval = SourceWindowReconnector.defaultInterval,
         timeout: TimeInterval = SourceWindowReconnector.defaultTimeout) {
        self.target = target
        self.interval = interval
        self.timeout = timeout
    }

    var isReconnecting: Bool { isWaiting }

    /// 开始等待（立即查一次，之后按间隔查）。
    func start() {
        begin(resettingDeadline: true)
    }

    /// 拿到窗口但重建抓取失败：继续等下一个周期（已等的时间不顺延，超时照样结束）。
    /// 不立即查：那个窗口可能还在列表里，立刻再查会再匹配到它，失败就变成不带间隔的查询循环。
    func resumeWaiting() {
        begin(resettingDeadline: false, checkingImmediately: false)
    }

    private func begin(resettingDeadline: Bool, checkingImmediately: Bool = true) {
        guard !isWaiting else { return }
        isWaiting = true
        if resettingDeadline { startedAt = ProcessInfo.processInfo.systemUptime }
        timer = Timer.scheduledOnCommonModes(interval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        if checkingImmediately { check() }
    }

    /// 只停定时器，不清 `onWindow` / `onTimeout`：匹配到窗口后先 stop 再回调，
    /// 面板重建抓取失败会 `resumeWaiting()` 继续等，回调还得在。不用了由面板丢掉整个 reconnector。
    func stop() {
        isWaiting = false
        timer?.invalidate()
        timer = nil
    }

    /// 用户点了小窗：别等下一个周期，现在就查一次。
    func checkNow() {
        guard isWaiting, !isChecking else { return }
        check()
    }

    private func check() {
        guard isWaiting else { return }
        // 先看超时：在途的 SCShareableContent 查询可能一直不回来，不能让它挡住 deadline
        if hasTimedOut {
            finish()
            return
        }
        guard !isChecking else { return }
        isChecking = true
        Task {
            defer { isChecking = false }
            guard let windows = try? await WindowLocator.shareableWindows(forBundleID: target.bundleID) else { return }
            // 查询期间可能已经超时（或被面板停掉了）：超时之后不要再把窗口接上去
            guard isWaiting, !hasTimedOut else { return }
            let byID = Dictionary(windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
            let candidates = windows.map {
                Candidate(windowID: $0.windowID, title: $0.title ?? "", size: $0.frame.size)
            }
            guard isWaiting, let match = Self.bestMatch(in: candidates, target: target),
                  let window = byID[match.windowID] else { return }
            let notify = onWindow
            stop()
            notify?(window)
        }
    }

    private var hasTimedOut: Bool {
        ProcessInfo.processInfo.systemUptime - startedAt >= timeout
    }

    /// 等太久了：通知面板走正常的关闭流程
    private func finish() {
        let notify = onTimeout
        stop()
        notify?()
    }

    /// 挑最像原窗口的候选。宁可不接（返回 nil、继续等）也不要接错窗口：
    /// 只有「同一个 windowID」「标题（trim 后）完全相同」或「尺寸接近且只有一个候选」才算匹配。
    static func bestMatch(in candidates: [Candidate], target: Target) -> Candidate? {
        guard !candidates.isEmpty else { return nil }
        if let sameID = candidates.first(where: { $0.windowID == target.windowID }) { return sameID }

        let wanted = target.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !wanted.isEmpty {
            let exact = candidates.filter { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == wanted }
            if let hit = closestBySize(exact, to: target.size) { return hit }
        }

        // 标题帮不上忙（没权限、标题改了）：尺寸接近的候选必须唯一，几扇窗口里挑一个容易接错
        let closeBySize = candidates.filter { isCloseInSize($0.size, target.size) }
        guard closeBySize.count == 1 else { return nil }
        return closeBySize[0]
    }

    /// 尺寸差（宽 + 高），越小越像
    private static func sizeDistance(_ size: CGSize, _ target: CGSize) -> CGFloat {
        abs(size.width - target.width) + abs(size.height - target.height)
    }

    private static func closestBySize(_ candidates: [Candidate], to size: CGSize) -> Candidate? {
        candidates.min { sizeDistance($0.size, size) < sizeDistance($1.size, size) }
    }

    private static func isCloseInSize(_ size: CGSize, _ target: CGSize) -> Bool {
        func close(_ value: CGFloat, _ expected: CGFloat) -> Bool {
            guard expected >= 1 else { return false }
            return abs(value - expected) / expected <= sizeTolerance
        }
        return close(size.width, target.width) && close(size.height, target.height)
    }
}