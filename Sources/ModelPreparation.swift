import Foundation
import Combine
import Darwin

struct PreparedModel: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    var ready: Bool
    var completedBytes: Int64
    let totalBytes: Int64
    var phase: String
    var progress: Double { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0 }
    var purpose: String {
        switch id { case "asr": return "中文转写"; case "embedding": return "会议与资料检索"; default: return "中文纪要与问答" }
    }
    var symbol: String {
        switch id { case "asr": return "waveform"; case "embedding": return "doc.text.magnifyingglass"; default: return "text.bubble" }
    }
}

private struct PreparationEvent: Decodable {
    let type: String
    let models: [PreparedModel]
    let message: String?
}

/// Runs only the explicit model installer. It never starts the meeting backend or requests TCC access.
@MainActor final class ModelPreparation: ObservableObject {
    @Published private(set) var models: [PreparedModel] = []
    @Published private(set) var isChecking = false
    @Published private(set) var isDownloading = false
    @Published private(set) var isCancelling = false
    @Published private(set) var verificationComplete = false
    @Published private(set) var message = ""
    let projectRoot: URL
    let modelRoot: URL
    private let executable: URL
    private let helper: URL
    private let isolatedPython: Bool
    private let binaryDirectory: URL?
    private let certificateFile: URL?
    private let runtimeValidation: (() throws -> Void)?
    private var process: Process?
    private var cancellationEscalation: Task<Void, Never>?
    private var requiredFiles: [(url: URL, size: Int64)] = []
    private var operation: UUID?
    private var cancelled = false
    private var receivedCompletion = false
    private var protocolFailed = false
    private var lastProgressPublication = Date.distantPast
    private let expectedIDs: Set<String> = ["asr", "embedding", "llm"]

    init(projectRoot: URL, modelRoot: URL? = nil, executable: URL? = nil, helper: URL? = nil,
         isolatedPython: Bool = false, binaryDirectory: URL? = nil, certificateFile: URL? = nil,
         runtimeValidation: (() throws -> Void)? = nil) {
        self.projectRoot = projectRoot
        self.modelRoot = (modelRoot ?? projectRoot.appendingPathComponent("models", isDirectory: true)).standardizedFileURL
        self.executable = executable ?? projectRoot.appendingPathComponent(".venv/bin/python")
        self.helper = helper ?? projectRoot.appendingPathComponent("scripts/setup-models.py")
        self.isolatedPython = isolatedPython
        self.binaryDirectory = binaryDirectory
        self.certificateFile = certificateFile
        self.runtimeValidation = runtimeValidation
        struct Catalog: Decodable {
            struct Model: Decodable {
                struct File: Decodable { let path: String; let size: Int64 }
                let id: String; let name: String; let files: [File]
            }
            let models: [Model]
        }
        if let data = try? Data(contentsOf: projectRoot.appendingPathComponent("Resources/ModelCatalog.json")),
           let catalog = try? JSONDecoder().decode(Catalog.self, from: data) {
            models = catalog.models.map {
                PreparedModel(id: $0.id, name: $0.name, ready: false, completedBytes: 0,
                              totalBytes: $0.files.reduce(0) { $0 + $1.size }, phase: "waiting")
            }
            let files = catalog.models.flatMap(\.files)
            if files.allSatisfy({ $0.size > 0 && !$0.path.hasPrefix("/") && !$0.path.split(separator: "/").contains("..") }) {
                requiredFiles = files.map { (self.modelRoot.appendingPathComponent($0.path).standardizedFileURL, $0.size) }
            }
        }
    }
    var isBusy: Bool { isChecking || isDownloading }
    var canUseModels: Bool {
        verificationComplete && !isBusy && Set(models.map(\.id)) == expectedIDs && models.allSatisfy(\.ready) && currentFilesPresent
    }
    private var currentFilesPresent: Bool {
        !requiredFiles.isEmpty && requiredFiles.allSatisfy { file in
            guard file.url.resolvingSymlinksInPath() == file.url,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: file.url.path) else { return false }
            return attributes[.type] as? FileAttributeType == .typeRegular && (attributes[.size] as? NSNumber)?.int64Value == file.size
        }
    }
    var preparedCount: Int { models.filter(\.ready).count }
    var totalBytes: Int64 { models.reduce(0) { $0 + $1.totalBytes } }
    var completedBytes: Int64 { models.reduce(0) { $0 + $1.completedBytes } }
    var progress: Double { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0 }
    var missingBytes: Int64 { max(0, totalBytes - completedBytes) }
    var activeModel: PreparedModel? { models.first { $0.phase == "downloading" || $0.phase == "checking" } }

    func check() async { guard !isBusy else { return }; await run(download: false) }
    func download() async { guard !isBusy, !canUseModels else { return }; await run(download: true) }
    func cancel() {
        guard isBusy else { return }
        cancelled = true; isCancelling = true
        if let child = process, child.isRunning {
            child.terminate()
            let ticket = operation
            cancellationEscalation?.cancel()
            cancellationEscalation = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.operation == ticket, self.isCancelling, child.isRunning else { return }
                kill(child.processIdentifier, SIGKILL)
            }
        }
    }
    func shutdown() async {
        cancel()
        let deadline = Date().addingTimeInterval(3)
        while isBusy {
            if Date() >= deadline, let child = process, child.isRunning {
                // This is the one owned downloader child, never an app or unrelated process.
                kill(child.processIdentifier, SIGKILL)
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }
    private func run(download: Bool) async {
        let ticket = UUID(); operation = ticket
        cancelled = false; receivedCompletion = false; protocolFailed = false
        lastProgressPublication = .distantPast
        verificationComplete = false; message = ""; isCancelling = false
        isDownloading = download; isChecking = !download
        defer {
            if operation == ticket {
                cancellationEscalation?.cancel(); cancellationEscalation = nil
                process = nil; operation = nil; isChecking = false; isDownloading = false; isCancelling = false
            }
        }
        do { try runtimeValidation?() }
        catch { message = error.localizedDescription; return }
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              FileManager.default.fileExists(atPath: helper.path) else {
            message = isolatedPython ? "应用内的模型准备组件不完整，请重新下载知会。" : "找不到本地模型安装环境，请从项目重新构建知会。"; return
        }
        if isolatedPython {
            let bundle = projectRoot.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
            let destination = modelRoot.resolvingSymlinksInPath()
            guard destination.path != bundle.path, !destination.path.hasPrefix(bundle.path + "/") else {
                message = "模型目录需要保存在应用之外，请使用本机资料目录。"; return
            }
        }
        let child = Process(); let pipe = Pipe()
        child.executableURL = executable
        child.arguments = (isolatedPython ? ["-I", "-B", "-u"] : ["-u"]) + [helper.path, "--model-dir", modelRoot.path, download ? "--progress-json" : "--status-json"]
        child.currentDirectoryURL = projectRoot
        var environment = ProcessInfo.processInfo.environment
        if isolatedPython {
            environment = environment.filter { !$0.key.hasPrefix("PYTHON") && !$0.key.hasPrefix("DYLD_") && $0.key != "VIRTUAL_ENV" && $0.key != "__PYVENV_LAUNCHER__" }
            environment["PATH"] = (binaryDirectory?.path ?? projectRoot.appendingPathComponent("bin").path) + ":/usr/bin:/bin"
            if let certificateFile { environment["SSL_CERT_FILE"] = certificateFile.path }
            environment.removeValue(forKey: "SSL_CERT_DIR")
            environment.removeValue(forKey: "REQUESTS_CA_BUNDLE")
            environment.removeValue(forKey: "CURL_CA_BUNDLE")
        }
        environment["DO_NOT_TRACK"] = "1"
        child.environment = environment; child.standardInput = FileHandle.nullDevice
        child.standardOutput = pipe; child.standardError = pipe; process = child
        do {
            try child.run()
            try? pipe.fileHandleForWriting.close()
            let code = try await Task.detached(priority: .utility) { [weak self] in
                var buffer = Data()
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    guard buffer.count <= 131_072 else {
                        if child.isRunning { child.terminate() }
                        throw PreparationFailure.invalidOutput
                    }
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                        if !line.isEmpty { await self?.accept(line, ticket: ticket) }
                    }
                }
                if !buffer.isEmpty { await self?.accept(buffer, ticket: ticket) }
                child.waitUntilExit()
                try? pipe.fileHandleForReading.close()
                return child.terminationStatus
            }.value
            guard operation == ticket else { return }
            if cancelled || code == 130 {
                message = "下载已暂停，已下载的内容保留在本机，稍后可以继续。"
            } else if code == 0 && receivedCompletion && !protocolFailed {
                verificationComplete = true
                if models.allSatisfy(\.ready) { message = "" }
            } else if message.isEmpty {
                message = "模型准备未完成，请检查网络后重试。"
            }
            if protocolFailed || (receivedCompletion && code != 0 && !cancelled) {
                models = models.map { var item = $0; item.ready = false; item.phase = "waiting"; return item }
            }
        } catch {
            if child.isRunning {
                child.terminate()
                await Task.detached(priority: .utility) {
                    let deadline = Date().addingTimeInterval(2)
                    while child.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(25)) }
                    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                    child.waitUntilExit()
                }.value
            }
            message = cancelled ? "下载已暂停，稍后可以继续。" : "无法完成模型检查或下载，请重试。"
        }
    }
    private func accept(_ data: Data, ticket: UUID) {
        guard operation == ticket else { return }
        guard let event = try? JSONDecoder().decode(PreparationEvent.self, from: data) else {
            protocolFailed = true; return
        }
        let valid = event.models.count == 3 && Set(event.models.map(\.id)) == expectedIDs && event.models.allSatisfy {
            $0.totalBytes > 0 && $0.completedBytes >= 0 && $0.completedBytes <= $0.totalBytes &&
            (!$0.ready || ($0.phase == "ready" && $0.completedBytes == $0.totalBytes))
        }
        if valid {
            let changedPhase = models.map(\.phase) != event.models.map(\.phase)
            if event.type != "progress" || changedPhase || Date().timeIntervalSince(lastProgressPublication) >= 0.12 {
                models = event.models; lastProgressPublication = Date()
            }
        }
        else { protocolFailed = true }
        if event.type == "complete" && valid { receivedCompletion = true }
        if let text = event.message, !text.isEmpty { message = String(text.prefix(300)) }
    }
    private enum PreparationFailure: Error { case invalidOutput }
}

func modelByteText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
}
