import CoreGraphics
import Foundation

/// 存一个 PiP 位置时用的稳定键：窗口 ID + 区域（左上角原点的整数点；整窗时区域为零）。
/// 和标题、语言无关，同一目标换个标题再开也还是同一个键。
extension PiPKey {
    var storageKey: String { "\(windowID):\(x):\(y):\(width):\(height)" }
}

/// 一条记住的位置：只存原始数字，不存任何本地化文本。
private struct PiPPositionEntry: Codable {
    let key: String
    let x: Double
    let y: Double
}

/// 每个 PiP 上次被拖到的位置（面板**左上角**，Cocoa 屏幕坐标，点）。存左上角而不是原点：
/// 缩放手柄拖大时左上角不动，面板尺寸又不记忆，存左上角恢复后看得见的那块和放下时一致。
/// 按 PiPKey 记在 UserDefaults 里：一个 JSON 数组，按最近保存的顺序排列，最多 50 条，超了丢最旧的。
/// 只有拖动结束（松手）才写盘。
@MainActor
final class PiPPositionMemory {
    static let shared = PiPPositionMemory()
    /// 最多记 50 条：要 PiP 的目标会不断变（窗口 ID 会复用、区域各不相同），不能无限膨胀
    static let maximumCount = 50
    private static let defaultsKey = "PipDog.pipPositions"

    private let defaults: UserDefaults

    /// - Parameter defaults: 存在哪一套 UserDefaults（默认标准域；单独验证时用临时 suite，不碰真实记录）
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 这个 PiP 上次的左上角位置（屏幕坐标）；没记过时为 nil（新建面板就级联排叠）
    func topLeft(for key: PiPKey) -> CGPoint? {
        let storageKey = key.storageKey
        return entries().last { $0.key == storageKey }.map { CGPoint(x: $0.x, y: $0.y) }
    }

    /// 拖动结束才调用：记住这次的位置（面板左上角）。同一个 PiP 只留最新一条。
    func remember(topLeft: CGPoint, for key: PiPKey) {
        guard topLeft.x.isFinite, topLeft.y.isFinite else { return }
        let storageKey = key.storageKey
        var entries = entries().filter { $0.key != storageKey }
        entries.append(PiPPositionEntry(key: storageKey, x: topLeft.x, y: topLeft.y))
        if entries.count > Self.maximumCount {
            entries.removeFirst(entries.count - Self.maximumCount)
        }
        save(entries)
    }

    /// 源 app 重启、窗口 ID 变了：把记住的位置转到新的键上（面板现在在的位置不变，下次打开还在原处）。
    func migrate(from oldKey: PiPKey, to newKey: PiPKey) {
        let old = oldKey.storageKey, new = newKey.storageKey
        guard old != new else { return }
        var entries = entries()
        guard let index = entries.lastIndex(where: { $0.key == old }) else { return }
        let entry = entries.remove(at: index)
        entries.removeAll { $0.key == new } // 新键上的旧记录作废：迁移过来的位置才是最新的，也别占条数上限
        entries.append(PiPPositionEntry(key: new, x: entry.x, y: entry.y))
        save(entries)
    }

    private func save(_ entries: [PiPPositionEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private func entries() -> [PiPPositionEntry] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([PiPPositionEntry].self, from: data)) ?? []
    }
}