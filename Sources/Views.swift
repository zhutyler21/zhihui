import SwiftUI
import AppKit

struct MeetingDetailView: View {
    @ObservedObject var model: AppModel
    @State private var tab = "转写"; @State private var trashConfirmation = false
    var body: some View {
        Group {
            if let meeting = model.detail {
                VStack(alignment: .leading, spacing: 0) {
                    header(meeting)
                    recordingBar
                    Picker("会议内容", selection: $tab) { ForEach(["转写", "笔记", "中文纪要", "附件"], id: \.self) { name in Text(name).tag(name) } }
                        .pickerStyle(.segmented).labelsHidden().font(Design.Typography.callout).tint(Design.accentFill).padding(.horizontal, 24).padding(.vertical, 16)
                    Divider().overlay(Design.line).padding(.horizontal, 24)
                    tabContent(meeting).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }.background(Design.surface, in: RoundedRectangle(cornerRadius: 16))
                    .confirmationDialog("将这场会议移入回收站？", isPresented: $trashConfirmation, titleVisibility: .visible) { Button("移入回收站", role: .destructive) { Task { await model.moveToTrash(meeting) } }; Button("取消", role: .cancel) {} } message: { Text("会议、转写和附件仍会保留，可以在回收站恢复。") }
            } else {
                VStack(spacing: 0) { EmptyState(icon: "waveform", title: "记录每一次讨论", message: "选择左侧会议，或新建会议开始录音。中文转写、纪要和资料都留在本机。", fillsSpace: false); Button("新建会议") { Task { await model.newMeeting() } }.buttonStyle(PrimaryButton()) }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.bottom, 35).background(Design.surface, in: RoundedRectangle(cornerRadius: 22))
            }
        }.disabled(model.isSwitchingMeeting)
            .overlay {
                if model.isSwitchingMeeting {
                    HStack(spacing: 12) { ProgressView().controlSize(.small); Text("正在打开会议，笔记正在妥善保存").font(Design.Typography.callout.weight(.medium)) }
                        .padding(.horizontal, 20).padding(.vertical, 15).background(Design.surface, in: RoundedRectangle(cornerRadius: 13))
                        .shadow(color: Design.ink.opacity(0.08), radius: 18, y: 4)
                }
            }
    }
    private func header(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("会议名称", text: $model.titleDraft).font(Design.Typography.title2.weight(.semibold)).textFieldStyle(.plain).onSubmit { Task { await model.renameMeeting() } }.accessibilityLabel("会议名称")
                    HStack(spacing: 9) { Text(dateText(meeting.createdAt)); Text("·"); Text("\(meeting.segmentCount) 段转写"); if model.titleDraft != meeting.title { Button("保存名称") { Task { await model.renameMeeting() } }.buttonStyle(.plain).foregroundStyle(Design.accent) } }.font(Design.Typography.caption).foregroundStyle(Design.muted)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("导出会议纪要…") { Task { await model.exportMeeting() } }
                    Button("导入音频…") { model.importAudio() }.disabled(model.recording || model.startingRecording)
                    Divider()
                    Button("移入回收站", role: .destructive) { trashConfirmation = true }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("会议更多操作")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { recordingActions(meeting); Spacer(minLength: 8); recordingPicker }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 12) { recordingActions(meeting); recordingPicker }
            }
        }.padding(24)
    }
    private func recordingActions(_ meeting: Meeting) -> some View {
        HStack(spacing: 10) {
            if model.recordingMeetingID == meeting.id && model.recording {
                Button { Task { await model.stopRecording() } } label: { Label("停止录音", systemImage: "stop.fill") }.buttonStyle(PrimaryButton())
            } else {
                Button { Task { await model.startRecording() } } label: { Label(model.startingRecording ? "正在请求权限" : "开始录音", systemImage: "mic.fill") }.buttonStyle(PrimaryButton()).disabled(model.recording || model.startingRecording)
            }
            Button { model.askCurrentMeeting() } label: { Label("问这场会议", systemImage: "bubble.left") }.buttonStyle(QuietButton())
        }
    }
    private var recordingPicker: some View {
        Picker("声音来源", selection: $model.recordingMode) { ForEach(RecordingMode.allCases) { mode in Text(mode.rawValue).tag(mode) } }
            .labelsHidden().font(Design.Typography.callout).frame(maxWidth: 180).tint(Design.accent).disabled(model.recording || model.startingRecording)
            .help("麦克风记录现场声音；系统声音记录 Mac 内播放的声音；两者混音适合戴耳机的在线会议。")
    }
    @ViewBuilder private var recordingBar: some View {
        if model.recording {
            HStack(spacing: 10) { Image(systemName: "record.circle.fill").foregroundStyle(Design.recording); Text("正在录制\(model.recordingMode.rawValue)"); Text(timeText(model.recordingSeconds)).monospacedDigit(); Spacer(); Text("音频持续保存到本机").foregroundStyle(Design.muted) }.font(Design.Typography.caption).padding(14).background(Design.soft, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 24)
        }
    }
    @ViewBuilder private func tabContent(_ meeting: Meeting) -> some View {
        switch tab {
        case "笔记": MarkdownNotesView(model: model).id(meeting.id)
        case "中文纪要": SummaryView(model: model, meeting: meeting)
        case "附件": AttachmentsView(model: model, meeting: meeting)
        default: TranscriptView(model: model, meeting: meeting)
        }
    }
}

struct TranscriptView: View {
    @ObservedObject var model: AppModel
    let meeting: Meeting
    @State private var presented: TranscriptSheet?
    private enum TranscriptSheet: Identifiable {
        case edit(Segment), deleted(Meeting)
        var id: String {
            switch self { case .edit(let segment): return "edit-" + segment.id
            case .deleted(let meeting): return "deleted-" + meeting.id }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("转写片段").font(Design.Typography.headline)
                Text("\(meeting.segments.count) 段").font(Design.Typography.caption).foregroundStyle(Design.muted)
                Spacer(minLength: 8)
                Button { presented = .deleted(meeting) } label: {
                    Label("已删除片段（\(model.trashSegments.count)）", systemImage: "trash")
                }
                .buttonStyle(.borderless).font(Design.Typography.caption).foregroundStyle(Design.muted)
                .help("查看和恢复本场会议已删除的转写片段")
                .disabled(model.isSwitchingMeeting)
            }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 12)
            if meeting.segments.isEmpty {
                if !model.trashSegments.isEmpty {
                    VStack(spacing: 0) {
                        EmptyState(icon: "text.page", title: "会议原文暂时为空",
                                   message: "\(model.trashSegments.count) 段转写已被删除，可以查看并恢复。", fillsSpace: false)
                        Button("查看已删除片段") { presented = .deleted(meeting) }.buttonStyle(QuietButton())
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.bottom, 24)
                } else {
                    VStack(spacing: 0) {
                        EmptyState(icon: "waveform", title: "等待第一段转写", message: "点击开始录音，或导入音频。已保存的音频会逐段转换成中文文字。", fillsSpace: false)
                        Button("导入音频") { model.importAudio() }.buttonStyle(QuietButton())
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.bottom, 24)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(meeting.segments) { segment in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Label("\(timeText(segment.start)) – \(timeText(segment.end))", systemImage: "waveform")
                                        .font(Design.Typography.caption).foregroundStyle(Design.muted)
                                    Spacer()
                                    Menu {
                                        Button { presented = .edit(segment) } label: { Label("校对转写文字…", systemImage: "pencil") }
                                        Button(role: .destructive) { Task { await model.trashSegment(segment) } } label: { Label("删除转写片段", systemImage: "trash") }
                                    } label: { Image(systemName: "ellipsis.circle").imageScale(.large) }
                                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("转写片段操作")
                                    .help("校对或删除这段转写").disabled(model.isSwitchingMeeting)
                                }
                                Text(segment.text).font(Design.Typography.body).lineSpacing(7).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Divider().overlay(Design.line)
                        }
                    }.padding(24)
                }
            }
        }
        .sheet(item: $presented) { sheet in
            switch sheet {
            case .edit(let segment): SegmentEditor(segment: segment, model: model, done: { presented = nil })
            case .deleted(let selected): DeletedSegmentsSheet(model: model, meetingID: selected.id, meetingTitle: selected.title)
            }
        }
        .onChange(of: meeting.id) { presented = nil }
    }
}

struct DeletedSegmentsSheet: View {
    @ObservedObject var model: AppModel
    let meetingID: String
    let meetingTitle: String
    @Environment(\.dismiss) private var dismiss
    @State private var restoring: Set<String> = []
    private var segments: [Segment] { model.selectedMeetingID == meetingID ? model.trashSegments : [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("已删除片段", systemImage: "trash").font(Design.Typography.title2)
                    Text(meetingTitle).font(Design.Typography.caption).foregroundStyle(Design.muted).lineLimit(2)
                }
                Spacer()
                Button("完成") { dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
            }
            Text("这些片段已从会议原文移出。恢复后会回到原来的时间位置。")
                .font(Design.Typography.callout).foregroundStyle(Design.muted)
                .fixedSize(horizontal: false, vertical: true)
            if segments.isEmpty {
                EmptyState(icon: "trash", title: "没有已删除片段", message: "本场会议删除的片段会显示在这里，可以随时恢复。")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(segments) { segment in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Label("\(timeText(segment.start)) – \(timeText(segment.end))", systemImage: "waveform")
                                        .font(Design.Typography.caption).foregroundStyle(Design.muted)
                                    Spacer()
                                    Button(restoring.contains(segment.id) ? "正在恢复" : "恢复到原文") {
                                        guard model.selectedMeetingID == meetingID else { return }
                                        restoring.insert(segment.id)
                                        Task {
                                            defer { restoring.remove(segment.id) }
                                            guard model.selectedMeetingID == meetingID else { return }
                                            await model.trashSegment(segment, restore: true)
                                        }
                                    }
                                    .buttonStyle(QuietButton()).disabled(restoring.contains(segment.id) || model.isSwitchingMeeting)
                                    .accessibilityLabel("恢复此片段到会议原文")
                                }
                                Text(segment.text).font(Design.Typography.body).lineSpacing(6).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(18).background(Design.soft, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
        }
        .padding(28).frame(minWidth: 600, idealWidth: 680, maxWidth: 760, minHeight: 420, idealHeight: 540, maxHeight: 700)
        .background(Design.canvas).tint(Design.accent)
        .onChange(of: model.selectedMeetingID) { if model.selectedMeetingID != meetingID { dismiss() } }
    }
}
struct SummaryView: View {
    @ObservedObject var model: AppModel; let meeting: Meeting
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("总览、决定、行动项与未决问题").font(Design.Typography.caption).foregroundStyle(Design.muted); Spacer(); Button(meeting.summary.isEmpty ? "生成中文纪要" : "重新整理") { Task { await model.summarize() } }.buttonStyle(QuietButton()).disabled(model.jobs.values.contains { $0.title == "正在整理中文纪要" }) }.padding(24)
            if meeting.summary.isEmpty { EmptyState(icon: "text.alignleft", title: "让讨论变得清晰", message: "整理会议转写与笔记，生成中文纪要。资料没有提到的内容会明确标注。") }
            else { ScrollView { MarkdownBody(text: meeting.summary).padding(.horizontal, 28).padding(.bottom, 28) } }
        }
    }
}
struct AttachmentsView: View {
    @ObservedObject var model: AppModel; let meeting: Meeting
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("仅关联这场会议的资料").font(Design.Typography.caption).foregroundStyle(Design.muted); Spacer(); Button { model.importFiles(meetingID: meeting.id) } label: { Label("添加附件", systemImage: "paperclip") }.buttonStyle(QuietButton()) }.padding(24)
            if meeting.attachments.isEmpty { EmptyState(icon: "paperclip", title: "把讨论资料放在一起", message: "添加文档、PDF或表格。向这场会议提问时，会同时检索这些附件。") }
            else { ScrollView { LazyVStack(spacing: 12) { ForEach(meeting.attachments) { file in SourceRow(source: file, model: model) } }.padding(.horizontal, 24).padding(.bottom, 24) } }
        }
    }
}

struct SourceRow: View {
    let source: SourceFile; @ObservedObject var model: AppModel
    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "doc.text").font(.system(size: 19, weight: .light)).foregroundStyle(Design.accent).frame(width: 40, height: 44).background(Design.surface, in: RoundedRectangle(cornerRadius: 10))
            Button { Task { await model.previewSource(source) } } label: {
                VStack(alignment: .leading, spacing: 7) { Text(source.filename).font(Design.Typography.body.weight(.medium)).lineLimit(2); Text(source.statusText).font(Design.Typography.caption).foregroundStyle(source.status == "error" ? .orange : Design.muted); if !source.extractionNote.isEmpty { Text(source.extractionNote).font(Design.Typography.caption).foregroundStyle(Design.muted).lineLimit(2) } }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).accessibilityLabel("预览资料 \(source.filename)")
            Menu { Button("预览文字") { Task { await model.previewSource(source) } }; Button("在访达显示副本") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source.path)]) }; Divider(); Button("移入回收站", role: .destructive) { Task { await model.trashSource(source) } } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
        }.padding(16).background(Design.soft, in: RoundedRectangle(cornerRadius: 14))
    }
}
struct LibraryView: View {
    @ObservedObject var model: AppModel
    @State private var filter = ""
    @State private var selectedSourceID: String?
    @State private var sortOrder = [KeyPathComparator(\SourceFile.createdAt, order: .reverse)]
    private var filtered: [SourceFile] {
        model.sources.filter { filter.isEmpty || $0.filename.localizedCaseInsensitiveContains(filter) }.sorted(using: sortOrder)
    }
    private var selected: SourceFile? { model.sources.first { $0.id == selectedSourceID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("知识库").font(Design.Typography.largeTitle.weight(.semibold))
                Text("你的本机资料，检索时附上出处").font(Design.Typography.callout).foregroundStyle(Design.muted)
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Design.muted).accessibilityHidden(true)
                TextField("搜索资料名称", text: $filter).textFieldStyle(.plain).accessibilityLabel("搜索知识库资料")
                if !filter.isEmpty {
                    Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(Design.muted).accessibilityLabel("清空资料搜索")
                }
            }.font(Design.Typography.callout).padding(13).background(Design.surface, in: RoundedRectangle(cornerRadius: 10))
            if model.sources.isEmpty {
                VStack(spacing: 16) {
                    EmptyState(icon: "books.vertical", title: "建立自己的知识库",
                               message: "添加项目文档或参考资料。知会在本机建立语义索引，回答时提供出处。", fillsSpace: false)
                    Button { model.importFiles(meetingID: nil) } label: { Label("添加资料", systemImage: "plus") }.buttonStyle(PrimaryButton())
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                sourceTable
                HStack(spacing: 12) {
                    Text("\(filtered.count) / \(model.sources.count) 份资料").font(Design.Typography.caption).foregroundStyle(Design.muted)
                    Spacer()
                    Button { if let selected { Task { await model.previewSource(selected) } } } label: { Label("预览资料", systemImage: "doc.text.magnifyingglass") }
                        .buttonStyle(QuietButton()).disabled(selected == nil)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private var sourceTable: some View {
        Table(filtered, selection: $selectedSourceID, sortOrder: $sortOrder) {
            TableColumn("资料", value: \.filename) { source in
                Label(source.filename, systemImage: "doc.text")
                    .font(Design.Typography.body).lineLimit(1).help(source.filename)
                    .frame(minHeight: 38, alignment: .leading)
            }.width(min: 210, ideal: 340)
            TableColumn("关联会议") { source in
                Text(meetingName(source)).font(Design.Typography.callout).lineLimit(1).help(meetingName(source))
            }.width(min: 120, ideal: 200)
            TableColumn("读取状态", value: \.status) { source in
                Label(shortStatus(source), systemImage: statusIcon(source))
                    .font(Design.Typography.caption).lineLimit(1)
                    .help(source.statusText + (source.extractionNote.isEmpty ? "" : "\n" + source.extractionNote))
            }.width(min: 120, ideal: 170)
            TableColumn("添加时间", value: \.createdAt) { source in
                Text(dateText(source.createdAt)).font(Design.Typography.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.width(min: 125, ideal: 140)
        }
        .tableStyle(.inset).font(Design.Typography.callout)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let source = model.sources.first(where: { $0.id == id }) {
                Button("预览文字") { Task { await model.previewSource(source) } }
                Button("在访达显示副本") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source.path)]) }
                Divider()
                Button("移入回收站", role: .destructive) { Task { await model.trashSource(source) } }
            }
        } primaryAction: { ids in
            if let id = ids.first, let source = model.sources.first(where: { $0.id == id }) { Task { await model.previewSource(source) } }
        }
        .overlay {
            if filtered.isEmpty { EmptyState(icon: "magnifyingglass", title: "没有匹配的资料", message: "试试其他名称，或清空搜索。") }
        }
        .background(Design.surface, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("知识库资料表格")
    }
    private func meetingName(_ source: SourceFile) -> String {
        guard let id = source.meetingID else { return "公共知识库" }
        return model.meetings.first(where: { $0.id == id })?.title ?? "会议资料"
    }
    private func shortStatus(_ source: SourceFile) -> String {
        switch source.status {
        case "indexed": return "已索引 · \(source.chunkCount) 片段"
        case "indexing": return "正在索引"
        case "unreadable": return "无可读文字"
        case "error": return "读取失败"
        default: return "待处理"
        }
    }
    private func statusIcon(_ source: SourceFile) -> String {
        switch source.status {
        case "indexed": return "checkmark.circle"
        case "indexing": return "clock"
        case "unreadable", "error": return "exclamationmark.circle"
        default: return "doc"
        }
    }
}



struct AskView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { VStack(alignment: .leading, spacing: 8) { Text("提问").font(Design.Typography.largeTitle.weight(.semibold)); Text("从你的会议与资料中寻找答案").font(Design.Typography.caption).foregroundStyle(Design.muted) }; Spacer(); if !model.chat.isEmpty { Button("清空对话") { model.chat = [] }.buttonStyle(QuietButton()).disabled(model.isAsking) } }
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        if model.chat.isEmpty && !model.isAsking {
                            VStack(spacing: 17) { EmptyState(icon: "bubble.left.and.bubble.right", title: "把问题交给你的资料", message: "选择检索范围，再询问会议决定、行动项，或比较不同会议的讨论。回答会附上可查看的来源。")
                                HStack(spacing: 10) { suggestion("这场会议有哪些行动项？"); suggestion("资料里提到了哪些风险？") }
                            }.padding(.top, 60).padding(.bottom, 30)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 30) {
                                ForEach(model.chat) { turn in ChatTurnView(turn: turn, model: model) }
                                if model.isAsking { VStack(alignment: .leading, spacing: 15) { Label("正在检索并组织回答", systemImage: "sparkle").font(Design.Typography.caption).foregroundStyle(Design.muted); if !model.askPartial.isEmpty { MarkdownBody(text: model.askPartial) } else { ProgressView().controlSize(.small) } }.padding(.vertical, 12) }
                                Color.clear.frame(height: 1).id("end")
                            }.padding(30)
                        }
                    }.onChange(of: model.chat.count) {
                        if reduceMotion { proxy.scrollTo("end", anchor: .bottom) }
                        else { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) } }
                    }
                }
                composer
            }.background(Design.surface, in: RoundedRectangle(cornerRadius: 22))
        }.padding(4)
    }
    private func suggestion(_ text: String) -> some View {
        Button { model.question = text } label: { Text(text).font(Design.Typography.caption).foregroundStyle(Design.accent).padding(.horizontal, 13).padding(.vertical, 10).background(Design.soft, in: RoundedRectangle(cornerRadius: 10)) }.buttonStyle(.plain)
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 13) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    scopeControls
                    Spacer(minLength: 10)
                    Text("切换范围会清空对话").font(Design.Typography.caption).foregroundStyle(Design.muted).fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    scopeControls
                    Text("切换范围会清空对话").font(Design.Typography.caption).foregroundStyle(Design.muted)
                }
            }
            HStack(alignment: .bottom, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    if model.question.isEmpty { Text("询问你的会议或资料…").font(Design.Typography.body).foregroundStyle(Design.muted).padding(.top, 9).padding(.leading, 7).allowsHitTesting(false) }
                    TextEditor(text: $model.question).font(Design.Typography.body).scrollContentBackground(.hidden).frame(height: 74).accessibilityLabel("输入问题")
                }
                if model.isAsking { Button { model.cancelAsk() } label: { Image(systemName: "stop.fill").frame(width: 20, height: 20) }.buttonStyle(QuietButton()).help("停止回答").accessibilityLabel("停止回答") }
                else { Button { Task { await model.ask() } } label: { Image(systemName: "arrow.up").font(.system(size: 15, weight: .semibold)).frame(width: 20, height: 20) }.buttonStyle(PrimaryButton()).keyboardShortcut(.return, modifiers: .command).disabled(model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("发送问题") }
            }.padding(13).background(Design.soft, in: RoundedRectangle(cornerRadius: 18))
            Text("回答依据所选范围的资料生成，请查看引用核对重要信息。⌘ Return 发送").font(Design.Typography.caption).foregroundStyle(Design.muted)
        }.padding(.horizontal, 24).padding(.bottom, 20).padding(.top, 12)
    }
    private var scopeControls: some View {
        HStack(spacing: 10) {
            Text("检索范围").font(Design.Typography.caption).foregroundStyle(Design.muted).fixedSize()
            Picker("检索范围", selection: $model.scope) { Text("全部知识库").tag("all"); Text("全部会议").tag("meetings"); Text("指定会议").tag("meeting") }
                .labelsHidden().font(Design.Typography.callout).frame(width: 152).tint(Design.accent)
            if model.scope == "meeting" {
                Picker("指定会议", selection: $model.askMeetingID) { Text("请选择会议").tag(nil as String?); ForEach(model.meetings) { meeting in Text(meeting.title).tag(Optional(meeting.id)) } }
                    .labelsHidden().font(Design.Typography.callout).frame(maxWidth: 260).tint(Design.accent)
            }
        }
    }
}
struct ChatTurnView: View {
    let turn: ChatTurn; @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Spacer(minLength: 50); Text(turn.question).font(Design.Typography.body).lineSpacing(5).padding(16).background(Design.soft, in: RoundedRectangle(cornerRadius: 16)).textSelection(.enabled) }
            VStack(alignment: .leading, spacing: 15) {
                Label("知会", systemImage: "waveform").font(Design.Typography.callout.weight(.semibold)).foregroundStyle(Design.accent)
                MarkdownBody(text: turn.answer)
                if !turn.citations.isEmpty {
                    Text("参考来源").font(Design.Typography.caption.weight(.medium)).foregroundStyle(Design.muted).padding(.top, 8)
                    ForEach(turn.citations) { citation in
                        Button { model.currentCitation = citation } label: {
                            HStack(spacing: 10) { Text(citation.label).font(Design.Typography.caption.weight(.semibold)).foregroundStyle(Design.accent); VStack(alignment: .leading, spacing: 4) { Text(citation.filename.isEmpty ? citation.meetingTitle : citation.filename).font(Design.Typography.callout.weight(.medium)).lineLimit(1); if !citation.meetingTitle.isEmpty && !citation.filename.isEmpty { Text(citation.meetingTitle).font(Design.Typography.caption).foregroundStyle(Design.muted).lineLimit(1) } }; Spacer(); Image(systemName: "arrow.up.right").font(Design.Typography.caption).foregroundStyle(Design.muted) }.padding(14).background(Design.soft, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).accessibilityLabel("查看引用 \(citation.label)")
                    }
                }
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(turn.answer, forType: .string) } label: { Label("复制回答", systemImage: "doc.on.doc").font(Design.Typography.caption).foregroundStyle(Design.muted) }.buttonStyle(.plain)
            }
        }
    }
}

struct TrashView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 9) { Text("回收站").font(Design.Typography.largeTitle.weight(.semibold)); Text("已删除的会议和资料仍保留在本机，可以随时恢复。").font(Design.Typography.caption).foregroundStyle(Design.muted) }
            if model.trashMeetings.isEmpty && model.trashSources.isEmpty { EmptyState(icon: "trash", title: "回收站是空的", message: "移入回收站的会议和资料会显示在这里。单段转写可在对应会议的“已删除片段”中恢复。").background(Design.surface, in: RoundedRectangle(cornerRadius: 22)) }
            else {
                ScrollView { LazyVStack(alignment: .leading, spacing: 14) {
                    if !model.trashMeetings.isEmpty { Text("会议").font(Design.Typography.callout.weight(.semibold)).foregroundStyle(Design.muted).padding(.top, 10) }
                    ForEach(model.trashMeetings) { meeting in HStack(spacing: 15) { Image(systemName: "waveform").foregroundStyle(Design.accent); VStack(alignment: .leading, spacing: 6) { Text(meeting.title).font(Design.Typography.body.weight(.medium)); Text("\(dateText(meeting.createdAt)) · \(meeting.segmentCount) 段转写").font(Design.Typography.caption).foregroundStyle(Design.muted) }; Spacer(); Button("恢复会议") { Task { await model.restoreMeeting(meeting) } }.buttonStyle(QuietButton()) }.padding(20).background(Design.soft, in: RoundedRectangle(cornerRadius: 14)) }
                    if !model.trashSources.isEmpty { Text("资料").font(Design.Typography.callout.weight(.semibold)).foregroundStyle(Design.muted).padding(.top, 18) }
                    ForEach(model.trashSources) { source in HStack(spacing: 15) { Image(systemName: "doc.text").foregroundStyle(Design.accent); Text(source.filename).font(Design.Typography.callout).lineLimit(2); Spacer(); Button("恢复资料") { Task { await model.trashSource(source, restore: true) } }.buttonStyle(QuietButton()) }.padding(20).background(Design.soft, in: RoundedRectangle(cornerRadius: 14)) }
                }.padding(24) }.background(Design.surface, in: RoundedRectangle(cornerRadius: 22))
            }
        }.padding(4)
    }
}

struct JobFooter: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 10) {
            if model.importingAudio { HStack(spacing: 10) { ProgressView().controlSize(.small); Text("正在保存音频到本机，完成后开始转写").font(Design.Typography.caption); Spacer() }.foregroundStyle(Design.muted) }
            if let job = model.sortedJobs.first {
                HStack(spacing: 13) { ProgressView(value: job.progress).frame(width: 100); VStack(alignment: .leading, spacing: 3) { Text(job.title).font(Design.Typography.caption.weight(.medium)); Text(job.message.isEmpty ? "本地模型处理中，首次使用需要加载" : job.message).font(Design.Typography.caption).foregroundStyle(Design.muted).lineLimit(2) }; Spacer(); if model.jobs.count > 1 { Text("还有 \(model.jobs.count - 1) 项任务").font(Design.Typography.caption).foregroundStyle(Design.muted) }; Button("取消") { Task { await model.cancelJob(job.id) } }.buttonStyle(.plain).font(Design.Typography.caption).foregroundStyle(Design.muted) }
            }
            if !model.pending.isEmpty {
                HStack(spacing: 8) { Image(systemName: model.pendingErrors > 0 ? "exclamationmark.circle" : "waveform"); Text(model.pendingErrors > 0 ? "\(model.pending.count) 段音频待重试 · 原音频已保留" : "\(model.pending.count) 段音频待转写 · 音频已保存"); Spacer(); if model.pendingErrors > 0 { Button("查看原因") { model.alert = UserAlert(title: "录音转写未完成", message: model.pending.first?.error ?? "") }.buttonStyle(.plain); Button("重试") { model.retryAudio() }.buttonStyle(.plain).foregroundStyle(Design.accent) } }.font(Design.Typography.caption).foregroundStyle(Design.muted)
            }
        }.padding(.horizontal, 26).padding(.vertical, 14)
    }
}
struct ModelStatusView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("本地模型").font(Design.Typography.title3.weight(.semibold))
            ForEach([("asr", "中文转写"), ("embedding", "语义检索"), ("llm", "摘要与问答")], id: \.0) { key, title in
                let status = model.modelStatus[key] as? JSONObject ?? [:]
                let ready = status["ready"] as? Bool == true; let loaded = status["loaded"] as? Bool == true
                VStack(alignment: .leading, spacing: 7) { HStack { Text(title).font(Design.Typography.callout.weight(.medium)); Spacer(); Text(ready ? (loaded ? "已加载" : "可用，首次使用加载") : "尚未准备").font(Design.Typography.caption).foregroundStyle(ready ? Design.muted : .orange) }; Text(status["name"] as? String ?? "等待模型状态").font(Design.Typography.caption).foregroundStyle(Design.muted); if let error = status["error"] as? String, !error.isEmpty { Text(error).font(Design.Typography.caption).foregroundStyle(.orange).textSelection(.enabled) } }
            }
            Text("模型离线运行，首次处理会稍慢。模型和录音均保存在本机。").font(Design.Typography.caption).foregroundStyle(Design.muted).lineSpacing(4)
            Button("刷新状态") { Task { await model.refreshModelHealth() } }.buttonStyle(QuietButton())
        }.padding(24).frame(width: 360).tint(Design.accent)
    }
}
struct SourcePreview: View {
    let source: SourceFile; @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { VStack(alignment: .leading, spacing: 7) { Text(source.filename).font(Design.Typography.title2.weight(.semibold)).lineLimit(2); Text(source.statusText).font(Design.Typography.caption).foregroundStyle(Design.muted) }; Spacer(); Button("完成") { model.sourcePreview = nil }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction) }
            if !source.extractionNote.isEmpty { Text(source.extractionNote).font(Design.Typography.caption).foregroundStyle(Design.muted) }
            ScrollView { Text(source.text.isEmpty ? "此资料没有可预览的文字。扫描 PDF 需要 OCR 后重新导入。" : source.text).font(Design.Typography.body).lineSpacing(7).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(22) }.background(Design.soft, in: RoundedRectangle(cornerRadius: 14))
            Button("在访达显示保存的副本") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source.path)]) }.buttonStyle(.plain).font(Design.Typography.caption).foregroundStyle(Design.accent)
        }.padding(26).frame(width: 700, height: 580).background(Design.surface).tint(Design.accent)
    }
}
struct CitationPreview: View {
    let citation: Citation; @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("引用 \(citation.label)").font(Design.Typography.title2.weight(.semibold)); Spacer(); Button("完成") { model.currentCitation = nil }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction) }
            VStack(alignment: .leading, spacing: 8) { if !citation.meetingTitle.isEmpty { Label(citation.meetingTitle, systemImage: "waveform") }; if !citation.filename.isEmpty { Label(citation.filename, systemImage: "doc.text") } }.font(Design.Typography.caption).foregroundStyle(Design.muted)
            ScrollView { Text(citation.text).font(Design.Typography.body).lineSpacing(7).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(22) }.background(Design.soft, in: RoundedRectangle(cornerRadius: 14))
            if let id = citation.meetingID { Button("打开这场会议") { model.currentCitation = nil; model.section = .meetings; Task { await model.selectMeeting(id) } }.buttonStyle(QuietButton()) }
        }.padding(26).frame(width: 690, height: 500).background(Design.surface).tint(Design.accent)
    }
}
