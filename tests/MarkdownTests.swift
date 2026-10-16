import Foundation

private func require(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

@main
struct MarkdownTests {
    @MainActor static func main() async throws {
        let raw = "# 中文标题\n\n正文 **加粗** 与 `inline`。\n软换行\n硬换行  \n下一行。\n\n```swift\nlet text = \"# 不应变标题\"\n\n\tprint(text)\n```\n"
        let doc = MarkdownDocument(source: raw)
        require(doc.source == raw, "Markdown source must remain byte-for-byte unchanged")
        require(doc.blocks.contains { if case .heading(let level, _) = $0.kind { return level == 1 }; return false }, "heading")
        let code = doc.blocks.compactMap { block -> MarkdownCode? in if case .code(let value) = block.kind { return value }; return nil }.first!
        require(code.text == "let text = \"# 不应变标题\"\n\n\tprint(text)\n", "fenced code and blank lines must stay verbatim")
        require(code.language == "swift" && code.closed, "fence metadata")
        let paragraph = doc.blocks.compactMap { block -> MarkdownInline? in if case .paragraph(let value) = block.kind { return value }; return nil }.first!
        require(String(paragraph.attributed.characters).contains("。 软换行 硬换行\n下一行。"), "soft and hard lines")
        require(paragraph.attributed.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }, "native inline strong")
        require(paragraph.attributed.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true }, "native inline code")
        require(MarkdownDocument(source: raw).blocks.map(\.id) == doc.blocks.map(\.id), "stable deterministic block ids")
        let withoutEnding = MarkdownDocument(source: "# 标题\n\n同位置的不同文字")
        let withEnding = MarkdownDocument(source: "# 标题\n\n同位置的新文字更长，仍是同一段")
        require(withoutEnding.blocks.map(\.id) == withEnding.blocks.map(\.id), "block identity uses source start span rather than mutable content length")
        let unicode = "👩🏽‍💻 中文 e\u{301}\n\n# 后续标题\n"
        let unicodeDoc = MarkdownDocument(source: unicode)
        let originalNS = unicode as NSString
        for block in unicodeDoc.blocks {
            let slice = originalNS.substring(with: NSRange(location: block.span.startUTF16, length: block.span.endUTF16 - block.span.startUTF16))
            require(!slice.isEmpty, "UTF16 span handles CJK, emoji and combined characters")
        }

        let unclosed = MarkdownDocument(source: "~~~~python\n## literal\n```\n最后一行")
        guard case .code(let unfinished) = unclosed.blocks.first!.kind else { fatalError("unclosed fence") }
        require(!unfinished.closed && unfinished.text == "## literal\n```\n最后一行", "malformed fence content preserved")
        let crlf = MarkdownDocument(source: "```\r\na\r\n\r\nb\r\n```\r\n")
        guard case .code(let crlfCode) = crlf.blocks.first!.kind else { fatalError("CRLF fence") }
        require(crlfCode.text == "a\r\n\r\nb\r\n", "code CRLF preserved")
        let tabFence = MarkdownDocument(source: "```\n\t```\nactual code\n```\n")
        guard case .code(let tabCode) = tabFence.blocks.first!.kind else { fatalError("tab fence") }
        require(tabCode.text == "\t```\nactual code\n", "indented tab fence must not close outer code")

        let escaped = MarkdownDocument(source: "\\# 普通文字\n\n\\- 不应成为列表\n\n###### 六级\n####### 仍是普通文字")
        require(escaped.blocks.filter { if case .heading = $0.kind { return true }; return false }.count == 1, "escaped syntax and heading boundaries")
        let list = MarkdownDocument(source: "- [ ] 待办 **甲**\n- [x] 已完成\n1. 有序第一项\n2. 第二项\n  续写中文\n")
        guard case .list(let items) = list.blocks.first!.kind else { fatalError("list") }
        require(items.count == 4 && items[0].checked == false && items[1].checked == true, "task list")
        require(items[2].ordinal == 1 && items[3].ordinal == 2, "ordered markers")
        require(items[3].text.source.contains("续写中文"), "list continuation")

        let table = MarkdownDocument(source: "| 名称 | 金额 |\n| :--- | ---: |\n| 中文 \\| 合作 | `3|4` |\n\n# 表格之后\n")
        guard case .table(let parsed) = table.blocks.first!.kind else { fatalError("table") }
        require(parsed.header.cells.count == 2 && parsed.rows.count == 1, "table rows")
        require(parsed.rows[0].cells[0].text.source.contains("\\|"), "escaped pipe cell boundary")
        require(parsed.rows[0].cells[1].text.source == "`3|4`", "inline code pipe cell boundary")
        require(parsed.alignments == [.leading, .trailing], "table alignment")
        require(table.blocks.contains { if case .heading = $0.kind { return true }; return false }, "table ends at blank boundary")
        let invalid = MarkdownDocument(source: "甲 | 乙\n--- | --\n正文")
        require(!invalid.blocks.contains { if case .table = $0.kind { return true }; return false }, "malformed delimiter stays ordinary text")
        let wide = MarkdownDocument(source: "| 一 | 二 | 三 | 四 | 五 | 六 | 七 | 八 |\n| --- | --- | --- | --- | --- | --- | --- | --- |\n| 中文 | 中 | 中 | 中 | 中 | 中 | 中 | `很长的代码值` |\n文字结束")
        guard case .table(let wideTable) = wide.blocks.first!.kind else { fatalError("wide table") }
        require(wideTable.header.cells.count == 8 && wideTable.rows[0].cells.count == 8, "wide table retains all columns for adaptive renderer")
        require(wide.blocks.last?.kind == .paragraph(MarkdownInline(source: "文字结束")), "table does not consume following paragraph")

        let mixed = MarkdownDocument(source: "> 中文引用\n> - 引用列表\n\n---\n\n[安全链接](https://example.com) [危险链接](javascript:alert) ![图片](https://example.com/p.png)")
        require(mixed.blocks.contains { if case .quote = $0.kind { return true }; return false }, "quote")
        require(mixed.blocks.contains { if case .divider = $0.kind { return true }; return false }, "divider")
        let inline = MarkdownInline(source: "[安全](https://example.com) [危险](javascript:alert)")
        require(inline.attributed.runs.filter { $0.link != nil }.count == 1, "only ordinary web/mail link schemes retained")
        let styled = MarkdownInline(source: "*斜体* ~~删除~~ `代码` \\*字面星号\\*")
        require(styled.attributed.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true }, "inline italic")
        require(styled.attributed.runs.contains { $0.inlinePresentationIntent?.contains(.strikethrough) == true }, "inline strike")
        require(String(styled.attributed.characters).contains("*字面星号*"), "escaped inline syntax stays literal")
        require(MarkdownDocument(source: String(repeating: ">", count: 2000) + "安全深层引用").source.hasSuffix("安全深层引用"), "pathological quote nesting stays bounded without losing original source")

        var session = MarkdownNoteSession(meetingID: "synthetic-A")
        require(session.mode == .preview, "notes initially preview")
        session.beginEditing()
        let failed = session.beginSaving(draft: "# 草稿", currentMeetingID: "synthetic-A", switching: false)!
        require(!session.finishSaving(failed, succeeded: false, currentMeetingID: "synthetic-A", currentDraft: "# 草稿", dirty: true, switching: false), "failed Done stays editing")
        require(session.mode == .editing && !session.saving, "failure edit state")
        let late = session.beginSaving(draft: "# 草稿", currentMeetingID: "synthetic-A", switching: false)!
        require(!session.finishSaving(late, succeeded: true, currentMeetingID: "synthetic-B", currentDraft: "# B", dirty: false, switching: false), "A late Done must not affect B")
        let changed = session.beginSaving(draft: "旧文本", currentMeetingID: "synthetic-A", switching: false)!
        require(!session.finishSaving(changed, succeeded: true, currentMeetingID: "synthetic-A", currentDraft: "新文本", dirty: false, switching: false), "new edit cannot become preview after old completion")
        let dirty = session.beginSaving(draft: "新文本", currentMeetingID: "synthetic-A", switching: false)!
        require(!session.finishSaving(dirty, succeeded: true, currentMeetingID: "synthetic-A", currentDraft: "新文本", dirty: true, switching: false), "success return with dirty flag remains editor")
        let saved = session.beginSaving(draft: "新文本", currentMeetingID: "synthetic-A", switching: false)!
        require(session.finishSaving(saved, succeeded: true, currentMeetingID: "synthetic-A", currentDraft: "新文本", dirty: false, switching: false), "saved same draft becomes preview")
        require(session.mode == .preview, "successful Done preview")
        session.beginEditing()
        let blurred = session.beginSaving(draft: "原文", currentMeetingID: "synthetic-A", switching: false)!
        session.beginEditing()
        require(!session.saving && session.mode == .editing, "refocusing while autosave waits restores editable source")
        require(!session.finishSaving(blurred, succeeded: true, currentMeetingID: "synthetic-A", currentDraft: "原文", dirty: false, switching: false), "old blur completion cannot steal a resumed editor even when its text is unchanged")
        let nextBlur = session.beginSaving(draft: "新原文", currentMeetingID: "synthetic-A", switching: false)!
        require(session.pendingPreview == nextBlur, "automatic preview keeps meeting-owned draft ticket")
        require(session.finishSaving(nextBlur, succeeded: true, currentMeetingID: "synthetic-A", currentDraft: "新原文", dirty: false, switching: false), "new blur renders only the latest saved source")
        session.beginEditing()
        require(session.beginSaving(draft: "x", currentMeetingID: "synthetic-A", switching: true) == nil, "switching disables Done")
#if MARKDOWN_APP_MODEL_TESTS
        try await actualModelNotesRegression()
#endif
        print("PASS: Markdown parsing, inline formatting, source preservation, spans, and actual notes session completion guards")
    }

#if MARKDOWN_APP_MODEL_TESTS
    @MainActor static func actualModelNotesRegression() async throws {
        let port = Int(CommandLine.arguments[1])!
        let client = APIClient(port: port, token: "native-fixture-token")
        let model = AppModel(client: client)
        await model.selectMeeting("old")
        var state = MarkdownNoteSession(meetingID: "old")
        state.beginEditing()
        let original = "# 中文保存测试\n\n**加粗** 和 `代码`\n\n- [ ] 原文待办\n"
        require(model.updateNoteDraft(original), "real AppModel source-edit binding")
        let ticket = state.beginSaving(draft: model.noteDraft, currentMeetingID: model.selectedMeetingID, switching: model.isSwitchingMeeting)!
        try await model.saveNotesIfNeeded()
        require(state.finishSaving(ticket, succeeded: true, currentMeetingID: model.selectedMeetingID, currentDraft: model.noteDraft, dirty: model.noteDirty, switching: model.isSwitchingMeeting), "actual HTTP save must enable preview")
        let stored = try await client.call("/api/test/status")
        require((stored["saved_notes"] as? JSONObject)?["old"] as? String == original, "actual HTTP stored Markdown remains exact source")

        state.beginEditing(); require(model.updateNoteDraft("FAILSAVE"), "real failed-save draft")
        let failed = state.beginSaving(draft: model.noteDraft, currentMeetingID: model.selectedMeetingID, switching: model.isSwitchingMeeting)!
        var threw = false
        do { try await model.saveNotesIfNeeded() }
        catch {
            threw = true
            state.finishSaving(failed, succeeded: false, currentMeetingID: model.selectedMeetingID, currentDraft: model.noteDraft, dirty: model.noteDirty, switching: model.isSwitchingMeeting)
            model.showError(error, title: "笔记尚未保存")
        }
        require(threw && model.noteDraft == "FAILSAVE" && model.noteDirty && state.mode == .editing && !state.saving, "actual HTTP failure preserves source and editor")
        require(model.alert?.title == "笔记尚未保存", "actual failure is visible")
        require(!model.noteSaveErrorMessage.isEmpty, "save failure remains observable when editor views are recreated")
        require(model.updateNoteDraft(original), "failed draft can be restored to its saved Markdown source")
        let deadline = Date().addingTimeInterval(4)
        while model.noteDirty && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        require(!model.noteDirty && model.noteSaveErrorMessage.isEmpty, "existing debounce saves restored source after failure, so automatic preview cannot wait forever")
        let restored = try await client.call("/api/test/status")
        require((restored["saved_notes"] as? JSONObject)?["old"] as? String == original, "restored source persisted exactly through automatic retry")
        require(model.updateNoteDraft("# 恢复后的笔记"), "retry keeps Markdown editable")
        try await model.saveNotesIfNeeded()
        require(model.noteSaveErrorMessage.isEmpty && !model.noteDirty, "successful retry clears persistent failure state")

        let other = AppModel(client: client)
        await other.selectMeeting("A")
        var pending = MarkdownNoteSession(meetingID: "A"); pending.beginEditing()
        require(other.updateNoteDraft("# A 的笔记"), "A source edit")
        let late = pending.beginSaving(draft: other.noteDraft, currentMeetingID: other.selectedMeetingID, switching: other.isSwitchingMeeting)!
        try await other.saveNotesIfNeeded()
        await other.selectMeeting("B")
        let bDraft = other.noteDraft
        require(!pending.finishSaving(late, succeeded: true, currentMeetingID: other.selectedMeetingID, currentDraft: other.noteDraft, dirty: other.noteDirty, switching: other.isSwitchingMeeting), "late A completion after actual B load remains isolated")
        require(other.selectedMeetingID == "B" && other.noteDraft == bDraft, "late completion cannot touch B draft")
        print("PASS: actual AppModel and authenticated loopback HTTP Markdown save, rejected save preserves editor/draft, meeting-owned late completion")
    }
#endif
}
