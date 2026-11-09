import AppKit
import CoreMedia
import ScreenCaptureKit

/// 用 ScreenCaptureKit 抓取单个窗口（或窗口里的一块区域）。
/// 所有状态都在主线程上；只有 SCStream 的帧回调和停止回调是 nonisolated，
/// 它们只碰线程安全的 FrameMailbox，然后切回主线程处理。
///
/// 配置更新只有一条串行路径（setNeedsUpdate）：每次都用当前状态新建一个 SCStreamConfiguration 交给
/// updateConfiguration，不会在更新进行中修改同一个配置对象；更新期间又有变化时，结束后再更新一次。
@MainActor
final class WindowCapture: NSObject {
    enum StopReason {
        case windowClosed
        case failed(any Error)
    }

    private enum State { case idle, starting, running, stopped }

    /// 输出画面长边的上限（像素），防止超大面板或超大窗口占用过多内存
    static let maximumOutputDimension: CGFloat = 4096
    /// 不依赖帧到达、定期检查原窗口是否还在（画面静止时 ScreenCaptureKit 不发完整帧）
    private static let sourceCheckInterval: TimeInterval = 1.5

    private let window: SCWindow
    /// 用户要的区域（窗口内坐标，点，左上角原点）；nil 表示整个窗口。窗口变小时实际抓取的区域会被裁剪。
    private let requestedRegion: CGRect?
    private var state: State = .idle
    private var stream: SCStream?

    /// 当前实际抓取的源尺寸（点）、区域和像素比例
    private var sourceSize: CGSize
    private var sourceRect: CGRect?
    private var scale: CGFloat = 2
    private var fps = CaptureSettings.defaultFrameRate
    /// 输出尺寸上限（像素），通常是 PiP 面板的像素尺寸；nil 表示按源的原生分辨率
    private var outputLimit: CGSize?

    private var lastGeometry: FrameGeometry?
    private var lastGeometryCheck = Date.distantPast
    private var isUpdating = false
    private var needsUpdate = false
    private var sourceTimer: Timer?

    private nonisolated let mailbox = FrameMailbox()
    private nonisolated let queue = DispatchQueue(label: "PipDog.capture")

    var onFrame: ((CapturedFrame) -> Void)?
    /// 源尺寸（点）变化时调用，用来调整面板宽高比
    var onSourceSizeChange: ((CGSize) -> Void)?
    /// 抓取意外结束（原窗口关闭、出错）时调用；收到后应走正常的关闭流程（stop）
    var onStop: ((StopReason) -> Void)?

    init(window: SCWindow, region: CGRect?) {
        self.window = window
        requestedRegion = region
        sourceRect = region
        sourceSize = region?.size ?? window.frame.size
        super.init()
    }

    /// 开始抓取。启动期间调用了 stop() 的话，正常返回（不抛错），由调用方当作已关闭处理。
    func start(fps: Int) async throws {
        guard state == .idle else { return }
        self.fps = fps
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
            let cancelled = state == .stopped
            state = .stopped
            detach(stream)
            if cancelled { return } // 用户已经关掉了，不再报错
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
        sourceTimer = Timer.scheduledTimer(withTimeInterval: Self.sourceCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSource(scaleFactor: nil) }
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

    /// 设置输出尺寸上限（像素），一般在面板缩放结束时调用。变化很小时忽略。
    func setOutputLimit(_ pixels: CGSize) {
        guard pixels.width >= 1, pixels.height >= 1 else { return }
        if let outputLimit, abs(outputLimit.width - pixels.width) < 2, abs(outputLimit.height - pixels.height) < 2 { return }
        outputLimit = pixels
        setNeedsUpdate()
    }

    /// 停止抓取并移除输出。可以重复调用；启动还没完成时调用，会在启动完成后立刻停掉。
    func stop() async {
        let previous = state
        state = .stopped
        sourceTimer?.invalidate()
        sourceTimer = nil
        onFrame = nil
        onSourceSizeChange = nil
        onStop = nil
        _ = mailbox.take()
        guard previous == .running, let stream else { return }
        try? await stream.stopCapture()
        detach(stream)
    }

    // MARK: - 配置

    /// 按当前状态新建一份配置（每次更新都用新对象）。
    private func makeConfiguration() -> sending SCStreamConfiguration {
        let config = SCStreamConfiguration()
        if let sourceRect { config.sourceRect = sourceRect }
        let output = outputPixelSize()
        config.width = Int(output.width)
        config.height = Int(output.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))
        config.showsCursor = false
        config.queueDepth = 3 // 面板持有 1 帧、信箱里最多 1 帧，再留 1 帧给 ScreenCaptureKit
        return config
    }

    /// 输出像素尺寸：源的原生像素尺寸，按面板尺寸和长边上限等比缩小（不放大）。
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
        return CGSize(width: max(width.rounded(), 1), height: max(height.rounded(), 1))
    }

    /// 唯一的配置更新入口：串行执行，更新期间又有变化时结束后再更新一次。启动中只记下，启动完成后统一应用。
    private func setNeedsUpdate() {
        needsUpdate = true
        guard state == .running, !isUpdating, let stream else { return }
        isUpdating = true
        Task {
            while needsUpdate, state == .running {
                needsUpdate = false
                do { try await stream.updateConfiguration(makeConfiguration()) } catch {
                    NSLog("PipDog: 更新抓取配置失败：\(error.localizedDescription)")
                }
            }
            isUpdating = false
            // 更新期间被跳过的尺寸变化，在下一帧重新检查
            lastGeometry = nil
            lastGeometryCheck = .distantPast
        }
    }

    // MARK: - 内部

    private func detach(_ stream: SCStream) {
        try? stream.removeStreamOutput(self, type: .screen)
        if self.stream === stream { self.stream = nil }
    }

    private var isActive: Bool { state == .starting || state == .running }

    private func end(_ reason: StopReason) {
        guard isActive else { return }
        sourceTimer?.invalidate()
        sourceTimer = nil
        if let onStop { onStop(reason) } else { Task { await stop() } }
    }

    fileprivate func deliverLatestFrame() {
        guard isActive, let frame = mailbox.take() else { return }
        onFrame?(frame)
        followSourceGeometry(frame.geometry)
    }

    fileprivate func streamDidStop(with error: any Error) {
        NSLog("PipDog: 抓取已停止：\(error.localizedDescription)")
        end(WindowLocator.bounds(of: window.windowID) == nil ? .windowClosed : .failed(error))
    }

    /// 帧信息（contentRect / contentScale / scaleFactor）变化时立即检查原窗口，否则最多每秒检查一次。
    private func followSourceGeometry(_ geometry: FrameGeometry) {
        let now = Date()
        guard geometry != lastGeometry || now.timeIntervalSince(lastGeometryCheck) >= 1 else { return }
        lastGeometry = geometry
        lastGeometryCheck = now
        checkSource(scaleFactor: geometry.scaleFactor)
    }

    /// 检查原窗口：已关闭就结束；尺寸、区域或像素比例变了就更新配置。
    private func checkSource(scaleFactor: CGFloat?) {
        guard state == .running else { return }
        guard let bounds = WindowLocator.bounds(of: window.windowID) else {
            end(.windowClosed)
            return
        }
        let newScale = scaleFactor ?? scale
        let newRect: CGRect?
        let newSize: CGSize
        if let requestedRegion {
            let clipped = requestedRegion.intersection(CGRect(origin: .zero, size: bounds.size))
            guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return }
            newRect = clipped
            newSize = clipped.size
        } else {
            newRect = nil
            newSize = bounds.size
        }
        let sizeChanged = abs(newSize.width - sourceSize.width) >= 1 || abs(newSize.height - sourceSize.height) >= 1
        let rectChanged = newRect.map { r in sourceRect.map { !$0.equalTo(r) } ?? true } ?? false
        guard sizeChanged || rectChanged || abs(newScale - scale) > 0.01 else { return }
        sourceRect = newRect
        sourceSize = newSize
        scale = newScale
        setNeedsUpdate()
        if sizeChanged { onSourceSizeChange?(newSize) }
    }
}

extension WindowCapture: SCStreamOutput, SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .screen, let frame = CapturedFrame(sampleBuffer), mailbox.put(frame) else { return }
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
