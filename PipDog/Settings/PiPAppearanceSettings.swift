import Foundation
import Observation

/// 小窗外观：不透明度和悬停自动隐藏，各存一个 UserDefaults 键；没有保存过时用 100%、开启。
/// 改了立即应用到已打开的小窗。不透明度最低 30%，不允许 0%（小窗看不见就没法再找回来）。
@MainActor
@Observable
final class PiPAppearanceSettings {
    static let shared = PiPAppearanceSettings()
    static let defaultOpacity = 1.0
    static let minimumOpacity = 0.3
    static let defaultHoverAutoHide = true

    /// 不透明度 0.3…1.0（用 NSWindow.alphaValue 应用）
    var opacity: Double {
        didSet {
            opacity = Self.clamped(opacity)
            guard opacity != oldValue else { return }
            UserDefaults.standard.set(opacity, forKey: Self.opacityKey)
            onChange?()
        }
    }

    /// 鼠标在小窗上停一会儿后淡出、点击穿透到下面的窗口
    var hoverAutoHide: Bool {
        didSet {
            guard hoverAutoHide != oldValue else { return }
            UserDefaults.standard.set(hoverAutoHide, forKey: Self.hoverAutoHideKey)
            onChange?()
        }
    }

    /// 由 PiPManager 设置，用来更新已打开的小窗
    @ObservationIgnored var onChange: (() -> Void)?
    private static let opacityKey = "PipDog.windowOpacity"
    private static let hoverAutoHideKey = "PipDog.hoverAutoHide"

    private init() {
        let defaults = UserDefaults.standard
        opacity = (defaults.object(forKey: Self.opacityKey) as? Double).map(Self.clamped) ?? Self.defaultOpacity
        hoverAutoHide = defaults.object(forKey: Self.hoverAutoHideKey) as? Bool ?? Self.defaultHoverAutoHide
    }

    func restoreDefaults() {
        opacity = Self.defaultOpacity
        hoverAutoHide = Self.defaultHoverAutoHide
    }

    private static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(max(value, minimumOpacity), 1) : defaultOpacity
    }
}
