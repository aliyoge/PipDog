import Foundation

extension Timer {
    /// 创建计时器并加到主 run loop 的 common 模式：打开菜单、显示弹框（runModal）、拖动滑块期间也照常触发。
    /// `Timer.scheduledTimer` 只在默认模式下运行，这些时候会停。
    static func scheduledOnCommonModes(interval: TimeInterval, repeats: Bool,
                                       block: @escaping @Sendable (Timer) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats, block: block)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
