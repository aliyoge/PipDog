import AppKit
import CoreMedia
import ScreenCaptureKit

/// 用 ScreenCaptureKit 抓取单个窗口（或窗口里的一块区域）。
/// 所有状态都在主线程上；只有 SCStream 的帧回调和停止回调是 nonisolated，
/// 它们只碰线程安全的 FrameMailbox，然后切回主线程处理。
@MainActor
final class WindowCapture: NSObject {
    enum StopReason {
        case windowClosed
        case failed(any Error)
    }

    private enum State { case idle, starting, running, stopped }

    private let window: SCWindow
    /// 用户要的区域（窗口内坐标，点，左上角原点）；nil 表示整个窗口。窗口变小时实际抓取的区域会被裁剪。
    private let requestedRegion: CGRect?
    private var state: State = .idle
    private var stream: SCStream?
    private var configuration: SCStreamConfiguration?

    /// 当前实际抓取的源尺寸（点）、区域和像素比例
    private var sourceSize: CGSize
    private var sourceRect: CGRect?
    private var scale: CGFloat = 2
    private var lastGeometry: FrameGeometry?
    private var lastGeometryCheck = Date.distantPast
    private var isReconfiguring = false

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

    func start(fps: Int) async throws {
        guard state == .idle else { return }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        if let sourceRect { config.sourceRect = sourceRect }
        apply(size: sourceSize, to: config)
        config.minimumFrameInterval = Self.frameInterval(fps)
        config.showsCursor = false
        config.queueDepth = 5 // 面板持有 1 帧、信箱里最多 1 帧，留足余量给 ScreenCaptureKit

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        configuration = config
        state = .starting
        do {
            try await stream.startCapture()
        } catch {
            state = .stopped
            detach(stream)
            throw error
        }
        guard state == .starting else {
            // 启动期间已经调用了 stop()：现在才能真正停掉
            try? await stream.stopCapture()
            detach(stream)
            return
        }
        state = .running
        // 启动期间改过帧率的话，补上最新的
        let wanted = CaptureSettings.shared.frameRate
        if wanted != fps { try? await setFrameRate(wanted) }
    }

    /// 实时修改帧率；区域和输出尺寸保持不变。
    func setFrameRate(_ fps: Int) async throws {
        guard state == .running, let stream, let configuration else { return }
        configuration.minimumFrameInterval = Self.frameInterval(fps)
        try await stream.updateConfiguration(configuration)
    }

    /// 停止抓取并移除输出。可以重复调用；启动还没完成时调用，会在启动完成后立刻停掉。
    func stop() async {
        let previous = state
        state = .stopped
        onFrame = nil
        onSourceSizeChange = nil
        onStop = nil
        _ = mailbox.take()
        guard previous == .running, let stream else { return }
        try? await stream.stopCapture()
        detach(stream)
    }

    // MARK: - 内部

    private static func frameInterval(_ fps: Int) -> CMTime {
        CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))
    }

    private func apply(size: CGSize, to config: SCStreamConfiguration) {
        config.width = max(Int((size.width * scale).rounded()), 1)
        config.height = max(Int((size.height * scale).rounded()), 1)
    }

    private func detach(_ stream: SCStream) {
        try? stream.removeStreamOutput(self, type: .screen)
        if self.stream === stream {
            self.stream = nil
            configuration = nil
        }
    }

    private var isActive: Bool { state == .starting || state == .running }

    private func end(_ reason: StopReason) {
        guard isActive else { return }
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

    /// 跟随原窗口的尺寸和屏幕缩放：帧信息（contentRect / contentScale / scaleFactor）变化时立即检查，否则最多每秒检查一次。
    private func followSourceGeometry(_ geometry: FrameGeometry) {
        let now = Date()
        guard geometry != lastGeometry || now.timeIntervalSince(lastGeometryCheck) >= 1 else { return }
        lastGeometry = geometry
        lastGeometryCheck = now
        guard let bounds = WindowLocator.bounds(of: window.windowID) else {
            end(.windowClosed)
            return
        }
        let newScale = geometry.scaleFactor ?? scale
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
        let changed = abs(newSize.width - sourceSize.width) >= 1 || abs(newSize.height - sourceSize.height) >= 1
            || abs(newScale - scale) > 0.01
            || (newRect.map { r in sourceRect.map { !$0.equalTo(r) } ?? true } ?? false)
        guard changed else { return }
        reconfigure(rect: newRect, size: newSize, scale: newScale)
    }

    private func reconfigure(rect: CGRect?, size: CGSize, scale newScale: CGFloat) {
        guard state == .running, !isReconfiguring, let stream, let configuration else { return }
        let sizeChanged = size != sourceSize
        sourceRect = rect
        sourceSize = size
        scale = newScale
        if let rect { configuration.sourceRect = rect }
        apply(size: size, to: configuration)
        if sizeChanged { onSourceSizeChange?(size) }
        isReconfiguring = true
        Task {
            do { try await stream.updateConfiguration(configuration) } catch {
                NSLog("PipDog: 更新抓取尺寸失败：\(error.localizedDescription)")
            }
            isReconfiguring = false
        }
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
