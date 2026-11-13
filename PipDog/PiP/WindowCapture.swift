import AppKit
import CoreImage
import CoreMedia
import ScreenCaptureKit

/// 用 ScreenCaptureKit 抓取单个窗口（或窗口里的一块区域）。
/// 所有状态都在主线程上；只有 SCStream 的帧回调和停止回调是 nonisolated，
/// 它们只碰线程安全的 FrameMailbox，然后切回主线程处理。
///
/// sourceRect 有两个用途：区域 PiP 的基准区域，以及用户放大后要看的可见区域（setVisibleRegion）。
/// 放大在采集端裁剪，输出像素是可见区域乘屏幕像素比例，所以放大后画面不会变糊（不超过可见区域的原生分辨率）。
///
/// 配置更新只有一条串行路径（setNeedsUpdate）：每次都用当前状态新建一个 SCStreamConfiguration 交给
/// updateConfiguration，不会在更新进行中修改同一个配置对象；更新期间又有变化时，结束后再更新一次。
///
/// 原 app 被隐藏（⌘H、Dock）时 ScreenCaptureKit 会停掉这条流，窗口也可能从窗口列表里消失。
/// 这不算结束：进入 paused（保留最近一帧和回调，不调用 onStop），原 app 取消隐藏后 resumeAfterUnhide()
/// 重新找到窗口、重新开始抓取。只有 app 退出、或 app 没隐藏但窗口不见了，才当作原窗口已关闭。
///
/// 渲染卡顿单靠帧回调发现不了（没有帧就没有回调）：周期检查里用 RendererWatchdog 按当前帧率
/// 判断「该来的帧没来」，分级重申配置 → 重建流 → 提示用户。静止降帧、被遮挡、最小化、截图、
/// 暂停时本来就没有帧，这些状态下不监控。
@MainActor
final class WindowCapture: NSObject {
    enum StopReason {
        case windowClosed
        case failed(any Error)
    }

    private enum State { case idle, starting, running, paused, stopped }

    /// 输出画面长边的上限（像素），防止超大面板或超大窗口占用过多内存
    static let maximumOutputDimension: CGFloat = 4096
    /// 不依赖帧到达、定期检查原窗口是否还在（画面静止时 ScreenCaptureKit 不发完整帧）
    private static let sourceCheckInterval: TimeInterval = 1.5
    /// 画面连续这么久没有变化就降到低功耗帧率
    private static let staticTimeout: TimeInterval = 5
    /// 静止 / 遮挡时实际使用的帧率
    private static let lowPowerFrameRate = 1

    /// 取消隐藏后重新开始抓取时会换成新找到的 SCWindow（同一个窗口 ID）
    private var window: SCWindow
    /// 原窗口所属 app 的进程，用来区分「被隐藏」和「真的关了 / 退出了」
    private let sourcePID: pid_t?
    /// 正在重新开始抓取（防止取消隐藏通知和单击同时触发两次）
    private var isResuming = false
    /// 用户要的区域（窗口内坐标，点，左上角原点）；nil 表示整个窗口。窗口变小时实际抓取的区域会被裁剪。
    /// 它也是缩放的基准：区域 PiP 的可见区域不会超出这块区域。
    private let requestedRegion: CGRect?
    /// 放大后要看的可见区域（窗口内坐标，点，左上角原点）；nil 表示整个基准矩形。
    /// 由 PiPContentView 算好，缩放 / 平移停下后经 setVisibleRegion 交过来。
    private var visibleRegion: CGRect?
    /// 缩放基准矩形（窗口内坐标，点）：区域 PiP 是那块区域，否则是整个窗口；窗口变小时跟着变。
    private(set) var baseRect: CGRect
    private var state: State = .idle
    private var stream: SCStream?

    /// 当前实际抓取的源尺寸（点）、区域和像素比例
    private var sourceSize: CGSize
    private var sourceRect: CGRect?
    private var scale: CGFloat = 2
    /// 用户设定的帧率（按 app 记录或全局默认），实际帧率还要看静止降帧和遮挡暂停
    private var fps = CaptureSettings.defaultFrameRate
    /// 画面静止降帧：相邻帧指纹相同已超过 staticTimeout
    private var isPictureStatic = false
    private var lastFrameFingerprint: UInt64?
    /// 最近一次确认画面有变化的时间（systemUptime，单调）
    private var lastContentChange = ProcessInfo.processInfo.systemUptime
    /// 最近一帧到达的时间（systemUptime）；还没收到过帧时为 nil
    private var lastFrameUptime: TimeInterval?
    /// 面板被完全遮挡或不在当前桌面（由 PiPPanel 每秒检查）
    private var isOccluded = false
    /// 原窗口最小化（由 PiPPanel 每秒检查）：最小化时没有新帧是正常的
    private var isSourceMinimized = false
    /// 渲染卡顿分级判断；期望间隔在每次周期检查时按实际帧率更新
    private var watchdog = RendererWatchdog(expectedInterval: 1)
    /// 正在重建流（卡顿第 2 级），避免重入
    private var isRestartingStream = false
    /// 输出尺寸上限（像素），通常是 PiP 面板的像素尺寸；nil 表示按源的原生分辨率
    private var outputLimit: CGSize?

    private var lastGeometry: FrameGeometry?
    /// 最近一次检查原窗口几何的时间（systemUptime，单调）；-∞ 表示还没检查过
    private var lastGeometryCheck = -TimeInterval.infinity
    private var isUpdating = false
    private var needsUpdate = false
    private var sourceTimer: Timer?
    /// 等待配置更新结束的截图请求（setNeedsUpdate 的更新结束时唤醒）
    private var updateWaiters: [CheckedContinuation<Void, Never>] = []
    /// 截图进行中（同一时间只截一张）
    private var isTakingSnapshot = false
    /// 截图在等的那一帧：像素尺寸和原生分辨率配置一致的下一帧完整帧
    private var frameWaiter: CheckedContinuation<CapturedFrame, any Error>?
    private var awaitedPixelSize = CGSize.zero
    /// 最近一帧完整帧（面板也持有同一帧，不多占缓冲）：已经是原生分辨率时截图直接用它，
    /// 画面静止时 ScreenCaptureKit 不发新的完整帧
    private var lastFrame: CapturedFrame?
    /// 每次等帧加一，旧的超时任务不会误伤后一次截图
    private var frameWaitID = 0

    private nonisolated let mailbox = FrameMailbox()
    private nonisolated let queue = DispatchQueue(label: "PipDog.capture")

    var onFrame: ((CapturedFrame) -> Void)?
    /// 基准矩形的大小（点）变化时调用，用来调整面板宽高比
    var onSourceSizeChange: ((CGSize) -> Void)?
    /// 基准矩形变化时调用（原窗口 resize、区域被窗口裁小），用来重算缩放以它为准
    var onBaseRectChange: ((CGRect) -> Void)?
    /// 抓取意外结束（原窗口关闭、app 退出、出错）时调用；收到后应走正常的关闭流程（stop）。原 app 被隐藏不会调用
    var onStop: ((StopReason) -> Void)?
    /// 渲染卡顿重申配置、重建流都没能恢复时调用（由面板提示用户）
    var onRendererStalled: (() -> Void)?

    init(window: SCWindow, region: CGRect?) {
        self.window = window
        sourcePID = window.owningApplication?.processID
        requestedRegion = region
        baseRect = region ?? CGRect(origin: .zero, size: window.frame.size)
        sourceRect = region
        sourceSize = baseRect.size
        super.init()
    }

    /// 开始抓取。启动期间调用了 stop() 的话，正常返回（不抛错），由调用方当作已关闭处理。
    func start(fps: Int) async throws {
        guard state == .idle else { return }
        // 上一轮流可能留下没取走的帧和「已安排投递」标志：不清干净的话，新流的投递会被它永久吞掉
        _ = mailbox.take()
        self.fps = fps
        resetStaticDetection()
        let filter = SCContentFilter(desktopIndependentWindow: window)
        scale = CGFloat(filter.pointPixelScale)
        needsUpdate = false // 下面的配置已经包含当前所有设置
        let stream = SCStream(filter: filter, configuration: makeConfiguration(), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        state = .starting
        do {
            try await stream.startCapture()
        } catch {
            // 启动期间已经 stop()（用户关掉了）或 pauseUntilShown()（原 app 隐藏 / 最小化）：
            // 保持调用方设定的状态，不把它改写成 stopped，也不报错
            let superseded = state != .starting
            if !superseded { state = .stopped }
            detach(stream)
            if superseded { return }
            throw error
        }
        guard state == .starting else {
            // 启动期间已经调用了 stop()：现在才能真正停掉
            try? await stream.stopCapture()
            detach(stream)
            return
        }
        Permissions.recordCaptureSuccess()
        state = .running
        lastFrameUptime = nil
        // 任意一帧（包括内容没变的 idle 帧）都算「流还在给帧」；启动时从现在重新算
        mailbox.noteArrival(at: ProcessInfo.processInfo.systemUptime)
        watchdog.setExpectedInterval(1 / Double(max(effectiveFrameRate, 1)))
        watchdog.beginMonitoring(at: ProcessInfo.processInfo.systemUptime)
        sourceTimer = Timer.scheduledOnCommonModes(interval: Self.sourceCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.periodicCheck() }
        }
        // 启动期间改过帧率或面板尺寸的话，补上最新的
        if needsUpdate { setNeedsUpdate() }
    }

    /// 实时修改帧率。
    func setFrameRate(_ fps: Int) {
        guard fps != self.fps else { return }
        self.fps = fps
        setNeedsUpdate()
    }

    /// 面板被其他窗口完全遮挡、或不在当前桌面时为 true：实际帧率降到 1 fps，恢复可见后立即回来。
    func setOccluded(_ occluded: Bool) {
        guard occluded != isOccluded else { return }
        isOccluded = occluded
        setNeedsUpdate()
    }

    /// 原窗口最小化（面板每秒检查）。最小化时 ScreenCaptureKit 可能不再发帧，这不是渲染卡顿。
    func setSourceMinimized(_ minimized: Bool) {
        guard minimized != isSourceMinimized else { return }
        isSourceMinimized = minimized
        // 最小化期间帧会停：取消最小化后从这一刻重新起算，不要拿最小化之前的到达时间当「上一帧」
        if !minimized { watchdog.beginMonitoring(at: ProcessInfo.processInfo.systemUptime) }
    }

    /// 因为原 app 隐藏 / 窗口暂时不见而暂停（保留最后一帧，等 resumeAfterUnhide）
    var isPaused: Bool { state == .paused }

    /// 距离上一帧多久（秒）；还没收到过帧时为 nil。Chromium 停帧提示用。
    var secondsSinceLastFrame: TimeInterval? {
        lastFrameTime.map { ProcessInfo.processInfo.systemUptime - $0 }
    }

    /// 最近一帧到达的时间（systemUptime，包括内容没变的 idle 帧）；还没收到过帧时为 nil。
    /// 「流还在给帧」用它（渲染卡顿、Chromium 停画提示），「画面有没有变化」用 lastFrameTime。
    var lastArrivalTime: TimeInterval? { mailbox.arrivalTime }

    /// 最近一帧完整帧的时间（systemUptime）；还没收到过帧时为 nil。
    var lastFrameTime: TimeInterval? { lastFrameUptime }

    /// 设置里的「静止时降到 1 fps」「被遮挡时暂停」变了：关掉的那一项立即恢复，不用等下一次判断。
    func reapplyEfficiencySettings() {
        let settings = CaptureSettings.shared
        var changed = false
        if !settings.reduceFrameRateWhenStatic, isPictureStatic {
            isPictureStatic = false
            lastFrameFingerprint = nil
            changed = true
        }
        if !settings.pauseWhenObscured, isOccluded {
            isOccluded = false
            changed = true
        }
        if changed { setNeedsUpdate() }
    }

    /// 设置输出尺寸上限（像素），一般在面板缩放结束时调用。变化很小时忽略。
    func setOutputLimit(_ pixels: CGSize) {
        guard pixels.width >= 1, pixels.height >= 1 else { return }
        if let outputLimit, abs(outputLimit.width - pixels.width) < 2, abs(outputLimit.height - pixels.height) < 2 { return }
        outputLimit = pixels
        setNeedsUpdate()
    }

    /// 设置放大后要看的可见区域（窗口内坐标，点，左上角原点）。裁剪回窗口和区域 PiP 的基准内；
    /// 和整个基准一样大时收回整块，让 ScreenCaptureKit 直接抓整个窗口（回 1 倍恢复整窗）。
    func setVisibleRegion(_ region: CGRect) {
        let newRegion = Self.clampedRegion(region, in: baseRect)
        guard newRegion != visibleRegion else { return }
        visibleRegion = newRegion
        sourceRect = newRegion ?? (requestedRegion == nil ? nil : baseRect)
        sourceSize = (newRegion ?? baseRect).size
        setNeedsUpdate()
    }

    /// 停止抓取并移除输出。可以重复调用；启动还没完成时调用，会在启动完成后立刻停掉。
    func stop() async {
        let previous = state
        state = .stopped
        sourceTimer?.invalidate()
        sourceTimer = nil
        watchdog.reset()
        onFrame = nil
        onSourceSizeChange = nil
        onBaseRectChange = nil
        onStop = nil
        onRendererStalled = nil
        _ = mailbox.take()
        lastFrame = nil
        failFrameWaiter(SnapshotError.notCapturing)
        resumeUpdateWaiters()
        guard previous == .running, let stream else { return } // paused 时流已经拆掉了
        try? await stream.stopCapture()
        detach(stream)
    }

    /// 原尺寸截图一张（快速查看用）：从正在运行的抓取流里取，不另开 ScreenCaptureKit 会话
    /// （同一窗口再开一个截图会话会和这条流冲突）。临时把这条流切到原生分辨率（不受面板尺寸和 4096 上限影响，
    /// 区域 PiP 仍是那块区域，放大时是当前可见区域），等到下一帧这个尺寸的完整帧，复制成 CGImage，再恢复原来的配置。
    func snapshot() async throws -> CGImage {
        guard !isTakingSnapshot else { throw SnapshotError.busy }
        if state == .paused, let lastFrame { return try Self.copyImage(lastFrame) } // 原 app 隐藏中：用停住的画面
        guard WindowLocator.bounds(of: window.windowID) != nil else { throw SnapshotError.windowClosed }
        guard state == .running, stream != nil else { throw SnapshotError.notCapturing }
        let pixels = nativePixelSize()
        if let lastFrame, Self.pixelSize(of: lastFrame) == pixels { return try Self.copyImage(lastFrame) }
        isTakingSnapshot = true
        defer { isTakingSnapshot = false }

        // 不和 setNeedsUpdate 的配置更新交错：等它结束，再把这次截图当作进行中的更新
        while isUpdating { await withCheckedContinuation { updateWaiters.append($0) } }
        guard state == .running, let stream else { throw SnapshotError.notCapturing }
        isUpdating = true
        defer {
            // 恢复：用 makeConfiguration()（面板尺寸上限 + 4096）重新配置；已经停止时 setNeedsUpdate 什么都不做
            isUpdating = false
            resumeUpdateWaiters()
            setNeedsUpdate()
        }

        awaitedPixelSize = pixels
        try await stream.updateConfiguration(makeConfiguration(pixelSize: pixels))
        guard state == .running else { throw SnapshotError.notCapturing }
        do {
            let frame = try await nextFrame(timeout: .seconds(1.5))
            return try Self.copyImage(frame) // 在恢复配置（IOSurface 被复用）之前把像素复制出来
        } catch SnapshotError.timedOut {
            // 画面不动的窗口（或原 app 被隐藏）不一定再发新帧：退回到当前画面（可能小于原尺寸）
            guard let lastFrame else { throw SnapshotError.timedOut }
            NSLog("PipDog: no full-size frame arrived in time; Quick Look uses the current frame")
            return try Self.copyImage(lastFrame)
        }
    }

    private static func pixelSize(of frame: CapturedFrame) -> CGSize {
        CGSize(width: CVPixelBufferGetWidth(frame.pixelBuffer), height: CVPixelBufferGetHeight(frame.pixelBuffer))
    }

    private static let ciContext = CIContext()

    /// 把一帧复制成独立的 CGImage（不再依赖抓取流的 IOSurface）。
    private static func copyImage(_ frame: CapturedFrame) throws -> CGImage {
        let image = CIImage(cvPixelBuffer: frame.pixelBuffer)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let cgImage = ciContext.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace)
        else { throw SnapshotError.conversionFailed }
        return cgImage
    }

    enum SnapshotError: LocalizedError {
        case windowClosed, notCapturing, busy, timedOut, conversionFailed
        var errorDescription: String? {
            switch self {
            case .windowClosed: String(localized: "the source window is closed or not visible")
            case .notCapturing: String(localized: "this PiP has no picture yet")
            case .busy: String(localized: "the previous snapshot isn't finished yet")
            case .timedOut: String(localized: "the source window can't be captured right now (it may be minimized or hidden). Try again later.")
            case .conversionFailed: String(localized: "couldn't create the snapshot")
            }
        }
    }

    /// 等下一帧像素尺寸为 awaitedPixelSize 的完整帧；超时或抓取停止时抛错。
    private func nextFrame(timeout: Duration) async throws -> CapturedFrame {
        try await withCheckedThrowingContinuation { continuation in
            frameWaiter = continuation
            frameWaitID += 1
            let id = frameWaitID
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, self.frameWaitID == id else { return }
                self.failFrameWaiter(SnapshotError.timedOut)
            }
        }
    }

    private func failFrameWaiter(_ error: any Error) {
        guard let waiter = frameWaiter else { return }
        frameWaiter = nil
        waiter.resume(throwing: error)
    }

    private func resumeUpdateWaiters() {
        let waiters = updateWaiters
        updateWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// 截图在等的话，把尺寸对得上的帧交给它（更新前排队的旧尺寸帧不算）。
    private func handOverToSnapshot(_ frame: CapturedFrame) {
        guard let waiter = frameWaiter, Self.pixelSize(of: frame) == awaitedPixelSize else { return }
        frameWaiter = nil
        waiter.resume(returning: frame)
    }

    // MARK: - 配置

    /// 按当前状态新建一份配置（每次更新都用新对象）。pixelSize 为 nil 时用面板尺寸上限（outputPixelSize）。
    private func makeConfiguration(pixelSize: CGSize? = nil) -> sending SCStreamConfiguration {
        let config = SCStreamConfiguration()
        if let sourceRect { config.sourceRect = sourceRect }
        let output = pixelSize ?? outputPixelSize()
        config.width = Int(output.width)
        config.height = Int(output.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(effectiveFrameRate, 1)))
        config.showsCursor = false
        config.queueDepth = 3 // 面板持有 1 帧、信箱里最多 1 帧，再留 1 帧给 ScreenCaptureKit
        return config
    }

    /// 实际使用的帧率：设定的帧率；画面静止或被遮挡时是 1 fps。截图期间用设定的帧率，免得等一帧等太久。
    private var effectiveFrameRate: Int {
        if isTakingSnapshot { return fps }
        let settings = CaptureSettings.shared
        if settings.reduceFrameRateWhenStatic, isPictureStatic { return Self.lowPowerFrameRate }
        if settings.pauseWhenObscured, isOccluded { return Self.lowPowerFrameRate }
        return fps
    }

    /// 当前可见区域的原生像素尺寸（截图用，不受面板尺寸和长边上限影响）。
    private func nativePixelSize() -> CGSize {
        CGSize(width: max((sourceSize.width * scale).rounded(), 1), height: max((sourceSize.height * scale).rounded(), 1))
    }

    /// 输出像素尺寸：可见区域的原生像素尺寸，按面板尺寸和长边上限等比缩小（不放大）。
    private func outputPixelSize() -> CGSize {
        var width = max(sourceSize.width * scale, 1)
        var height = max(sourceSize.height * scale, 1)
        func fit(maxWidth: CGFloat, maxHeight: CGFloat) {
            let factor = min(1, maxWidth / width, maxHeight / height)
            width *= factor
            height *= factor
        }
        if let outputLimit { fit(maxWidth: outputLimit.width, maxHeight: outputLimit.height) }
        fit(maxWidth: Self.maximumOutputDimension, maxHeight: Self.maximumOutputDimension)
        // 先向下取整：四舍五入可能让长边变成上限 + 1，而且配置用的是 Int
        return CGSize(width: max(width.rounded(.down), 1), height: max(height.rounded(.down), 1))
    }

    /// 唯一的配置更新入口：串行执行，更新期间又有变化时结束后再更新一次。启动中只记下，启动完成后统一应用。
    private func setNeedsUpdate() {
        needsUpdate = true
        guard state == .running, !isUpdating, stream != nil else { return }
        isUpdating = true
        Task {
            while needsUpdate, state == .running {
                needsUpdate = false
                // 用当时的 self.stream：等待期间可能已经重建过流，对旧流更新配置会吞掉这次变化
                guard let stream = self.stream else { break }
                do { try await stream.updateConfiguration(makeConfiguration()) } catch {
                    NSLog("PipDog: failed to update the capture configuration: \(error.localizedDescription)")
                }
                if self.stream !== stream {
                    needsUpdate = true // 换流了：新流还没收到这次配置
                    break
                }
            }
            isUpdating = false
            resumeUpdateWaiters()
            // 更新期间被跳过的尺寸变化，在下一帧重新检查
            lastGeometry = nil
            lastGeometryCheck = -.infinity
            // 循环因状态变化退出、或期间又攒下变化（更新期间调用方只记账，不会自己再排一次）：补一次
            if needsUpdate { setNeedsUpdate() }
        }
    }

    // MARK: - 内部

    private func detach(_ stream: SCStream) {
        try? stream.removeStreamOutput(self, type: .screen)
        if self.stream === stream { self.stream = nil }
    }

    private var isActive: Bool { state == .starting || state == .running }

    private func end(_ reason: StopReason) {
        guard isActive || state == .paused else { return }
        sourceTimer?.invalidate()
        sourceTimer = nil
        if let onStop { onStop(reason) } else { Task { await stop() } }
    }

    /// 原窗口所属 app 还在运行（没退出）
    private var sourceApp: NSRunningApplication? {
        guard let sourcePID, let app = NSRunningApplication(processIdentifier: sourcePID), !app.isTerminated else { return nil }
        return app
    }

    /// 原 app 被隐藏：停掉这条流，保留最近一帧和回调，等取消隐藏后 resumeAfterUnhide()。不调用 onStop。
    func pauseUntilShown() {
        guard isActive else { return }
        state = .paused
        sourceTimer?.invalidate()
        sourceTimer = nil
        watchdog.reset()
        _ = mailbox.take()
        failFrameWaiter(SnapshotError.timedOut) // 进行中的截图退回到最近一帧
        resumeUpdateWaiters()
        guard let stream else { return }
        detach(stream)
        Task { try? await stream.stopCapture() } // 流可能已经被系统停了，失败不要紧
    }

    /// 原 app 取消隐藏后重新开始抓取。返回 true：正在抓取（恢复成功或本来就没暂停）；
    /// false：没能恢复（仍暂停，可以再试）；nil：app 还隐藏着、另一次恢复正在进行，或抓取已经结束。
    /// 窗口刚显示时 ScreenCaptureKit 可能还没列出它，约 1 秒内重试几次。
    func resumeAfterUnhide() async -> Bool? {
        guard state == .paused else { return isActive ? true : nil }
        guard !isResuming else { return nil }
        isResuming = true
        defer { isResuming = false }
        for attempt in 0..<8 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(150)) }
            guard state == .paused else { return nil } // 期间被关掉了
            guard let app = sourceApp else {
                end(.windowClosed)
                return nil
            }
            if app.isHidden { return nil } // 又被隐藏了，等下一次取消隐藏
            guard let found = try? await WindowLocator.shareableWindow(for: window.windowID) else { continue }
            guard state == .paused else { return nil }
            window = found
            state = .idle
            do {
                try await start(fps: fps)
                return isActive
            } catch {
                NSLog("PipDog: failed to restart capture after unhide: \(error.localizedDescription)")
                state = .paused
                end(.failed(error))
                return nil
            }
        }
        // 一直找不到：窗口真的不见了就结束；否则保持暂停，下次单击小窗再试
        if state == .paused, sourceApp?.isHidden == false, WindowLocator.bounds(of: window.windowID) == nil {
            end(.windowClosed)
            return nil
        }
        return state == .paused ? false : nil
    }

    /// 流停了或窗口不在窗口列表里了：app 退出就结束；否则先暂停，稍等再判断
    /// （隐藏时 isHidden 可能晚一点才更新）：被隐藏就保持暂停；窗口不见了算关闭；
    /// 窗口还在但流出错（如撤销了屏幕录制权限）按错误结束；窗口还在且没出错就重新开始抓取。
    private func sourceMayHaveGone(error: (any Error)?) {
        guard isActive else { return }
        guard sourceApp != nil else { return end(.windowClosed) }
        pauseUntilShown()
        Task { await settleAfterPause(error: error) }
    }

    /// 暂停之后再判断：app 隐藏就继续等；窗口真的没了就结束；窗口还在但流出错按错误结束；否则重新开始抓取。
    private func settleAfterPause(error: (any Error)?) async {
        try? await Task.sleep(for: .milliseconds(600))
        guard state == .paused, !isResuming, let app = sourceApp else {
            if state == .paused, !isResuming { end(.windowClosed) }
            return
        }
        if app.isHidden { return }
        if WindowLocator.bounds(of: window.windowID) == nil {
            end(.windowClosed)
        } else if let error {
            end(.failed(error))
        } else {
            _ = await resumeAfterUnhide()
        }
    }

    fileprivate func deliverLatestFrame() {
        // 不管是否活动都先把帧取走：投递标志（deliveryScheduled）留着不清，之后新流的投递就会被永久吞掉
        guard let frame = mailbox.take(), isActive else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lastFrame = frame
        lastFrameUptime = now
        handOverToSnapshot(frame)
        onFrame?(frame)
        followSourceGeometry(frame.geometry)
        trackStaticPicture(frame, at: now)
    }

    // MARK: - 渲染卡顿分级恢复

    /// 周期检查：先看该来的帧是不是没来（渲染卡顿），再看原窗口是否还在。
    private func periodicCheck() {
        checkRendererHealth()
        checkSource(scaleFactor: nil)
    }

    /// 按当前帧率判断「该来一帧却没来」并分级恢复：重申配置 → 重建流 → 提示用户。
    /// 「来了一帧」按 ScreenCaptureKit 送来的任意帧算（包括画面没变的 idle 帧）：静止的窗口
    /// 只有 idle 帧，不能当成卡顿。静止降帧、被遮挡、最小化、截图、暂停时不监控。
    private func checkRendererHealth() {
        guard state == .running, !isTakingSnapshot, !isLowPowerCapture, !isSourceMinimized else {
            watchdog.reset()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if watchdog.isMonitoring {
            if let arrival = mailbox.arrivalTime {
                let wasStalled = watchdog.isInStall
                watchdog.recordFrame(at: arrival)
                if wasStalled, !watchdog.isInStall { NSLog("PipDog: frames are arriving again") }
            }
        } else {
            // 刚从「不监控」回来（最小化、遮挡、低功耗、截图结束）：从这一刻重新算。
            // 拿排除期间（可能已经很久之前）的到达时间当「上一帧」会在同一轮就判成卡顿。
            watchdog.beginMonitoring(at: now)
        }
        watchdog.setExpectedInterval(1 / Double(max(effectiveFrameRate, 1)))
        switch watchdog.tick(now: now) {
        case .none:
            break
        case .reapplyConfiguration:
            NSLog("PipDog: no frame arrived in time; reapplying the capture configuration")
            setNeedsUpdate()
        case .restartStream:
            NSLog("PipDog: the picture is still stuck; restarting the capture stream")
            restartCaptureStream()
        case .notifyUser:
            NSLog("PipDog: the capture stream is still not delivering frames")
            onRendererStalled?()
        }
    }

    /// 低功耗抓取（静止降帧 / 被遮挡降到 1 fps）时没有帧是正常的，不能当卡顿
    private var isLowPowerCapture: Bool {
        let settings = CaptureSettings.shared
        return (settings.reduceFrameRateWhenStatic && isPictureStatic)
            || (settings.pauseWhenObscured && isOccluded)
    }

    /// 卡顿第 2 级：把流安全地重建一次（同一个窗口、同样的配置）。关闭、暂停期间不做；
    /// 窗口当前不可抓时不动当前这条流，watchdog 保持这一级，下一次周期检查再试。
    private func restartCaptureStream() {
        guard state == .running, !isRestartingStream else { return }
        isRestartingStream = true
        Task { [weak self] in
            await self?.rebuildStream()
        }
    }

    private func rebuildStream() async {
        defer { isRestartingStream = false }
        guard state == .running, let old = stream else { return }
        // 先确认窗口还能抓再动手：窗口暂时不在 ScreenCaptureKit 的 on-screen 列表里（最小化、别的 Space、
        // 列表慢一拍）时，拆掉旧流只会把画面停在一个没人恢复的暂停态。
        // 什么都不改，watchdog 停在当前级别，下一次周期检查再试。
        guard let found = try? await WindowLocator.shareableWindow(for: window.windowID) else {
            NSLog("PipDog: the source window isn't available for capture right now; keeping the current stream")
            watchdog.retryRestart(at: ProcessInfo.processInfo.systemUptime)
            return
        }
        guard state == .running, stream === old else { return } // 等待期间流换了，或用户关掉了小窗
        sourceTimer?.invalidate()
        sourceTimer = nil
        // 先离开 running，再把旧流彻底停掉；start() 会重新建流并重新装上 sourceTimer
        state = .idle
        stream = nil
        try? await old.stopCapture()
        detach(old)
        guard state == .idle else { return } // 期间用户关掉了小窗
        window = found
        do {
            try await start(fps: fps)
            watchdog.noteStreamRestarted(at: ProcessInfo.processInfo.systemUptime)
        } catch {
            NSLog("PipDog: failed to restart capture after a renderer stall: \(error.localizedDescription)")
            // 新流建不起来（例如屏幕录制被撤销）：按抓取失败结束，由面板提示并关闭，
            // 不要停在没有定时器的暂停态里（end() 只在活动或暂停时生效）
            state = .paused
            end(.failed(error))
        }
    }

    // MARK: - 画面静止降帧

    /// 比较相邻帧的低分辨率指纹：连续 staticTimeout 没变化就降到 1 fps，一有变化立刻恢复。
    /// 指纹在帧回调已有的主线程跳转里算（一帧约 4096 个采样点），不另建 Task，也不在非主线程碰像素。
    private func trackStaticPicture(_ frame: CapturedFrame, at now: TimeInterval) {
        guard CaptureSettings.shared.reduceFrameRateWhenStatic else { return }
        guard let fingerprint = FrameFingerprint.of(frame.pixelBuffer) else {
            contentDidChange(at: now) // 算不出指纹（不是 BGRA）：保守当作有变化，宁可不降帧
            return
        }
        guard fingerprint == lastFrameFingerprint else {
            lastFrameFingerprint = fingerprint
            contentDidChange(at: now)
            return
        }
        guard !isPictureStatic, now - lastContentChange >= Self.staticTimeout else { return }
        isPictureStatic = true
        NSLog("PipDog: the picture has been static for a while; capturing at %d fps", Self.lowPowerFrameRate)
        setNeedsUpdate()
    }

    private func contentDidChange(at now: TimeInterval) {
        lastContentChange = now
        guard isPictureStatic else { return }
        isPictureStatic = false
        NSLog("PipDog: the picture changed again; capturing at %d fps", fps)
        setNeedsUpdate()
    }

    /// 开始抓取时清空静止检测：新流的第一帧一定算「有变化」。
    private func resetStaticDetection() {
        lastFrameFingerprint = nil
        lastContentChange = ProcessInfo.processInfo.systemUptime
        isPictureStatic = false
    }

    fileprivate func streamDidStop(with error: any Error) {
        NSLog("PipDog: capture stopped: \(error.localizedDescription)")
        sourceMayHaveGone(error: error)
    }

    /// 帧信息（contentRect / contentScale / scaleFactor）变化时立即检查原窗口，否则最多每秒检查一次。
    private func followSourceGeometry(_ geometry: FrameGeometry) {
        let now = ProcessInfo.processInfo.systemUptime
        guard geometry != lastGeometry || now - lastGeometryCheck >= 1 else { return }
        lastGeometry = geometry
        lastGeometryCheck = now
        checkSource(scaleFactor: geometry.scaleFactor)
    }

    /// 检查原窗口：已关闭就结束；基准矩形、可见区域或像素比例变了就更新配置。
    private func checkSource(scaleFactor: CGFloat?) {
        guard state == .running else { return }
        guard let bounds = WindowLocator.bounds(of: window.windowID) else {
            sourceMayHaveGone(error: nil)
            return
        }
        let newBase = baseRect(forWindowOf: bounds.size)
        guard newBase.width >= 1, newBase.height >= 1 else { return }
        // 窗口变小时可见区域跟着裁剪回窗口内
        let newVisible = visibleRegion.flatMap { Self.clampedRegion($0, in: newBase) }
        let newRect = newVisible ?? (requestedRegion == nil ? nil : newBase)
        let newSize = (newVisible ?? newBase).size
        let newScale = scaleFactor ?? scale
        let baseChanged = !newBase.equalTo(baseRect)
        let sizeChanged = abs(newSize.width - sourceSize.width) >= 1 || abs(newSize.height - sourceSize.height) >= 1
        let rectChanged = newRect != sourceRect
        guard baseChanged || sizeChanged || rectChanged || abs(newScale - scale) > 0.01 else { return }
        visibleRegion = newVisible
        baseRect = newBase
        sourceRect = newRect
        sourceSize = newSize
        scale = newScale
        setNeedsUpdate()
        if baseChanged {
            onBaseRectChange?(newBase)
            onSourceSizeChange?(newBase.size)
        }
    }

    /// 基准矩形（窗口内坐标，点）：区域 PiP 是那块区域，否则是整个窗口。
    private func baseRect(forWindowOf size: CGSize) -> CGRect {
        let window = CGRect(origin: .zero, size: size)
        guard let requestedRegion else { return window }
        return Self.regionInsideWindow(requestedRegion, in: window)
    }

    /// 区域裁进窗口；窗口小到区域和它完全不相交时，把整块区域移回窗口内（贴着最近的边），
    /// 不让一块落在窗外的矩形继续当抓取范围（那会停在最后一帧）。
    private static func regionInsideWindow(_ region: CGRect, in window: CGRect) -> CGRect {
        let clipped = region.intersection(window)
        guard clipped.isNull || clipped.width < 1 || clipped.height < 1 else { return clipped }
        let width = min(region.width, window.width)
        let height = min(region.height, window.height)
        let x = min(max(region.minX, window.minX), window.maxX - width)
        let y = min(max(region.minY, window.minY), window.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// 要看的区域裁剪回基准内；和整个基准差不多大时返回 nil（抓整块）。
    private static func clampedRegion(_ region: CGRect, in base: CGRect) -> CGRect? {
        let clipped = region.intersection(base)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
        guard clipped.width < base.width - 0.5 || clipped.height < base.height - 0.5 else { return nil }
        return clipped
    }
}

extension WindowCapture: SCStreamOutput, SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .screen else { return }
        mailbox.noteArrival(at: ProcessInfo.processInfo.systemUptime)
        guard let frame = CapturedFrame(sampleBuffer), mailbox.put(frame) else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.deliverLatestFrame() }
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.streamDidStop(with: error) }
        }
    }
}
