import Foundation

typealias JSONObject = [String: Any]

func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? Double(value as? String ?? "") ?? 0 }
func dateText(_ seconds: Double) -> String {
    guard seconds > 0 else { return "" }
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "MM月dd日 HH:mm"
    return formatter.string(from: Date(timeIntervalSince1970: seconds))
}
func timeText(_ seconds: Double) -> String {
    let total = max(0, Int(seconds)); return String(format: "%02d:%02d", total / 60, total % 60)
}

struct Meeting: Identifiable, Hashable {
    var id: String; var title: String; var createdAt: Double; var updatedAt: Double
    var deletedAt: Double?; var segmentCount: Int; var attachmentCount: Int; var summary: String
    var note: String; var segments: [Segment]; var attachments: [SourceFile]
    var translation: TranslationSettings
    init(_ json: JSONObject) {
        id = json["id"] as? String ?? ""; title = json["title"] as? String ?? "未命名会议"
        createdAt = number(json["created_at"]); updatedAt = number(json["updated_at"])
        deletedAt = json["deleted_at"] is NSNull || json["deleted_at"] == nil ? nil : number(json["deleted_at"])
        segmentCount = Int(number(json["segment_count"])); attachmentCount = Int(number(json["attachment_count"]))
        summary = json["summary"] as? String ?? ""; note = json["note"] as? String ?? ""
        segments = (json["segments"] as? [JSONObject] ?? []).map(Segment.init)
        attachments = (json["attachments"] as? [JSONObject] ?? []).map(SourceFile.init)
        translation = TranslationSettings(json["translation"] as? JSONObject ?? [:])
    }
}
struct Segment: Identifiable, Hashable {
    var id: String; var text: String; var start: Double; var end: Double; var createdAt: Double
    var translations: [SegmentTranslation]
    init(_ json: JSONObject) {
        id = json["id"] as? String ?? ""; text = json["text"] as? String ?? ""
        start = number(json["start_seconds"]); end = number(json["end_seconds"]); createdAt = number(json["created_at"])
        translations = (json["translations"] as? [JSONObject] ?? []).map(SegmentTranslation.init)
    }
}
struct TranslationSettings: Hashable {
    var sourceLanguage: String; var targetLanguages: [String]; var enabled: Bool
    var targetLanguage: String { targetLanguages.first ?? "en" }
    init(_ json: JSONObject = [:]) {
        sourceLanguage = json["source_language"] as? String ?? "auto"
        let targets = json["target_languages"] as? [String] ?? []
        targetLanguages = targets.isEmpty ? [json["target_language"] as? String ?? "en"] : targets
        enabled = json["enabled"] as? Bool ?? false
    }
}
struct SegmentTranslation: Hashable {
    var targetLanguage: String; var text: String; var state: String; var error: String
    init(_ json: JSONObject) {
        targetLanguage = json["target_language"] as? String ?? ""
        text = json["text"] as? String ?? ""; state = json["state"] as? String ?? ""
        error = json["error"] as? String ?? ""
    }
}
enum MeetingLanguages {
    static let sources = [("auto", "自动识别"), ("zh", "中文"), ("en", "英语"), ("ja", "日语"), ("ko", "韩语"), ("yue", "粤语")]
    static let targets = [("zh", "简体中文"), ("en", "English"), ("ja", "日本語"), ("ko", "한국어")]
    static func targetName(_ code: String) -> String { targets.first { $0.0 == code }?.1 ?? code }
    static func sourceName(_ code: String) -> String { sources.first { $0.0 == code }?.1 ?? code }
}
struct SourceFile: Identifiable, Hashable {
    var id: String; var meetingID: String?; var filename: String; var path: String
    var text: String; var extractionNote: String; var status: String; var createdAt: Double; var chunkCount: Int
    init(_ json: JSONObject) {
        id = json["id"] as? String ?? ""; meetingID = json["meeting_id"] as? String
        filename = json["filename"] as? String ?? "资料"; path = json["path"] as? String ?? ""
        text = json["text"] as? String ?? ""; extractionNote = json["extraction_note"] as? String ?? ""
        status = json["status"] as? String ?? ""; createdAt = number(json["created_at"])
        chunkCount = Int(number(json["chunk_count"]))
    }
    var statusText: String {
        switch status { case "indexed": return "已建立语义索引 · \(chunkCount) 个片段"
        case "indexing": return "正在读取与建立索引"; case "unreadable": return "无法提取文字"
        case "error": return "读取或索引失败"; default: return status.isEmpty ? "待处理" : status }
    }
}
struct Citation: Identifiable, Hashable {
    var id: String; var label: String; var meetingID: String?; var meetingTitle: String
    var sourceID: String?; var filename: String; var text: String; var score: Double
    init(_ json: JSONObject, index: Int) {
        label = String(describing: json["label"] ?? "[\(index + 1)]")
        id = "\(index)-\(label)"; meetingID = json["meeting_id"] as? String
        meetingTitle = json["meeting_title"] as? String ?? ""; sourceID = json["source_id"] as? String
        filename = json["filename"] as? String ?? ""; text = json["text"] as? String ?? ""; score = number(json["score"])
    }
}
struct ChatTurn: Identifiable {
    var id = UUID(); var question: String; var answer: String; var citations: [Citation]
    var scope: String; var meetingID: String?
}
struct JobRecord {
    var id: String; var state: String; var progress: Double; var message: String
    var partial: String; var result: Any?; var error: String
    init(_ json: JSONObject) {
        id = json["id"] as? String ?? ""; state = json["state"] as? String ?? ""
        progress = number(json["progress"]); message = json["message"] as? String ?? ""
        partial = json["partial"] as? String ?? ""; result = json["result"]; error = json["error"] as? String ?? "任务失败"
    }
}
enum AppSection: String, CaseIterable, Identifiable {
    case meetings = "会议", library = "知识库", ask = "提问", trash = "回收站"
    var id: String { rawValue }
    var icon: String {
        switch self { case .meetings: return "waveform"; case .library: return "books.vertical"
        case .ask: return "bubble.left.and.bubble.right"; case .trash: return "trash" }
    }
}
struct PendingTranscription: Codable, Identifiable {
    var id: String; var meetingID: String; var path: String; var startSeconds: Double
    var durationSeconds: Double; var error: String?
    var sourceLanguage: String? = nil; var translationTarget: String? = nil
    var translationTargets: [String]? = nil
}
