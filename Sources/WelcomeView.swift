import SwiftUI

/// Presentation only. The owner decides which setup step follows this page.
public struct WelcomeView: View {
    public let onContinue: () -> Void

    public init(onContinue: @escaping () -> Void) { self.onContinue = onContinue }

    public var body: some View {
        ScrollView {
            HStack(alignment: .center, spacing: 40) {
                introduction.frame(minWidth: 340, idealWidth: 380, maxWidth: 430, alignment: .leading)
                WelcomeGlass().frame(minWidth: 440, maxWidth: .infinity)
            }
            .frame(maxWidth: 1180)
            .padding(.horizontal, 48).padding(.vertical, 40)
            .frame(maxWidth: .infinity, minHeight: 620)
        }
        .background(Design.canvas)
        .font(Design.Typography.body)
        .tint(Design.accent)
        .frame(minWidth: 980, minHeight: 640)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 12) {
                BrandMark()
                VStack(alignment: .leading, spacing: 3) {
                    Text("知会").font(Design.Typography.title2)
                    Text("你的本地会议助手").font(Design.Typography.callout).foregroundStyle(Design.muted)
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                Text("留住讨论，\n看清下一步。")
                    .font(.system(size: 42, weight: .semibold, design: .rounded))
                    .foregroundStyle(Design.ink).lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("把声音、笔记和资料连在一起。\n整理中文纪要，也能从会议原文中寻找答案。")
                    .font(Design.Typography.body).lineSpacing(7).foregroundStyle(Design.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 20) {
                WelcomeFeature(symbol: "waveform", title: "专心讨论，中文记录", detail: "现场声音和在线会议，都有清晰的转写。")
                WelcomeFeature(symbol: "doc.text", title: "资料跟着会议走", detail: "笔记、附件和行动项，放在同一场会议里。")
                WelcomeFeature(symbol: "text.bubble", title: "问到答案，查得到出处", detail: "围绕会议与知识库提问，随时回看引用原文。")
            }
            VStack(alignment: .leading, spacing: 12) {
                Button(action: onContinue) {
                    HStack(spacing: 10) { Text("开始设置"); Image(systemName: "arrow.right") }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                }
                .buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
                .accessibilityLabel("开始设置知会")
                Text("声音权限与本地模型准备完成后，就可以开始使用。")
                    .font(Design.Typography.caption).foregroundStyle(Design.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label("会议与资料留在这台 Mac 上", systemImage: "internaldrive")
                .font(Design.Typography.caption).foregroundStyle(Design.teal)
        }
    }
}

private struct WelcomeFeature: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 21, weight: .medium))
                .foregroundStyle(Design.accent).frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(Design.Typography.headline).foregroundStyle(Design.ink)
                Text(detail).font(Design.Typography.callout).foregroundStyle(Design.muted)
                    .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
