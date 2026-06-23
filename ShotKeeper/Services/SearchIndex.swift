import Foundation
import SQLite3

/// Local, offline full-text search index backed by SQLite FTS5.
/// Lives in Application Support — nothing leaves the machine except the image
/// sent to the vision model at rename time.
final class SearchIndex {
    private var db: OpaquePointer?
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShotKeeper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("index.sqlite").path

        if sqlite3_open(path, &db) != SQLITE_OK {
            assertionFailure("Could not open SQLite db at \(path)")
        }
        createSchema()
    }

    deinit { sqlite3_close(db) }

    private func createSchema() {
        let sql = """
        CREATE TABLE IF NOT EXISTS shots(
            id TEXT PRIMARY KEY,
            current_path TEXT NOT NULL,
            original_name TEXT NOT NULL,
            current_name TEXT NOT NULL,
            ocr TEXT, summary TEXT, keywords TEXT,
            indexed_at REAL
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS shots_fts USING fts5(
            current_name, ocr, summary, keywords,
            content='shots', content_rowid='rowid'
        );
        """
        exec(sql)
    }

    // MARK: - Writes

    func upsert(_ s: Screenshot) {
        let sql = """
        INSERT INTO shots(id,current_path,original_name,current_name,ocr,summary,keywords,indexed_at)
        VALUES(?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          current_path=excluded.current_path, current_name=excluded.current_name,
          ocr=excluded.ocr, summary=excluded.summary, keywords=excluded.keywords,
          indexed_at=excluded.indexed_at;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, s.id)
        bind(stmt, 2, s.currentPath.path)
        bind(stmt, 3, s.originalName)
        bind(stmt, 4, s.currentName)
        bind(stmt, 5, s.ocrText)
        bind(stmt, 6, s.summary)
        bind(stmt, 7, s.keywords.joined(separator: " "))
        sqlite3_bind_double(stmt, 8, s.indexedAt.timeIntervalSince1970)
        sqlite3_step(stmt)
        rebuildFTS()
    }

    func delete(id: String) {
        let sql = "DELETE FROM shots WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id)
        sqlite3_step(stmt)
        rebuildFTS()
    }

    // MARK: - Reads

    /// Empty query returns everything (most recent first).
    func search(_ query: String) -> [Screenshot] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let sql: String
        if trimmed.isEmpty {
            sql = "SELECT id,current_path,original_name,current_name,ocr,summary,keywords,indexed_at FROM shots ORDER BY indexed_at DESC;"
        } else {
            sql = """
            SELECT s.id,s.current_path,s.original_name,s.current_name,s.ocr,s.summary,s.keywords,s.indexed_at
            FROM shots_fts f JOIN shots s ON s.rowid = f.rowid
            WHERE shots_fts MATCH ? ORDER BY rank;
            """
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        if !trimmed.isEmpty {
            // Prefix-match each token so partial words hit.
            let match = trimmed.split(separator: " ").map { "\($0)*" }.joined(separator: " ")
            bind(stmt, 1, match)
        }

        var out: [Screenshot] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(row(stmt))
        }
        return out
    }

    // MARK: - Helpers

    private func row(_ stmt: OpaquePointer?) -> Screenshot {
        Screenshot(
            id: col(stmt, 0),
            currentPath: URL(fileURLWithPath: col(stmt, 1)),
            originalName: col(stmt, 2),
            currentName: col(stmt, 3),
            ocrText: col(stmt, 4),
            summary: col(stmt, 5),
            keywords: col(stmt, 6).split(separator: " ").map(String.init),
            indexedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
        )
    }

    private func rebuildFTS() {
        exec("INSERT INTO shots_fts(shots_fts) VALUES('rebuild');")
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func bind(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
        sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT)
    }

    private func col(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: c)
    }
}
