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
    let projectRoot: URL; let dataRoot: URL; let modelRoot: URL; let port: Int
    let runtime: RuntimePaths
    private var child: Process?; private var output: FileHandle?
    private var generation: UInt64 = 0
    var childPID: Int32? { child?.isRunning == true ? child?.processIdentifier : nil }
    private(set) var client: APIClient?
    init(paths: RuntimePaths = RuntimePaths()) {
        runtime = paths
        projectRoot = paths.projectRoot; dataRoot = paths.dataRoot; modelRoot = paths.modelRoot; port = paths.port
    }
    func verify(_ health: JSONObject) throws {
        guard health["ok"] as? Bool == true, health["app"] as? String == "zhihui", Int(number(health["version"])) == 1,
              let dir = health["data_dir"] as? String, URL(fileURLWithPath: dir).resolvingSymlinksInPath().path == dataRoot.resolvingSymlinksInPath().path,
              let root = health["project_root"] as? String, URL(fileURLWithPath: root).resolvingSymlinksInPath().path == projectRoot.resolvingSymlinksInPath().path,
              let models = health["models_dir"] as? String, URL(fileURLWithPath: models).resolvingSymlinksInPath().path == modelRoot.resolvingSymlinksInPath().path,
              runtime.ffmpeg == nil || (health["ffmpeg_path"] as? String).map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == runtime.ffmpeg?.resolvingSymlinksInPath().path }) == true else {
            throw APIError(message: "本地端口被其他服务占用，或服务版本、运行环境、模型与资料目录不一致。请关闭冲突服务后重试。")
        }
    }
    func start() async throws -> JSONObject {
        let launchGeneration = generation
        try runtime.validate()
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
        let logURL = dataRoot.appendingPathComponent("backend.log")
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let log = try FileHandle(forWritingTo: logURL); try log.seekToEnd(); output = log
        let process = Process(); process.executableURL = runtime.python; process.currentDirectoryURL = projectRoot
        let entry = runtime.isBundled ? ["-I", "-B", "-u", runtime.backendLauncher.path] : ["-u", "-m", "backend.server"]
        process.arguments = entry + ["--port", String(port), "--data-dir", dataRoot.path, "--models-dir", modelRoot.path, "--token-file", tokenURL.path]
        if let ffmpeg = runtime.ffmpeg { process.arguments?.append(contentsOf: ["--ffmpeg", ffmpeg.path]) }
        var environment = ProcessInfo.processInfo.environment
        if let binaryDirectory = runtime.binaryDirectory {
            environment = environment.filter { !$0.key.hasPrefix("PYTHON") && !$0.key.hasPrefix("DYLD_") && $0.key != "VIRTUAL_ENV" && $0.key != "__PYVENV_LAUNCHER__" }
            environment["PATH"] = binaryDirectory.path + ":/usr/bin:/bin"
            environment["SSL_CERT_FILE"] = runtime.certificateFile?.path
            environment.removeValue(forKey: "SSL_CERT_DIR")
            environment.removeValue(forKey: "REQUESTS_CA_BUNDLE")
            environment.removeValue(forKey: "CURL_CA_BUNDLE")
        } else {
            environment["PYTHONPATH"] = projectRoot.path
        }
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
