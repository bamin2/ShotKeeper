import Foundation

/// Watches a folder for newly created image files using FSEvents, and calls
/// `onNewFile` for each one. Used for the "auto-rename on new screenshot" feature.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let folder: URL
    private let onNewFile: (URL) -> Void
    private var seen = Set<String>()

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "tiff"]

    init(folder: URL, onNewFile: @escaping (URL) -> Void) {
        self.folder = folder
        self.onNewFile = onNewFile
        // Pre-seed with existing files so we only react to genuinely new ones.
        if let existing = try? FileManager.default.contentsOfDirectory(atPath: folder.path) {
            seen = Set(existing)
        }
    }

    /// Mark a filename as already-seen so the watcher won't process it. The app
    /// calls this for files it renames itself, preventing a feedback loop where
    /// a renamed screenshot looks like a brand-new file.
    func ignore(_ filename: String) {
        seen.insert(filename)
    }

    func start() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, _, _, _ in
            guard let info = info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.scan()
        }

        stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [folder.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, // latency seconds
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        )
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func scan() {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in files where !seen.contains(name) {
            seen.insert(name)
            let ext = (name as NSString).pathExtension.lowercased()
            guard Self.imageExtensions.contains(ext) else { continue }
            onNewFile(folder.appendingPathComponent(name))
        }
    }
}
