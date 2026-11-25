import Foundation
import CSQLite

/// One local SQLite database, updated transactionally. Stored JSON retains format-specific locators.
public final class LibraryStore {
    private var db: OpaquePointer?
    public let root: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Books"), withIntermediateDirectories: true)
        guard sqlite3_open(root.appendingPathComponent("library.sqlite").path, &db) == SQLITE_OK else {
            throw LeafError.invalid("无法打开本地书库数据库。")
        }
        try execute("PRAGMA journal_mode=WAL")
        try execute("CREATE TABLE IF NOT EXISTS objects (kind TEXT NOT NULL, id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(kind,id))")
    }
    deinit { sqlite3_close(db) }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func failure() -> LeafError { .invalid("保存书库失败：\(String(cString: sqlite3_errmsg(db)))") }

    public func save<T: Encodable>(_ object: T, kind: String, id: String) throws {
        let data = try JSONEncoder().encode(object)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO objects(kind,id,payload) VALUES(?,?,?)", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, kind, -1, transient)
        sqlite3_bind_text(stmt, 2, id, -1, transient)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(data.count), transient) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }
    public func load<T: Decodable>(_ type: T.Type, kind: String) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM objects WHERE kind=?", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, kind, -1, transient)
        var values: [T] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { throw failure() }
            values.append(try JSONDecoder().decode(type, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))))
        }
        return values
    }
    public func remove(kind: String, id: String) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM objects WHERE kind=? AND id=?", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, kind, -1, transient); sqlite3_bind_text(stmt, 2, id, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }
    public func restore(_ backup: Backup) throws {
        guard backup.version == 1 else { throw LeafError.invalid("这个备份版本暂不支持。") }
        // Import only annotations whose exact book file exists locally. Never silently rebind to another edition.
        let local = Set(try load(Book.self, kind: "book").map(\.id))
        guard backup.annotations.allSatisfy({ local.contains($0.bookID) }) else {
            throw LeafError.invalid("请先导入备份对应的原版 EPUB，再恢复笔记。备份不包含书籍文件。")
        }
        try execute("BEGIN IMMEDIATE")
        do {
            for item in backup.annotations { try save(item, kind: "annotation", id: item.id.uuidString) }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func bookDirectory(_ id: String) -> URL { root.appendingPathComponent("Books/\(id)") }
}
