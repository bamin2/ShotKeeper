import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            PreferencesPane()
                .tabItem { Label("Preferences", systemImage: "slider.horizontal.3") }
            APIKeyPane()
                .tabItem { Label("API Key", systemImage: "key") }
            HelpPane()
                .tabItem { Label("Help", systemImage: "questionmark.circle") }
            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 540, height: 480)
    }
}

// MARK: - Preferences

struct PreferencesPane: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Form {
            Section("Keyboard Shortcuts") {
                ShortcutRow(title: "Rename Selected",
                            key: $store.scRenameKey, cmd: $store.scRenameCmd,
                            opt: $store.scRenameOpt, ctrl: $store.scRenameCtrl, shift: $store.scRenameShift)
                ShortcutRow(title: "Open Search",
                            key: $store.scSearchKey, cmd: $store.scSearchCmd,
                            opt: $store.scSearchOpt, ctrl: $store.scSearchCtrl, shift: $store.scSearchShift)
                Text("Shortcuts apply while ShotKeeper is the active app.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Watch Folder") {
                Toggle("Automatically rename new screenshots", isOn: Binding(
                    get: { store.autoRename },
                    set: { store.setAutoRename($0) }))
                HStack {
                    TextField("Folder to watch", text: $store.watchFolderPath)
                    Button("Choose…") { chooseFolder() }
                }
                Text("Point this at your Desktop or wherever macOS saves screenshots.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Custom AI Instructions") {
                TextField("Added to the base prompt", text: $store.namingStyle, axis: .vertical)
                    .lineLimit(3...6)
                Text("""
                Layered on top of the built-in prompt for every engine. Examples:
                • “Include the app or website name if visible.”
                • “Prefer the document title; keep names under 5 words.”
                • “Add the date when one is shown.”
                """)
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: store.scRenameKey)   { _, _ in store.applyGlobalShortcuts() }
        .onChange(of: store.scRenameCmd)   { _, _ in store.applyGlobalShortcuts() }
        .onChange(of: store.scRenameOpt)   { _, _ in store.applyGlobalShortcuts() }
        .onChange(of: store.scRenameCtrl)  { _, _ in store.applyGlobalShortcuts() }
        .onChange(of: store.scRenameShift) { _, _ in store.applyGlobalShortcuts() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            store.watchFolderPath = url.path
            if store.autoRename { store.stopWatching(); store.startWatching() }
        }
    }
}

/// One editable shortcut: modifier toggle-buttons + a single key.
struct ShortcutRow: View {
    let title: String
    @Binding var key: String
    @Binding var cmd: Bool
    @Binding var opt: Bool
    @Binding var ctrl: Bool
    @Binding var shift: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Spacer()
            Toggle("⌃", isOn: $ctrl).toggleStyle(.button)
            Toggle("⌥", isOn: $opt).toggleStyle(.button)
            Toggle("⇧", isOn: $shift).toggleStyle(.button)
            Toggle("⌘", isOn: $cmd).toggleStyle(.button)
            TextField("", text: $key)
                .frame(width: 34)
                .multilineTextAlignment(.center)
                .onChange(of: key) { _, newValue in
                    if let c = newValue.lowercased().last { key = String(c) } else { key = "" }
                }
        }
    }
}

// MARK: - API keys

struct APIKeyPane: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Form {
            Section("Claude (Anthropic)") {
                Toggle("Use Claude", isOn: $store.enableClaude)
                SecureField("API key (sk-ant-…)", text: $store.claudeKey)
                TextField("Model", text: $store.claudeModel)
            }
            Section("OpenAI") {
                Toggle("Use OpenAI", isOn: $store.enableOpenAI)
                SecureField("API key (sk-…)", text: $store.openAIKey)
                TextField("Model", text: $store.openAIModel)
            }
            Section("Apple Intelligence") {
                Toggle("Use Apple Intelligence", isOn: $store.enableApple)
                Text("Runs on-device, free, no key required. Always used as the fallback, so ShotKeeper works even with no API keys set.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Engines are tried in priority order: Claude → OpenAI → Apple Intelligence. The first enabled engine with a key names each screenshot; if it fails, the next one takes over.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Help

struct HelpPane: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                item("Rename from Finder",
                     "Select screenshots in Finder, then choose “Rename Selected” from the ShotKeeper menu-bar icon (or its shortcut).")
                item("Rename in the app",
                     "Click Rename ▸ Choose Files…, or drag screenshots straight onto the window.")
                item("Search",
                     "Type any keyword, visible text, or description. Results group by date — tap a #keyword to filter to it.")
                item("List or grid",
                     "Use the toggle next to the search bar. Click any thumbnail to open the full screenshot.")
                item("Rename manually",
                     "Double-click a file’s name in the list to edit it yourself.")
                item("Revert",
                     "Every AI rename can be undone with Revert, restoring the original file name.")
                item("Auto-rename",
                     "In Preferences, choose a watch folder and turn on auto-rename to name new screenshots automatically.")
                item("Engines",
                     "Pick Claude, OpenAI, and/or Apple Intelligence in the API Key tab. Apple Intelligence runs privately on-device and is always available.")
            }
            .padding()
        }
    }

    private func item(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(body).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - About

struct AboutPane: View {
    @EnvironmentObject var updater: UpdaterManager

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 92, height: 92)
            VStack(spacing: 2) {
                Text("ShotKeeper").font(.title.bold())
                Text("Version \(appVersion)").font(.caption).foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                Text("Bader Amin").font(.title3.weight(.semibold))
                Text("DEVELOPER")
                    .font(.caption2.weight(.bold))
                    .tracking(1.5)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)))

            VStack(spacing: 6) {
                Button { updater.checkForUpdates() } label: {
                    Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!updater.canCheckForUpdates)
                if !updater.isConfigured {
                    Text("Add the Sparkle package to enable updates.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
