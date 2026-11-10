import SwiftUI

/// 设置窗口：全局快捷键、修饰键 + 双击触发、帧率、小窗点击方式和外观、语言和开机时启动。
/// 内容比窗口高时由 Form 自己滚动（窗口高度见 SettingsActivation），「恢复默认」固定在底部。
struct SettingsView: View {
    /// 窗口内容的宽度和默认高度；高度还会受屏幕可用高度限制
    static let width: CGFloat = 480
    static let idealHeight: CGFloat = 600
    static let minHeight: CGFloat = 320

    private var settings: ShortcutSettings { .shared }
    private var capture: CaptureSettings { .shared }
    private var windowClick: WindowClickSettings { .shared }
    private var appearance: PiPAppearanceSettings { .shared }
    private var launchAtLogin: LaunchAtLogin { .shared }
    private var language: LanguageSettings { .shared }

    var body: some View {
        VStack(spacing: 0) {
            form
            Divider()
            HStack {
                Spacer()
                Button("Restore Defaults") { // 不改开机时启动：那是系统登录项，不是 app 的偏好
                    settings.restoreDefaults()
                    capture.restoreDefaults()
                    windowClick.restoreDefaults()
                    appearance.restoreDefaults()
                    language.restoreDefaults() // 有变化时会提示重新启动
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: Self.width)
        .frame(minHeight: Self.minHeight, idealHeight: Self.idealHeight, maxHeight: .infinity)
        .onAppear { launchAtLogin.refresh() } // 用户可能在系统设置里改过
        .onDisappear { settings.cancelRecording() }
    }

    private var form: some View {
        Form {
            Section("Global Shortcuts") {
                ForEach(ShortcutAction.allCases) { action in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(action.title) { ShortcutRecorder(action: action) }
                        if let error = settings.errors[action] {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                Text("Click a shortcut, then press a new combination with ⌘, ⌃ or ⌥. Cleared actions stay in the menu.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Modifier + Double-Click: PiP Area Under Pointer") {
                Toggle("Enabled", isOn: Binding(get: { settings.config.clickEnabled },
                                            set: { settings.setClickEnabled($0) }))
                LabeledContent("Hold") {
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
                Text("The second click is kept from the app. Needs Accessibility; without it, PipDog only observes.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.config.clickModifiers.contains(.control) {
                    Text("Tip: macOS treats a ⌃-click as a right-click, so the app may show its shortcut menu on the first click.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Capture") {
                Picker("Frame Rate", selection: Binding(get: { capture.frameRate }, set: { capture.frameRate = $0 })) {
                    ForEach(CaptureSettings.frameRateOptions, id: \.self) { Text(verbatim: "\($0) fps").tag($0) }
                }
                Text("Higher is smoother but uses more CPU; 5–10 fps is plenty for logs and progress bars.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("PiP Window") {
                Picker("Switch Back / Park", selection: Binding(get: { windowClick.mode }, set: { windowClick.mode = $0 })) {
                    ForEach(WindowClickMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Brings the source window to the front; again while it's in front parks it at the screen edge.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Opacity") {
                    HStack {
                        Slider(value: Binding(get: { appearance.opacity }, set: { appearance.setOpacity($0) }),
                               in: PiPAppearanceSettings.minimumOpacity...1, step: 0.05)
                        Text(verbatim: "\(Int((appearance.opacity * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                Toggle("Hide on Hover", isOn: Binding(get: { appearance.hoverAutoHide },
                                                 set: { appearance.hoverAutoHide = $0 }))
                if appearance.hoverAutoHide {
                    Text("Rest the pointer on a PiP for about 1.5 s to fade it out; press ⌥ alone to bring it back")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("General") {
                Picker("Language", selection: Binding(get: { language.language }, set: { language.setLanguage($0) })) {
                    ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                Toggle("Open at Login", isOn: Binding(get: { launchAtLogin.isEnabled },
                                              set: { launchAtLogin.setEnabled($0) }))
                if launchAtLogin.requiresApproval {
                    Text("Registered. Allow PipDog in System Settings › General › Login Items & Extensions so it opens at login.")
                        .font(.caption).foregroundStyle(.orange)
                    Button("Open Login Items Settings") { launchAtLogin.openLoginItemsSettings() }
                }
            }
        }
        .formStyle(.grouped)
    }
}
