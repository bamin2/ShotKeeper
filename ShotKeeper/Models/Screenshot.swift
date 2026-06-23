import Foundation

/// One indexed screenshot. Mirrors a row in the SQLite `shots` table.
struct Screenshot: Identifiable, Hashable {
    let id: String          // stable id (we use the original file path hash)
    var currentPath: URL    // where the file lives right now
    var originalName: String // name before we renamed it (for revert)
    var currentName: String  // current file name on disk
    var ocrText: String      // text extracted from the image
    var summary: String      // short AI description
    var keywords: [String]   // searchable tags
    var indexedAt: Date

    var displayName: String { currentName }
}

/// What the vision model returns for a single image.
struct VisionResult: Codable {
    let name: String          // suggested descriptive file name (no extension)
    let ocr: String           // visible text in the image
    let summary: String       // one-line description
    let keywords: [String]    // 3-8 search keywords
}
