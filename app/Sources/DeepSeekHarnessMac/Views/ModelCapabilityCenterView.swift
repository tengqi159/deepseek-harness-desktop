import AppKit
import SwiftUI

struct ModelCapabilityCenterView: View {
    @ObservedObject var store: ModelCapabilityStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "switch.2")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("模型能力中心")
                        .font(.title2.weight(.semibold))
                    if let registry = store.registry {
                        Text("官方资料核验于 \(registry.verifiedAt) · 到期 \(registry.expiresAt)")
                            .foregroundStyle(store.isExpired ? .orange : .secondary)
                    }
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            if let error = store.errorMessage {
                ContentUnavailableView(
                    "无法读取能力注册表",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(store.providers) { provider in
                            ProviderCapabilityCard(provider: provider)
                        }
                    }
                    .padding(20)
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Text("添加 Kimi：在 Harness 左下角“设置 → Models”中选择 `moonshotai-cn`（中国区）或 `moonshotai`（国际区），保存对应区域的 API key，再选择 Kimi 模型。密钥不会写入这份能力注册表。")
                    .font(.callout)
                    .textSelection(.enabled)
                Text("实际能力始终取“模型服务商 ∩ Harness 适配器 ∩ 当前附件通路”的交集；未知上限不会被当作无限制。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(.bar)
        }
        .frame(width: 760, height: 720)
    }
}

private struct ProviderCapabilityCard: View {
    let provider: VerifiedProviderCapability

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .font(.headline)
                    Text("\(provider.id) · \(provider.baseURL)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Text(provider.region == "cn" ? "中国区" : "国际区")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }

            if let input = provider.input {
                HStack(spacing: 7) {
                    CapabilityPill(title: "文字", status: input.text)
                    CapabilityPill(title: "图片", status: input.image)
                    CapabilityPill(title: "视频", status: input.video)
                    CapabilityPill(title: "PDF/文件", status: input.fileExtract)
                    CapabilityPill(title: "音频", status: input.audio)
                }
            } else if let inherits = provider.inherits {
                Text("能力继承自 \(inherits)，但账户与 API key 必须使用国际区。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let models = provider.models, !models.isEmpty {
                Text(models.map(\.id).joined(separator: "  ·  "))
                    .font(.callout.weight(.medium))
                    .textSelection(.enabled)
            }

            ForEach(provider.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let source = provider.sources.first, let url = URL(string: source) {
                Button("查看官方说明") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.link)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct CapabilityPill: View {
    let title: String
    let status: String?

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(color.opacity(0.11), in: Capsule())
            .help(statusText)
    }

    private var statusText: String {
        switch status {
        case "supported": return "可直接使用"
        case "local-tool": return "由本地工具处理"
        case "tool-only": return "只能通过受控工具处理"
        case "unsupported": return "不支持"
        default: return "尚未核验"
        }
    }

    private var symbol: String {
        switch status {
        case "supported": return "checkmark.circle.fill"
        case "local-tool", "tool-only": return "wrench.and.screwdriver.fill"
        case "unsupported": return "xmark.circle.fill"
        default: return "questionmark.circle.fill"
        }
    }

    private var color: Color {
        switch status {
        case "supported": return .green
        case "local-tool", "tool-only": return .orange
        case "unsupported": return .secondary
        default: return .orange
        }
    }
}
