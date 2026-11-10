import SwiftUI

/// 设置窗口：全局快捷键、修饰键 + 双击触发、帧率、小窗点击方式和外观、开机时启动。
struct SettingsView: View {
    private var settings: ShortcutSettings { .shared }
    private var capture: CaptureSettings { .shared }
    private var windowClick: WindowClickSettings { .shared }
    private var appearance: PiPAppearanceSettings { .shared }
    private var launchAtLogin: LaunchAtLogin { .shared }

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

            Section("小窗") {
                Picker("切回 / 移到旁边", selection: Binding(get: { windowClick.mode }, set: { windowClick.mode = $0 })) {
                    ForEach(WindowClickMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("在小窗上单击或双击，把原窗口切到前面；原窗口已在最前时，把它移到屏幕边上。默认双击，拖动或随手点一下不会误触发。⌥ + 单击仍是快速查看。")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("不透明度") {
                    HStack {
                        Slider(value: Binding(get: { appearance.opacity }, set: { appearance.opacity = $0 }),
                               in: PiPAppearanceSettings.minimumOpacity...1, step: 0.05)
                        Text("\(Int((appearance.opacity * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                Toggle("悬停时自动隐藏", isOn: Binding(get: { appearance.hoverAutoHide },
                                                 set: { appearance.hoverAutoHide = $0 }))
                Text("不透明度最低 30%。打开悬停隐藏后，鼠标在小窗上停约 0.6 秒，小窗会淡出，点击直接穿透到下面的窗口；鼠标移出小窗原来的范围就恢复。在小窗上点击、拖动、滚动后，或按住 ⌥、指着 × 和缩放手柄时不会隐藏。滚动或捏合可以放大画面，放大后拖动是平移，缩回原大小才能拖动小窗。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("启动") {
                Toggle("开机时启动", isOn: Binding(get: { launchAtLogin.isEnabled },
                                              set: { launchAtLogin.setEnabled($0) }))
                if launchAtLogin.requiresApproval {
                    Text("已登记，还需要在「系统设置 › 通用 › 登录项与扩展」里允许 PipDog，开机时才会启动。")
                        .font(.caption).foregroundStyle(.orange)
                    Button("打开登录项设置") { launchAtLogin.openLoginItemsSettings() }
                }
                Text("这是系统的登录项，不受「恢复默认」影响。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("恢复默认") { // 不改开机时启动：那是系统登录项，不是 app 的偏好
                    settings.restoreDefaults()
                    capture.restoreDefaults()
                    windowClick.restoreDefaults()
                    appearance.restoreDefaults()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .background(WindowAccessor { SettingsActivation.shared.attach($0) })
        .onAppear { launchAtLogin.refresh() } // 用户可能在系统设置里改过
        .onDisappear { settings.cancelRecording() }
    }
}
