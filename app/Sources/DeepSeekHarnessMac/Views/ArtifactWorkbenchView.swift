import AppKit
import PDFKit
import Quartz
import SwiftUI

struct ArtifactWorkbenchView: View {
    @ObservedObject var store: ArtifactStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                if store.artifacts.isEmpty {
                    ContentUnavailableView(
                        "还没有文件",
                        systemImage: "doc.badge.plus",
                        description: Text("导入 PDF、图片、Office 文档、数据或代码文件。")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(store.artifacts, selection: $store.selectedArtifactID) { artifact in
                        ArtifactRow(artifact: artifact)
                            .tag(artifact.id)
                    }
                }

                Divider()
                HStack {
                    Button {
                        store.importFiles()
                    } label: {
                        Label("导入文件", systemImage: "plus")
                    }
                    Spacer()
                    Button {
                        store.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("刷新")
                }
                .padding(10)
            }
            .navigationTitle("研究文件")
        } detail: {
            if let artifact = store.selectedArtifact {
                ArtifactDetail(artifact: artifact, store: store)
            } else {
                ContentUnavailableView("选择一个文件", systemImage: "doc.text.magnifyingglass")
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 980, idealWidth: 1120, minHeight: 620, idealHeight: 720)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if let error = store.lastError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                HStack {
                    Text("在对话中直接说“读取我刚导入的文件”或“分析第 3 页”，Harness 会调用本地文件工具。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("完成") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
            .background(.bar)
        }
    }
}

private struct ArtifactRow: View {
    let artifact: ManagedArtifact

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.displayName)
                    .lineLimit(2)
                Text("\(artifact.kind.rawValue) · \(artifact.sizeDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var symbol: String {
        switch artifact.kind {
        case .pdf: return "doc.richtext.fill"
        case .image: return "photo.fill"
        case .document: return "doc.text.fill"
        case .spreadsheet: return "tablecells.fill"
        case .presentation: return "rectangle.on.rectangle.angled"
        case .text: return "text.document.fill"
        case .appshot: return "macwindow.badge.plus"
        case .other: return "doc.fill"
        }
    }

    private var color: Color {
        switch artifact.kind {
        case .pdf: return .red
        case .spreadsheet: return .green
        case .presentation: return .orange
        case .appshot: return .purple
        default: return .accentColor
        }
    }
}

private struct ArtifactDetail: View {
    let artifact: ManagedArtifact
    @ObservedObject var store: ArtifactStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(artifact.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(artifact.relativePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                if artifact.kind == .image {
                    Button("复制图片") {
                        copyImageToPasteboard()
                    }
                    .help("复制后可粘贴到已选择视觉模型的对话中")
                }
                Button("在原应用打开") { store.open(artifact) }
                Button("在访达中显示") { store.reveal(artifact) }
            }
            .padding(12)
            Divider()

            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch artifact.kind {
        case .pdf:
            PDFPreview(url: artifact.url)
        case .image:
            if let image = NSImage(contentsOf: artifact.url) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(20)
                }
            } else {
                previewUnavailable
            }
        case .text, .appshot:
            TextFilePreview(url: artifact.url)
        default:
            QuickLookPreview(url: artifact.url)
        }
    }

    private var previewUnavailable: some View {
        ContentUnavailableView(
            "无法生成预览",
            systemImage: "eye.slash",
            description: Text("文件仍已安全导入，可以让模型读取或在原应用中打开。")
        )
    }

    private func copyImageToPasteboard() {
        guard let image = NSImage(contentsOf: artifact.url),
              let cgImage = image.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
              ),
              let data = NSBitmapImageRep(cgImage: cgImage)
                .representation(using: .png, properties: [:]) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
    }
}

private struct PDFPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .windowBackgroundColor
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}

private struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView(frame: .zero)
        view?.autostarts = true
        view?.previewItem = url as NSURL
        return view ?? QLPreviewView(frame: .zero)!
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        view.previewItem = url as NSURL
    }
}

private struct TextFilePreview: View {
    let url: URL
    @State private var text = "正在读取…"

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(18)
        }
        .task(id: url) {
            text = await Task.detached(priority: .utility) {
                guard let handle = try? FileHandle(forReadingFrom: url) else {
                    return "无法读取这个文件。"
                }
                defer { try? handle.close() }
                let data = (try? handle.read(upToCount: 512 * 1_024)) ?? Data()
                guard let text = String(data: data, encoding: .utf8) else {
                    return "这个文件不是 UTF-8 文本，可在原应用中打开。"
                }
                return text + (data.count == 512 * 1_024 ? "\n\n…预览已截断…" : "")
            }.value
        }
    }
}
