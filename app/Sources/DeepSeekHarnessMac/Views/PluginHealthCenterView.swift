import SwiftUI

struct PluginHealthCenterView: View {
    @ObservedObject var harness: HarnessService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("插件健康中心")
                        .font(.title2.weight(.semibold))
                    Text(harness.isReady
                         ? "本地服务已就绪 · dsh \(harness.runtimeVersion ?? "已验证版本")"
                         : harness.statusMessage)
                        .foregroundStyle(harness.isReady ? .green : .secondary)
                }
                Spacer()
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

            Divider()

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(items) { item in
                        PluginHealthRow(item: item)
                    }
                }
                .padding(18)
            }

            Divider()
            Text("“会话预设已启用”是静态配置说明，不是实时连接检测；“已启用”只表示本次 Harness 启动时完成首次发现和注册，不保证 MCP 后续持续在线。“自动”表示工具进入会话目录后，模型可按任务选择；高风险动作仍必须让你确认。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                .background(.bar)
        }
        .frame(width: 780, height: 760)
    }

    private var items: [PluginHealthItem] {
        let computerUseStatus = liveStatus(harness.computerUsePluginHealth)
        let artifactsStatus = liveStatus(harness.artifactsPluginHealth)
        let nativeAttachmentsStatus = liveStatus(harness.nativeAttachmentsPluginHealth)
        return [
            PluginHealthItem(
                title: "文件、Shell、搜索、代码编辑",
                technicalNames: "tool-fs · tool-bash · tool-fs-search · web_search",
                status: .preset,
                automatic: true,
                detail: "顶层列表中的停用行是官方宿主占位；实际能力由每个会话的 standard 预设装配。"
            ),
            PluginHealthItem(
                title: "计划、目标、Todo、子代理、工作流、Jobs",
                technicalNames: "plan · goal · todo · subagent · workflow · jobs",
                status: .preset,
                automatic: true,
                detail: "均由 standard 预设启用。复杂任务时模型可以自动规划、拆分和跟踪，不需要手动安装。"
            ),
            PluginHealthItem(
                title: "Skills 自动发现",
                technicalNames: "skill-filesystem · tool-skill",
                status: .preset,
                automatic: true,
                detail: "受管 Skills 会在启动时同步，并由每个 standard 会话预设装配；这是预设配置，不是实时插件连接状态。"
            ),
            PluginHealthItem(
                title: "macOS 电脑控制",
                technicalNames: "mcp-macos-computer-use",
                status: computerUseStatus,
                automatic: computerUseStatus == .active,
                detail: liveDetail(
                    harness.computerUsePluginHealth,
                    active: "首次发现和工具注册成功。只有你先附加一个明确应用后才可调用；操作精确绑定进程、窗口和快照。",
                    missing: "当前插件清单中没有找到 exact entryId：include:mcp-macos-computer-use。"
                )
            ),
            PluginHealthItem(
                title: "研究文件与 PDF",
                technicalNames: "mcp-artifacts",
                status: artifactsStatus,
                automatic: artifactsStatus == .active,
                detail: liveDetail(
                    harness.artifactsPluginHealth,
                    active: "首次发现和工具注册成功。导入本地研究文件后，模型可按任务列出、读取、搜索、渲染和引用页码。",
                    missing: "当前插件清单中没有找到 exact entryId：include:mcp-artifacts。"
                )
            ),
            PluginHealthItem(
                title: "原生文件拖入",
                technicalNames: "native-attachments",
                status: nativeAttachmentsStatus,
                automatic: nativeAttachmentsStatus == .active,
                detail: liveDetail(
                    harness.nativeAttachmentsPluginHealth,
                    active: "文件卡片与当前会话草稿桥接已启动。纯图片保留模型原生图片通道；PDF、Office、代码和混合文件自动转为受管研究附件。",
                    missing: "当前插件清单中没有找到 exact entryId：include:native-attachments。"
                )
            ),
            PluginHealthItem(
                title: "会话提醒",
                technicalNames: "dsh-schedule",
                status: .available,
                automatic: false,
                detail: "官方包可用但暂不自动开启：它会泄漏到 minimal 等精简预设，而且 App 或原会话关闭时不能准时通知。待加入真正的 macOS 通知与范围隔离后再启用。"
            ),
            PluginHealthItem(
                title: "DeepSeek 与 Kimi 模型适配器",
                technicalNames: "dsh-llm-deepseek · dsh-llm-pi-ai",
                status: .available,
                automatic: false,
                detail: "适配器始终可用；模型由你选择。Kimi 配好 API 后，图片直接走视觉模型，不经过 OCR。"
            ),
            PluginHealthItem(
                title: "HMR 开发热更新",
                technicalNames: "cordis-plugin-hmr",
                status: .intentional,
                automatic: false,
                detail: "只服务插件开发，正式 App 关闭它更稳定，不影响任何用户功能。"
            ),
            PluginHealthItem(
                title: "PowerShell",
                technicalNames: "tool-pwsh",
                status: .intentional,
                automatic: false,
                detail: "这是 Windows 专用替代入口；macOS 使用 Shell 工具，功能没有损失。"
            ),
            PluginHealthItem(
                title: "minimal 预设字符串编辑器",
                technicalNames: "tool-str-replace-editor",
                status: .presetSpecific,
                automatic: false,
                detail: "仅供 minimal 精简预设按需装配；standard 预设不启用。它不是旧工具，也不表示已被其他工具替代。"
            ),
            PluginHealthItem(
                title: "外部 Codex / Claude Code 子代理",
                technicalNames: "tool-subagent-codex · tool-subagent-claude-code",
                status: .intentional,
                automatic: false,
                detail: "未配置外部提供商时保持关闭；Harness 自带的原生子代理已启用。"
            )
        ]
    }

    private var isCheckingLivePlugins: Bool {
        harness.computerUsePluginHealth == .checking
            || harness.artifactsPluginHealth == .checking
            || harness.nativeAttachmentsPluginHealth == .checking
    }

    private func liveStatus(_ state: HarnessService.PluginHealthState) -> PluginHealthItem.Status {
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
            return active + " 此状态不保证后续连接持续在线。"
        case .missing:
            return missing
        case .error(let detail):
            return "实时检查失败：\(detail)"
        }
    }
}

private struct PluginHealthItem: Identifiable {
    enum Status {
        case active
        case preset
        case available
        case checking
        case missing
        case error
        case intentional
        case presetSpecific
    }

    let id = UUID()
    let title: String
    let technicalNames: String
    let status: Status
    let automatic: Bool
    let detail: String
}

private struct PluginHealthRow: View {
    let item: PluginHealthItem

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 24)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(item.title)
                        .font(.headline)
                    Text(statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(color.opacity(0.1), in: Capsule())
                    if item.automatic {
                        Text("自动")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.blue)
                    }
                }
                Text(item.technicalNames)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(item.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusText: String {
        switch item.status {
        case .active: return "已启用"
        case .preset: return "会话预设已启用"
        case .available: return "可配置"
        case .checking: return "检查中"
        case .missing: return "未发现"
        case .error: return "异常"
        case .intentional: return "有意停用"
        case .presetSpecific: return "minimal 专用"
        }
    }

    private var symbol: String {
        switch item.status {
        case .active, .preset: return "checkmark.circle.fill"
        case .available: return "plus.circle.fill"
        case .checking: return "clock.fill"
        case .missing: return "questionmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .intentional: return "pause.circle.fill"
        case .presetSpecific: return "slider.horizontal.3"
        }
    }

    private var color: Color {
        switch item.status {
        case .active, .preset: return .green
        case .available: return .blue
        case .checking: return .orange
        case .missing, .error: return .red
        case .intentional, .presetSpecific: return .secondary
        }
    }
}
