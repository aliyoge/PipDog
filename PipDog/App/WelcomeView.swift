import AppKit
import SwiftUI

/// 欢迎窗口显示的内容：由 Onboarding 按当前设置生成。
/// 这里只放纯数据，视图不直接读设置，方便单独渲染预览。
struct WelcomeInfo {
    struct Shortcut: Identifiable {
        let icon: String
        let title: String
        /// 每个键一个键帽；空数组表示未设置
        let keys: [String]
        /// 键帽后面的文字（如「双击」）
        var suffix: String?
        var id: String { title }
    }

    struct Gesture: Identifiable {
        let icon: String
        let action: String
        let gesture: String
        var id: String { action }
    }

    struct Permission: Identifiable {
        enum State { case granted, restartRequired, missing }
        let icon: String
        let name: String
        let note: String
        let state: State
        var id: String { name }
    }

    var icon: NSImage
    /// 菜单栏图标（模板图），嵌在副标题里
    var menuBarIcon: NSImage?
    var shortcuts: [Shortcut]
    var gestures: [Gesture]
    /// 悬停隐藏打开时的一句说明
    var hoverNote: String?
    var permissions: [Permission]
}

/// 第一次启动和菜单「使用说明…」显示的欢迎窗口内容。
struct WelcomeView: View {
    let info: WelcomeInfo
    var onOpenSettings: () -> Void = {}
    var onStart: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 30)
                .padding(.bottom, 22)
            VStack(alignment: .leading, spacing: 18) {
                section("Shortcuts") { shortcuts }
                section("PiP Gestures") { gestures }
                section("Permissions") { permissions }
            }
            .padding(.horizontal, 24)
            footer
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 20)
        }
        .frame(width: 540)
    }

    // MARK: 顶部

    private var header: some View {
        VStack(spacing: 8) {
            Image(nsImage: info.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 80, height: 80)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            Text("Welcome to PipDog")
                .font(.system(size: 22, weight: .bold))
            Text("PipDog runs in the menu bar. Click the menu bar icon \(Text(menuBarImage).baselineOffset(-2)) or use a shortcut to start.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true) // 英文较长：换行而不是截断
        }
        .padding(.horizontal, 40)
    }

    private var menuBarImage: Image {
        guard let icon = info.menuBarIcon else { return Image(systemName: "pip") }
        return Image(nsImage: icon).renderingMode(.template)
    }

    // MARK: 快捷键

    private var shortcuts: some View {
        VStack(spacing: 0) {
            ForEach(Array(info.shortcuts.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider().padding(.leading, 44) }
                HStack(spacing: 10) {
                    Image(systemName: item.icon)
                        .font(.system(size: 14))
                        .foregroundStyle(.tint)
                        .frame(width: 22)
                    Text(item.title)
                    Spacer(minLength: 12)
                    if item.keys.isEmpty {
                        Text("Not Set").foregroundStyle(.tertiary)
                    } else {
                        HStack(spacing: 4) {
                            ForEach(Array(item.keys.enumerated()), id: \.offset) { _, key in Keycap(key: key) }
                            if let suffix = item.suffix {
                                Text("+ \(suffix)")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 2)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .card()
    }

    // MARK: 小窗操作

    private var gestures: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                ForEach(Array(stride(from: 0, to: info.gestures.count, by: 2)), id: \.self) { start in
                    GridRow {
                        GestureItem(item: info.gestures[start])
                        if start + 1 < info.gestures.count {
                            GestureItem(item: info.gestures[start + 1])
                        } else {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }
            if let hoverNote = info.hoverNote {
                Divider()
                Label(hoverNote, systemImage: "eye.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: 权限

    private var permissions: some View {
        VStack(spacing: 0) {
            ForEach(Array(info.permissions.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider().padding(.leading, 44) }
                HStack(spacing: 10) {
                    Image(systemName: item.icon)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name)
                        Text(item.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    PermissionBadge(state: item.state)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
        }
        .card()
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Reopen anytime from Welcome Guide… in the menu.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Open Settings", action: onOpenSettings)
                .controlSize(.large)
            Button("Get Started", action: onStart)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
    }

    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            content()
        }
    }
}

/// 一个键的键帽。
private struct Keycap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 12, weight: .medium))
            .frame(minWidth: 12)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.2), radius: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
    }
}

/// 小窗操作网格里的一项：图标 + 动作 + 手势。
private struct GestureItem: View {
    let item: WelcomeInfo.Gesture

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.tint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.action)
                Text(item.gesture)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 权限状态：圆点 + 文字。
private struct PermissionBadge: View {
    let state: WelcomeInfo.Permission.State

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch state {
        case .granted: String(localized: "Granted")
        case .restartRequired: String(localized: "Relaunch Required")
        case .missing: String(localized: "Not Granted")
        }
    }

    private var color: Color {
        switch state {
        case .granted: .green
        case .restartRequired: .orange
        case .missing: Color(nsColor: .tertiaryLabelColor)
        }
    }
}

private extension View {
    /// 分组卡片背景
    func card() -> some View {
        background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quinary))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
            )
    }
}
