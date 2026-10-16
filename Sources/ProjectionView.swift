import SwiftUI
import AppKit

struct TranslationProjectionView: View {
    @ObservedObject var model: AppModel
    let meetingID: String
    @StateObject private var session = ProjectionSession()
    @StateObject private var windowReference = ProjectionWindowReference()
    @State private var fontSize = 32.0
    @State private var showOriginal = true
    @State private var followLatest = true
    @State private var darkBackground = true
    @State private var showLanguages = false
    private var targets: [String] { session.meeting?.translation.targetLanguages ?? [] }
    private var columns: [String] { (showOriginal ? ["original"] : []) + targets }
    private var revision: [Segment] { session.meeting?.segments ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            controls.padding(20)
            Divider()
            if let meeting = session.meeting {
                if !meeting.translation.enabled {
                    Label("本场实时翻译未开启，可在“语言设置”中开启", systemImage: "info.circle")
                        .font(Design.Typography.body).padding(14).frame(maxWidth: .infinity).background(Design.soft)
                }
                board(meeting)
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "rectangle.on.rectangle").font(.system(size: 42)).foregroundStyle(Design.accent)
                    Text(session.message).font(.system(size: 24, weight: .medium))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(minWidth: 1000, minHeight: 650)
        .foregroundStyle(Design.ink).background(Design.canvas)
        .preferredColorScheme(darkBackground ? .dark : .light)
        .background(ProjectionWindowAccessor(reference: windowReference).allowsHitTesting(false).accessibilityHidden(true))
        .sheet(isPresented: $showLanguages) {
            if let meeting = session.meeting { TranslationSettingsSheet(model: model, meeting: meeting).id(meeting.id) }
        }
        .task(id: meetingID) {
            session.bind(meetingID)
            while !Task.isCancelled {
                if let client = try? model.api { await session.refresh(client: client) }
                do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            }
        }
        .onDisappear { session.invalidate() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("实时翻译大屏").font(.system(size: 20, weight: .semibold))
                    Text(session.meeting?.title ?? "正在打开会议")
                        .font(Design.Typography.callout).foregroundStyle(Design.muted).lineLimit(2)
                }
                Spacer()
                Label(session.paused ? "显示已暂停" : model.recordingMeetingID == meetingID ? "录音中" : "等待本场新内容",
                      systemImage: session.paused ? "pause.circle" : "waveform")
                    .font(Design.Typography.callout).foregroundStyle(session.paused ? Design.muted : Design.accent)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { displayActions; Spacer(minLength: 4); presentationActions }
                VStack(alignment: .leading, spacing: 12) { displayActions; presentationActions }
            }.font(Design.Typography.callout)
        }
    }
    private var displayActions: some View {
        HStack(spacing: 16) {
            Button("语言设置…", systemImage: "globe") { showLanguages = true }
                .disabled(session.meeting == nil || model.recordingMeetingID == meetingID || model.translationUpdating)
            Button("补齐译文") {
                if let meeting = session.meeting { Task { await model.translateMeeting(meeting) } }
            }.disabled(session.meeting?.segments.isEmpty != false || model.translatingMeetings.contains(meetingID))
            Button(session.paused ? "继续显示" : "暂停显示", systemImage: session.paused ? "play.fill" : "pause.fill") {
                session.setPaused(!session.paused)
            }.help("只暂停大屏更新，录音与翻译继续保存")
            Toggle("显示原文", isOn: $showOriginal).toggleStyle(.checkbox)
            Toggle("跟随最新", isOn: $followLatest).toggleStyle(.checkbox)
                .help("新发言显示在顶部；开启后自动回到最新内容")
        }
    }
    private var presentationActions: some View {
        HStack(spacing: 14) {
            Button { fontSize = max(24, fontSize - 4) } label: { Image(systemName: "textformat.size.smaller") }
                .accessibilityLabel("缩小字幕").disabled(fontSize <= 24)
            Text("\(Int(fontSize))").monospacedDigit().frame(minWidth: 24).accessibilityLabel("字幕字号 \(Int(fontSize))")
            Button { fontSize = min(64, fontSize + 4) } label: { Image(systemName: "textformat.size.larger") }
                .accessibilityLabel("放大字幕").disabled(fontSize >= 64)
            Button { darkBackground.toggle() } label: { Image(systemName: darkBackground ? "sun.max" : "moon") }
                .accessibilityLabel(darkBackground ? "切换大屏为浅色" : "切换大屏为深色")
            Button("全屏", systemImage: "arrow.up.left.and.arrow.down.right") {
                windowReference.window?.toggleFullScreen(nil)
            }.help("可移到外接显示器后全屏；按 Esc 退出")
        }
    }
    private func board(_ meeting: Meeting) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(columns, id: \.self) { language in
                    Text(language == "original" ? "原文 · \(MeetingLanguages.sourceName(meeting.translation.sourceLanguage))" : MeetingLanguages.targetName(language))
                        .font(.system(size: 20, weight: .semibold)).foregroundStyle(Design.accent)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.vertical, 18)
                }
            }.background(Design.surface)
            Divider()
            if meeting.segments.isEmpty {
                VStack(spacing: 14) {
                    Text("等待讲话内容").font(.system(size: 30, weight: .medium))
                    Text("在主窗口开始录音或导入音频，原文与各语言译文会在这里逐段出现。")
                        .font(Design.Typography.body).foregroundStyle(Design.muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            Color.clear.frame(height: 1).id("projection-top")
                            // Only the display reverses time order; meeting transcripts stay chronological.
                            ForEach(meeting.segments.reversed()) { segment in
                                HStack(alignment: .top, spacing: 0) {
                                    ForEach(columns, id: \.self) { language in
                                        subtitle(segment, language: language)
                                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                                            .padding(.horizontal, 22).padding(.vertical, 24)
                                    }
                                }.frame(maxWidth: .infinity).background(Design.surface.opacity(0.35)).id(segment.id)
                                Divider()
                            }
                        }
                    }
                    .onChange(of: revision, initial: true) { _, _ in follow(proxy) }
                    .onChange(of: followLatest) { _, _ in follow(proxy) }
                    .onChange(of: fontSize) { _, _ in follow(proxy) }
                    .onChange(of: columns) { _, _ in follow(proxy) }
                    .background(GeometryReader { geometry in
                        Color.clear.onChange(of: geometry.size) { _, _ in follow(proxy) }
                    }.allowsHitTesting(false).accessibilityHidden(true))
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func follow(_ proxy: ScrollViewProxy) {
        if followLatest {
            Task { @MainActor in
                await Task.yield()
                if followLatest { proxy.scrollTo("projection-top", anchor: .top) }
            }
        }
    }
    @ViewBuilder private func subtitle(_ segment: Segment, language: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(timeText(segment.start)).font(Design.Typography.caption).foregroundStyle(Design.muted).monospacedDigit()
            if language == "original" { subtitleText(segment.text) }
            else if let translation = segment.translations.first(where: { $0.targetLanguage == language }) {
                if translation.state == "done" { subtitleText(translation.text) }
                else { Text(translation.state == "error" ? "译文未完成，可点“补齐译文”重试" : "正在翻译…")
                    .font(.system(size: max(20, fontSize - 6))).foregroundStyle(Design.muted) }
            } else { Text("等待译文…").font(.system(size: max(20, fontSize - 6))).foregroundStyle(Design.muted) }
        }
    }
    private func subtitleText(_ text: String) -> some View {
        Text(text).font(.system(size: fontSize, weight: .medium)).lineSpacing(fontSize * 0.25)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
    private var footer: some View {
        HStack(spacing: 12) {
            Label("本机处理", systemImage: "lock.shield")
            Text(session.message.isEmpty ? "原文与译文按同一段发言对齐 · 译文逐栏更新" : session.message)
            Spacer()
            Text("最新在顶部 · 最近 30 段 · 暂停显示不停止录音")
        }.font(Design.Typography.caption).foregroundStyle(Design.muted)
    }
}

@MainActor private final class ProjectionWindowReference: ObservableObject { weak var window: NSWindow? }
private struct ProjectionWindowAccessor: NSViewRepresentable {
    let reference: ProjectionWindowReference
    func makeNSView(context: Context) -> ProjectionNativeView {
        let view = ProjectionNativeView(); view.reference = reference; return view
    }
    func updateNSView(_ view: ProjectionNativeView, context: Context) { view.reference = reference }
}
private final class ProjectionNativeView: NSView {
    weak var reference: ProjectionWindowReference?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); window?.tabbingMode = .disallowed; reference?.window = window
    }
}
