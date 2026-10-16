import SwiftUI
import AppKit

struct RootView: View {
    @ObservedObject var model: AppModel
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @State private var navigationVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $navigationVisibility) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 184, ideal: 208, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if model.recording || model.stoppingRecording {
                    ActiveRecordingBar(model: model)
                    Divider()
                }
                if model.starting { startup }
                else if !model.ready { disconnected }
                else { sectionContent }
                if !model.jobs.isEmpty || !model.pending.isEmpty || model.importingAudio {
                    VStack(spacing: 0) { Divider(); JobFooter(model: model) }.background(Design.canvas)
                } else if !model.notice.isEmpty {
                    VStack(spacing: 0) {
                        Divider()
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle").foregroundStyle(Design.teal)
                            Text(model.notice).lineLimit(2)
                            Spacer(minLength: 8)
                            Button { model.notice = "" } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless).accessibilityLabel("关闭提示")
                        }
                        .font(Design.Typography.caption).foregroundStyle(Design.muted)
                        .padding(.horizontal, 22).padding(.vertical, 10)
                    }.fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .background(Design.canvas)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar { nativeToolbar }
        .navigationTitle("知会")
        .navigationSubtitle(model.section.rawValue)
        .tint(Design.accent)
        .font(Design.Typography.body)
        .preferredColorScheme(appearanceMode == "light" ? .light : appearanceMode == "dark" ? .dark : nil)
        .frame(minWidth: 1080, maxWidth: .infinity, minHeight: 700, maxHeight: .infinity)
        .task { await model.start() }
        .alert(item: $model.alert) { item in
            Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("知道了")))
        }
        .sheet(item: $model.sourcePreview) { source in SourcePreview(source: source, model: model) }
        .sheet(item: $model.currentCitation) { citation in CitationPreview(citation: citation, model: model) }
        .onChange(of: model.scope) { model.scopeChanged() }
        .onChange(of: model.askMeetingID) { if model.scope == "meeting" { model.scopeChanged() } }
    }
    @ViewBuilder private var sectionContent: some View {
        switch model.section {
        case .meetings:
            HSplitView {
                MeetingList(model: model)
                    .frame(minWidth: 250, idealWidth: 282, maxWidth: 330, maxHeight: .infinity)
                MeetingDetailView(model: model).padding(18)
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        case .library: LibraryView(model: model).padding(24)
        case .ask: AskView(model: model).padding(24)
        case .trash: TrashView(model: model).padding(24)
        }
    }
    @ToolbarContentBuilder private var nativeToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.section == .library {
                Button { model.importFiles(meetingID: nil) } label: { Label("添加资料", systemImage: "plus") }
                    .labelStyle(.titleAndIcon).font(Design.Typography.callout).disabled(!model.ready).help("添加本机资料到知识库")
            }
            Button { model.modelDetails.toggle() } label: { Label("本地模型", systemImage: "cpu") }
                .font(Design.Typography.callout).help("查看本地模型状态")
                .popover(isPresented: $model.modelDetails) { ModelStatusView(model: model) }
            AppearanceToggleButton()
        }
        ToolbarItem(placement: .primaryAction) {
            Button { Task { await model.newMeeting() } } label: {
                Label("新建会议", systemImage: "plus").labelStyle(.titleAndIcon)
            }
            .buttonStyle(PrimaryButton()).disabled(!model.ready || model.isSwitchingMeeting)
            .help("新建会议（⌘N）").accessibilityIdentifier("meeting.new")
        }
    }
    private var startup: some View {
        VStack(spacing: 18) {
            BrandMark()
            Text("正在准备知会").font(Design.Typography.title2.weight(.semibold))
            ProgressView().controlSize(.small)
            Text("连接本机服务，读取你的会议资料").font(Design.Typography.callout).foregroundStyle(Design.muted)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var disconnected: some View {
        VStack(spacing: 16) {
            EmptyState(icon: "exclamationmark.circle", title: "暂时无法连接", message: model.connectionError, fillsSpace: false)
            Button("重新连接") { Task { await model.connect() } }.buttonStyle(PrimaryButton())
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @State private var navigationTicket = UUID()
    private var preparedModelCount: Int {
        ["asr", "embedding", "llm"].filter {
            (model.modelStatus[$0] as? JSONObject)?["ready"] as? Bool == true
        }.count
    }
    private var modelStatusColor: Color {
        model.ready && preparedModelCount == 3 ? Design.success : Design.muted
    }
    private var modelStatusLabel: String {
        guard model.ready else { return "本机 · 未连接" }
        return preparedModelCount == 3 ? "本机 · 模型就绪" : "本机 · \(preparedModelCount)/3 就绪"
    }
    private var selection: Binding<AppSection?> {
        Binding(get: { model.section }, set: { section in
            guard let section else { return }
            let ticket = UUID(); navigationTicket = ticket
            let originSection = model.section
            let originMeetingID = model.selectedMeetingID
            Task {
                do {
                    try await model.saveNotesIfNeeded()
                    guard navigationTicket == ticket,
                          model.section == originSection,
                          model.selectedMeetingID == originMeetingID else { return }
                    model.section = section
                } catch {
                    if navigationTicket == ticket,
                       model.section == originSection,
                       model.selectedMeetingID == originMeetingID {
                        model.showError(error, title: "笔记尚未保存")
                    }
                }
            }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                BrandMark()
                VStack(alignment: .leading, spacing: 3) {
                    Text("知会").font(Design.Typography.title2.weight(.semibold)).lineLimit(1)
                    Text("本地会议与知识").font(Design.Typography.caption).foregroundStyle(Design.muted).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Design.Spacing.sidebarInset).padding(.top, 24).padding(.bottom, 24)
            List(selection: selection) {
                Section {
                    ForEach(AppSection.allCases.filter { $0 != .trash }) { section in
                        Label(section.rawValue, systemImage: section.icon)
                            .font(Design.Typography.body.weight(.medium)).padding(.vertical, 7).padding(.leading, 4)
                            .symbolRenderingMode(.hierarchical)
                            .tag(section)
                            .accessibilityLabel(section.rawValue)
                    }
                } header: { Text("工作空间").font(Design.Typography.caption.weight(.medium)) }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
                .environment(\.defaultMinListRowHeight, 44)
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            Spacer(minLength: 12)
            Divider().padding(.horizontal, 17).padding(.bottom, 10)
            Button { selection.wrappedValue = .trash } label: {
                Label("回收站", systemImage: "trash")
                    .font(Design.Typography.callout.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .foregroundStyle(model.section == .trash ? Color.white : Design.muted)
                    .background(model.section == .trash ? Design.accentFill : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain).accessibilityLabel("回收站：已删除的会议和资料")
            .accessibilityValue(model.section == .trash ? "已选中" : "")
            .help("查看和恢复已删除的会议与资料；单段转写在会议内管理")
            .padding(.horizontal, 12).padding(.bottom, 14)
            Label(modelStatusLabel, systemImage: "internaldrive")
                .font(Design.Typography.caption.weight(.medium)).foregroundStyle(modelStatusColor)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("本机处理 · \(model.ready ? model.modelCaption : "本地服务未连接")")
                .accessibilityLabel("本机处理，\(model.ready ? model.modelCaption : "本地服务未连接")")
                .padding(.horizontal, 17).padding(.bottom, 20)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: model.section) { navigationTicket = UUID() }
        .onChange(of: model.selectedMeetingID) { navigationTicket = UUID() }
    }
}
struct MeetingList: View {
    @ObservedObject var model: AppModel
    @State private var selectedRow: String?
    @State private var selectionTicket = UUID()
    private var selection: Binding<String?> {
        Binding(get: { selectedRow ?? model.selectedMeetingID }, set: { id in
            guard let id else { return }
            selectedRow = id; let ticket = UUID(); selectionTicket = ticket
            Task {
                await model.selectMeeting(id)
                if selectionTicket == ticket { selectedRow = model.selectedMeetingID }
            }
        })
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("会议").font(Design.Typography.title2.weight(.semibold))
                Spacer()
                Text("\(model.meetings.count)").font(Design.Typography.caption.monospacedDigit()).foregroundStyle(Design.muted)
            }.padding(.horizontal, 20).padding(.top, 23).padding(.bottom, 16)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Design.muted).accessibilityHidden(true)
                TextField("搜索会议和转写", text: $model.search).textFieldStyle(.plain).accessibilityLabel("搜索会议和转写")
                if model.searching { ProgressView().controlSize(.mini) }
            }.font(Design.Typography.callout).padding(12).background(Design.surface, in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, Design.Spacing.listInset).padding(.bottom, 13)
                .onChange(of: model.search) { model.searchChanged() }
            if model.meetings.isEmpty {
                EmptyState(icon: model.search.isEmpty ? "waveform" : "magnifyingglass",
                           title: model.search.isEmpty ? "还没有会议" : "未找到会议",
                           message: model.search.isEmpty ? "新建会议开始录音，或导入已有记录。" : "试试其他关键词。")
            } else {
                List(model.meetings, selection: selection) { meeting in
                    MeetingRow(meeting: meeting)
                        .tag(meeting.id).help(meeting.title)
                }.listStyle(.inset).scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
            }
            Divider()
            Button { model.importForesight() } label: { Label("导入 Foresight 会议", systemImage: "square.and.arrow.down") }
                .buttonStyle(.borderless).font(Design.Typography.callout).padding(.vertical, 15)
        }
        .background(Design.canvas)
        .onAppear { selectedRow = model.selectedMeetingID }
        .onChange(of: model.selectedMeetingID) { selectedRow = model.selectedMeetingID }
        .onChange(of: model.isSwitchingMeeting) { if !model.isSwitchingMeeting { selectedRow = model.selectedMeetingID } }
    }
}
struct MeetingRow: View {
    let meeting: Meeting
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(meeting.title).font(Design.Typography.body.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { Text(dateText(meeting.createdAt)); Text("·"); counts }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 5) { Text(dateText(meeting.createdAt)); counts }
            }.font(Design.Typography.caption).monospacedDigit().foregroundStyle(.secondary)
        }.padding(.vertical, 11).accessibilityElement(children: .combine)
    }
    private var counts: some View {
        HStack(spacing: 8) {
            Label("\(meeting.segmentCount)", systemImage: "waveform")
            if meeting.attachmentCount > 0 { Label("\(meeting.attachmentCount)", systemImage: "paperclip") }
        }
    }
}

struct AppearanceToggleButton: View {
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }
    private var actionTitle: String { isDark ? "切换到浅色外观" : "切换到深色外观" }
    private var currentAppearance: String {
        let name = isDark ? "深色" : "浅色"
        return appearanceMode == "system" ? "跟随系统，当前\(name)" : "当前\(name)"
    }
    var body: some View {
        Button { appearanceMode = isDark ? "light" : "dark" } label: {
            Label(actionTitle, systemImage: isDark ? "sun.max.fill" : "moon.fill")
                .labelStyle(.iconOnly)
        }
        .font(Design.Typography.callout)
        .help(actionTitle)
        .accessibilityLabel(actionTitle)
        .accessibilityValue(currentAppearance)
    }
}

struct AppearanceSettingsView: View {
    @ObservedObject var updater: AppUpdater
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    var body: some View {
        Form {
            Section {
                Picker("外观", selection: $appearanceMode) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }.pickerStyle(.segmented).tint(Design.accentFill)
                Text("只改变知会的显示方式，不修改 macOS 的系统外观。").font(Design.Typography.callout).foregroundStyle(Design.muted)
            } header: { Text("界面外观") }
            UpdateSettingsSection(updater: updater)
        }.formStyle(.grouped).font(Design.Typography.body).padding(14).frame(width: 520, height: 540)
            .navigationTitle("知会设置")
            .tint(Design.accent)
            .preferredColorScheme(appearanceMode == "light" ? .light : appearanceMode == "dark" ? .dark : nil)
    }
}
