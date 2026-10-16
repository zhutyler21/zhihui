import SwiftUI
import Combine
import Sparkle

/// Sparkle owns downloads, signature verification, replacement and relaunch.
/// Application termination still passes through AppDelegate's save protection.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var deferredInstallation = false
    @Published var showsDeferredNotice = false
    @Published private(set) var status = ""
    let isAvailable: Bool
    var interruptionReason: () -> String? = { nil }
    private var started = false
    private var installHandler: (() -> Void)?
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false,
                                                              updaterDelegate: self,
                                                              userDriverDelegate: nil)

    init(isAvailable: Bool = Bundle.main.object(forInfoDictionaryKey: "ZhihuiRuntimeLayout") as? String == "bundled-v1") {
        self.isAvailable = isAvailable
        super.init()
        if !isAvailable { status = "源码开发包不接收发行更新。" }
    }

    func start() {
        guard isAvailable, !started else { return }
        started = true
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: RunLoop.main).assign(to: &$automaticallyChecks)
        updater.publisher(for: \.lastUpdateCheckDate).receive(on: RunLoop.main).assign(to: &$lastCheck)
        controller.startUpdater()
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        guard isAvailable else { return }
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    func checkForUpdates() {
        guard isAvailable, canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    func installDeferredUpdate() {
        guard let installHandler else { return }
        if let reason = interruptionReason() { status = reason; return }
        self.installHandler = nil
        deferredInstallation = false
        status = "正在准备安装，知会将保存笔记并重新启动。"
        installHandler()
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if let reason = interruptionReason() {
            status = reason
            throw NSError(domain: "io.local.zhihui.updates", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: reason])
        }
        status = "正在检查新版本…"
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        // A recording may have started while the archive was downloading.
        guard let reason = interruptionReason() else { return false }
        self.installHandler = installHandler
        deferredInstallation = true
        showsDeferredNotice = true
        status = "更新已下载。\(reason) 完成后可在设置中安装并重启。"
        return true
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = "发现新版本 \(item.displayVersionString)。"
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error = error as NSError? {
            installHandler = nil
            deferredInstallation = false
            showsDeferredNotice = false
            if error.domain == SUSparkleErrorDomain && error.code == SUError.noUpdateError.rawValue {
                status = "当前已是最新版本。"
            } else if error.domain == "io.local.zhihui.updates" {
                status = error.localizedDescription
            } else {
                status = "未完成更新检查，可稍后重试或前往 GitHub 下载。"
            }
        } else if !deferredInstallation {
            status = "更新检查已结束。"
        }
    }
}

struct UpdateSettingsSection: View {
    @ObservedObject var updater: AppUpdater
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "—")（\(info["CFBundleVersion"] as? String ?? "—")）"
    }
    var body: some View {
        Section {
            LabeledContent("当前版本", value: version)
            Toggle("自动检查新版本", isOn: Binding(get: { updater.automaticallyChecks },
                                                set: { updater.setAutomaticallyChecks($0) }))
                .disabled(!updater.isAvailable)
            Text("联网检查 GitHub 发行版本；发现更新后由你确认安装。会议、录音和模型保留在本机。")
                .font(Design.Typography.caption).foregroundStyle(Design.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("检查更新…", action: updater.checkForUpdates).disabled(!updater.canCheckForUpdates)
                Link("GitHub 下载", destination: URL(string: "https://github.com/zhutyler21/zhihui/releases")!)
                Spacer(minLength: 0)
            }
            if updater.deferredInstallation {
                Button("安装更新并重启", action: updater.installDeferredUpdate)
            }
            if !updater.status.isEmpty {
                Text(updater.status).font(Design.Typography.caption).foregroundStyle(Design.muted)
                    .fixedSize(horizontal: false, vertical: true).accessibilityLabel(updater.status)
            }
            if let date = updater.lastCheck {
                Text("上次检查：\(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(Design.Typography.caption).foregroundStyle(Design.muted)
            }
        } header: { Text("软件更新") }
    }
}
