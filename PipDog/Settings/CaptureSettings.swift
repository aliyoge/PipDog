import Foundation
import Observation

/// 画面抓取相关设置（目前只有帧率），单独存一个 UserDefaults 键；没有保存过时用默认值。
@MainActor
@Observable
final class CaptureSettings {
    static let shared = CaptureSettings()
    static let frameRateOptions = [5, 10, 15, 24, 30, 60]
    static let defaultFrameRate = 10

    /// 每秒帧数。修改后立即保存，并通知已打开的 PiP。
    var frameRate: Int {
        didSet {
            guard frameRate != oldValue else { return }
            UserDefaults.standard.set(frameRate, forKey: Self.frameRateKey)
            onFrameRateChange?(frameRate)
        }
    }

    /// 由 PiPManager 设置，用来把新帧率应用到已打开的 PiP
    @ObservationIgnored var onFrameRateChange: ((Int) -> Void)?
    private static let frameRateKey = "PipDog.captureFrameRate"

    private init() {
        let saved = UserDefaults.standard.integer(forKey: Self.frameRateKey) // 没有这个键时为 0
        frameRate = Self.frameRateOptions.contains(saved) ? saved : Self.defaultFrameRate
    }

    func restoreDefaults() { frameRate = Self.defaultFrameRate }
}
