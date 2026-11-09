import ScreenCaptureKit
import CoreMedia
import IOSurface

/// 用 ScreenCaptureKit 抓取单个窗口（或窗口里的一块区域）的画面，并把每一帧交给主线程。
final class WindowCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    private let window: SCWindow
    /// 窗口内的区域，单位是点，原点在窗口左上角；nil 表示整个窗口。
    private let sourceRect: CGRect?
    private var stream: SCStream?
    private var configuration: SCStreamConfiguration?
    private let queue = DispatchQueue(label: "PipDog.capture")
    @MainActor var onFrame: ((IOSurface) -> Void)?

    init(window: SCWindow, sourceRect: CGRect? = nil) {
        self.window = window
        self.sourceRect = sourceRect
    }

    func start(fps: Int) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        let size: CGSize
        if let sourceRect {
            config.sourceRect = sourceRect
            size = sourceRect.size
        } else {
            size = window.frame.size
        }
        config.width = max(Int(size.width * scale), 1)
        config.height = max(Int(size.height * scale), 1)
        config.minimumFrameInterval = Self.frameInterval(fps)
        config.showsCursor = false
        config.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        self.configuration = config
    }

    /// 实时修改帧率；sourceRect 和输出尺寸保持不变。
    func setFrameRate(_ fps: Int) async throws {
        guard let stream, let configuration else { return }
        configuration.minimumFrameInterval = Self.frameInterval(fps)
        try await stream.updateConfiguration(configuration)
    }

    private static func frameInterval(_ fps: Int) -> CMTime {
        CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        configuration = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return }
        let surface = surfaceRef as IOSurface
        Task { @MainActor in self.onFrame?(surface) }
    }
}
