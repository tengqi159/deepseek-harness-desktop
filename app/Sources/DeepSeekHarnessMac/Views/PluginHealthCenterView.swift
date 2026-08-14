import SwiftUI

struct PluginHealthCenterView: View {
    @ObservedObject var harness: HarnessService
    @Environment(\.dismiss) private var dismiss
    @State private var showsTechnicalNames = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    explanationCard

                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Label(group.title, systemImage: group.symbol)
                                .font(.headline)
                                .foregroundStyle(.secondary)

                            ForEach(group.items) { item in
                                CapabilityRow(
                                    item: item,
                                    showsTechnicalNames: showsTechnicalNames
                                )
                            }
                        }
                    }

                    intentionalSummary
                }
                .padding(20)
            }

            Divider()
            footer
        }
        .frame(width: 760, height: 720)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 3) {
                Text("能力与插件")
                    .font(.title2.weight(.semibold))
                Text(harness.isReady
                     ? "本地服务已就绪 · dsh \(harness.runtimeVersion ?? "已验证版本")"
                     : harness.statusMessage)
                    .foregroundStyle(harness.isReady ? .green : .secondary)
            }

            Spacer()

            Toggle("技术标识", isOn: $showsTechnicalNames)
                .toggleStyle(.switch)
                .controlSize(.small)

            Button {
                harness.refreshPluginHealth()
            } label: {
                Label("重新检查", systemImage: "arrow.clockwise")
            }
            .disabled(!harness.isReady || isCheckingLivePlugins)

            Button("完成") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    private var explanationCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "lightbulb.max.fill")
                .font(.title2)
                .foregroundStyle(.yellow)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 6) {
                Text("不需要先“召唤”大多数工具")
                    .font(.headline)
                Text("标为“模型可自动选择”的能力由 standard 会话预设装配；当前会话使用该预设时，模型会根据任务决定是否调用。输入 / 命令或 /skill-name 只是更确定的手动快捷方式，并不是启用插件的开关。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.blue.opacity(0.16))
        }
    }

    private var groups: [CapabilityGroup] {
        let computerUseStatus = liveStatus(harness.computerUsePluginHealth)
        let artifactsStatus = liveStatus(harness.artifactsPluginHealth)
        let nativeAttachmentsStatus = liveStatus(harness.nativeAttachmentsPluginHealth)
        let capabilityCatalogStatus = liveStatus(harness.capabilityCatalogPluginHealth)
        let standardPresetStatus = liveStatus(harness.standardPresetPluginHealth)

        return [
            CapabilityGroup(
                title: "模型可按任务选择",
                symbol: "wand.and.stars",
                items: [
                    CapabilityItem(
                        title: "文件、代码与 Shell",
                        technicalNames: "tool-fs · tool-bash · tool-fs-search",
                        symbol: "terminal.fill",
                        tint: .indigo,
                        status: standardPresetStatus,
                        invocation: .modelAutomatic,
                        detail: "读取和编辑工作区文件、运行命令、查找代码。由 standard 会话预设实际装配。"
                    ),
                    CapabilityItem(
                        title: "网页搜索",
                        technicalNames: "tool-web · web_search",
                        symbol: "globe",
                        tint: .cyan,
                        status: standardPresetStatus,
                        invocation: .modelAutomatic,
                        detail: "研究任务需要新资料时，模型可以自行调用网页搜索。"
                    ),
                    CapabilityItem(
                        title: "计划、目标与 Todo",
                        technicalNames: "plan · goal · todo",
                        symbol: "checklist.checked",
                        tint: .orange,
                        status: standardPresetStatus,
                        invocation: .modelAutomatic,
                        detail: "复杂任务时可自动规划、记录目标和跟踪待办；/plan 与 /goal 仍是手动快捷入口。"
                    ),
                    CapabilityItem(
                        title: "子代理、工作流与 Jobs",
                        technicalNames: "subagent · workflow · jobs",
                        symbol: "person.2.fill",
                        tint: .purple,
                        status: standardPresetStatus,
                        invocation: .modelAutomatic,
                        detail: "任务适合并行或需要后台命令时，模型可以自动拆分和协调。"
                    ),
                    CapabilityItem(
                        title: "Skills",
                        technicalNames: "skill-filesystem · tool-skill",
                        symbol: "sparkles.rectangle.stack.fill",
                        tint: .pink,
                        status: standardPresetStatus,
                        invocation: .onDemand,
                        detail: "启动时自动发现。模型先看到名称和说明，任务明显匹配时可自动按需加载完整 Skill。"
                    )
                ]
            ),
            CapabilityGroup(
                title: "完成前置后可自动使用",
                symbol: "arrow.triangle.branch",
                items: [
                    CapabilityItem(
                        title: "研究文件、PDF 与 Office",
                        technicalNames: "mcp-artifacts",
                        symbol: "doc.text.magnifyingglass",
                        tint: .blue,
                        status: artifactsStatus,
                        invocation: .afterImport,
                        detail: liveDetail(
                            harness.artifactsPluginHealth,
                            active: "先拖入或导入文件。之后模型可按需读取文本、搜索 PDF、引用页码、渲染页面或提取 Office 内容。",
                            missing: "当前插件清单中没有找到研究文件桥。"
                        )
                    ),
                    CapabilityItem(
                        title: "macOS 电脑控制",
                        technicalNames: "mcp-macos-computer-use",
                        symbol: "macwindow.and.cursorarrow",
                        tint: .purple,
                        status: computerUseStatus,
                        invocation: .afterAttach,
                        detail: liveDetail(
                            harness.computerUsePluginHealth,
                            active: "先在窗口顶部附加一个明确应用并完成系统授权。之后模型可在任务需要时选择相应工具。",
                            missing: "当前插件清单中没有找到 macOS 电脑控制桥。"
                        )
                    ),
                    CapabilityItem(
                        title: "原生文件拖入",
                        technicalNames: "native-attachments",
                        symbol: "arrow.down.doc.fill",
                        tint: .teal,
                        status: nativeAttachmentsStatus,
                        invocation: .systemRouting,
                        detail: liveDetail(
                            harness.nativeAttachmentsPluginHealth,
                            active: "你拖入文件后，系统自动把它绑定到当时的会话；纯图片与研究文件会按当前模型能力选择正确通路。",
                            missing: "当前插件清单中没有找到原生附件桥。"
                        )
                    )
                ]
            ),
            CapabilityGroup(
                title: "由你手动启动",
                symbol: "hand.tap.fill",
                items: [
                    CapabilityItem(
                        title: "图标化能力菜单",
                        technicalNames: "capability-catalog",
                        symbol: "square.grid.2x2.fill",
                        tint: .indigo,
                        status: capabilityCatalogStatus,
                        invocation: .manualOnly,
                        detail: liveDetail(
                            harness.capabilityCatalogPluginHealth,
                            active: "点击输入框工具栏里的彩色能力图标，可以按分组查看命令、Skills 和插件状态；选择条目只会写入草稿，不会替你发送。",
                            missing: "当前插件清单中没有找到图标化能力菜单。"
                        )
                    ),
                    CapabilityItem(
                        title: "Appshot",
                        technicalNames: "native Appshot",
                        symbol: "viewfinder.circle.fill",
                        tint: .mint,
                        status: .included,
                        invocation: .manualOnly,
                        detail: "必须由你点击工具栏、菜单或快捷键发起，并在预览中确认；模型不能静默截屏。"
                    ),
                    CapabilityItem(
                        title: "模型与提供商",
                        technicalNames: "dsh-llm-deepseek · dsh-llm-pi-ai",
                        symbol: "brain.head.profile",
                        tint: .blue,
                        status: .adapterIncluded,
                        invocation: .manualOnly,
                        detail: "模型由你选择，Harness 不会自行切换 API 提供商。选定模型之后，模型才会自动决定是否调用工具。"
                    ),
                    CapabilityItem(
                        title: "Slash Commands",
                        technicalNames: "/compact · /export · /goal · /permission · /plan · /model",
                        symbol: "slash.circle.fill",
                        tint: .gray,
                        status: .registered,
                        invocation: .manualOnly,
                        detail: "这些是用户界面命令，只在你选择或输入后执行；模型不会自己点击命令菜单。"
                    )
                ]
            )
        ]
    }

    private var intentionalSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("按环境或预设启用", systemImage: "pause.circle.fill")
                .font(.headline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                intentionalLine(
                    icon: "hammer.fill",
                    title: "HMR 开发热更新",
                    detail: "用户功能不依赖这个开发入口；宿主层无需启用它。"
                )
                intentionalLine(
                    icon: "pc",
                    title: "PowerShell",
                    detail: "Windows 专用；macOS 已使用 Shell。"
                )
                intentionalLine(
                    icon: "slider.horizontal.3",
                    title: "minimal 专用编辑器",
                    detail: "只在 minimal 精简预设装配。"
                )
                intentionalLine(
                    icon: "person.badge.plus",
                    title: "外部 Codex / Claude Code 子代理",
                    detail: "未配置外部提供商时关闭；Harness 原生子代理正常可用。"
                )
                intentionalLine(
                    icon: "bell.badge",
                    title: "会话提醒",
                    detail: "官方包存在，但在缺少可靠 macOS 后台通知前不默认启用。"
                )
            }
            .padding(14)
            .background(.quaternary.opacity(0.34), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func intentionalLine(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title)
                .font(.callout.weight(.semibold))
            Text("· \(detail)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text("当前无需启用")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.message.fill")
                .foregroundStyle(.blue)
            Text("“可自动选择”不等于“这一轮已经调用”。真正调用时，对话中会出现对应的工具调用卡片；如果任务很关键，你也可以明确说“请读取附件”或“请使用电脑控制”。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.bar)
    }

    private var isCheckingLivePlugins: Bool {
        harness.computerUsePluginHealth == .checking
            || harness.artifactsPluginHealth == .checking
            || harness.nativeAttachmentsPluginHealth == .checking
            || harness.capabilityCatalogPluginHealth == .checking
            || harness.standardPresetPluginHealth == .checking
    }

    private func liveStatus(_ state: HarnessService.PluginHealthState) -> CapabilityItem.Status {
        switch state {
        case .checking: return .checking
        case .active: return .active
        case .missing: return .missing
        case .error: return .error
        }
    }

    private func liveDetail(
        _ state: HarnessService.PluginHealthState,
        active: String,
        missing: String
    ) -> String {
        switch state {
        case .checking:
            return "正在读取 Harness 的实时插件清单。"
        case .active:
            return active + " 当前状态表示本次启动已完成发现和注册，不保证连接永远在线。"
        case .missing:
            return missing
        case .error(let detail):
            return "实时检查失败：\(detail)"
        }
    }
}

private struct CapabilityGroup: Identifiable {
    let title: String
    let symbol: String
    let items: [CapabilityItem]

    var id: String { title }
}

private struct CapabilityItem: Identifiable {
    enum Status {
        case active
        case preset
        case available
        case included
        case adapterIncluded
        case registered
        case checking
        case missing
        case error
    }

    enum Invocation {
        case modelAutomatic
        case onDemand
        case afterImport
        case afterAttach
        case systemRouting
        case manualOnly

        var text: String {
            switch self {
            case .modelAutomatic: return "模型可自动选择"
            case .onDemand: return "模型可按需加载"
            case .afterImport: return "导入后可自动选择"
            case .afterAttach: return "附加后可自动选择"
            case .systemRouting: return "拖入后自动处理"
            case .manualOnly: return "仅手动"
            }
        }

        var color: Color {
            switch self {
            case .modelAutomatic, .onDemand: return .green
            case .afterImport, .afterAttach, .systemRouting: return .blue
            case .manualOnly: return .secondary
            }
        }
    }

    let title: String
    let technicalNames: String
    let symbol: String
    let tint: Color
    let status: Status
    let invocation: Invocation
    let detail: String

    var id: String { title }
}

private struct CapabilityRow: View {
    let item: CapabilityItem
    let showsTechnicalNames: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(item.tint)
                .frame(width: 38, height: 38)
                .background(item.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.headline)

                    Text(item.invocation.text)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(item.invocation.color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(item.invocation.color.opacity(0.1), in: Capsule())

                    Spacer(minLength: 6)

                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                        Text(statusText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(statusColor)
                    }
                }

                Text(item.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if showsTechnicalNames {
                    Text(item.technicalNames)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.36), in: RoundedRectangle(cornerRadius: 13))
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        switch item.status {
        case .active: return "启动已注册"
        case .preset: return "会话已装配"
        case .available: return "可用"
        case .included: return "应用已内置"
        case .adapterIncluded: return "适配器已包含"
        case .registered: return "命令已注册"
        case .checking: return "检查中"
        case .missing: return "未发现"
        case .error: return "检查失败"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .active, .preset: return .green
        case .available, .included, .adapterIncluded, .registered: return .blue
        case .checking: return .orange
        case .missing, .error: return .red
        }
    }
}
