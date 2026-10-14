import Foundation
import Darwin

private struct Failure: Error { let message: String }
private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure(message: message) }
}
@main struct ModelPreparationTests {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: "/Users/zhutyler21/我的项目仓库/知会本地会议", isDirectory: true)
        guard let location = ProcessInfo.processInfo.environment["ZHIHUI_MODEL_TEST_ROOT"] else { throw Failure(message: "Missing approved fixture") }
        let fixture = URL(fileURLWithPath: location, isDirectory: true).standardizedFileURL
        try require(fixture.path.hasPrefix(root.appendingPathComponent("work/setup-and-trash-v2/native-tests/").path + "/"), "Only named fixture output is allowed")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let helper = fixture.appendingPathComponent("helper.py")
        let modeFile = fixture.appendingPathComponent("mode")
        let testProject = fixture.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: testProject.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        let catalogModels: [[String: Any]] = try ["asr", "embedding", "llm"].map { id in
            let file = testProject.appendingPathComponent("models/\(id)/weights.bin")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 100).write(to: file)
            return ["id": id, "name": "fixture " + id, "files": [["path": id + "/weights.bin", "size": 100]]]
        }
        try JSONSerialization.data(withJSONObject: ["models": catalogModels]).write(to: testProject.appendingPathComponent("Resources/ModelCatalog.json"))
        let python = root.appendingPathComponent(".venv/bin/python")
        let script = #"""
import json,pathlib,sys,time,signal,os
root=pathlib.Path(__file__).parent
mode=(root/'mode').read_text()
(root/'pid').write_text(str(os.getpid()))
with (root/'calls').open('a') as f:f.write('call\n')
def emit(kind, amount, ready=False):
    value={'type':kind,'models':[{'id':i,'name':'fixture '+i,'ready':ready,'completedBytes':amount,'totalBytes':100,'phase':'ready' if ready else 'downloading'} for i in ('asr','embedding','llm')]}
    data=json.dumps(value,ensure_ascii=False)+'\n'
    # Deliberately split each JSON line across pipe writes.
    sys.stdout.write(data[:17]);sys.stdout.flush();sys.stdout.write(data[17:]);sys.stdout.flush()
if '--status-json' in sys.argv:
    emit('status',0);emit('complete',0);sys.exit(0)
if mode=='malformed':
    print('invalid-json',flush=True);emit('complete',100,True);sys.exit(0)
if mode=='nonzero':
    emit('complete',100,True);sys.exit(9)
if mode in ('cancel','stubborn','quit-stubborn'):
    def cancelled(*_):
        emit('cancelled',20);sys.exit(130)
    signal.signal(signal.SIGTERM,cancelled if mode=='cancel' else signal.SIG_IGN)
    emit('progress',20)
    while True:time.sleep(.02)
emit('progress',20)
time.sleep(.2);emit('progress',50);time.sleep(.2);emit('complete',100,True)
"""#
        try script.write(to: helper, atomically: true, encoding: .utf8)
        let preparation = ModelPreparation(projectRoot: testProject, executable: python, helper: helper)
        try "valid".write(to: modeFile, atomically: true, encoding: .utf8)
        await preparation.check()
        try require(preparation.verificationComplete && !preparation.canUseModels, "An offline missing snapshot cannot enable entry")
        let transfer = Task { await preparation.download() }
        let deadline = Date().addingTimeInterval(3)
        while preparation.completedBytes == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try require(preparation.isDownloading && preparation.progress > 0 && preparation.progress < 1 && !preparation.canUseModels, "Real child pipe progress updates before completion without allowing entry")
        let callsBefore = try String(contentsOf: fixture.appendingPathComponent("calls"), encoding: .utf8)
        await preparation.check(); await preparation.download()
        let callsAfter = try String(contentsOf: fixture.appendingPathComponent("calls"), encoding: .utf8)
        try require(callsAfter == callsBefore, "Busy state prevents duplicate child processes")
        await transfer.value
        try require(preparation.canUseModels && preparation.preparedCount == 3 && preparation.progress == 1, "Only complete protocol and exit zero enable models")
        let removedModel = testProject.appendingPathComponent("models/asr/weights.bin")
        try FileManager.default.removeItem(at: removedModel)
        try require(!preparation.canUseModels, "Moving a required model after check immediately closes the entry gate")
        try Data(repeating: 1, count: 100).write(to: removedModel)
        for mode in ["nonzero", "malformed"] {
            let failed = ModelPreparation(projectRoot: testProject, executable: python, helper: helper)
            try mode.write(to: modeFile, atomically: true, encoding: .utf8)
            await failed.download()
            try require(!failed.canUseModels && failed.preparedCount == 0 && !failed.message.isEmpty, "Failure after complete or malformed pipe never produces optimistic readiness")
        }
        for mode in ["cancel", "stubborn", "quit-stubborn"] {
            let cancelled = ModelPreparation(projectRoot: testProject, executable: python, helper: helper)
            try mode.write(to: modeFile, atomically: true, encoding: .utf8)
            let task = Task { await cancelled.download() }
            let deadline = Date().addingTimeInterval(3)
            while cancelled.completedBytes == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try require(cancelled.isDownloading && cancelled.progress > 0, "Cancellation fixture is really in transfer")
            let pidText = try String(contentsOf: fixture.appendingPathComponent("pid"), encoding: .utf8)
            guard let pid = Int32(pidText) else { throw Failure(message: "Missing child PID") }
            let began = Date()
            if mode == "quit-stubborn" { await cancelled.shutdown() } else { cancelled.cancel() }
            let stopDeadline = Date().addingTimeInterval(4)
            while cancelled.isBusy && Date() < stopDeadline { try await Task.sleep(for: .milliseconds(10)) }
            let stoppedWithoutFallback = !cancelled.isBusy
            if !stoppedWithoutFallback { await cancelled.shutdown() }
            await task.value
            try require(stoppedWithoutFallback && !cancelled.isBusy && !cancelled.canUseModels && Date().timeIntervalSince(began) < 5,
                        "Cancel and quit stop even an unresponsive owned child in bounded time")
            errno = 0
            try require(kill(pid, 0) == -1 && errno == ESRCH, "Owned downloader process has been reaped")
        }
        let missing = ModelPreparation(projectRoot: root, executable: fixture.appendingPathComponent("absent-python"), helper: helper)
        await missing.check()
        try require(!missing.canUseModels && !missing.isBusy && !missing.message.isEmpty, "Missing runtime retains a useful retry state")
        let real = ModelPreparation(projectRoot: root)
        await real.check()
        try require(real.canUseModels && real.preparedCount == 3 && real.totalBytes == 2_614_496_485, "Genuine production installer verifies all present models through the native process path")
        print("PASS native model preparation: real pipe streaming, split JSON, busy gate, failure after complete, malformed protocol, cancel/quit cleanup, missing runtime, actual production offline status")
    }
}
