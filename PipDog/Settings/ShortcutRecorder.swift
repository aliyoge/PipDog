import SwiftUI

/// 单个动作的快捷键录制控件：点击开始录制，按下组合键完成，Esc 取消，× 清除。
struct ShortcutRecorder: View {
    let action: ShortcutAction
    private var settings: ShortcutSettings { .shared }

    var body: some View {
        let isRecording = settings.recordingAction == action
        let combo = settings.combo(for: action)
        HStack(spacing: 6) {
            Button {
                if isRecording { settings.cancelRecording() } else { settings.startRecording(action) }
            } label: {
                Text(isRecording ? String(localized: "Press a Shortcut… (Esc to Cancel)") : (combo?.display ?? String(localized: "Click to Record")))
                    .foregroundStyle(isRecording ? Color.accentColor : (combo == nil ? Color.secondary : Color.primary))
                    .frame(minWidth: 150)
            }
            Button {
                settings.clear(action)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Clear Shortcut")
            .opacity(combo == nil ? 0 : 1)
            .disabled(combo == nil)
        }
    }
}
