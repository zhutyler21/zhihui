import SwiftUI

struct MeetingTranslationControls: View {
    @ObservedObject var model: AppModel
    let meeting: Meeting
    let showLanguages: () -> Void
    let openDisplay: () -> Void
    private var settingsLocked: Bool {
        model.recordingMeetingID == meeting.id || model.startingRecording || model.translationUpdating
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { translationSwitch; Spacer(minLength: 8); actions }
                VStack(alignment: .leading, spacing: 12) { translationSwitch; actions }
            }
            Text(model.translationUpdating ? "正在保存语言设置…" :
                 "讲话：\(MeetingLanguages.sourceName(meeting.translation.sourceLanguage)) · 译文：\(meeting.translation.targetLanguages.map(MeetingLanguages.sourceName).joined(separator: "、"))")
                .font(Design.Typography.caption).foregroundStyle(Design.muted)
                .fixedSize(horizontal: false, vertical: true)
            if meeting.translation.enabled && !meeting.segments.isEmpty {
                TranslationStatusView(model: model, meeting: meeting)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.soft, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
    private var translationSwitch: some View {
        Toggle(isOn: Binding(get: { meeting.translation.enabled }, set: { enabled in
            var settings = meeting.translation; settings.enabled = enabled
            Task { await model.configureTranslation(settings, meetingID: meeting.id) }
        })) { Label("实时翻译", systemImage: "translate") }
            .toggleStyle(.switch).font(Design.Typography.callout.weight(.semibold))
            .fixedSize().disabled(settingsLocked)
            .accessibilityLabel("实时翻译")
            .help(settingsLocked ? "停止录音后可调整翻译设置" : "开启后，录音和导入音频会按所选语言自动翻译")
    }
    private var actions: some View {
        HStack(spacing: 10) {
            Button("语言设置…", systemImage: "globe") { showLanguages() }
                .disabled(settingsLocked)
            Button("打开翻译大屏", systemImage: "display.2") { openDisplay() }
                .help("独立打开本场字幕窗口，可移到另一块屏幕全屏显示；主窗口继续记录会议")
        }.buttonStyle(QuietButton()).fixedSize(horizontal: true, vertical: false)
    }
}

struct TranslationSettingsSheet: View {
    @ObservedObject var model: AppModel
    let meeting: Meeting
    @Environment(\.dismiss) private var dismiss
    @State private var source: String
    @State private var targets: [String]
    @State private var enabled: Bool

    init(model: AppModel, meeting: Meeting) {
        self.model = model; self.meeting = meeting
        _source = State(initialValue: meeting.translation.sourceLanguage)
        _targets = State(initialValue: meeting.translation.targetLanguages)
        _enabled = State(initialValue: meeting.translation.enabled)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("语言设置", systemImage: "globe").font(Design.Typography.title2.weight(.semibold))
            Text(meeting.title).font(Design.Typography.callout).foregroundStyle(Design.muted)
            Form {
                Picker("讲话语言", selection: $source) {
                    ForEach(MeetingLanguages.sources, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle("实时翻译", isOn: $enabled)
                Section("译文语言 · 可多选") {
                    ForEach(MeetingLanguages.targets, id: \.0) { language in
                        Toggle(language.1, isOn: Binding(get: { targets.contains(language.0) }, set: { selected in
                            if selected { if !targets.contains(language.0) { targets.append(language.0) } }
                            else { targets.removeAll { $0 == language.0 } }
                        })).toggleStyle(.checkbox)
                    }
                }
            }.font(Design.Typography.body)
            Text("语音输入支持中文、英语、日语、韩语和粤语。原文逐段保存后在本机翻译；会后可补译已有原文，再整理中文纪要。")
                .font(Design.Typography.callout).foregroundStyle(Design.muted).fixedSize(horizontal: false, vertical: true)
            Label("录音、原文和译文留在这台 Mac", systemImage: "lock.shield")
                .font(Design.Typography.caption).foregroundStyle(Design.muted)
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(QuietButton())
                Spacer()
                Button(model.translationUpdating ? "正在保存…" : "保存设置") {
                    Task {
                        var settings = meeting.translation
                        settings.sourceLanguage = source; settings.targetLanguages = targets; settings.enabled = enabled
                        if await model.configureTranslation(settings, meetingID: meeting.id) { dismiss() }
                    }
                }.keyboardShortcut(.defaultAction).buttonStyle(PrimaryButton()).disabled(model.translationUpdating || targets.isEmpty)
            }
            if targets.isEmpty { Text("请至少选择一种译文语言").font(Design.Typography.caption).foregroundStyle(Design.muted) }
        }.padding(28).frame(width: 470).fixedSize(horizontal: false, vertical: true)
    }
}

struct TranslationStatusView: View {
    @ObservedObject var model: AppModel
    let meeting: Meeting
    private var active: Bool {
        model.translatingMeetings.contains(meeting.id) || meeting.segments.contains {
            $0.translations.contains { meeting.translation.targetLanguages.contains($0.targetLanguage) && ["queued", "running"].contains($0.state) }
        }
    }
    private var completed: Int {
        meeting.segments.reduce(0) { count, segment in count + segment.translations.filter {
            meeting.translation.targetLanguages.contains($0.targetLanguage) && $0.state == "done"
        }.count }
    }
    private var total: Int { meeting.segments.count * meeting.translation.targetLanguages.count }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { status; Spacer(minLength: 8); action }
            VStack(alignment: .leading, spacing: 10) { status; action }
        }
    }
    private var status: some View {
        HStack(spacing: 10) {
            if active { ProgressView().controlSize(.small) }
            else { Image(systemName: "translate").foregroundStyle(Design.accent) }
            Text(active ? "正在翻译 · 已完成 \(completed)/\(total) 份译文" : "已保存 \(completed)/\(total) 份译文")
                .font(Design.Typography.caption).foregroundStyle(Design.muted)
        }
    }
    @ViewBuilder private var action: some View {
        if completed < total {
            Button("翻译已有原文") { Task { await model.translateMeeting(meeting) } }
                .buttonStyle(.borderless).font(Design.Typography.caption).disabled(active || meeting.segments.isEmpty)
        }
    }
}

struct SegmentTranslationView: View {
    let segment: Segment
    let target: String
    private var translation: SegmentTranslation? { segment.translations.first { $0.targetLanguage == target } }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(MeetingLanguages.targetName(target), systemImage: "translate")
                .font(Design.Typography.caption).foregroundStyle(Design.muted)
            if let translation, translation.state == "done" {
                Text(translation.text).font(Design.Typography.body).lineSpacing(6).textSelection(.enabled)
                    .environment(\.layoutDirection, target == "ar" ? .rightToLeft : .leftToRight)
            } else if let translation, translation.state == "error" {
                Text("译文未完成：\(translation.error)").font(Design.Typography.callout).foregroundStyle(Design.muted)
            } else {
                Text(translation == nil ? "可点击“翻译已有原文”补译这段内容" : "正在翻译，原文已保存…")
                    .font(Design.Typography.callout).foregroundStyle(Design.muted)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(Design.soft, in: RoundedRectangle(cornerRadius: 10))
    }
}
