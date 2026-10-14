import SwiftUI

struct PermissionsView: View {
    @ObservedObject var setup: OnboardingState
    @ObservedObject var models: ModelPreparation
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    BrandMark()
                    Text("准备好，让讨论更清晰").font(Design.Typography.title2)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("准备声音与本地模型").font(Design.Typography.largeTitle)
                    Text("允许声音访问，准备中文模型。完成后，转写、纪要和问答都在这台 Mac 上处理。")
                        .font(Design.Typography.body).foregroundStyle(Design.muted).lineSpacing(7)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Label("声音权限 \(setup.permissions.authorizedCount) / 2", systemImage: "mic.and.signal.meter").monospacedDigit()
                    Spacer()
                    Button("重新检查") { setup.refresh() }.buttonStyle(QuietButton()).disabled(setup.requesting != nil)
                }.font(Design.Typography.callout).foregroundStyle(Design.muted)
                HStack(alignment: .top, spacing: 16) {
                    permissionRow(.microphone, title: "麦克风", icon: "mic", detail: "记录现场发言，也可以和系统声音一起录制在线会议。")
                    permissionRow(.systemAudio, title: "系统声音", icon: "speaker.wave.2", detail: "记录这台 Mac 播放的会议声音。macOS 将其列在“录屏与系统录音”中；知会只保存音频，不保存屏幕图像。")
                }
                ModelPreparationCard(models: models)
                if !setup.message.isEmpty {
                    Label(setup.message, systemImage: "info.circle")
                        .font(Design.Typography.callout).foregroundStyle(Design.muted).lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true).accessibilityLabel(setup.message)
                }
                Divider()
                HStack(alignment: .center, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("会议留在本机", systemImage: "lock.shield").font(Design.Typography.callout.weight(.medium))
                        Text("转写、纪要和问答在这台 Mac 上处理。").font(Design.Typography.caption).foregroundStyle(Design.muted)
                    }
                    Spacer(minLength: 12)
                    Button { Task { await models.check(); setup.finish() } } label: { Label("进入知会", systemImage: "arrow.right") }
                        .buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
                        .disabled(!setup.canEnterMain).help("声音权限与三个本地模型均准备完成后进入主界面")
                }
            }
            .padding(36).frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Design.canvas).tint(Design.accent)
        .navigationTitle("知会 · 权限设置")
    }
    private func permissionRow(_ permission: SetupPermission, title: String, icon: String, detail: String) -> some View {
        let status = setup.permissions[permission]
        let allowed = status.isAuthorized
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 20, weight: .medium)).foregroundStyle(Design.accent)
                    .frame(width: 38, height: 38).background(Design.soft, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                Text(title).font(Design.Typography.headline)
                Spacer(minLength: 4)
                Label(allowed ? "已允许" : (status == .restricted ? "系统限制" : "待设置"),
                      systemImage: allowed ? "checkmark.circle.fill" : "circle")
                    .font(Design.Typography.caption.weight(.medium))
                    .foregroundStyle(allowed ? Design.success : Design.muted)
                    .accessibilityLabel("\(title)：\(allowed ? "已允许" : "尚未允许")")
            }
            VStack(alignment: .leading, spacing: 9) {
                Text(detail).font(Design.Typography.caption).foregroundStyle(Design.muted).lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                if !allowed {
                    HStack(spacing: 12) {
                        Button {
                            Task { await setup.request(permission) }
                        } label: {
                            if setup.requesting == permission { Label("等待系统确认", systemImage: "hourglass") }
                            else { Text(status == .restricted ? "受系统策略限制" : "允许\(title)") }
                        }.buttonStyle(QuietButton()).disabled(setup.requesting != nil || status == .restricted)
                        Button("打开系统设置") { setup.openSettings(permission) }
                            .buttonStyle(.borderless).font(Design.Typography.callout)
                            .disabled(setup.requesting != nil)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Design.line, lineWidth: 1) }
    }
}

struct ModelPreparationCard: View {
    @ObservedObject var models: ModelPreparation
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("本地中文模型", systemImage: "internaldrive").font(Design.Typography.headline)
                Spacer()
                Text("\(models.preparedCount) / 3 已准备").font(Design.Typography.caption.weight(.medium))
                    .foregroundStyle(models.canUseModels ? Design.success : Design.muted).monospacedDigit()
            }
            Text("只需下载一次。已有文件会检查后继续使用，会议内容不会上传。")
                .font(Design.Typography.caption).foregroundStyle(Design.muted)
            ForEach(models.models) { model in
                HStack(spacing: 12) {
                    Image(systemName: model.symbol).foregroundStyle(Design.accent).frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.purpose).font(Design.Typography.callout.weight(.medium))
                        Text(model.name).font(Design.Typography.caption).foregroundStyle(Design.muted).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    if model.ready {
                        Label("已准备", systemImage: "checkmark.circle.fill").foregroundStyle(Design.success)
                    } else {
                        Text(models.isBusy && model.phase == "checking" ? "正在检查" :
                             models.isDownloading && model.phase == "downloading" ? "正在下载" :
                             model.completedBytes > 0 ? "待继续" : "待下载")
                            .foregroundStyle(Design.muted)
                    }
                }.font(Design.Typography.caption)
            }
            if models.isDownloading {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: models.progress).tint(Design.accentFill)
                        .accessibilityLabel("模型准备进度")
                        .accessibilityValue("\(Int(models.progress * 100))%")
                    HStack {
                        Text(models.isCancelling ? "正在暂停…" : (models.activeModel?.name ?? "正在准备模型"))
                        Spacer()
                        Text("\(modelByteText(models.completedBytes)) / \(modelByteText(models.totalBytes))").monospacedDigit()
                    }.font(Design.Typography.caption).foregroundStyle(Design.muted)
                }
            }
            if !models.message.isEmpty {
                Text(models.message).font(Design.Typography.caption).foregroundStyle(Design.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                if models.isDownloading {
                    Button("暂停下载") { models.cancel() }.buttonStyle(QuietButton()).disabled(models.isCancelling)
                } else {
                    Button { Task { await models.download() } } label: {
                        Label(models.canUseModels ? "模型已就绪" : models.completedBytes > 0 ? "继续下载" : "下载所需模型", systemImage: models.canUseModels ? "checkmark" : "arrow.down.circle")
                    }.buttonStyle(QuietButton()).disabled(models.isBusy || models.canUseModels)
                    Button { Task { await models.check() } } label: {
                        if models.isChecking { Label("正在检查", systemImage: "hourglass") }
                        else { Text("重新检查模型") }
                    }.buttonStyle(.borderless).font(Design.Typography.callout).disabled(models.isBusy)
                }
                Spacer()
                if !models.canUseModels && !models.isBusy && models.missingBytes > 0 {
                    Text("还需约 \(modelByteText(models.missingBytes))").font(Design.Typography.caption).foregroundStyle(Design.muted)
                }
            }
        }
        .padding(22).background(Design.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Design.line, lineWidth: 1) }
    }
}
