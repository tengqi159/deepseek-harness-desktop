import SwiftUI

struct AppshotPreviewView: View {
    @ObservedObject var store: AppshotStore
    @Environment(\.dismiss) private var dismiss
    @State private var saveError: String?

    var body: some View {
        Group {
            if let draft = store.draft {
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "macwindow.badge.plus")
                            .font(.title2)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("确认 Appshot")
                                .font(.title2.weight(.semibold))
                            Text("\(draft.applicationName) · \(draft.windowTitle ?? "当前窗口")")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(18)

                    Divider()

                    HSplitView {
                        ScrollView([.horizontal, .vertical]) {
                            Image(
                                nsImage: draft.previewImage(
                                    allowingOriginal: store.allowImageForVisionModel
                                )
                            )
                                .resizable()
                                .scaledToFit()
                                .padding(14)
                        }
                        .frame(minWidth: 520)

                        VStack(alignment: .leading, spacing: 12) {
                            Text("将提供给模型的文字上下文")
                                .font(.headline)
                            ScrollView {
                                Text(draft.contextMarkdown)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                    .padding(10)
                            }
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

                            Toggle("允许支持视觉的模型读取这张原图", isOn: $store.allowImageForVisionModel)
                                .toggleStyle(.checkbox)
                            Text(store.allowImageForVisionModel
                                 ? "正在显示原图。保存后，只有已声明图像能力的模型适配器才能读取；实际发送仍需在对话中确认。"
                                 : "正在显示本机遮盖敏感内容后的版本。保存和复制都不会使用未经批准的原图。")
                                .font(.caption)
                                .foregroundStyle(
                                    store.allowImageForVisionModel ? Color.orange : Color.secondary
                                )
                                .fixedSize(horizontal: false, vertical: true)

                            if draft.visualRedactionCount > 0 {
                                Label(
                                    "已在图片中遮盖 \(draft.visualRedactionCount) 处疑似凭据；右侧文字也已脱敏。",
                                    systemImage: "lock.shield"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(minWidth: 360, idealWidth: 420)
                        .padding(16)
                    }

                    Divider()

                    HStack {
                        if let saveError {
                            Text(saveError)
                                .font(.callout)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button(store.allowImageForVisionModel ? "复制原图" : "复制脱敏图片") {
                            store.copyDraftImageToPasteboard()
                        }
                        .help(
                            store.allowImageForVisionModel
                                ? "复制明确批准的原图"
                                : "复制本机遮盖敏感内容后的图片"
                        )
                        Button("丢弃") {
                            store.discard()
                            dismiss()
                        }
                        Button(
                            store.allowImageForVisionModel
                                ? "保存并批准原图"
                                : "保存脱敏 Appshot"
                        ) {
                            do {
                                _ = try store.confirm()
                                dismiss()
                            } catch {
                                saveError = error.localizedDescription
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                    .padding(14)
                }
            } else {
                ProgressView("正在生成 Appshot…")
                    .padding(40)
            }
        }
        .frame(minWidth: 960, idealWidth: 1120, minHeight: 640, idealHeight: 760)
    }
}
