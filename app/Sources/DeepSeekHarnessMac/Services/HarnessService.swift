import AppKit
import Darwin
import Foundation

@MainActor
final class HarnessService: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case ready(URL)
        case failed(String)
    }

    enum PluginHealthState: Equatable {
        case checking
        case active
        case missing
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var statusMessage = "正在准备本地服务…"
    @Published private(set) var reloadToken = 0
    @Published private(set) var runtimeVersion: String?
    @Published private(set) var computerUsePluginHealth: PluginHealthState = .checking
    @Published private(set) var artifactsPluginHealth: PluginHealthState = .checking
    @Published private(set) var nativeAttachmentsPluginHealth: PluginHealthState = .checking

    private var process: Process?
    private var outputPipe: Pipe?
    private var pluginHealthTask: Task<Void, Never>?
    private var ownsProcess = false
    private var isStopping = false
    private var recentOutput = ""
    private var discoveredURL: URL?
    private var expectedWorkingDirectory: URL?

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    func start() async {
        guard state == .idle || isFailed else { return }

        state = .starting
        statusMessage = "正在准备本地 Harness…"
        computerUsePluginHealth = .checking
        artifactsPluginHealth = .checking
        nativeAttachmentsPluginHealth = .checking
        isStopping = false

        let runtime: HarnessRuntime
        switch HarnessRuntimeResolver.resolve() {
        case .available(let resolved):
            runtime = resolved
            runtimeVersion = resolved.version
        case .unavailable(let message):
            markPluginHealthUnavailable()
            state = .failed(message)
            return
        }

        statusMessage = "正在启动 DeepSeek Harness…"

        do {
            try launch(runtime: runtime)
        } catch {
            markPluginHealthUnavailable()
            state = .failed("启动失败：\(error.localizedDescription)")
            return
        }

        for _ in 0..<100 {
            if let url = discoveredURL,
               await probeHarness(at: url) {
                state = .ready(url)
                refreshPluginHealth()
                return
            }

            if let process, !process.isRunning {
                let detail = recentOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                markPluginHealthUnavailable()
                state = .failed(
                    detail.isEmpty
                        ? "Harness 进程提前退出，请确认 dsh 安装完整。"
                        : "Harness 进程提前退出：\n\(detail)"
                )
                return
            }

            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        stop()
        markPluginHealthUnavailable()
        state = .failed("Harness 在 30 秒内没有就绪，请检查网络代理或重新安装 dsh。")
    }

    func restart() async {
        stop()
        state = .idle
        try? await Task.sleep(nanoseconds: 350_000_000)
        await start()
    }

    func stop() {
        isStopping = true
        pluginHealthTask?.cancel()
        pluginHealthTask = nil
        computerUsePluginHealth = .checking
        artifactsPluginHealth = .checking
        nativeAttachmentsPluginHealth = .checking
        outputPipe?.fileHandleForReading.readabilityHandler = nil

        if ownsProcess, let process, process.isRunning {
            process.terminate()
        }

        self.process = nil
        outputPipe = nil
        ownsProcess = false
    }

    func reload() {
        guard isReady else { return }
        reloadToken += 1
    }

    func refreshPluginHealth() {
        guard case .ready(let baseURL) = state else {
            computerUsePluginHealth = .error("本地 Harness 尚未就绪")
            artifactsPluginHealth = .error("本地 Harness 尚未就绪")
            nativeAttachmentsPluginHealth = .error("本地 Harness 尚未就绪")
            return
        }

        pluginHealthTask?.cancel()
        computerUsePluginHealth = .checking
        artifactsPluginHealth = .checking
        nativeAttachmentsPluginHealth = .checking

        pluginHealthTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let entries = try await self.fetchPluginInventory(at: baseURL)
                try Task.checkCancellation()
                guard case .ready(let currentURL) = self.state,
                      currentURL == baseURL else { return }

                self.computerUsePluginHealth = self.pluginHealth(
                    entryID: "include:mcp-macos-computer-use",
                    entries: entries
                )
                self.artifactsPluginHealth = self.pluginHealth(
                    entryID: "include:mcp-artifacts",
                    entries: entries
                )
                self.nativeAttachmentsPluginHealth = self.pluginHealth(
                    entryID: "include:native-attachments",
                    entries: entries
                )
            } catch is CancellationError {
                return
            } catch {
                guard case .ready(let currentURL) = self.state,
                      currentURL == baseURL else { return }
                let detail = error.localizedDescription
                self.computerUsePluginHealth = .error(detail)
                self.artifactsPluginHealth = .error(detail)
                self.nativeAttachmentsPluginHealth = .error(detail)
            }
        }
    }

    func openInBrowser() {
        guard case .ready(let url) = state else { return }
        NSWorkspace.shared.open(url)
    }

    func reportWebViewFailure(_ message: String) {
        guard isReady else { return }
        markPluginHealthUnavailable()
        state = .failed("本地页面加载失败：\(message)")
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func launch(runtime: HarnessRuntime) throws {
        let process = Process()
        let outputPipe = Pipe()
        let workingDirectory = try defaultWorkingDirectory()
        let installation = try HarnessHomeInstaller.prepare()

        process.executableURL = runtime.executableURL
        process.arguments = [
            "web",
            "--patch", installation.integrationPatch.path,
            "--host", "127.0.0.1",
            "--port", "0"
        ]
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let inherited = ProcessInfo.processInfo.environment
        let allowedInheritedKeys = [
            "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR",
            "LANG", "LC_ALL", "LC_CTYPE", "TZ"
        ]
        var environment: [String: String] = [:]
        for key in allowedInheritedKeys {
            if let value = inherited[key] {
                environment[key] = value
            }
        }
        environment["PWD"] = workingDirectory.path
        environment["DSH_HOME"] = installation.home.path
        environment["DSH_APP_BRIDGE_BIN"] = installation.helperBinary.path
        environment["DSH_ARTIFACT_BRIDGE_BIN"] = installation.artifactHelperBinary.path
        environment["DSH_APP_BRIDGE_PARENT_PID"] = String(getpid())

        let standardPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = runtime.binDirectory + ":" + standardPath
        for (key, value) in SystemProxyEnvironment.values() {
            environment[key] = value
        }
        process.environment = environment

        recentOutput = ""
        discoveredURL = nil
        expectedWorkingDirectory = workingDirectory.standardizedFileURL
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }

            Task { @MainActor [weak self] in
                self?.appendOutput(text)
            }
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor [weak self] in
                guard let self,
                      self.process === terminatedProcess,
                      !self.isStopping else { return }

                if self.isReady {
                    self.markPluginHealthUnavailable()
                    self.state = .failed("本地 Harness 服务已停止，请点击“重试”。")
                }
            }
        }

        try process.run()
        self.process = process
        self.outputPipe = outputPipe
        ownsProcess = true
    }

    private func appendOutput(_ text: String) {
        recentOutput += text
        if recentOutput.count > 4_000 {
            recentOutput = String(recentOutput.suffix(4_000))
        }

        if discoveredURL == nil,
           let range = recentOutput.range(
               of: #"dsh web:\s+(http://127\.0\.0\.1:[0-9]+/?)(?:\r?\n|$)"#,
               options: .regularExpression
           ) {
            let readinessLine = String(recentOutput[range])
            let urlText = readinessLine
                .replacingOccurrences(of: "dsh web:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: urlText),
               url.scheme == "http",
               url.host == "127.0.0.1",
               let port = url.port,
               (1...65_535).contains(port) {
                discoveredURL = url
            }
        }

        if text.contains("dsh web:") {
            statusMessage = "正在连接本地界面…"
        }
    }

    private func defaultWorkingDirectory() throws -> URL {
        let fileManager = FileManager.default
        let workspace = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DeepSeek Harness/Workspace", isDirectory: true)

        do {
            try fileManager.createDirectory(
                at: workspace,
                withIntermediateDirectories: true
            )
            return workspace
        } catch {
            throw WorkspaceError.unavailable(error.localizedDescription)
        }
    }

    private func probeHarness(at baseURL: URL) async -> Bool {
        guard let endpoint = URL(string: "api/host.describe", relativeTo: baseURL) else {
            return false
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 1.5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            "{\"type\":\"client-request\",\"rpcId\":\"mac-app-health\",\"method\":\"host.describe\",\"payload\":{}}".utf8
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "server-response",
                  json["rpcId"] as? String == "mac-app-health",
                  let result = json["result"] as? [String: Any],
                  result["ok"] as? Bool == true,
                  let value = result["value"] as? [String: Any],
                  let cwd = value["cwd"] as? String,
                  URL(fileURLWithPath: cwd).standardizedFileURL == expectedWorkingDirectory else {
                return false
            }
            return true
        } catch {
            return false
        }
    }

    private func fetchPluginInventory(at baseURL: URL) async throws -> [PluginInventoryEntry] {
        guard let endpoint = URL(
            string: "/api/pluginInventory/list",
            relativeTo: baseURL
        )?.absoluteURL else {
            throw PluginHealthError.invalidEndpoint
        }

        let rpcID = "mac-app-plugin-health-\(UUID().uuidString)"
        let payload: [String: Any] = [
            "type": "client-request",
            "rpcId": rpcID,
            "method": "pluginInventory/list",
            "payload": ["args": [:] as [String: Any]]
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw PluginHealthError.invalidHTTPResponse
        }

        let envelope = try JSONDecoder().decode(PluginInventoryEnvelope.self, from: data)
        guard envelope.type == "server-response",
              envelope.rpcId == rpcID else {
            throw PluginHealthError.invalidRPCResponse
        }
        guard envelope.result.ok else {
            throw PluginHealthError.requestRejected
        }
        guard let entries = envelope.result.value?.entries else {
            throw PluginHealthError.missingInventory
        }
        return entries
    }

    private func pluginHealth(
        entryID: String,
        entries: [PluginInventoryEntry]
    ) -> PluginHealthState {
        guard let entry = entries.first(where: { $0.entryId == entryID }) else {
            return .missing
        }
        guard entry.enabled == true else {
            return .error("插件已发现，但当前未启用")
        }
        guard entry.fiberPhase == "active" else {
            let phase = entry.fiberPhase ?? "未知"
            return .error("插件已发现，但初始化状态为 \(phase)")
        }
        return .active
    }

    private func markPluginHealthUnavailable() {
        pluginHealthTask?.cancel()
        pluginHealthTask = nil
        computerUsePluginHealth = .error("本地 Harness 未就绪")
        artifactsPluginHealth = .error("本地 Harness 未就绪")
        nativeAttachmentsPluginHealth = .error("本地 Harness 未就绪")
    }

    private struct PluginInventoryEnvelope: Decodable {
        let type: String
        let rpcId: String
        let result: PluginInventoryResult
    }

    private struct PluginInventoryResult: Decodable {
        let ok: Bool
        let value: PluginInventoryValue?
    }

    private struct PluginInventoryValue: Decodable {
        let entries: [PluginInventoryEntry]
    }

    private struct PluginInventoryEntry: Decodable {
        let entryId: String
        let enabled: Bool?
        let fiberPhase: String?
    }

    private enum PluginHealthError: LocalizedError {
        case invalidEndpoint
        case invalidHTTPResponse
        case invalidRPCResponse
        case requestRejected
        case missingInventory

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint:
                return "无法生成插件检查地址"
            case .invalidHTTPResponse:
                return "插件清单接口返回异常"
            case .invalidRPCResponse:
                return "插件清单响应无法核验"
            case .requestRejected:
                return "Harness 拒绝了插件清单请求"
            case .missingInventory:
                return "插件清单响应缺少 entries"
            }
        }
    }

    private enum WorkspaceError: LocalizedError {
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let detail):
                return "无法创建隔离的 Harness 工作区，因此已停止启动，以免误把整个个人目录暴露给代理。\n\(detail)"
            }
        }
    }
}
