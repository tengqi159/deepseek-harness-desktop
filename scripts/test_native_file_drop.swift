import Foundation

private enum QAFailure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let message): return message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw QAFailure.message(message) }
}

private func write(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url, options: [.atomic])
}

@main
struct NativeFileDropQA {
    static func main() async throws {
        guard let rootPath = ProcessInfo.processInfo.environment["DSH_ARTIFACT_STORE_ROOT"],
              !rootPath.isEmpty else {
            throw QAFailure.message("DSH_ARTIFACT_STORE_ROOT is required")
        }

        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let sources = root.appendingPathComponent("sources", isDirectory: true)
        try fileManager.createDirectory(at: sources, withIntermediateDirectories: true)

        let notes = sources.appendingPathComponent("notes.md")
        let paper = sources.appendingPathComponent("paper.pdf")
        let reservedMetadata = sources.appendingPathComponent("metadata.json")
        let reservedPreview = sources.appendingPathComponent("preview.png")
        let hidden = sources.appendingPathComponent(".hidden.py")
        try write("# Drop QA\nresearch note\n", to: notes)
        try Data("%PDF-1.4\n% drop fixture\n".utf8).write(to: paper)
        try write("{\"source\":\"user\"}\n", to: reservedMetadata)
        try write("not an image", to: reservedPreview)
        try write("print('safe')\n", to: hidden)

        let directory = sources.appendingPathComponent("folder", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let symbolicLink = sources.appendingPathComponent("notes-link.md")
        try fileManager.createSymbolicLink(at: symbolicLink, withDestinationURL: notes)

        let oversized = sources.appendingPathComponent("oversized.bin")
        fileManager.createFile(atPath: oversized.path, contents: Data())
        let oversizedHandle = try FileHandle(forWritingTo: oversized)
        try oversizedHandle.truncate(atOffset: UInt64(ArtifactStore.maximumImportBytes + 1))
        try oversizedHandle.close()

        let store = await MainActor.run { ArtifactStore() }
        await MainActor.run {
            store.importDroppedFiles([
                notes,
                notes,
                paper,
                reservedMetadata,
                reservedPreview,
                hidden,
                directory,
                symbolicLink,
                oversized
            ], targetSessionID: "session-A")
        }

        let deadline = Date().addingTimeInterval(15)
        while await MainActor.run(body: { store.isImportingDroppedFiles }) {
            if Date() > deadline { throw QAFailure.message("drop import timed out") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let payload = await MainActor.run { store.nativeAttachmentPayloads.last }
        let error = await MainActor.run { store.dropError }
        guard let payload else { throw QAFailure.message("no native attachment payload") }

        let firstRevision = payload.revision
        try require(firstRevision >= 1, "unexpected payload revision")
        try require(
            firstRevision < ArtifactStore.maximumJavaScriptSafeInteger,
            "payload revision is not JavaScript-safe"
        )
        try require(payload.sessionID == "session-A", "drop-time session identity was not preserved")
        try require(payload.deliveryState == .pending, "new native payload must begin pending")
        try require(payload.attachments.count == 5, "expected five successful unique files")
        let names = Set(payload.attachments.map(\.displayName))
        try require(names.contains("notes.md"), "Markdown file missing")
        try require(names.contains("paper.pdf"), "PDF file missing")
        try require(names.contains("imported-metadata.json"), "reserved metadata name was not rewritten")
        try require(names.contains("imported-preview.png"), "reserved preview name was not rewritten")
        try require(names.contains("hidden.py"), "leading-dot filename was not made visible")
        try require(payload.attachments.allSatisfy { $0.id == $0.relativePath }, "payload identity/path mismatch")
        try require(payload.attachments.allSatisfy { $0.relativePath.hasPrefix("Inbox/") }, "unmanaged path escaped payload")

        try require(error?.contains("folder") == true, "directory rejection was not reported")
        try require(error?.contains("notes-link.md") == true, "symbolic-link rejection was not reported")
        try require(error?.contains("oversized.bin") == true, "oversized-file rejection was not reported")

        for attachment in payload.attachments {
            let file = ArtifactStore.rootURL.appendingPathComponent(attachment.relativePath)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            try require(values.isRegularFile == true, "published attachment is not a regular file")
            let mode = try fileManager.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            try require(mode?.intValue == 0o600, "published attachment permissions are not 0600")
        }

        let inboxItems = try fileManager.contentsOfDirectory(
            at: ArtifactStore.inboxURL,
            includingPropertiesForKeys: nil
        )
        try require(!inboxItems.contains(where: { $0.lastPathComponent.hasSuffix(".partial") }), "partial import directory leaked")

        let object = payload.javaScriptObject
        try require(object["version"] as? Int == 1, "JavaScript payload version missing")
        try require(object["sessionId"] as? String == "session-A", "JavaScript session identity missing")
        try require((object["attachments"] as? [[String: Any]])?.count == 5, "JavaScript payload attachment count mismatch")

        let firstAttachmentIDs = payload.attachments.map(\.id)
        await MainActor.run {
            store.handleNativeAttachmentLifecycle(
                NativeAttachmentLifecycleEvent(
                    kind: .accepted,
                    revision: payload.revision,
                    sessionID: payload.sessionID,
                    attachmentIDs: firstAttachmentIDs
                )
            )
        }
        let acceptedPayload = await MainActor.run { store.nativeAttachmentPayloads.first }
        try require(acceptedPayload?.deliveryState == .accepted, "lifecycle ACK did not promote payload")

        let removedAttachmentID = firstAttachmentIDs[0]
        await MainActor.run {
            store.handleNativeAttachmentLifecycle(
                NativeAttachmentLifecycleEvent(
                    kind: .removed,
                    revision: payload.revision,
                    sessionID: payload.sessionID,
                    attachmentIDs: [removedAttachmentID]
                )
            )
        }
        let partiallyRemovedPayload = await MainActor.run { store.nativeAttachmentPayloads.first }
        try require(partiallyRemovedPayload?.attachments.count == 4, "removed attachment stayed in native replay state")
        try require(
            partiallyRemovedPayload?.attachments.contains(where: { $0.id == removedAttachmentID }) == false,
            "removed attachment was not tombstoned"
        )

        // A late queue ACK must never reintroduce a user-removed attachment.
        await MainActor.run {
            store.handleNativeAttachmentLifecycle(
                NativeAttachmentLifecycleEvent(
                    kind: .accepted,
                    revision: payload.revision,
                    sessionID: payload.sessionID,
                    attachmentIDs: firstAttachmentIDs
                )
            )
        }
        let afterLateAcceptance = await MainActor.run { store.nativeAttachmentPayloads.first }
        try require(afterLateAcceptance?.attachments.count == 4, "late ACK resurrected a removed attachment")

        let second = sources.appendingPathComponent("second.txt")
        try write("second batch\n", to: second)
        await MainActor.run {
            store.importDroppedFiles([second], targetSessionID: "session-B")
        }
        let secondDeadline = Date().addingTimeInterval(15)
        while await MainActor.run(body: { store.isImportingDroppedFiles }) {
            if Date() > secondDeadline { throw QAFailure.message("second drop import timed out") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let queuedPayloads = await MainActor.run { store.nativeAttachmentPayloads }
        try require(queuedPayloads.count == 2, "consecutive drop payloads were not retained as FIFO")
        try require(
            queuedPayloads.map(\.revision) == [firstRevision, firstRevision + 1],
            "FIFO revisions are out of order"
        )
        try require(queuedPayloads.map(\.sessionID) == ["session-A", "session-B"], "drop-time sessions drifted")

        let remainingFirstIDs = queuedPayloads[0].attachments.map(\.id)
        await MainActor.run {
            store.handleNativeAttachmentLifecycle(
                NativeAttachmentLifecycleEvent(
                    kind: .removed,
                    revision: firstRevision,
                    sessionID: "session-A",
                    attachmentIDs: remainingFirstIDs
                )
            )
            store.handleNativeAttachmentLifecycle(
                NativeAttachmentLifecycleEvent(
                    kind: .accepted,
                    revision: firstRevision,
                    sessionID: "session-A",
                    attachmentIDs: firstAttachmentIDs
                )
            )
        }
        let afterRemoveWins = await MainActor.run { store.nativeAttachmentPayloads }
        try require(
            afterRemoveWins.map(\.revision) == [firstRevision + 1],
            "remove did not win over a late lifecycle ACK"
        )

        let pastedPNG = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        let pasteStore = await MainActor.run { ArtifactStore() }
        await MainActor.run {
            pasteStore.importPastedImageData(
                pastedPNG,
                fileExtension: "png",
                targetSessionID: "paste-session"
            )
        }
        let pasteDeadline = Date().addingTimeInterval(15)
        while await MainActor.run(body: { pasteStore.isImportingDroppedFiles }) {
            if Date() > pasteDeadline { throw QAFailure.message("clipboard image import timed out") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let pastedPayload = await MainActor.run(body: {
            pasteStore.nativeAttachmentPayloads.last
        }) else {
            throw QAFailure.message("clipboard image did not create an attachment payload")
        }
        try require(pastedPayload.sessionID == "paste-session", "clipboard image lost its session")
        try require(pastedPayload.attachments.count == 1, "clipboard image was imported more than once")
        try require(
            pastedPayload.attachments[0].displayName == "pasted-image.png",
            "clipboard image filename changed"
        )
        let pastedFile = ArtifactStore.rootURL.appendingPathComponent(
            pastedPayload.attachments[0].relativePath
        )
        let pastedFileData = try Data(contentsOf: pastedFile)
        try require(pastedFileData == pastedPNG, "clipboard image bytes changed")
        let pastedMode = try fileManager.attributesOfItem(atPath: pastedFile.path)[.posixPermissions]
            as? NSNumber
        try require(pastedMode?.intValue == 0o600, "clipboard image permissions are not 0600")

        let limitStore = await MainActor.run { ArtifactStore() }
        var limitSources: [URL] = []
        for index in 1...33 {
            let source = sources.appendingPathComponent("pending-\(index).txt")
            try write("pending \(index)\n", to: source)
            limitSources.append(source)
        }
        for source in limitSources.prefix(32) {
            await MainActor.run {
                limitStore.importDroppedFiles([source], targetSessionID: "limit-session")
            }
            let deadline = Date().addingTimeInterval(15)
            while await MainActor.run(body: { limitStore.isImportingDroppedFiles }) {
                if Date() > deadline { throw QAFailure.message("pending-limit import timed out") }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        let fullPendingQueue = await MainActor.run { limitStore.nativeAttachmentPayloads }
        try require(fullPendingQueue.count == 32, "pending payload queue did not reach its exact bound")
        try require(fullPendingQueue.allSatisfy { $0.deliveryState == .pending }, "pending-limit fixture drifted")
        guard let limitFirstRevision = fullPendingQueue.first?.revision else {
            throw QAFailure.message("pending-limit queue lost its first revision")
        }

        await MainActor.run {
            limitStore.importDroppedFiles([limitSources[32]], targetSessionID: "limit-session")
        }
        let rejectedImporting = await MainActor.run { limitStore.isImportingDroppedFiles }
        let rejectedError = await MainActor.run { limitStore.dropError }
        let rejectedRevisions = await MainActor.run { limitStore.nativeAttachmentPayloads.map(\.revision) }
        try require(!rejectedImporting, "a 33rd unresolved payload unexpectedly started importing")
        try require(rejectedError?.contains("32 批") == true, "pending-limit rejection was not reported")
        try require(
            rejectedRevisions == Array(limitFirstRevision...(limitFirstRevision + 31)),
            "a rejected 33rd payload evicted an unresolved predecessor"
        )

        await MainActor.run {
            limitStore.handleNativeAttachmentLifecycle(
                NativeAttachmentLifecycleEvent(
                    kind: .accepted,
                    revision: limitFirstRevision,
                    sessionID: "limit-session",
                    attachmentIDs: fullPendingQueue[0].attachments.map(\.id)
                )
            )
            limitStore.importDroppedFiles([limitSources[32]], targetSessionID: "limit-session")
        }
        let acceptedTrimDeadline = Date().addingTimeInterval(15)
        while await MainActor.run(body: { limitStore.isImportingDroppedFiles }) {
            if Date() > acceptedTrimDeadline { throw QAFailure.message("accepted-history trim import timed out") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let afterAcceptedTrim = await MainActor.run { limitStore.nativeAttachmentPayloads }
        try require(afterAcceptedTrim.count == 32, "accepted replay history was not bounded")
        try require(
            afterAcceptedTrim.map(\.revision)
                == Array((limitFirstRevision + 1)...(limitFirstRevision + 32)),
            "pending payload was evicted before accepted history"
        )

        print("NATIVE_FILE_DROP_QA_OK attachments=7 partial_failures=3 fifo_batches=2 clipboard_image=1")
    }
}
