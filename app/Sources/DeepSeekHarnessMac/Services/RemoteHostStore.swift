import Darwin
import Foundation

struct RemoteHostDescriptor: Codable, Hashable, Identifiable, Sendable {
    let alias: String
    let user: String
    let hostname: String
    let port: Int

    var id: String { alias }

    var endpoint: String {
        let displayedHost = hostname.contains(":") ? "[\(hostname)]" : hostname
        return "\(user)@\(displayedHost):\(port)"
    }
}

struct RemoteHostSelection: Codable, Equatable, Sendable {
    let version: Int
    let selectionID: String
    let selectedAt: String
    let expiresAt: String
    let hostAlias: String
    let resolvedHostname: String
    let resolvedUser: String
    let resolvedPort: Int
    let remoteWorkspace: String

    enum CodingKeys: String, CodingKey {
        case version
        case selectionID = "selection_id"
        case selectedAt = "selected_at"
        case expiresAt = "expires_at"
        case hostAlias = "host_alias"
        case resolvedHostname = "resolved_hostname"
        case resolvedUser = "resolved_user"
        case resolvedPort = "resolved_port"
        case remoteWorkspace = "remote_workspace"
    }

    var alias: String { hostAlias }
    var user: String { resolvedUser }
    var hostname: String { resolvedHostname }
    var port: Int { resolvedPort }

    var host: RemoteHostDescriptor {
        RemoteHostDescriptor(
            alias: hostAlias,
            user: resolvedUser,
            hostname: resolvedHostname,
            port: resolvedPort
        )
    }
}

#if REMOTE_HOST_STORE_QA
extension RemoteHostStore {
    nonisolated static func runLocalSecurityQA() {
        let validAliases = [
            "a",
            "A0",
            "9host",
            "host.example",
            "host_name",
            "host-name"
        ]
        let invalidAliases = [
            "",
            "-host",
            ".host",
            "_host",
            "host:22",
            "host*",
            "host/name",
            " host",
            "服务器",
            String(repeating: "a", count: 256)
        ]
        precondition(validAliases.allSatisfy(isSafeAlias))
        precondition(invalidAliases.allSatisfy { !isSafeAlias($0) })

        let parsed = parseExplicitAliases(
            from: "Host good -bad bad:22 .bad _bad also_good also-good good.example\n"
        )
        precondition(parsed == ["good", "also_good", "also-good", "good.example"])

        let completed = runBoundedProcess(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["bounded-ok"],
            capture: .standardOutput,
            wallClockTimeout: 1,
            outputLimit: 128
        )
        precondition(completed.endReason == .completed)
        precondition(completed.terminationStatus == 0)
        precondition(completed.output == Data("bounded-ok\n".utf8))
        precondition(!completed.outputWasTruncated)

        let timeoutStart = Date()
        let timedOut = runBoundedProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; while :; do :; done"],
            capture: .standardOutput,
            wallClockTimeout: 0.15,
            outputLimit: 128,
            terminationGrace: 0.08,
            killGrace: 0.5
        )
        precondition(timedOut.endReason == .wallClockTimeout)
        precondition(timedOut.didSendSIGTERM)
        precondition(timedOut.didSendSIGKILL)
        precondition(Date().timeIntervalSince(timeoutStart) < 2)

        let outputStart = Date()
        let oversized = runBoundedProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
            arguments: ["bounded-output"],
            capture: .standardOutput,
            wallClockTimeout: 2,
            outputLimit: 1_024,
            terminationGrace: 0.08,
            killGrace: 0.5
        )
        precondition(oversized.endReason == .outputLimitExceeded)
        precondition(oversized.outputWasTruncated)
        precondition(oversized.output.count == 1_024)
        precondition(oversized.didSendSIGTERM)
        precondition(Date().timeIntervalSince(outputStart) < 2)
    }
}
#endif

enum RemoteHostStatus: Equatable, Sendable {
    case idle(String)
    case working(String)
    case success(String)
    case warning(String)
    case failure(String)

    var message: String {
        switch self {
        case .idle(let message),
             .working(let message),
             .success(let message),
             .warning(let message),
             .failure(let message):
            return message
        }
    }
}

private enum RemoteProcessCaptureStream: Sendable {
    case standardOutput
    case standardError
}

private enum RemoteProcessEndReason: Equatable, Sendable {
    case completed
    case wallClockTimeout
    case outputLimitExceeded
    case launchFailed
}

private struct RemoteProcessResult: Sendable {
    let endReason: RemoteProcessEndReason
    let terminationStatus: Int32?
    let output: Data
    let outputWasTruncated: Bool
    let didSendSIGTERM: Bool
    let didSendSIGKILL: Bool
}

private final class RemoteProcessSignals: @unchecked Sendable {
    let firstEvent = DispatchSemaphore(value: 0)
    let termination = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var didTerminate = false
    private var terminationStatus: Int32?
    private var didExceedOutputLimit = false

    func markTerminated(status: Int32) {
        lock.lock()
        didTerminate = true
        terminationStatus = status
        lock.unlock()

        termination.signal()
        firstEvent.signal()
    }

    func markOutputLimitExceeded() {
        lock.lock()
        let shouldSignal = !didExceedOutputLimit
        didExceedOutputLimit = true
        lock.unlock()

        if shouldSignal {
            firstEvent.signal()
        }
    }

    func snapshot() -> (
        didTerminate: Bool,
        terminationStatus: Int32?,
        didExceedOutputLimit: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (didTerminate, terminationStatus, didExceedOutputLimit)
    }
}

private final class BoundedRemoteProcessOutput: @unchecked Sendable {
    private let limit: Int
    private let signals: RemoteProcessSignals
    private let lock = NSLock()
    private var data = Data()
    private var wasTruncated = false

    init(limit: Int, signals: RemoteProcessSignals) {
        self.limit = limit
        self.signals = signals
    }

    func append(_ bytes: [UInt8], count: Int) {
        guard count > 0 else { return }

        lock.lock()
        let remaining = max(0, limit - data.count)
        let acceptedCount = min(remaining, count)
        if acceptedCount > 0 {
            bytes.withUnsafeBufferPointer { buffer in
                if let baseAddress = buffer.baseAddress {
                    data.append(baseAddress, count: acceptedCount)
                }
            }
        }
        let newlyTruncated = count > remaining && !wasTruncated
        if newlyTruncated {
            wasTruncated = true
        }
        lock.unlock()

        if newlyTruncated {
            signals.markOutputLimitExceeded()
        }
    }

    func snapshot() -> (data: Data, wasTruncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (data, wasTruncated)
    }
}

private final class ManagedRemoteFileDescriptor: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
    }

    func close() {
        lock.lock()
        let descriptorToClose = descriptor
        descriptor = nil
        lock.unlock()

        if let descriptorToClose {
            _ = Darwin.close(descriptorToClose)
        }
    }
}

@MainActor
final class RemoteHostStore: ObservableObject {
    @Published private(set) var hosts: [RemoteHostDescriptor] = []
    @Published private(set) var selection: RemoteHostSelection?
    @Published private(set) var isDiscovering = false
    @Published private(set) var isTesting = false
    @Published private(set) var discoveryStatus: RemoteHostStatus = .idle(
        "尚未读取 SSH 主机列表。"
    )
    @Published private(set) var selectionStatus: RemoteHostStatus = .idle(
        "尚未选择远程服务器。"
    )
    @Published private(set) var connectionStatus: RemoteHostStatus = .idle(
        "选择服务器和远程工作区后，可手动测试连接。"
    )

    private var discoveryGeneration = UUID()
    private var connectionGeneration = UUID()
    private var expiryTask: Task<Void, Never>?

    init() {
        if let persisted = Self.readPersistedSelection() {
            selection = persisted
            selectionStatus = .success(
                "已选择 \(persisted.alias) · \(persisted.remoteWorkspace)"
            )
            scheduleExpiry(for: persisted)
        }
    }

    deinit {
        expiryTask?.cancel()
    }

    var selectedAlias: String? { selection?.alias }

    func refreshHosts() {
        let generation = UUID()
        discoveryGeneration = generation
        isDiscovering = true
        discoveryStatus = .working("正在从系统 SSH 配置发现明确的主机别名…")

        Task {
            let report = await Task.detached(priority: .userInitiated) {
                Self.discoverHosts()
            }.value

            guard discoveryGeneration == generation else { return }
            isDiscovering = false

            switch report {
            case .success(let result):
                hosts = result.hosts

                if result.hosts.isEmpty {
                    discoveryStatus = .idle(
                        "没有发现可显示的明确 Host 别名。请先在终端配置 ~/.ssh/config。"
                    )
                } else if result.unresolvedCount > 0 || result.wasTruncated {
                    var details = "已安全解析 \(result.hosts.count) 台服务器"
                    if result.unresolvedCount > 0 {
                        details += "，另有 \(result.unresolvedCount) 个别名未能解析"
                    }
                    if result.wasTruncated {
                        details += "；列表已按安全上限截断"
                    }
                    discoveryStatus = .warning(details + "。")
                } else {
                    discoveryStatus = .success(
                        "已安全解析 \(result.hosts.count) 台服务器。"
                    )
                }

            case .failure(let message):
                hosts = []
                discoveryStatus = .failure(message)
            }
        }
    }

    @discardableResult
    func select(host: RemoteHostDescriptor, remoteWorkspace: String) -> Bool {
        guard hosts.contains(host) else {
            selectionStatus = .failure("服务器列表已经变化，请刷新后重新选择。")
            return false
        }

        guard let normalizedWorkspace = Self.normalizedRemoteWorkspace(remoteWorkspace) else {
            selectionStatus = .failure("远程工作区必须是以 / 开头的绝对 POSIX 路径。")
            return false
        }

        let selectedAt = Date()
        let expiresAt = selectedAt.addingTimeInterval(24 * 60 * 60)
        let formatter = ISO8601DateFormatter()
        let newSelection = RemoteHostSelection(
            version: 1,
            selectionID: UUID().uuidString.lowercased(),
            selectedAt: formatter.string(from: selectedAt),
            expiresAt: formatter.string(from: expiresAt),
            hostAlias: host.alias,
            resolvedHostname: host.hostname,
            resolvedUser: host.user,
            resolvedPort: host.port,
            remoteWorkspace: normalizedWorkspace
        )

        do {
            try Self.persist(newSelection)
            selection = newSelection
            selectionStatus = .success(
                "已选择 \(host.alias) · \(normalizedWorkspace)"
            )
            connectionStatus = .idle("尚未测试这个服务器连接。")
            scheduleExpiry(for: newSelection)
            return true
        } catch {
            selectionStatus = .failure("无法保存服务器选择，请检查本机应用数据目录。")
            return false
        }
    }

    func detach() {
        connectionGeneration = UUID()
        expiryTask?.cancel()
        expiryTask = nil
        isTesting = false

        do {
            if FileManager.default.fileExists(atPath: Self.selectionURL.path) {
                try FileManager.default.removeItem(at: Self.selectionURL)
            }
            selection = nil
            selectionStatus = .idle("已断开远程服务器选择。")
            connectionStatus = .idle("选择服务器和远程工作区后，可手动测试连接。")
        } catch {
            selectionStatus = .failure("无法移除已保存的服务器选择。")
        }
    }

    func testSelectedConnection() {
        guard let selection else {
            connectionStatus = .failure("请先选择服务器和远程工作区。")
            return
        }
        guard Self.selectionDatesAreValid(selection) else {
            expireSelection(selectionID: selection.selectionID)
            connectionStatus = .warning("服务器选择已过期，请重新选择后再测试。")
            return
        }

        let generation = UUID()
        connectionGeneration = generation
        isTesting = true
        connectionStatus = .working(
            "正在以非交互方式测试 \(selection.alias)…"
        )

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Self.runConnectionTest(selection)
            }.value

            guard connectionGeneration == generation,
                  self.selection == selection else { return }

            isTesting = false
            switch result {
            case .success(let message):
                connectionStatus = .success(message)
            case .warning(let message):
                connectionStatus = .warning(message)
            case .failure(let message):
                connectionStatus = .failure(message)
            }
        }
    }

    func workspaceValidationMessage(for path: String) -> String? {
        if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请输入远程工作区的绝对路径。"
        }
        if Self.normalizedRemoteWorkspace(path) == nil {
            return "路径必须以 / 开头，且不能包含控制字符。"
        }
        return nil
    }

    private static var selectionURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeepSeek Harness", isDirectory: true)
            .appendingPathComponent("remote-host-selection.json", isDirectory: false)
    }

    nonisolated private static var sshConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config", isDirectory: false)
    }

    private static func readPersistedSelection() -> RemoteHostSelection? {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: selectionURL.path
        ),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value,
              permissions & 0o077 == 0,
              permissions & 0o600 == 0o600,
              let data = try? Data(contentsOf: selectionURL),
              let value = try? JSONDecoder().decode(RemoteHostSelection.self, from: data),
              value.version == 1,
              UUID(uuidString: value.selectionID) != nil,
              isSafeAlias(value.alias),
              isSafeResolvedValue(value.user),
              isSafeResolvedValue(value.hostname),
              (1...65_535).contains(value.port),
              normalizedRemoteWorkspace(value.remoteWorkspace) == value.remoteWorkspace,
              selectionDatesAreValid(value) else {
            return nil
        }
        return value
    }

    private static func selectionDatesAreValid(_ selection: RemoteHostSelection) -> Bool {
        let formatter = ISO8601DateFormatter()
        guard let selectedAt = formatter.date(from: selection.selectedAt),
              let expiresAt = formatter.date(from: selection.expiresAt),
              expiresAt > Date(),
              expiresAt > selectedAt,
              expiresAt.timeIntervalSince(selectedAt) <= 24 * 60 * 60 else {
            return false
        }
        return true
    }

    private func scheduleExpiry(for selection: RemoteHostSelection) {
        expiryTask?.cancel()

        let formatter = ISO8601DateFormatter()
        guard let expiryDate = formatter.date(from: selection.expiresAt) else { return }
        let delay = max(0, expiryDate.timeIntervalSinceNow)
        let selectionID = selection.selectionID

        expiryTask = Task { [weak self] in
            let nanoseconds = UInt64(min(delay, 24 * 60 * 60) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.expireSelection(selectionID: selectionID)
        }
    }

    private func expireSelection(selectionID: String) {
        guard selection?.selectionID == selectionID else { return }
        try? FileManager.default.removeItem(at: Self.selectionURL)
        selection = nil
        expiryTask = nil
        selectionStatus = .warning("服务器选择已在 24 小时后自动过期，请重新选择。")
        connectionStatus = .idle("选择服务器和远程工作区后，可手动测试连接。")
    }

    private static func persist(_ selection: RemoteHostSelection) throws {
        let directory = selectionURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(selection)
        try data.write(to: selectionURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: selectionURL.path
        )
    }

    private static func normalizedRemoteWorkspace(_ rawPath: String) -> String? {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"),
              path.utf8.count <= 4_096,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }

        let standardized = (path as NSString).standardizingPath
        guard standardized.hasPrefix("/") else { return nil }
        return standardized
    }

    private struct DiscoveryResult: Sendable {
        let hosts: [RemoteHostDescriptor]
        let unresolvedCount: Int
        let wasTruncated: Bool
    }

    private enum DiscoveryReport: Sendable {
        case success(DiscoveryResult)
        case failure(String)
    }

    nonisolated private static func discoverHosts() -> DiscoveryReport {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sshConfigURL.path) else {
            return .success(
                DiscoveryResult(hosts: [], unresolvedCount: 0, wasTruncated: false)
            )
        }

        do {
            let attributes = try fileManager.attributesOfItem(atPath: sshConfigURL.path)
            if let size = attributes[.size] as? NSNumber,
               size.intValue > 1_048_576 {
                return .failure("SSH 配置文件过大，已停止发现服务器。")
            }

            let data = try Data(contentsOf: sshConfigURL)
            guard let contents = String(data: data, encoding: .utf8) else {
                return .failure("SSH 配置不是可读取的 UTF-8 文本。")
            }

            let allAliases = parseExplicitAliases(from: contents)
            let aliases = Array(allAliases.prefix(128))
            var resolvedHosts: [RemoteHostDescriptor] = []
            var unresolvedCount = 0

            for alias in aliases {
                if let host = resolve(alias: alias) {
                    resolvedHosts.append(host)
                } else {
                    unresolvedCount += 1
                }
            }

            return .success(
                DiscoveryResult(
                    hosts: resolvedHosts.sorted {
                        $0.alias.localizedStandardCompare($1.alias) == .orderedAscending
                    },
                    unresolvedCount: unresolvedCount,
                    wasTruncated: allAliases.count > aliases.count
                )
            )
        } catch {
            return .failure("无法读取系统 SSH 配置；应用不会显示配置内容。")
        }
    }

    nonisolated private static func parseExplicitAliases(from contents: String) -> [String] {
        var aliases: [String] = []
        var seen: Set<String> = []

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let lineBeforeComment = rawLine.split(
                separator: "#",
                maxSplits: 1,
                omittingEmptySubsequences: false
            ).first ?? rawLine[...]
            let parts = lineBeforeComment.split(whereSeparator: \.isWhitespace)
            guard let directive = parts.first,
                  String(directive).caseInsensitiveCompare("Host") == .orderedSame else {
                continue
            }

            for rawAlias in parts.dropFirst() {
                let alias = String(rawAlias).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                guard isSafeAlias(alias), seen.insert(alias).inserted else { continue }
                aliases.append(alias)
            }
        }

        return aliases
    }

    nonisolated private static func isSafeAlias(_ alias: String) -> Bool {
        guard !alias.isEmpty,
              alias.utf8.count <= 255,
              let first = alias.unicodeScalars.first,
              isASCIIAlphaNumeric(first) else {
            return false
        }

        return alias.unicodeScalars.dropFirst().allSatisfy { scalar in
            switch scalar.value {
            case 45, 46, 95, 48...57, 65...90, 97...122:
                return true
            default:
                return false
            }
        }
    }

    nonisolated private static func isASCIIAlphaNumeric(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            return true
        default:
            return false
        }
    }

    nonisolated private static func isSafeResolvedValue(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 512
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    nonisolated private static func resolve(alias: String) -> RemoteHostDescriptor? {
        guard isSafeAlias(alias) else { return nil }

        let result = runBoundedProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: [
                "-G",
                "-o", "PermitLocalCommand=no",
                "-o", "ProxyCommand=none",
                "-o", "ProxyJump=none",
                alias
            ],
            capture: .standardOutput,
            wallClockTimeout: 3,
            outputLimit: 262_144
        )

        guard result.endReason == .completed,
              result.terminationStatus == 0,
              !result.outputWasTruncated,
              let output = String(data: result.output, encoding: .utf8) else {
            return nil
        }

        var user: String?
        var hostname: String?
        var port: Int?

        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(
                maxSplits: 1,
                whereSeparator: \.isWhitespace
            )
            guard fields.count == 2 else { continue }
            let key = fields[0].lowercased()
            let value = String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)

            switch key {
            case "user" where user == nil:
                user = value
            case "hostname" where hostname == nil:
                hostname = value
            case "port" where port == nil:
                port = Int(value)
            default:
                continue
            }
        }

        guard let user,
              let hostname,
              let port,
              isSafeResolvedValue(user),
              isSafeResolvedValue(hostname),
              (1...65_535).contains(port) else {
            return nil
        }

        return RemoteHostDescriptor(
            alias: alias,
            user: user,
            hostname: hostname,
            port: port
        )
    }

    nonisolated private static func runBoundedProcess(
        executableURL: URL,
        arguments: [String],
        capture: RemoteProcessCaptureStream,
        wallClockTimeout: TimeInterval,
        outputLimit: Int,
        terminationGrace: TimeInterval = 0.25,
        killGrace: TimeInterval = 0.75
    ) -> RemoteProcessResult {
        guard wallClockTimeout > 0,
              outputLimit > 0,
              terminationGrace >= 0,
              killGrace >= 0 else {
            return RemoteProcessResult(
                endReason: .launchFailed,
                terminationStatus: nil,
                output: Data(),
                outputWasTruncated: false,
                didSendSIGTERM: false,
                didSendSIGKILL: false
            )
        }

        var descriptors = [Int32](repeating: -1, count: 2)
        let pipeResult = descriptors.withUnsafeMutableBufferPointer { buffer in
            Darwin.pipe(buffer.baseAddress!)
        }
        guard pipeResult == 0 else {
            return RemoteProcessResult(
                endReason: .launchFailed,
                terminationStatus: nil,
                output: Data(),
                outputWasTruncated: false,
                didSendSIGTERM: false,
                didSendSIGKILL: false
            )
        }

        let readDescriptor = descriptors[0]
        let writeDescriptor = descriptors[1]
        let readOwner = ManagedRemoteFileDescriptor(readDescriptor)
        let writeOwner = ManagedRemoteFileDescriptor(writeDescriptor)

        let currentFlags = Darwin.fcntl(readDescriptor, F_GETFL)
        guard currentFlags >= 0,
              Darwin.fcntl(readDescriptor, F_SETFL, currentFlags | O_NONBLOCK) == 0 else {
            readOwner.close()
            writeOwner.close()
            return RemoteProcessResult(
                endReason: .launchFailed,
                terminationStatus: nil,
                output: Data(),
                outputWasTruncated: false,
                didSendSIGTERM: false,
                didSendSIGKILL: false
            )
        }

        _ = Darwin.fcntl(readDescriptor, F_SETFD, FD_CLOEXEC)
        _ = Darwin.fcntl(writeDescriptor, F_SETFD, FD_CLOEXEC)

        let signals = RemoteProcessSignals()
        let output = BoundedRemoteProcessOutput(limit: outputLimit, signals: signals)
        let readerReachedEOF = DispatchSemaphore(value: 0)
        let readerCancelled = DispatchSemaphore(value: 0)
        let readerQueue = DispatchQueue(
            label: "com.tengqi.deepseek-harness.ssh-output-reader",
            qos: .utility
        )
        let reader = DispatchSource.makeReadSource(
            fileDescriptor: readDescriptor,
            queue: readerQueue
        )

        reader.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 8_192)

            // Bound work per dispatch event so cancellation cannot be starved
            // by a child that continuously writes output.
            for _ in 0..<64 {
                let count = buffer.withUnsafeMutableBytes { rawBuffer in
                    Darwin.read(readDescriptor, rawBuffer.baseAddress, rawBuffer.count)
                }

                if count > 0 {
                    output.append(buffer, count: count)
                    continue
                }

                if count == 0 {
                    readerReachedEOF.signal()
                    reader.cancel()
                    return
                }

                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }

                readerReachedEOF.signal()
                reader.cancel()
                return
            }
        }
        reader.setCancelHandler {
            readOwner.close()
            readerCancelled.signal()
        }
        reader.resume()

        let writeHandle = FileHandle(
            fileDescriptor: writeDescriptor,
            closeOnDealloc: false
        )
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        switch capture {
        case .standardOutput:
            process.standardOutput = writeHandle
            process.standardError = FileHandle.nullDevice
        case .standardError:
            process.standardOutput = FileHandle.nullDevice
            process.standardError = writeHandle
        }
        process.terminationHandler = { terminatedProcess in
            signals.markTerminated(status: terminatedProcess.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            writeOwner.close()
            reader.cancel()
            if readerCancelled.wait(timeout: .now() + 0.25) == .timedOut {
                readOwner.close()
            }
            let snapshot = output.snapshot()
            return RemoteProcessResult(
                endReason: .launchFailed,
                terminationStatus: nil,
                output: snapshot.data,
                outputWasTruncated: snapshot.wasTruncated,
                didSendSIGTERM: false,
                didSendSIGKILL: false
            )
        }

        // The child inherited the write end during launch. Closing the parent
        // copy ensures EOF can be observed when the child exits.
        writeOwner.close()

        let firstEvent = signals.firstEvent.wait(
            timeout: .now() + wallClockTimeout
        )
        var endReason: RemoteProcessEndReason
        if firstEvent == .timedOut {
            endReason = .wallClockTimeout
        } else {
            let snapshot = signals.snapshot()
            if snapshot.didExceedOutputLimit {
                endReason = .outputLimitExceeded
            } else if snapshot.didTerminate {
                endReason = .completed
            } else {
                endReason = .wallClockTimeout
            }
        }

        var didSendSIGTERM = false
        var didSendSIGKILL = false
        if endReason != .completed {
            let processID = process.processIdentifier
            if !signals.snapshot().didTerminate, processID > 0 {
                didSendSIGTERM = Darwin.kill(processID, SIGTERM) == 0
            }

            if signals.termination.wait(
                timeout: .now() + terminationGrace
            ) == .timedOut,
               !signals.snapshot().didTerminate,
               processID > 0 {
                didSendSIGKILL = Darwin.kill(processID, SIGKILL) == 0
                _ = signals.termination.wait(timeout: .now() + killGrace)
            }
        }

        // Give the nonblocking reader one bounded opportunity to observe EOF,
        // then cancel and close regardless of child or descendant behavior.
        _ = readerReachedEOF.wait(timeout: .now() + 0.15)
        reader.cancel()
        if readerCancelled.wait(timeout: .now() + 0.25) == .timedOut {
            readOwner.close()
        }

        let outputSnapshot = output.snapshot()
        if outputSnapshot.wasTruncated, endReason == .completed {
            endReason = .outputLimitExceeded
        }
        let signalSnapshot = signals.snapshot()
        return RemoteProcessResult(
            endReason: endReason,
            terminationStatus: signalSnapshot.terminationStatus,
            output: outputSnapshot.data,
            outputWasTruncated: outputSnapshot.wasTruncated,
            didSendSIGTERM: didSendSIGTERM,
            didSendSIGKILL: didSendSIGKILL
        )
    }

    private enum ConnectionResult: Sendable {
        case success(String)
        case warning(String)
        case failure(String)
    }

    nonisolated private static func runConnectionTest(
        _ selection: RemoteHostSelection
    ) -> ConnectionResult {
        guard let currentHost = resolve(alias: selection.alias) else {
            return .failure("无法解析已选择的服务器，请刷新列表后重试。")
        }

        guard currentHost.user == selection.user,
              currentHost.hostname == selection.hostname,
              currentHost.port == selection.port else {
            return .warning("SSH 配置已经变化。为避免连接到错误主机，请重新选择服务器。")
        }

        let result = runBoundedProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: [
                "-T",
                "-o", "BatchMode=yes",
                "-o", "PasswordAuthentication=no",
                "-o", "KbdInteractiveAuthentication=no",
                "-o", "PreferredAuthentications=publickey",
                "-o", "NumberOfPasswordPrompts=0",
                "-o", "StrictHostKeyChecking=yes",
                "-o", "ConnectTimeout=8",
                "-o", "ConnectionAttempts=1",
                "-o", "PermitLocalCommand=no",
                "-o", "ClearAllForwardings=yes",
                "-o", "ForwardAgent=no",
                "-o", "ForwardX11=no",
                "-o", "Tunnel=no",
                "-o", "ControlMaster=no",
                "-o", "ProxyCommand=none",
                "-o", "ProxyJump=none",
                "-o", "RequestTTY=no",
                selection.alias,
                "exit 0"
            ],
            capture: .standardError,
            wallClockTimeout: 12,
            outputLimit: 65_536
        )

        switch result.endReason {
        case .launchFailed:
            return .failure("无法启动系统 SSH 客户端。")
        case .wallClockTimeout:
            return .failure("连接服务器超过 12 秒，已停止 SSH 进程。请检查网络或 VPN。")
        case .outputLimitExceeded:
            return .failure("SSH 返回了异常多的诊断信息，已停止连接测试。")
        case .completed:
            break
        }

        if result.terminationStatus == 0 {
            return .success("连接测试通过；系统 SSH 的非交互认证可用。")
        }

        let errorText = String(data: result.output, encoding: .utf8)?
            .lowercased() ?? ""

        if errorText.contains("host key verification failed")
            || errorText.contains("no host key is known") {
            return .warning(
                "主机指纹尚未确认或已经变化。请先在终端运行 ssh \(selection.alias)，核对指纹后再测试。"
            )
        }
        if errorText.contains("permission denied")
            || errorText.contains("no more authentication methods") {
            return .warning(
                "系统 SSH 没有可用的非交互凭据。请先在终端配置密钥或 ssh-agent；应用不会保存密码。"
            )
        }
        if errorText.contains("could not resolve hostname") {
            return .failure("无法解析服务器地址，请检查系统 SSH 配置和网络。")
        }
        if errorText.contains("connection timed out") {
            return .failure("连接服务器超时，请检查网络或 VPN。")
        }
        if errorText.contains("connection refused") {
            return .failure("服务器拒绝了 SSH 连接。")
        }
        if errorText.contains("no route to host") || errorText.contains("network is unreachable") {
            return .failure("当前网络无法到达该服务器。")
        }

        return .failure("SSH 连接测试失败。请先在终端确认该别名能够正常连接。")
    }
}
