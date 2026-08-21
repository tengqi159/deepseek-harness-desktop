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
    static let supportedVersion = "0.1.1-rc.2"
    static let supportedSHA256 = "c0226687bb20f45c603ec6fe50f3de16d1c3510c3a803304ec575ef9bc366c62"

    private struct VerifiedDependency {
        let relativePath: String
        let sha256: String
    }

    // The launcher and persistent-shell prompt fix remain byte-identical in
    // rc.2. Pin them and the newer DeepSeek adapter's image serializer so a
    // locally edited node_modules tree cannot satisfy a launcher-only check.
    private static let verifiedDependencies = [
        VerifiedDependency(
            relativePath: "node_modules/@deepseek-ai/dsh-terminal-bash/lib/index.js",
            sha256: "3585f6db352babc2df9768337261445a93033f3cdf212b2a54aefc3b83506f83"
        ),
        VerifiedDependency(
            relativePath: "node_modules/@deepseek-ai/dsh-tool-bash-persistent/lib/index.js",
            sha256: "0a35823964f5c4c3afe8a847dcd99eebbaae07c87198d51ee74aaf3866b6b609"
        ),
        VerifiedDependency(
            relativePath: "node_modules/@deepseek-ai/dsh-llm-deepseek/lib/index.js",
            sha256: "eed9492246cc6451f060de211768d3128388046478deae7f1959de7cde56ea82"
        ),
    ]

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

            let runtimeRoot = resolved
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            if let dependencyFailure = dependencyIntegrityFailure(in: runtimeRoot) {
                rejected.append("\(candidate.path)：\(dependencyFailure)")
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

    private static func dependencyIntegrityFailure(in runtimeRoot: URL) -> String? {
        for dependency in verifiedDependencies {
            let file = runtimeRoot
                .appendingPathComponent(dependency.relativePath)
                .resolvingSymlinksInPath()
            guard let digest = sha256(of: file) else {
                return "缺少已验证的运行时依赖 \(dependency.relativePath)"
            }
            guard digest == dependency.sha256 else {
                return "运行时依赖 \(dependency.relativePath) 的内容与官方 \(supportedVersion) 不一致"
            }
        }
        return nil
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
