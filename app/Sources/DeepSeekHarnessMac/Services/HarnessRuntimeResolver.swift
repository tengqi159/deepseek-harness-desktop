import CryptoKit
import Foundation

struct HarnessRuntime {
    let executableURL: URL
    let version: String
    let sha256: String

    var binDirectory: String {
        executableURL.deletingLastPathComponent().path
    }
}

enum HarnessRuntimeResolution {
    case available(HarnessRuntime)
    case unavailable(String)
}

enum HarnessRuntimeResolver {
    static let supportedVersion = "0.1.0-rc.6"
    static let supportedSHA256 = "c0226687bb20f45c603ec6fe50f3de16d1c3510c3a803304ec575ef9bc366c62"

    static func resolve() -> HarnessRuntimeResolution {
        var rejected: [String] = []
        for candidate in candidates() {
            guard FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }

            let resolved = candidate.resolvingSymlinksInPath()
            guard let digest = sha256(of: resolved) else {
                rejected.append("\(candidate.path)：无法校验文件完整性")
                continue
            }
            guard digest == supportedSHA256 else {
                rejected.append("\(candidate.path)：文件来源或内容与已验证版本不一致")
                continue
            }
            guard let version = version(of: candidate) else {
                rejected.append("\(candidate.path)：无法读取版本")
                continue
            }
            guard version == supportedVersion else {
                rejected.append("\(candidate.path)：版本 \(version) 尚未通过兼容测试")
                continue
            }

            return .available(
                HarnessRuntime(
                    executableURL: candidate,
                    version: version,
                    sha256: digest
                )
            )
        }

        if let first = rejected.first {
            return .unavailable(
                "检测到 dsh，但为了防止预览版更新破坏本地功能，已停止启动。\n\(first)\n" +
                "当前已验证版本：\(supportedVersion)。请通过 App 的兼容检查更新后再使用。"
            )
        }
        return .unavailable(
            "未找到官方 dsh。请安装已验证版本：\n" +
            "npm install -g @deepseek-ai/dsh@\(supportedVersion) --registry=https://registry.npmjs.org"
        )
    }

    private static func candidates() -> [URL] {
        var values: [URL] = []
#if DEBUG
        if let override = ProcessInfo.processInfo.environment["DSH_BIN"], !override.isEmpty {
            values.append(URL(fileURLWithPath: override))
        }
#endif
        values += nvmCandidates()
        values += conventionalCandidates()

        var seen = Set<String>()
        return values.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func nvmCandidates() -> [URL] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nvm/versions/node", isDirectory: true)
        guard let versions = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return versions
            .sorted {
                $0.lastPathComponent.compare(
                    $1.lastPathComponent,
                    options: .numeric
                ) == .orderedDescending
            }
            .map { $0.appendingPathComponent("bin/dsh") }
    }

    private static func conventionalCandidates() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/opt/homebrew/bin/dsh"),
            URL(fileURLWithPath: "/usr/local/bin/dsh"),
            home.appendingPathComponent(".local/bin/dsh"),
            home.appendingPathComponent(".volta/bin/dsh")
        ]
    }

    private static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func version(of executable: URL) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.standardOutput = pipe
        process.standardError = pipe
        process.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": executable.deletingLastPathComponent().path
                + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        ]
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
