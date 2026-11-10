import Foundation
import Observation

/// 小窗上切回原窗口 / 移到屏幕边上用单击还是双击。
enum WindowClickMode: String, CaseIterable, Identifiable {
    case single, double

    var id: String { rawValue }
    /// 界面上的叫法，也用在「双击小窗恢复」这类提示里
    var title: String { self == .single ? String(localized: "Click") : String(localized: "Double-click") }
}

/// 小窗点击设置，单独存一个 UserDefaults 键；没有保存过时用双击。每次点击时实时读取，改了立即生效。
@MainActor
@Observable
final class WindowClickSettings {
    static let shared = WindowClickSettings()
    static let defaultMode = WindowClickMode.double

    var mode: WindowClickMode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            onModeChange?(mode)
        }
    }

    /// 由 PiPManager 设置，用来更新已打开小窗上的提示文字
    @ObservationIgnored var onModeChange: ((WindowClickMode) -> Void)?
    private static let modeKey = "PipDog.windowClickMode"

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.modeKey).flatMap(WindowClickMode.init(rawValue:))
        mode = saved ?? Self.defaultMode
    }

    func restoreDefaults() { mode = Self.defaultMode }
}
