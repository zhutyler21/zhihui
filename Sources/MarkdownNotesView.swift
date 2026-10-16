import SwiftUI

/// Parent supplies .id(meeting.id): presentation belongs to this meeting only.
/// Markdown source and autosave remain owned by AppModel.
struct MarkdownNotesView: View {
    @ObservedObject var model: AppModel
    @State private var session: MarkdownNoteSession

    init(model: AppModel) {
        self.model = model
        _session = State(initialValue: MarkdownNoteSession(meetingID: model.selectedMeetingID ?? ""))
    }
    var body: some View { MarkdownNotesEditor(model: model, session: $session) }
}

struct MarkdownNotesEditor: View {
    @ObservedObject var model: AppModel
    @Binding var session: MarkdownNoteSession
    @FocusState private var editorFocused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var formattingHelp = false

    private var showsSource: Bool {
        session.mode == .editing || visibleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("会议笔记").font(Design.Typography.headline).foregroundStyle(Design.ink)
                    Text(statusText).font(Design.Typography.caption).foregroundStyle(Design.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if session.saving { ProgressView().controlSize(.small).accessibilityLabel("等待笔记自动保存") }
                Button { formattingHelp.toggle() } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.borderless).foregroundStyle(Design.muted)
                    .accessibilityLabel("笔记格式提示").help("查看 Markdown 格式提示")
                    .popover(isPresented: $formattingHelp) {
                        Text(verbatim: "Markdown 格式\n\n# 标题\n**加粗**\n- 列表\n- [ ] 待办\n``` 代码块\n\n点击笔记直接编辑；点击其他区域或按 ⌘Return 后自动排版。")
                            .font(Design.Typography.callout.monospaced()).padding(20)
                    }
            }
            if showsSource { sourceEditor }
            else {
                Button(action: beginEditing) {
                    ScrollView {
                        MarkdownBody(text: visibleDraft)
                            .frame(maxWidth: 840, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 24)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }.buttonStyle(.plain).disabled(blocked)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("会议笔记，点击继续编辑")
                    .help("点击笔记内容继续编辑 Markdown")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(Design.accent)
        .onAppear {
            if !model.noteSaveErrorMessage.isEmpty { preserveFailedDraft() }
            else if session.saving { completeAutomaticPreview() }
            else if session.mode == .editing && isEnabled {
                session.beginEditing(); editorFocused = true
            }
        }
        .onChange(of: editorFocused) { _, focused in
            if focused { session.beginEditing() }
            else if isEnabled { requestPreview() }
        }
        .onChange(of: model.noteDirty) { _, dirty in
            if !dirty { completeAutomaticPreview() }
        }
        .onChange(of: model.noteSaveErrorMessage) { _, error in
            if !error.isEmpty { preserveFailedDraft() }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { editorFocused = false; requestPreview() }
        }
    }
    private var sourceEditor: some View {
        TextEditor(text: draftBinding)
            .font(Design.Typography.body.monospaced()).lineSpacing(7)
            .scrollContentBackground(.hidden)
            .focused($editorFocused).disabled(blocked)
            .frame(minHeight: 64, maxHeight: .infinity).padding(16)
            .background(Design.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(editorFocused ? Design.accent.opacity(0.5) : Design.line, lineWidth: 1)
            }
            .overlay(alignment: .topLeading) {
                if visibleDraft.isEmpty {
                    Text("直接输入 Markdown，记下背景、决定和待办。")
                        .font(Design.Typography.body).foregroundStyle(Design.muted)
                        .padding(22).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .background(NoteEditorFocusBoundary(active: isEnabled && !blocked && session.mode == .editing,
                onLeave: endEditing).frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false).accessibilityHidden(true))
            .onKeyPress(.return, phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                endEditing(); return .handled
            }
            .onExitCommand(perform: endEditing)
            .accessibilityLabel("会议 Markdown 笔记原文")
            .help("直接输入 Markdown，自动保存；点击其他区域或按 ⌘Return 显示排版")
    }
    private var blocked: Bool {
        model.isSwitchingMeeting || model.selectedMeetingID != session.meetingID
    }
    private var visibleDraft: String { model.selectedMeetingID == session.meetingID ? model.noteDraft : "" }
    private var statusText: String {
        if model.isSwitchingMeeting { return "正在切换会议" }
        if !model.noteSaveErrorMessage.isEmpty && model.noteDirty { return "尚未保存，草稿已保留" }
        if session.saving { return "自动保存后显示排版" }
        if model.noteDirty { return "更改将自动保存" }
        return showsSource ? "自动保存 · 离开笔记区域后排版" : "已保存 · 点击笔记继续输入"
    }
    private var draftBinding: Binding<String> {
        Binding(get: { visibleDraft }, set: { value in
            guard !blocked, isEnabled else { return }
            if session.mode != .editing || session.saving { session.beginEditing() }
            model.updateNoteDraft(value)
        })
    }
    private func beginEditing() {
        guard !blocked, isEnabled else { return }
        session.beginEditing(); editorFocused = true
    }
    private func endEditing() {
        guard !blocked else { return }
        editorFocused = false; requestPreview()
    }
    private func requestPreview() {
        guard !blocked, session.mode == .editing else { return }
        if !model.noteSaveErrorMessage.isEmpty && model.noteDirty { model.noteChanged() }
        _ = session.beginSaving(draft: model.noteDraft, currentMeetingID: model.selectedMeetingID,
            switching: model.isSwitchingMeeting)
        completeAutomaticPreview()
    }
    private func completeAutomaticPreview() {
        guard !editorFocused, !model.noteDirty, let ticket = session.pendingPreview else { return }
        session.finishSaving(ticket, succeeded: true, currentMeetingID: model.selectedMeetingID,
            currentDraft: model.noteDraft, dirty: model.noteDirty, switching: model.isSwitchingMeeting)
    }
    private func preserveFailedDraft() {
        guard model.noteDirty, let ticket = session.pendingPreview else { return }
        session.finishSaving(ticket, succeeded: false, currentMeetingID: model.selectedMeetingID,
            currentDraft: model.noteDraft, dirty: true, switching: model.isSwitchingMeeting)
    }
}
