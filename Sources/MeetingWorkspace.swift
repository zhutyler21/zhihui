import SwiftUI

/// One capture entry per workspace. Recording stop actions belong to the persistent bar.
struct MeetingCaptureActions: View {
    @ObservedObject var model: AppModel
    let meetingID: String
    var includesImport = true
    private var ownsRecording: Bool { model.recordingMeetingID == meetingID }
    private var finishing: Bool { model.finishingMeetings.contains(meetingID) }
    private var blocked: Bool {
        !model.ready || model.isSwitchingMeeting || model.selectedMeetingID != meetingID || model.stoppingRecording
    }
    private var importPending: Bool {
        model.audioImportMeetingID == meetingID || model.pending.contains { $0.meetingID == meetingID && $0.durationSeconds == 0 }
    }
    var body: some View {
        HStack(spacing: 10) {
            if !(ownsRecording && (model.recording || model.stoppingRecording)) {
                HStack(spacing: 4) {
                    Button(model.startingRecording && ownsRecording ? "正在准备录音…" : "开始录音", systemImage: "mic.fill") {
                        Task {
                            guard model.selectedMeetingID == meetingID else { return }
                            await model.startRecording()
                        }
                    }
                    .buttonStyle(PrimaryButton())
                    .help("使用\(model.recordingMode.rawValue)开始录音（⇧⌘R）")
                    Menu {
                        Picker("声音来源", selection: $model.recordingMode) {
                            ForEach(RecordingMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                        }.pickerStyle(.inline)
                    } label: { Image(systemName: "chevron.down") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden)
                        .frame(width: 28, height: 32).foregroundStyle(Design.accent)
                        .accessibilityLabel("录音来源")
                        .accessibilityValue(model.recordingMode.rawValue)
                        .help("当前声音来源：\(model.recordingMode.rawValue)；点击选择麦克风、系统声音或混音")
                }
                    .disabled(blocked || model.recording || model.startingRecording || finishing || importPending)
                if includesImport {
                    Button("导入音频", systemImage: "square.and.arrow.down") {
                        guard model.selectedMeetingID == meetingID else { return }
                        model.importAudio()
                    }.buttonStyle(QuietButton())
                        .disabled(blocked || model.recording || model.startingRecording || model.importingAudio || finishing)
                        .help("把已有音频导入本场会议，在本机转写")
                }
            }
        }.fixedSize(horizontal: true, vertical: false)
    }
}

/// A persistent content-area status bar remains reachable in every destination.
struct ActiveRecordingBar: View {
    @ObservedObject var model: AppModel
    private var meetingID: String? { model.recordingMeetingID }
    private var title: String {
        model.meetings.first { $0.id == meetingID }?.title ?? "当前会议"
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { status; Spacer(minLength: 12); actions }
            VStack(alignment: .leading, spacing: 12) { status; actions }
        }
        .padding(.horizontal, Design.Spacing.contentInset).padding(.vertical, 12)
        .background(Design.surface)
    }
    private var status: some View {
        HStack(spacing: 12) {
            Label(model.stoppingRecording ? "正在保存录音" : "正在录音", systemImage: "record.circle.fill")
                .foregroundStyle(Design.recording).fixedSize(horizontal: true, vertical: false)
            Text(timeText(model.recordingSeconds)).monospacedDigit().font(Design.Typography.headline)
                .fixedSize(horizontal: true, vertical: false)
            if model.selectedMeetingID != meetingID || model.section != .meetings {
                Button { revealRecording() } label: { Text(title).lineLimit(1) }
                    .buttonStyle(.borderless).frame(maxWidth: 220, alignment: .leading)
                    .help("打开正在录音的会议：\(title)")
            }
        }.font(Design.Typography.callout.weight(.medium))
            .accessibilityElement(children: .contain)
    }
    private var actions: some View {
        HStack(spacing: 10) {
            Button(model.stoppingRecording ? "正在停止…" : "停止录音", systemImage: "stop.fill") {
                guard let id = meetingID else { return }
                Task {
                    guard model.recordingMeetingID == id else { return }
                    await model.stopRecording()
                }
            }.buttonStyle(PrimaryButton()).disabled(model.stoppingRecording)
                .help("保存当前录音，继续处理剩余转写")
            Button("停止并整理") {
                guard let meetingID else { return }
                Task { await model.finishAndSummarize(meetingID) }
            }.buttonStyle(QuietButton())
                .disabled(model.stoppingRecording || meetingID.map { model.finishingMeetings.contains($0) } != false)
        }.fixedSize(horizontal: true, vertical: false)
    }
    private func revealRecording() {
        guard let id = meetingID, !model.isSwitchingMeeting else { return }
        Task {
            await model.selectMeeting(id)
            if model.selectedMeetingID == id { model.section = .meetings }
        }
    }
}

/// Keyed to one meeting by the parent. Editor presentation state lives above
/// both split containers so resizing and tab changes cannot reset editing.
struct MeetingContentWorkspace: View {
    @ObservedObject var model: AppModel
    let meeting: Meeting
    @State private var tab = "转写"
    @State private var notes: MarkdownNoteSession
    @AppStorage("meetingSideBySide") private var sideBySide = true
    init(model: AppModel, meeting: Meeting) {
        self.model = model; self.meeting = meeting
        _notes = State(initialValue: MarkdownNoteSession(meetingID: meeting.id))
    }
    private var writing: Bool { tab == "转写" || tab == "笔记" }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                tabs.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                if writing { layoutToggle }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Design.Spacing.contentInset).padding(.vertical, 12)
            Divider().padding(.horizontal, Design.Spacing.contentInset)
            Group {
                if writing {
                    if sideBySide {
                        GeometryReader { geometry in
                            if geometry.size.width >= 680 {
                                HSplitView {
                                    transcript.frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                                    editor.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                                }
                            } else {
                                ScrollView {
                                VSplitView {
                                    transcript.frame(minHeight: 160, maxHeight: .infinity)
                                    editor.frame(minHeight: 170, maxHeight: .infinity)
                                }.frame(height: max(340, geometry.size.height))
                                }
                            }
                        }
                    } else if tab == "笔记" { editor }
                    else { transcript }
                } else if tab == "中文纪要" { SummaryView(model: model, meeting: meeting) }
                else { AttachmentsView(model: model, meeting: meeting) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
    private var tabs: some View {
        Picker("会议内容", selection: $tab) {
            ForEach(["转写", "笔记", "中文纪要", "附件"], id: \.self) { name in Text(name).tag(name) }
        }.pickerStyle(.segmented).labelsHidden().font(Design.Typography.callout).tint(Design.accentFill)
    }
    private var layoutToggle: some View {
        Toggle(isOn: $sideBySide) {
            Label(tab == "笔记" ? "并排转写" : "并排笔记", systemImage: "rectangle.split.2x1")
        }.labelStyle(.iconOnly).toggleStyle(.button).font(Design.Typography.callout)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("同时显示转写和笔记")
            .help("宽窗口左右并排，窄窗口上下排列；可拖动分隔线调整大小")
    }
    private var transcript: some View { TranscriptView(model: model, meeting: meeting, compactEmptyState: sideBySide) }
    private var editor: some View { MarkdownNotesEditor(model: model, session: $notes).background(Design.soft.opacity(0.4)) }
}
