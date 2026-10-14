import SwiftUI
import AppKit
import AVFoundation

@main
struct ZhihuiEntry {
    static func main() {
        if CommandLine.arguments.contains("--api-self-test") {
            Task { @MainActor in
                do { try await ClientSelfTest.run(); print("PASS native HTTP client and backend lifecycle checks"); exit(0) }
                catch { fputs("FAIL \(error.localizedDescription)\n", stderr); exit(1) }
            }
            RunLoop.main.run(); return
        }
        if CommandLine.arguments.contains("--self-test") {
            do { try NativeSelfTest.run(); print("PASS native audio chunk, WAV header, tail and offset checks"); exit(0) }
            catch { fputs("FAIL \(error.localizedDescription)\n", stderr); exit(1) }
        }
        ZhihuiApp.main()
    }
}
@MainActor struct ZhihuiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel
    @StateObject private var setup: OnboardingState
    @StateObject private var models: ModelPreparation
    init() {
        let appModel = AppModel()
        _model = StateObject(wrappedValue: appModel)
        let preparation = ModelPreparation(projectRoot: appModel.host.projectRoot)
        _models = StateObject(wrappedValue: preparation)
        _setup = StateObject(wrappedValue: OnboardingState(service: SystemSetupPermissions(),
                                                          store: FileSetupCompletionStore(directory: appModel.host.dataRoot),
                                                          modelsReady: { preparation.canUseModels }))
    }
    var body: some Scene {
        WindowGroup("知会", id: "main") {
            MainSceneContent(model: model, setup: setup, models: models, delegate: delegate)
        }
        .defaultSize(width: 1280, height: 850)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
            .commands {
                CommandGroup(replacing: .newItem) { Button("新建会议") { Task { await model.newMeeting() } }.keyboardShortcut("n", modifiers: .command).disabled(!setup.isInMain || !model.ready) }
                CommandMenu("会议") {
                    Button("开始录音") { Task { await model.startRecording() } }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(!setup.isInMain || model.selectedMeetingID == nil || model.recording || !model.ready || model.isSwitchingMeeting)
                    Button("停止并保存录音") { Task { await model.stopRecording() } }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!setup.isInMain || !model.recording)
                    Divider()
                    Button("导入音频…") { model.importAudio() }.disabled(!setup.isInMain || model.selectedMeetingID == nil || !model.ready || model.recording || model.isSwitchingMeeting)
                    Button("添加本场会议附件…") { model.importFiles(meetingID: model.selectedMeetingID) }.disabled(!setup.isInMain || model.selectedMeetingID == nil || !model.ready || model.isSwitchingMeeting)
                    Button("导出会议纪要…") { Task { await model.exportMeeting() } }.disabled(!setup.isInMain || model.selectedMeetingID == nil || !model.ready || model.isSwitchingMeeting)
                    Divider()
                    Button("向本场会议提问") { model.askCurrentMeeting() }.keyboardShortcut("l", modifiers: .command).disabled(!setup.isInMain || model.selectedMeetingID == nil || !model.ready || model.isSwitchingMeeting)
                    Button("导入 Foresight 记录…") { model.importForesight() }.disabled(!setup.isInMain || !model.ready)
                }
            }
        Settings { AppearanceSettingsView() }
    }
}

private struct MainSceneContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var setup: OnboardingState
    @ObservedObject var models: ModelPreparation
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    var body: some View {
        Group {
            switch setup.phase {
            case .checking:
                VStack(spacing: 18) { BrandMark(); Text("正在检查本机设置").font(Design.Typography.headline); ProgressView() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Design.canvas)
            case .welcome: WelcomeView { setup.beginPermissions() }
            case .permissions: PermissionsView(setup: setup, models: models)
            case .main: RootView(model: model)
            }
        }
            .frame(minWidth: 1080, maxWidth: .infinity, minHeight: 700, maxHeight: .infinity)
            .preferredColorScheme(appearanceMode == "light" ? .light : appearanceMode == "dark" ? .dark : nil)
            .background(MainWindowAccessor { window in delegate.registerMainWindow(window) }
                .allowsHitTesting(false).accessibilityHidden(true))
            .task { await models.check(); setup.initialize() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { setup.refresh() } }
            .onAppear {
                delegate.model = model
                delegate.models = models
                let action = openWindow
                delegate.reopenMainWindow = { action(id: "main") }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?; private var quitting = false
    weak var models: ModelPreparation?
    private weak var mainWindow: NSWindow?
    var reopenMainWindow: (() -> Void)?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        localizeMenus()
    }
    func registerMainWindow(_ window: NSWindow) {
        // Only the main scene hosts this accessor; Settings and panels never register here.
        window.identifier = NSUserInterfaceItemIdentifier("zhihui.main-window")
        mainWindow = window
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if mainWindow?.isVisible != true, let reopenMainWindow {
            reopenMainWindow()
            return false // SwiftUI has handled the scene; skip AppKit's untitled-window fallback.
        }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateNow }
        guard let model else { return .terminateNow }
        if models?.isDownloading == true || model.recording || model.startingRecording || model.importingAudio || !model.pending.isEmpty || !model.jobs.isEmpty {
            let alert = NSAlert(); alert.messageText = "退出知会？"
            alert.informativeText = "音频和已下载的模型会保留在本机，未完成的转写下次启动后继续，模型下载可重新发起并继续。当前摘要或问答生成会中断，可重新发起。"
            alert.addButton(withTitle: "退出并保留录音"); alert.addButton(withTitle: "继续使用")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        quitting = true
        Task {
            do { await models?.shutdown(); try await model.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
            catch {
                quitting = false
                model.showError(error, title: "笔记尚未保存，知会继续运行")
                sender.reply(toApplicationShouldTerminate: false)
                if mainWindow?.isVisible == true { mainWindow?.makeKeyAndOrderFront(nil) }
                else { reopenMainWindow?() }
            }
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { models?.cancel(); model?.host.shutdown() }
    private func localizeMenus() {
        let translations = ["File":"文件", "Edit":"编辑", "View":"显示", "Window":"窗口", "Help":"帮助", "Services":"服务", "Show All":"全部显示", "Hide Others":"隐藏其他", "Undo":"撤销", "Redo":"重做", "Cut":"剪切", "Copy":"复制", "Paste":"粘贴", "Paste and Match Style":"粘贴并匹配样式", "Select All":"全选", "Minimize":"最小化", "Zoom":"缩放", "Bring All to Front":"前置全部窗口", "Enter Full Screen":"进入全屏", "Exit Full Screen":"退出全屏", "Close Window":"关闭窗口", "About 知会":"关于知会", "Hide 知会":"隐藏知会", "Quit 知会":"退出知会", "知会 Help":"知会帮助", "Show Toolbar":"显示工具栏", "Hide Toolbar":"隐藏工具栏", "Customize Toolbar…":"自定义工具栏…", "Settings…":"设置…", "Settings...":"设置…", "Show Sidebar":"显示侧边栏", "Hide Sidebar":"隐藏侧边栏"]
        func translate(_ menu: NSMenu) { for item in menu.items { if let title = translations[item.title] { item.title = title }; if let submenu = item.submenu { translate(submenu) } } }
        if let menu = NSApp.mainMenu { translate(menu) }
    }
}

/// AppKit identifies the current macOS 14 scene window without retaining a closed scene.
private struct MainWindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> WindowIdentityView { WindowIdentityView(onWindow: onWindow) }
    func updateNSView(_ view: WindowIdentityView, context: Context) { view.onWindow = onWindow; if let window = view.window { onWindow(window) } }
    final class WindowIdentityView: NSView {
        var onWindow: (NSWindow) -> Void
        init(onWindow: @escaping (NSWindow) -> Void) { self.onWindow = onWindow; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { onWindow(window) } }
    }
}

