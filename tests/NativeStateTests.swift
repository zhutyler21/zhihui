import Foundation

@main
struct NativeStateTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw APIError(message: message) }
    }
    @MainActor static func main() async {
        do {
            try queueRegression(); try spoolRegression(); try selectionRegression()
            try await delayedCancellationRegression()
            try await delayedMeetingEditingRegression()
            try await staleRefreshSavedDraftRegression()
            try await blockedCompletionRegression()
            try await projectionOwnershipRegression()
            try await translationSettingsPollingRegression()
            try NativeSelfTest.run()
            print("PASS native state: recording/import clocks, unknown-duration order, restart, owned spool, delayed HTTP cancellation, actual AppModel delayed selection/edit lock/save failure/latest response, system gap and mixed audio")
        } catch { fputs("FAIL \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func queueRegression() throws {
        var queue = AudioQueueState()
        for index in 0..<3 { queue.appendRecording(PendingTranscription(id:"r\(index)",meetingID:"A",path:"record\(index).wav",startSeconds:Double(index*10),durationSeconds:10)) }
        try queue.complete("r0",actualDuration:10)
        queue.enqueueImports(meetingID:"A",paths:["import1.aiff","import2.aiff","import3.aiff"],savedEnd:10)
        queue.enqueueImports(meetingID:"B",paths:["other.aiff"],savedEnd:5)
        let imports = queue.pending.filter { $0.meetingID == "A" && $0.durationSeconds == 0 }
        try require(imports.count == 3 && imports[0].startSeconds == 30,"导入与待转写10–30秒录音重叠")
        try queue.complete("r1",actualDuration:10); try queue.complete("r2",actualDuration:10)
        try queue.complete(imports[0].id,actualDuration:7.5)
        try require(queue.pending.first { $0.id == imports[1].id }?.startSeconds == 37.5,"未知时长第二音频没有依序推进")
        try require(queue.pending.first { $0.meetingID == "B" }?.startSeconds == 5,"A完成后污染B时间线")
        let beforeInvalid = queue.snapshot
        do { try queue.complete(imports[1].id,actualDuration:-4); throw APIError(message:"负时长竟然完成") }
        catch let error as APIError { if error.message == "负时长竟然完成" { throw error } }
        try require(queue.pending.count == beforeInvalid.items.count,"负时长使原队列丢失")
        queue.markError(imports[1].id,message:"临时失败"); queue.retry()
        try require(queue.pending.first { $0.id == imports[1].id }?.error == nil,"重试没有维护实际队列")
        try queue.complete(imports[1].id,actualDuration:4)
        try require(queue.pending.first { $0.id == imports[2].id }?.startSeconds == 41.5,"第三个音频没有跟随第二个时长")
        try queue.complete(imports[2].id,actualDuration:2)
        queue.appendRecording(PendingTranscription(id:"tail",meetingID:"A",path:"tail.wav",startSeconds:43.5,durationSeconds:1.25))
        try queue.complete("tail",actualDuration:1.25)
        let bytes = try JSONEncoder().encode(queue.snapshot)
        var restarted = AudioQueueState(snapshot:try JSONDecoder().decode(AudioQueueSnapshot.self,from:bytes))
        try require(restarted.baseOffset(meetingID:"A",savedEnd:10) == 44.75,"重启丢失已完成尾块/未知文件的真实时长")
        restarted.enqueueImports(meetingID:"A",paths:["after-restart.wav"],savedEnd:10)
        try require(restarted.pending.last?.startSeconds == 44.75,"重启后导入回退到旧detail时间")
        let legacy = AudioQueueState(snapshot:AudioQueueSnapshot(items:[PendingTranscription(id:"negative",meetingID:"C",path:"x",startSeconds:-3,durationSeconds:-2)],knownEnds:[:]))
        try require(legacy.pending[0].startSeconds == 0 && legacy.pending[0].durationSeconds == 0,"旧队列负时长没有按未知时长恢复")
        var bilingual = AudioQueueState()
        bilingual.enqueueImports(meetingID: "synthetic-translation", paths: ["synthetic.wav"], savedEnd: 0, sourceLanguage: "ja", translationTarget: "zh")
        let restored = AudioQueueState(snapshot: try JSONDecoder().decode(AudioQueueSnapshot.self, from: JSONEncoder().encode(bilingual.snapshot)))
        try require(restored.pending.first?.sourceLanguage == "ja" && restored.pending.first?.translationTarget == "zh", "重启后语言设置丢失或跟随了错误会议")
        bilingual.enqueueImports(meetingID: "multi", paths: ["multi.wav"], savedEnd: 0, sourceLanguage: "yue", translationTargets: ["en", "ja", "ko"])
        let multi = AudioQueueState(snapshot: try JSONDecoder().decode(AudioQueueSnapshot.self, from: JSONEncoder().encode(bilingual.snapshot)))
        try require(multi.pending.last?.translationTargets == ["en", "ja", "ko"], "多语种录音队列重启后丢失目标语言")
        try require(TranslationSettings(["target_language":"ja"]).targetLanguages == ["ja"], "旧版单语种设置未兼容")
    }
    static func spoolRegression() throws {
        let root = URL(fileURLWithPath:ProcessInfo.processInfo.environment["ZHIHUI_NATIVE_TEST_ROOT"]!,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let original=root.appendingPathComponent("original.aiff"), payload=Data("owned audio bytes".utf8)
        try payload.write(to:original,options:.atomic)
        let saved=AudioImportSpool.copy([original,root.appendingPathComponent("missing.aiff")],into:root)
        try require(saved.copiedPaths.count == 1 && saved.errors.count == 1,"独立复制失败回滚了成功文件")
        let moved=root.appendingPathComponent(UUID().uuidString+"-moved.aiff")
        try FileManager.default.moveItem(at:original,to:moved)
        let path=saved.copiedPaths[0]
        let savedBytes=try Data(contentsOf:URL(fileURLWithPath:path))
        try require(savedBytes == payload,"用户移动原文件后spool丢失")
        try require(path.hasPrefix(root.path+"/recordings/imports/"),"音频副本不在自己的资料目录")
        let attrs=try FileManager.default.attributesOfItem(atPath:path), folder=try FileManager.default.attributesOfItem(atPath:URL(fileURLWithPath:path).deletingLastPathComponent().path)
        try require((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600 && (folder[.posixPermissions] as? NSNumber)?.intValue == 0o700,"音频副本权限不安全")
    }
    static func selectionRegression() throws {
        var selection=MeetingSelectionState()
        let a=selection.begin("A"), b=selection.begin("B")
        try require(!selection.isCurrent(a,id:"A") && selection.isCurrent(b,id:"B"),"A旧响应可污染B")
        selection.invalidate(); try require(!selection.isCurrent(b,id:"B"),"回收后旧响应仍可回填")
    }
    @MainActor static func delayedCancellationRegression() async throws {
        let port=Int(CommandLine.arguments[1])!, client=APIClient(port:port,token:"native-fixture-token")
        var session=AskSessionState(); let first=session.begin()
        let responseTask=Task { try await client.call("/api/ask",method:"POST",body:["question":"延迟请求"]) }
        try await Task.sleep(nanoseconds:30_000_000)
        try require(session.cancel() == nil && !session.active,"创建job之前停止没有立即生效")
        let second=session.begin() // A fresh request must not be reset by the old response.
        let late=try await responseTask.value, lateID=late["job_id"] as! String
        try require(!session.accept(jobID:lateID,ticket:first),"迟到job被接受到新对话")
        _=try await client.call("/api/jobs/\(lateID)/cancel",method:"POST")
        try require(session.isCurrent(second),"旧响应取消污染了新对话")
        try require(session.accept(jobID:"active-current",ticket:second),"新请求无法正常接收job")
        let active=session.cancel(); try require(active == "active-current" && !session.active,"已知job没有立即取消")
        _=try await client.call("/api/jobs/\(active!)/cancel",method:"POST")
        let status=try await client.call("/api/test/status"), cancelled=status["cancelled"] as! [String]
        try require(cancelled.contains(lateID) && cancelled.contains("active-current"),"真实HTTP客户端没有取消迟到及运行中的job")
    }
    @MainActor static func delayedMeetingEditingRegression() async throws {
        let client=APIClient(port:Int(CommandLine.arguments[1])!,token:"native-fixture-token")
        let model=AppModel(client:client)
        await model.selectMeeting("old")
        try require(model.updateNoteDraft("old unsaved"),"正常笔记编辑被拒绝")
        let opening=Task { await model.selectMeeting("A") }
        try await Task.sleep(nanoseconds:40_000_000)
        try require(model.isSwitchingMeeting,"第一await期间没有锁定编辑")
        try require(!model.updateNoteDraft("late edit must never replace old unsaved"),"GET期间仍可修改旧笔记导致丢失")
        try require(model.noteDraft == "old unsaved","锁定期间修改了真实笔记草稿")
        await opening.value
        try require(model.selectedMeetingID == "A" && model.noteDraft == "A saved" && !model.isSwitchingMeeting,"新会议读取或解锁失败")
        let status=try await client.call("/api/test/status")
        try require((status["saved_notes"] as? JSONObject)?["old"] as? String == "old unsaved","切换前未保存旧笔记")
        await model.selectMeeting("old"); model.updateNoteDraft("FAILSAVE")
        await model.selectMeeting("A")
        try require(model.selectedMeetingID == "old" && model.noteDraft == "FAILSAVE" && model.noteDirty && !model.isSwitchingMeeting,"保存失败丢弃旧笔记或仍锁定界面")
        let other=AppModel(client:client); await other.selectMeeting("old")
        let lateA=Task { await other.selectMeeting("A") }
        try await Task.sleep(nanoseconds:40_000_000)
        let latestB=Task { await other.selectMeeting("B") }; await latestB.value
        try require(other.selectedMeetingID == "B" && !other.isSwitchingMeeting,"最新B完成后仍被旧A锁定")
        await lateA.value
        try require(other.selectedMeetingID == "B" && other.noteDraft == "B saved" && other.trashSegments.first?.id == "B-trash" && !other.isSwitchingMeeting,"旧A响应覆盖B笔记/回收站/解锁状态")
    }
    @MainActor static func staleRefreshSavedDraftRegression() async throws {
        let client=APIClient(port:Int(CommandLine.arguments[1])!,token:"native-fixture-token"), model=AppModel(client:APIClient(port:Int(CommandLine.arguments[1])!,token:"native-fixture-token"))
        await model.selectMeeting("A")
        let refreshing=Task { try await model.refreshDetail("A") }
        try await Task.sleep(nanoseconds:300_000_000)
        let newest="saved while refresh awaited trash"
        try require(model.updateNoteDraft(newest),"刷新期间笔记编辑意外被拒绝")
        try await model.saveNotesIfNeeded()
        try require(!model.noteDirty,"最新笔记未成功保存")
        try await refreshing.value
        let stored=try await client.call("/api/test/status")
        try require((stored["saved_notes"] as? JSONObject)?["A"] as? String == newest,"fixture后台没有持久新笔记")
        try require(model.noteDraft == newest && model.detail?.note == newest && !model.noteDirty,"陈旧刷新覆盖了已经保存的最新笔记草稿/详情")
    }
    @MainActor static func blockedCompletionRegression() async throws {
        var failed = PendingTranscription(id:"blocked-B",meetingID:"B",path:"synthetic-B.wav",startSeconds:0,durationSeconds:6)
        failed.error = "synthetic ASR failure"
        let waiting = PendingTranscription(id:"waiting-A",meetingID:"A",path:"synthetic-A.wav",startSeconds:0,durationSeconds:6)
        let client = APIClient(port:Int(CommandLine.arguments[1])!,token:"native-fixture-token")
        let model = AppModel(client:client, audioSnapshot:AudioQueueSnapshot(items:[failed,waiting],knownEnds:[:]))
        let finishing = Task { await model.finishAndSummarize("A") }
        try await Task.sleep(for:.milliseconds(650))
        finishing.cancel(); await finishing.value
        try require(model.alert?.title == "还有原文未完成", "其他会议失败的队首任务让完成纪要一直等待")
        try require(model.pending.count == 2 && model.finishingMeetings.isEmpty, "失败提示丢失原音频或留下整理锁")
    }
    @MainActor static func projectionOwnershipRegression() async throws {
        let client = APIClient(port:Int(CommandLine.arguments[1])!,token:"native-fixture-token")
        let screen = ProjectionSession(); screen.bind("A")
        let old = Task { await screen.refresh(client:client) }
        try await Task.sleep(for:.milliseconds(40)); screen.bind("B")
        await screen.refresh(client:client); await old.value
        try require(screen.meeting?.id == "B", "大屏被旧会议的迟到响应覆盖")
        screen.bind("A")
        let pause = Task { await screen.refresh(client:client) }
        try await Task.sleep(for:.milliseconds(40)); screen.setPaused(true); await pause.value
        try require(screen.meeting == nil, "暂停后仍显示了在途新内容")
        screen.setPaused(false); await screen.refresh(client:client)
        try require(screen.meeting?.id == "A", "大屏继续显示后无法恢复刷新")
        screen.bind("deleted"); await screen.refresh(client:client)
        try require(screen.meeting == nil && screen.message.contains("回收站"), "已删除会议仍在投屏")
    }
    @MainActor static func translationSettingsPollingRegression() async throws {
        let client = APIClient(port:Int(CommandLine.arguments[1])!, token:"native-fixture-token")
        for id in ["translation-save", "translation-fail"] {
            let model = AppModel(client: client)
            await model.selectMeeting(id)
            try require(model.detail?.id == id && model.detail?.segments.first?.translations.first?.state == "running", "合成翻译会议初始身份或状态不正确")
            let saved = await model.configureTranslation(TranslationSettings(["enabled":true]), meetingID:id)
            try require(saved == (id == "translation-save"), "语言设置成功/失败夹具未生效")
            _ = try await client.call("/api/test/complete-translation", method:"POST", body:["meeting_id":id])
            for _ in 0..<30 {
                if model.detail?.segments.first?.translations.first?.state == "done" { break }
                try await Task.sleep(for:.milliseconds(100))
            }
            try require(model.detail?.segments.first?.translations.first?.state == "done", "保存语言设置\(saved ? "成功" : "失败")后，后台译文完成但原生状态没有继续刷新")
        }
        let switched = AppModel(client: client)
        await switched.selectMeeting("translation-other")
        try require(switched.detail?.id == "translation-other", "切换后合成会议身份不正确")
        _ = await switched.configureTranslation(TranslationSettings(), meetingID:"translation-save")
        _ = try await client.call("/api/test/complete-translation", method:"POST", body:["meeting_id":"translation-other"])
        for _ in 0..<30 {
            if switched.detail?.segments.first?.translations.first?.state == "done" { break }
            try await Task.sleep(for:.milliseconds(100))
        }
        try require(switched.detail?.id == "translation-other" && switched.detail?.segments.first?.translations.first?.state == "done", "保存旧会议设置中断了当前会议的译文刷新")
    }
}
