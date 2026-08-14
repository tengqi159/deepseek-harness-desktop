import AppKit
import SwiftUI

@main
struct DeepSeekHarnessMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var harness = HarnessService()
    @StateObject private var artifactStore = ArtifactStore()
    @StateObject private var appshotStore = AppshotStore()
    @StateObject private var modelCapabilityStore = ModelCapabilityStore()
    @StateObject private var remoteHostStore = RemoteHostStore()

    var body: some Scene {
        WindowGroup("DeepSeek Harness") {
            ContentView(
                harness: harness,
                artifactStore: artifactStore,
                appshotStore: appshotStore,
                modelCapabilityStore: modelCapabilityStore,
                remoteHostStore: remoteHostStore
            )
                .task {
                    appDelegate.harness = harness
                    appDelegate.configureAppshot(store: appshotStore)
                    await harness.start()
                }
        }
        .defaultSize(width: 1240, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .toolbar) {
                Button("重新载入") {
                    harness.reload()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!harness.isReady)

                Button("在浏览器中打开") {
                    harness.openInBrowser()
                }
                .disabled(!harness.isReady)

                Divider()

                Button("导入研究文件…") {
                    artifactStore.importFiles()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("创建 Appshot") {
                    appshotStore.captureAfterSwitchingApplications()
                }
                .keyboardShortcut("2", modifiers: [.command, .shift, .option])
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var harness: HarnessService?
    private var appshotHotKey: GlobalHotKeyController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        appshotHotKey?.unregister()
        harness?.stop()
    }

    func configureAppshot(store: AppshotStore) {
        guard appshotHotKey == nil else { return }
        let controller = GlobalHotKeyController { [weak store] in
            store?.captureFrontmostApplication()
        }
        do {
            try controller.register()
            appshotHotKey = controller
        } catch {
            NSLog("Unable to register Appshot hot key: %@", error.localizedDescription)
        }
    }
}
