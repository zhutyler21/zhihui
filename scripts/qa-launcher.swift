// Dedicated developer launcher: open this project's app with isolated test data.
// It exposes no shell or arbitrary command interface and performs no GUI automation.
import AppKit

@MainActor final class QALauncher: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "ZhihuiProjectRoot") as? String ?? "")
        let installed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/知会.app")
        let app = FileManager.default.fileExists(atPath: installed.path) ? installed : root.appendingPathComponent("dist/知会.app")
        let data = root.appendingPathComponent("work/ui-qa")
        let status = NSTextField(labelWithString: "正在打开知会，使用项目内的隔离验收资料…")
        status.font = .systemFont(ofSize: 15)
        status.frame = NSRect(x: 24, y: 30, width: 450, height: 40)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 110),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        self.window = window; window.title = "知会 · 界面验收启动器"
        window.contentView?.addSubview(status); window.center(); window.makeKeyAndOrderFront(nil)
        do {
            guard root.path == "/Users/zhutyler21/我的项目仓库/知会本地会议",
                  FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/知会").path) else {
                throw NSError(domain: "Zhihui", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有找到本项目的应用，请先构建。"])
            }
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = true
            configuration.environment = ["ZHIHUI_DATA_DIR": data.path, "ZHIHUI_PORT": "8788"]
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
                Task { @MainActor in
                    if let error { status.stringValue = "启动失败：\(error.localizedDescription)" }
                    else { NSApp.terminate(nil) }
                }
            }
        } catch { status.stringValue = error.localizedDescription }
    }
}

@main struct LauncherMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = QALauncher()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}
