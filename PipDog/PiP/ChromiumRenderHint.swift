import Foundation

/// Chromium / Electron 源窗口停帧的可疑信号。
///
/// 只有「源窗口真的看不见了（别的 Space / 被完全遮挡）→ 重新看得见 → 过了宽限期连 idle 帧都不再来」才算可疑；
/// 画面一直在动（新帧不断到达）时调用方根本不会来看窗口列表，所以这个判断很便宜。
///
/// 停画用「任意一帧的到达时间」判断，不能用画面内容（完整帧）的时间戳：静止的页面本来就
/// 不再发完整帧，只看它会把「切 Space 回来」误判成停画。
///
/// 纯状态机：输入「源窗口是否看得见」「最近一帧到达时间」，输出「该提示了吗」。不查系统、不碰 UI。
struct ChromiumRenderHint {
    /// 画面停住这么久之后，才开始每秒看一次源窗口的可见性
    static let observationDelay: TimeInterval = 2
    /// 源窗口重新看得见之后，再等这么久连一帧都没来才提示（正常切回来会立刻来一帧，静止页面也有 idle 帧）
    static let resumeGrace: TimeInterval = 2

    private enum Phase: Equatable {
        case idle
        /// 源窗口看不见了（别的 Space、最小化或被完全遮挡）
        case away(since: TimeInterval)
        /// 又看得见了，等新帧
        case returned(since: TimeInterval, arrivalAtReturn: TimeInterval?)
    }

    private var phase = Phase.idle

    /// 值得查一次源窗口可见性吗：画面还在动就什么都不查。
    static func needsVisibilityCheck(secondsSinceLastFrame: TimeInterval?) -> Bool {
        guard let secondsSinceLastFrame else { return false }
        return secondsSinceLastFrame >= observationDelay
    }

    /// 每秒调用一次。返回 true 表示该提示用户了（同一次停帧只返回一次）。
    /// - Parameters:
    ///   - visible: 源窗口此刻是否在当前桌面上看得见；nil 表示窗口已经不在列表里（重连路径负责，这里不管）
    ///   - arrivalAt: 最近一次有帧到达的时间（systemUptime，内容没变的 idle 帧也算）；还没收到过帧时为 nil
    mutating func observe(visible: Bool?, arrivalAt: TimeInterval?, at now: TimeInterval) -> Bool {
        guard let visible else {
            reset()
            return false
        }
        switch phase {
        case .idle:
            if !visible { phase = .away(since: now) }
            return false

        case .away:
            if visible { phase = .returned(since: now, arrivalAtReturn: arrivalAt) }
            return false

        case let .returned(since, arrivalAtReturn):
            guard visible else { // 宽限期内又看不见了：重新从头等
                phase = .away(since: now)
                return false
            }
            guard arrivalAt == arrivalAtReturn else { // 回来后帧又来（idle 帧也算）：流是活的，不用提示
                reset()
                return false
            }
            guard now - since >= Self.resumeGrace else { return false }
            reset()
            return true
        }
    }

    mutating func reset() {
        phase = .idle
    }
}