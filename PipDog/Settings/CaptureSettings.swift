import Foundation
import Observation

/// 画面抓取相关设置：全局帧率、静止降帧和遮挡暂停，各自单独存一个 UserDefaults 键；没有保存过时用默认值。
@MainActor
@Observable
final class CaptureSettings {
    static let shared = CaptureSettings()
    static let frameRateOptions = [5, 10, 15, 24, 30, 60]
    static let defaultFrameRate = 10

    /// 每秒帧数（没有按 app 记录的 app 用这个）。修改后立即保存，并通知已打开的 PiP。
    var frameRate: Int {
        didSet {
            guard frameRate != oldValue else { return }
            UserDefaults.standard.set(frameRate, forKey: Self.frameRateKey)
            onChange?()
        }
    }

    /// 画面连续约 5 秒没有变化时把实际帧率降到 1 fps；默认开。
    var reduceFrameRateWhenStatic: Bool {
        didSet {
            guard reduceFrameRateWhenStatic != oldValue else { return }
            UserDefaults.standard.set(reduceFrameRateWhenStatic, forKey: Self.reduceFrameRateWhenStaticKey)
            onChange?()
        }
    }

    /// PiP 被其他窗口完全遮挡、或不在当前桌面时暂停刷新（降到 1 fps）；默认开。
    var pauseWhenObscured: Bool {
        didSet {
            guard pauseWhenObscured != oldValue else { return }
            UserDefaults.standard.set(pauseWhenObscured, forKey: Self.pauseWhenObscuredKey)
            onChange?()
        }
    }

    /// 由 PiPManager 设置，用来把帧率和两个节能开关的变化应用到已打开的 PiP
    @ObservationIgnored var onChange: (() -> Void)?
    private static let frameRateKey = "PipDog.captureFrameRate"
    private static let reduceFrameRateWhenStaticKey = "PipDog.reduceFrameRateWhenStatic"
    private static let pauseWhenObscuredKey = "PipDog.pauseWhenObscured"

    private init() {
        let defaults = UserDefaults.standard
        let saved = defaults.integer(forKey: Self.frameRateKey) // 没有这个键时为 0
        frameRate = Self.frameRateOptions.contains(saved) ? saved : Self.defaultFrameRate
        reduceFrameRateWhenStatic = defaults.object(forKey: Self.reduceFrameRateWhenStaticKey) as? Bool ?? true
        pauseWhenObscured = defaults.object(forKey: Self.pauseWhenObscuredKey) as? Bool ?? true
    }

    func restoreDefaults() {
        frameRate = Self.defaultFrameRate
        reduceFrameRateWhenStatic = true
        pauseWhenObscured = true
    }
}
