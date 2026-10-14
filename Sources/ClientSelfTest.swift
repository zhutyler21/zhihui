import Foundation

enum ClientSelfTest {
    @MainActor static func run() async throws {
        let host = BackendHost()
        let workRoot = host.projectRoot.appendingPathComponent("work", isDirectory: true).standardizedFileURL.path + "/"
        guard ProcessInfo.processInfo.environment["ZHIHUI_DATA_DIR"] != nil,
              host.dataRoot.standardizedFileURL.path.hasPrefix(workRoot), host.port != 8768 else {
            throw APIError(message: "接口自测必须指定项目work内隔离ZHIHUI_DATA_DIR和非默认端口ZHIHUI_PORT")
        }
        defer { host.shutdown() }
        let health = try await host.start()
        guard let api = host.client, let childPID = host.childPID else { throw APIError(message: "自测需要新启动独立后端") }
        let attrs = try FileManager.default.attributesOfItem(atPath: host.dataRoot.appendingPathComponent("api-token").path)
        guard (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { throw APIError(message: "API令牌文件权限错误") }
        let created = Meeting(try await api.call("/api/meetings", method: "POST", body: ["title": "原生客户端验收会议"]))
        guard !created.id.isEmpty, created.title == "原生客户端验收会议", created.createdAt > 0 else { throw APIError(message: "客户端会议解析失败") }
        let renamed = Meeting(try await api.call("/api/meetings/\(created.id)", method: "PATCH", body: ["title": "已校验的中文会议"]))
        guard renamed.title == "已校验的中文会议" else { throw APIError(message: "中文名称没有持久保存") }
        let exported = try await api.call("/api/meetings/\(created.id)/export")
        guard (exported["markdown"] as? String)?.contains(renamed.title) == true else { throw APIError(message: "导出不含会议名称") }
        _ = try await api.call("/api/meetings/\(created.id)/trash", method: "POST")
        let trash = (try await api.call("/api/meetings?trash=1")["items"] as? [JSONObject] ?? []).map(Meeting.init)
        guard trash.contains(where: { $0.id == created.id }) else { throw APIError(message: "会议没有进入回收站") }
        _ = try await api.call("/api/meetings/\(created.id)/restore", method: "POST")
        let restored = (try await api.call("/api/meetings?trash=0")["items"] as? [JSONObject] ?? []).map(Meeting.init)
        guard restored.contains(where: { $0.id == created.id }) else { throw APIError(message: "会议没有恢复") }
        let unauthenticated = APIClient(port: host.port, token: "invalid")
        do { _ = try await unauthenticated.call("/api/health"); throw APIError(message: "服务接受了无效令牌") }
        catch let error as APIError { if error.message == "服务接受了无效令牌" { throw error } }
        // A second host reuses the authenticated, version-bound service without taking ownership.
        let reused = BackendHost(); _ = try await reused.start()
        guard reused.childPID == nil else { throw APIError(message: "已有服务被重复启动") }
        reused.shutdown(); _ = try await api.call("/api/health")
        host.shutdown()
        var stopped = false
        for _ in 0..<40 {
            if (try? await api.call("/api/health")) == nil { stopped = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard stopped else { throw APIError(message: "自己的后台子进程未在退出时停止") }
        let receipt: JSONObject = ["health": health, "meeting_id": created.id, "child_pid": Int(childPID), "token_permission": "0600", "reuse_does_not_stop_service": true, "own_child_stopped": stopped, "test_scope": "native HTTP client; excludes rendered UI and model inference"]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: host.dataRoot.appendingPathComponent("native-client-receipt.json"), options: .atomic)
    }
}
