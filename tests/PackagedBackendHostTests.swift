import Foundation
import Darwin

@main struct PackagedBackendHostTests {
    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else { throw APIError(message: "Expected owned moved App, data and port") }
        let app = URL(fileURLWithPath: arguments[1]).resolvingSymlinksInPath()
        let data = URL(fileURLWithPath: arguments[2]).resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        // The controller owns a UUID fixture and an untouched copy of the real release.
        guard app.path.hasPrefix(temporary.path + "/zhihui-standalone-"),
              data.path.hasPrefix(temporary.path + "/zhihui-standalone-"),
              app.path.contains("/Moved Applications 中文/知会.app"),
              data.lastPathComponent == "private-data", let bundle = Bundle(url: app),
              bundle.bundleIdentifier == "io.local.zhihui.meetings", let port = Int(arguments[3]), port > 1024 else {
            throw APIError(message: "Packaged fixture ownership guard failed")
        }
        let paths = RuntimePaths(bundle: bundle, environment: ["ZHIHUI_DATA_DIR": data.path,
            "ZHIHUI_MODEL_DIR": data.appendingPathComponent("models").path, "ZHIHUI_PORT": String(port),
            "ZHIHUI_PROJECT_ROOT": "/__deliberately_invalid_development_path__"])
        let host = BackendHost(paths: paths)
        defer { host.shutdown() }
        let health = try await host.start()
        guard let pid = host.childPID, let client = host.client,
              (health["project_root"] as? String).map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == paths.projectRoot.resolvingSymlinksInPath().path }) == true else {
            throw APIError(message: "Actual packaged child or moved runtime identity missing: pid=\(String(describing: host.childPID)) root=\(String(describing: health["project_root"])) expected=\(app.appendingPathComponent("Contents/Resources/Runtime").path)")
        }
        _ = try await host.start()
        guard host.childPID == pid else { throw APIError(message: "Repeated start spawned another child") }
        let reuse = BackendHost(paths: paths)
        _ = try await reuse.start()
        guard reuse.childPID == nil else { throw APIError(message: "Reuse incorrectly owns the existing child") }
        reuse.shutdown()
        _ = try await client.call("/api/health")
        host.shutdown()
        for _ in 0..<100 {
            if kill(pid, 0) != 0 && errno == ESRCH { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard kill(pid, 0) != 0 && errno == ESRCH else {
            throw APIError(message: "Owned packaged child did not exit")
        }
        let result: JSONObject = ["pass": true, "runtime": paths.projectRoot.path, "health": health,
            "child_exited": true, "repeat_start_reused": true, "other_host_shutdown_preserved_child": true]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
