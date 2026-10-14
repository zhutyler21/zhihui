import SwiftUI

/// Parent supplies .id(meeting.id): editor state belongs to one meeting only.
/// Draft storage/autosave remain entirely owned by the existing AppModel.
struct MarkdownNotesView: View {
    @ObservedObject var model: AppModel
    @State private var session: MarkdownNoteSession
    @FocusState private var editorFocused: Bool

    init(model: AppModel) {
        self.model = model
        // Intentional one-time seed; changing meetings creates a new keyed view.
        _session = State(initialValue: MarkdownNoteSession(meetingID: model.selectedMeetingID ?? ""))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.mode == .editing ? "编辑笔记" : "会议笔记")
                        .font(Design.Typography.headline).foregroundStyle(Design.ink)
                    Text(statusText).font(Design.Typography.caption).foregroundStyle(Design.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if session.saving { ProgressView().controlSize(.small).accessibilityLabel("正在保存笔记") }
                if session.mode == .editing {
                    Button(action: finishEditing) { Label("完成", systemImage: "checkmark") }
                        .buttonStyle(.borderedProminent)
                        .font(Design.Typography.callout.weight(.medium)).controlSize(.large)
                        .tint(Design.accentFill)
                        .disabled(blocked)
                        .help("保存笔记后显示排版预览")
                } else {
                    Button(action: beginEditing) { Label("编辑", systemImage: "pencil") }
                        .buttonStyle(.bordered)
                        .font(Design.Typography.callout.weight(.medium)).controlSize(.regular)
                        .tint(Design.accent)
                        .disabled(blocked)
                }
            }
            if session.mode == .editing {
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: "Markdown 原文 · # 标题   **加粗**   - 列表   - [ ] 待办   ``` 代码")
                        .font(Design.Typography.caption.monospaced()).foregroundStyle(Design.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    TextEditor(text: draftBinding)
                        .font(Design.Typography.body.monospaced()).lineSpacing(7)
                        .scrollContentBackground(.hidden)
                        .focused($editorFocused)
                        .disabled(blocked)
                        .frame(minHeight: 160, maxHeight: .infinity)
                        .padding(16)
                        .background(Design.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Design.line, lineWidth: 1) }
                        .accessibilityLabel("会议 Markdown 笔记原文")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if visibleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("记下背景、决定和待办").font(Design.Typography.body.weight(.medium)).foregroundStyle(Design.ink)
                    Text("点击编辑，使用普通文字或 Markdown 写笔记；完成后即可阅读排版预览。")
                        .font(Design.Typography.body).foregroundStyle(Design.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("开始写笔记", action: beginEditing).buttonStyle(QuietButton()).disabled(blocked)
                }
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    MarkdownBody(text: visibleDraft)
                        .frame(maxWidth: 840, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 24)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(Design.accent)
    }

    private var blocked: Bool {
        session.saving || model.isSwitchingMeeting || model.selectedMeetingID != session.meetingID
    }
    private var visibleDraft: String { model.selectedMeetingID == session.meetingID ? model.noteDraft : "" }
    private var statusText: String {
        if session.saving { return "正在保存，请稍候" }
        if model.isSwitchingMeeting { return "正在切换会议" }
        if model.noteDirty { return "有修改待保存" }
        return session.mode == .editing ? "完成后保存并显示预览" : "已保存 · 支持 Markdown"
    }
    private var draftBinding: Binding<String> {
        // A closure binding is required to route writes through AppModel's guarded
        // method; a direct $model.noteDraft would bypass meeting-switch protection.
        Binding(get: { visibleDraft }, set: { value in
            guard model.selectedMeetingID == session.meetingID, !session.saving else { return }
            model.updateNoteDraft(value)
        })
    }
    private func beginEditing() {
        guard !blocked else { return }
        session.beginEditing(); editorFocused = true
    }
    private func finishEditing() {
        guard let ticket = session.beginSaving(draft: model.noteDraft, currentMeetingID: model.selectedMeetingID, switching: model.isSwitchingMeeting) else { return }
        Task { @MainActor in
            do {
                try await model.saveNotesIfNeeded()
                if session.finishSaving(ticket, succeeded: true, currentMeetingID: model.selectedMeetingID, currentDraft: model.noteDraft, dirty: model.noteDirty, switching: model.isSwitchingMeeting) {
                    editorFocused = false
                }
            } catch {
                session.finishSaving(ticket, succeeded: false, currentMeetingID: model.selectedMeetingID, currentDraft: model.noteDraft, dirty: model.noteDirty, switching: model.isSwitchingMeeting)
                if model.selectedMeetingID == ticket.meetingID {
                    model.showError(error, title: "笔记尚未保存")
                }
            }
        }
    }
}
