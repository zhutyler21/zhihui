import SwiftUI

struct SegmentEditor: View {
    let segment: Segment; @ObservedObject var model: AppModel; var done: () -> Void
    @State private var draft: String; @State private var saving = false; @State private var message = ""
    init(segment: Segment, model: AppModel, done: @escaping () -> Void) {
        self.segment = segment; self.model = model; self.done = done; _draft = State(initialValue: segment.text)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("校对转写").font(Design.Typography.title2)
            Text("可以修正人名、术语或识别错误。录音和时间保持不变，原纪要会等待重新整理。").font(Design.Typography.callout).foregroundStyle(Design.muted).lineSpacing(6)
            Text("\(timeText(segment.start)) – \(timeText(segment.end))").font(Design.Typography.caption).monospacedDigit().foregroundStyle(Design.muted)
            TextEditor(text: $draft).font(Design.Typography.body).lineSpacing(7).padding(16).scrollContentBackground(.hidden).background(Design.soft, in: RoundedRectangle(cornerRadius: 14)).accessibilityLabel("校对转写文字")
            if !message.isEmpty { Text(message).font(Design.Typography.caption).foregroundStyle(.orange) }
            HStack { Spacer(); Button("取消") { done() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction).disabled(saving); Button(saving ? "正在保存" : "保存校对") { Task { saving = true; do { try await model.editSegment(segment, text: draft); done() } catch { message = error.localizedDescription; saving = false } } }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction).disabled(saving || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(26).frame(width: 700, height: 530).background(Design.surface).tint(Design.accent).interactiveDismissDisabled(saving)
    }
}
