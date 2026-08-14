import SwiftUI

struct RemoteServersView: View {
    @ObservedObject var store: RemoteHostStore
    @Environment(\.dismiss) private var dismiss

    @State private var chosenAlias: String?
    @State private var remoteWorkspace: String

    init(store: RemoteHostStore) {
        self.store = store
        _chosenAlias = State(initialValue: store.selection?.alias)
        _remoteWorkspace = State(initialValue: store.selection?.remoteWorkspace ?? "")
    }

    private var chosenHost: RemoteHostDescriptor? {
        guard let chosenAlias else { return nil }
        return store.hosts.first { $0.alias == chosenAlias }
    }

    private var workspaceMessage: String? {
        store.workspaceValidationMessage(for: remoteWorkspace)
    }

    private var canSaveSelection: Bool {
        chosenHost != nil && workspaceMessage == nil && !store.isDiscovering
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let selection = store.selection {
                        activeSelectionCard(selection)
                    }

                    hostPicker
                    workspaceEditor
                    connectionPanel
                    safetyPanel
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack(spacing: 12) {
                if store.selection != nil {
                    Button("断开服务器", role: .destructive) {
                        store.detach()
                        chosenAlias = nil
                        remoteWorkspace = ""
                    }
                    .disabled(store.isTesting)
                }

                Spacer()

                Button("完成") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(
            minWidth: 620,
            idealWidth: 720,
            maxWidth: 760,
            minHeight: 520,
            idealHeight: 680,
            maxHeight: 760
        )
        .task {
            store.refreshHosts()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "server.rack")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background(.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                Text("远程服务器")
                    .font(.title2.weight(.semibold))
                Text("为当前应用选择一个明确的 SSH 主机与远程工作区")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                store.refreshHosts()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(store.isDiscovering || store.isTesting)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private func activeSelectionCard(_ selection: RemoteHostSelection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("当前选择", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)

            LabeledContent("服务器") {
                Text(selection.alias)
                    .fontWeight(.semibold)
                    .textSelection(.enabled)
            }
            LabeledContent("解析地址") {
                Text(selection.host.endpoint)
                    .monospaced()
                    .textSelection(.enabled)
            }
            LabeledContent("远程工作区") {
                Text(selection.remoteWorkspace)
                    .monospaced()
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            LabeledContent("选择到期") {
                Text(selection.expiresAt)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }

            RemoteStatusBanner(status: store.selectionStatus)
        }
        .padding(16)
        .background(.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.green.opacity(0.25))
        }
    }

    private var hostPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("1. 选择 SSH 主机")
                        .font(.headline)
                    Text("只显示 ~/.ssh/config 中明确、非通配符的 Host 别名")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if store.isDiscovering {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            RemoteStatusBanner(status: store.discoveryStatus)

            if !store.hosts.isEmpty {
                LazyVStack(spacing: 8) {
                    ForEach(store.hosts) { host in
                        hostRow(host)
                    }
                }
            }
        }
    }

    private func hostRow(_ host: RemoteHostDescriptor) -> some View {
        let isChosen = chosenAlias == host.alias

        return Button {
            chosenAlias = host.alias
            if store.selection?.alias == host.alias {
                remoteWorkspace = store.selection?.remoteWorkspace ?? remoteWorkspace
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.title3)
                    .foregroundStyle(isChosen ? Color.accentColor : Color.secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(host.alias)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(host.endpoint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer()

                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(
                        isChosen ? Color.accentColor : Color.secondary.opacity(0.65)
                    )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
            .background(
                isChosen ? Color.accentColor.opacity(0.09) : Color.secondary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 11)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(
                        isChosen ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.15)
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(host.alias)，\(host.endpoint)")
        .accessibilityValue(isChosen ? "已选择" : "未选择")
    }

    private var workspaceEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("2. 设置远程工作区")
                .font(.headline)

            TextField("例如 /data/project", text: $remoteWorkspace)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .disabled(chosenHost == nil)

            if let workspaceMessage {
                Label(workspaceMessage, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Label("将保存规范化后的绝对 POSIX 路径。", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()

                Button("保存选择") {
                    guard let chosenHost else { return }
                    if store.select(host: chosenHost, remoteWorkspace: remoteWorkspace) {
                        remoteWorkspace = store.selection?.remoteWorkspace ?? remoteWorkspace
                    }
                }
                .disabled(!canSaveSelection || store.isTesting)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "network")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 4) {
                    Text("3. 手动测试连接")
                        .font(.headline)
                    Text("只有点击下方按钮时，应用才会发起一次不分配终端的 SSH 测试。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    store.testSelectedConnection()
                } label: {
                    if store.isTesting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("测试连接", systemImage: "bolt.horizontal.circle")
                    }
                }
                .disabled(store.selection == nil || store.isTesting || store.isDiscovering)
            }

            RemoteStatusBanner(status: store.connectionStatus)
        }
        .padding(16)
        .background(.tint.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.tint.opacity(0.18))
        }
    }

    private var safetyPanel: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("连接与凭据边界", systemImage: "lock.shield.fill")
                .font(.headline)

            SafetyLine(
                icon: "key.horizontal",
                text: "首版只使用系统 OpenSSH 已配置的公钥或 ssh-agent 非交互登录；不支持密码或 MFA 输入，也不会保存私钥。"
            )
            SafetyLine(
                icon: "terminal",
                text: "首次连接请先在终端运行 ssh <别名>，核对并确认主机指纹。这里始终使用严格主机密钥校验，指纹未知或变化时会停止。"
            )
            SafetyLine(
                icon: "eye.slash",
                text: "界面与保存文件只包含别名、解析后的 user@host:port 和远程工作区；不会显示 IdentityFile 或 ProxyCommand。"
            )
            SafetyLine(
                icon: "sparkles",
                text: "选择最多有效 24 小时；再次明确保存会刷新期限。完成选择后，支持远程的工具才具备被模型按需自动使用的前置条件，实际调用仍受访问模式与确认策略限制。"
            )
        }
        .padding(16)
        .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct SafetyLine: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct RemoteStatusBanner: View {
    let status: RemoteHostStatus

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            if status.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 18)
            } else {
                Image(systemName: status.symbolName)
                    .foregroundStyle(status.tint)
                    .frame(width: 18)
            }

            Text(status.message)
                .font(.caption)
                .foregroundStyle(status.tint)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(status.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }
}

private extension RemoteHostStatus {
    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }

    var symbolName: String {
        switch self {
        case .idle:
            return "info.circle"
        case .working:
            return "clock"
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .failure:
            return "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .idle:
            return .secondary
        case .working:
            return .accentColor
        case .success:
            return .green
        case .warning:
            return .orange
        case .failure:
            return .red
        }
    }
}
