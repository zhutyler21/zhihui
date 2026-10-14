import Foundation

private struct CheckFailure: Error { let message: String }
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(message: message) }
}
@MainActor private final class FakePermissions: SetupPermissionService {
    var value: SetupPermissions
    var requests: [SetupPermission] = []
    var holdRequest = false
    var pending: CheckedContinuation<Void, Never>?
    init(_ microphone: SetupAuthorization, _ system: SetupAuthorization) {
        value = SetupPermissions(microphone: microphone, systemAudio: system)
    }
    func read() -> SetupPermissions { value }
    func request(_ permission: SetupPermission) async {
        requests.append(permission)
        if holdRequest { await withCheckedContinuation { pending = $0 } }
    }
    func openSettings(_ permission: SetupPermission) -> Bool { false }
}
private final class MemoryCompletion: SetupCompletionStore {
    var completed: Bool
    var writes = 0
    var fail = false
    init(_ completed: Bool = false) { self.completed = completed }
    func readCompleted() -> Bool { completed }
    func writeCompleted() throws {
        writes += 1
        if fail { throw CheckFailure(message: "fixture save failure") }
        completed = true
    }
}
@main struct OnboardingTests {
    @MainActor static func main() async throws {
        let unspecified = OnboardingState(service: FakePermissions(.authorized, .authorized), store: MemoryCompletion(true))
        unspecified.initialize()
        try require(!unspecified.isInMain && !unspecified.canEnterMain, "An unspecified model provider fails closed")
        var prepared = false
        let modelStore = MemoryCompletion(true)
        let modelGate = OnboardingState(service: FakePermissions(.authorized, .authorized),
                                        store: modelStore, modelsReady: { prepared })
        modelGate.initialize()
        try require(modelGate.phase == .permissions && !modelGate.canEnterMain,
                    "Missing models must retain setup even with saved completion and granted permissions")
        modelGate.finish()
        try require(!modelGate.isInMain && modelStore.writes == 0, "Missing models cannot write completion or enter")
        prepared = true; modelGate.refresh()
        try require(modelGate.canEnterMain && !modelGate.isInMain, "Models ready enables explicit entry")
        prepared = false; modelGate.finish()
        try require(!modelGate.isInMain && modelStore.writes == 0, "Entry rechecks model availability behind stale readiness")
        prepared = true; modelGate.finish()
        try require(modelGate.isInMain && modelStore.writes == 1, "Ready models and permissions permit durable entry")
        // All four permission combinations, for new and previously completed launches.
        for saved in [false, true] {
            for mic in [false, true] {
                for audio in [false, true] {
                    let service = FakePermissions(mic ? .authorized : .denied, audio ? .authorized : .needsApproval)
                    let store = MemoryCompletion(saved)
                    let state = OnboardingState(service: service, store: store, modelsReady: { true })
                    try require(state.phase == .checking && !state.isInMain, "No main window flash before initial read")
                    state.initialize()
                    try require(state.isInMain == (saved && mic && audio), "A completion receipt cannot bypass missing OS access")
                    try require(store.writes == 0 && service.requests.isEmpty, "Initial reads must neither write completion nor prompt")
                    if !saved { try require(state.phase == .welcome, "New setup must show welcome even if already authorized"); state.beginPermissions() }
                    if !state.isInMain {
                        try require(state.canEnterMain == (mic && audio), "Both checks are mandatory")
                        state.finish()
                        try require(state.isInMain == (mic && audio), "Blocked continue cannot enter main")
                        try require(store.writes == (mic && audio ? 1 : 0), "Incomplete access must not persist completion")
                    }
                }
            }
        }
        let service = FakePermissions(.authorized, .authorized)
        let store = MemoryCompletion()
        let state = OnboardingState(service: service, store: store, modelsReady: { true })
        state.initialize(); state.finish()
        try require(state.phase == .welcome && store.writes == 0, "Cannot bypass welcome with a direct finish event")
        state.beginPermissions()
        try require(state.canEnterMain, "Fixture initially grants both")
        service.value.systemAudio = .needsApproval
        state.finish()
        try require(!state.isInMain && store.writes == 0 && !state.message.isEmpty, "Fresh click detects revoked access behind a stale green tick")
        await state.request(.systemAudio)
        try require(!state.permissions.systemAudio.isAuthorized, "A completed request never means permission granted")
        service.value.systemAudio = .authorized; state.refresh()
        try require(state.canEnterMain && !state.isInMain, "Manual OS grant enables button but does not automatically advance")
        store.fail = true; state.finish()
        try require(state.phase == .permissions && !state.message.isEmpty && !store.completed, "Save failure retains permissions screen")
        store.fail = false; state.finish()
        try require(state.isInMain && store.completed, "Retry can enter only after durable completion")
        state.beginPermissions(); state.initialize()
        try require(state.isInMain, "Completed route cannot navigate back into welcome")

        let held = FakePermissions(.needsApproval, .needsApproval); held.holdRequest = true
        let heldStore = MemoryCompletion()
        let heldState = OnboardingState(service: held, store: heldStore, modelsReady: { true })
        heldState.initialize(); heldState.beginPermissions()
        let first = Task { await heldState.request(.microphone) }
        for _ in 0..<100 where held.pending == nil { await Task.yield() }
        try require(held.pending != nil, "Pending fixture actually started")
        await heldState.request(.systemAudio)
        held.value = SetupPermissions(microphone: .authorized, systemAudio: .authorized)
        heldState.refresh(); heldState.finish()
        try require(held.requests == [.microphone] && !heldState.canEnterMain && heldStore.writes == 0,
                    "Rapid requests and finish are blocked while the OS dialog is pending")
        held.pending?.resume(); held.pending = nil; await first.value
        try require(heldState.canEnterMain, "Pending request cleanup refreshes status")
        heldState.openSettings(.systemAudio)
        try require(!heldState.message.isEmpty, "Failed settings link provides a manual route")

        guard let path = ProcessInfo.processInfo.environment["ZHIHUI_ONBOARDING_TEST_ROOT"] else { throw CheckFailure(message: "Missing isolated fixture root") }
        let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let approved = URL(fileURLWithPath: "/Users/zhutyler21/我的项目仓库/知会本地会议/work/fixture/onboarding-tests", isDirectory: true)
        try require(directory.path.hasPrefix(approved.path + "/"), "Reject non-fixture persistence target")
        let diskStore = FileSetupCompletionStore(directory: directory)
        try require(!diskStore.readCompleted(), "Absent completion is not granted")
        try diskStore.writeCompleted()
        try require(diskStore.readCompleted(), "Durable receipt is read back")
        let file = directory.appendingPathComponent("onboarding.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        try require((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Completion stays private")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        try require(object?["version"] as? Int == 1 && object?["completed"] as? Bool == true, "Exact persisted receipt")
        try Data("{\"version\":999,\"completed\":true}".utf8).write(to: file)
        try require(!diskStore.readCompleted(), "Unknown schema does not bypass onboarding")
        try Data("invalid".utf8).write(to: file)
        try require(!diskStore.readCompleted(), "Damaged receipt fails closed")
        let blockedDirectory = directory.appendingPathComponent("blocked", isDirectory: true)
        try Data("regular file blocking the directory".utf8).write(to: blockedDirectory)
        let blockedStore = FileSetupCompletionStore(directory: blockedDirectory)
        let diskState = OnboardingState(service: FakePermissions(.authorized, .authorized), store: blockedStore, modelsReady: { true })
        diskState.initialize(); diskState.beginPermissions(); diskState.finish()
        try require(diskState.phase == .permissions && !diskState.message.isEmpty && !blockedStore.readCompleted(),
                    "Real filesystem write failure must retain setup")
        try FileManager.default.moveItem(at: blockedDirectory, to: directory.appendingPathComponent("blocked-fixture-backup"))
        diskState.finish()
        try require(diskState.isInMain && blockedStore.readCompleted(), "Real filesystem retry persists completion before entering")
        print("PASS onboarding: model readiness and fresh entry gate; 8 launch combinations; fresh-access gate; no optimistic grant; busy serialization; real filesystem failure/retry; private isolated persistence")
    }
}
