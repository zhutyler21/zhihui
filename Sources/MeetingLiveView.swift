import SwiftUI

/// The live workspace owns controls; meeting materials remain a separate destination.
struct MeetingLiveView: View {
    @ObservedObject var model: AppModel
    let meeting: Meeting
    let returnToMaterials: () -> Void
    let showLanguages: () -> Void
    let openDisplay: () -> Void
    private var recordingThisMeeting: Bool { model.recording && model.recordingMeetingID == meeting.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                Button("返回会议资料", systemImage: "chevron.left") { returnToMaterials() }
                    .buttonStyle(.borderless).font(Design.Typography.callout)
                VStack(alignment: .leading, spacing: 7) {
                    Text("实时会场").font(Design.Typography.title2)
                    Text(meeting.title).font(Design.Typography.callout).foregroundStyle(Design.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                recordingButtons
                HStack(spacing: 10) {
                    Image(systemName: recordingThisMeeting ? "record.circle.fill" : "mic")
                        .foregroundStyle(recordingThisMeeting ? Design.recording : Design.muted)
                    Text(recordingThisMeeting ? "正在录音 · \(timeText(model.recordingSeconds))" :
                         model.recording ? "另一场会议正在录音" : "准备就绪，开始录音后逐段保存原文")
                        .monospacedDigit()
                }.font(Design.Typography.caption).foregroundStyle(Design.muted)
                MeetingTranslationControls(model: model, meeting: meeting,
                    showLanguages: showLanguages, openDisplay: openDisplay)
            }.padding(24)
            Divider().padding(.horizontal, 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("最新原文").font(Design.Typography.headline)
                    if let latest = meeting.segments.last {
                        Text(timeText(latest.start)).font(Design.Typography.caption).foregroundStyle(Design.muted)
                        Text(latest.text).font(.system(size: 22)).lineSpacing(8).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("等待讲话内容").font(Design.Typography.title3).foregroundStyle(Design.muted)
                    }
                    Text("大屏独立显示原文与多语译文；完整转写、笔记、纪要和附件请返回会议资料。")
                        .font(Design.Typography.caption).foregroundStyle(Design.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }.frame(maxHeight: .infinity)
        }
    }
    private var recordingButtons: some View { MeetingCaptureActions(model: model, meetingID: meeting.id) }
}
