import AppKit
import Observation

/// 按源 app 记住的帧率（bundle ID → fps），单独存一个 UserDefaults 键。
///
/// 打开 PiP 时优先用对应 app 的记录；没有记录时用全局默认帧率。终端、编辑器这类「字多、变化慢」的 app
/// 第一次打开时记为 5 fps 并写进记录（之后用户可以在设置里改）。只认 CaptureSettings.frameRateOptions
/// 里的值：手改 plist 写进去的非法值按没有记录处理。
@MainActor
@Observable
final class AppFrameRateSettings {
    static let shared = AppFrameRateSettings()

    /// 第一次打开时默认 5 fps 的 app（终端、日志、编辑器 / IDE、活动监视器）。
    static let lowFrameRateBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.github.wez.wezterm", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "org.alacritty", "com.mitchellh.ghostty",
        "com.microsoft.VSCode", "com.apple.dt.Xcode", "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf", "dev.zed.Zed", "com.panic.Nova", "com.barebones.bbedit",
        "com.macromates.TextMate", "com.coteditor.CotEditor", "org.gnu.Emacs", "org.vim.MacVim",
        "com.apple.ActivityMonitor", "com.apple.Console",
    ]
    /// 前缀匹配的 app 系列（Sublime Text、JetBrains 全家桶的 bundle ID 带版本或产品名）
    private static let lowFrameRateBundleIDPrefixes = ["com.sublimetext.", "com.jetbrains."]
    /// 上面这些 app 第一次打开时的帧率
    static let lowFrameRate = 5

    /// 已记住的帧率，按 bundle ID 存原始值。
    private(set) var records: [String: Int]
    /// 由 PiPManager 设置：某个 app 的帧率变了，参数是 bundle ID。
    @ObservationIgnored var onChange: ((String) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    private static let recordsKey = "PipDog.perAppFrameRates"

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.dictionary(forKey: Self.recordsKey) ?? [:]
        records = saved.compactMapValues { ($0 as? NSNumber).map(\.intValue) }
            .filter { CaptureSettings.frameRateOptions.contains($0.value) }
    }

    /// 打开 PiP 时用的帧率：有记录用记录，否则用全局默认；终端 / 编辑器类 app 第一次打开记为 5 fps。
    func frameRate(forApp bundleID: String?) -> Int {
        guard let bundleID, !bundleID.isEmpty else { return CaptureSettings.shared.frameRate }
        if let recorded = records[bundleID] { return recorded }
        guard Self.isLowFrameRateApp(bundleID) else { return CaptureSettings.shared.frameRate }
        setFrameRate(Self.lowFrameRate, forApp: bundleID)
        return Self.lowFrameRate
    }

    func setFrameRate(_ fps: Int, forApp bundleID: String) {
        guard !bundleID.isEmpty, CaptureSettings.frameRateOptions.contains(fps), records[bundleID] != fps else { return }
        records[bundleID] = fps
        save()
        onChange?(bundleID)
    }

    /// 删掉记录：这个 app 回到用全局默认帧率。
    func remove(_ bundleID: String) {
        guard records.removeValue(forKey: bundleID) != nil else { return }
        save()
        onChange?(bundleID)
    }

    /// 恢复默认：清空所有记录，全部 app 都用全局默认帧率。
    func restoreDefaults() {
        guard !records.isEmpty else { return }
        let removed = records.keys.sorted()
        records = [:]
        save()
        removed.forEach { onChange?($0) }
    }

    /// 记录里显示的 app 名：先找正在运行的 app，再按 bundle ID 找磁盘上的 app，都找不到就显示 bundle ID。
    func appName(for bundleID: String) -> String {
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
           let name = running.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        return bundleID
    }

    private static func isLowFrameRateApp(_ bundleID: String) -> Bool {
        lowFrameRateBundleIDs.contains(bundleID)
            || lowFrameRateBundleIDPrefixes.contains { bundleID.hasPrefix($0) }
    }

    private func save() {
        defaults.set(records, forKey: Self.recordsKey)
    }
}
