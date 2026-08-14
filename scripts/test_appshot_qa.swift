import AppKit
import Carbon
import Foundation

enum ArtifactStore {
    static var appshotsURL: URL {
        guard let root = ProcessInfo.processInfo.environment["APPSHOT_QA_ROOT"], !root.isEmpty else {
            fatalError("APPSHOT_QA_ROOT is required")
        }
        return URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("Appshots", isDirectory: true)
    }
}

extension Notification.Name {
    static let deepSeekArtifactsDidChange = Notification.Name("DeepSeekHarness.AppshotQA")
}

@main
@MainActor
struct AppshotQA {
    private static var passed = 0

    static func main() async throws {
        _ = NSApplication.shared
        try testWindowSelection()
        try testSensitiveBundlePolicy()
        let fixture = try makeFixtureImage()
        let ocr = try await AppshotQAHooks.recognizeAndRedact(fixture.cgImage)
        try testOCRRedaction(raw: fixture, result: ocr)
        try testConfirmationBoundary(raw: fixture, result: ocr)
        try testHotKeyLifecycle()
        print("APPSHOT_QA_OK \(passed) checks")
    }

    private static func testWindowSelection() throws {
        let exactFrame = CGRect(x: 100, y: 80, width: 900, height: 620)
        let exact = AppshotWindowSelector.selectWindowID(
            candidates: [
                AppshotWindowDescriptor(windowID: 10, frame: exactFrame, title: "Fixture")
            ],
            focusedFrame: exactFrame,
            focusedTitle: "Fixture"
        )
        try expect(exact == 10, "exact focused window")

        let byTitle = AppshotWindowSelector.selectWindowID(
            candidates: [
                AppshotWindowDescriptor(windowID: 11, frame: exactFrame, title: "Other"),
                AppshotWindowDescriptor(windowID: 12, frame: exactFrame, title: "Fixture")
            ],
            focusedFrame: exactFrame,
            focusedTitle: "Fixture"
        )
        try expect(byTitle == 12, "title disambiguates identical frames")

        let ambiguous = AppshotWindowSelector.selectWindowID(
            candidates: [
                AppshotWindowDescriptor(windowID: 13, frame: exactFrame, title: "Same"),
                AppshotWindowDescriptor(windowID: 14, frame: exactFrame, title: "Same")
            ],
            focusedFrame: exactFrame,
            focusedTitle: "Same"
        )
        try expect(ambiguous == nil, "ambiguous windows fail closed")

        let withoutAX = AppshotWindowSelector.selectWindowID(
            candidates: [
                AppshotWindowDescriptor(windowID: 15, frame: exactFrame, title: "Only")
            ],
            focusedFrame: nil,
            focusedTitle: nil
        )
        try expect(withoutAX == 15, "single window works without Accessibility")

        let multipleWithoutAX = AppshotWindowSelector.selectWindowID(
            candidates: [
                AppshotWindowDescriptor(windowID: 16, frame: exactFrame, title: "One"),
                AppshotWindowDescriptor(
                    windowID: 17,
                    frame: exactFrame.offsetBy(dx: 50, dy: 50),
                    title: "Two"
                )
            ],
            focusedFrame: nil,
            focusedTitle: nil
        )
        try expect(multipleWithoutAX == nil, "multiple windows without Accessibility fail closed")

        let drifted = AppshotWindowSelector.selectWindowID(
            candidates: [
                AppshotWindowDescriptor(
                    windowID: 18,
                    frame: exactFrame.offsetBy(dx: 4, dy: -3),
                    title: "Fixture"
                )
            ],
            focusedFrame: exactFrame,
            focusedTitle: "Fixture"
        )
        try expect(drifted == 18, "minor capture timing drift is tolerated")

        let unrelated = AppshotWindowSelector.selectWindowID(
            candidates: [
                AppshotWindowDescriptor(
                    windowID: 19,
                    frame: exactFrame.offsetBy(dx: 400, dy: 300),
                    title: "Fixture"
                )
            ],
            focusedFrame: exactFrame,
            focusedTitle: "Fixture"
        )
        try expect(unrelated == nil, "unrelated frame is rejected")
    }

    private static func testSensitiveBundlePolicy() throws {
        try expect(
            AppshotQAHooks.isBlockedBundle("com.apple.Passwords"),
            "Apple Passwords is blocked"
        )
        try expect(
            AppshotQAHooks.isBlockedBundle("org.keepassxc.keepassxc"),
            "KeePassXC is blocked"
        )
        try expect(
            AppshotQAHooks.isBlockedBundle("com.apple.LocalAuthentication.UIAgent"),
            "system authentication agent is blocked"
        )
        try expect(
            !AppshotQAHooks.isBlockedBundle("org.example.AppshotFixture"),
            "ordinary fixture app is allowed"
        )
        try expect(AppshotQAHooks.isBlockedBundle(nil), "missing identity fails closed")
    }

    private static func testOCRRedaction(
        raw: FixtureImage,
        result: AppshotQAHooks.OCRProbe
    ) throws {
        let redactedText = HarnessPrivacy.redact(result.text)
        try expect(
            redactedText.contains("<redacted secret>"),
            "local OCR text redacts synthetic credential"
        )
        try expect(result.visualRedactionCount >= 1, "credential region is visually masked")
        let redactedData = try pngData(result.locallyRedactedImage)
        try expect(redactedData != raw.pngData, "redacted bitmap differs from original")

        let root = ArtifactStore.appshotsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try raw.pngData.write(to: root.appendingPathComponent("qa-original.png"), options: .atomic)
        try redactedData.write(to: root.appendingPathComponent("qa-redacted.png"), options: .atomic)
        print("APPSHOT_QA_ORIGINAL=\(root.appendingPathComponent("qa-original.png").path)")
        print("APPSHOT_QA_REDACTED=\(root.appendingPathComponent("qa-redacted.png").path)")
    }

    private static func testConfirmationBoundary(
        raw: FixtureImage,
        result: AppshotQAHooks.OCRProbe
    ) throws {
        let redactedData = try pngData(result.locallyRedactedImage)
        let store = AppshotStore()

        let defaultDraft = makeDraft(
            id: "qa-default",
            raw: raw,
            redactedImage: result.locallyRedactedImage,
            redactedData: redactedData,
            visualRedactionCount: result.visualRedactionCount
        )
        store.installDraftForAppshotQA(defaultDraft)
        let defaultDirectory = ArtifactStore.appshotsURL
            .appendingPathComponent(defaultDraft.id, isDirectory: true)
        try expect(!FileManager.default.fileExists(atPath: defaultDirectory.path), "draft stays in memory")
        _ = try store.confirm()
        let defaultPreview = try Data(
            contentsOf: defaultDirectory.appendingPathComponent("preview.png")
        )
        try expect(defaultPreview == redactedData, "default confirmation persists redacted image")
        try expect(defaultPreview != raw.pngData, "default confirmation does not persist original")
        let defaultMetadata = try metadata(at: defaultDirectory)
        try expect(
            defaultMetadata["imageApprovedForVisionModel"] as? Bool == false,
            "original image approval defaults to false"
        )
        try expect(
            defaultMetadata["previewIsLocallyRedacted"] as? Bool == true,
            "default metadata marks local redaction"
        )
        try expect(store.draft == nil, "confirmed draft is cleared")

        let approvedDraft = makeDraft(
            id: "qa-approved",
            raw: raw,
            redactedImage: result.locallyRedactedImage,
            redactedData: redactedData,
            visualRedactionCount: result.visualRedactionCount
        )
        store.installDraftForAppshotQA(approvedDraft)
        store.allowImageForVisionModel = true
        _ = try store.confirm()
        let approvedDirectory = ArtifactStore.appshotsURL
            .appendingPathComponent(approvedDraft.id, isDirectory: true)
        let approvedPreview = try Data(
            contentsOf: approvedDirectory.appendingPathComponent("preview.png")
        )
        try expect(approvedPreview == raw.pngData, "explicit approval persists original")
        let approvedMetadata = try metadata(at: approvedDirectory)
        try expect(
            approvedMetadata["imageApprovedForVisionModel"] as? Bool == true,
            "explicit original approval is recorded"
        )
        try expect(
            approvedMetadata["previewIsLocallyRedacted"] as? Bool == false,
            "approved metadata identifies original image"
        )
    }

    private static func testHotKeyLifecycle() throws {
        let first = GlobalHotKeyController(
            qaSignature: 0x44535141,
            qaIdentifier: 91,
            qaKeyCode: UInt32(kVK_F18),
            qaModifiers: UInt32(controlKey | optionKey | cmdKey)
        ) { }
        try first.register()
        try first.register()

        let second = GlobalHotKeyController(
            qaSignature: 0x44535142,
            qaIdentifier: 92,
            qaKeyCode: UInt32(kVK_F18),
            qaModifiers: UInt32(controlKey | optionKey | cmdKey)
        ) { }
        var conflictWasRejected = false
        do {
            try second.register()
        } catch {
            conflictWasRejected = true
        }
        try expect(conflictWasRejected, "conflicting global shortcut is rejected cleanly")
        first.unregister()
        try second.register()
        second.unregister()
        try expect(true, "global shortcut can re-register after cleanup")
    }

    private static func makeFixtureImage() throws -> FixtureImage {
        let size = NSSize(width: 1_280, height: 360)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 42, weight: .regular),
            .foregroundColor: NSColor.black
        ]
        NSString(string: "Disposable Appshot QA fixture")
            .draw(at: NSPoint(x: 45, y: 255), withAttributes: attributes)
        NSString(string: "API key: sk-" + "testfixture1234567890abcdef")
            .draw(at: NSPoint(x: 45, y: 155), withAttributes: attributes)
        NSString(string: "Ordinary research text remains visible")
            .draw(at: NSPoint(x: 45, y: 55), withAttributes: attributes)
        image.unlockFocus()
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw QAError.failed("could not render fixture image")
        }
        return FixtureImage(cgImage: cgImage, pngData: try pngData(cgImage))
    }

    private static func makeDraft(
        id: String,
        raw: FixtureImage,
        redactedImage: CGImage,
        redactedData: Data,
        visualRedactionCount: Int
    ) -> AppshotDraft {
        AppshotDraft(
            id: id,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            applicationName: "Disposable Fixture",
            bundleIdentifier: "org.example.AppshotFixture",
            processIdentifier: 42,
            windowID: 7,
            windowTitle: "Fixture",
            image: NSImage(cgImage: raw.cgImage, size: .zero),
            pngData: raw.pngData,
            locallyRedactedImage: NSImage(cgImage: redactedImage, size: .zero),
            locallyRedactedPNGData: redactedData,
            visualRedactionCount: visualRedactionCount,
            ocrText: "API key: <redacted secret>",
            accessibilityText: "AXStaticText | Disposable fixture"
        )
    }

    private static func pngData(_ image: CGImage) throws -> Data {
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw QAError.failed("could not encode PNG")
        }
        return data
    }

    private static func metadata(at directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent("metadata.json"))
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QAError.failed("invalid metadata")
        }
        return value
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw QAError.failed(label) }
        passed += 1
        print("PASS \(label)")
    }

    private struct FixtureImage {
        let cgImage: CGImage
        let pngData: Data
    }

    private enum QAError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .failed(let label): return "Appshot QA failed: \(label)"
            }
        }
    }
}
