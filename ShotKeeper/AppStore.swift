import Foundation
import SwiftUI
import AppKit
import CryptoKit
import Combine
import Security
import Carbon.HIToolbox

/// Central app state + orchestration: settings, the search index, the rename
/// engine, batch progress, and the optional auto-rename folder watcher.
@MainActor
final class AppStore: ObservableObject {
    // API keys live in the macOS Keychain (one entry per provider).
    @Published var claudeKey: String = Keychain.load(.claude) {
        didSet { Keychain.save(claudeKey, .claude) }
    }
    @Published var openAIKey: String = Keychain.load(.openAI) {
        didSet { Keychain.save(openAIKey, .openAI) }
    }

    // Which engines are enabled. Tried in priority order: Claude → OpenAI →
    // Apple Intelligence. Apple Intelligence is always the final fallback, so
    // the app is never unusable without an API key.
    @AppStorage("enableClaude") var enableClaude = false
    @AppStorage("enableOpenAI") var enableOpenAI = false
    @AppStorage("enableApple")  var enableApple  = true

    @AppStorage("claudeModel") var claudeModel = "claude-sonnet-4-6"
    @AppStorage("openAIModel") var openAIModel = "gpt-4o-mini"

    @AppStorage("namingStyle") var namingStyle: String = "Use Title Case and keep it under 6 words."
    @AppStorage("autoRename")  var autoRename: Bool = false
    @AppStorage("watchFolder") var watchFolderPath: String = ""

    // Customizable in-app keyboard shortcuts (applied to the menu-bar items).
    // Default ⌥⌘I — a global hotkey, so it deliberately avoids plain ⌘-combos
    // that would clash with other apps' shortcuts.
    @AppStorage("scRenameKey")   var scRenameKey   = "i"
    @AppStorage("scRenameCmd")   var scRenameCmd   = true
    @AppStorage("scRenameOpt")   var scRenameOpt   = true
    @AppStorage("scRenameCtrl")  var scRenameCtrl  = false
    @AppStorage("scRenameShift") var scRenameShift = false
    @AppStorage("scSearchKey")   var scSearchKey   = "s"
    @AppStorage("scSearchCmd")   var scSearchCmd   = true
    @AppStorage("scSearchOpt")   var scSearchOpt   = false
    @AppStorage("scSearchCtrl")  var scSearchCtrl  = false
    @AppStorage("scSearchShift") var scSearchShift = true

    var renameModifiers: SwiftUI.EventModifiers { Self.mods(scRenameCmd, scRenameOpt, scRenameCtrl, scRenameShift) }
    var searchModifiers: SwiftUI.EventModifiers { Self.mods(scSearchCmd, scSearchOpt, scSearchCtrl, scSearchShift) }
    var renameKeyEquivalent: KeyEquivalent { KeyEquivalent(scRenameKey.lowercased().first ?? "i") }
    var searchKeyEquivalent: KeyEquivalent { KeyEquivalent(scSearchKey.lowercased().first ?? "s") }

    private static func mods(_ cmd: Bool, _ opt: Bool, _ ctrl: Bool, _ shift: Bool) -> SwiftUI.EventModifiers {
        var m: SwiftUI.EventModifiers = []
        if cmd { m.insert(.command) }
        if opt { m.insert(.option) }
        if ctrl { m.insert(.control) }
        if shift { m.insert(.shift) }
        return m
    }

    // UI state
    @Published var results: [Screenshot] = []
    @Published var query: String = "" { didSet { runSearch() } }
    @Published var isWorking = false
    @Published var progress: Double = 0      // 0...1 during batch
    @Published var statusMessage: String = ""
    @Published var lastError: String?
    @Published var queueTotal = 0            // shown in the menu bar as done/total
    @Published var queueDone = 0

    private let index = SearchIndex()
    private var watcher: FolderWatcher?

    init() {
        runSearch()
        if autoRename { startWatching() }
        applyGlobalShortcuts()
    }

    /// (Re)register the system-wide hotkey for Rename Selected so it works even
    /// while another app (e.g. Finder) is frontmost.
    func applyGlobalShortcuts() {
        GlobalHotkeyManager.shared.register(
            name: "rename",
            character: scRenameKey.lowercased().first,
            cmd: scRenameCmd, opt: scRenameOpt, ctrl: scRenameCtrl, shift: scRenameShift
        ) { [weak self] in
            Task { @MainActor in self?.renameFinderSelection(activate: false) }
        }
    }

    enum Engine { case claude, openAI, apple }

    /// Enabled engines in priority order. Apple Intelligence is always appended
    /// as the final fallback so naming never fails for lack of a key.
    private func orderedEngines() -> [Engine] {
        var list: [Engine] = []
        if enableClaude, !claudeKey.isEmpty { list.append(.claude) }
        if enableOpenAI, !openAIKey.isEmpty { list.append(.openAI) }
        list.append(.apple)
        return list
    }

    /// True when the primary engine runs on-device (for the footer icon).
    var isOnDevicePrimary: Bool { orderedEngines().first == .apple }

    /// Human-readable engine order shown in the footer, e.g. "Claude → Apple Intelligence".
    var engineStatus: String {
        orderedEngines().map { engine in
            switch engine {
            case .claude: return "Claude"
            case .openAI: return "OpenAI"
            case .apple:  return "Apple Intelligence"
            }
        }.joined(separator: " → ")
    }

    /// Try each enabled engine in order, falling through to the next on error.
    private func describe(_ url: URL) async throws -> VisionResult {
        var lastError: Error?
        for engine in orderedEngines() {
            do {
                switch engine {
                case .claude:
                    return try await VisionClient(apiKey: claudeKey, model: claudeModel, namingStyle: namingStyle)
                        .describe(imageAt: url)
                case .openAI:
                    return try await OpenAIClient(apiKey: openAIKey, model: openAIModel, namingStyle: namingStyle)
                        .describe(imageAt: url)
                case .apple:
                    return try await LocalVisionDescriber(namingStyle: namingStyle).describe(imageAt: url)
                }
            } catch {
                lastError = error
            }
        }
        throw lastError ?? VisionError.badImage
    }

    // MARK: - Search

    func runSearch() {
        // Drop any indexed entries whose file no longer exists (moved, deleted,
        // or left over from an earlier double-rename) so the grid stays clean.
        var alive: [Screenshot] = []
        for shot in index.search(query) {
            if FileManager.default.fileExists(atPath: shot.currentPath.path) {
                alive.append(shot)
            } else {
                index.delete(id: shot.id)
            }
        }
        results = alive
    }

    // MARK: - Rename

    /// Rename a batch of files picked by the user. Reports progress.
    func renameBatch(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        isWorking = true
        progress = 0
        lastError = nil
        queueTotal = urls.count
        queueDone = 0
        defer { isWorking = false; progress = 0; queueTotal = 0; queueDone = 0; runSearch() }

        for (i, url) in urls.enumerated() {
            statusMessage = "Naming \(url.lastPathComponent)…"
            do { try await rename(url) }
            catch { lastError = error.localizedDescription }
            queueDone = i + 1
            progress = Double(i + 1) / Double(urls.count)
        }
        statusMessage = "Done — \(urls.count) file(s) processed."
    }

    /// Process one file: ask the model, rename on disk, index it.
    @discardableResult
    func rename(_ url: URL) async throws -> Screenshot {
        let result = try await describe(url)

        let ext = url.pathExtension
        let cleaned = Self.sanitize(Self.normalizeCasing(result.name))
        let targetName = ext.isEmpty ? cleaned : "\(cleaned).\(ext)"
        let dest = Self.uniqueDestination(in: url.deletingLastPathComponent(), name: targetName)

        let originalName = url.lastPathComponent
        // Tell the watcher about the new name *before* the move so it doesn't
        // treat our own renamed file as a fresh screenshot to process again.
        watcher?.ignore(dest.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: dest)

        let shot = Screenshot(
            id: Self.stableID(for: originalName, in: url.deletingLastPathComponent()),
            currentPath: dest,
            originalName: originalName,
            currentName: dest.lastPathComponent,
            ocrText: result.ocr,
            summary: result.summary,
            keywords: result.keywords,
            indexedAt: Date()
        )
        index.upsert(shot)
        return shot
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "tiff"]

    /// Rename whatever image files are currently selected in Finder.
    /// `activate` brings ShotKeeper forward (so first-run prompts/errors show);
    /// the global hotkey passes false so renaming stays in the background.
    func renameFinderSelection(activate: Bool = true) {
        if activate { NSApp.activate(ignoringOtherApps: true) }
        do {
            let urls = try FinderBridge.selectedURLs()
            let images = urls.filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
            guard !images.isEmpty else {
                lastError = urls.isEmpty
                    ? "Nothing is selected in Finder."
                    : "No image files in the Finder selection."
                return
            }
            lastError = nil
            Task { await renameBatch(images) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Rename a file to a name the user typed in the grid (keeps the extension,
    /// updates the index in place, and tells the watcher to ignore it).
    func manualRename(_ shot: Screenshot, toBaseName base: String) {
        let cleaned = Self.sanitize(base)
        let dir = shot.currentPath.deletingLastPathComponent()
        let ext = shot.currentPath.pathExtension
        let targetName = ext.isEmpty ? cleaned : "\(cleaned).\(ext)"
        guard targetName != shot.currentName else { return }   // no-op

        let dest = Self.uniqueDestination(in: dir, name: targetName)
        watcher?.ignore(dest.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: shot.currentPath, to: dest)
            var updated = shot
            updated.currentPath = dest
            updated.currentName = dest.lastPathComponent
            index.upsert(updated)          // same id, so the row is updated
            runSearch()
        } catch {
            lastError = "Rename failed: \(error.localizedDescription)"
        }
    }

    /// Revert a previously renamed file back to its original name.
    func revert(_ shot: Screenshot) {
        let dir = shot.currentPath.deletingLastPathComponent()
        let dest = Self.uniqueDestination(in: dir, name: shot.originalName)
        do {
            try FileManager.default.moveItem(at: shot.currentPath, to: dest)
            index.delete(id: shot.id)
            runSearch()
        } catch {
            lastError = "Revert failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Auto-rename watcher

    func startWatching() {
        guard !watchFolderPath.isEmpty else { return }
        let folder = URL(fileURLWithPath: watchFolderPath)
        watcher = FolderWatcher(folder: folder) { [weak self] url in
            guard let self else { return }
            Task { @MainActor in
                try? await self.rename(url)
                self.runSearch()
            }
        }
        watcher?.start()
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    func setAutoRename(_ on: Bool) {
        autoRename = on
        if on { startWatching() } else { stopWatching() }
    }

    // MARK: - Utilities

    /// Title-case any ALL-CAPS word longer than 4 letters (e.g. a "STRATHCLYDE
    /// BUSINESS SCHOOL" letterhead the model copied verbatim), while leaving
    /// short acronyms like API, iOS, or EAS untouched.
    private static func normalizeCasing(_ name: String) -> String {
        name.split(separator: " ").map { word -> String in
            let w = String(word)
            if w.count > 4, w == w.uppercased(), w != w.lowercased() {
                return w.prefix(1).uppercased() + w.dropFirst().lowercased()
            }
            return w
        }.joined(separator: " ")
    }

    private static func sanitize(_ raw: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = raw.components(separatedBy: bad).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "screenshot" : String(cleaned.prefix(100))
    }

    private static func uniqueDestination(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }

        let base = (name as NSString).deletingPathExtension
        let ext  = (name as NSString).pathExtension
        var n = 2
        repeat {
            let next = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = dir.appendingPathComponent(next)
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    private static func stableID(for originalName: String, in dir: URL) -> String {
        let input = dir.path + "/" + originalName
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Keychain wrapper storing one generic-password item per provider.
/// Only this app (same code signature) can read them.
enum Keychain {
    enum Account: String {
        case claude = "anthropic-api-key"
        case openAI = "openai-api-key"
    }
    private static let service = "com.bader.ShotKeeper"
    private static let legacyDefaultsKey = "apiKey"   // pre-Keychain Claude key

    private static func baseQuery(_ account: Account) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account.rawValue]
    }

    static func save(_ value: String, _ account: Account) {
        SecItemDelete(baseQuery(account) as CFDictionary)
        guard !value.isEmpty else { return }             // empty == just remove
        var item = baseQuery(account)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    /// Load a key, migrating the legacy UserDefaults Claude key on first run.
    static func load(_ account: Account) -> String {
        if let existing = read(account), !existing.isEmpty { return existing }

        if account == .claude,
           let legacy = UserDefaults.standard.string(forKey: legacyDefaultsKey),
           !legacy.isEmpty {
            save(legacy, .claude)
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
            return legacy
        }
        return ""
    }

    private static func read(_ account: Account) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Finder selection bridge

enum FinderError: LocalizedError {
    case automationDenied
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .automationDenied:
            return "ShotKeeper isn't allowed to control Finder yet. Enable it in System Settings ▸ Privacy & Security ▸ Automation ▸ ShotKeeper ▸ Finder, then try again."
        case .scriptFailed(let m):
            return "Couldn't read the Finder selection: \(m)"
        }
    }
}

/// Reads the files currently selected in Finder via Apple Events, so the user
/// can select screenshots in Finder and rename them straight from the menu bar.
enum FinderBridge {
    static func selectedURLs() throws -> [URL] {
        let source = """
        tell application "Finder"
            set theItems to selection as alias list
            set thePaths to {}
            repeat with anItem in theItems
                set end of thePaths to POSIX path of (anItem as text)
            end repeat
            set AppleScript's text item delimiters to linefeed
            return thePaths as text
        end tell
        """
        guard let script = NSAppleScript(source: source) else {
            throw FinderError.scriptFailed("could not compile script")
        }
        var errorInfo: NSDictionary?
        let output = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            // -1743 = not authorized to send Apple events to Finder.
            if code == -1743 { throw FinderError.automationDenied }
            let msg = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "error \(code)"
            throw FinderError.scriptFailed(msg)
        }
        let text = output.stringValue ?? ""
        return text
            .split(separator: "\n")
            .map { URL(fileURLWithPath: String($0)) }
    }
}

// MARK: - Global hotkey (system-wide, via Carbon)

/// Registers system-wide hotkeys with Carbon's RegisterEventHotKey — they fire
/// even when another app is frontmost, and need no Accessibility permission.
final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    private var registrations: [String: (ref: EventHotKeyRef, id: UInt32)] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x53484b59  // 'SHKY'

    private init() { installHandler() }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, eventRef, userData in
            guard let eventRef, let userData else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(eventRef, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            manager.handlers[hkID.id]?()
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    /// Register (replacing any existing) a hotkey under `name`. A modifier is
    /// required; with none, the hotkey is cleared (we don't grab a bare key).
    func register(name: String, character: Character?,
                  cmd: Bool, opt: Bool, ctrl: Bool, shift: Bool,
                  action: @escaping () -> Void) {
        unregister(name)
        guard let character, let keyCode = Self.keyCodes[character] else { return }
        let mods = Self.carbonModifiers(cmd: cmd, opt: opt, ctrl: ctrl, shift: shift)
        guard mods != 0 else { return }

        let id = nextID; nextID += 1
        handlers[id] = action
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        if RegisterEventHotKey(keyCode, mods, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr,
           let ref {
            registrations[name] = (ref, id)
        } else {
            handlers[id] = nil
        }
    }

    func unregister(_ name: String) {
        if let reg = registrations[name] {
            UnregisterEventHotKey(reg.ref)
            handlers[reg.id] = nil
            registrations[name] = nil
        }
    }

    private static func carbonModifiers(cmd: Bool, opt: Bool, ctrl: Bool, shift: Bool) -> UInt32 {
        var m: UInt32 = 0
        if cmd  { m |= UInt32(cmdKey) }
        if opt  { m |= UInt32(optionKey) }
        if ctrl { m |= UInt32(controlKey) }
        if shift { m |= UInt32(shiftKey) }
        return m
    }

    /// US-ANSI virtual key codes for letters, digits, and a few symbols.
    private static let keyCodes: [Character: UInt32] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "9": 0x19,
        "7": 0x1A, "8": 0x1C, "0": 0x1D, "o": 0x1F, "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25,
        "j": 0x26, "k": 0x28, "n": 0x2D, "m": 0x2E
    ]
}
