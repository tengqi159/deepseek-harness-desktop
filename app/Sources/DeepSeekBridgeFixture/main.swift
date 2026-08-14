import AppKit
import Foundation

private let syntheticSecretProbe = "sk-" + "fixtureredactiontoken4729abcd"

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class PassiveFixtureWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct FixtureOptions {
    let role: String
    let stateURL: URL
    let readyURL: URL?

    init(arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
                return nil
            }
            return arguments[index + 1]
        }

        role = value(after: "--role") ?? "primary"
        let defaultState = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepseek-bridge-fixture-state-\(ProcessInfo.processInfo.processIdentifier).json")
        stateURL = value(after: "--state-file").map { URL(fileURLWithPath: $0) } ?? defaultState
        readyURL = value(after: "--ready-file").map { URL(fileURLWithPath: $0) }
    }
}

@MainActor
private final class FixtureState {
    private let role: String
    private let stateURL: URL
    private(set) var clickCount = 0
    private(set) var secondaryActionCount = 0
    private(set) var scheduledWaitCount = 0
    private(set) var sliderActionCount = 0
    private(set) var keyEventCount = 0
    private(set) var scrollEventCount = 0
    private(set) var lastKeyCode: UInt16?
    private(set) var lastCharacters = ""
    private(set) var lastScrollDeltaX = 0.0
    private(set) var lastScrollDeltaY = 0.0
    private(set) var scrollOriginY = 0.0
    private(set) var scrollDocumentHeight = 0.0
    private(set) var scrollClipHeight = 0.0
    private(set) var scrollFrameInWindow: [String: Double] = [:]
    private(set) var lastScrollLocationInWindow: [String: Double] = [:]
    private(set) var lastScrollWindowNumber = 0
    private(set) var lastScrollHitTestClass = ""
    private(set) var lastScrollHitTestIdentifier = ""
    private(set) var selectionStart = -1
    private(set) var selectionLength = 0
    private(set) var sliderValue = 50.0
    private(set) var waitValue = "WAIT-IDLE"

    init(role: String, stateURL: URL) {
        self.role = role
        self.stateURL = stateURL
    }

    func recordClick(inputValue: String) {
        clickCount += 1
        persist(inputValue: inputValue)
    }

    func recordSecondaryAction(inputValue: String) {
        secondaryActionCount += 1
        persist(inputValue: inputValue)
    }

    func recordScheduledWait(inputValue: String) {
        scheduledWaitCount += 1
        persist(inputValue: inputValue)
    }

    func recordSliderAction(value: Double, inputValue: String) {
        sliderActionCount += 1
        sliderValue = value
        persist(inputValue: inputValue)
    }

    func recordWaitValue(_ value: String, inputValue: String) {
        waitValue = value
        persist(inputValue: inputValue)
    }

    func recordKey(_ event: NSEvent, inputValue: String) {
        keyEventCount += 1
        lastKeyCode = event.keyCode
        lastCharacters = String((event.characters ?? "").prefix(256))
        persist(inputValue: inputValue)
    }

    func recordScroll(
        _ event: NSEvent,
        inputValue: String,
        hitTestClass: String,
        hitTestIdentifier: String
    ) {
        scrollEventCount += 1
        lastScrollDeltaX = event.scrollingDeltaX
        lastScrollDeltaY = event.scrollingDeltaY
        lastScrollLocationInWindow = [
            "x": Double(event.locationInWindow.x),
            "y": Double(event.locationInWindow.y)
        ]
        lastScrollWindowNumber = event.windowNumber
        lastScrollHitTestClass = hitTestClass
        lastScrollHitTestIdentifier = hitTestIdentifier
        persist(inputValue: inputValue)
    }

    func recordScrollGeometry(
        originY: Double,
        documentHeight: Double,
        clipHeight: Double,
        frameInWindow: NSRect,
        selectionStart: Int,
        selectionLength: Int,
        sliderValue: Double,
        waitValue: String,
        inputValue: String
    ) {
        scrollOriginY = originY
        scrollDocumentHeight = documentHeight
        scrollClipHeight = clipHeight
        scrollFrameInWindow = [
            "x": Double(frameInWindow.origin.x),
            "y": Double(frameInWindow.origin.y),
            "width": Double(frameInWindow.width),
            "height": Double(frameInWindow.height)
        ]
        self.selectionStart = selectionStart
        self.selectionLength = selectionLength
        self.sliderValue = sliderValue
        self.waitValue = waitValue
        persist(inputValue: inputValue)
    }

    func persist(inputValue: String) {
        var payload: [String: Any] = [
            "ready": true,
            "role": role,
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "bundle_identifier": Bundle.main.bundleIdentifier ?? "",
            "input_value": inputValue,
            "click_count": clickCount,
            "secondary_action_count": secondaryActionCount,
            "scheduled_wait_count": scheduledWaitCount,
            "slider_action_count": sliderActionCount,
            "slider_value": sliderValue,
            "selection_start": selectionStart,
            "selection_length": selectionLength,
            "wait_value": waitValue,
            "key_event_count": keyEventCount,
            "scroll_event_count": scrollEventCount,
            "last_characters": lastCharacters,
            "last_scroll_delta_x": lastScrollDeltaX,
            "last_scroll_delta_y": lastScrollDeltaY,
            "scroll_origin_y": scrollOriginY,
            "scroll_document_height": scrollDocumentHeight,
            "scroll_clip_height": scrollClipHeight,
            "scroll_frame_in_window": scrollFrameInWindow,
            "last_scroll_location_in_window": lastScrollLocationInWindow,
            "last_scroll_window_number": lastScrollWindowNumber,
            "last_scroll_hit_test_class": lastScrollHitTestClass,
            "last_scroll_hit_test_identifier": lastScrollHitTestIdentifier,
            "updated_at": ISO8601DateFormatter().string(from: Date())
        ]
        if let lastKeyCode { payload["last_key_code"] = Int(lastKeyCode) }

        do {
            let directory = stateURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: stateURL, options: .atomic)
        } catch {
            fputs("DeepSeekBridgeFixture: unable to write state: \(error)\n", stderr)
        }
    }
}

@MainActor
private final class FixtureDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSMenuDelegate {
    private let options: FixtureOptions
    private let state: FixtureState
    private var window: NSWindow!
    private var secondaryWindow: NSWindow?
    private var inputField: NSTextField!
    private var statusLabel: NSTextField!
    private var scrollView: NSScrollView!
    private var secondaryButton: NSButton!
    private var waitLabel: NSTextField!
    private var slider: NSSlider!
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var inputPoller: Timer?
    private var lastPersistedInput = ""

    init(options: FixtureOptions) {
        self.options = options
        state = FixtureState(role: options.role, stateURL: options.stateURL)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        installEventProbes()
        window.center()
        positionScrollAreaUnderPointer()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(inputField)
        persistCurrentState()
        writeReadyMarker()

        inputPoller = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let currentOriginY = Double(self.scrollView.contentView.bounds.origin.y)
                let selection = self.currentSelectionRange()
                guard self.inputField.stringValue != self.lastPersistedInput
                    || abs(currentOriginY - self.state.scrollOriginY) > 0.01
                    || selection.location != self.state.selectionStart
                    || selection.length != self.state.selectionLength
                    || abs(self.slider.doubleValue - self.state.sliderValue) > 0.001
                    || self.waitLabel.stringValue != self.state.waitValue else { return }
                self.persistCurrentState()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        inputPoller?.invalidate()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
    }

    func controlTextDidChange(_ notification: Notification) {
        persistCurrentState()
    }

    @objc private func fixtureButtonPressed(_ sender: Any?) {
        state.recordClick(inputValue: inputField.stringValue)
        refreshStatus()
        window.makeFirstResponder(inputField)
    }

    @objc private func scheduleWaitState(_ sender: Any?) {
        waitLabel.stringValue = "WAIT-PENDING"
        state.recordScheduledWait(inputValue: inputField.stringValue)
        persistCurrentState()
        let timer = Timer(timeInterval: 2.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.waitLabel.stringValue = "WAIT-READY"
                self.state.recordWaitValue("WAIT-READY", inputValue: self.inputField.stringValue)
                self.persistCurrentState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        state.recordSliderAction(value: sender.doubleValue, inputValue: inputField.stringValue)
        persistCurrentState()
    }

    func menuWillOpen(_ menu: NSMenu) {
        state.recordSecondaryAction(inputValue: inputField.stringValue)
        refreshStatus()
        let cancelTimer = Timer(timeInterval: 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.secondaryButton.menu?.cancelTracking()
            }
        }
        RunLoop.main.add(cancelTimer, forMode: .common)
    }

    private func buildWindow() {
        let initialValue: String
        switch options.role {
        case "primary": initialValue = "PRIMARY-INITIAL"
        case "sibling": initialValue = "SIBLING-INITIAL"
        default: initialValue = "DECOY-INITIAL"
        }
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DeepSeek Bridge QA Fixture — \(options.role)"
        window.setFrameAutosaveName("DeepSeekBridgeFixture-\(options.role)")

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let marker = NSTextField(labelWithString: "OCR SAFETY CHECK 4729")
        marker.font = .systemFont(ofSize: 28, weight: .bold)
        marker.textColor = .labelColor
        marker.alignment = .center
        marker.setAccessibilityIdentifier("fixture.ocr-marker")

        let explanation = NSTextField(wrappingLabelWithString: "Disposable local QA app. It contains no user data and closes automatically when the test finishes.")
        explanation.alignment = .center
        explanation.textColor = .secondaryLabelColor
        explanation.setAccessibilityIdentifier("fixture.explanation")

        let redactionProbe = NSTextField(labelWithString: "Synthetic redaction probe: \(syntheticSecretProbe)")
        redactionProbe.textColor = .secondaryLabelColor
        redactionProbe.setAccessibilityIdentifier("fixture.redaction-probe")

        let urlRedactionProbe = NSView()
        urlRedactionProbe.setAccessibilityElement(true)
        urlRedactionProbe.setAccessibilityRole(.staticText)
        urlRedactionProbe.setAccessibilityLabel("Synthetic URL redaction probe")
        urlRedactionProbe.setAccessibilityIdentifier("fixture.url-redaction-probe")
        urlRedactionProbe.setAccessibilityValue(
            URL(string: "https://fixture.invalid/callback?api_key=\(syntheticSecretProbe)")!
        )
        urlRedactionProbe.heightAnchor.constraint(equalToConstant: 1).isActive = true

        inputField = NSTextField(string: initialValue)
        inputField.delegate = self
        inputField.placeholderString = "Bridge input test"
        inputField.setAccessibilityIdentifier("fixture.input")

        let inputLabel = NSTextField(labelWithString: "Editable value")
        inputLabel.setAccessibilityIdentifier("fixture.input-label")
        let inputRow = NSStackView(views: [inputLabel, inputField])
        inputRow.orientation = .horizontal
        inputRow.spacing = 12
        inputLabel.setContentHuggingPriority(.required, for: .horizontal)

        let secureField = NSSecureTextField(string: "fixture-secret-must-be-redacted-4729")
        secureField.setAccessibilityIdentifier("fixture.secure")
        let secureLabel = NSTextField(labelWithString: "Secure value")
        secureLabel.setAccessibilityIdentifier("fixture.secure-label")
        let secureRow = NSStackView(views: [secureLabel, secureField])
        secureRow.orientation = .horizontal
        secureRow.spacing = 12
        secureLabel.setContentHuggingPriority(.required, for: .horizontal)

        let button = NSButton(title: "Fixture Button", target: self, action: #selector(fixtureButtonPressed(_:)))
        button.bezelStyle = .rounded
        button.setAccessibilityIdentifier("fixture.button")
        button.widthAnchor.constraint(equalToConstant: 600).isActive = true

        secondaryButton = NSButton(title: "Secondary Action Target", target: nil, action: nil)
        secondaryButton.bezelStyle = .rounded
        secondaryButton.setAccessibilityIdentifier("fixture.secondary-action")
        let secondaryMenu = NSMenu(title: "Fixture Secondary Menu")
        secondaryMenu.addItem(withTitle: "Safe Fixture Menu Item", action: nil, keyEquivalent: "")
        secondaryMenu.delegate = self
        secondaryButton.menu = secondaryMenu

        let scheduleButton = NSButton(title: "Schedule Wait State", target: self, action: #selector(scheduleWaitState(_:)))
        scheduleButton.bezelStyle = .rounded
        scheduleButton.setAccessibilityIdentifier("fixture.schedule-wait")
        waitLabel = NSTextField(labelWithString: "WAIT-IDLE")
        waitLabel.alignment = .center
        waitLabel.setAccessibilityIdentifier("fixture.wait-state")
        let waitRow = NSStackView(views: [scheduleButton, waitLabel])
        waitRow.orientation = .horizontal
        waitRow.spacing = 12
        scheduleButton.setContentHuggingPriority(.required, for: .horizontal)

        slider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: self, action: #selector(sliderChanged(_:)))
        slider.isContinuous = true
        slider.setAccessibilityIdentifier("fixture.drag-slider")
        slider.setAccessibilityLabel("Fixture Drag Slider")
        let dragTarget = NSTextField(labelWithString: "DRAG TARGET")
        dragTarget.alignment = .center
        dragTarget.setAccessibilityIdentifier("fixture.drag-target")
        dragTarget.setContentHuggingPriority(.required, for: .horizontal)
        let dragRow = NSStackView(views: [slider, dragTarget])
        dragRow.orientation = .horizontal
        dragRow.spacing = 12
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 480).isActive = true

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.alignment = .center
        statusLabel.setAccessibilityIdentifier("fixture.status")

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.setAccessibilityIdentifier("fixture.scroll")
        let rowCount = options.role == "primary" ? 620 : 45
        let rowHeight = 22.0
        let scrollDocument = FlippedDocumentView(
            frame: NSRect(x: 0, y: 0, width: 680, height: Double(rowCount) * rowHeight)
        )
        scrollDocument.setAccessibilityIdentifier("fixture.scroll-content")
        for row in 1...rowCount {
            let filler = options.role == "primary" ? String(repeating: "x", count: 470) : ""
            let label = NSTextField(labelWithString: "Safe fixture payload row \(row) \(filler)")
            label.frame = NSRect(x: 8, y: Double(row - 1) * rowHeight, width: 650, height: 20)
            label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            label.lineBreakMode = .byTruncatingTail
            scrollDocument.addSubview(label)
        }
        scrollView.documentView = scrollDocument
        scrollView.heightAnchor.constraint(equalToConstant: 170).isActive = true

        let stack = NSStackView(views: [marker, explanation, redactionProbe, urlRedactionProbe, inputRow, secureRow, button, secondaryButton, waitRow, dragRow, statusLabel, scrollView])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 14
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24),
            inputField.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
            secureField.widthAnchor.constraint(equalTo: inputField.widthAnchor)
        ])
        refreshStatus()

        if options.role != "decoy" {
            let secondary = PassiveFixtureWindow(
                contentRect: NSRect(x: 80, y: 80, width: 280, height: 130),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            secondary.title = "DeepSeek Bridge QA Secondary"
            let secondaryLabel = NSTextField(wrappingLabelWithString: "SECONDARY QA WINDOW\nThe larger window must be used for OCR.")
            secondaryLabel.alignment = .center
            secondaryLabel.setAccessibilityIdentifier("fixture.secondary-marker")
            secondary.contentView = secondaryLabel
            secondary.orderFront(nil)
            secondaryWindow = secondary
        }
    }

    private func installEventProbes() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                if let self {
                    self.state.recordKey(event, inputValue: self.inputField.stringValue)
                    self.refreshStatus()
                }
            }
            return event
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                if let self {
                    let hitView = event.window?.contentView?.hitTest(event.locationInWindow)
                    self.state.recordScroll(
                        event,
                        inputValue: self.inputField.stringValue,
                        hitTestClass: hitView.map { String(describing: type(of: $0)) } ?? "<none>",
                        hitTestIdentifier: hitView?.identifier?.rawValue ?? ""
                    )
                    self.refreshStatus()
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.persistCurrentState()
                    }
                }
            }
            return event
        }
    }

    private func persistCurrentState() {
        lastPersistedInput = inputField.stringValue
        let selection = currentSelectionRange()
        state.recordScrollGeometry(
            originY: Double(scrollView.contentView.bounds.origin.y),
            documentHeight: Double(scrollView.documentView?.frame.height ?? 0),
            clipHeight: Double(scrollView.contentView.bounds.height),
            frameInWindow: scrollView.convert(scrollView.bounds, to: nil),
            selectionStart: selection.location,
            selectionLength: selection.length,
            sliderValue: slider.doubleValue,
            waitValue: waitLabel.stringValue,
            inputValue: inputField.stringValue
        )
        refreshStatus()
    }

    private func currentSelectionRange() -> (location: Int, length: Int) {
        guard let editor = inputField.currentEditor() as? NSTextView else {
            return (-1, 0)
        }
        let range = editor.selectedRange()
        return (range.location == NSNotFound ? -1 : range.location, range.length)
    }

    private func positionScrollAreaUnderPointer() {
        window.layoutIfNeeded()
        let mouse = NSEvent.mouseLocation
        let scrollCenterInWindow = scrollView.convert(
            NSPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY),
            to: nil
        )
        window.setFrameOrigin(
            NSPoint(x: mouse.x - scrollCenterInWindow.x, y: mouse.y - scrollCenterInWindow.y)
        )
    }

    private func refreshStatus() {
        statusLabel?.stringValue = "Clicks: \(state.clickCount)   Secondary: \(state.secondaryActionCount)   Keys: \(state.keyEventCount)   Scrolls: \(state.scrollEventCount)"
    }

    private func writeReadyMarker() {
        guard let readyURL = options.readyURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: readyURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("ready\n".utf8).write(to: readyURL, options: .atomic)
        } catch {
            fputs("DeepSeekBridgeFixture: unable to write ready marker: \(error)\n", stderr)
        }
    }
}

@MainActor
private func runFixture() {
    let options = FixtureOptions(arguments: CommandLine.arguments)
    let application = NSApplication.shared
    let delegate = FixtureDelegate(options: options)
    application.setActivationPolicy(.regular)
    application.delegate = delegate
    application.run()
}

await MainActor.run {
    runFixture()
}
