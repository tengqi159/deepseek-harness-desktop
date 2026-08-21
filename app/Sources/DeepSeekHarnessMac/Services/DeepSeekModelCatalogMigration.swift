import Foundation

/// Keeps the companion's one verified DeepSeek Vision catalog entry usable
/// when an existing `settings.yaml` overrides the bundled profile catalog.
///
/// The upstream adapter deliberately treats an omitted `inputModalities` as
/// text-only. We therefore edit only the exact model record below; this never
/// turns an entire provider (or any other model) into a vision route.
enum DeepSeekModelCatalogMigration {
    static let visionModelID = "deepseek-v4-flash-vision-exp"
    private static let backupName = "settings.before-deepseek-flash-vision.yaml"
    private static let maximumSettingsBytes = 1 * 1_024 * 1_024

    /// Applies a narrowly scoped, atomic migration. An absent settings file,
    /// no DeepSeek model list, or an unfamiliar YAML layout is intentionally a
    /// no-op: the bundled profile catalog remains the safe default in those
    /// cases.
    @discardableResult
    static func reconcile(settingsAt url: URL, fileManager: FileManager = .default) throws -> Bool {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size >= 0,
              size <= maximumSettingsBytes,
              let original = String(data: try Data(contentsOf: url), encoding: .utf8),
              let migrated = reconciledSettings(original),
              migrated != original else {
            return false
        }

        let backup = url.deletingLastPathComponent().appendingPathComponent(backupName)
        if !fileManager.fileExists(atPath: backup.path) {
            try fileManager.copyItem(at: url, to: backup)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        try Data(migrated.utf8).write(to: url, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }

    /// A deliberately small YAML transformation for the stable settings
    /// structure written by Harness. It avoids a lossy YAML round-trip and
    /// returns `nil` rather than guessing when the required section is absent.
    static func reconciledSettings(_ original: String) -> String? {
        var lines = original.components(separatedBy: "\n")
        guard let deepSeekStart = lines.firstIndex(where: isDeepSeekRoot) else {
            return nil
        }

        let deepSeekEnd = sectionEnd(in: lines, after: deepSeekStart, indent: 0)
        guard let modelsIndex = (deepSeekStart + 1..<deepSeekEnd).first(where: {
            indentation(of: lines[$0]) > 0 && trimmed(lines[$0]).hasPrefix("models:")
        }) else {
            return nil
        }

        let modelsIndent = indentation(of: lines[modelsIndex])
        let modelsEnd = sectionEnd(in: lines, after: modelsIndex, indent: modelsIndent)
        let modelIndices = (modelsIndex + 1..<modelsEnd).filter {
            isModelStart(lines[$0])
        }
        let modelIndent = modelIndices.first.map { indentation(of: lines[$0]) } ?? (modelsIndent + 2)

        guard let targetStart = modelIndices.first(where: {
            modelID(in: lines[$0]) == visionModelID
        }) else {
            let fieldIndent = String(repeating: " ", count: modelIndent + 2)
            let itemIndent = String(repeating: " ", count: modelIndent)
            lines.insert(contentsOf: [
                "\(itemIndent)- id: \(visionModelID)",
                "\(fieldIndent)name: DeepSeek-V4-Flash Vision",
                "\(fieldIndent)contextWindow: 1000000",
                "\(fieldIndent)inputModalities: [text, image]"
            ], at: modelsEnd)
            return lines.joined(separator: "\n")
        }

        let targetEnd = modelEnd(in: lines, after: targetStart, modelsEnd: modelsEnd, modelIndent: indentation(of: lines[targetStart]))
        let fieldIndent = indentation(of: lines[targetStart]) + 2
        let directFields = (targetStart + 1..<targetEnd).filter {
            indentation(of: lines[$0]) == fieldIndent && trimmed(lines[$0]).hasPrefix("inputModalities:")
        }

        if let modalitiesIndex = directFields.first {
            let existing = trimmed(lines[modalitiesIndex])
            if existing.contains("text") && existing.contains("image") {
                return original
            }

            lines[modalitiesIndex] = String(repeating: " ", count: fieldIndent) + "inputModalities: [text, image]"
            let continuation = modalitiesIndex + 1
            var remainingOriginalLines = targetEnd - continuation
            while remainingOriginalLines > 0, continuation < lines.count {
                let line = lines[continuation]
                let indent = indentation(of: line)
                let content = trimmed(line)
                if indent <= fieldIndent && !content.isEmpty && !content.hasPrefix("#") {
                    break
                }
                if indent > fieldIndent || content.isEmpty || content.hasPrefix("#") {
                    lines.remove(at: continuation)
                    remainingOriginalLines -= 1
                    continue
                }
                break
            }
            return lines.joined(separator: "\n")
        }

        lines.insert(
            String(repeating: " ", count: fieldIndent) + "inputModalities: [text, image]",
            at: targetStart + 1
        )
        return lines.joined(separator: "\n")
    }

    private static func isDeepSeekRoot(_ line: String) -> Bool {
        indentation(of: line) == 0 && trimmed(line).hasPrefix("llm-deepseek:")
    }

    private static func isModelStart(_ line: String) -> Bool {
        trimmed(line).hasPrefix("- id:")
    }

    private static func modelID(in line: String) -> String? {
        let prefix = "- id:"
        let value = trimmed(line)
        guard value.hasPrefix(prefix) else { return nil }
        let candidate = value.dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespaces)
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidate, !candidate.isEmpty else { return nil }
        return candidate.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private static func sectionEnd(in lines: [String], after start: Int, indent: Int) -> Int {
        for index in (start + 1)..<lines.count {
            let content = trimmed(lines[index])
            guard !content.isEmpty, !content.hasPrefix("#") else { continue }
            if indentation(of: lines[index]) <= indent {
                return index
            }
        }
        return lines.count
    }

    private static func modelEnd(in lines: [String], after start: Int, modelsEnd: Int, modelIndent: Int) -> Int {
        for index in (start + 1)..<modelsEnd {
            let content = trimmed(lines[index])
            guard !content.isEmpty, !content.hasPrefix("#") else { continue }
            if indentation(of: lines[index]) == modelIndent && content.hasPrefix("- ") {
                return index
            }
        }
        return modelsEnd
    }

    private static func indentation(of line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    private static func trimmed(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }
}
