import SwiftUI

struct ContentView: View {
    @ObservedObject var harness: HarnessService
    @ObservedObject var artifactStore: ArtifactStore
    @ObservedObject var appshotStore: AppshotStore
    @ObservedObject var modelCapabilityStore: ModelCapabilityStore
    @ObservedObject var remoteHostStore: RemoteHostStore
    @StateObject private var attachmentStore = AppAttachmentStore()
    @State private var showsComputerUseSettings = false
    @State private var showsArtifactWorkbench = false
    @State private var showsModelCapabilityCenter = false
    @State private var showsPluginHealthCenter = false
    @State private var showsRemoteServers = false
    @State private var isNativeFileDragActive = false

    var body: some View {
        ZStack {
            Group {
                switch harness.state {
                case .idle, .starting:
                    LaunchingView(message: harness.statusMessage)

                case .ready(let url):
                    HarnessWebView(
                        url: url,
                        reloadToken: harness.reloadToken,
                        nativeAttachmentPayloads: artifactStore.nativeAttachmentPayloads,
                        supportsDirectImageInput: { providerID, modelID in
                            modelCapabilityStore.supportsDirectImageInput(
                                providerID: providerID,
                                modelID: modelID
                            )
                        },
                        currentHostRouteMatches: { providerID, modelID in
                            await harness.currentHostRouteMatches(
                                providerID: providerID,
                                modelID: modelID
                            )
                        },
                        onFileDragStateChanged: { active in
                            isNativeFileDragActive = active
                        },
                        onFileURLsDropped: { urls, sessionID in
                            artifactStore.importDroppedFiles(
                                urls,
                                targetSessionID: sessionID
                            )
                        },
                        onImageDataPasted: { data, fileExtension, sessionID in
                            artifactStore.importPastedImageData(
                                data,
                                fileExtension: fileExtension,
                                targetSessionID: sessionID
                            )
                        },
                        onNativeAttachmentLifecycle: { event in
                            artifactStore.handleNativeAttachmentLifecycle(event)
                        },
                        onFailure: harness.reportWebViewFailure
                    )

                case .failed(let message):
                    FailureView(message: message) {
                        Task { await harness.restart() }
                    }
                }
            }

            if isNativeFileDragActive || artifactStore.isImportingDroppedFiles {
                FileDropOverlay(isImporting: artifactStore.isImportingDroppedFiles)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.16), value: isNativeFileDragActive)
        .animation(.easeOut(duration: 0.16), value: artifactStore.isImportingDroppedFiles)
        .frame(minWidth: 760, minHeight: 520)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button {
                        showsRemoteServers = true
                    } label: {
                        Label("管理远程服务器…", systemImage: "server.rack")
                    }

                    if let selection = remoteHostStore.selection {
                        Divider()

                        Button {
                            remoteHostStore.testSelectedConnection()
                            showsRemoteServers = true
                        } label: {
                            Label("测试 \(selection.alias)", systemImage: "bolt.horizontal.circle")
                        }
                        .disabled(remoteHostStore.isTesting)

                        Button(role: .destructive) {
                            remoteHostStore.detach()
                        } label: {
                            Label("断开 \(selection.alias)", systemImage: "xmark.circle")
                        }
                        .disabled(remoteHostStore.isTesting)
                    }
                } label: {
                    Label(
                        remoteHostStore.selectedAlias.map { "SSH · \($0)" } ?? "远程服务器",
                        systemImage: "server.rack"
                    )
                }
                .help("选择 SSH 服务器与远程工作区")

                Menu {
                    Button {
                        appshotStore.captureAfterSwitchingApplications()
                    } label: {
                        Label("创建 Appshot…", systemImage: "macwindow.badge.plus")
                    }
                    .disabled(appshotStore.isCapturing)

                    Button {
                        artifactStore.refresh()
                        showsArtifactWorkbench = true
                    } label: {
                        Label("打开研究文件库…", systemImage: "tray.full")
                    }

                    Divider()

                    Menu {
                        if attachmentStore.selectedBundleIdentifier != nil {
                            Button {
                                attachmentStore.detach()
                            } label: {
                                Label("停止附加", systemImage: "xmark.circle")
                            }

                            Divider()
                        }

                        ForEach(attachmentStore.applications) { application in
                            Button {
                                attachmentStore.attach(application)
                            } label: {
                                HStack {
                                    Image(nsImage: application.icon)
                                        .accessibilityHidden(true)
                                    Text(applicationMenuTitle(for: application))
                                    if attachmentStore.isSelected(application) {
                                        Image(systemName: "checkmark")
                                            .accessibilityHidden(true)
                                    }
                                }
                            }
                            .accessibilityLabel(
                                attachmentStore.isSelected(application)
                                    ? "\(applicationMenuTitle(for: application))，已附加"
                                    : applicationMenuTitle(for: application)
                            )
                        }

                        Divider()

                        Button {
                            attachmentStore.refresh()
                        } label: {
                            Label("刷新应用列表", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Label("附加运行中的应用", systemImage: "macwindow.and.cursorarrow")
                    }

                    Button {
                        attachmentStore.refreshPermissions()
                        showsComputerUseSettings = true
                    } label: {
                        Label("电脑控制权限…", systemImage: "hand.raised")
                    }
                } label: {
                    Label("上下文与附件",
                        systemImage: attachmentStore.selectedBundleIdentifier == nil
                            ? "paperclip"
                            : "paperclip.circle.fill"
                    )
                }
                .accessibilityValue(
                    attachmentStore.selectedApplicationName.map { "已附加 \($0)" } ?? "未附加应用"
                )
                .accessibilityLabel("上下文与附件")
                .accessibilityHint("文件可直接拖入或粘贴到对话；此菜单用于 Appshot、研究文件库和附加应用")
                .help("文件直接拖入或粘贴到对话；这里管理 Appshot、研究文件库和附加应用")

                if harness.isReady {
                    Button {
                        showsPluginHealthCenter = true
                    } label: {
                        Label("能力", systemImage: "sparkles.rectangle.stack.fill")
                    }
                    .help("查看哪些能力会自动调用、哪些需要先准备或手动启动")

                    Menu {
                        Button {
                            modelCapabilityStore.reload()
                            showsModelCapabilityCenter = true
                        } label: {
                            Label("模型能力中心", systemImage: "switch.2")
                        }

                        Divider()

                        Button {
                            harness.reload()
                        } label: {
                            Label("重新载入界面", systemImage: "arrow.clockwise")
                        }

                        Button {
                            harness.openInBrowser()
                        } label: {
                            Label("在浏览器中打开", systemImage: "safari")
                        }
                    } label: {
                        Label("更多", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showsComputerUseSettings) {
            ComputerUseSettingsView(store: attachmentStore)
        }
        .sheet(isPresented: $showsArtifactWorkbench) {
            ArtifactWorkbenchView(store: artifactStore)
        }
        .sheet(isPresented: $showsModelCapabilityCenter) {
            ModelCapabilityCenterView(store: modelCapabilityStore)
        }
        .sheet(isPresented: $showsPluginHealthCenter) {
            PluginHealthCenterView(harness: harness)
        }
        .sheet(isPresented: $showsRemoteServers) {
            RemoteServersView(store: remoteHostStore)
        }
        .sheet(
            isPresented: Binding(
                get: { appshotStore.draft != nil },
                set: { presented in
                    if !presented { appshotStore.discard() }
                }
            )
        ) {
            AppshotPreviewView(store: appshotStore)
        }
        .alert(
            "Appshot 无法完成",
            isPresented: Binding(
                get: { appshotStore.errorMessage != nil },
                set: { presented in
                    if !presented { appshotStore.clearError() }
                }
            )
        ) {
            Button("知道了", role: .cancel) { appshotStore.clearError() }
            Button("打开权限设置") {
                attachmentStore.openScreenCaptureSettings()
                appshotStore.clearError()
            }
        } message: {
            Text(appshotStore.errorMessage ?? "请稍后重试。")
        }
        .alert(
            "部分文件未能加入对话",
            isPresented: Binding(
                get: { artifactStore.dropError != nil },
                set: { presented in
                    if !presented { artifactStore.clearDropError() }
                }
            )
        ) {
            Button("知道了", role: .cancel) {
                artifactStore.clearDropError()
            }
            Button("打开研究文件") {
                artifactStore.clearDropError()
                artifactStore.refresh()
                showsArtifactWorkbench = true
            }
        } message: {
            Text(artifactStore.dropError ?? "请检查文件后重试。")
        }
    }

    private func applicationMenuTitle(for application: AttachableApplication) -> String {
        let hasDuplicateName = attachmentStore.applications.contains {
            $0.id != application.id && $0.name == application.name
        }
        return hasDuplicateName
            ? "\(application.name) · PID \(application.processIdentifier)"
            : application.name
    }
}

private struct FileDropOverlay: View {
    let isImporting: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)

            VStack(spacing: 14) {
                if isImporting {
                    ProgressView()
                        .controlSize(.large)
                } else {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(.tint)
                }

                Text(isImporting ? "正在安全导入文件…" : "松开以加入当前对话")
                    .font(.title2.weight(.semibold))

                Text("支持 PDF、图片、Office、Markdown、代码与数据文件\n文件会复制到本机研究工作台，原文件不会被修改")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 38)
            .padding(.vertical, 30)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(.tint.opacity(0.55), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            }
            .shadow(color: .black.opacity(0.16), radius: 24, y: 10)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isImporting ? "正在导入文件" : "松开以加入当前对话")
    }
}

private struct ComputerUseSettingsView: View {
    @ObservedObject var store: AppAttachmentStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "cursorarrow.motionlines")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 4) {
                    Text("电脑控制")
                        .font(.title2.weight(.semibold))
                    Text("让 Harness 读取并操控你明确附加的应用")
                        .foregroundStyle(.secondary)
                }
            }

            PermissionRow(
                title: "辅助功能",
                detail: "读取控件，并执行点击、输入与滚动",
                isAllowed: store.accessibilityAllowed,
                requestPermission: store.requestAccessibilityPermission
            )

            PermissionRow(
                title: "屏幕与系统录音",
                detail: "截取附加窗口并在本机识别不可访问的文字",
                isAllowed: store.screenCaptureAllowed,
                requestPermission: store.requestScreenCapturePermission
            )

            Text("权限由 macOS 管理；只有你点击“请求权限”并在系统提示或系统设置中确认后才会生效。持续“附加应用”模式只发送经过脱敏的可访问性与本机 OCR 文字，原图不落盘；一次性 Appshot 会先显示预览，只有你确认后才保存到本机研究文件。若选用支持视觉的模型，仍需你在预览中明确允许发送原图。密码与钥匙串类应用始终被阻止。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("重新检查") {
                    store.refreshPermissions()
                }

                Spacer()

                Button("完成") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 540)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let isAllowed: Bool
    let requestPermission: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: isAllowed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title2)
                .foregroundStyle(isAllowed ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(isAllowed ? "已允许" : "请求权限", action: requestPermission)
                .disabled(isAllowed)
        }
        .padding(14)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct LaunchingView: View {
    let message: String

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 54, weight: .medium))
                .foregroundStyle(.tint)

            Text("DeepSeek Harness")
                .font(.largeTitle.weight(.semibold))

            ProgressView()
                .controlSize(.large)

            Text(message)
                .foregroundStyle(.secondary)
        }
        .padding(40)
    }
}

private struct FailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 46))
                .foregroundStyle(.orange)

            Text("无法启动 DeepSeek Harness")
                .font(.title2.weight(.semibold))

            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: 620)

            Button("重试", action: retry)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(40)
    }
}
