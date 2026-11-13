import CoreVideo

/// 画面静止检测用的廉价指纹：把一帧按 64 × 64 网格最近邻抽样成灰度，再混成一个 UInt64。
///
/// 只读像素、不分配内存、不做颜色转换：一帧 4096 个采样点，量级是几十微秒，所以在帧回调已有的
/// 主线程跳转里直接算即可（不建 Task，也不把 CVPixelBuffer 带到别的线程）。
/// 灰度压到 4 bit，忽略抖动 / 压缩带来的极小差异；宽度和高度也混进指纹，分辨率变了就算「有变化」。
enum FrameFingerprint {
    /// 网格边长（每帧采样 gridSize × gridSize 个点）
    static let gridSize = 64
    /// FNV-1a 的质数
    private static let prime: UInt64 = 0x0000_0100_0000_01b3

    /// 只处理抓取用的 32BGRA 打包格式；其他格式返回 nil，调用方当作「本帧判断不了」。
    static func of(_ pixelBuffer: CVPixelBuffer) -> UInt64? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              !CVPixelBufferIsPlanar(pixelBuffer),
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess
        else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0, bytesPerRow >= width * 4 else { return nil }

        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV-1a 的初始值
        for row in 0..<gridSize {
            let y = min(height - 1, (row * height + height / 2) / gridSize)
            let line = bytes + y * bytesPerRow
            for column in 0..<gridSize {
                let x = min(width - 1, (column * width + width / 2) / gridSize)
                let pixel = line + x * 4
                // BGRA 的 B/G/R 三通道，按 BT.601 近似算灰度
                let luma = (UInt16(pixel[2]) * 77 + UInt16(pixel[1]) * 151 + UInt16(pixel[0]) * 28) >> 8
                hash = (hash ^ UInt64(luma >> 4)) &* prime
            }
        }
        hash = (hash ^ UInt64(width)) &* prime
        hash = (hash ^ UInt64(height)) &* prime
        return hash
    }
}
