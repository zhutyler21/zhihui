import Foundation

struct AudioQueueSnapshot: Codable {
    var items: [PendingTranscription]
    var knownEnds: [String: Double]
}
/// Shared by actual recording/import/retry/persistence paths and the native state regression.
struct AudioQueueState {
    private(set) var pending: [PendingTranscription] = []
    private(set) var knownEnds: [String: Double] = [:]
    init(snapshot: AudioQueueSnapshot = AudioQueueSnapshot(items: [], knownEnds: [:])) {
        pending = snapshot.items.map { item in
            var value = item; value.startSeconds = max(0, item.startSeconds.isFinite ? item.startSeconds : 0)
            value.durationSeconds = max(0, item.durationSeconds.isFinite ? item.durationSeconds : 0); return value
        }
        knownEnds = snapshot.knownEnds.mapValues { max(0, $0.isFinite ? $0 : 0) }
        for item in pending where item.durationSeconds > 0 { rememberEnd(item.meetingID, item.startSeconds + item.durationSeconds) }
    }
    var snapshot: AudioQueueSnapshot { AudioQueueSnapshot(items: pending, knownEnds: knownEnds) }
    func baseOffset(meetingID: String, savedEnd: Double) -> Double {
        let queuedEnd = pending.filter { $0.meetingID == meetingID && $0.durationSeconds > 0 }
            .map { $0.startSeconds + $0.durationSeconds }.max() ?? 0
        return max(max(0, savedEnd), queuedEnd, knownEnds[meetingID] ?? 0)
    }
    mutating func appendRecording(_ item: PendingTranscription) {
        guard !pending.contains(where: { $0.id == item.id }) else { return }
        pending.append(item); rememberEnd(item.meetingID, item.startSeconds + max(0, item.durationSeconds))
    }
    mutating func enqueueImports(meetingID: String, paths: [String], savedEnd: Double, sourceLanguage: String? = nil, translationTarget: String? = nil, translationTargets: [String]? = nil) {
        let start = baseOffset(meetingID: meetingID, savedEnd: savedEnd)
        for path in paths { pending.append(PendingTranscription(id: UUID().uuidString, meetingID: meetingID, path: path, startSeconds: start, durationSeconds: 0, sourceLanguage: sourceLanguage, translationTarget: translationTarget, translationTargets: translationTargets)) }
    }
    mutating func complete(_ id: String, actualDuration: Double) throws {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let item = pending[index]
        guard actualDuration.isFinite, actualDuration >= 0 else { throw APIError(message: "本地服务返回的音频时长无效，原音频保留待重试。") }
        let duration = max(item.durationSeconds, actualDuration)
        guard duration > 0 else { throw APIError(message: "本地服务没有返回有效音频时长，原音频保留待重试。") }
        let end = item.startSeconds + duration
        rememberEnd(item.meetingID, end)
        pending.remove(at: index)
        // Other meetings keep independent clocks. Only the next unknown file follows this end;
        // later unknown files are advanced when their predecessor's duration is actually resolved.
        if let next = pending.indices.first(where: { pending[$0].meetingID == item.meetingID && pending[$0].durationSeconds <= 0 }) {
            pending[next].startSeconds = max(pending[next].startSeconds, end)
        }
    }
    mutating func markError(_ id: String, message: String) { if let index = pending.firstIndex(where: { $0.id == id }) { pending[index].error = message } }
    mutating func retry() { for index in pending.indices { pending[index].error = nil } }
    private mutating func rememberEnd(_ id: String, _ end: Double) { knownEnds[id] = max(knownEnds[id] ?? 0, end) }
}

/// Generation tickets make cancellation immediate even before an HTTP response supplies a job ID.
struct AskSessionState {
    private(set) var ticket = UUID()
    private(set) var jobID: String?
    private(set) var starting = false
    var active: Bool { starting || jobID != nil }
    mutating func begin() -> UUID { ticket = UUID(); starting = true; jobID = nil; return ticket }
    mutating func accept(jobID: String, ticket: UUID) -> Bool {
        guard self.ticket == ticket, starting else { return false }
        self.jobID = jobID; starting = false; return true
    }
    @discardableResult mutating func cancel() -> String? {
        let prior = jobID; ticket = UUID(); jobID = nil; starting = false; return prior
    }
    func isCurrent(_ ticket: UUID, jobID: String? = nil) -> Bool {
        self.ticket == ticket && active && (jobID == nil || self.jobID == jobID)
    }
    mutating func finish(_ ticket: UUID) { if self.ticket == ticket { jobID = nil; starting = false } }
}

struct MeetingSelectionState {
    private(set) var ticket = UUID()
    private(set) var requestedID: String?
    private(set) var switching = false
    mutating func begin(_ id: String) -> UUID { ticket = UUID(); requestedID = id; switching = true; return ticket }
    func isCurrent(_ ticket: UUID, id: String) -> Bool { self.ticket == ticket && requestedID == id }
    mutating func finish(_ ticket: UUID, id: String) { if isCurrent(ticket, id: id) { switching = false } }
    mutating func fail(_ ticket: UUID, id: String, restoreID: String?) {
        if isCurrent(ticket, id: id) { self.ticket = UUID(); requestedID = restoreID; switching = false }
    }
    mutating func invalidate() { ticket = UUID(); requestedID = nil; switching = false }
}
