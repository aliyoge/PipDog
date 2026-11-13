import Foundation

/// 渲染卡顿的分级恢复判断：只看「按当前帧率，最多应该多久来一帧」和「上一帧是什么时候」，
/// 输出下一步建议的动作，不碰 ScreenCaptureKit，也不做任何 IO。
///
///     该来没来 → 重申配置 → 还没来（再等一个阈值）→ 重建流 → 还没来 → 提示用户
///
/// 每一级之间至少隔一个阈值，所以一次瞬时抖动不会连跳三级；中途只要有帧到达就回到健康状态。
/// 低功耗状态（静止降帧、被遮挡、截图、暂停）下由调用方停止喂帧并 reset()，
/// 否则「没有帧」会被误判成卡顿。
struct RendererWatchdog {
    /// 建议的恢复动作
    enum Recovery: Equatable {
        case none
        /// 第 1 级：重新下发一遍抓取配置
        case reapplyConfiguration
        /// 第 2 级：重建抓取流
        case restartStream
        /// 第 3 级：告诉用户画面卡住了、已经尝试恢复
        case notifyUser
    }

    /// 判定阈值 = 预期间隔 × toleranceFactor，且不低于 minimumStallInterval 秒：
    /// 高帧率时不至于一抖就判卡顿，低帧率时也不会一直等。
    /// 可选帧率最低 5 fps（间隔 0.2 秒 × 5 = 1 秒），所以实际生效的总是 2 秒这一档：
    /// 只要 2 秒没有帧就当作卡顿，和帧率无关；toleranceFactor 留给以后允许更低帧率时用。
    static let toleranceFactor: TimeInterval = 5
    static let minimumStallInterval: TimeInterval = 2

    private enum Phase: Equatable {
        case healthy
        case reapplied(since: TimeInterval)
        case restarted(since: TimeInterval)
        case notified
    }

    /// 按设定帧率算出来的「一帧应该多久来一次」（秒）
    private(set) var expectedInterval: TimeInterval
    /// 判定阈值（秒）
    var stallInterval: TimeInterval { max(Self.minimumStallInterval, expectedInterval * Self.toleranceFactor) }
    /// 已经在卡顿恢复流程里（有帧到达就结束）
    var isInStall: Bool { phase != .healthy }
    /// 正在监控：reset 之后、下一次 beginMonitoring 之前是 false。
    /// 调用方靠它区分「第一次拿到帧」和「从暂停 / 低功耗 / 截图回到监控」。
    var isMonitoring: Bool { lastFrameAt != nil }

    private var lastFrameAt: TimeInterval?
    private var phase = Phase.healthy

    init(expectedInterval: TimeInterval) {
        self.expectedInterval = max(expectedInterval, 1.0 / 60)
    }

    /// 帧率变了：阈值跟着变，正在进行的卡顿判断不清零（不因为用户改帧率而漏掉这次卡顿）。
    mutating func setExpectedInterval(_ interval: TimeInterval) {
        expectedInterval = max(interval, 1.0 / 60)
    }

    /// 开始监控：从这一刻起算「该来一帧」（流刚启动时还没有任何帧，也要能被发现）。
    mutating func beginMonitoring(at now: TimeInterval) {
        lastFrameAt = now
        phase = .healthy
    }

    /// 收到一帧：恢复健康，卡顿流程结束。旧时间戳重复上报（没有新帧）不算恢复，
    /// 否则周期检查每次把同一个旧时间当新帧，永远升不到下一级。
    mutating func recordFrame(at now: TimeInterval) {
        if let lastFrameAt, now <= lastFrameAt { return }
        lastFrameAt = now
        phase = .healthy
    }

    /// 重建流完成：保住已经升到的级别，只把「下一级」的计时重新开始。
    mutating func noteStreamRestarted(at now: TimeInterval) {
        lastFrameAt = now
        phase = .restarted(since: now)
    }

    /// 重建没能进行（源窗口暂时抓不到）：停在「等重建」这一级，隔一个阈值再试，
    /// 不升级到提示用户——窗口回到屏幕上以后流自己就会恢复。
    mutating func retryRestart(at now: TimeInterval) {
        lastFrameAt = now
        phase = .reapplied(since: now)
    }

    /// 定时调用（约每秒一次）。只在跨过恢复边界的那一次返回动作。
    mutating func tick(now: TimeInterval) -> Recovery {
        guard let lastFrameAt else { return .none }
        switch phase {
        case .healthy:
            guard now - lastFrameAt >= stallInterval else { return .none }
            phase = .reapplied(since: now)
            return .reapplyConfiguration
        case let .reapplied(since):
            guard now - since >= stallInterval else { return .none }
            phase = .restarted(since: now)
            return .restartStream
        case let .restarted(since):
            guard now - since >= stallInterval else { return .none }
            phase = .notified
            return .notifyUser
        case .notified:
            return .none
        }
    }

    /// 停止监控（暂停、低功耗、截图、关闭）：下次 beginMonitoring 从头开始。
    mutating func reset() {
        lastFrameAt = nil
        phase = .healthy
    }
}