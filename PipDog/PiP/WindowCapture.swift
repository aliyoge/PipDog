import ScreenCaptureKit
import CoreMedia
import IOSurface

/// 用 ScreenCaptureKit 抓取单个窗口的画面，并把每一帧交给主线程。
final class WindowCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    private let window: SCWindow
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "PipDog.capture")
    @MainActor var onFrame: ((IOSurface) -> Void)?

    init(window: SCWindow) { self.window = window }

    func start(fps: Int = 15) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = 2.0
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.showsCursor = false
        config.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
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
