import SwiftUI

/// 设置窗口：全局快捷键、修饰键 + 双击触发、帧率。
struct SettingsView: View {
    private var settings: ShortcutSettings { .shared }
    private var capture: CaptureSettings { .shared }

    var body: some View {
        Form {
            Section("全局快捷键") {
                ForEach(ShortcutAction.allCases) { action in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(action.title) { ShortcutRecorder(action: action) }
                        if let error = settings.errors[action] {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                Text("点击按钮后按下新的组合键，至少包含 ⌘、⌃ 或 ⌥；只用 ⌘ 或 ⌘⇧ 加普通键（如 ⌘C、⌘Q）会抢走常用快捷键，不允许。清除后该动作没有快捷键，仍可从菜单使用。切到别的 app 会自动取消录制。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("修饰键 + 双击：PiP 鼠标下方的区域") {
                Toggle("启用", isOn: Binding(get: { settings.config.clickEnabled },
                                            set: { settings.setClickEnabled($0) }))
                LabeledContent("需要按住") {
                    HStack(spacing: 4) {
                        ForEach(ClickModifier.allCases) { modifier in
                            Toggle(modifier.symbol, isOn: Binding(
                                get: { settings.config.clickModifiers.contains(modifier.flag) },
                                set: { settings.setClickModifier(modifier, on: $0) }))
                            .toggleStyle(.button)
                        }
                    }
                }
                .disabled(!settings.config.clickEnabled)
                Text("至少选一个修饰键，默认 ⌥⇧。触发用的第二次点击会被 PipDog 拦下，不会传给目标 app，第一次单击仍会照常传过去。拦截需要辅助功能权限；没有权限时只能旁观，双击仍会传给目标 app。")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.config.clickModifiers.contains(.control) {
                    Text("提示：按住 ⌃ 点击时 macOS 会把第一次点击当成右键，目标 app 可能弹出右键菜单。")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section("画面") {
                Picker("帧率", selection: Binding(get: { capture.frameRate }, set: { capture.frameRate = $0 })) {
                    ForEach(CaptureSettings.frameRateOptions, id: \.self) { Text("\($0) fps").tag($0) }
                }
                Text("修改后立即应用到已打开的 PiP。帧率越高画面越流畅，但 CPU 占用也越高；盯日志、进度条用 5–10 fps 就够了。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("恢复默认") {
                    settings.restoreDefaults()
                    capture.restoreDefaults()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .background(WindowAccessor { SettingsActivation.shared.attach($0) })
        .onDisappear { settings.cancelRecording() }
    }
}
