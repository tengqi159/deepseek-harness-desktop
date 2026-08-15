import AppKit
import CoreFoundation
import ImageIO
import SwiftUI
import WebKit

struct HarnessWebView: NSViewRepresentable {
    let url: URL
    let reloadToken: Int
    let nativeAttachmentPayloads: [NativeAttachmentPayload]
    let supportsDirectImageInput: (String, String) -> Bool
    let onFileDragStateChanged: (Bool) -> Void
    let onFileURLsDropped: ([URL], String?) -> Void
    let onNativeAttachmentLifecycle: (NativeAttachmentLifecycleEvent) -> Void
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onFailure: onFailure,
            reloadToken: reloadToken,
            allowedOrigin: url,
            supportsDirectImageInput: supportsDirectImageInput,
            onNativeAttachmentLifecycle: onNativeAttachmentLifecycle
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(
            context.coordinator,
            name: Coordinator.modelRouteMessageName
        )
        configuration.userContentController.add(
            context.coordinator,
            name: Coordinator.attachmentLifecycleMessageName
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Coordinator.nativeEventRelayScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        let webView = DropAwareWKWebView(frame: .zero, configuration: configuration)
        webView.onNativeFileDragStateChanged = onFileDragStateChanged
        webView.onNativeFileURLsDropped = onFileURLsDropped
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.allowedOrigin = url
        context.coordinator.supportsDirectImageInput = supportsDirectImageInput
        context.coordinator.pendingAttachmentPayloads = nativeAttachmentPayloads

        if let dropAwareWebView = webView as? DropAwareWKWebView {
            dropAwareWebView.onNativeFileDragStateChanged = onFileDragStateChanged
            dropAwareWebView.onNativeFileURLsDropped = onFileURLsDropped
        }

        if webView.url?.absoluteString != url.absoluteString,
           !webView.isLoading {
            webView.load(URLRequest(url: url))
        }

        if context.coordinator.reloadToken != reloadToken {
            context.coordinator.reloadToken = reloadToken
            webView.reload()
        }

        context.coordinator.dispatchPendingAttachmentsIfPossible(to: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.modelRouteMessageName
        )
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.attachmentLifecycleMessageName
        )
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let modelRouteMessageName = "deepSeekHarnessModelRoute"
        static let attachmentLifecycleMessageName = "deepSeekHarnessNativeAttachmentLifecycle"
        static let nativeEventRelayScript = """
        window.addEventListener("deepseek-harness:model-route", (event) => {
          const handler = window.webkit?.messageHandlers?.deepSeekHarnessModelRoute;
          if (handler === undefined) return;
          const route = event.detail;
          handler.postMessage(route === null ? { version: 1 } : route);
        });
        window.addEventListener("deepseek-harness:native-attachment-lifecycle", (event) => {
          const handler = window.webkit?.messageHandlers?.deepSeekHarnessNativeAttachmentLifecycle;
          if (handler === undefined) return;
          handler.postMessage(event.detail);
        });
        """

        let onFailure: (String) -> Void
        var reloadToken: Int
        var allowedOrigin: URL
        var supportsDirectImageInput: (String, String) -> Bool
        var pendingAttachmentPayloads: [NativeAttachmentPayload] = []
        private let onNativeAttachmentLifecycle: (NativeAttachmentLifecycleEvent) -> Void
        private var dispatchedAttachmentRevisions = Set<Int>()
        private var attachmentDispatchFailureCounts: [Int: Int] = [:]
        private var isDispatchingAttachments = false
        private var pageGeneration = 0
        private var modelRouteValidationGeneration = 0

        init(
            onFailure: @escaping (String) -> Void,
            reloadToken: Int,
            allowedOrigin: URL,
            supportsDirectImageInput: @escaping (String, String) -> Bool,
            onNativeAttachmentLifecycle: @escaping (NativeAttachmentLifecycleEvent) -> Void
        ) {
            self.onFailure = onFailure
            self.reloadToken = reloadToken
            self.allowedOrigin = allowedOrigin
            self.supportsDirectImageInput = supportsDirectImageInput
            self.onNativeAttachmentLifecycle = onNativeAttachmentLifecycle
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.frameInfo.isMainFrame,
                  let body = message.body as? [String: Any] else { return }

            switch message.name {
            case Self.modelRouteMessageName:
                guard let webView = message.webView as? DropAwareWKWebView else { return }
                handleModelRoute(body, webView: webView)
            case Self.attachmentLifecycleMessageName:
                handleAttachmentLifecycle(body)
            default:
                return
            }
        }

        private func handleModelRoute(
            _ body: [String: Any],
            webView: DropAwareWKWebView
        ) {
            // A route publication is asynchronous relative to session changes.
            // Revoke upstream image handling first, then grant it only after the
            // route's session still matches the page's live composer session.
            // This prevents a late image-capable route from another conversation
            // from leaking into a text-only DeepSeek draft.
            modelRouteValidationGeneration += 1
            let validationGeneration = modelRouteValidationGeneration
            let validationPageGeneration = pageGeneration
            webView.allowsUpstreamImageDrops = false

            guard Self.strictInteger(body["version"], minimum: 1, maximum: 1) == 1 else {
                return
            }
            if Set(body.keys) == Set(["version"]) {
                return
            }

            guard Set(body.keys) == Set(["version", "sessionId", "provider", "model"]),
                  let sessionID = Self.boundedRouteText(body["sessionId"], maximum: 1_024),
                  let providerID = Self.boundedRouteText(body["provider"], maximum: 256),
                  let modelID = Self.boundedRouteText(body["model"], maximum: 512),
                  !sessionID.isEmpty else {
                return
            }

            let script = """
            const resolver = window.__deepSeekHarnessResolveNativeAttachmentSession;
            if (typeof resolver !== "function") return null;
            const value = resolver();
            return typeof value === "string" && value.length > 0 ? value : null;
            """
            webView.callAsyncJavaScript(
                script,
                arguments: [:],
                in: nil,
                in: .page
            ) { [weak self, weak webView] result in
                guard let self, let webView,
                      self.pageGeneration == validationPageGeneration,
                      self.modelRouteValidationGeneration == validationGeneration else {
                    return
                }
                guard case .success(let value) = result,
                      let activeSessionID = value as? String,
                      activeSessionID == sessionID else {
                    webView.allowsUpstreamImageDrops = false
                    return
                }
                webView.allowsUpstreamImageDrops = self.supportsDirectImageInput(
                    providerID,
                    modelID
                )
            }
        }

        private func handleAttachmentLifecycle(_ body: [String: Any]) {
            let expectedKeys = Set(["version", "type", "revision", "sessionId", "attachmentIds"])
            guard Set(body.keys) == expectedKeys,
                  Self.strictInteger(body["version"], minimum: 1, maximum: 1) == 1,
                  let rawKind = body["type"] as? String,
                  let kind = NativeAttachmentLifecycleEvent.Kind(rawValue: rawKind),
                  let revision = Self.strictInteger(
                      body["revision"],
                      minimum: 1,
                      maximum: 9_007_199_254_740_991
                  ),
                  let sessionID = Self.boundedRouteText(body["sessionId"], maximum: 1_024),
                  let attachmentIDs = body["attachmentIds"] as? [String],
                  !attachmentIDs.isEmpty,
                  attachmentIDs.count <= 32,
                  Set(attachmentIDs).count == attachmentIDs.count,
                  attachmentIDs.allSatisfy({
                      Self.boundedRouteText($0, maximum: 4_096) != nil
                  }) else {
                return
            }
            let event = NativeAttachmentLifecycleEvent(
                kind: kind,
                revision: revision,
                sessionID: sessionID,
                attachmentIDs: attachmentIDs
            )
            applyLifecycleToPendingMirror(event)
            onNativeAttachmentLifecycle(event)
        }

        private static func strictInteger(
            _ value: Any?,
            minimum: Int,
            maximum: Int
        ) -> Int? {
            guard minimum <= maximum,
                  let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else {
                return nil
            }
            let doubleValue = number.doubleValue
            guard doubleValue.isFinite,
                  doubleValue.rounded(.towardZero) == doubleValue,
                  number.compare(NSNumber(value: minimum)) != .orderedAscending,
                  number.compare(NSNumber(value: maximum)) != .orderedDescending else {
                return nil
            }
            return Int(exactly: number.int64Value)
        }

        private func applyLifecycleToPendingMirror(_ event: NativeAttachmentLifecycleEvent) {
            guard let index = pendingAttachmentPayloads.firstIndex(where: {
                $0.revision == event.revision && $0.sessionID == event.sessionID
            }) else {
                return
            }
            let payload = pendingAttachmentPayloads[index]
            let reportedIDs = Set(event.attachmentIDs)
            let currentIDs = Set(payload.attachments.map(\.id))
            switch event.kind {
            case .accepted:
                guard currentIDs.isSubset(of: reportedIDs) else { return }
                pendingAttachmentPayloads[index] = NativeAttachmentPayload(
                    revision: payload.revision,
                    sessionID: payload.sessionID,
                    attachments: payload.attachments,
                    deliveryState: .accepted
                )
            case .removed:
                let remaining = payload.attachments.filter { !reportedIDs.contains($0.id) }
                guard remaining.count != payload.attachments.count else { return }
                if remaining.isEmpty {
                    pendingAttachmentPayloads.remove(at: index)
                } else {
                    pendingAttachmentPayloads[index] = NativeAttachmentPayload(
                        revision: payload.revision,
                        sessionID: payload.sessionID,
                        attachments: remaining,
                        deliveryState: payload.deliveryState
                    )
                }
            }
        }

        private static func boundedRouteText(_ value: Any?, maximum: Int) -> String? {
            guard let value = value as? String,
                  !value.isEmpty,
                  value.count <= maximum,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                return nil
            }
            return value
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let destination = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            if Self.isSameHarnessOrigin(destination, as: allowedOrigin) {
                decisionHandler(.allow)
                return
            }

            if navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(destination)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            dispatchPendingAttachmentsIfPossible(to: webView)
        }

        func webView(
            _ webView: WKWebView,
            didStartProvisionalNavigation navigation: WKNavigation!
        ) {
            (webView as? DropAwareWKWebView)?.allowsUpstreamImageDrops = false
            modelRouteValidationGeneration += 1
            dispatchedAttachmentRevisions.removeAll()
            attachmentDispatchFailureCounts.removeAll()
            isDispatchingAttachments = false
            pageGeneration += 1
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            onFailure(error.localizedDescription)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            onFailure(error.localizedDescription)
        }

        private static func isSameHarnessOrigin(_ url: URL, as origin: URL) -> Bool {
            url.scheme?.lowercased() == "http"
                && url.scheme?.caseInsensitiveCompare(origin.scheme ?? "") == .orderedSame
                && url.host?.caseInsensitiveCompare(origin.host ?? "") == .orderedSame
                && url.port == origin.port
        }

        func dispatchPendingAttachmentsIfPossible(to webView: WKWebView) {
            guard !isDispatchingAttachments,
                  let payload = pendingAttachmentPayloads.first(where: {
                    !dispatchedAttachmentRevisions.contains($0.revision)
                  }),
                  !webView.isLoading,
                  let currentURL = webView.url,
                  Self.isSameHarnessOrigin(currentURL, as: allowedOrigin) else {
                return
            }

            isDispatchingAttachments = true
            let dispatchGeneration = pageGeneration
            let isReplay = payload.deliveryState == .accepted
            let script = """
            const payload = nativePayload;
            const queueKey = "__deepSeekHarnessNativeAttachmentQueue";
            const eventName = "deepseek-harness:native-attachments";
            let accepted = false;
            const detail = {
              payload,
              replay: nativeReplay,
              accept: () => { accepted = true; }
            };
            window.dispatchEvent(new CustomEvent(eventName, { detail }));
            if (!accepted) {
              const queue = Array.isArray(window[queueKey]) ? window[queueKey] : [];
              if (!queue.some((item) => item
                  && item.payload
                  && item.payload.revision === payload.revision
                  && item.replay === nativeReplay)) {
                queue.push({ payload, replay: nativeReplay });
              }
              window[queueKey] = queue.slice(-32);
            }
            return accepted;
            """

            webView.callAsyncJavaScript(
                script,
                arguments: [
                    "nativePayload": payload.javaScriptObject,
                    "nativeReplay": isReplay
                ],
                in: nil,
                in: .page
            ) { [weak self] result in
                guard let self else { return }
                guard self.pageGeneration == dispatchGeneration else { return }
                self.isDispatchingAttachments = false
                switch result {
                case .success:
                    // If the plugin is not ready, the script has placed this exact
                    // delivery in its page-local FIFO. Its later lifecycle ACK will
                    // promote the native source of truth to `.accepted`.
                    self.dispatchedAttachmentRevisions.insert(payload.revision)
                    self.attachmentDispatchFailureCounts.removeValue(forKey: payload.revision)
                    self.dispatchPendingAttachmentsIfPossible(to: webView)
                case .failure:
                    let failureCount = (self.attachmentDispatchFailureCounts[payload.revision] ?? 0) + 1
                    self.attachmentDispatchFailureCounts[payload.revision] = failureCount
                    let retryDelays: [TimeInterval] = [0.1, 0.25, 0.5, 1.0, 2.0]
                    let retryDelay = retryDelays[min(failureCount - 1, retryDelays.count - 1)]
                    DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self, weak webView] in
                        guard let self, let webView,
                              self.pageGeneration == dispatchGeneration,
                              !self.dispatchedAttachmentRevisions.contains(payload.revision),
                              self.pendingAttachmentPayloads.contains(where: {
                                  $0.revision == payload.revision
                              }) else {
                            return
                        }
                        self.dispatchPendingAttachmentsIfPossible(to: webView)
                    }
                }
            }
        }
    }
}

private final class DropAwareWKWebView: WKWebView {
    var onNativeFileDragStateChanged: ((Bool) -> Void)?
    var onNativeFileURLsDropped: (([URL], String?) -> Void)?
    var allowsUpstreamImageDrops = false

    private var isHandlingNativeFileDrag = false
    private var consumedCurrentNativeDrag = false
    private static let upstreamImageExtensions = Set(["png", "jpg", "jpeg", "webp", "gif"])
    private static let upstreamImageTypes = Set([
        "public.png",
        "public.jpeg",
        "org.webmproject.webp",
        "com.compuserve.gif"
    ])
    private static let maximumUpstreamImageBytes: Int64 = 5 * 1_024 * 1_024
    private static let maximumUpstreamImagesPerMessage = 20
    private static let maximumUpstreamMessageImageBytes: Int64 = 100 * 1_024 * 1_024

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        let types = Set(registeredDraggedTypes).union([.fileURL])
        registerForDraggedTypes(Array(types))
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        let types = Set(registeredDraggedTypes).union([.fileURL])
        registerForDraggedTypes(Array(types))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard shouldHandleNatively(sender) else {
            isHandlingNativeFileDrag = false
            return super.draggingEntered(sender)
        }
        isHandlingNativeFileDrag = true
        consumedCurrentNativeDrag = false
        onNativeFileDragStateChanged?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard shouldHandleNatively(sender) else {
            if isHandlingNativeFileDrag {
                isHandlingNativeFileDrag = false
                onNativeFileDragStateChanged?(false)
            }
            return super.draggingUpdated(sender)
        }
        if !isHandlingNativeFileDrag {
            isHandlingNativeFileDrag = true
            onNativeFileDragStateChanged?(true)
        }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if isHandlingNativeFileDrag {
            isHandlingNativeFileDrag = false
            onNativeFileDragStateChanged?(false)
        } else {
            super.draggingExited(sender)
        }
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard shouldHandleNatively(sender) else {
            return super.prepareForDragOperation(sender)
        }
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard shouldHandleNatively(sender) else {
            return super.performDragOperation(sender)
        }
        let urls = Self.fileURLs(from: sender.draggingPasteboard)
        isHandlingNativeFileDrag = false
        consumedCurrentNativeDrag = true
        onNativeFileDragStateChanged?(false)
        guard !urls.isEmpty else { return false }
        resolveNativeAttachmentSession { [weak self] sessionID in
            self?.onNativeFileURLsDropped?(urls, sessionID)
        }
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if isHandlingNativeFileDrag || consumedCurrentNativeDrag {
            isHandlingNativeFileDrag = false
            consumedCurrentNativeDrag = false
            onNativeFileDragStateChanged?(false)
            return
        }
        super.concludeDragOperation(sender)
    }

    private func shouldHandleNatively(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        guard allowsUpstreamImageDrops,
              urls.count <= Self.maximumUpstreamImagesPerMessage else {
            return true
        }
        var totalBytes: Int64 = 0
        for url in urls {
            guard let byteCount = Self.upstreamImageByteCount(url) else { return true }
            let (nextTotal, overflow) = totalBytes.addingReportingOverflow(byteCount)
            guard !overflow,
                  nextTotal <= Self.maximumUpstreamMessageImageBytes else {
                return true
            }
            totalBytes = nextTotal
        }
        return false
    }

    private func resolveNativeAttachmentSession(
        completion: @escaping (String?) -> Void
    ) {
        let script = """
        const resolver = window.__deepSeekHarnessResolveNativeAttachmentSession;
        if (typeof resolver !== "function") return null;
        const value = resolver();
        return typeof value === "string" && value.length > 0 ? value : null;
        """
        callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value):
                completion(value as? String)
            case .failure:
                completion(nil)
            }
        }
    }

    private static func isUpstreamImageFile(_ url: URL) -> Bool {
        guard upstreamImageExtensions.contains(url.pathExtension.lowercased()),
              let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .isAliasFileKey,
                .isPackageKey,
                .fileSizeKey
              ]) else {
            return false
        }
        guard values.isRegularFile == true
            && values.isDirectory != true
            && values.isSymbolicLink != true
            && values.isAliasFile != true
            && values.isPackage != true,
              let fileSize = values.fileSize,
              fileSize >= 0,
              Int64(fileSize) <= maximumUpstreamImageBytes,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String?,
              upstreamImageTypes.contains(type) else {
            return false
        }
        return true
    }

    private static func upstreamImageByteCount(_ url: URL) -> Int64? {
        guard isUpstreamImageFile(url),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= 0 else {
            return nil
        }
        return Int64(size)
    }

    private static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []
        return objects.compactMap { object in
            guard let nsURL = object as? NSURL,
                  let url = nsURL.absoluteURL,
                  url.isFileURL else { return nil }
            return url
        }
    }
}
