import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.openSettings) private var openSettings
    @AppStorage("listView") private var listView = true
    @State private var dropTargeted = false

    private let gridColumns = [GridItem(.adaptive(minimum: 180), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if store.isWorking {
                ProgressView(value: store.progress) { Text(store.statusMessage).font(.caption) }
                    .padding(.horizontal).padding(.top, 6)
            }
            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).font(.caption)
                    .padding(.horizontal).padding(.top, 4)
            }
            content
            Divider()
            statusBar
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers); return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(6)
            }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search by keyword, text, or description…", text: $store.query)
                    .textFieldStyle(.plain)
                if !store.query.isEmpty {
                    Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text(resultCountLabel).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $listView) {
                    Image(systemName: "list.bullet").tag(true)
                    Image(systemName: "square.grid.2x2").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()

                Button { openSettings() } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")

                Menu {
                    Button("Rename Finder Selection") { store.renameFinderSelection() }
                        .keyboardShortcut("r", modifiers: .command)
                    Button("Choose Files…") { pickAndRename() }
                } label: {
                    Label("Rename", systemImage: "wand.and.stars")
                }
                .menuStyle(.button)
                .fixedSize()
                .disabled(store.isWorking)
            }
        }
        .padding(12)
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Label(store.engineStatus, systemImage: store.isOnDevicePrimary ? "lock.laptopcomputer" : "cloud")
            Label(watcherStatus, systemImage: store.autoRename ? "eye.fill" : "eye.slash")
            Spacer()
            if store.queueTotal > 0 {
                Text("Queue \(store.queueDone)/\(store.queueTotal)")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var watcherStatus: String {
        guard store.autoRename, !store.watchFolderPath.isEmpty else { return "Auto-rename off" }
        return "Watching \(URL(fileURLWithPath: store.watchFolderPath).lastPathComponent)"
    }

    private var resultCountLabel: String {
        let n = store.results.count
        let noun = n == 1 ? "screenshot" : "screenshots"
        return store.query.isEmpty ? "\(n) \(noun)" : "\(n) \(noun) matching"
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if store.results.isEmpty {
            ContentUnavailableView(
                store.query.isEmpty ? "No screenshots yet" : "No matches",
                systemImage: store.query.isEmpty ? "photo.on.rectangle.angled" : "magnifyingglass",
                description: Text(store.query.isEmpty
                    ? "Click “Rename files…”, or drag screenshots onto this window."
                    : "Try a different keyword.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections, id: \.title) { section in
                        Section {
                            if listView {
                                ForEach(section.shots) { ShotRow(shot: $0) }
                            } else {
                                LazyVGrid(columns: gridColumns, spacing: 12) {
                                    ForEach(section.shots) { ShotCard(shot: $0) }
                                }
                            }
                        } header: {
                            sectionHeader(section.title, count: section.shots.count)
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            Text("\(count)").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 4)
        .background(.bar)
    }

    /// Group results into Today / Yesterday / Earlier This Week / Earlier.
    private var sections: [(title: String, shots: [Screenshot])] {
        let cal = Calendar.current
        let order = ["Today", "Yesterday", "Earlier This Week", "Earlier"]
        var buckets: [String: [Screenshot]] = [:]
        for s in store.results {
            let key: String
            if cal.isDateInToday(s.indexedAt) { key = "Today" }
            else if cal.isDateInYesterday(s.indexedAt) { key = "Yesterday" }
            else if let d = cal.dateComponents([.day], from: s.indexedAt, to: Date()).day, d < 7 {
                key = "Earlier This Week"
            } else { key = "Earlier" }
            buckets[key, default: []].append(s)
        }
        return order.compactMap { k in buckets[k].map { (k, $0) } }
    }

    // MARK: Actions

    private func pickAndRename() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .gif, .tiff, .image]
        panel.level = .modalPanel
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await store.renameBatch(urls) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in
                    _ = try? await store.rename(url)
                    store.runSearch()
                }
            }
        }
    }
}

// MARK: - Shared pieces

/// Shows the FULL screenshot (scaled to fit — never cropped) on a subtle
/// letterbox background. Click opens the file in the default viewer.
struct Thumbnail: View {
    let url: URL
    var height: CGFloat
    var cornerRadius: CGFloat = 8

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.primary.opacity(0.06))
            .frame(height: height)
            .overlay {
                if let img = NSImage(contentsOf: url) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .padding(3)
                } else {
                    Image(systemName: "photo").imageScale(.large).foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .contentShape(Rectangle())
            .onTapGesture { NSWorkspace.shared.open(url) }
            .help("Click to open")
    }
}

/// Wraps chips onto new lines as whole pills (so text never breaks mid-word).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > maxWidth, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            sv.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}

/// Clickable keyword chips — tapping one searches for that keyword.
struct KeywordChips: View {
    @EnvironmentObject var store: AppStore
    let keywords: [String]
    var limit: Int = 5

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(keywords.prefix(limit), id: \.self) { kw in
                Button { store.query = kw } label: {
                    Text("#\(kw)")
                        .font(.caption2)
                        .lineLimit(1)
                        .fixedSize()          // chip sizes to its text; never wraps
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.12)))
                .foregroundStyle(.primary)
            }
        }
    }
}

/// Editable file name: double-click to rename in place.
struct EditableName: View {
    @EnvironmentObject var store: AppStore
    let shot: Screenshot
    var font: Font = .callout
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if editing {
            TextField("Name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(font)
                .focused($focused)
                .onAppear { focused = true }
                .onSubmit(commit)
                .onExitCommand { editing = false }
        } else {
            Text(shot.currentName)
                .font(font).fontWeight(.medium)
                .lineLimit(1).truncationMode(.middle)
                .onTapGesture(count: 2) {
                    draft = (shot.currentName as NSString).deletingPathExtension
                    editing = true
                }
                .help("Double-click to rename")
        }
    }

    private func commit() {
        editing = false
        store.manualRename(shot, toBaseName: draft)
    }
}

/// Reveal / Revert actions shared by both layouts.
struct ShotActions: View {
    @EnvironmentObject var store: AppStore
    let shot: Screenshot

    var body: some View {
        HStack(spacing: 12) {
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([shot.currentPath]) }
                .buttonStyle(.borderless).font(.caption)
            Button("Copy") { copyToClipboard() }
                .buttonStyle(.borderless).font(.caption)
            Button("Revert") { store.revert(shot) }
                .buttonStyle(.borderless).font(.caption).foregroundStyle(.orange)
        }
    }

    /// Copy the screenshot to the clipboard — as both the file and the image,
    /// so it pastes into Finder/Mail (file) or image editors (picture).
    private func copyToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        var items: [NSPasteboardWriting] = [shot.currentPath as NSURL]
        if let image = NSImage(contentsOf: shot.currentPath) { items.append(image) }
        pb.writeObjects(items)
    }
}

// MARK: - Grid card

struct ShotCard: View {
    let shot: Screenshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Thumbnail(url: shot.currentPath, height: 150)
            EditableName(shot: shot)
            if !shot.summary.isEmpty {
                Text(shot.summary).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if !shot.keywords.isEmpty { KeywordChips(keywords: shot.keywords) }
            Spacer(minLength: 0)
            Divider().opacity(0.4)
            HStack { ShotActions(shot: shot); Spacer() }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }
}

// MARK: - List row

struct ShotRow: View {
    let shot: Screenshot

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Thumbnail(url: shot.currentPath, height: 56, cornerRadius: 6)
                .frame(width: 84)
            VStack(alignment: .leading, spacing: 5) {
                EditableName(shot: shot, font: .callout)
                if !shot.summary.isEmpty {
                    Text(shot.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !shot.keywords.isEmpty { KeywordChips(keywords: shot.keywords, limit: 6) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ShotActions(shot: shot)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary.opacity(0.6)))
    }
}
