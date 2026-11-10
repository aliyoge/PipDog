import SwiftUI

/// 设置窗口：全局快捷键、修饰键 + 双击触发、帧率、小窗点击方式和外观、开机时启动。
struct SettingsView: View {
    private var settings: ShortcutSettings { .shared }
    private var capture: CaptureSettings { .shared }
    private var windowClick: WindowClickSettings { .shared }
    private var appearance: PiPAppearanceSettings { .shared }
    private var launchAtLogin: LaunchAtLogin { .shared }
    private var language: LanguageSettings { .shared }

    var body: some View {
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
                Text("Click a button, then press the new combination. It must include ⌘, ⌃ or ⌥; ⌘ or ⌘⇧ with a regular key (like ⌘C or ⌘Q) isn't allowed because it would take over common shortcuts. A cleared action has no shortcut but is still in the menu. Switching to another app cancels recording.")
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
                Text("Choose at least one modifier; the default is ⌥⇧. PipDog intercepts the second click so it doesn't reach the app, while the first click goes through as usual. Intercepting needs Accessibility permission; without it PipDog only observes, and the double-click still reaches the app.")
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
                Text("Changes apply to open PiPs right away. Higher frame rates are smoother but use more CPU; 5–10 fps is plenty for watching logs or progress bars.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("PiP Window") {
                Picker("Switch Back / Park", selection: Binding(get: { windowClick.mode }, set: { windowClick.mode = $0 })) {
                    ForEach(WindowClickMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Click or double-click a PiP to bring its source window to the front; if the source is already in front, it moves to the screen edge. Double-click is the default, so dragging or a stray click won't trigger it. ⌥-click is always Quick Look.")
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
                Text("Opacity goes down to 30%. Hide on Hover is off by default; when on, a PiP fades out after the pointer rests on it for about 1.5 s, and clicks go straight through to the window below. It comes back when the pointer leaves its area, or right away when you press ⌥ alone (without clicking); ⌥-clicks still go through to the app below. It doesn't hide after you click, drag or scroll on it, or while you hold ⌥ or point at × or the resize handle. Scroll or pinch to zoom in; when zoomed, dragging pans. ⌘-click a PiP to reset the zoom.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Open at Login", isOn: Binding(get: { launchAtLogin.isEnabled },
                                              set: { launchAtLogin.setEnabled($0) }))
                if launchAtLogin.requiresApproval {
                    Text("Registered. Allow PipDog in System Settings › General › Login Items & Extensions so it opens at login.")
                        .font(.caption).foregroundStyle(.orange)
                    Button("Open Login Items Settings") { launchAtLogin.openLoginItemsSettings() }
                }
                Text("This is a macOS login item, so Restore Defaults doesn't change it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Language") {
                Picker("Language", selection: Binding(get: { language.language }, set: { language.setLanguage($0) })) {
                    ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                Text("PipDog asks to relaunch after you change the language. Follow System uses Simplified Chinese on Chinese systems and English otherwise.")
                    .font(.caption).foregroundStyle(.secondary)
            }

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
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { launchAtLogin.refresh() } // 用户可能在系统设置里改过
        .onDisappear { settings.cancelRecording() }
    }
}
