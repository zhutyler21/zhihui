import Foundation
import AppKit

struct APIError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
final class APIClient {
    let baseURL: URL; var token: String
    init(port: Int, token: String) {
        baseURL = URL(string: "http://127.0.0.1:\(port)")!; self.token = token
    }
    func call(_ path: String, method: String = "GET", body: JSONObject? = nil) async throws -> JSONObject {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw APIError(message: "请求地址无效") }
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = path == "/api/health" ? 2 : 45
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError(message: "本地服务没有返回有效响应") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject ?? [:]
        guard 200..<300 ~= http.statusCode else { throw APIError(message: json["error"] as? String ?? "本地服务错误（\(http.statusCode)）") }
        return json
    }
    func job(_ id: String) async throws -> JobRecord { JobRecord(try await call("/api/jobs/\(id)")) }
}

@MainActor
final class BackendHost {
    let projectRoot: URL; let dataRoot: URL; let port: Int
    private var child: Process?; private var output: FileHandle?
    private var generation: UInt64 = 0
    var childPID: Int32? { child?.isRunning == true ? child?.processIdentifier : nil }
    private(set) var client: APIClient?
    init() {
        let env = ProcessInfo.processInfo.environment
        let root = env["ZHIHUI_PROJECT_ROOT"] ?? Bundle.main.object(forInfoDictionaryKey: "ZhihuiProjectRoot") as? String ?? ""
        projectRoot = URL(fileURLWithPath: root, isDirectory: true)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let configuredData = env["ZHIHUI_DATA_DIR"] ?? Bundle.main.object(forInfoDictionaryKey: "ZhihuiDataDirectory") as? String
        dataRoot = configuredData.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? support.appendingPathComponent("知会", isDirectory: true)
        port = Int(env["ZHIHUI_PORT"] ?? "") ?? (Bundle.main.object(forInfoDictionaryKey: "ZhihuiPort") as? NSNumber)?.intValue ?? 8768
    }
    private func verify(_ health: JSONObject) throws {
        guard health["ok"] as? Bool == true, health["app"] as? String == "zhihui", Int(number(health["version"])) == 1,
              let dir = health["data_dir"] as? String, URL(fileURLWithPath: dir).standardizedFileURL == dataRoot.standardizedFileURL,
              let root = health["project_root"] as? String, URL(fileURLWithPath: root).standardizedFileURL == projectRoot.standardizedFileURL else {
            throw APIError(message: "本地端口被其他服务占用，或服务版本、项目与资料目录不一致。请关闭冲突服务后重试。")
        }
    }
    func start() async throws -> JSONObject {
        let launchGeneration = generation
        guard FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("backend/server.py").path) else {
            throw APIError(message: "找不到项目后端，请从项目重新构建应用。")
        }
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dataRoot.path)
        let tokenURL = dataRoot.appendingPathComponent("api-token")
        if !FileManager.default.fileExists(atPath: tokenURL.path) {
            let token = UUID().uuidString + UUID().uuidString
            try Data(token.utf8).write(to: tokenURL, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw APIError(message: "本地服务令牌为空，请检查资料目录。") }
        let api = APIClient(port: port, token: token); client = api
        let existingHealth = try? await api.call("/api/health")
        try requireCurrentLaunch(launchGeneration)
        if let health = existingHealth { try verify(health); return health }
        // A rejected authenticated response also means a listener exists: never kill or replace it.
        let probe = URL(string: "http://127.0.0.1:\(port)/api/health")!
        var probeRequest = URLRequest(url: probe); probeRequest.timeoutInterval = 1
        let existingListener = (try? await URLSession.shared.data(for: probeRequest)) != nil
        try requireCurrentLaunch(launchGeneration)
        if existingListener {
            throw APIError(message: "本地端口 \(port) 已被其他服务占用，无法安全启动。")
        }
        if let child, child.isRunning { return try await waitForHealth(api, generation: launchGeneration) }
        let python = projectRoot.appendingPathComponent(".venv/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw APIError(message: "本地 Python 环境尚未安装（项目 .venv）。") }
        let logURL = dataRoot.appendingPathComponent("backend.log")
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let log = try FileHandle(forWritingTo: logURL); try log.seekToEnd(); output = log
        let process = Process(); process.executableURL = python; process.currentDirectoryURL = projectRoot
        process.arguments = ["-m", "backend.server", "--port", String(port), "--data-dir", dataRoot.path, "--token-file", tokenURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"; environment["PYTHONPATH"] = projectRoot.path
        // The model layer is offline; prevent implicit model-hub downloads as an extra guard.
        environment["HF_HUB_OFFLINE"] = "1"; environment["TRANSFORMERS_OFFLINE"] = "1"
        process.environment = environment; process.standardOutput = log; process.standardError = log
        try process.run(); child = process
        return try await waitForHealth(api, generation: launchGeneration)
    }
    private func requireCurrentLaunch(_ launchGeneration: UInt64) throws {
        guard launchGeneration == generation else { throw CancellationError() }
    }
    private func waitForHealth(_ api: APIClient, generation launchGeneration: UInt64) async throws -> JSONObject {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            try requireCurrentLaunch(launchGeneration)
            let health = try? await api.call("/api/health")
            try requireCurrentLaunch(launchGeneration)
            if let health { try verify(health); return health }
            if let child, !child.isRunning { throw APIError(message: "本地服务启动失败，请查看资料目录中的 backend.log。") }
            try await Task.sleep(nanoseconds: 250_000_000)
            try requireCurrentLaunch(launchGeneration)
        }
        throw APIError(message: "本地服务启动超时，请查看 backend.log 后重试。")
    }
    func shutdown() {
        generation &+= 1
        if let child, child.isRunning { child.terminate() }
        child = nil; client = nil; try? output?.close(); output = nil
    }
}
