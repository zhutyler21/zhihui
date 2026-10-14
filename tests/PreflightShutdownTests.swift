import Foundation

private struct Failure: Error { let message: String }
@main struct PreflightShutdownTests {
    @MainActor static func main() async throws {
        guard let raw = ProcessInfo.processInfo.environment["ZHIHUI_DATA_DIR"] else { throw Failure(message: "Missing fixture root") }
        let directory = URL(fileURLWithPath: raw).standardizedFileURL
        guard directory.path.hasPrefix("/Users/zhutyler21/我的项目仓库/知会本地会议/work/fixture/onboarding-tests/") else { throw Failure(message: "Not an owned fixture") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("pending-transcriptions.json")
        let item = PendingTranscription(id: "welcome-quit-fixture", meetingID: "meeting-quit-fixture", path: directory.appendingPathComponent("retained.wav").path, startSeconds: 23, durationSeconds: 4)
        let original = try JSONEncoder().encode(AudioQueueSnapshot(items: [item], knownEnds: [item.meetingID: 27]))
        try original.write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let cold = AppModel()
        try await cold.shutdown()
        guard try Data(contentsOf: file) == original else { throw Failure(message: "Welcome quit overwrote uninitialized saved audio queue") }
        let failedStartup = AppModel()
        await failedStartup.start()
        guard !failedStartup.ready && !failedStartup.connectionError.isEmpty else { throw Failure(message: "Failure fixture did not fail startup") }
        try await failedStartup.shutdown()
        guard try Data(contentsOf: file) == original else { throw Failure(message: "Startup failure quit overwrote retained audio queue") }
        print("PASS actual AppModel: quitting before service initialization and after failed startup preserves saved audio queue bytes")
    }
}
