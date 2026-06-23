import SwiftUI
import AppKit
import Combine
#if canImport(Sparkle)
import Sparkle
#endif

@main
struct ShotKeeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()
    @StateObject private var updater = UpdaterManager()

    var body: some Scene {
        // Regular Dock app: a single main window for Search / the queue…
        Window("ShotKeeper", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 720, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(updater)
        }

        // …plus a menu-bar dropdown for quick actions.
        MenuBarExtra {
            MenuBarMenu().environmentObject(store)
        } label: {
            Image(systemName: "camera.viewfinder")
                .symbolEffect(.pulse, isActive: store.isWorking)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// The menu-bar dropdown. "Rename Selected" runs in the background; "Search"
/// and "Queue Progress" bring up the main window.
struct MenuBarMenu: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Rename Selected") { store.renameFinderSelection() }
            .keyboardShortcut(store.renameKeyEquivalent, modifiers: store.renameModifiers)

        Button("Search") { showMainWindow() }
            .keyboardShortcut(store.searchKeyEquivalent, modifiers: store.searchModifiers)

        Button("Queue Progress: \(store.queueDone)/\(store.queueTotal)") { showMainWindow() }

        Divider()

        Button("Quit ShotKeeper") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    private func showMainWindow() {
        // Become a normal Dock app again before showing the window.
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Makes the app behave like Keep It Shot: a regular Dock app while a window is
/// open, but a menu-bar-only accessory (no Dock icon) once the window is closed.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil)
    }

    // Keep running (in the menu bar) after the last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc private func windowWillClose(_ note: Notification) {
        let closing = note.object as? NSWindow
        // After the window actually closes, if no real windows remain, drop the
        // Dock icon and live in the menu bar only.
        DispatchQueue.main.async {
            let hasVisibleWindow = NSApp.windows.contains { window in
                window !== closing && window.isVisible && window.canBecomeMain
            }
            if !hasVisibleWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

/// Wraps Sparkle's updater. Guarded by `#if canImport(Sparkle)` so the app
/// builds before the Sparkle package is added, then activates once it is.
final class UpdaterManager: ObservableObject {
    @Published var canCheckForUpdates = false

    /// True once the Sparkle package is linked.
    var isConfigured: Bool {
        #if canImport(Sparkle)
        return true
        #else
        return false
        #endif
    }

    #if canImport(Sparkle)
    private let controller: SPUStandardUpdaterController
    #endif

    init() {
        #if canImport(Sparkle)
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        #endif
    }

    func checkForUpdates() {
        #if canImport(Sparkle)
        controller.updater.checkForUpdates()
        #endif
    }
}
