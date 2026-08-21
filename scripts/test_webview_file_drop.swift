import AppKit
import Foundation
import ImageIO
import ObjectiveC.runtime
import SwiftUI
import WebKit

private enum WebViewDropQAFailure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let message): return message
        }
    }
}

@MainActor
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw WebViewDropQAFailure.message(message) }
}

@MainActor
private final class FixtureDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    weak var destinationWindow: NSWindow?

    init(pasteboard: NSPasteboard, destinationWindow: NSWindow?) {
        self.draggingPasteboard = pasteboard
        self.destinationWindow = destinationWindow
    }

    var draggingDestinationWindow: NSWindow? { destinationWindow }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { NSPoint(x: 120, y: 120) }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 73_901 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}

    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? {
        nil
    }

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}

    func resetSpringLoading() {}
}

@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private(set) var finished = false
    private(set) var failure: Error?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        failure = error
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        failure = error
    }
}

@MainActor
private final class ApplicationKeyEventProbe {
    private var monitor: Any?
    private(set) var commandVEvents = 0

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers == .command,
               event.charactersIgnoringModifiers?.lowercased() == "v" {
                self?.commandVEvents += 1
            }
            return event
        }
    }

    func uninstall() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

@MainActor
private final class WebKitSuperclassProbe {
    private static var activeProbe: WebKitSuperclassProbe?

    private let performSelector = NSSelectorFromString("performDragOperation:")
    private let concludeSelector = NSSelectorFromString("concludeDragOperation:")
    private var originalPerform: IMP?
    private var originalConclude: IMP?
    private var performTypes: UnsafePointer<CChar>?
    private var concludeTypes: UnsafePointer<CChar>?
    private var probePerform: IMP?
    private var probeConclude: IMP?

    private(set) var performCalls = 0
    private(set) var concludeCalls = 0

    func install() throws {
        guard Self.activeProbe == nil else {
            throw WebViewDropQAFailure.message("WKWebView superclass probe was installed twice")
        }
        guard let performMethod = class_getInstanceMethod(WKWebView.self, performSelector),
              let concludeMethod = class_getInstanceMethod(WKWebView.self, concludeSelector),
              let performTypes = method_getTypeEncoding(performMethod),
              let concludeTypes = method_getTypeEncoding(concludeMethod) else {
            throw WebViewDropQAFailure.message("WKWebView drag superclass methods were not discoverable")
        }

        originalPerform = method_getImplementation(performMethod)
        originalConclude = method_getImplementation(concludeMethod)
        self.performTypes = performTypes
        self.concludeTypes = concludeTypes
        Self.activeProbe = self

        let performBlock: @convention(block) (AnyObject, AnyObject?) -> Bool = { _, _ in
            guard let probe = Self.activeProbe else { return false }
            probe.performCalls += 1
            return false
        }
        let concludeBlock: @convention(block) (AnyObject, AnyObject?) -> Void = { _, _ in
            Self.activeProbe?.concludeCalls += 1
        }
        let performIMP = imp_implementationWithBlock(performBlock)
        let concludeIMP = imp_implementationWithBlock(concludeBlock)
        probePerform = performIMP
        probeConclude = concludeIMP

        if !class_addMethod(WKWebView.self, performSelector, performIMP, performTypes),
           let ownMethod = class_getInstanceMethod(WKWebView.self, performSelector) {
            method_setImplementation(ownMethod, performIMP)
        }
        if !class_addMethod(WKWebView.self, concludeSelector, concludeIMP, concludeTypes),
           let ownMethod = class_getInstanceMethod(WKWebView.self, concludeSelector) {
            method_setImplementation(ownMethod, concludeIMP)
        }
    }

    func uninstall() {
        if let originalPerform, let performTypes {
            class_replaceMethod(WKWebView.self, performSelector, originalPerform, performTypes)
        }
        if let originalConclude, let concludeTypes {
            class_replaceMethod(WKWebView.self, concludeSelector, originalConclude, concludeTypes)
        }
        if let probePerform { imp_removeBlock(probePerform) }
        if let probeConclude { imp_removeBlock(probeConclude) }
        Self.activeProbe = nil
    }
}

@MainActor
private func runLoop(until predicate: () -> Bool, timeout: TimeInterval, label: String) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() {
        if Date() >= deadline {
            throw WebViewDropQAFailure.message("timed out while waiting for \(label)")
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

@MainActor
private func descendantWebView(of view: NSView) -> WKWebView? {
    if let webView = view as? WKWebView { return webView }
    for child in view.subviews {
        if let found = descendantWebView(of: child) { return found }
    }
    return nil
}

@MainActor
private func makeFilePasteboard(_ urls: [URL]) throws -> NSPasteboard {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("DeepSeekHarness.WebViewDropQA.\(UUID().uuidString)"))
    pasteboard.clearContents()
    try require(pasteboard.writeObjects(urls.map { $0 as NSURL }), "could not write file URLs to fixture pasteboard")
    return pasteboard
}

@MainActor
private func makeTextPasteboard() throws -> NSPasteboard {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("DeepSeekHarness.WebViewDropQA.\(UUID().uuidString)"))
    pasteboard.clearContents()
    try require(pasteboard.setString("ordinary text drag", forType: .string), "could not write text fixture")
    return pasteboard
}

@MainActor
private struct GeneralPasteboardSnapshot {
    private let items: [NSPasteboardItem]

    init() {
        items = (NSPasteboard.general.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    func restore() {
        NSPasteboard.general.clearContents()
        if !items.isEmpty {
            _ = NSPasteboard.general.writeObjects(items)
        }
    }
}

@MainActor
private func putFileURLsOnGeneralPasteboard(_ urls: [URL]) throws {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    try require(
        pasteboard.writeObjects(urls.map { $0 as NSURL }),
        "could not write file URLs to the general pasteboard fixture"
    )
}

@MainActor
private func putTextOnGeneralPasteboard(_ text: String) throws {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    try require(
        pasteboard.setString(text, forType: .string),
        "could not write ordinary text to the general pasteboard fixture"
    )
}

@MainActor
private func putRawPNGOnGeneralPasteboard(_ data: Data) throws {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    try require(
        pasteboard.setData(data, forType: .png),
        "could not write raw PNG data to the general pasteboard fixture"
    )
}

@MainActor
private func commandVPasteEvent(window: NSWindow) throws -> NSEvent {
    try commandVPasteEvent(window: window, modifiers: .command)
}

@MainActor
private func commandVPasteEvent(
    window: NSWindow,
    modifiers: NSEvent.ModifierFlags
) throws -> NSEvent {
    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: "v",
        charactersIgnoringModifiers: "v",
        isARepeat: false,
        keyCode: 9
    ) else {
        throw WebViewDropQAFailure.message("could not create the synthetic Command-V event")
    }
    return event
}

@MainActor
private func sendCommandVThroughApplication(
    to webView: WKWebView,
    window: NSWindow,
    modifiers: NSEvent.ModifierFlags = .command
) throws {
    window.makeKeyAndOrderFront(nil)
    try require(window.makeFirstResponder(webView), "WKWebView did not accept first-responder focus")
    try focusOrdinaryPasteTarget(webView)
    NSApp.sendEvent(try commandVPasteEvent(window: window, modifiers: modifiers))
}

@MainActor
private func pageJavaScriptValue(
    _ webView: WKWebView,
    script: String,
    label: String
) throws -> Any? {
    var finished = false
    var value: Any?
    var failure: Error?
    webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
        switch result {
        case .success(let resultValue): value = resultValue
        case .failure(let error): failure = error
        }
        finished = true
    }
    try runLoop(until: { finished }, timeout: 3, label: label)
    if let failure {
        throw WebViewDropQAFailure.message("\(label) failed: \(failure.localizedDescription)")
    }
    return value
}

@MainActor
private func focusOrdinaryPasteTarget(_ webView: WKWebView) throws {
    let value = try pageJavaScriptValue(
        webView,
        script: """
        const target = document.getElementById("ordinary-paste-target");
        if (!(target instanceof HTMLTextAreaElement)) return false;
        target.value = "";
        target.focus();
        target.setSelectionRange(0, 0);
        return document.activeElement === target;
        """,
        label: "ordinary paste target focus"
    )
    try require(value as? Bool == true, "fixture textarea did not receive DOM focus")
}

@MainActor
private func DOMPasteEventCount(_ webView: WKWebView) throws -> Int {
    let value = try pageJavaScriptValue(
        webView,
        script: "return window.__nativePasteQAEventCount ?? 0;",
        label: "DOM paste event count"
    )
    return (value as? NSNumber)?.intValue ?? 0
}

@MainActor
private func ordinaryPasteTargetValue(_ webView: WKWebView) throws -> String {
    let value = try pageJavaScriptValue(
        webView,
        script: "return document.getElementById('ordinary-paste-target')?.value ?? '';",
        label: "ordinary paste target value"
    )
    return value as? String ?? ""
}

private func writeImageFixture(_ data: Data, to url: URL, expectedType: String) throws {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          CGImageSourceGetCount(source) == 1,
          let observedType = CGImageSourceGetType(source) as String?,
          observedType == expectedType,
          CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
        throw WebViewDropQAFailure.message("fixture \(url.lastPathComponent) is not a decodable \(expectedType) image")
    }
    try data.write(to: url, options: [.atomic])
}

private func makeRasterFixtureData(_ type: NSBitmapImageRep.FileType) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 2,
        pixelsHigh: 2,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw WebViewDropQAFailure.message("could not allocate raster fixture")
    }
    bitmap.setColor(NSColor(deviceRed: 0.55, green: 0.20, blue: 0.80, alpha: 1), atX: 0, y: 0)
    bitmap.setColor(NSColor(deviceRed: 0.10, green: 0.35, blue: 0.90, alpha: 1), atX: 1, y: 0)
    bitmap.setColor(NSColor(deviceRed: 0.20, green: 0.70, blue: 0.30, alpha: 1), atX: 0, y: 1)
    bitmap.setColor(NSColor(deviceRed: 0.95, green: 0.45, blue: 0.10, alpha: 1), atX: 1, y: 1)
    guard let data = bitmap.representation(using: type, properties: [:]) else {
        throw WebViewDropQAFailure.message("could not encode raster fixture")
    }
    return data
}

private struct FixtureFiles {
    let png: URL
    let jpg: URL
    let webp: URL
    let gif: URL
    let pdf: URL
    let code: URL
    let spoofPNG: URL
    let oversizedPNG: URL
    let imageSet21: [URL]

    var supportedImages: [URL] { [png, jpg, webp, gif] }
}

private func makeFixtures(in root: URL) throws -> FixtureFiles {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let png = root.appendingPathComponent("pixel.png")
    let jpg = root.appendingPathComponent("pixel.jpg")
    let webp = root.appendingPathComponent("pixel.webp")
    let gif = root.appendingPathComponent("pixel.gif")
    let pdf = root.appendingPathComponent("paper.pdf")
    let code = root.appendingPathComponent("analysis.py")
    let spoofPNG = root.appendingPathComponent("spoof.png")
    let oversizedPNG = root.appendingPathComponent("oversized.png")

    try writeImageFixture(makeRasterFixtureData(.png), to: png, expectedType: "public.png")
    try writeImageFixture(makeRasterFixtureData(.jpeg), to: jpg, expectedType: "public.jpeg")
    try writeImageFixture(
        Data(base64Encoded: "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEAAUAmJaQAA3AA/v89WAAAAA==")!,
        to: webp,
        expectedType: "org.webmproject.webp"
    )
    try writeImageFixture(makeRasterFixtureData(.gif), to: gif, expectedType: "com.compuserve.gif")
    try Data("%PDF-1.4\n% WebView drop fixture\n".utf8).write(to: pdf, options: [.atomic])
    try Data("print('native file drop fixture')\n".utf8).write(to: code, options: [.atomic])
    try Data("this is not image data\n".utf8).write(to: spoofPNG, options: [.atomic])

    let pngData = try Data(contentsOf: png)
    var oversizedData = pngData
    oversizedData.append(
        Data(repeating: 0, count: 5 * 1_024 * 1_024 + 1 - oversizedData.count)
    )
    try oversizedData.write(to: oversizedPNG, options: [.atomic])
    guard let oversizedSource = CGImageSourceCreateWithURL(oversizedPNG as CFURL, nil),
          CGImageSourceGetType(oversizedSource) as String? == "public.png" else {
        throw WebViewDropQAFailure.message("oversized PNG fixture lost its ImageIO identity")
    }

    let imageSetDirectory = root.appendingPathComponent("image-set", isDirectory: true)
    try FileManager.default.createDirectory(at: imageSetDirectory, withIntermediateDirectories: true)
    var imageSet21: [URL] = []
    for index in 1...21 {
        let copy = imageSetDirectory.appendingPathComponent(String(format: "pixel-%02d.png", index))
        try FileManager.default.copyItem(at: png, to: copy)
        imageSet21.append(copy)
    }

    return FixtureFiles(
        png: png,
        jpg: jpg,
        webp: webp,
        gif: gif,
        pdf: pdf,
        code: code,
        spoofPNG: spoofPNG,
        oversizedPNG: oversizedPNG,
        imageSet21: imageSet21
    )
}

@MainActor
private final class DropRecorder {
    var states: [Bool] = []
    var drops: [([URL], String?)] = []
    var imagePastes: [(data: Data, fileExtension: String, sessionID: String?)] = []
}

@MainActor
private final class RouteRecorder {
    private(set) var queries: [(provider: String, model: String)] = []

    func supports(provider: String, model: String) -> Bool {
        queries.append((provider, model))
        return (provider == "moonshotai-cn" && model == "kimi-k3")
            || (provider == "deepseek-official" && model == "deepseek-v4-flash-vision-exp")
    }
}

@MainActor
private final class HostRouteRecorder {
    private(set) var provider: String
    private(set) var model: String
    private(set) var checks: [(provider: String, model: String)] = []

    init(provider: String, model: String) {
        self.provider = provider
        self.model = model
    }

    func set(provider: String, model: String) {
        self.provider = provider
        self.model = model
    }

    func matches(provider: String, model: String) -> Bool {
        checks.append((provider, model))
        return self.provider == provider && self.model == model
    }
}

@MainActor
private final class LifecycleRecorder {
    private(set) var events: [NativeAttachmentLifecycleEvent] = []

    func record(_ event: NativeAttachmentLifecycleEvent) {
        events.append(event)
    }
}

@MainActor
private func publishModelRoute(
    to webView: WKWebView,
    route: [String: Any]?,
    routeRecorder: RouteRecorder,
    expectedQuery: (provider: String, model: String)?
) throws {
    var finished = false
    var failure: Error?
    let queryCountBefore = routeRecorder.queries.count
    let script = """
    window.dispatchEvent(new CustomEvent("deepseek-harness:model-route", {
      detail: publishedRoute
    }));
    await new Promise((resolve) => setTimeout(resolve, 25));
    return true;
    """
    webView.callAsyncJavaScript(
        script,
        arguments: ["publishedRoute": route ?? NSNull()],
        in: nil,
        in: .page
    ) { result in
        switch result {
        case .success:
            finished = true
        case .failure(let error):
            failure = error
            finished = true
        }
    }
    try runLoop(until: { finished }, timeout: 3, label: "model-route relay")
    if let failure {
        throw WebViewDropQAFailure.message("model-route relay failed: \(failure.localizedDescription)")
    }
    if let expectedQuery {
        try runLoop(
            until: {
                routeRecorder.queries.count > queryCountBefore
                    && routeRecorder.queries.last.map {
                    $0.provider == expectedQuery.provider && $0.model == expectedQuery.model
                } == true
            },
            timeout: 3,
            label: "model capability query \(expectedQuery.provider)/\(expectedQuery.model)"
        )
    }
}

@MainActor
private func publishAttachmentLifecycle(
    to webView: WKWebView,
    detail: [String: Any],
    recorder: LifecycleRecorder,
    expectedCount: Int
) throws {
    var finished = false
    var failure: Error?
    let script = """
    window.dispatchEvent(new CustomEvent("deepseek-harness:native-attachment-lifecycle", {
      detail: publishedLifecycle
    }));
    await new Promise((resolve) => setTimeout(resolve, 25));
    return true;
    """
    webView.callAsyncJavaScript(
        script,
        arguments: ["publishedLifecycle": detail],
        in: nil,
        in: .page
    ) { result in
        if case .failure(let error) = result { failure = error }
        finished = true
    }
    try runLoop(until: { finished }, timeout: 3, label: "attachment lifecycle relay")
    if let failure {
        throw WebViewDropQAFailure.message("attachment lifecycle relay failed: \(failure.localizedDescription)")
    }
    try runLoop(
        until: { recorder.events.count == expectedCount },
        timeout: 3,
        label: "native attachment lifecycle callback"
    )
}

@MainActor
private func reset(_ recorder: DropRecorder) {
    recorder.states.removeAll()
    recorder.drops.removeAll()
    recorder.imagePastes.removeAll()
}

@MainActor
private func verifyPassThrough(
    _ webView: WKWebView,
    window: NSWindow,
    pasteboard: NSPasteboard,
    recorder: DropRecorder,
    probe: WebKitSuperclassProbe,
    label: String
) throws {
    reset(recorder)
    let performCallsBefore = probe.performCalls
    let concludeCallsBefore = probe.concludeCalls
    let dragging = FixtureDraggingInfo(pasteboard: pasteboard, destinationWindow: window)

    _ = webView.draggingEntered(dragging)
    _ = webView.draggingUpdated(dragging)
    _ = webView.prepareForDragOperation(dragging)
    _ = webView.performDragOperation(dragging)
    webView.concludeDragOperation(dragging)

    try require(recorder.states.isEmpty, "\(label) entered the native overlay path")
    try require(recorder.drops.isEmpty, "\(label) invoked the native drop callback")
    try require(probe.performCalls == performCallsBefore + 1, "\(label) did not pass perform to WKWebView")
    try require(probe.concludeCalls == concludeCallsBefore + 1, "\(label) did not pass conclude to WKWebView")
}

@MainActor
private func verifyNativeLifecycle(
    _ webView: WKWebView,
    window: NSWindow,
    pasteboard: NSPasteboard,
    expectedURLs: [URL],
    recorder: DropRecorder,
    probe: WebKitSuperclassProbe,
    label: String
) throws {
    reset(recorder)
    let performCallsBefore = probe.performCalls
    let concludeCallsBefore = probe.concludeCalls
    let dragging = FixtureDraggingInfo(pasteboard: pasteboard, destinationWindow: window)

    try require(webView.draggingEntered(dragging) == .copy, "\(label) was not accepted as a native copy")
    try require(webView.draggingUpdated(dragging) == .copy, "\(label) update left the native copy path")
    try require(webView.prepareForDragOperation(dragging), "\(label) native prepare failed")
    try require(webView.performDragOperation(dragging), "\(label) native perform failed")
    webView.concludeDragOperation(dragging)

    try runLoop(until: { recorder.drops.count == 1 }, timeout: 3, label: "\(label) async session resolution")
    try require(recorder.states.first == true, "\(label) never activated the native overlay")
    try require(recorder.states.last == false, "\(label) did not clear the native overlay")
    try require(recorder.drops.count == 1, "\(label) invoked the native drop callback more than once")
    try require(recorder.drops[0].0 == expectedURLs, "\(label) changed file URL ordering or membership")
    try require(recorder.drops[0].1 == "session-A", "\(label) did not preserve the drop-time session")
    try require(probe.performCalls == performCallsBefore, "\(label) incorrectly passed perform to WKWebView")
    try require(probe.concludeCalls == concludeCallsBefore, "\(label) incorrectly passed conclude to WKWebView")
}

@MainActor
private func verifyNativeFileURLPaste(
    _ webView: WKWebView,
    window: NSWindow,
    url: URL,
    recorder: DropRecorder,
    eventProbe: ApplicationKeyEventProbe,
    label: String
) throws {
    reset(recorder)
    try putFileURLsOnGeneralPasteboard([url])
    try focusOrdinaryPasteTarget(webView)
    let pasteEventsBefore = try DOMPasteEventCount(webView)

    try sendCommandVThroughApplication(to: webView, window: window)

    try runLoop(until: { recorder.drops.count == 1 }, timeout: 3, label: "\(label) paste session resolution")
    try require(recorder.states.isEmpty, "\(label) incorrectly activated the drag overlay")
    try require(recorder.drops.count == 1, "\(label) invoked the native paste callback more than once")
    try require(recorder.drops[0].0 == [url], "\(label) changed the pasted file URL")
    try require(recorder.drops[0].1 == "session-A", "\(label) did not bind to the active session")
    try require(recorder.imagePastes.isEmpty, "\(label) treated a file URL as raw image data")
    let pasteEventsAfter = try DOMPasteEventCount(webView)
    try require(pasteEventsAfter == pasteEventsBefore,
                "\(label) leaked a paste event into WebKit")
}

@MainActor
private func verifyOrdinaryTextPastePassThrough(
    _ webView: WKWebView,
    window: NSWindow,
    recorder: DropRecorder,
    eventProbe: ApplicationKeyEventProbe
) throws {
    reset(recorder)
    try putTextOnGeneralPasteboard("ordinary clipboard text")
    window.makeKeyAndOrderFront(nil)
    try require(window.makeFirstResponder(webView), "WKWebView did not accept text-paste focus")
    try focusOrdinaryPasteTarget(webView)
    let handled = webView.performKeyEquivalent(with: try commandVPasteEvent(window: window))

    try require(recorder.states.isEmpty, "ordinary text paste activated the drag overlay")
    try require(recorder.drops.isEmpty, "ordinary text paste invoked the native file callback")
    try require(recorder.imagePastes.isEmpty, "ordinary text paste invoked the native image callback")
    try require(handled, "ordinary text paste did not reach WKWebView")
}

@MainActor
private func verifyFilePasteIgnoredOutsideWebView(
    _ webView: WKWebView,
    window: NSWindow,
    hostingView: NSView,
    url: URL,
    recorder: DropRecorder
) throws {
    reset(recorder)
    try putFileURLsOnGeneralPasteboard([url])

    let externalField = NSTextField(frame: NSRect(x: 8, y: 8, width: 180, height: 24))
    externalField.stringValue = "native field"
    hostingView.addSubview(externalField)
    defer { externalField.removeFromSuperview() }

    window.makeKeyAndOrderFront(nil)
    try require(window.makeFirstResponder(externalField), "external native field did not accept focus")
    externalField.selectText(nil)
    NSApp.sendEvent(try commandVPasteEvent(window: window))
    _ = webView.performKeyEquivalent(with: try commandVPasteEvent(window: window))
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))

    try require(recorder.states.isEmpty, "external field paste activated the drag overlay")
    try require(recorder.drops.isEmpty, "external field paste was imported into the conversation")
    try require(recorder.imagePastes.isEmpty, "external field paste invoked the image callback")
}

@MainActor
private func verifyNativeRawPNGPaste(
    _ webView: WKWebView,
    window: NSWindow,
    pngData: Data,
    recorder: DropRecorder,
    eventProbe: ApplicationKeyEventProbe,
    modifiers: NSEvent.ModifierFlags = .command,
    label: String = "raw PNG paste"
) throws {
    reset(recorder)
    try putRawPNGOnGeneralPasteboard(pngData)
    try focusOrdinaryPasteTarget(webView)
    let pasteEventsBefore = try DOMPasteEventCount(webView)

    try sendCommandVThroughApplication(to: webView, window: window, modifiers: modifiers)

    try runLoop(
        until: { recorder.imagePastes.count == 1 },
        timeout: 3,
        label: "\(label) session resolution"
    )
    try require(recorder.states.isEmpty, "\(label) activated the drag overlay")
    try require(recorder.drops.isEmpty, "\(label) invoked the file-URL callback")
    try require(recorder.imagePastes.count == 1, "\(label) invoked the image callback more than once")
    let pasted = recorder.imagePastes[0]
    try require(pasted.fileExtension == "png", "\(label) reported a non-PNG extension")
    try require(pasted.sessionID == "session-A", "\(label) did not bind to session-A")
    guard let source = CGImageSourceCreateWithData(pasted.data as CFData, nil),
          CGImageSourceGetCount(source) == 1,
          CGImageSourceGetType(source) as String? == "public.png",
          CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
        throw WebViewDropQAFailure.message("\(label) callback data was not a decodable PNG")
    }
    let pasteEventsAfter = try DOMPasteEventCount(webView)
    try require(pasteEventsAfter == pasteEventsBefore,
                "managed DeepSeek \(label) leaked into WebKit")
}

@MainActor
private func verifyRawPNGPastePassThrough(
    _ webView: WKWebView,
    window: NSWindow,
    pngData: Data,
    recorder: DropRecorder,
    eventProbe: ApplicationKeyEventProbe
) throws {
    reset(recorder)
    try putRawPNGOnGeneralPasteboard(pngData)
    window.makeKeyAndOrderFront(nil)
    try require(window.makeFirstResponder(webView), "WKWebView did not accept Kimi paste focus")
    try focusOrdinaryPasteTarget(webView)
    _ = webView.performKeyEquivalent(with: try commandVPasteEvent(window: window))

    try require(recorder.states.isEmpty, "Kimi raw PNG paste activated the drag overlay")
    try require(recorder.drops.isEmpty, "Kimi raw PNG paste invoked the native file callback")
    try require(recorder.imagePastes.isEmpty, "Kimi raw PNG paste invoked the native image callback")
}

@MainActor
private func verifyNativeCancellation(
    _ webView: WKWebView,
    window: NSWindow,
    pasteboard: NSPasteboard,
    recorder: DropRecorder,
    probe: WebKitSuperclassProbe
) throws {
    reset(recorder)
    let performCallsBefore = probe.performCalls
    let concludeCallsBefore = probe.concludeCalls
    let dragging = FixtureDraggingInfo(pasteboard: pasteboard, destinationWindow: window)

    try require(webView.draggingEntered(dragging) == .copy, "native cancellation fixture was not accepted")
    webView.draggingExited(dragging)

    try require(recorder.states == [true, false], "native drag exit did not balance the overlay lifecycle")
    try require(recorder.drops.isEmpty, "native drag exit imported a file without a drop")
    try require(probe.performCalls == performCallsBefore, "native drag exit reached WKWebView perform")
    try require(probe.concludeCalls == concludeCallsBefore, "native drag exit reached WKWebView conclude")
}

private func requireSourceContract(_ source: String, contains snippets: [String], label: String) throws {
    for snippet in snippets where !source.contains(snippet) {
        throw WebViewDropQAFailure.message("\(label) lost required contract: \(snippet)")
    }
}

private func requireSourceContract(_ source: String, excludes snippets: [String], label: String) throws {
    for snippet in snippets where source.contains(snippet) {
        throw WebViewDropQAFailure.message("\(label) retained forbidden contract: \(snippet)")
    }
}

private func verifyStaticContracts(workspace: URL) throws {
    let harnessWebViewURL = workspace
        .appendingPathComponent("app/Sources/DeepSeekHarnessMac/Views/HarnessWebView.swift")
    let artifactStoreURL = workspace
        .appendingPathComponent("app/Sources/DeepSeekHarnessMac/Services/ArtifactStore.swift")
    let contentViewURL = workspace
        .appendingPathComponent("app/Sources/DeepSeekHarnessMac/Views/ContentView.swift")
    let modelCapabilityStoreURL = workspace
        .appendingPathComponent("app/Sources/DeepSeekHarnessMac/Services/ModelCapabilityStore.swift")
    let pluginURL = workspace.appendingPathComponent(
        "integration/dsh-home-template/profiles/web/node_modules/@tengqi/dsh-native-attachments/lib/client.js"
    )

    let web = try String(contentsOf: harnessWebViewURL, encoding: .utf8)
    let artifacts = try String(contentsOf: artifactStoreURL, encoding: .utf8)
    let content = try String(contentsOf: contentViewURL, encoding: .utf8)
    let modelCapabilities = try String(contentsOf: modelCapabilityStoreURL, encoding: .utf8)
    let plugin = try String(contentsOf: pluginURL, encoding: .utf8)

    try requireSourceContract(web, contains: [
        "private var consumedCurrentNativeDrag = false",
        "if isHandlingNativeFileDrag || consumedCurrentNativeDrag",
        "consumedCurrentNativeDrag = false\n            onNativeFileDragStateChanged?(false)\n            return",
        "return super.performDragOperation(sender)",
        "pendingAttachmentPayloads.first(where:",
        "payload.deliveryState == .accepted",
        "queue.push({ payload, replay: nativeReplay })",
        "window[queueKey] = queue.slice(-32)",
        "attachmentDispatchFailureCounts",
        "let retryDelays: [TimeInterval] = [0.1, 0.25, 0.5, 1.0, 2.0]",
        "attachmentLifecycleMessageName",
        "handleAttachmentLifecycle",
        "CFGetTypeID(number) != CFBooleanGetTypeID()",
        "applyLifecycleToPendingMirror(event)",
        "deepseek-harness:native-attachment-lifecycle",
        "resolveNativeAttachmentSession",
        "var allowsUpstreamImageDrops = false",
        "guard allowsUpstreamImageDrops,",
        "private static let maximumUpstreamImageBytes: Int64 = 5 * 1_024 * 1_024",
        "private static let maximumUpstreamImagesPerMessage = 20",
        "CGImageSourceCreateWithURL",
        "window.addEventListener(\"deepseek-harness:model-route\"",
        "modelRouteValidationGeneration += 1",
        "webView.allowsUpstreamImageDrops = false",
        "activeSessionID == sessionID",
        "let currentHostRouteMatches: (String, String) async -> Bool",
        "let matches = await self.currentHostRouteMatches(providerID, modelID)",
        "guard matches else {",
        "self.supportsDirectImageInput(",
        "override func performKeyEquivalent(with event: NSEvent) -> Bool",
        "NSEvent.addLocalMonitorForEvents(matching: .keyDown)",
        "self.ownsCurrentFirstResponder()",
        "firstResponderView.isDescendant(of: self)",
        "event.window === window",
        "handleNativePasteboardIfNeeded(NSPasteboard.general)",
        "return super.performKeyEquivalent(with: event)",
        "webView.url.map({ !Self.isSameHarnessOrigin($0, as: url) }) ?? true",
        "static func isSameHarnessOrigin(_ candidate: URL, as origin: URL) -> Bool",
        "(webView as? DropAwareWKWebView)?.allowsUpstreamImageDrops = false"
    ], label: "WKWebView native lifecycle/FIFO/replay/model route")

    try requireSourceContract(artifacts, contains: [
        "let sessionID: String",
        "let deliveryState: DeliveryState",
        "@Published private(set) var nativeAttachmentPayloads: [NativeAttachmentPayload] = []",
        "self.nativeAttachmentPayloads.append(payload)",
        "maximumNativeAttachmentPayloads = 32",
        "$0.deliveryState == .pending",
        "let acceptedIndex = self.nativeAttachmentPayloads.firstIndex",
        "func handleNativeAttachmentLifecycle(_ event: NativeAttachmentLifecycleEvent)",
        "case .removed:",
        "sessionID: targetSessionID"
    ], label: "ArtifactStore FIFO/session")

    try requireSourceContract(content, contains: [
        "nativeAttachmentPayloads: artifactStore.nativeAttachmentPayloads",
        "supportsDirectImageInput: { providerID, modelID in",
        "modelCapabilityStore.supportsDirectImageInput(",
        "currentHostRouteMatches: { providerID, modelID in",
        "await harness.currentHostRouteMatches(",
        "onFileURLsDropped: { urls, sessionID in",
        "targetSessionID: sessionID",
        "onImageDataPasted: { data, fileExtension, sessionID in",
        "artifactStore.importPastedImageData(",
        "onNativeAttachmentLifecycle: { event in",
        "artifactStore.handleNativeAttachmentLifecycle(event)",
        "Label(\"上下文与附件\"",
        "Label(\"创建 Appshot…\", systemImage: \"macwindow.badge.plus\")",
        "Label(\"打开研究文件库…\", systemImage: \"tray.full\")",
        "Label(\"附加运行中的应用\", systemImage: \"macwindow.and.cursorarrow\")",
        "attachmentStore.selectedApplicationName.map { \"已附加 \\($0)\" } ?? \"未附加应用\""
    ], label: "ContentView session/model handoff")

    try requireSourceContract(content, excludes: [
        "Label(\"导入文件\", systemImage: \"doc.badge.plus\")",
        "Label(\"Appshot\", systemImage: \"macwindow.badge.plus\")",
        "Label(\"研究文件\", systemImage: \"folder.badge.gearshape\")"
    ], label: "ContentView consolidated toolbar")

    try requireSourceContract(modelCapabilities, contains: [
        "func supportsDirectImageInput(providerID: String, modelID: String) -> Bool",
        "guard !isExpired,",
        "capability.image == \"supported\"",
        "model.lifecycle == \"active\"",
        "model.input?.contains(\"image\") == true"
    ], label: "verified model capability intersection")

    try requireSourceContract(plugin, contains: [
        "const PAYLOAD_KEYS = Object.freeze([\"attachments\", \"revision\", \"sessionId\", \"version\"])",
        "const QUEUE_ROW_KEYS = Object.freeze([\"payload\", \"replay\"])",
        "store.planReplay(sessionId, effectivePayload, draft)",
        "if (!replay && planned.nextDraft !== draft) input.setDraft(planned.nextDraft)",
        "input = inputForSession(sessionId)",
        "Array.prototype.splice.call(queue, 0, queueLength, ...retained)",
        "const MODEL_ROUTE_EVENT_NAME = \"deepseek-harness:model-route\"",
        "const LIFECYCLE_EVENT_NAME = \"deepseek-harness:native-attachment-lifecycle\"",
        "ctx.slots.inject(\"shell.overlay\"",
        "store.entryExact(",
        "reconcileSessionAndPublish(originSessionId, committedDraft)",
        "getSnapshot: () => store.snapshotAll()",
        "publishLifecycle(\"removed\"",
        "route = modelRouteFromState(currentSessionId, directory.store.getSnapshot())",
        "publish(null, true)"
    ], label: "browser plugin FIFO/session/replay/model publisher")
}

@main
@MainActor
private struct WebViewFileDropQA {
    static func main() throws {
        guard let fixtureRootPath = ProcessInfo.processInfo.environment["WEBVIEW_DROP_QA_ROOT"],
              !fixtureRootPath.isEmpty else {
            throw WebViewDropQAFailure.message("WEBVIEW_DROP_QA_ROOT is required")
        }

        let sourceFile = URL(fileURLWithPath: #filePath)
        let workspace = sourceFile.deletingLastPathComponent().deletingLastPathComponent()
        try verifyStaticContracts(workspace: workspace)

        let harnessOrigin = URL(string: "http://127.0.0.1:9")!
        try require(
            HarnessWebView.isSameHarnessOrigin(
                URL(string: "http://127.0.0.1:9/")!,
                as: harnessOrigin
            ),
            "a trailing slash made the same Harness origin look different"
        )
        try require(
            HarnessWebView.isSameHarnessOrigin(
                URL(string: "http://127.0.0.1:9/session/local?view=chat#composer")!,
                as: harnessOrigin
            ),
            "a same-origin client route made the native shell reload Harness"
        )
        try require(
            !HarnessWebView.isSameHarnessOrigin(
                URL(string: "http://127.0.0.1:10/")!,
                as: harnessOrigin
            ),
            "a different Harness port was accepted as the current origin"
        )

        let fixtures = try makeFixtures(in: URL(fileURLWithPath: fixtureRootPath, isDirectory: true))
        let recorder = DropRecorder()
        let routeRecorder = RouteRecorder()
        let hostRouteRecorder = HostRouteRecorder(
            provider: "deepseek",
            model: "DeepSeek-V4-Flash"
        )
        let lifecycleRecorder = LifecycleRecorder()
        _ = NSApplication.shared
        let generalPasteboardSnapshot = GeneralPasteboardSnapshot()
        defer { generalPasteboardSnapshot.restore() }
        let applicationKeyEventProbe = ApplicationKeyEventProbe()
        applicationKeyEventProbe.install()
        defer { applicationKeyEventProbe.uninstall() }

        let representable = HarnessWebView(
            url: URL(string: "http://127.0.0.1:9/")!,
            reloadToken: 0,
            nativeAttachmentPayloads: [],
            supportsDirectImageInput: { providerID, modelID in
                routeRecorder.supports(provider: providerID, model: modelID)
            },
            currentHostRouteMatches: { providerID, modelID in
                await MainActor.run {
                    hostRouteRecorder.matches(provider: providerID, model: modelID)
                }
            },
            onFileDragStateChanged: { recorder.states.append($0) },
            onFileURLsDropped: { urls, sessionID in recorder.drops.append((urls, sessionID)) },
            onImageDataPasted: { data, fileExtension, sessionID in
                recorder.imagePastes.append((data, fileExtension, sessionID))
            },
            onNativeAttachmentLifecycle: { lifecycleRecorder.record($0) },
            onFailure: { _ in }
        )
        let hostingView = NSHostingView(rootView: representable.frame(width: 720, height: 480))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()

        try runLoop(
            until: { descendantWebView(of: hostingView) != nil },
            timeout: 3,
            label: "SwiftUI representable to create its real WKWebView"
        )
        guard let webView = descendantWebView(of: hostingView) else {
            throw WebViewDropQAFailure.message("HarnessWebView did not expose a WKWebView descendant")
        }

        // Replace the unreachable port load with a deterministic same-process page.
        let navigationWaiter = NavigationWaiter()
        webView.navigationDelegate = navigationWaiter
        webView.loadHTMLString(
            """
            <html><body>
            <textarea id="ordinary-paste-target" aria-label="ordinary paste target"></textarea>
            drop fixture<script>
            window.__nativePasteQAEventCount = 0;
            document.addEventListener("paste", () => {
              window.__nativePasteQAEventCount += 1;
            }, true);
            window.__deepSeekHarnessResolveNativeAttachmentSession = () => 'session-A';
            </script></body></html>
            """,
            baseURL: URL(string: "http://127.0.0.1:9/")!
        )
        try runLoop(
            until: { navigationWaiter.finished || navigationWaiter.failure != nil },
            timeout: 5,
            label: "local WKWebView fixture page"
        )
        if let failure = navigationWaiter.failure {
            throw WebViewDropQAFailure.message("local WKWebView fixture failed: \(failure.localizedDescription)")
        }

        let lifecycleAttachmentID = "Inbox/11111111-1111-4111-8111-111111111111/fixture.pdf"
        try publishAttachmentLifecycle(
            to: webView,
            detail: [
                "version": 1,
                "type": "accepted",
                "revision": 71,
                "sessionId": "session-A",
                "attachmentIds": [lifecycleAttachmentID]
            ],
            recorder: lifecycleRecorder,
            expectedCount: 1
        )
        try require(lifecycleRecorder.events[0] == NativeAttachmentLifecycleEvent(
            kind: .accepted,
            revision: 71,
            sessionID: "session-A",
            attachmentIDs: [lifecycleAttachmentID]
        ), "accepted lifecycle event changed across the real WKWebView relay")
        try publishAttachmentLifecycle(
            to: webView,
            detail: [
                "version": 1,
                "type": "removed",
                "revision": 71,
                "sessionId": "session-A",
                "attachmentIds": [lifecycleAttachmentID]
            ],
            recorder: lifecycleRecorder,
            expectedCount: 2
        )
        try require(lifecycleRecorder.events[1].kind == .removed, "removed lifecycle event was not relayed")
        try publishAttachmentLifecycle(
            to: webView,
            detail: [
                "version": true,
                "type": "accepted",
                "revision": 72,
                "sessionId": "session-A",
                "attachmentIds": [lifecycleAttachmentID]
            ],
            recorder: lifecycleRecorder,
            expectedCount: 2
        )
        try publishAttachmentLifecycle(
            to: webView,
            detail: [
                "version": 1,
                "type": "accepted",
                "revision": true,
                "sessionId": "session-A",
                "attachmentIds": [lifecycleAttachmentID]
            ],
            recorder: lifecycleRecorder,
            expectedCount: 2
        )
        try require(lifecycleRecorder.events.count == 2, "JavaScript booleans bypassed strict integer validation")

        let probe = WebKitSuperclassProbe()
        try probe.install()
        defer { probe.uninstall() }

        // No browser route has been published yet: fail closed even for a valid PNG.
        try verifyNativeLifecycle(
            webView,
            window: window,
            pasteboard: makeFilePasteboard([fixtures.png]),
            expectedURLs: [fixtures.png],
            recorder: recorder,
            probe: probe,
            label: "valid PNG before model route"
        )

        // Reproduce the visible route from the product UI exactly. DeepSeek's
        // current text-only Flash route must be consumed by the managed native
        // path, including a pure PNG/JPEG batch. Reaching WKWebView here would
        // let the upstream composer display its "model does not support image"
        // toast instead of creating managed attachment cards.
        let deepSeekRoute: [String: Any] = [
            "version": 1,
            "sessionId": "session-A",
            "provider": "deepseek",
            "model": "DeepSeek-V4-Flash"
        ]
        try publishModelRoute(
            to: webView,
            route: deepSeekRoute,
            routeRecorder: routeRecorder,
            expectedQuery: ("deepseek", "DeepSeek-V4-Flash")
        )
        try verifyNativeLifecycle(
            webView,
            window: window,
            pasteboard: makeFilePasteboard([fixtures.png]),
            expectedURLs: [fixtures.png],
            recorder: recorder,
            probe: probe,
            label: "valid PNG on the visible DeepSeek-V4-Flash route"
        )
        try verifyNativeLifecycle(
            webView,
            window: window,
            pasteboard: makeFilePasteboard([fixtures.png, fixtures.jpg]),
            expectedURLs: [fixtures.png, fixtures.jpg],
            recorder: recorder,
            probe: probe,
            label: "pure PNG/JPEG batch on the visible DeepSeek-V4-Flash route"
        )

        // The pinned registry spelling must remain text-only as well. Keeping
        // both the live UI spelling and the registry spelling in this fixture
        // prevents a provider/model alias change from silently reopening the
        // upstream image path.
        let deepSeekProRoute: [String: Any] = [
            "version": 1,
            "sessionId": "session-A",
            "provider": "deepseek-official",
            "model": "deepseek-v4-pro"
        ]
        hostRouteRecorder.set(provider: "deepseek-official", model: "deepseek-v4-pro")
        try publishModelRoute(
            to: webView,
            route: deepSeekProRoute,
            routeRecorder: routeRecorder,
            expectedQuery: ("deepseek-official", "deepseek-v4-pro")
        )
        try verifyNativeLifecycle(
            webView,
            window: window,
            pasteboard: makeFilePasteboard([fixtures.jpg]),
            expectedURLs: [fixtures.jpg],
            recorder: recorder,
            probe: probe,
            label: "valid JPEG on the pinned DeepSeek Pro route"
        )
        try verifyNativeFileURLPaste(
            webView,
            window: window,
            url: fixtures.png,
            recorder: recorder,
            eventProbe: applicationKeyEventProbe,
            label: "general-pasteboard PNG file URL on DeepSeek Pro"
        )
        try verifyOrdinaryTextPastePassThrough(
            webView,
            window: window,
            recorder: recorder,
            eventProbe: applicationKeyEventProbe
        )
        try verifyFilePasteIgnoredOutsideWebView(
            webView,
            window: window,
            hostingView: hostingView,
            url: fixtures.png,
            recorder: recorder
        )
        try verifyNativeRawPNGPaste(
            webView,
            window: window,
            pngData: try Data(contentsOf: fixtures.png),
            recorder: recorder,
            eventProbe: applicationKeyEventProbe
        )
        try verifyNativeRawPNGPaste(
            webView,
            window: window,
            pngData: try Data(contentsOf: fixtures.png),
            recorder: recorder,
            eventProbe: applicationKeyEventProbe,
            modifiers: [.command, .capsLock],
            label: "raw PNG paste with Caps Lock"
        )

        // The companion must not use the display name as the authorization
        // key. This is the exact configured DeepSeek Vision model ID. Once
        // the live Host route matches, a pure image must remain an upstream
        // image attachment: no native payload, no managed-reference draft text.
        let deepSeekFlashVisionRoute: [String: Any] = [
            "version": 1,
            "sessionId": "session-A",
            "provider": "deepseek-official",
            "model": "deepseek-v4-flash-vision-exp"
        ]
        hostRouteRecorder.set(
            provider: "deepseek-official",
            model: "deepseek-v4-flash-vision-exp"
        )
        let hostChecksBeforeMatchingFlashVision = hostRouteRecorder.checks.count
        try publishModelRoute(
            to: webView,
            route: deepSeekFlashVisionRoute,
            routeRecorder: routeRecorder,
            expectedQuery: ("deepseek-official", "deepseek-v4-flash-vision-exp")
        )
        try runLoop(
            until: {
                hostRouteRecorder.checks.count == hostChecksBeforeMatchingFlashVision + 1
            },
            timeout: 3,
            label: "matching DeepSeek Flash Vision Host route validation"
        )
        try verifyRawPNGPastePassThrough(
            webView,
            window: window,
            pngData: try Data(contentsOf: fixtures.png),
            recorder: recorder,
            eventProbe: applicationKeyEventProbe
        )
        for (label, url) in [("Flash Vision PNG", fixtures.png), ("Flash Vision JPG", fixtures.jpg)] {
            try verifyPassThrough(
                webView,
                window: window,
                pasteboard: makeFilePasteboard([url]),
                recorder: recorder,
                probe: probe,
                label: label
            )
        }

        // A delayed capability event from another conversation must not grant
        // upstream image handling to the active DeepSeek conversation. The
        // page resolver still reports session-A, while this Kimi route belongs
        // to session-B. This is the smallest race that can recreate the toast
        // observed with a text-only model selected in the visible composer.
        let staleKimiRoute: [String: Any] = [
            "version": 1,
            "sessionId": "session-B",
            "provider": "moonshotai-cn",
            "model": "kimi-k3"
        ]
        let capabilityQueriesBeforeStaleRoute = routeRecorder.queries.count
        try publishModelRoute(
            to: webView,
            route: staleKimiRoute,
            routeRecorder: routeRecorder,
            expectedQuery: nil
        )
        try require(
            routeRecorder.queries.count == capabilityQueriesBeforeStaleRoute,
            "a stale Kimi route queried capabilities before matching its session"
        )
        try verifyNativeLifecycle(
            webView,
            window: window,
            pasteboard: makeFilePasteboard([fixtures.png]),
            expectedURLs: [fixtures.png],
            recorder: recorder,
            probe: probe,
            label: "stale Kimi route from session-B while DeepSeek session-A is active"
        )

        // Session identity alone is insufficient during a same-conversation
        // model switch. A delayed Kimi event can still belong to session-A
        // after the page/Host has already switched that session to DeepSeek
        // Pro. Passing the capability registry is not sufficient: the Host's
        // current provider/model must also match before passthrough is enabled.
        let kimiRoute: [String: Any] = [
            "version": 1,
            "sessionId": "session-A",
            "provider": "moonshotai-cn",
            "model": "kimi-k3"
        ]
        let capabilityQueriesBeforeSameSessionStaleRoute = routeRecorder.queries.count
        let hostChecksBeforeSameSessionStaleRoute = hostRouteRecorder.checks.count
        try publishModelRoute(
            to: webView,
            route: kimiRoute,
            routeRecorder: routeRecorder,
            expectedQuery: nil
        )
        try runLoop(
            until: {
                hostRouteRecorder.checks.count == hostChecksBeforeSameSessionStaleRoute + 1
            },
            timeout: 3,
            label: "same-session Kimi Host route validation"
        )
        try require(
            hostRouteRecorder.checks.count == hostChecksBeforeSameSessionStaleRoute + 1,
            "a same-session Kimi route was not checked against the Host's current provider/model"
        )
        try require(
            routeRecorder.queries.count == capabilityQueriesBeforeSameSessionStaleRoute,
            "a stale same-session Kimi route queried capabilities while the Host route was DeepSeek Pro"
        )
        try verifyNativeLifecycle(
            webView,
            window: window,
            pasteboard: makeFilePasteboard([fixtures.png]),
            expectedURLs: [fixtures.png],
            recorder: recorder,
            probe: probe,
            label: "stale same-session Kimi route while the Host route is DeepSeek Pro"
        )

        // Only an exact match between the active session, the page/Host's live
        // provider/model, and the verified Kimi event enables the official
        // upstream image path.
        hostRouteRecorder.set(provider: "moonshotai-cn", model: "kimi-k3")
        let hostChecksBeforeMatchingKimiRoute = hostRouteRecorder.checks.count
        try publishModelRoute(
            to: webView,
            route: kimiRoute,
            routeRecorder: routeRecorder,
            expectedQuery: ("moonshotai-cn", "kimi-k3")
        )
        try runLoop(
            until: {
                hostRouteRecorder.checks.count == hostChecksBeforeMatchingKimiRoute + 1
            },
            timeout: 3,
            label: "matching Kimi Host route validation"
        )
        try require(
            hostRouteRecorder.checks.count == hostChecksBeforeMatchingKimiRoute + 1,
            "an exact same-session Kimi route did not revalidate against the Host"
        )
        try verifyRawPNGPastePassThrough(
            webView,
            window: window,
            pngData: try Data(contentsOf: fixtures.png),
            recorder: recorder,
            eventProbe: applicationKeyEventProbe
        )
        for (label, url) in [
            ("PNG", fixtures.png),
            ("JPG", fixtures.jpg),
            ("WebP", fixtures.webp),
            ("GIF", fixtures.gif)
        ] {
            try verifyPassThrough(
                webView,
                window: window,
                pasteboard: makeFilePasteboard([url]),
                recorder: recorder,
                probe: probe,
                label: label
            )
        }
        try verifyPassThrough(
            webView,
            window: window,
            pasteboard: makeFilePasteboard(fixtures.supportedImages),
            recorder: recorder,
            probe: probe,
            label: "four supported image formats in one Kimi batch"
        )
        try verifyPassThrough(
            webView,
            window: window,
            pasteboard: makeFilePasteboard(Array(fixtures.imageSet21.prefix(20))),
            recorder: recorder,
            probe: probe,
            label: "twenty verified PNG images"
        )

        // Non-file drags remain WebKit-owned regardless of model route.
        try verifyPassThrough(
            webView,
            window: window,
            pasteboard: makeTextPasteboard(),
            recorder: recorder,
            probe: probe,
            label: "non-file text drag"
        )

        // Non-image and mixed batches remain native even when Kimi supports images.
        try verifyNativeLifecycle(
            webView,
            window: window,
            pasteboard: makeFilePasteboard([fixtures.pdf]),
            expectedURLs: [fixtures.pdf],
            recorder: recorder,
            probe: probe,
            label: "PDF"
        )
        try verifyNativeLifecycle(
            webView,
            window: window,
            pasteboard: makeFilePasteboard([fixtures.code]),
            expectedURLs: [fixtures.code],
            recorder: recorder,
            probe: probe,
            label: "code"
        )
        try verifyNativeLifecycle(
            webView,
            window: window,
            pasteboard: makeFilePasteboard([fixtures.png, fixtures.pdf]),
            expectedURLs: [fixtures.png, fixtures.pdf],
            recorder: recorder,
            probe: probe,
            label: "mixed image and PDF"
        )
        try verifyNativeLifecycle(
            webView,
            window: window,
            pasteboard: makeFilePasteboard([fixtures.spoofPNG]),
            expectedURLs: [fixtures.spoofPNG],
            recorder: recorder,
            probe: probe,
            label: "spoofed PNG bytes"
        )
        try verifyNativeLifecycle(
            webView,
            window: window,
            pasteboard: makeFilePasteboard([fixtures.oversizedPNG]),
            expectedURLs: [fixtures.oversizedPNG],
            recorder: recorder,
            probe: probe,
            label: "PNG above the 5 MiB direct limit"
        )
        try verifyNativeLifecycle(
            webView,
            window: window,
            pasteboard: makeFilePasteboard(fixtures.imageSet21),
            expectedURLs: fixtures.imageSet21,
            recorder: recorder,
            probe: probe,
            label: "twenty-one image batch"
        )

        // A null route immediately revokes the previous Kimi permission.
        try publishModelRoute(
            to: webView,
            route: nil,
            routeRecorder: routeRecorder,
            expectedQuery: nil
        )
        try verifyNativeLifecycle(
            webView,
            window: window,
            pasteboard: makeFilePasteboard([fixtures.png]),
            expectedURLs: [fixtures.png],
            recorder: recorder,
            probe: probe,
            label: "valid PNG after null route"
        )

        // An unknown model also fails closed through the verified capability closure.
        let unknownRoute: [String: Any] = [
            "version": 1,
            "sessionId": "session-A",
            "provider": "moonshotai-cn",
            "model": "unknown-model"
        ]
        hostRouteRecorder.set(provider: "moonshotai-cn", model: "unknown-model")
        try publishModelRoute(
            to: webView,
            route: unknownRoute,
            routeRecorder: routeRecorder,
            expectedQuery: ("moonshotai-cn", "unknown-model")
        )
        try verifyNativeLifecycle(
            webView,
            window: window,
            pasteboard: makeFilePasteboard([fixtures.png]),
            expectedURLs: [fixtures.png],
            recorder: recorder,
            probe: probe,
            label: "valid PNG on unknown model"
        )
        try verifyNativeCancellation(
            webView,
            window: window,
            pasteboard: makeFilePasteboard([fixtures.pdf]),
            recorder: recorder,
            probe: probe
        )

        window.contentView = nil
        print("WEBVIEW_FILE_DROP_QA_OK pass_through=10 native=14 pastes=5 cancelled=1 model_routes=8 image_limits=3 real_wkwebview=1 superclass_probe=1 local_event_monitor=1 static_contracts=5")
    }
}
