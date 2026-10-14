import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct UserAlert: Identifiable { let id = UUID(); var title: String; var message: String }
struct VisibleJob: Identifiable {
    var id: String; var title: String; var progress: Double = 0; var message: String = "准备中"; var partial: String = ""
}

@MainActor
final class AppModel: ObservableObject {
    let host = BackendHost(); let recorder = AudioRecorder()
    @Published var section: AppSection = .meetings
    @Published var meetings: [Meeting] = []; @Published var trashMeetings: [Meeting] = []
    @Published var detail: Meeting?; @Published var selectedMeetingID: String?
    @Published var sources: [SourceFile] = []; @Published var sourcePreview: SourceFile?
    @Published var trashSources: [SourceFile] = []
    @Published var trashSegments: [Segment] = []
    @Published var ready = false; @Published var starting = true; @Published var connectionError = ""
    @Published var modelStatus: JSONObject = [:]; @Published var modelDetails = false
    @Published var alert: UserAlert?; @Published var notice = ""; @Published var jobs: [String: VisibleJob] = [:]
    @Published var search = ""; @Published var searching = false
    @Published var titleDraft = ""; @Published var noteDraft = ""; @Published var noteDirty = false
    @Published var recording = false; @Published var startingRecording = false
    @Published var recordingMode: RecordingMode = .microphone; @Published var recordingStarted: Date?
    @Published var recordingMeetingID: String?; @Published var recordingSeconds: Double = 0
    @Published private var audioQueue = AudioQueueState(); @Published var processingAudio = false
    @Published var importingAudio = false; @Published var audioImportMeetingID: String?
    @Published var scope = "all"; @Published var askMeetingID: String?; @Published var question = ""
    @Published var chat: [ChatTurn] = []; @Published private var askSession = AskSessionState(); @Published var askPartial = ""
    @Published var currentCitation: Citation?
    private var recordingTimer: Timer?; private var searchTask: Task<Void, Never>?
    private var noteSaveTask: Task<Void, Never>?; private var noteMeetingID: String?
    private var noteRevision: UInt64 = 0
    private var audioImportTask: Task<Void, Never>?
    @Published private var selectionState = MeetingSelectionState()
    private let injectedClient: APIClient?
    private var initialLaunchDone = false; private var terminating = false
    private var recordingBaseOffset: Double = 0
    private var recordingChunkIDs: Set<String> = []
    var pending: [PendingTranscription] { audioQueue.pending }
    var askJobID: String? { askSession.starting ? "starting" : askSession.jobID }
    var isSwitchingMeeting: Bool { selectionState.switching }
    init(client: APIClient? = nil) { injectedClient = client; if client != nil { ready = true; starting = false } }
    var api: APIClient { get throws { guard let client = injectedClient ?? host.client, ready else { throw APIError(message: "本地服务尚未连接") }; return client } }
    var modelCaption: String {
        let names = ["asr", "embedding", "llm"]
        let count = names.filter { (modelStatus[$0] as? JSONObject)?["ready"] as? Bool == true }.count
        return count == 3 ? "本地模型已准备" : "本地模型 \(count)/3 已准备"
    }
    var sortedJobs: [VisibleJob] { jobs.values.sorted { $0.id < $1.id } }
    var pendingErrors: Int { pending.filter { $0.error != nil }.count }
    var isAsking: Bool { askSession.active }

    func start() async {
        guard !initialLaunchDone else { return }; initialLaunchDone = true
        await connect()
    }
    func connect() async {
        starting = true; connectionError = ""
        do {
            let health = try await host.start(); modelStatus = health["models"] as? JSONObject ?? [:]
            ready = true; starting = false
            loadPending(); try await reloadMeetings(); try await reloadSources()
            if selectedMeetingID == nil, let first = meetings.first { await selectMeeting(first.id) }
            resumeAudioQueue()
        } catch { connectionError = error.localizedDescription; ready = false; starting = false }
    }
    func showError(_ error: Error, title: String = "操作未完成") { alert = UserAlert(title: title, message: error.localizedDescription) }
    func reloadMeetings() async throws {
        let client = try api
        meetings = (try await client.call("/api/meetings?trash=0")["items"] as? [JSONObject] ?? []).map(Meeting.init)
        trashMeetings = (try await client.call("/api/meetings?trash=1")["items"] as? [JSONObject] ?? []).map(Meeting.init)
    }
    func reloadSources() async throws {
        sources = (try await api.call("/api/sources")["items"] as? [JSONObject] ?? []).map(SourceFile.init)
        trashSources = (try await api.call("/api/sources?trash=1")["items"] as? [JSONObject] ?? []).map(SourceFile.init)
    }
    func selectMeeting(_ id: String) async {
        let ticket = selectionState.begin(id)
        defer { selectionState.finish(ticket, id: id) }
        do {
            try await saveNotesIfNeeded()
            guard selectionState.isCurrent(ticket, id: id) else { return }
            let meeting = Meeting(try await api.call("/api/meetings/\(id)"))
            guard selectionState.isCurrent(ticket, id: id) else { return }
            let deleted = (try await api.call("/api/meetings/\(id)/segments?trash=1")["items"] as? [JSONObject] ?? []).map(Segment.init)
            guard selectionState.isCurrent(ticket, id: id) else { return }
            detail = meeting; selectedMeetingID = id; titleDraft = meeting.title; noteDraft = meeting.note
            noteRevision &+= 1
            noteMeetingID = id; noteDirty = false
            trashSegments = deleted
        } catch {
            if selectionState.isCurrent(ticket, id: id) { selectionState.fail(ticket, id: id, restoreID: selectedMeetingID); showError(error) }
        }
    }
    func refreshDetail(_ id: String? = nil) async throws {
        guard let id = id ?? selectedMeetingID else { return }
        let ticket = selectionState.ticket
        guard selectedMeetingID == id, selectionState.isCurrent(ticket, id: id) else { return }
        let oldTitle = detail?.title
        let capturedNoteRevision = noteRevision, capturedNoteDraft = noteDraft, capturedNoteDirty = noteDirty
        var meeting = Meeting(try await api.call("/api/meetings/\(id)"))
        guard selectedMeetingID == id, selectionState.isCurrent(ticket, id: id) else { return }
        let deleted = (try await api.call("/api/meetings/\(id)/segments?trash=1")["items"] as? [JSONObject] ?? []).map(Segment.init)
        if selectedMeetingID == id, selectionState.isCurrent(ticket, id: id) {
            if noteRevision == capturedNoteRevision && noteDraft == capturedNoteDraft && !capturedNoteDirty && !noteDirty {
                noteDraft = meeting.note
            } else {
                // A local edit/save or newer refresh overtook this network snapshot. Refresh the
                // other meeting fields, while retaining the latest draft and confirmed saved note.
                meeting.note = detail?.note ?? ""
                meeting.summary = detail?.summary ?? ""
            }
            detail = meeting
            if titleDraft == oldTitle || titleDraft.isEmpty { titleDraft = meeting.title }
            trashSegments = deleted
        }
    }
    func newMeeting() async {
        let ticket = selectionState.begin("creating")
        defer { selectionState.finish(ticket, id: "creating") }
        do {
            let meeting = Meeting(try await api.call("/api/meetings", method: "POST", body: [:]))
            try await reloadMeetings()
            guard selectionState.isCurrent(ticket, id: "creating") else { return }
            section = .meetings; await selectMeeting(meeting.id)
        } catch { if selectionState.isCurrent(ticket, id: "creating") { selectionState.fail(ticket, id: "creating", restoreID: selectedMeetingID); showError(error) } }
    }
    func renameMeeting() async {
        guard !isSwitchingMeeting else { return }
        guard let id = selectedMeetingID else { return }
        let capturedDraft = titleDraft
        let title = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...100).contains(title.count) else { alert = UserAlert(title: "名称不合适", message: "会议名称需要 1–100 个字。"); return }
        do {
            _ = try await api.call("/api/meetings/\(id)", method: "PATCH", body: ["title": title]); try await reloadMeetings()
            guard selectedMeetingID == id, selectionState.requestedID == id else { return }
            try await refreshDetail(id)
            if selectedMeetingID == id, selectionState.requestedID == id { if titleDraft == capturedDraft { titleDraft = title }; notice = "会议名称已保存" }
        }
        catch { showError(error) }
    }
    func noteChanged() {
        guard noteMeetingID != nil, noteDraft != detail?.note else { return }
        noteDirty = true; noteSaveTask?.cancel()
        noteSaveTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            do { try await saveNotesIfNeeded() } catch { if !Task.isCancelled { showError(error, title: "笔记未保存") } }
        }
    }
    @discardableResult func updateNoteDraft(_ value: String) -> Bool {
        guard !isSwitchingMeeting else { return false }
        if noteDraft != value { noteRevision &+= 1; noteDraft = value; noteChanged() }; return true
    }
    func saveNotesIfNeeded() async throws {
        while noteDirty, let id = noteMeetingID {
            let text = noteDraft
            _ = try await api.call("/api/meetings/\(id)", method: "PATCH", body: ["note": text])
            if noteMeetingID != id { return }
            if noteDraft == text {
                noteRevision &+= 1; noteDirty = false
                if detail?.note != text { detail?.summary = "" }
                detail?.note = text; notice = "笔记已保存"
            }
            try Task.checkCancellation()
        }
    }
    func searchChanged() {
        searchTask?.cancel(); let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000); guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            do {
                if query.isEmpty { try await reloadMeetings() }
                else {
                    var parts = URLComponents(); parts.path = "/api/search"; parts.queryItems = [URLQueryItem(name: "q", value: query)]
                    let result = try await api.call(parts.string ?? "/api/search")
                    guard !Task.isCancelled, search.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                    meetings = (result["items"] as? [JSONObject] ?? []).map(Meeting.init)
                }
            } catch { if !Task.isCancelled { showError(error) } }
        }
    }
    func moveToTrash(_ meeting: Meeting) async {
        guard audioImportMeetingID != meeting.id else { alert = UserAlert(title: "音频正在保存", message: "请等本场会议的音频保存完，再移入回收站。"); return }
        guard recordingMeetingID != meeting.id else { alert = UserAlert(title: "会议正在录音", message: "先停止录音，再将会议移入回收站。"); return }
        guard !pending.contains(where: { $0.meetingID == meeting.id }) else { alert = UserAlert(title: "会议还有音频待处理", message: "请先完成或重试录音转写，再移动会议。"); return }
        do {
            try await saveNotesIfNeeded()
            _ = try await api.call("/api/meetings/\(meeting.id)/trash", method: "POST")
            if selectedMeetingID == meeting.id { if selectionState.requestedID == meeting.id { selectionState.invalidate() }; selectedMeetingID = nil; detail = nil; noteMeetingID = nil }
            try await reloadMeetings(); try await reloadSources(); notice = "会议已移入回收站，可随时恢复"
        } catch { showError(error) }
    }
    func restoreMeeting(_ meeting: Meeting) async {
        do { _ = try await api.call("/api/meetings/\(meeting.id)/restore", method: "POST"); try await reloadMeetings(); try await reloadSources(); notice = "会议已恢复" }
        catch { showError(error) }
    }
    func trashSegment(_ segment: Segment, restore: Bool = false) async {
        guard let id = selectedMeetingID else { return }
        do { _ = try await api.call("/api/meetings/\(id)/segments/\(segment.id)/\(restore ? "restore" : "trash")", method: "POST"); try await refreshDetail(); try await reloadMeetings(); notice = restore ? "转写片段已恢复到会议原文" : "转写片段已删除，可在“已删除片段”中恢复" }
        catch { showError(error) }
    }
    func editSegment(_ segment: Segment, text: String) async throws {
        guard let id = selectedMeetingID else { throw APIError(message: "未选择会议") }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw APIError(message: "转写文字不能为空") }
        _ = try await api.call("/api/meetings/\(id)/segments/\(segment.id)", method: "PATCH", body: ["text": value])
        try await refreshDetail(); try await reloadMeetings(); notice = "转写已校对，可重新生成纪要"
    }
    func importFiles(meetingID: String?) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = []; panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.title = meetingID == nil ? "添加知识库资料" : "添加本场会议附件"
        panel.prompt = "添加资料"
        panel.message = "支持文字、PDF、Word、演示文稿和表格；文件会保存在知会自己的资料目录。"
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path)
        Task {
            do {
                let json = try await api.call("/api/sources", method: "POST", body: ["paths": paths, "meeting_id": meetingID as Any? ?? NSNull()])
                _ = try await followJob(json, title: "正在添加资料")
                try await reloadSources(); try await reloadMeetings(); try await refreshDetail(); notice = "资料已处理，请查看读取状态"
            } catch { showError(error, title: "资料添加未完成") }
        }
    }
    func previewSource(_ source: SourceFile) async {
        do { sourcePreview = SourceFile(try await api.call("/api/sources/\(source.id)")) } catch { showError(error) }
    }
    func trashSource(_ source: SourceFile, restore: Bool = false) async {
        do { _ = try await api.call("/api/sources/\(source.id)/\(restore ? "restore" : "trash")", method: "POST"); sourcePreview = nil; try await reloadSources(); try await refreshDetail(); try await reloadMeetings() }
        catch { showError(error) }
    }
    func summarize() async {
        guard let id = selectedMeetingID else { return }
        do {
            try await saveNotesIfNeeded()
            let result = try await api.call("/api/meetings/\(id)/summarize", method: "POST")
            _ = try await followJob(result, title: "正在整理中文纪要")
            try await refreshDetail(id); try await reloadMeetings(); notice = "中文纪要已保存"
        } catch { showError(error, title: "纪要未完成") }
    }
    func exportMeeting() async {
        guard let id = selectedMeetingID else { return }
        do {
            try await saveNotesIfNeeded()
            let result = try await api.call("/api/meetings/\(id)/export")
            let panel = NSSavePanel(); panel.title = "导出会议纪要"; panel.nameFieldStringValue = result["filename"] as? String ?? "会议纪要.md"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try Data((result["markdown"] as? String ?? "").utf8).write(to: url, options: .atomic); notice = "会议已导出"
        } catch { showError(error, title: "导出未完成") }
    }
    func importForesight() {
        let alert = NSAlert(); alert.messageText = "导入原 Foresight 会议"
        alert.informativeText = "读取原应用的本地会议、笔记和已关联附件，复制到知会。原记录保持不变，重复导入不会重复创建会议。"
        alert.addButton(withTitle: "开始导入"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do { let result = try await api.call("/api/import-foresight", method: "POST", body: [:]); _ = try await followJob(result, title: "正在导入历史会议"); try await reloadMeetings(); try await reloadSources(); notice = "历史会议已导入" }
            catch { showError(error, title: "历史会议未导入") }
        }
    }
    func followJob(_ response: JSONObject, title: String, onPartial: ((String) -> Void)? = nil) async throws -> Any? {
        guard let id = response["job_id"] as? String else { throw APIError(message: "本地服务未返回任务编号") }
        jobs[id] = VisibleJob(id: id, title: title)
        defer { jobs.removeValue(forKey: id) }
        while !terminating {
            let job = try await api.job(id)
            jobs[id] = VisibleJob(id: id, title: title, progress: job.progress, message: job.message, partial: job.partial)
            if !job.partial.isEmpty { onPartial?(job.partial) }
            switch job.state {
            case "done": await refreshModelHealth(); return job.result
            case "error": throw APIError(message: job.error)
            case "cancelled": throw APIError(message: "任务已取消，已有资料仍保留。")
            default: break
            }
            try await Task.sleep(nanoseconds: 600_000_000)
        }
        throw CancellationError()
    }
    func refreshModelHealth() async {
        if let health = try? await api.call("/api/health") { modelStatus = health["models"] as? JSONObject ?? [:] }
    }
    func cancelJob(_ id: String) async {
        do { _ = try await api.call("/api/jobs/\(id)/cancel", method: "POST") }
        catch { showError(error) }
    }
    func scopeChanged() {
        cancelAsk()
        chat = []; question = ""
        if scope == "meeting", askMeetingID == nil { askMeetingID = selectedMeetingID ?? meetings.first?.id }
    }
    func cancelAsk() {
        let wasActive = askSession.active
        let priorJob = askSession.cancel()
        askPartial = ""
        if let priorJob { Task { await cancelJob(priorJob) } }
        if wasActive { notice = "回答已停止" }
    }
    func askCurrentMeeting() {
        scope = "meeting"; askMeetingID = selectedMeetingID; scopeChanged(); section = .ask
    }
    func ask() async {
        let prompt = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, prompt.count <= 2000 else { alert = UserAlert(title: "请填写问题", message: "问题需要 1–2000 个字。"); return }
        guard !isAsking else { return }
        let requestedScope = scope; let requestedMeeting = scope == "meeting" ? askMeetingID : nil
        if requestedScope == "meeting", requestedMeeting == nil { alert = UserAlert(title: "请选择会议", message: "先选择需要检索的会议。"); return }
        let prior = chat.suffix(3).flatMap { [["role": "user", "content": $0.question], ["role": "assistant", "content": $0.answer]] }
        let ticket = askSession.begin(); askPartial = ""; question = ""
        do {
            let response = try await api.call("/api/ask", method: "POST", body: ["question": prompt, "scope": requestedScope, "meeting_id": requestedMeeting as Any? ?? NSNull(), "history": prior])
            guard let id = response["job_id"] as? String else { throw APIError(message: "提问任务未创建") }
            // Scope changes invalidate this conversation before any answer can be shown.
            guard scope == requestedScope, (scope != "meeting" || askMeetingID == requestedMeeting), askSession.accept(jobID: id, ticket: ticket) else { await cancelJob(id); return }
            let result = try await followJob(response, title: "正在检索并回答") { partial in
                if self.askSession.isCurrent(ticket, jobID: id) { self.askPartial = partial }
            }
            guard askSession.isCurrent(ticket, jobID: id), scope == requestedScope, (scope != "meeting" || askMeetingID == requestedMeeting) else { return }
            let json = result as? JSONObject ?? [:]
            let citations = (json["citations"] as? [JSONObject] ?? []).enumerated().map { Citation($0.element, index: $0.offset) }
            chat.append(ChatTurn(question: prompt, answer: json["answer"] as? String ?? "没有生成回答", citations: citations, scope: requestedScope, meetingID: requestedMeeting))
            askSession.finish(ticket); askPartial = ""
        } catch { if askSession.isCurrent(ticket), scope == requestedScope && (scope != "meeting" || askMeetingID == requestedMeeting) { askSession.finish(ticket); askPartial = ""; question = prompt; showError(error, title: "回答未完成") } }
    }
    func importAudio() {
        guard !isSwitchingMeeting else { return }
        guard let id = selectedMeetingID else { return }
        guard !importingAudio else { alert = UserAlert(title: "音频正在保存", message: "请等当前音频复制完，再导入其他文件。"); return }
        guard !recording && !startingRecording else { alert = UserAlert(title: "请先停止录音", message: "保存当前录音后，再导入其他音频，确保时间顺序正确。"); return }
        let panel = NSOpenPanel(); panel.title = "导入会议音频"; panel.prompt = "开始转写"
        panel.allowedContentTypes = [.audio]; panel.allowsOtherFileTypes = true
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.message = "音频在本机处理，原文件保持不变。支持 WAV、AIFF、MP3、M4A 等格式。"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls; let savedEnd = detail?.segments.map(\.end).max() ?? 0; let dataRoot = host.dataRoot
        importingAudio = true; audioImportMeetingID = id; notice = "正在保存音频到本机"
        audioImportTask = Task {
            let result = await Task.detached(priority: .userInitiated) { AudioImportSpool.copy(urls, into: dataRoot) }.value
            // Captured meeting ownership survives selection changes during a long disk copy.
            audioQueue.enqueueImports(meetingID: id, paths: result.copiedPaths, savedEnd: savedEnd)
            persistPending(); importingAudio = false; audioImportMeetingID = nil
            notice = result.copiedPaths.isEmpty ? "音频未保存" : "音频已保存，准备本地转写"
            if !result.errors.isEmpty { alert = UserAlert(title: "部分音频未保存", message: result.errors.joined(separator: "\n")) }
            resumeAudioQueue()
        }
    }
    func startRecording() async {
        guard !isSwitchingMeeting else { return }
        guard let id = selectedMeetingID, !recording, !startingRecording else { return }
        guard audioImportMeetingID != id else { alert = UserAlert(title: "音频正在保存", message: "请等导入音频保存并转写完成，再继续录音。"); return }
        guard !pending.contains(where: { $0.meetingID == id && $0.durationSeconds == 0 }) else {
            alert = UserAlert(title: "音频仍在导入", message: "请等本场会议的导入音频完成，再继续录音，确保时间顺序正确。"); return
        }
        startingRecording = true; recordingMeetingID = id
        recordingBaseOffset = audioQueue.baseOffset(meetingID: id, savedEnd: detail?.segments.map(\.end).max() ?? 0)
        recordingChunkIDs = []
        do {
            let directory = host.dataRoot.appendingPathComponent("recordings", isDirectory: true)
            let base = recordingBaseOffset
            try await recorder.start(mode: recordingMode, directory: directory) { [weak self] chunk in
                Task { @MainActor in
                    guard let self else { return }
                    self.ingestChunk(chunk, meetingID: id, base: base)
                }
            } onError: { [weak self] message in
                Task { @MainActor in
                    guard let self else { return }; self.alert = UserAlert(title: "录音出现问题", message: message)
                    await self.stopRecording()
                }
            }
            if terminating { _ = await recorder.stop(); startingRecording = false; recordingMeetingID = nil; return }
            recording = true; startingRecording = false; recordingStarted = Date(); recordingSeconds = 0
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in if let self, let started = self.recordingStarted { self.recordingSeconds = Date().timeIntervalSince(started) } }
            }
        } catch { startingRecording = false; recordingMeetingID = nil; if !terminating { showError(error, title: "录音未启动") } }
    }
    func stopRecording() async {
        guard recording || startingRecording else { return }
        recordingTimer?.invalidate(); recordingTimer = nil
        let id = recordingMeetingID; let base = recordingBaseOffset
        let finalChunks = await recorder.stop()
        if let id { for chunk in finalChunks { ingestChunk(chunk, meetingID: id, base: base) } }
        recording = false; startingRecording = false; recordingStarted = nil; recordingMeetingID = nil
        notice = "录音已保存，剩余音频将继续转写"
        // onChunk dispatches back to the main actor; yielding ensures final publication joins the queue.
        await Task.yield(); persistPending(); resumeAudioQueue()
    }
    private func ingestChunk(_ chunk: AudioChunk, meetingID: String, base: Double) {
        guard recordingChunkIDs.insert(chunk.id).inserted else { return }
        audioQueue.appendRecording(PendingTranscription(id: chunk.id, meetingID: meetingID, path: chunk.path, startSeconds: base + chunk.startSeconds, durationSeconds: chunk.durationSeconds))
        persistPending(); resumeAudioQueue()
    }
    private var pendingURL: URL { host.dataRoot.appendingPathComponent("pending-transcriptions.json") }
    private func loadPending() {
        guard FileManager.default.fileExists(atPath: pendingURL.path) else { return }
        do {
            let data = try Data(contentsOf: pendingURL)
            if let snapshot = try? JSONDecoder().decode(AudioQueueSnapshot.self, from: data) { audioQueue = AudioQueueState(snapshot: snapshot) }
            else { audioQueue = AudioQueueState(snapshot: AudioQueueSnapshot(items: try JSONDecoder().decode([PendingTranscription].self, from: data), knownEnds: [:])) }
        }
        catch { showError(error, title: "录音处理队列无法读取") }
    }
    private func persistPending() {
        do {
            try JSONEncoder().encode(audioQueue.snapshot).write(to: pendingURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pendingURL.path)
        } catch { showError(error, title: "录音处理队列未保存") }
    }
    func retryAudio() { audioQueue.retry(); persistPending(); resumeAudioQueue() }
    private func resumeAudioQueue() {
        guard ready, !processingAudio, !terminating, let first = pending.first, first.error == nil else { return }
        processingAudio = true
        Task {
            defer { processingAudio = false }
            while !terminating, let item = pending.first, item.error == nil {
                do {
                    let response = try await api.call("/api/meetings/\(item.meetingID)/transcribe", method: "POST", body: ["path": item.path, "start_seconds": item.startSeconds, "request_id": item.id])
                    let result = try await followJob(response, title: "正在转写录音")
                    guard !terminating else { return }
                    // Subsequent imported files append after the preceding file's measured duration.
                    let resultJSON = result as? JSONObject ?? [:]
                    let duration = max(number(resultJSON["duration_seconds"]), number((resultJSON["segment"] as? JSONObject)?["end_seconds"]) - item.startSeconds)
                    try audioQueue.complete(item.id, actualDuration: duration)
                    persistPending(); try await reloadMeetings(); try await refreshDetail(item.meetingID)
                    notice = recording ? "已转写到 \(timeText(item.startSeconds + max(duration, item.durationSeconds)))，录音继续保存" : (pending.isEmpty ? "录音转写已完成" : "这段录音已转写，继续处理剩余音频")
                } catch {
                    if !terminating { audioQueue.markError(item.id, message: error.localizedDescription); persistPending() }
                    return
                }
            }
        }
    }
    func shutdown() async throws {
        // Welcome and failed startup have not loaded the saved audio queue.
        // Never replace that file with a new model's empty snapshot on quit.
        guard ready || noteDirty || recording || startingRecording || importingAudio || !pending.isEmpty || !jobs.isEmpty else {
            host.shutdown(); return
        }
        noteSaveTask?.cancel()
        try await saveNotesIfNeeded()
        terminating = true
        if let audioImportTask { await audioImportTask.value }
        await stopRecording(); await Task.yield(); persistPending()
        do { try await saveNotesIfNeeded() }
        catch { terminating = false; resumeAudioQueue(); throw error }
        host.shutdown()
    }
}
