import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite-backed persistence for clipboard history.
/// Lives in ~/Library/Application Support/ATFM/clipboard.sqlite
final class ClipboardStore: @unchecked Sendable {
    let directory: URL
    let databaseURL: URL
    private var db: OpaquePointer?
    private let lock = NSLock()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("ATFM", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("clipboard.sqlite")
        open()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Schema

    private func open() {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK else {
            NSLog("ATFM: failed to open database: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("""
        CREATE TABLE IF NOT EXISTS clips (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at REAL NOT NULL,
            kind INTEGER NOT NULL,
            text TEXT NOT NULL DEFAULT '',
            app_name TEXT,
            app_bundle_id TEXT,
            app_path TEXT,
            byte_count INTEGER NOT NULL DEFAULT 0,
            image_w INTEGER NOT NULL DEFAULT 0,
            image_h INTEGER NOT NULL DEFAULT 0,
            image_data BLOB,
            thumb_data BLOB,
            hash TEXT NOT NULL
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_clips_created ON clips(created_at DESC);")
        exec("CREATE INDEX IF NOT EXISTS idx_clips_hash ON clips(hash);")
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            NSLog("ATFM sqlite error: \(err.map { String(cString: $0) } ?? "unknown")")
            sqlite3_free(err)
            return false
        }
        return true
    }

    // MARK: - Reads

    func fetchAll() -> [ClipItem] {
        lock.lock(); defer { lock.unlock() }
        var items: [ClipItem] = []
        var stmt: OpaquePointer?
        let sql = """
        SELECT id, created_at, kind, text, app_name, app_bundle_id, app_path,
               byte_count, image_w, image_h, hash
        FROM clips ORDER BY created_at DESC, id DESC
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            items.append(ClipItem(
                id: sqlite3_column_int64(stmt, 0),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                kind: ClipKind(rawValue: Int(sqlite3_column_int(stmt, 2))) ?? .text,
                text: columnText(stmt, 3) ?? "",
                app: SourceApp(name: columnText(stmt, 4), bundleID: columnText(stmt, 5), path: columnText(stmt, 6)),
                byteCount: Int(sqlite3_column_int64(stmt, 7)),
                imageWidth: Int(sqlite3_column_int(stmt, 8)),
                imageHeight: Int(sqlite3_column_int(stmt, 9)),
                hash: columnText(stmt, 10) ?? ""
            ))
        }
        return items
    }

    func imageData(id: Int64) -> Data? { blob(column: "image_data", id: id) }
    func thumbData(id: Int64) -> Data? { blob(column: "thumb_data", id: id) }

    private func blob(column: String, id: Int64) -> Data? {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT \(column) FROM clips WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW, let ptr = sqlite3_column_blob(stmt, 0) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, 0))
        return Data(bytes: ptr, count: count)
    }

    var databaseSizeBytes: Int64 {
        let paths = [databaseURL.path, databaseURL.path + "-wal"]
        return paths.reduce(0) { total, path in
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            return total + ((attrs?[.size] as? Int64) ?? 0)
        }
    }

    // MARK: - Writes

    func insert(_ clip: CapturedClip) -> ClipItem? {
        lock.lock(); defer { lock.unlock() }
        let sql = """
        INSERT INTO clips (created_at, kind, text, app_name, app_bundle_id, app_path,
                           byte_count, image_w, image_h, image_data, thumb_data, hash)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        var width = 0, height = 0
        var image: Data?
        var thumb: Data?
        if case let .image(png, t, w, h, _) = clip.payload {
            width = w; height = h; image = png; thumb = t
        }

        sqlite3_bind_double(stmt, 1, clip.date.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 2, Int32(clip.kind.rawValue))
        bind(stmt, 3, clip.text)
        bind(stmt, 4, clip.source.name)
        bind(stmt, 5, clip.source.bundleID)
        bind(stmt, 6, clip.source.path)
        sqlite3_bind_int64(stmt, 7, Int64(clip.byteCount))
        sqlite3_bind_int(stmt, 8, Int32(width))
        sqlite3_bind_int(stmt, 9, Int32(height))
        bindBlob(stmt, 10, image)
        bindBlob(stmt, 11, thumb)
        bind(stmt, 12, clip.hash)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            NSLog("ATFM: insert failed: \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
        let id = sqlite3_last_insert_rowid(db)
        return ClipItem(id: id, createdAt: clip.date, kind: clip.kind, text: clip.text, app: clip.source,
                        byteCount: clip.byteCount, imageWidth: width, imageHeight: height, hash: clip.hash)
    }

    /// Moves an existing entry to the top by updating its timestamp and source app.
    func bump(id: Int64, date: Date, source: SourceApp) {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        let sql = "UPDATE clips SET created_at = ?, app_name = ?, app_bundle_id = ?, app_path = ? WHERE id = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
        bind(stmt, 2, source.name)
        bind(stmt, 3, source.bundleID)
        bind(stmt, 4, source.path)
        sqlite3_bind_int64(stmt, 5, id)
        sqlite3_step(stmt)
    }

    func delete(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        exec("BEGIN")
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM clips WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
            for id in ids {
                sqlite3_reset(stmt)
                sqlite3_bind_int64(stmt, 1, id)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
        exec("COMMIT")
    }

    func deleteAll() {
        lock.lock(); defer { lock.unlock() }
        exec("DELETE FROM clips")
        exec("VACUUM")
    }

    // MARK: - Binding helpers

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindBlob(_ stmt: OpaquePointer?, _ index: Int32, _ data: Data?) {
        if let data, !data.isEmpty {
            data.withUnsafeBytes { buffer in
                _ = sqlite3_bind_blob(stmt, index, buffer.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}
