import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

struct AppshotDraft: Identifiable {
    let id: String
    let capturedAt: Date
    let applicationName: String
    let bundleIdentifier: String
    let processIdentifier: pid_t
    let windowID: CGWindowID
    let windowTitle: String?
    let image: NSImage
    let pngData: Data
    let locallyRedactedImage: NSImage
    let locallyRedactedPNGData: Data
    let visualRedactionCount: Int
    let ocrText: String
    let accessibilityText: String

    func previewImage(allowingOriginal: Bool) -> NSImage {
        allowingOriginal ? image : locallyRedactedImage
    }

    func persistedPNGData(allowingOriginal: Bool) -> Data {
        allowingOriginal ? pngData : locallyRedactedPNGData
    }

    var contextMarkdown: String {
        var parts = [
            "# Appshot",
            "",
            "- Application: \(applicationName)",
            "- Bundle identifier: \(bundleIdentifier)",
            "- Process ID: \(processIdentifier)",
            "- Window ID: \(windowID)",
            "- Captured at: \(ISO8601DateFormatter().string(from: capturedAt))"
        ]
        if let windowTitle, !windowTitle.isEmpty {
            parts.append("- Window title: \(HarnessPrivacy.redact(windowTitle, limit: 500))")
        }
        parts += [
            "- Visual redactions applied locally: \(visualRedactionCount)",
            "",
            "## Accessibility text",
            "",
            accessibilityText.isEmpty ? "(No accessibility text was available.)" : accessibilityText,
            "",
            "## Local OCR text",
            "",
            ocrText.isEmpty ? "(No OCR text was recognized.)" : ocrText
        ]
        return HarnessPrivacy.redact(parts.joined(separator: "\n"), limit: 80_000)
    }
}

@MainActor
final class AppshotStore: ObservableObject {
    @Published private(set) var draft: AppshotDraft?
    @Published private(set) var isCapturing = false
    @Published private(set) var errorMessage: String?
    @Published var allowImageForVisionModel = false

    var isPresentingDraft: Bool { draft != nil }

    func captureFrontmostApplication() {
        guard !isCapturing else { return }
        guard let application = NSWorkspace.shared.frontmostApplication else {
            errorMessage = "没有找到当前应用。"
            return
        }
        if application.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            captureAfterSwitchingApplications()
            return
        }
        beginCapture(application: application)
    }

    func captureAfterSwitchingApplications(delay: Duration = .seconds(2)) {
        guard !isCapturing else { return }
        isCapturing = true
        errorMessage = nil
        NSApp.hide(nil)

        Task {
            try? await Task.sleep(for: delay)
            guard let application = NSWorkspace.shared.frontmostApplication else {
                isCapturing = false
                errorMessage = "没有找到要截取的应用。"
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            await capture(application: application)
        }
    }

    func discard() {
        draft = nil
        allowImageForVisionModel = false
    }

    func confirm() throws -> URL {
        guard let draft else { throw AppshotError.noDraft }
        let directory = ArtifactStore.appshotsURL.appendingPathComponent(draft.id, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let previewURL = directory.appendingPathComponent("preview.png")
        let contextURL = directory.appendingPathComponent("context.md")
        let metadataURL = directory.appendingPathComponent("metadata.json")

        do {
            let persistedPNGData = draft.persistedPNGData(
                allowingOriginal: allowImageForVisionModel
            )
            try persistedPNGData.write(to: previewURL, options: [.atomic])
            try Data(draft.contextMarkdown.utf8).write(to: contextURL, options: [.atomic])
            let metadata = AppshotMetadata(
                id: draft.id,
                capturedAt: ISO8601DateFormatter().string(from: draft.capturedAt),
                applicationName: draft.applicationName,
                bundleIdentifier: draft.bundleIdentifier,
                processIdentifier: draft.processIdentifier,
                windowID: draft.windowID,
                windowTitle: draft.windowTitle.map { HarnessPrivacy.redact($0, limit: 500) },
                previewFilename: previewURL.lastPathComponent,
                contextFilename: contextURL.lastPathComponent,
                imageApprovedForVisionModel: allowImageForVisionModel,
                previewIsLocallyRedacted: !allowImageForVisionModel,
                visualRedactionCount: draft.visualRedactionCount
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(metadata).write(to: metadataURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previewURL.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: contextURL.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }

        self.draft = nil
        allowImageForVisionModel = false
        NotificationCenter.default.post(name: .deepSeekArtifactsDidChange, object: nil)
        return contextURL
    }

    func copyDraftImageToPasteboard() {
        guard let draft else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(
            draft.persistedPNGData(allowingOriginal: allowImageForVisionModel),
            forType: .png
        )
    }

    func clearError() {
        errorMessage = nil
    }

    private func beginCapture(application: NSRunningApplication) {
        isCapturing = true
        errorMessage = nil
        Task { await capture(application: application) }
    }

    private func capture(application: NSRunningApplication) async {
        do {
            let captured = try await AppshotCaptureEngine.capture(application: application)
            draft = captured
            allowImageForVisionModel = false
        } catch {
            errorMessage = error.localizedDescription
        }
        isCapturing = false
        NSApp.activate(ignoringOtherApps: true)
    }

    private struct AppshotMetadata: Codable {
        let id: String
        let capturedAt: String
        let applicationName: String
        let bundleIdentifier: String
        let processIdentifier: pid_t
        let windowID: CGWindowID
        let windowTitle: String?
        let previewFilename: String
        let contextFilename: String
        let imageApprovedForVisionModel: Bool
        let previewIsLocallyRedacted: Bool
        let visualRedactionCount: Int
    }

#if DEBUG
    func installDraftForAppshotQA(_ draft: AppshotDraft) {
        self.draft = draft
        allowImageForVisionModel = false
        errorMessage = nil
    }
#endif
}

private enum AppshotCaptureEngine {
    static func capture(application: NSRunningApplication) async throws -> AppshotDraft {
        guard !application.isTerminated,
              application.processIdentifier > 1,
              let bundleIdentifier = application.bundleIdentifier,
              let applicationName = application.localizedName,
              !AppshotSensitivity.isBlockedBundle(bundleIdentifier) else {
            throw AppshotError.sensitiveOrUnavailableApplication
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw AppshotError.screenRecordingNotGranted
        }

        let pid = application.processIdentifier
        try requireFrontmostApplication(processIdentifier: pid)
        let accessibility = AXSnapshot.capture(processIdentifier: pid)
        if accessibility.containsSecureTextField {
            throw AppshotError.sensitiveWindow
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        try requireFrontmostApplication(processIdentifier: pid)
        let candidates = content.windows.filter { window in
            window.owningApplication?.processID == pid
                && window.isOnScreen
                && window.windowLayer == 0
                && window.frame.width >= 40
                && window.frame.height >= 40
        }

        let descriptors = candidates.map {
            AppshotWindowDescriptor(windowID: $0.windowID, frame: $0.frame, title: $0.title)
        }
        let selectedID = AppshotWindowSelector.selectWindowID(
            candidates: descriptors,
            focusedFrame: accessibility.focusedWindowFrame,
            focusedTitle: accessibility.focusedWindowTitle
        )
        let selected = selectedID.flatMap { id in
            candidates.first { $0.windowID == id }
        }

        guard let window = selected else {
            if candidates.isEmpty { throw AppshotError.noVisibleWindow }
            throw AppshotError.ambiguousWindow
        }


        // Window focus can move while ScreenCaptureKit builds its shareable-content
        // snapshot. Re-check immediately before capture and fail closed instead of
        // returning a screenshot from a formerly focused window.
        try requireFrontmostApplication(processIdentifier: pid)
        let currentFocus = AXSnapshot.captureFocus(processIdentifier: pid)
        if currentFocus.isAvailable {
            let currentID = AppshotWindowSelector.selectWindowID(
                candidates: descriptors,
                focusedFrame: currentFocus.frame,
                focusedTitle: currentFocus.title
            )
            guard currentID == window.windowID else {
                throw AppshotError.focusChanged
            }
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let longestEdge = max(window.frame.width, window.frame.height, 1)
        let scale = min(2.0, 3_000.0 / longestEdge)
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        try requireFrontmostApplication(processIdentifier: pid)
        let ocrResult = try await OCRRecognizer.recognize(cgImage)
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw AppshotError.encodingFailed
        }
        let redactedBitmap = NSBitmapImageRep(cgImage: ocrResult.locallyRedactedImage)
        guard let locallyRedactedPNGData = redactedBitmap.representation(
            using: .png,
            properties: [:]
        ) else {
            throw AppshotError.encodingFailed
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let now = Date()
        let identifier = "\(formatter.string(from: now))-\(UUID().uuidString.prefix(8).lowercased())"

        return AppshotDraft(
            id: identifier,
            capturedAt: now,
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            processIdentifier: pid,
            windowID: window.windowID,
            windowTitle: accessibility.focusedWindowTitle ?? window.title,
            image: NSImage(cgImage: cgImage, size: .zero),
            pngData: pngData,
            locallyRedactedImage: NSImage(cgImage: ocrResult.locallyRedactedImage, size: .zero),
            locallyRedactedPNGData: locallyRedactedPNGData,
            visualRedactionCount: ocrResult.visualRedactionCount,
            ocrText: HarnessPrivacy.redact(ocrResult.text, limit: 40_000),
            accessibilityText: HarnessPrivacy.redact(accessibility.text, limit: 40_000)
        )
    }

    private static func requireFrontmostApplication(processIdentifier: pid_t) throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else {
            throw AppshotError.focusChanged
        }
    }
}

struct AppshotWindowDescriptor: Equatable {
    let windowID: CGWindowID
    let frame: CGRect
    let title: String?
}

enum AppshotWindowSelector {
    static func selectWindowID(
        candidates: [AppshotWindowDescriptor],
        focusedFrame: CGRect?,
        focusedTitle: String?
    ) -> CGWindowID? {
        guard !candidates.isEmpty else { return nil }
        guard let focusedFrame, focusedFrame.width > 0, focusedFrame.height > 0 else {
            return candidates.count == 1 ? candidates[0].windowID : nil
        }

        let normalizedFocusedTitle = normalizeTitle(focusedTitle)
        let tolerance = max(12, min(36, max(focusedFrame.width, focusedFrame.height) * 0.025))
        let scored = candidates.compactMap { candidate -> WindowScore? in
            let distance = frameDistance(candidate.frame, focusedFrame)
            let overlap = overlapRatio(candidate.frame, focusedFrame)
            guard distance <= tolerance || overlap >= 0.985 else { return nil }
            let normalizedCandidateTitle = normalizeTitle(candidate.title)
            let titleMatches = normalizedFocusedTitle != nil
                && normalizedFocusedTitle == normalizedCandidateTitle
            return WindowScore(
                windowID: candidate.windowID,
                distance: distance,
                overlap: overlap,
                titleMatches: titleMatches
            )
        }.sorted(by: isPreferred)

        guard let best = scored.first else { return nil }
        guard scored.count > 1 else { return best.windowID }
        let runnerUp = scored[1]

        if best.titleMatches != runnerUp.titleMatches {
            return best.titleMatches ? best.windowID : nil
        }
        if best.overlap - runnerUp.overlap > 0.01 {
            return best.windowID
        }
        if runnerUp.distance - best.distance > max(2, tolerance * 0.1) {
            return best.windowID
        }
        return nil
    }

    private struct WindowScore {
        let windowID: CGWindowID
        let distance: CGFloat
        let overlap: CGFloat
        let titleMatches: Bool
    }

    private static func isPreferred(_ left: WindowScore, _ right: WindowScore) -> Bool {
        if left.titleMatches != right.titleMatches { return left.titleMatches }
        if left.overlap != right.overlap { return left.overlap > right.overlap }
        if left.distance != right.distance { return left.distance < right.distance }
        return left.windowID < right.windowID
    }

    private static func normalizeTitle(_ title: String?) -> String? {
        guard let value = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func frameDistance(_ left: CGRect, _ right: CGRect) -> CGFloat {
        abs(left.minX - right.minX)
            + abs(left.minY - right.minY)
            + abs(left.width - right.width)
            + abs(left.height - right.height)
    }

    private static func overlapRatio(_ left: CGRect, _ right: CGRect) -> CGFloat {
        let intersection = left.intersection(right)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return 0
        }
        let smallerArea = min(left.width * left.height, right.width * right.height)
        guard smallerArea > 0 else { return 0 }
        return (intersection.width * intersection.height) / smallerArea
    }
}

private enum OCRRecognizer {
    struct Result {
        let text: String
        let locallyRedactedImage: CGImage
        let visualRedactionCount: Int
    }

    static func recognize(_ image: CGImage) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
            try handler.perform([request])
            let observations = request.results ?? []
            let lines = observations
                .sorted {
                    let delta = $0.boundingBox.midY - $1.boundingBox.midY
                    if abs(delta) > 0.015 { return delta > 0 }
                    return $0.boundingBox.minX < $1.boundingBox.minX
                }
                .prefix(400)
                .compactMap { $0.topCandidates(1).first?.string }
            let sensitiveObservations = observations.filter { observation in
                guard let candidate = observation.topCandidates(1).first?.string else {
                    return false
                }
                return HarnessPrivacy.redact(candidate, limit: 10_000) != candidate
            }
            let locallyRedactedImage = coverSensitiveText(
                in: image,
                observations: sensitiveObservations
            ) ?? image
            return Result(
                text: lines.joined(separator: "\n"),
                locallyRedactedImage: locallyRedactedImage,
                visualRedactionCount: sensitiveObservations.count
            )
        }.value
    }

    private static func coverSensitiveText(
        in image: CGImage,
        observations: [VNRecognizedTextObservation]
    ) -> CGImage? {
        guard !observations.isEmpty else { return image }
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: bounds)
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        for observation in observations {
            let normalized = observation.boundingBox
            let padding = max(3, CGFloat(min(width, height)) * 0.004)
            var rectangle = CGRect(
                x: normalized.minX * CGFloat(width),
                y: normalized.minY * CGFloat(height),
                width: normalized.width * CGFloat(width),
                height: normalized.height * CGFloat(height)
            ).insetBy(dx: -padding, dy: -padding)
            rectangle = rectangle.intersection(bounds)
            if !rectangle.isNull { context.fill(rectangle) }
        }
        return context.makeImage()
    }
}

private enum AppshotSensitivity {
    private static let blockedIdentifierFragments = [
        "password", "keychain", "securityagent", "authorizationhost",
        "authenticationservicesui", "localauthentication", "onepassword",
        "1password", "bitwarden", "lastpass", "dashlane", "keepass",
        "protonpass", "strongbox", "enpass", "nordpass", "keepersecurity"
    ]

    static func isBlockedBundle(_ bundleIdentifier: String?) -> Bool {
        guard let identifier = bundleIdentifier?.lowercased(), !identifier.isEmpty else {
            return true
        }
        if HarnessPrivacy.isSensitiveBundle(identifier) { return true }
        return blockedIdentifierFragments.contains { identifier.contains($0) }
    }
}

private struct AXSnapshot {
    let focusedWindowFrame: CGRect?
    let focusedWindowTitle: String?
    let text: String
    let containsSecureTextField: Bool

    struct Focus {
        let frame: CGRect?
        let title: String?

        var isAvailable: Bool { frame != nil }
    }

    static func capture(processIdentifier: pid_t) -> AXSnapshot {
        guard AXIsProcessTrusted() else {
            return AXSnapshot(
                focusedWindowFrame: nil,
                focusedWindowTitle: nil,
                text: "",
                containsSecureTextField: false
            )
        }
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.4)
        guard let focusedWindow = focusedWindow(of: application) else {
            return AXSnapshot(
                focusedWindowFrame: nil,
                focusedWindowTitle: nil,
                text: "",
                containsSecureTextField: false
            )
        }
        AXUIElementSetMessagingTimeout(focusedWindow, 0.25)
        let frame = frame(of: focusedWindow)
        let title = stringAttribute(focusedWindow, kAXTitleAttribute as CFString)

        var visitor = AXTextVisitor(deadline: Date().addingTimeInterval(2), maximumElements: 500)
        visitor.visit(focusedWindow, depth: 0)
        return AXSnapshot(
            focusedWindowFrame: frame,
            focusedWindowTitle: title,
            text: visitor.lines.joined(separator: "\n"),
            containsSecureTextField: visitor.containsSecureTextField
        )
    }

    static func captureFocus(processIdentifier: pid_t) -> Focus {
        guard AXIsProcessTrusted() else { return Focus(frame: nil, title: nil) }
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.3)
        guard let focusedWindow = focusedWindow(of: application) else {
            return Focus(frame: nil, title: nil)
        }
        AXUIElementSetMessagingTimeout(focusedWindow, 0.2)
        return Focus(
            frame: frame(of: focusedWindow),
            title: stringAttribute(focusedWindow, kAXTitleAttribute as CFString)
        )
    }

    private static func focusedWindow(of application: AXUIElement) -> AXUIElement? {
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            guard let value = attributeValue(application, attribute as CFString),
                  CFGetTypeID(value) == AXUIElementGetTypeID() else { continue }
            return (value as! AXUIElement)
        }
        return nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attributeValue(element, kAXPositionAttribute as CFString),
              CFGetTypeID(position) == AXValueGetTypeID(),
              AXValueGetType(position as! AXValue) == .cgPoint,
              let size = attributeValue(element, kAXSizeAttribute as CFString),
              CFGetTypeID(size) == AXValueGetTypeID(),
              AXValueGetType(size as! AXValue) == .cgSize else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }

    fileprivate static func attributeValue(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }

    fileprivate static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        guard let value = attributeValue(element, attribute) else { return nil }
        if CFGetTypeID(value) == CFStringGetTypeID() { return value as? String }
        if CFGetTypeID(value) == CFAttributedStringGetTypeID() {
            return (value as! NSAttributedString).string
        }
        if CFGetTypeID(value) == CFURLGetTypeID() { return (value as! URL).absoluteString }
        return nil
    }
}

private struct AXTextVisitor {
    let deadline: Date
    let maximumElements: Int
    private(set) var elementCount = 0
    private(set) var lines: [String] = []
    private(set) var containsSecureTextField = false

    mutating func visit(_ element: AXUIElement, depth: Int) {
        guard elementCount < maximumElements, depth <= 12, Date() < deadline else { return }
        elementCount += 1
        AXUIElementSetMessagingTimeout(element, 0.2)

        let role = AXSnapshot.stringAttribute(element, kAXRoleAttribute as CFString)
        let subrole = AXSnapshot.stringAttribute(element, kAXSubroleAttribute as CFString)
        let title = AXSnapshot.stringAttribute(element, kAXTitleAttribute as CFString)
        let description = AXSnapshot.stringAttribute(element, kAXDescriptionAttribute as CFString)
        let help = AXSnapshot.stringAttribute(element, kAXHelpAttribute as CFString)
        let label = [title, description, help].compactMap { $0 }.joined(separator: " · ")

        if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
            containsSecureTextField = true
        }

        var fragments = [role, title, description, help].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        if HarnessPrivacy.isSensitiveElement(role: role, subrole: subrole, label: label) {
            fragments.append("<redacted sensitive field>")
        } else if let value = AXSnapshot.stringAttribute(element, kAXValueAttribute as CFString),
                  !value.isEmpty {
            fragments.append(value)
        }
        if !fragments.isEmpty {
            lines.append(HarnessPrivacy.redact(fragments.joined(separator: " | "), limit: 1_000))
        }

        guard let childrenValue = AXSnapshot.attributeValue(element, kAXChildrenAttribute as CFString),
              let children = childrenValue as? [AXUIElement] else { return }
        for child in children {
            visit(child, depth: depth + 1)
            if elementCount >= maximumElements || Date() >= deadline { break }
        }
    }
}

enum AppshotError: LocalizedError {
    case noDraft
    case sensitiveOrUnavailableApplication
    case sensitiveWindow
    case screenRecordingNotGranted
    case noVisibleWindow
    case ambiguousWindow
    case focusChanged
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .noDraft:
            return "没有待确认的 Appshot。"
        case .sensitiveOrUnavailableApplication:
            return "这个应用不可截取；密码、钥匙串和系统安全窗口始终被阻止。"
        case .sensitiveWindow:
            return "当前窗口包含密码输入框，已为保护隐私阻止 Appshot。"
        case .screenRecordingNotGranted:
            return "需要先在系统设置中允许“屏幕与系统录音”。"
        case .noVisibleWindow:
            return "当前应用没有可见窗口。"
        case .ambiguousWindow:
            return "无法安全确定当前窗口。请允许辅助功能，或只保留一个可见窗口后重试。"
        case .focusChanged:
            return "截取过程中前台应用或聚焦窗口发生了变化，请保持目标窗口不动后重试。"
        case .encodingFailed:
            return "无法生成 Appshot 预览。"
        }
    }
}

#if DEBUG
enum AppshotQAHooks {
    struct OCRProbe {
        let text: String
        let locallyRedactedImage: CGImage
        let visualRedactionCount: Int
    }

    static func recognizeAndRedact(_ image: CGImage) async throws -> OCRProbe {
        let result = try await OCRRecognizer.recognize(image)
        return OCRProbe(
            text: result.text,
            locallyRedactedImage: result.locallyRedactedImage,
            visualRedactionCount: result.visualRedactionCount
        )
    }

    static func isBlockedBundle(_ bundleIdentifier: String?) -> Bool {
        AppshotSensitivity.isBlockedBundle(bundleIdentifier)
    }
}
#endif
