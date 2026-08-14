import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Darwin
import Foundation

struct AttachableApplication: Identifiable, Hashable {
    let bundleIdentifier: String
    let name: String
    let processIdentifier: pid_t
    let processLaunchTime: TimeInterval
    let icon: NSImage
    let isFrontmost: Bool

    var id: String { "\(bundleIdentifier)#\(processIdentifier)#\(processLaunchTime)" }
}

@MainActor
final class AppAttachmentStore: ObservableObject {
    @Published private(set) var applications: [AttachableApplication] = []
    @Published private(set) var selectedBundleIdentifier: String?
    @Published private(set) var selectedProcessIdentifier: pid_t?
    @Published private(set) var selectedProcessLaunchTime: TimeInterval?
    @Published private(set) var accessibilityAllowed = false
    @Published private(set) var screenCaptureAllowed = false

    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        if let selection = Self.readSelection(),
           !Self.isSensitiveBundle(selection.bundleIdentifier) {
            selectedBundleIdentifier = selection.bundleIdentifier
            selectedProcessIdentifier = selection.processIdentifier
            selectedProcessLaunchTime = selection.processLaunchTime
        } else {
            selectedBundleIdentifier = nil
            selectedProcessIdentifier = nil
            selectedProcessLaunchTime = nil
            try? FileManager.default.removeItem(at: Self.selectionURL)
        }
        refresh()

        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification
        ] {
            workspaceObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.refresh()
                    }
                }
            )
        }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
    }

    var selectedApplication: AttachableApplication? {
        guard let selectedBundleIdentifier,
              let selectedProcessIdentifier,
              let selectedProcessLaunchTime else { return nil }
        return applications.first {
            $0.bundleIdentifier == selectedBundleIdentifier
                && $0.processIdentifier == selectedProcessIdentifier
                && abs($0.processLaunchTime - selectedProcessLaunchTime) <= 0.01
        }
    }

    var selectedApplicationName: String? {
        selectedApplication?.name ?? Self.readSelection()?.displayName
    }

    func refresh() {
        let ownBundleIdentifier = Bundle.main.bundleIdentifier

        applications = NSWorkspace.shared.runningApplications.compactMap { application in
            guard application.activationPolicy == .regular,
                  !application.isTerminated,
                  Self.processExists(application.processIdentifier),
                  let name = application.localizedName,
                  !name.isEmpty,
                  let bundleIdentifier = application.bundleIdentifier,
                  let launchDate = application.launchDate,
                  bundleIdentifier != ownBundleIdentifier,
                  !Self.isSensitiveBundle(bundleIdentifier) else {
                return nil
            }

            return AttachableApplication(
                bundleIdentifier: bundleIdentifier,
                name: name,
                processIdentifier: application.processIdentifier,
                processLaunchTime: launchDate.timeIntervalSince1970,
                icon: application.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!,
                isFrontmost: application.isActive
            )
        }
        .sorted {
            if $0.isFrontmost != $1.isFrontmost { return $0.isFrontmost }
            let nameOrder = $0.name.localizedStandardCompare($1.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.processIdentifier < $1.processIdentifier
        }

        if let selection = Self.readSelection(),
           !applications.contains(where: { application in
               guard let selectedLaunchTime = selection.processLaunchTime else {
                   return false
               }
               return application.bundleIdentifier == selection.bundleIdentifier
                   && application.processIdentifier == selection.processIdentifier
                   && abs(application.processLaunchTime - selectedLaunchTime) <= 0.01
           }) {
            detach()
        }

        refreshPermissions()
    }

    func attach(_ application: AttachableApplication) {
        selectedBundleIdentifier = application.bundleIdentifier
        selectedProcessIdentifier = application.processIdentifier
        selectedProcessLaunchTime = application.processLaunchTime
        Self.writeSelection(
            SelectionFile(
                bundleIdentifier: application.bundleIdentifier,
                displayName: application.name,
                processIdentifier: application.processIdentifier,
                processLaunchTime: application.processLaunchTime,
                updatedAt: ISO8601DateFormatter().string(from: Date())
            )
        )
    }

    func detach() {
        selectedBundleIdentifier = nil
        selectedProcessIdentifier = nil
        selectedProcessLaunchTime = nil
        try? FileManager.default.removeItem(at: Self.selectionURL)
    }

    func isSelected(_ application: AttachableApplication) -> Bool {
        selectedBundleIdentifier == application.bundleIdentifier
            && selectedProcessIdentifier == application.processIdentifier
            && selectedProcessLaunchTime.map {
                abs($0 - application.processLaunchTime) <= 0.01
            } ?? false
    }

    func refreshPermissions() {
        accessibilityAllowed = AXIsProcessTrusted()
        screenCaptureAllowed = CGPreflightScreenCaptureAccess()
    }

    func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    func openScreenCaptureSettings() {
        openPrivacyPane("Privacy_ScreenCapture")
    }

    func requestAccessibilityPermission() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        accessibilityAllowed = AXIsProcessTrustedWithOptions(options)
        if !accessibilityAllowed {
            openAccessibilitySettings()
        }
    }

    func requestScreenCapturePermission() {
        screenCaptureAllowed = CGRequestScreenCaptureAccess()
        if !screenCaptureAllowed {
            openScreenCaptureSettings()
        }
    }

    private func openPrivacyPane(_ anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private struct SelectionFile: Codable {
        let bundleIdentifier: String
        let displayName: String
        let processIdentifier: pid_t?
        let processLaunchTime: TimeInterval?
        let updatedAt: String
    }

    private static var selectionURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DeepSeek Harness", isDirectory: true)
            .appendingPathComponent("app-bridge-selection.json", isDirectory: false)
    }

    private static func readSelection() -> SelectionFile? {
        guard let data = try? Data(contentsOf: selectionURL) else { return nil }
        return try? JSONDecoder().decode(SelectionFile.self, from: data)
    }

    private static func writeSelection(_ selection: SelectionFile) {
        do {
            try FileManager.default.createDirectory(
                at: selectionURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(selection)
            try data.write(to: selectionURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: selectionURL.path
            )
        } catch {
            NSLog("Unable to save attached application: %@", error.localizedDescription)
        }
    }

    private static func isSensitiveBundle(_ bundleIdentifier: String) -> Bool {
        let identifier = bundleIdentifier.lowercased()
        let blocked: Set<String> = [
            "com.apple.passwords",
            "com.apple.keychainaccess",
            "com.apple.securityagent",
            "com.apple.loginwindow",
            "com.1password.1password",
            "com.agilebits.onepassword7",
            "com.bitwarden.desktop",
            "com.dashlane.dashlane",
            "com.lastpass.lastpass"
        ]
        return blocked.contains(identifier)
    }

    private static func processExists(_ pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
