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
    private var chromiumCompatibility: ChromiumCompatibilitySettings { .shared }
    private var appFrameRates: AppFrameRateSettings { .shared }
    private var windowClick: WindowClickSettings { .shared }
    private var appearance: PiPAppearanceSettings { .shared }
    private var launchAtLogin: LaunchAtLogin { .shared }
    private var language: LanguageSettings { .shared }
    private var enhancedMode: EnhancedModeSettings { .shared }

    var body: some View {
        VStack(spacing: 0) {
            form
            Divider()
            HStack {
                Spacer()
                Button("Restore Defaults") { // 不改开机时启动：那是系统登录项，不是 app 的偏好
                    settings.restoreDefaults()
                    capture.restoreDefaults()
                    chromiumCompatibility.restoreDefaults()
                    appFrameRates.restoreDefaults() // 按 app 记住的帧率也清掉，全部回到全局默认
                    windowClick.restoreDefaults()
                    appearance.restoreDefaults()
                    enhancedMode.restoreDefaults()
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

            Section("Keyboard Control") {
                Toggle("Keyboard Control", isOn: Binding(get: { enhancedMode.isEnabled },
                                                     set: { enhancedMode.isEnabled = $0 }))
                Text("fn+P PiPs the focused window and fn+⇧+P selects a region.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("While the pointer rests on a PiP: = and - zoom, F switches the frame rate, D toggles the static-picture frame rate reduction, a tap of fn hides or shows the PiP, and ⌫ closes it.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Off by default. Needs Accessibility: PipDog asks for it when you turn this on, and the shortcuts work once it's granted.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Capture") {
                Picker("Frame Rate", selection: Binding(get: { capture.frameRate }, set: { capture.frameRate = $0 })) {
                    ForEach(CaptureSettings.frameRateOptions, id: \.self) { Text(verbatim: "\($0) fps").tag($0) }
                }
                Text("Higher is smoother but uses more CPU; 5–10 fps is plenty for logs and progress bars.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Reduce to 1 fps when the picture is static",
                       isOn: Binding(get: { capture.reduceFrameRateWhenStatic },
                                     set: { capture.reduceFrameRateWhenStatic = $0 }))
                Text("After about 5 seconds without a change, the PiP refreshes once a second until something moves again.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Pause When Covered or on Another Desktop",
                       isOn: Binding(get: { capture.pauseWhenObscured },
                                     set: { capture.pauseWhenObscured = $0 }))
                Text("A PiP that's completely covered by other windows or on another desktop drops to 1 fps until it's visible again.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Chromium Compatibility Mode",
                       isOn: Binding(get: { chromiumCompatibility.isEnabled },
                                     set: { chromiumCompatibility.isEnabled = $0 }))
                Text("Off by default. When a Chromium or Electron app stops redrawing off screen, PipDog only suggests turning this mode on. With it on, the note suggests reopening the app with --disable-backgrounding-occluded-windows. PipDog never restarts apps for you.")
                    .font(.caption).foregroundStyle(.secondary)

                perAppFrameRates
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

    /// 按 app 记住的帧率：显示已有记录（app 名 + 帧率 + 删除），上面的全局帧率是没有记录时的默认值。
    @ViewBuilder
    private var perAppFrameRates: some View {
        Text("Per-App Frame Rate").font(.headline)
            .padding(.top, 6)
        Text("Apps whose frame rate you change keep it; terminal and editor apps, Activity Monitor and Console start at 5 fps the first time. Every other app uses the Frame Rate above.")
            .font(.caption).foregroundStyle(.secondary)
        if appFrameRates.records.isEmpty {
            Text("No app has its own frame rate yet.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            ForEach(appFrameRates.records.keys.sorted { appFrameRates.appName(for: $0) < appFrameRates.appName(for: $1) }, id: \.self) { bundleID in
                LabeledContent(appFrameRates.appName(for: bundleID)) {
                    HStack(spacing: 8) {
                        Picker("Frame Rate", selection: Binding(get: { appFrameRates.records[bundleID] ?? capture.frameRate },
                                                                set: { appFrameRates.setFrameRate($0, forApp: bundleID) })) {
                            ForEach(CaptureSettings.frameRateOptions, id: \.self) { Text(verbatim: "\($0) fps").tag($0) }
                        }
                        .labelsHidden()
                        Button {
                            appFrameRates.remove(bundleID)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this app's frame rate")
                    }
                }
            }
        }
    }
}
