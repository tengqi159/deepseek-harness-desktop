import AppKit
import CoreFoundation
import Foundation
import ImageIO

struct ManagedArtifact: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case pdf = "PDF"
        case image = "图片"
        case document = "文档"
        case spreadsheet = "表格"
        case presentation = "演示文稿"
        case text = "文本"
        case appshot = "Appshot"
        case other = "文件"
    }

    let id: String
    let url: URL
    let relativePath: String
    let displayName: String
    let byteCount: Int64
    let modifiedAt: Date
    let kind: Kind

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

struct NativeAttachmentPayload: Equatable, Sendable {
    enum DeliveryState: String, Equatable, Sendable {
        case pending
        case accepted
    }

    struct Attachment: Identifiable, Equatable, Sendable {
        let id: String
        let displayName: String
        let kind: String
        let relativePath: String
        let byteCount: Int64
        let sizeDescription: String

        fileprivate var javaScriptObject: [String: Any] {
            [
                "id": id,
                "displayName": displayName,
                "kind": kind,
                "relativePath": relativePath,
                "byteCount": byteCount,
                "sizeDescription": sizeDescription
            ]
        }
    }

    let revision: Int
    let sessionID: String
    let attachments: [Attachment]
    let deliveryState: DeliveryState

    var javaScriptObject: [String: Any] {
        [
            "version": 1,
            "revision": revision,
            "sessionId": sessionID,
            "attachments": attachments.map(\.javaScriptObject)
        ]
    }
}

struct NativeAttachmentLifecycleEvent: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case accepted
        case removed
    }

    let kind: Kind
    let revision: Int
    let sessionID: String
    let attachmentIDs: [String]
}

extension Notification.Name {
    static let deepSeekArtifactsDidChange = Notification.Name("DeepSeekHarness.ArtifactsDidChange")
}

@MainActor
final class ArtifactStore: ObservableObject {
    @Published private(set) var artifacts: [ManagedArtifact] = []
    @Published var selectedArtifactID: ManagedArtifact.ID?
    @Published private(set) var lastError: String?
    @Published private(set) var dropError: String?
    @Published private(set) var isImportingDroppedFiles = false
    @Published private(set) var nativeAttachmentPayloads: [NativeAttachmentPayload] = []

    nonisolated static let maximumImportBytes: Int64 = 512 * 1_024 * 1_024
    nonisolated static let maximumDropBatchBytes: Int64 = 512 * 1_024 * 1_024
    nonisolated static let maximumDropFileCount = 32
    nonisolated static let maximumNativeAttachmentPayloads = 32
    nonisolated static let maximumJavaScriptSafeInteger = 9_007_199_254_740_991
    private static let nativeAttachmentRevisionHighWaterKey =
        "DeepSeekHarness.NativeAttachmentRevisionHighWater"

    // Revisions are consumed by a long-lived web session and must not repeat when
    // the native shell is rebuilt or relaunched. Epoch milliseconds plus a
    // persisted high-water mark stay below Number.MAX_SAFE_INTEGER and preserve FIFO.
    private var nativeAttachmentRevision: Int

    nonisolated static var rootURL: URL {
#if DEBUG
        if let override = ProcessInfo.processInfo.environment["DSH_ARTIFACT_STORE_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
#endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DeepSeek Harness/Artifacts", isDirectory: true)
    }

    nonisolated static var inboxURL: URL {
        rootURL.appendingPathComponent("Inbox", isDirectory: true)
    }

    nonisolated static var appshotsURL: URL {
        rootURL.appendingPathComponent("Appshots", isDirectory: true)
    }

    nonisolated static var rendersURL: URL {
        rootURL.appendingPathComponent("Renders", isDirectory: true)
    }

    nonisolated static var exportsURL: URL {
        rootURL.appendingPathComponent("Exports", isDirectory: true)
    }

    private var observer: NSObjectProtocol?

    init() {
        nativeAttachmentRevision = Self.initialNativeAttachmentRevision()
        prepareDirectories()
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: .deepSeekArtifactsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var selectedArtifact: ManagedArtifact? {
        guard let selectedArtifactID else { return artifacts.first }
        return artifacts.first { $0.id == selectedArtifactID } ?? artifacts.first
    }

    func importFiles() {
        lastError = nil
        let panel = NSOpenPanel()
        panel.title = "导入到 DeepSeek Harness"
        panel.prompt = "导入"
        panel.message = "文件会复制到 Harness 的本地工作台；原文件不会被修改。"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true

        guard panel.runModal() == .OK else { return }

        var importedIDs: [String] = []
        var errors: [String] = []
        for source in panel.urls {
            do {
                let imported = try importFile(at: source)
                importedIDs.append(imported.id)
            } catch {
                errors.append("\(source.lastPathComponent)：\(error.localizedDescription)")
            }
        }

        refresh()
        if let last = importedIDs.last {
            selectedArtifactID = last
        }
        if !errors.isEmpty {
            lastError = errors.joined(separator: "\n")
        }
    }

    func importDroppedFiles(_ sources: [URL], targetSessionID: String?) {
        dropError = nil
        guard let targetSessionID = validatedImportSession(targetSessionID),
              canBeginNativeAttachmentImport() else { return }

        let uniqueSources = Self.uniqueFileURLs(sources)
        guard !uniqueSources.isEmpty else {
            dropError = "没有找到可导入的文件。"
            return
        }
        guard uniqueSources.count <= Self.maximumDropFileCount else {
            dropError = "一次最多拖入 \(Self.maximumDropFileCount) 个文件。"
            return
        }

        isImportingDroppedFiles = true
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.importDropBatch(uniqueSources)
            }.value

            guard let self else { return }
            self.finishNativeAttachmentImport(result, targetSessionID: targetSessionID)
        }
    }

    func importPastedImageData(
        _ data: Data,
        fileExtension: String,
        targetSessionID: String?
    ) {
        dropError = nil
        guard let targetSessionID = validatedImportSession(targetSessionID),
              canBeginNativeAttachmentImport() else { return }

        let normalizedExtension = fileExtension.lowercased()
        let allowedExtensions = Set(["png", "jpg", "jpeg", "gif", "tiff"])
        guard allowedExtensions.contains(normalizedExtension),
              !data.isEmpty,
              Int64(data.count) <= Self.maximumImportBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            dropError = "剪贴板中的图片数据无效或超过大小上限。"
            return
        }

        isImportingDroppedFiles = true
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                let stagingDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "deepseek-harness-paste-\(UUID().uuidString.lowercased())",
                        isDirectory: true
                    )
                defer { try? FileManager.default.removeItem(at: stagingDirectory) }
                do {
                    try FileManager.default.createDirectory(
                        at: stagingDirectory,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700]
                    )
                    let stagedImage = stagingDirectory.appendingPathComponent(
                        "pasted-image.\(normalizedExtension)",
                        isDirectory: false
                    )
                    try data.write(to: stagedImage, options: [.atomic])
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: stagedImage.path
                    )
                    return Self.importDropBatch([stagedImage])
                } catch {
                    return DropImportResult(
                        imported: [],
                        errors: ["剪贴板图片：\(error.localizedDescription)"]
                    )
                }
            }.value

            guard let self else { return }
            self.finishNativeAttachmentImport(result, targetSessionID: targetSessionID)
        }
    }

    private func validatedImportSession(_ targetSessionID: String?) -> String? {
        guard let targetSessionID,
              !targetSessionID.isEmpty,
              targetSessionID.count <= 512,
              !targetSessionID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            dropError = "当前会话尚未准备好接收文件，请等待输入框出现后再试。"
            return nil
        }
        return targetSessionID
    }

    private func canBeginNativeAttachmentImport() -> Bool {
        guard !isImportingDroppedFiles else {
            dropError = "上一批文件仍在导入，请稍候再试。"
            return false
        }
        guard nativeAttachmentPayloads.lazy.filter({ $0.deliveryState == .pending }).count
                < Self.maximumNativeAttachmentPayloads else {
            dropError = "仍有 32 批附件等待加入对话，请等待卡片出现或重新载入界面后再试。"
            return false
        }
        return true
    }

    private func finishNativeAttachmentImport(
        _ result: DropImportResult,
        targetSessionID: String
    ) {
        isImportingDroppedFiles = false
        refresh()

        if !result.imported.isEmpty {
            guard nativeAttachmentRevision < Self.maximumJavaScriptSafeInteger else {
                dropError = "附件批次编号已达到安全上限，请重新启动 DeepSeek Harness 后再试。"
                return
            }
            nativeAttachmentRevision += 1
            Self.persistNativeAttachmentRevision(nativeAttachmentRevision)
            let payload = NativeAttachmentPayload(
                revision: nativeAttachmentRevision,
                sessionID: targetSessionID,
                attachments: result.imported.map { artifact in
                    NativeAttachmentPayload.Attachment(
                        id: artifact.id,
                        displayName: artifact.displayName,
                        kind: artifact.kind.rawValue,
                        relativePath: artifact.relativePath,
                        byteCount: artifact.byteCount,
                        sizeDescription: artifact.sizeDescription
                    )
                },
                deliveryState: .pending
            )
            self.nativeAttachmentPayloads.append(payload)
            while self.nativeAttachmentPayloads.count > Self.maximumNativeAttachmentPayloads,
                  let acceptedIndex = self.nativeAttachmentPayloads.firstIndex(where: {
                      $0.deliveryState == .accepted
                  }) {
                self.nativeAttachmentPayloads.remove(at: acceptedIndex)
            }
            selectedArtifactID = result.imported.last?.id
            NotificationCenter.default.post(name: .deepSeekArtifactsDidChange, object: nil)
        }

        if !result.errors.isEmpty {
            dropError = result.errors.joined(separator: "\n")
        }
    }

    private static func initialNativeAttachmentRevision() -> Int {
        let maximumSeed = maximumJavaScriptSafeInteger - maximumNativeAttachmentPayloads - 1
        let clockSeed = min(maximumSeed, max(1, Int(Date().timeIntervalSince1970 * 1_000)))
#if DEBUG
        // Disposable QA stores must not mutate the user's application defaults.
        if ProcessInfo.processInfo.environment["DSH_ARTIFACT_STORE_ROOT"] != nil {
            return clockSeed
        }
#endif
        let stored = (UserDefaults.standard.object(
            forKey: nativeAttachmentRevisionHighWaterKey
        ) as? NSNumber)?.intValue ?? 0
        let boundedStored = min(maximumSeed - 1, max(0, stored))
        let seed = max(clockSeed, boundedStored + 1)
        UserDefaults.standard.set(seed, forKey: nativeAttachmentRevisionHighWaterKey)
        return seed
    }

    private static func persistNativeAttachmentRevision(_ revision: Int) {
#if DEBUG
        if ProcessInfo.processInfo.environment["DSH_ARTIFACT_STORE_ROOT"] != nil {
            return
        }
#endif
        UserDefaults.standard.set(revision, forKey: nativeAttachmentRevisionHighWaterKey)
    }

    func handleNativeAttachmentLifecycle(_ event: NativeAttachmentLifecycleEvent) {
        guard event.revision >= 1,
              !event.sessionID.isEmpty,
              !event.attachmentIDs.isEmpty,
              Set(event.attachmentIDs).count == event.attachmentIDs.count,
              let index = nativeAttachmentPayloads.firstIndex(where: {
                  $0.revision == event.revision && $0.sessionID == event.sessionID
              }) else {
            return
        }

        let payload = nativeAttachmentPayloads[index]
        let reportedIDs = Set(event.attachmentIDs)
        let currentIDs = Set(payload.attachments.map(\.id))

        switch event.kind {
        case .accepted:
            // A user removal may race a late queue acknowledgement. Only mark the
            // still-live subset accepted; never recreate attachments already removed.
            guard currentIDs.isSubset(of: reportedIDs),
                  payload.deliveryState != .accepted else {
                return
            }
            var updated = nativeAttachmentPayloads
            updated[index] = NativeAttachmentPayload(
                revision: payload.revision,
                sessionID: payload.sessionID,
                attachments: payload.attachments,
                deliveryState: .accepted
            )
            nativeAttachmentPayloads = updated

        case .removed:
            guard !currentIDs.isDisjoint(with: reportedIDs) else { return }
            let remaining = payload.attachments.filter { !reportedIDs.contains($0.id) }
            var updated = nativeAttachmentPayloads
            if remaining.isEmpty {
                updated.remove(at: index)
            } else {
                updated[index] = NativeAttachmentPayload(
                    revision: payload.revision,
                    sessionID: payload.sessionID,
                    attachments: remaining,
                    deliveryState: payload.deliveryState
                )
            }
            nativeAttachmentPayloads = updated
        }
    }

    func clearDropError() {
        dropError = nil
    }

    @discardableResult
    func importFile(at source: URL) throws -> ManagedArtifact {
        try prepareDirectoriesThrowing()
        let didAccess = source.startAccessingSecurityScopedResource()
        defer {
            if didAccess { source.stopAccessingSecurityScopedResource() }
        }

        let values = try source.resourceValues(forKeys: [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isAliasFileKey,
            .isPackageKey,
            .fileSizeKey,
            .nameKey
        ])
        guard values.isRegularFile == true,
              values.isDirectory != true,
              values.isSymbolicLink != true,
              values.isAliasFile != true,
              values.isPackage != true else {
            throw ArtifactError.notARegularFile
        }
        let byteCount = Int64(values.fileSize ?? 0)
        guard byteCount <= Self.maximumImportBytes else {
            throw ArtifactError.tooLarge(maximumBytes: Self.maximumImportBytes)
        }

        let itemID = UUID().uuidString.lowercased()
        let itemDirectory = Self.inboxURL.appendingPathComponent(itemID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: itemDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let safeName = Self.safeFilename(values.name ?? source.lastPathComponent)
        let destination = itemDirectory.appendingPathComponent(safeName, isDirectory: false)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            let metadata = ImportMetadata(
                id: itemID,
                originalName: source.lastPathComponent,
                importedAt: ISO8601DateFormatter().string(from: Date()),
                byteCount: byteCount
            )
            let metadataData = try JSONEncoder.pretty.encode(metadata)
            try metadataData.write(
                to: itemDirectory.appendingPathComponent("metadata.json"),
                options: [.atomic]
            )
        } catch {
            try? FileManager.default.removeItem(at: itemDirectory)
            throw error
        }

        NotificationCenter.default.post(name: .deepSeekArtifactsDidChange, object: nil)
        return Self.makeArtifact(url: destination, root: Self.rootURL) ?? ManagedArtifact(
            id: itemID,
            url: destination,
            relativePath: "Inbox/\(itemID)/\(safeName)",
            displayName: safeName,
            byteCount: byteCount,
            modifiedAt: Date(),
            kind: Self.kind(for: destination)
        )
    }

    func refresh() {
        prepareDirectories()
        let roots = [Self.inboxURL, Self.appshotsURL, Self.exportsURL]
        var discovered: [ManagedArtifact] = []

        for directory in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .fileSizeKey,
                    .contentModificationDateKey
                ],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                let name = url.lastPathComponent.lowercased()
                if name == "metadata.json" || name == "preview.png" { continue }
                if let artifact = Self.makeArtifact(url: url, root: Self.rootURL) {
                    discovered.append(artifact)
                }
            }
        }

        artifacts = discovered.sorted {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }

        if let selectedArtifactID,
           !artifacts.contains(where: { $0.id == selectedArtifactID }) {
            self.selectedArtifactID = artifacts.first?.id
        } else if self.selectedArtifactID == nil {
            self.selectedArtifactID = artifacts.first?.id
        }
    }

    func reveal(_ artifact: ManagedArtifact) {
        NSWorkspace.shared.activateFileViewerSelecting([artifact.url])
    }

    func open(_ artifact: ManagedArtifact) {
        NSWorkspace.shared.open(artifact.url)
    }

    private func prepareDirectories() {
        do {
            try prepareDirectoriesThrowing()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func prepareDirectoriesThrowing() throws {
        for directory in [Self.inboxURL, Self.appshotsURL, Self.rendersURL, Self.exportsURL] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    private nonisolated static func makeArtifact(url: URL, root: URL) -> ManagedArtifact? {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]), values.isRegularFile == true else { return nil }

        let standardizedRoot = root.standardizedFileURL.path
        let standardizedPath = url.standardizedFileURL.path
        guard standardizedPath.hasPrefix(standardizedRoot + "/") else { return nil }
        let relative = String(standardizedPath.dropFirst(standardizedRoot.count + 1))
        let components = relative.split(separator: "/")
        let id = components.count > 1 ? String(components[1]) : relative
        let isAppshot = relative.hasPrefix("Appshots/")

        return ManagedArtifact(
            id: isAppshot ? "appshot:\(id)" : relative,
            url: url,
            relativePath: relative,
            displayName: isAppshot && url.lastPathComponent == "context.md"
                ? "Appshot · \(id)"
                : url.lastPathComponent,
            byteCount: Int64(values.fileSize ?? 0),
            modifiedAt: values.contentModificationDate ?? .distantPast,
            kind: isAppshot ? .appshot : kind(for: url)
        )
    }

    private struct DropImportResult: Sendable {
        var imported: [ManagedArtifact] = []
        var errors: [String] = []
    }

    private static func uniqueFileURLs(_ sources: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for source in sources where source.isFileURL {
            let normalized = source.standardizedFileURL.path
            guard seen.insert(normalized).inserted else { continue }
            result.append(source)
        }
        return result
    }

    private nonisolated static func importDropBatch(_ sources: [URL]) -> DropImportResult {
        var result = DropImportResult()
        var prepared: [(source: URL, values: URLResourceValues, byteCount: Int64)] = []
        var totalBytes: Int64 = 0
        var resolvedSources = Set<String>()

        do {
            try prepareDirectoriesForBackgroundImport()
        } catch {
            result.errors.append("无法准备本地研究文件目录：\(error.localizedDescription)")
            return result
        }

        for original in sources {
            do {
                let source = try resolveDroppedSource(original)
                guard resolvedSources.insert(source.standardizedFileURL.path).inserted else {
                    continue
                }
                let values = try source.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .isAliasFileKey,
                    .isPackageKey,
                    .fileSizeKey,
                    .nameKey
                ])
                guard values.isRegularFile == true,
                      values.isDirectory != true,
                      values.isSymbolicLink != true,
                      values.isAliasFile != true,
                      values.isPackage != true else {
                    throw ArtifactError.notARegularFile
                }
                let byteCount = Int64(values.fileSize ?? 0)
                guard byteCount <= maximumImportBytes else {
                    throw ArtifactError.tooLarge(maximumBytes: maximumImportBytes)
                }
                let (nextTotal, overflow) = totalBytes.addingReportingOverflow(byteCount)
                guard !overflow, nextTotal <= maximumDropBatchBytes else {
                    throw ArtifactError.batchTooLarge(maximumBytes: maximumDropBatchBytes)
                }
                totalBytes = nextTotal
                prepared.append((source, values, byteCount))
            } catch {
                result.errors.append("\(original.lastPathComponent)：\(error.localizedDescription)")
            }
        }

        if result.errors.contains(where: { $0.contains("整批文件超过") }) {
            return result
        }

        for item in prepared {
            let source = item.source
            let didAccess = source.startAccessingSecurityScopedResource()
            defer {
                if didAccess { source.stopAccessingSecurityScopedResource() }
            }

            let itemID = UUID().uuidString.lowercased()
            let itemDirectory = inboxURL.appendingPathComponent(itemID, isDirectory: true)
            let partialDirectory = inboxURL.appendingPathComponent(".\(itemID).partial", isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: partialDirectory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                let safeName = safeFilename(item.values.name ?? source.lastPathComponent)
                let partialFile = partialDirectory.appendingPathComponent(safeName)
                try FileManager.default.copyItem(at: source, to: partialFile)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: partialFile.path
                )

                let copiedValues = try partialFile.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .fileSizeKey
                ])
                guard copiedValues.isRegularFile == true,
                      Int64(copiedValues.fileSize ?? -1) == item.byteCount else {
                    throw ArtifactError.sourceChangedDuringCopy
                }

                let metadata = ImportMetadata(
                    id: itemID,
                    originalName: source.lastPathComponent,
                    importedAt: ISO8601DateFormatter().string(from: Date()),
                    byteCount: item.byteCount
                )
                let metadataURL = partialDirectory.appendingPathComponent("metadata.json")
                try JSONEncoder.pretty.encode(metadata).write(to: metadataURL, options: [.atomic])
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: metadataURL.path
                )
                try FileManager.default.moveItem(at: partialDirectory, to: itemDirectory)

                let destination = itemDirectory.appendingPathComponent(safeName)
                let artifact = makeArtifact(url: destination, root: rootURL) ?? ManagedArtifact(
                    id: "Inbox/\(itemID)/\(safeName)",
                    url: destination,
                    relativePath: "Inbox/\(itemID)/\(safeName)",
                    displayName: safeName,
                    byteCount: item.byteCount,
                    modifiedAt: Date(),
                    kind: kind(for: destination)
                )
                result.imported.append(artifact)
            } catch {
                try? FileManager.default.removeItem(at: partialDirectory)
                try? FileManager.default.removeItem(at: itemDirectory)
                result.errors.append("\(source.lastPathComponent)：\(error.localizedDescription)")
            }
        }

        return result
    }

    private nonisolated static func prepareDirectoriesForBackgroundImport() throws {
        for directory in [inboxURL, appshotsURL, rendersURL, exportsURL] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    private nonisolated static func resolveDroppedSource(_ source: URL) throws -> URL {
        let values = try source.resourceValues(forKeys: [
            .isAliasFileKey,
            .isSymbolicLinkKey
        ])
        if values.isSymbolicLink == true {
            throw ArtifactError.symbolicLink
        }
        guard values.isAliasFile == true else { return source }
        return try URL(
            resolvingAliasFileAt: source,
            options: [.withoutUI, .withoutMounting]
        )
    }

    private nonisolated static func safeFilename(_ original: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\\0")
            .union(.newlines)
            .union(.controlCharacters)
        var safe = original.components(separatedBy: forbidden).joined(separator: "_")
        safe = safe.trimmingCharacters(in: .whitespacesAndNewlines)
        while safe.hasPrefix(".") {
            safe.removeFirst()
        }
        if safe.isEmpty || safe == "." || safe == ".." {
            safe = "imported-file"
        }
        let reserved = Set(["metadata.json", "preview.png"])
        if reserved.contains(safe.lowercased()) {
            safe = "imported-\(safe)"
        }
        return truncateFilename(safe, maximumUTF8Bytes: 180)
    }

    private nonisolated static func truncateFilename(_ filename: String, maximumUTF8Bytes: Int) -> String {
        guard filename.utf8.count > maximumUTF8Bytes else { return filename }
        let nsName = filename as NSString
        let ext = nsName.pathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        let suffixBytes = suffix.utf8.count
        if suffixBytes >= maximumUTF8Bytes {
            return utf8Prefix(filename, maximumBytes: maximumUTF8Bytes)
        }
        let stemBudget = max(1, maximumUTF8Bytes - suffixBytes)
        let stem = utf8Prefix(nsName.deletingPathExtension, maximumBytes: stemBudget)
        return stem.isEmpty ? "imported-file\(suffix)" : "\(stem)\(suffix)"
    }

    private nonisolated static func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        var result = ""
        var byteCount = 0
        for character in value {
            let nextBytes = String(character).utf8.count
            guard byteCount + nextBytes <= maximumBytes else { break }
            result.append(character)
            byteCount += nextBytes
        }
        return result
    }

    private nonisolated static func kind(for url: URL) -> ManagedArtifact.Kind {
        switch url.pathExtension.lowercased() {
        case "pdf": return .pdf
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp": return .image
        case "doc", "docx", "odt", "rtf": return .document
        case "xls", "xlsx", "ods": return .spreadsheet
        case "ppt", "pptx", "odp", "key": return .presentation
        case "txt", "md", "markdown", "csv", "tsv", "json", "xml", "yaml", "yml",
             "swift", "py", "js", "ts", "tsx", "jsx", "c", "cc", "cpp", "h", "hpp",
             "java", "kt", "go", "rs", "rb", "php", "sh", "zsh", "tex": return .text
        default: return .other
        }
    }

    private struct ImportMetadata: Codable {
        let id: String
        let originalName: String
        let importedAt: String
        let byteCount: Int64
    }

    private enum ArtifactError: LocalizedError {
        case notARegularFile
        case symbolicLink
        case tooLarge(maximumBytes: Int64)
        case batchTooLarge(maximumBytes: Int64)
        case sourceChangedDuringCopy

        var errorDescription: String? {
            switch self {
            case .notARegularFile:
                return "只能导入普通文件，不能导入文件夹或应用软件包。"
            case .symbolicLink:
                return "不接受符号链接；请拖入链接指向的原文件。"
            case .tooLarge(let maximumBytes):
                return "文件超过 \(ByteCountFormatter.string(fromByteCount: maximumBytes, countStyle: .file)) 上限。"
            case .batchTooLarge(let maximumBytes):
                return "整批文件超过 \(ByteCountFormatter.string(fromByteCount: maximumBytes, countStyle: .file)) 上限。"
            case .sourceChangedDuringCopy:
                return "复制期间文件发生变化，请稍后重新拖入。"
            }
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
