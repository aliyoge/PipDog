import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import ScreenCaptureKit

/// 一帧里和尺寸有关的附加信息，变化时说明原窗口可能改了大小或换了屏幕。
struct FrameGeometry: Equatable, Sendable {
    var contentRect: CGRect?
    var contentScale: CGFloat?
    var scaleFactor: CGFloat?
}

/// 一帧画面。持有 CVPixelBuffer：在它显示期间，ScreenCaptureKit 不会把同一块 IOSurface 拿去写下一帧。
struct CapturedFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let surface: IOSurface
    let geometry: FrameGeometry

    /// 只接受内容完整的帧（status == .complete），其余返回 nil。
    init?(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let statusRaw = info[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return nil }
        self.pixelBuffer = pixelBuffer
        surface = surfaceRef as IOSurface
        geometry = FrameGeometry(
            contentRect: (info[.contentRect] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) },
            contentScale: (info[.contentScale] as? NSNumber).map { CGFloat($0.doubleValue) },
            scaleFactor: (info[.scaleFactor] as? NSNumber).map { CGFloat($0.doubleValue) })
    }
}

/// 抓取线程和主线程之间只传「最新一帧」：主线程来不及显示时旧帧直接被覆盖，不会积压。
/// 另外记下任意一帧（包括内容没变的 idle 帧）到达的时间：渲染卡顿判断靠它区分
/// 「画面静止，流还在给帧」和「流真的不给帧了」。
final class FrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CapturedFrame?
    private var deliveryScheduled = false
    private var lastArrival: TimeInterval?

    /// 抓取回调线程：记下这一帧到达的时间（systemUptime）。
    func noteArrival(at uptime: TimeInterval) {
        lock.withLock { lastArrival = uptime }
    }

    /// 最近一次有帧到达的时间（任意状态）；还没有为 nil。
    var arrivalTime: TimeInterval? {
        lock.withLock { lastArrival }
    }

    /// 放入最新一帧。返回 true 表示需要安排一次主线程投递（已经安排过就返回 false）。
    func put(_ frame: CapturedFrame) -> Bool {
        lock.withLock {
            latest = frame
            if deliveryScheduled { return false }
            deliveryScheduled = true
            return true
        }
    }

    /// 取出最新一帧（主线程调用）。
    func take() -> CapturedFrame? {
        lock.withLock {
            deliveryScheduled = false
            let frame = latest
            latest = nil
            return frame
        }
    }
}
