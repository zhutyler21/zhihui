import Foundation
import SwiftUI

/// A display owns its meeting and refresh ticket independently of editor selection.
@MainActor final class ProjectionSession: ObservableObject {
    @Published private(set) var meeting: Meeting?
    @Published private(set) var message = "正在连接本场会议…"
    @Published private(set) var paused = false
    private(set) var meetingID: String?
    private var ticket = UUID()

    func bind(_ id: String) {
        guard meetingID != id else { return }
        meetingID = id; ticket = UUID(); meeting = nil; message = "正在连接本场会议…"
    }
    func setPaused(_ value: Bool) { paused = value; ticket = UUID() }
    func invalidate() { ticket = UUID() }
    func refresh(client: APIClient) async {
        guard let id = meetingID, !paused else { return }
        let request = ticket
        do {
            let response = try await client.call("/api/meetings/\(id)/projection")
            guard !Task.isCancelled, request == ticket, meetingID == id, !paused else { return }
            let value = Meeting(response)
            guard value.id == id else { throw APIError(message: "会议身份不一致，未显示其他会议内容") }
            if value.deletedAt != nil { meeting = nil; message = "这场会议已移入回收站" }
            else { meeting = value; message = "" }
        } catch {
            guard !Task.isCancelled, request == ticket, meetingID == id, !paused else { return }
            message = meeting == nil ? "暂时无法连接本场会议，正在重试" : "连接中断，保留上一屏，正在重试"
        }
    }
}
