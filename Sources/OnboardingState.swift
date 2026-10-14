import Foundation
import Combine

enum SetupPermission: String, CaseIterable, Identifiable {
    case microphone, systemAudio
    var id: String { rawValue }
}

enum SetupAuthorization: Equatable {
    case authorized, needsApproval, denied, restricted
    var isAuthorized: Bool { self == .authorized }
}

struct SetupPermissions: Equatable {
    var microphone: SetupAuthorization
    var systemAudio: SetupAuthorization
    var allAuthorized: Bool { microphone.isAuthorized && systemAudio.isAuthorized }
    var authorizedCount: Int { [microphone, systemAudio].filter(\.isAuthorized).count }
    subscript(permission: SetupPermission) -> SetupAuthorization {
        permission == .microphone ? microphone : systemAudio
    }
}

@MainActor protocol SetupPermissionService {
    func read() -> SetupPermissions
    func request(_ permission: SetupPermission) async
    func openSettings(_ permission: SetupPermission) -> Bool
}

protocol SetupCompletionStore {
    func readCompleted() -> Bool
    func writeCompleted() throws
}

/// Completion belongs to the same data directory as the app's meetings, including isolated QA.
struct FileSetupCompletionStore: SetupCompletionStore {
    let directory: URL
    private var file: URL { directory.appendingPathComponent("onboarding.json") }
    private struct Receipt: Codable { let version: Int; let completed: Bool }
    func readCompleted() -> Bool {
        guard let data = try? Data(contentsOf: file),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data) else { return false }
        return receipt.version == 1 && receipt.completed
    }
    func writeCompleted() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(Receipt(version: 1, completed: true))
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

@MainActor final class OnboardingState: ObservableObject {
    enum Phase: Equatable { case checking, welcome, permissions, main }
    @Published private(set) var phase: Phase = .checking
    @Published private(set) var permissions = SetupPermissions(microphone: .needsApproval, systemAudio: .needsApproval)
    @Published private(set) var requesting: SetupPermission?
    @Published private(set) var message = ""
    private let service: any SetupPermissionService
    private let store: any SetupCompletionStore
    private let modelsReady: @MainActor () -> Bool
    private var initialized = false
    var canEnterMain: Bool { phase == .permissions && permissions.allAuthorized && modelsReady() && requesting == nil }
    var isInMain: Bool { phase == .main }

    init(service: any SetupPermissionService, store: any SetupCompletionStore,
         modelsReady: @escaping @MainActor () -> Bool = { false }) {
        self.service = service; self.store = store; self.modelsReady = modelsReady
    }
    func initialize() {
        guard !initialized else { return }
        initialized = true
        permissions = service.read()
        if store.readCompleted() {
            phase = permissions.allAuthorized && modelsReady() ? .main : .permissions
        } else { phase = .welcome }
    }
    func beginPermissions() {
        guard phase == .welcome else { return }
        permissions = service.read(); message = ""; phase = .permissions
    }
    func refresh() {
        // Do not replace a live editor or an ongoing recording when returning to the app.
        // Recorder rechecks access before capture; every cold launch checks access again.
        guard phase != .main else { return }
        permissions = service.read()
        if permissions.allAuthorized { message = "" }
    }
    func request(_ permission: SetupPermission) async {
        guard phase == .permissions, requesting == nil else { return }
        permissions = service.read()
        guard !permissions[permission].isAuthorized else { return }
        requesting = permission; message = ""
        defer { requesting = nil; refresh() }
        await service.request(permission)
        permissions = service.read()
        if !permissions[permission].isAuthorized {
            message = permission == .microphone
                ? "麦克风尚未获准。请在系统设置中允许知会，再返回这里检查。"
                : "请在系统设置中允许知会录制系统声音。如果 macOS 要求重新打开应用，请按提示操作。"
        }
    }
    func openSettings(_ permission: SetupPermission) {
        guard phase == .permissions, requesting == nil else { return }
        if !service.openSettings(permission) { message = "未能打开系统设置。请手动进入“隐私与安全性”，允许知会使用相应权限。" }
    }
    func finish() {
        guard phase == .permissions, requesting == nil else { return }
        // The click must use fresh OS state, never a stale tick or the request's return value.
        permissions = service.read()
        guard permissions.allAuthorized else {
            message = "还有权限未完成。两项均显示已允许后，就可以进入知会。"; return
        }
        guard modelsReady() else {
            message = "本地模型尚未准备完成。下载并检查所需模型后，再进入知会。"; return
        }
        do { try store.writeCompleted(); message = ""; phase = .main }
        catch { message = "设置已获准，但未能保存引导状态：\(error.localizedDescription)。请重试。" }
    }
}
